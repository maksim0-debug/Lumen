import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'app_logger.dart';
import 'preferences_helper.dart';
import 'fcm_test_notification_service.dart';
import 'schedule_change_notification_service.dart';
import 'background_service.dart';
import '../models/emergency_status.dart';
import 'emergency_notification_service.dart';
import '../models/schedule_snapshot.dart';
import '../models/schedule_change_event.dart';
import 'schedule_ingestion_service.dart';

/// Full snapshots are applied locally. Legacy events retain network recovery.
@visibleForTesting
Future<bool> handleSnapshotPush(Map<String, dynamic> data,
    {ScheduleIngestionService? ingestion,
    bool alreadyDisplayed = false,
    Future<bool> Function()? applyLocal,
    Future<void> Function()? enqueueLocal,
    Future<void> Function()? recover}) async {
  if (data['snapshot'] == null && data['type'] != 'schedule_snapshot') {
    return false;
  }
  final service = ingestion ?? ScheduleIngestionService();
  try {
    final snapshot =
        ScheduleSnapshot.parse(data['snapshot'], now: service.now());
    final trigger = data['type'] == 'schedule_snapshot'
        ? null
        : ScheduleChangeEvent.fromPush(data, service.now());
    await service.ingest(snapshot,
        fromPush: true, trigger: trigger, alreadyDisplayed: alreadyDisplayed);
  } on FormatException catch (error) {
    AppLogger.w('Snapshot push rejected; scheduling API recovery',
        tag: 'FCM', error: error);
    await (recover ?? enqueueScheduleRefresh)();
    return true;
  } catch (error, stack) {
    AppLogger.e('Cannot persist snapshot push',
        tag: 'FCM', error: error, stackTrace: stack);
    await (recover ?? enqueueScheduleRefresh)();
    return true;
  }
  try {
    if (!await (applyLocal ?? applyPendingSchedules)()) {
      await (enqueueLocal ?? enqueueLocalScheduleWork)();
    }
  } catch (error, stack) {
    AppLogger.e('Received schedules saved; local effects pending',
        tag: 'FCM', error: error, stackTrace: stack);
    await (enqueueLocal ?? enqueueLocalScheduleWork)();
  }
  return true;
}

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) =>
    handleFcmBackgroundMessage(message);

@visibleForTesting
Future<void> handleFcmBackgroundMessage(RemoteMessage message,
    {FcmTestNotificationService? testNotifications,
    ScheduleChangeNotificationService? scheduleChanges,
    Future<void> Function()? refreshSchedules,
    Future<void> Function()? initializeFirebase}) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    if (await (testNotifications ?? FcmTestNotificationService())
        .handleIfTest(message,
            // Older notification payloads are already displayed by the OS.
            notify: message.notification == null)) {
      return;
    }
    if (initializeFirebase != null) {
      await initializeFirebase();
    } else {
      await Firebase.initializeApp();
    }
    if (EmergencyPush.isEmergency(message.data)) {
      await EmergencyNotificationService().handlePush(message.data);
      return;
    }
    if (await handleSnapshotPush(message.data,
        alreadyDisplayed: message.notification != null,
        recover: refreshSchedules)) {
      return;
    }
    AppLogger.i(
      "📩 FCM Бекграунд пуш [${message.messageId}] для групи ${message.data['group'] ?? 'не вказано'}: ${message.notification?.title ?? message.data['title']}",
      tag: 'FCM',
      persistToHistory: true,
    );

    try {
      await (scheduleChanges ?? ScheduleChangeNotificationService()).handlePush(
          message.data,
          alreadyDisplayed: message.notification != null);
    } on FormatException catch (error) {
      AppLogger.w('Ignoring invalid or expired schedule push',
          tag: 'FCM', error: error);
      return;
    } catch (error, stack) {
      AppLogger.e('Cannot process background schedule push',
          tag: 'FCM', error: error, stackTrace: stack);
      // Recover the durable pending delivery and refresh widgets/reminders even
      // when notification display or SQLite access failed.
    }
    await (refreshSchedules ?? enqueueScheduleRefresh)();
  } catch (e, stackTrace) {
    AppLogger.e("Помилка обробки фонового FCM повідомлення",
        tag: 'FCM', error: e, stackTrace: stackTrace);
  }
}

class FcmService {
  static final FcmService _instance = FcmService._internal();
  factory FcmService() => _instance;
  FcmService._internal();

  bool _isInitialized = false;

  static final StreamController<RemoteMessage> _messageStreamController =
      StreamController<RemoteMessage>.broadcast();

  static const String emergencyTopic = "emergency_alerts";
  static const String diagnosticClientTopic = 'lumen_diagnostics_v1';
  static const String scheduleSyncTopic = 'lumen_schedules_v1';

  /// Потік отриманих FCM-повідомлень для реактивного оновлення UI
  static Stream<RemoteMessage> get onMessageStream =>
      _messageStreamController.stream;

