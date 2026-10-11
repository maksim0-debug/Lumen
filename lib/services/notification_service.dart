import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'parser_service.dart';
import 'preferences_helper.dart';
import 'schedule_clock.dart';
import 'schedule_reminder_plan.dart';
import '../utils/app_formatters.dart';

class NotificationService {
  static NotificationService? _instance;

  factory NotificationService() {
    if (_instance == null) {
      AppLogger.d("Створення нового екземпляра...", tag: 'NotificationService');
      _instance = NotificationService._internal();
    }
    return _instance!;
  }

  NotificationService._internal()
      : _notificationsPlugin = FlutterLocalNotificationsPlugin(),
        _now = ScheduleClock.now {
    AppLogger.d("Конструктор викликано", tag: 'NotificationService');
  }

  NotificationService.forTesting(this._notificationsPlugin,
      {tz.TZDateTime Function()? now})
      : _now = now ?? ScheduleClock.now;

  /// Базовий ID для миттєвих сповіщень по групах (діапазон 9000000..9000011).
  /// Повністю ізольований від запланованих сповіщень (діапазон 0..1199999).
  static const int immediateGroupNotificationBaseId = 9000000;
  static const int emergencyNotificationId =
      immediateGroupNotificationBaseId + 12;
  static const int testNotificationId = immediateGroupNotificationBaseId + 13;
  static const int _test10SecondId = 99991;
  static const int _test1MinuteId = 99993;
  static const String _reminderStateKey = 'scheduled_reminder_state_v1';

  final FlutterLocalNotificationsPlugin _notificationsPlugin;
  final tz.TZDateTime Function() _now;
  Future<void> _reminderTail = Future.value();
  bool _reminderStateNeedsWrite = false;

  bool _isInitialized = false;
  Future<void>? _initFuture;
  Future<void>? _permissionFuture;
  String? _windowsIconPath;

  @visibleForTesting
  String? get windowsIconPath => _windowsIconPath;
  @visibleForTesting
  set windowsIconPath(String? path) => _windowsIconPath = path;

  /// Мінімальний запас часу перед запланованою подією (захист від race condition
  /// на Windows, де плагін викидає ArgumentError, якщо scheduledDate <= DateTime.now()).
  static const Duration minSchedulingLeadTime = Duration(seconds: 5);

  bool _canSchedule(tz.TZDateTime scheduledTime, tz.TZDateTime referenceNow) {
    return scheduledTime.difference(referenceNow) >= minSchedulingLeadTime;
  }

  @visibleForTesting
  bool canScheduleForTesting(
          tz.TZDateTime scheduledTime, tz.TZDateTime referenceNow) =>
      _canSchedule(scheduledTime, referenceNow);

  @visibleForTesting
  static void resetForTesting() {
    final current = _instance;
    _instance = null;
    current?._windowsIconPath = null;
    current?._isInitialized = false;
    current?._initFuture = null;
    current?._permissionFuture = null;
  }

  @visibleForTesting
  WindowsNotificationDetails createWindowsDetails() => _createWindowsDetails();

  Future<void> init({bool requestPermissions = true}) async {
    if (!_isInitialized) {
      await (_initFuture ??= _doInit());
    }
    // Headless FCM/Workmanager isolates cannot wait for a Settings activity.
    // Foreground initialization still requests permissions once per instance.
    if (_isInitialized && requestPermissions && Platform.isAndroid) {
      await (_permissionFuture ??= _requestPermissions());
    }
  }

