import 'schedule_clock.dart';
import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'app_logger.dart';
import 'notification_service.dart';
import 'parser_service.dart';
import 'preferences_helper.dart';
import 'widget_service.dart';
import 'fcm_event_guard.dart';
import 'dtek_snapshot.dart';
import '../utils/app_formatters.dart';

@pragma('vm:entry-point')
Future<void> firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  try {
    WidgetsFlutterBinding.ensureInitialized();
    await Firebase.initializeApp();
    AppLogger.i(
      "📩 FCM Бекграунд пуш [${message.messageId}] для групи ${message.data['group'] ?? 'не вказано'}: ${message.notification?.title ?? message.data['title']}",
      tag: 'FCM',
      persistToHistory: true,
    );

    final prefs = await PreferencesHelper.getSafeInstance();
    final now = ScheduleClock.now();
    final todayStr = AppFormatters.formatDateKey(now);
    final nowMs = now.millisecondsSinceEpoch;

    // Миттєво фіксуємо час сповіщення для цільової групи пушу,
    // щоб Workmanager не згенерував дублюючий пуш під час фонового парсингу
    final incomingGroup = message.data['group'] as String?;
    final dayType = message.data['dayType'] as String? ?? 'today';
    final targetDate = message.data['targetDate'] as String?;
    final currentTarget = targetDate == null ||
        targetDate.isEmpty ||
        targetDate == DtekSnapshot.notificationDate(dayType, now: now);
    if (currentTarget &&
        incomingGroup != null &&
        ParserService.allGroups.contains(incomingGroup)) {
      await prefs.setInt("last_change_notif_time_$incomingGroup", nowMs);
      await prefs.remove("fcm_pending_hash_${incomingGroup}_today");
      await prefs.remove("fcm_pending_time_${incomingGroup}_today");
      final rawHash = message.data['scheduleHash'] as String?;
      if (rawHash != null && rawHash.isNotEmpty) {
        if (dayType == 'today') {
          await prefs.setString("prev_hash_${incomingGroup}_today", rawHash);
          await prefs.setString("prev_date_${incomingGroup}_today", todayStr);
        } else if (dayType == 'tomorrow') {
          await prefs.setString("prev_hash_${incomingGroup}_tomorrow", rawHash);
          await prefs.setString(
              "prev_date_${incomingGroup}_tomorrow", todayStr);
        }
      }
    }

    // Оновлюємо розклад у фоні та віджет на робочому столі, щоб користувач бачив свіжі дані
    final parser = ParserService();
    final allSchedules = await parser
        .fetchAllSchedules()
        .timeout(const Duration(seconds: 15), onTimeout: () => {});

    if (allSchedules.isNotEmpty) {
      final widgetService = WidgetService();
      await widgetService.updateWidget(allSchedules);

      final notificationService = NotificationService();
      await notificationService.init();

      final List<String> notificationGroups =
          PreferencesHelper.getActiveNotificationGroups(prefs);

      bool first = true;

      for (final group in notificationGroups) {
        final mySchedule = allSchedules[group];
        if (mySchedule != null && !mySchedule.today.isEmpty) {
          await notificationService.scheduleNotificationsForToday(
            mySchedule,
            groupName: group,
            cancelExisting: first,
          );
          first = false;

          // Синхронізуємо хеш, щоб уникнути повторного дублюючого сповіщення від Workmanager
          final keyHash = "prev_hash_${group}_today";
          final keyDate = "prev_date_${group}_today";
          final keyLastNotif = "last_change_notif_time_$group";
          await prefs.setString(keyHash, mySchedule.today.scheduleHash);
          await prefs.setString(keyDate, todayStr);
          await prefs.setInt(keyLastNotif, nowMs);
          await prefs.remove("fcm_pending_hash_${group}_today");
          await prefs.remove("fcm_pending_time_${group}_today");
        }
      }
      AppLogger.i("✅ Фонове оновлення віджета та нагадувань завершено",
          tag: 'FCM');
    }
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

  /// Потік отриманих FCM-повідомлень для реактивного оновлення UI
  static Stream<RemoteMessage> get onMessageStream =>
      _messageStreamController.stream;

  bool get isSupportedPlatform =>
      !kIsWeb && (Platform.isAndroid || Platform.isIOS);

  /// Конвертує назву групи у валідний FCM-топік (без крапок та спецсимволів)
  /// Наприклад: ("GPV1.1", dayType: 'today') -> "group_gpv1_1"
  /// Наприклад: ("GPV1.1", dayType: 'tomorrow') -> "group_gpv1_1_tomorrow"
  static String groupToTopic(String group, {String dayType = 'today'}) {
    final clean = group.replaceAll('.', '_').replaceAll('-', '_').toLowerCase();
    final suffix = dayType == 'tomorrow' ? '_tomorrow' : '';
    return "group_$clean$suffix";
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
      FirebaseMessaging.onMessage.listen((RemoteMessage message) async {
        try {
          final date = message.data['targetDate'] as String?;
          if (date != null &&
              date.isNotEmpty &&
              date !=
                  DtekSnapshot.notificationDate(
                      message.data['dayType'] as String? ?? 'today')) {
            return;
          }
          if (!await FcmEventGuard.claim(message.data['eventId'] as String?)) {
            return;
          }
        } catch (error) {
          AppLogger.w('Cannot check FCM event identity', tag: 'FCM');
          // Identity storage failure must not suppress a valid update.
        }
        AppLogger.i(
          "🔔 FCM повідомлення у передньому плані [${message.messageId}] для групи ${message.data['group'] ?? 'не вказано'}: ${message.notification?.title ?? message.data['title']}",
          tag: 'FCM',
          persistToHistory: true,
        );

        // Перевіряємо, чи користувач увімкнув відповідне сповіщення
        try {
          final prefs = await PreferencesHelper.getSafeInstance();
          final dayType = message.data['dayType'] as String? ?? 'today';
          final notifyAllowed = dayType == 'tomorrow'
              ? (prefs.getBool('notify_tomorrow_schedule') ?? true)
              : (prefs.getBool('notify_schedule_change') ?? true);

          final groupName = message.data['group'] as String?;
          final activeGroups =
              PreferencesHelper.getActiveNotificationGroups(prefs);

          final isGroupTargeted =
              groupName == null || activeGroups.contains(groupName);

          if (notifyAllowed && isGroupTargeted) {
            final notification = message.notification;
            final defaultTitle =
                dayType == 'tomorrow' ? "Графік на завтра" : "Зміна графіку";
            final defaultBody = dayType == 'tomorrow'
                ? "Оновлено розклад на завтра"
                : "Оновлено розклад відключень";

            final title =
                notification?.title ?? message.data['title'] ?? defaultTitle;
            final body =
                notification?.body ?? message.data['body'] ?? defaultBody;

            await NotificationService().showImmediate(
              title,
              body,
              groupName: groupName,
            );
          }
        } catch (e) {
          AppLogger.w("Помилка перевірки налаштувань у foreground FCM: $e",
              tag: 'FCM');
        }

        // Сповіщаємо UI про надходження свіжих даних
        _messageStreamController.add(message);
      });

      // Обробка відкриття додатку через клік по пушу
      FirebaseMessaging.onMessageOpenedApp.listen((RemoteMessage message) {
        AppLogger.i(
          "📲 Додаток відкрито через клік по пушу: ${message.data}",
          tag: 'FCM',
        );
        _messageStreamController.add(message);
      });

      // Обробка холодного старту через клік по пушу
      final initialMessage = await messaging.getInitialMessage();
      if (initialMessage != null) {
        AppLogger.i(
          "📲 Додаток запущено з нуля через клік по пушу: ${initialMessage.data}",
          tag: 'FCM',
        );
        _messageStreamController.add(initialMessage);
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
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final notifyScheduleChange =
          prefs.getBool('notify_schedule_change') ?? true;
      final notifyTomorrowSchedule =
          prefs.getBool('notify_tomorrow_schedule') ?? true;

      final messaging = FirebaseMessaging.instance;
      final currentSubscribed =
          (prefs.getStringList('fcm_subscribed_topics') ?? []).toSet();

      final notificationGroups =
          PreferencesHelper.getActiveNotificationGroups(prefs);

      final targetTopics = <String>{};
      if (notifyScheduleChange) {
        for (final group in notificationGroups) {
          targetTopics.add(groupToTopic(group, dayType: 'today'));
        }
      }
      if (notifyTomorrowSchedule) {
        for (final group in notificationGroups) {
          targetTopics.add(groupToTopic(group, dayType: 'tomorrow'));
        }
      }

      AppLogger.d(
        "FCM: Старт синхронізації топіків. Цільові групи (${notificationGroups.length}): ${notificationGroups.join(', ')}. Усього топіків: ${targetTopics.length} (force: $forceResubscribe)",
        tag: 'FCM',
      );

      final activeSubscribed = currentSubscribed.toSet();

      // 1. Відписуємося від груп або топіків, які більше не активні
      final toUnsubscribe = currentSubscribed.difference(targetTopics);
      for (final topic in toUnsubscribe) {
        try {
          await messaging.unsubscribeFromTopic(topic);
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
        try {
          await messaging.subscribeToTopic(topic);
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