  bool get isSupportedPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Конвертує назву групи у валідний FCM-топік (без крапок та спецсимволів)
  /// Наприклад: ("GPV1.1", dayType: 'today') -> "group_gpv1_1"
  /// Наприклад: ("GPV1.1", dayType: 'tomorrow') -> "group_gpv1_1_tomorrow"
  static String groupToTopic(String group,
          {String dayType = 'today', bool versioned = false}) =>
      ScheduleChangeNotificationService.topicFor(group,
          dayType: dayType, versioned: versioned);

  @visibleForTesting
  static Set<String> topicsForPreferences(SharedPreferences prefs) {
    final notificationGroups =
        PreferencesHelper.getActiveNotificationGroups(prefs);
    final topics = <String>{scheduleSyncTopic};
    if (prefs.getBool('notify_schedule_change') ?? true) {
      for (final group in notificationGroups) {
        topics.add(groupToTopic(group, versioned: true));
      }
    }
    if (prefs.getBool('notify_tomorrow_schedule') ?? true) {
      for (final group in notificationGroups) {
        topics.add(groupToTopic(group, dayType: 'tomorrow', versioned: true));
      }
    }
    if (prefs.getBool('notify_emergency_outages') ?? true) {
      topics.add(emergencyTopic);
    }
    if (topics.any((topic) => topic != scheduleSyncTopic)) {
      topics.add(diagnosticClientTopic);
    }
    return topics;
  }

  @visibleForTesting
  Future<void> handleForegroundMessage(RemoteMessage message,
      {FcmTestNotificationService? testNotifications,
      ScheduleChangeNotificationService? scheduleChanges}) async {
    if (await (testNotifications ?? FcmTestNotificationService())
        .handleIfTest(message)) {
      return;
    }
    if (EmergencyPush.isEmergency(message.data)) {
      await EmergencyNotificationService().handlePush(message.data);
      _messageStreamController.add(message);
      return;
    }
    if (await handleSnapshotPush(message.data)) {
      _messageStreamController.add(message);
      return;
    }
    try {
      await (scheduleChanges ?? ScheduleChangeNotificationService())
          .handlePush(message.data);
    } on FormatException catch (error) {
      AppLogger.w('Ignoring invalid or expired foreground schedule push',
          tag: 'FCM', error: error);
      return;
    } catch (error, stack) {
      AppLogger.e('Cannot process foreground schedule push',
          tag: 'FCM', error: error, stackTrace: stack);
      // Network refresh still runs, and the durable pending state can recover.
    }
    _messageStreamController.add(message);
  }

  @visibleForTesting
  Future<void> handleNotificationOpened(RemoteMessage message) async {
    if (FcmTestNotificationService.isTest(message.data)) return;
    if (EmergencyPush.isEmergency(message.data)) {
      await EmergencyNotificationService()
          .handlePush(message.data, notify: false);
    }
    AppLogger.i(
      "📲 Додаток відкрито через клік по пушу: ${message.data}",
      tag: 'FCM',
    );
    _messageStreamController.add(message);
  }