  Future<void> _doInit() async {
    AppLogger.i("========== ІНІЦІАЛІЗАЦІЯ ==========",
        tag: 'NotificationService');

    try {
      AppLogger.d("Ініціалізація timezone...", tag: 'NotificationService');
      tz.initializeTimeZones();
      tz.setLocalLocation(ScheduleClock.location);

      String? windowsIconPath;
      if (Platform.isWindows) {
        AppLogger.d("Платформа: Windows. Підготовка іконки...",
            tag: 'NotificationService');
        windowsIconPath = await _prepareWindowsIcon();
      }

      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/launcher_icon');

      final WindowsInitializationSettings windowsSettings =
          WindowsInitializationSettings(
              appName: 'Lumen',
              appUserModelId: 'Maksim0Debug.Lumen.App',
              guid: '27042046-8148-4367-9d7a-757877477430',
              iconPath: windowsIconPath);

      final InitializationSettings settings = InitializationSettings(
        android: androidSettings,
        windows: windowsSettings,
      );

      AppLogger.d("Виклик initialize()...", tag: 'NotificationService');
      bool? result = await _notificationsPlugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (details) {
          AppLogger.i("Клік по сповіщенню: ${details.payload}",
              tag: 'NotificationService');
        },
      );
      AppLogger.d("initialize() повернув: $result", tag: 'NotificationService');
      if (result != true) {
        throw StateError(
            'Notification plugin initialization was not confirmed');
      }

      if (Platform.isAndroid) {
        AppLogger.d("Платформа: Android. Налаштування каналів...",
            tag: 'NotificationService');
        await _createNotificationChannels();
      }

      _isInitialized = true;
      AppLogger.i("✅✅✅ ІНІЦІАЛІЗАЦІЯ ЗАВЕРШЕНА", tag: 'NotificationService');
    } catch (e, stackTrace) {
      _initFuture = null;
      AppLogger.e("ПОМИЛКА ІНІЦІАЛІЗАЦІЇ",
          tag: 'NotificationService', error: e, stackTrace: stackTrace);
    }
  }

  Future<String?> _prepareWindowsIcon() async {
    _windowsIconPath = null;
    const assetIcon = 'assets/icon.png';
    try {
      final data = await rootBundle.load(assetIcon);
      final bytes =
          data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
      try {
        _windowsIconPath = await _writeWindowsIcon(
            await getApplicationSupportDirectory(), bytes);
      } catch (error) {
        AppLogger.w(
            'Cannot prepare Windows icon in application support; trying temporary storage',
            tag: 'NotificationService',
            error: error);
        _windowsIconPath =
            await _writeWindowsIcon(await getTemporaryDirectory(), bytes);
      }
      return _windowsIconPath;
    } catch (error, stack) {
      AppLogger.w('Cannot prepare Windows notification icon from $assetIcon',
          tag: 'NotificationService', error: error, stackTrace: stack);
      return null;
    }
  }

  Future<String> _writeWindowsIcon(Directory directory, List<int> bytes) async {
    await directory.create(recursive: true);
    final icon = File(p.join(directory.path, 'windows_notification_icon.png'));
    if (await icon.exists()) {
      try {
        if (listEquals(await icon.readAsBytes(), bytes)) return icon.path;
      } catch (error) {
        AppLogger.w('Cannot read existing Windows icon; replacing it',
            tag: 'NotificationService', error: error);
      }
    }
    // Commit a complete file so queued toasts never read a partially written image.
    final staging = File('${icon.path}.$pid.tmp');
    try {
      await staging.writeAsBytes(bytes, flush: true);
      await staging.rename(icon.path);
    } finally {
      if (await staging.exists()) {
        try {
          await staging.delete();
        } catch (error) {
          AppLogger.w('Cannot remove Windows icon staging file',
              tag: 'NotificationService', error: error);
        }
      }
    }
    return icon.path;
  }

  WindowsNotificationDetails _createWindowsDetails() {
    // Keep the app identity icon configured during initialization; reserve the
    // toast body for reminder text instead of repeating the app logo.
    return const WindowsNotificationDetails();
  }

  Future<void> _createNotificationChannels() async {
    final androidImpl =
        _notificationsPlugin.resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin>();

    if (androidImpl != null) {
      const immediateChannel = AndroidNotificationChannel(
        'immediate_channel',
        'Миттєві сповіщення',
        description: 'Канал для миттєвих сповіщень',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );

      const testChannel = AndroidNotificationChannel(
        'test_channel',
        'Тестові сповіщення',
        description: 'Канал для тестових сповіщень',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );

      const scheduleChannel = AndroidNotificationChannel(
        'schedule_channel',
        'Заплановані сповіщення',
        description: 'Сповіщення про відключення світла',
        importance: Importance.max,
        playSound: true,
        enableVibration: true,
      );

      await androidImpl.createNotificationChannel(immediateChannel);
      AppLogger.d("✅ Канал 'immediate_channel' створено",
          tag: 'NotificationService');

      await androidImpl.createNotificationChannel(testChannel);
      AppLogger.d("✅ Канал 'test_channel' створено",
          tag: 'NotificationService');

      await androidImpl.createNotificationChannel(scheduleChannel);
      AppLogger.d("✅ Канал 'schedule_channel' створено",
          tag: 'NotificationService');
    }
  }

  Future<void> _requestPermissions() async {
    try {
      final androidImpl =
          _notificationsPlugin.resolvePlatformSpecificImplementation<
              AndroidFlutterLocalNotificationsPlugin>();

      if (androidImpl != null) {
        try {
          final notifPerm = await androidImpl.requestNotificationsPermission();
          AppLogger.d("Дозвіл на сповіщення (13+): $notifPerm",
              tag: 'NotificationService');
        } catch (e) {
          AppLogger.w(
              "requestNotificationsPermission не підтримується (Android <13): $e",
              tag: 'NotificationService');
        }

        try {
          final alarmPerm = await androidImpl.requestExactAlarmsPermission();
          AppLogger.d("Дозвіл на точні будильники (12+): $alarmPerm",
              tag: 'NotificationService');
        } catch (e) {
          AppLogger.w("requestExactAlarmsPermission помилка: $e",
              tag: 'NotificationService');
        }

        try {
          final canSchedule = await androidImpl.canScheduleExactNotifications();
          AppLogger.d("canScheduleExactNotifications: $canSchedule",
              tag: 'NotificationService');
          if (canSchedule == false) {
            AppLogger.w("⚠️⚠️⚠️ НЕМАЄ ДОЗВОЛУ НА ТОЧНІ СПОВІЩЕННЯ!",
                tag: 'NotificationService');
          }
        } catch (e) {
          AppLogger.w("canScheduleExactNotifications помилка: $e",
              tag: 'NotificationService');
        }
      }
    } catch (e) {
      AppLogger.e("Помилка запиту дозволів",
          tag: 'NotificationService', error: e);
    }
  }

  Future<void> showImmediate(
    String title,
    String body, {
    String? groupName,
    int? notificationId,
    String? notificationTag,
    String? payload,
    bool onlyAlertOnce = false,
    bool rethrowOnError = false,
  }) async {
    AppLogger.d("========== showImmediate ==========",
        tag: 'NotificationService');
    AppLogger.i("title: '$title', body: '$body', group: '$groupName'",
        tag: 'NotificationService');

    if (!_isInitialized) {
      AppLogger.d("Не ініціалізовано, викликаємо init()...",
          tag: 'NotificationService');
      await init(requestPermissions: false);
    }

    if (rethrowOnError && !_isInitialized) {
      throw StateError('Notification service could not initialize');
    }

    try {
      String finalTitle = title;
      if (groupName != null) {
        String formattedGroup = AppFormatters.formatGroupName(groupName);
        if (!title.contains(formattedGroup) && !title.contains(groupName)) {
          finalTitle = "$title ($formattedGroup)";
        }
      }

      AppLogger.d("Створення Platform-specific details...",
          tag: 'NotificationService');

      final AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'immediate_channel',
        'Миттєві сповіщення',
        channelDescription: 'Канал для миттєвих сповіщень',
        importance: Importance.max,
        priority: Priority.high,
        icon: '@mipmap/launcher_icon',
        tag: notificationTag,
        onlyAlertOnce: onlyAlertOnce,
      );

      final WindowsNotificationDetails windowsDetails = _createWindowsDetails();

      final NotificationDetails details = NotificationDetails(
        android: androidDetails,
        windows: windowsDetails,
      );

      final int effectiveNotificationId;
      if (notificationId != null) {
        effectiveNotificationId = notificationId;
      } else if (groupName != null && groupName.isNotEmpty) {
        // Детермінований ID для групи: гарантовано унікальний для кожної групи (9000000..9000011)
        // та повністю ізольований від запланованих сповіщень (0..1199999). Оновлює попереднє сповіщення цієї групи.
        effectiveNotificationId =
            immediateGroupNotificationBaseId + getGroupIndex(groupName);
      } else {
        effectiveNotificationId =
            (DateTime.now().millisecondsSinceEpoch ~/ 1000) & 0x7FFFFFFF;
      }

      AppLogger.d("Виклик show() з ID: $effectiveNotificationId",
          tag: 'NotificationService');

      await _notificationsPlugin.show(
        effectiveNotificationId,
        finalTitle,
        body,
        details,
        payload: payload,
      );

      AppLogger.i("✅ show() успішно виконано", tag: 'NotificationService');
    } catch (e, stackTrace) {
      AppLogger.e("ПОМИЛКА show()",
          tag: 'NotificationService', error: e, stackTrace: stackTrace);
      if (rethrowOnError) rethrow;
    }
  }

  Future<void> _enqueueReminderWork(Future<void> Function() operation) {
    final result = _reminderTail.then((_) => operation());
    // Preserve the caller's error while keeping the next operation runnable.
    _reminderTail =
        result.then<void>((_) {}, onError: (Object error, StackTrace stack) {
      AppLogger.w('Reminder operation failed; subsequent work can retry',
          tag: 'NotificationService', error: error);
    });
    return result;
  }

  Future<void> scheduleNotificationsForToday(FullSchedule fullSchedule,
          {String? groupName,
          bool cancelExisting = true,
          bool rethrowOnError = false}) =>
      _enqueueReminderWork(() => _reconcileReminders(fullSchedule,
          groupName: groupName,
          cancelExisting: cancelExisting,
          rethrowOnError: rethrowOnError));

  Future<void> _reconcileReminders(FullSchedule fullSchedule,
      {String? groupName,
      required bool cancelExisting,
      required bool rethrowOnError}) async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    try {
      if (!_isInitialized) await init(requestPermissions: false);
      if (!_isInitialized) {
        throw StateError('Notification service could not initialize');
      }
      // Never delete working reminders when preferences cannot be loaded.
      final prefs = await PreferencesHelper.getSafeInstance();
      final activeGroups = PreferencesHelper.getActiveNotificationGroups(prefs);
      final index =
          groupName == null ? 0 : ParserService.allGroups.indexOf(groupName);
      if (index < 0) {
        throw ArgumentError.value(groupName, 'groupName', 'Unknown group');
      }
      final now = _now();
      final reminders = ScheduleReminderPlan.build(
        schedule: fullSchedule,
        day: now,
        groupIndex: index,
        titlePrefix: groupName != null && activeGroups.length > 1
            ? '${AppFormatters.formatGroupName(groupName)}: '
            : '',
        preferences: ReminderPreferences(
          off1h: prefs.getBool('notify_1h_before_off') ?? true,
          off30m: prefs.getBool('notify_30m_before_off') ?? true,
          off5m: prefs.getBool('notify_5m_before_off') ?? true,
          on1h: prefs.getBool('notify_1h_before_on') ?? true,
          on30m: prefs.getBool('notify_30m_before_on') ?? true,
        ),
      );
      final desired = {for (final reminder in reminders) reminder.id: reminder};
      // Enumeration failure must not result in blind duplicate Windows schedules.
      final pending = await _notificationsPlugin.pendingNotificationRequests();
      final pendingIds = pending.map((request) => request.id).toSet();
      final state = _readReminderState(prefs);
      final activeIndices =
          activeGroups.map(ParserService.allGroups.indexOf).toSet();
      (Object, StackTrace)? failure;
      void recordFailure(Object error, StackTrace stack) {
        failure ??= (error, stack);
      }

      final blockedIds = <int>{};
      for (final request in pending) {
        // Test reminders and other channels have separate ownership.
        if (!_isScheduleReminderId(request.id)) continue;
        final owner = request.id ~/ 100000;
        final belongsToGroup = owner == index;
        final inactiveGroup = cancelExisting && !activeIndices.contains(owner);
        if (!belongsToGroup && !inactiveGroup) continue;
        final reminder = belongsToGroup ? desired[request.id] : null;
        if (reminder != null &&
            state['${request.id}'] == 'pending:${reminder.identity}') {
          continue;
        }
        try {
          await _notificationsPlugin.cancel(request.id);
          pendingIds.remove(request.id);
          state.remove('${request.id}');
        } catch (error, stack) {
          blockedIds.add(request.id);
          recordFailure(error, stack);
          AppLogger.e('Cannot cancel stale reminder ${request.id}',
              tag: 'NotificationService', error: error);
        }
      }
      // Bound persisted state and remove obsolete/delivered records for this group.
      state.removeWhere((key, value) {
        final id = int.tryParse(key);
        if (id == null || !_isScheduleReminderId(id)) return true;
        if (blockedIds.contains(id)) return false;
        final owner = id ~/ 100000;
        if (cancelExisting && !activeIndices.contains(owner)) return true;
        if (owner != index) return false;
        final reminder = desired[id];
        return reminder == null ||
            (!pendingIds.contains(id) && !reminder.time.isAfter(now));
      });
      for (final reminder in reminders) {
        if (blockedIds.contains(reminder.id)) continue;
        final key = '${reminder.id}';
        final identity = reminder.identity;
        if (pendingIds.contains(reminder.id) &&
            state[key] == 'pending:$identity') {
          continue;
        }
        if (state[key] == 'shown:$identity') continue;
        final currentTime = _now();
        if (!reminder.time.isAfter(now)) continue;
        try {
          // A new/changed imminent reminder is delivered now, never silently lost.
          // Existing identical pending reminders retain their original delivery time.
          if (!_canSchedule(reminder.time, currentTime)) {
            await _showReminder(
                reminder.id, reminder.title, reminder.body, reminder.time);
            state[key] = 'shown:$identity';
          } else {
            final scheduled = await _scheduleOne(
                id: reminder.id,
                title: reminder.title,
                body: reminder.body,
                time: reminder.time);
            state[key] = '${scheduled ? 'pending' : 'shown'}:$identity';
          }
        } catch (error, stack) {
          recordFailure(error, stack);
          AppLogger.e('Cannot apply reminder ${reminder.id}',
              tag: 'NotificationService', error: error);
        }
      }
      try {
        final encodedState = jsonEncode(state);
        if (_reminderStateNeedsWrite ||
            prefs.getString(_reminderStateKey) != encodedState) {
          // SharedPreferences changes its cache even if the platform write fails.
          // Keep the dirty flag until a write succeeds so retries reach storage.
          _reminderStateNeedsWrite = true;
          if (!await prefs.setString(_reminderStateKey, encodedState)) {
            throw StateError('Cannot persist reminder delivery state');
          }
          _reminderStateNeedsWrite = false;
        }
      } catch (error, stack) {
        recordFailure(error, stack);
      }
      if (failure case final captured?) {
        Error.throwWithStackTrace(captured.$1, captured.$2);
      }
    } catch (error, stack) {
      AppLogger.e('Reminder reconciliation failed',
          tag: 'NotificationService', error: error, stackTrace: stack);
      if (rethrowOnError) rethrow;
    }
  }

  Map<String, String> _readReminderState(SharedPreferences prefs) {
    final encoded = prefs.getString(_reminderStateKey);
    if (encoded == null) return {};
    try {
      final decoded = jsonDecode(encoded) as Map<String, dynamic>;
      return decoded.map((key, value) => MapEntry(key, value as String));
    } catch (error) {
      AppLogger.w(
          'Invalid reminder state; reconcile against the system schedule',
          tag: 'NotificationService',
          error: error);
      return {};
    }
  }

  static bool _isScheduleReminderId(int id) {
    if (id < 0 || id >= ParserService.allGroups.length * 100000) return false;
    final localId = id % 100000;
    final kind = localId % 10;
    final minuteComponent = localId % 1000 - kind;
    return localId ~/ 1000 <= 48 &&
        kind >= 1 &&
        kind <= 5 &&
        (minuteComponent == 0 || minuteComponent == 300);
  }

  /// Отримати числовий індекс групи (0..11) для детермінованих ID сповіщень.
  static int getGroupIndex(String groupName) {
    int idx = ParserService.allGroups.indexOf(groupName);
    return idx >= 0 ? idx : 0;
  }

  NotificationDetails _reminderDetails(tz.TZDateTime time) =>
      NotificationDetails(
        android: AndroidNotificationDetails(
          'schedule_channel',
          'Заплановані сповіщення',
          channelDescription: 'Сповіщення про відключення світла',
          importance: Importance.max,
          priority: Priority.high,
          icon: '@mipmap/launcher_icon',
          when: time.millisecondsSinceEpoch,
          showWhen: true,
          usesChronometer: false,
          autoCancel: true,
        ),
        windows: _createWindowsDetails(),
      );

  Future<void> _showReminder(
          int id, String title, String body, tz.TZDateTime time) =>
      _notificationsPlugin.show(id, title, body, _reminderDetails(time));

  Future<bool> _scheduleOne({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime time,
  }) async {
    if (!_canSchedule(time, _now())) {
      await _showReminder(id, title, body, time);
      return false;
    }
    try {
      await _notificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        time,
        _reminderDetails(time),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
      AppLogger.d("✅ Заплановано: ID=$id, time=$time",
          tag: 'NotificationService');
      return true;
    } on ArgumentError {
      if (Platform.isWindows && !time.isAfter(_now())) {
        await _showReminder(id, title, body, time);
        return false;
      }
      rethrow;
    } catch (e, stack) {
      AppLogger.e("Помилка планування ID=$id",
          tag: 'NotificationService', error: e);
      Error.throwWithStackTrace(e, stack);
    }
  }

  Future<void> testNotifications() => _enqueueReminderWork(_testNotifications);

  Future<void> _testNotifications() async {
    AppLogger.d("========================================",
        tag: 'NotificationService');
    AppLogger.d("========== ТЕСТ СПОВІЩЕНЬ ==========",
        tag: 'NotificationService');
    AppLogger.d("========================================",
        tag: 'NotificationService');

    if (!_isInitialized) {
      AppLogger.d("Виклик init()...", tag: 'NotificationService');
      await init();
    }

    AppLogger.d("Статус ініціалізації: $_isInitialized",
        tag: 'NotificationService');

    AppLogger.d("[1/4] Відправка миттєвого сповіщення...",
        tag: 'NotificationService');
    if (!_isInitialized) {
      throw StateError('Notification service could not initialize');
    }
    await showImmediate("Тест", "Миттєве сповіщення працює!",
        notificationId: testNotificationId, rethrowOnError: true);
    AppLogger.d("[1/4] ✅ Миттєве відправлено", tag: 'NotificationService');

    if (Platform.isWindows) {
      AppLogger.d("Windows: тест запланованих...", tag: 'NotificationService');
    }

    if (Platform.isAndroid || Platform.isWindows) {
      AppLogger.d("[2/4] Очистка старих тестових сповіщень...",
          tag: 'NotificationService');
      try {
        await _notificationsPlugin.cancel(_test10SecondId);
        await _notificationsPlugin.cancel(_test1MinuteId);
        AppLogger.d("[2/4] ✅ Очищено", tag: 'NotificationService');
      } catch (e) {
        AppLogger.w("Не вдалося скасувати старі тестові сповіщення: $e",
            tag: 'NotificationService');
        rethrow;
      }

      final now = _now();
      AppLogger.d("Поточний час: $now", tag: 'NotificationService');

      AppLogger.d("[3/4] Планування: через 10 сек...",
          tag: 'NotificationService');
      final in10sec = now.add(const Duration(seconds: 10));
      await _scheduleTest(
          _test10SecondId, "Тест 10 сек", "Минуло 10 секунд!", in10sec);

      AppLogger.d("[3/4] Планування: через 1 хв...",
          tag: 'NotificationService');
      final in1min = _now().add(const Duration(minutes: 1));
      await _scheduleTest(
          _test1MinuteId, "Тест 1 хв", "Минула 1 хвилина!", in1min);

      AppLogger.d("[3/4] ✅ Все заплановано", tag: 'NotificationService');
    }

    AppLogger.d("[4/4] Перевірка списку запланованих...",
        tag: 'NotificationService');
    try {
      final pending = await _notificationsPlugin.pendingNotificationRequests();
      AppLogger.d("[4/4] Заплановано сповіщень: ${pending.length}",
          tag: 'NotificationService');
      for (var p in pending) {
        AppLogger.d("  - ID: ${p.id}, Title: '${p.title}', Body: '${p.body}'",
            tag: 'NotificationService');
      }
    } catch (e) {
      AppLogger.e("[4/4] Помилка отримання списку",
          tag: 'NotificationService', error: e);
    }

    AppLogger.d("========================================",
        tag: 'NotificationService');
    AppLogger.d("========== ТЕСТ ЗАВЕРШЕНО ==========",
        tag: 'NotificationService');
    AppLogger.d("========================================",
        tag: 'NotificationService');
  }

  Future<void> _scheduleTest(
      int id, String title, String body, tz.TZDateTime time) async {
    final diffSec = time.difference(_now()).inSeconds;
    AppLogger.d("  Планування ID=$id на $time (через $diffSec сек)",
        tag: 'NotificationService');

    try {
      await _notificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        time,
        NotificationDetails(
          android: AndroidNotificationDetails(
            'test_channel',
            'Тестові сповіщення',
            channelDescription: 'Канал для тестових сповіщень',
            importance: Importance.max,
            priority: Priority.high,
            icon: '@mipmap/launcher_icon',
            when: time.millisecondsSinceEpoch,
            showWhen: true,
            usesChronometer: false,
            autoCancel: true,
          ),
          windows: _createWindowsDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
      AppLogger.d("  ✅ ID=$id успішно заплановано", tag: 'NotificationService');
    } catch (e, stackTrace) {
      AppLogger.e("ID=$id помилка",
          tag: 'NotificationService', error: e, stackTrace: stackTrace);
      rethrow;
    }
  }

  Future<void> cancelAllScheduled() =>
      _enqueueReminderWork(_cancelAllScheduled);

  Future<void> _cancelAllScheduled() async {
    if (Platform.isAndroid || Platform.isWindows) {
      try {
        final pending =
            await _notificationsPlugin.pendingNotificationRequests();
        for (var request in pending) {
          await _notificationsPlugin.cancel(request.id);
        }
        final prefs = await PreferencesHelper.getSafeInstance();
        if (!await prefs.remove(_reminderStateKey)) {
          throw StateError('Cannot clear reminder delivery state');
        }
      } catch (e) {
        AppLogger.e("Помилка cancelAllScheduled",
            tag: 'NotificationService', error: e);
      }
    } else {
      await _notificationsPlugin.cancelAll();
    }
  }
}