  Future<void> init() async {
    if (!isSupportedPlatform) {
      AppLogger.d("FCM пропущено: платформа не підтримує мобільні пуші",
          tag: 'FCM');
      return;
    }

    if (_isInitialized) return;

    try {
      AppLogger.i("Ініціалізація Firebase та FCM...",
          tag: 'FCM', persistToHistory: true);
      await Firebase.initializeApp();

      FirebaseMessaging.onBackgroundMessage(firebaseMessagingBackgroundHandler);

      final messaging = FirebaseMessaging.instance;

      // Запит дозволів (для Android 13+ та iOS)
      final settings = await messaging.requestPermission(
        alert: true,
        announcement: false,
        badge: true,
        carPlay: false,
        criticalAlert: false,
        provisional: false,
        sound: true,
      );

      AppLogger.i(
        "Статус дозволу сповіщень FCM: ${settings.authorizationStatus}",
        tag: 'FCM',
        persistToHistory: true,
      );

      // Обробка пушів, коли додаток відкритий (Foreground)
      FirebaseMessaging.onMessage.listen(handleForegroundMessage);

      // Обробка відкриття додатку через клік по пушу
      FirebaseMessaging.onMessageOpenedApp.listen(handleNotificationOpened);

      // Обробка холодного старту через клік по пушу
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        await handleNotificationOpened(initialMessage);
      }

      _isInitialized = true;
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setBool('fcm_initialized', true);
      AppLogger.i("✅ FCM успішно ініціалізовано",
          tag: 'FCM', persistToHistory: true);

      // Синхронізуємо підписки на топіки для активних груп з повним підтвердженням
      await syncTopicSubscriptions(forceResubscribe: true);
    } catch (e, stackTrace) {
      try {
        final prefs = await PreferencesHelper.getSafeInstance();
        await prefs.setBool('fcm_initialized', false);
      } catch (_) {}
      AppLogger.e(
        "Помилка ініціалізації FCM",
        tag: 'FCM',
        error: e,
        stackTrace: stackTrace,
      );
    }
  }

  /// Перевірити, чи успішно ініціалізовано FCM на пристрої
  static Future<bool> isFcmInitialized() async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      return prefs.getBool('fcm_initialized') ?? false;
    } catch (_) {
      return false;
    }
  }

  bool _isSyncing = false;
  bool _hasPendingSync = false;
  bool _pendingForceResubscribe = false;

  /// Синхронізує підписки на FCM-топіки відповідно до налаштованих груп та тумблерів сповіщень.
  /// Забезпечує чергу та серіалізацію, щоб уникнути race conditions при швидкому перемиканні налаштувань.
  /// [forceResubscribe] — якщо true, примусово підтверджує підписку на всі цільові топіки (наприклад, при старті);
  /// якщо false, оновлює лише змінені топіки (дельту), заощаджуючи ресурси та трафік.
  Future<void> syncTopicSubscriptions({bool forceResubscribe = false}) async {
    if (!isSupportedPlatform || !_isInitialized) return;

    if (forceResubscribe) {
      _pendingForceResubscribe = true;
    }

    if (_isSyncing) {
      _hasPendingSync = true;
      AppLogger.d("FCM: Синхронізація вже триває, черговий запит відкладено",
          tag: 'FCM');
      return;
    }

    _isSyncing = true;
    try {
      do {
        _hasPendingSync = false;
        final shouldForce = _pendingForceResubscribe;
        _pendingForceResubscribe = false;
        await _executeSyncTopicSubscriptions(forceResubscribe: shouldForce);
      } while (_hasPendingSync);
    } finally {
      _isSyncing = false;
    }
  }

  Future<void> _executeSyncTopicSubscriptions(
      {bool forceResubscribe = false}) async {
    await synchronizeTopics(await PreferencesHelper.getSafeInstance(),
        subscribe: FirebaseMessaging.instance.subscribeToTopic,
        unsubscribe: FirebaseMessaging.instance.unsubscribeFromTopic,
        forceResubscribe: forceResubscribe);
  }

  @visibleForTesting
  static Future<void> synchronizeTopics(SharedPreferences prefs,
      {required Future<void> Function(String) subscribe,
      required Future<void> Function(String) unsubscribe,
      bool forceResubscribe = false}) async {
    try {
      await prefs.reload();
      final currentSubscribed =
          (prefs.getStringList('fcm_subscribed_topics') ?? []).toSet();

      final notificationGroups =
          PreferencesHelper.getActiveNotificationGroups(prefs);

      final targetTopics = topicsForPreferences(prefs);

      AppLogger.d(
        "FCM: Старт синхронізації топіків. Цільові групи (${notificationGroups.length}): ${notificationGroups.join(', ')}. Усього топіків: ${targetTopics.length} (force: $forceResubscribe)",
        tag: 'FCM',
      );

      final activeSubscribed = currentSubscribed.toSet();

      // 1. Відписуємося від груп або топіків, які більше не активні
      final toUnsubscribe = currentSubscribed.difference(targetTopics);
      for (final topic in toUnsubscribe) {
        try {
          await unsubscribe(topic);
          activeSubscribed.remove(topic);
          AppLogger.d("FCM: Відписано від застарілого топіка: $topic",
              tag: 'FCM');
        } catch (e) {
          AppLogger.w("FCM: Не вдалося відписатися від $topic: $e", tag: 'FCM');
        }
      }

      // 2. Підписуємося на цільові топіки:
      // Якщо forceResubscribe == true — підтверджуємо всі топіки для усунення «фантомного кешу».
      // Якщо false — підписуємося лише на дельту нових топіків.
      final topicsToSubscribe = forceResubscribe
          ? targetTopics
          : targetTopics.difference(currentSubscribed);

      for (final topic in topicsToSubscribe) {
        final legacyTopic =
            topic.replaceFirst(RegExp(r'_v2(?=_tomorrow$|$)'), '');
        if (legacyTopic != topic && activeSubscribed.contains(legacyTopic)) {
          // Android auto-displays legacy pushes before Dart can deduplicate.
          AppLogger.w(
              'FCM: Waiting for legacy unsubscribe before subscribing to $topic',
              tag: 'FCM');
          continue;
        }
        try {
          await subscribe(topic);
          activeSubscribed.add(topic);
          AppLogger.d("FCM: Підтверджено підписку на топік: $topic",
              tag: 'FCM');
        } catch (e) {
          AppLogger.w("FCM: Не вдалося підписатися на $topic: $e", tag: 'FCM');
        }
      }

      await prefs.setStringList(
        'fcm_subscribed_topics',
        activeSubscribed.toList(),
      );
      AppLogger.i(
        "✅ FCM: Синхронізацію топіків завершено. Активні топіки (${activeSubscribed.length}): ${activeSubscribed.join(', ')}",
        tag: 'FCM',
        persistToHistory: true,
      );
    } catch (e, stackTrace) {
      AppLogger.e("Помилка синхронізації топіків FCM",
          tag: 'FCM', error: e, stackTrace: stackTrace);
    }
  }
}
