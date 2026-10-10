import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'parser_service.dart';
import 'preferences_helper.dart';
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
      : _notificationsPlugin = FlutterLocalNotificationsPlugin() {
    AppLogger.d("Конструктор викликано", tag: 'NotificationService');
  }

  NotificationService.forTesting(this._notificationsPlugin);

  /// Базовий ID для миттєвих сповіщень по групах (діапазон 9000000..9000011).
  /// Повністю ізольований від запланованих сповіщень (діапазон 0..1199999).
  static const int immediateGroupNotificationBaseId = 9000000;
  static const int emergencyNotificationId =
      immediateGroupNotificationBaseId + 12;
  static const int testNotificationId = immediateGroupNotificationBaseId + 13;

  final FlutterLocalNotificationsPlugin _notificationsPlugin;

  bool _isInitialized = false;
  Future<void>? _initFuture;
  Future<void>? _permissionFuture;
  String? _windowsIconPath;

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
      try {
        tz.setLocalLocation(tz.getLocation('Europe/Kiev'));
        AppLogger.i("✅ Timezone: Europe/Kiev", tag: 'NotificationService');
      } catch (e) {
        tz.setLocalLocation(tz.local);
        AppLogger.w("⚠️ Timezone: local", tag: 'NotificationService');
      }

      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/launcher_icon');

      const WindowsInitializationSettings windowsSettings =
          WindowsInitializationSettings(
              appName: 'Lumen',
              appUserModelId: 'Maksim0Debug.Lumen.App',
              guid: '27042046-8148-4367-9d7a-757877477430');

      const InitializationSettings settings = InitializationSettings(
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
      } else if (Platform.isWindows) {
        AppLogger.d("Платформа: Windows. Підготовка іконки...",
            tag: 'NotificationService');
        await _prepareWindowsIcon();
      }

      _isInitialized = true;
      AppLogger.i("✅✅✅ ІНІЦІАЛІЗАЦІЯ ЗАВЕРШЕНА", tag: 'NotificationService');
    } catch (e, stackTrace) {
      _initFuture = null;
      AppLogger.e("ПОМИЛКА ІНІЦІАЛІЗАЦІЇ",
          tag: 'NotificationService', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> _prepareWindowsIcon() async {
    try {
      final directory = await getTemporaryDirectory();

      String assetIcon = 'assets/icon.png';

      try {
        final byteData = await rootBundle.load(assetIcon);

        final iconFile =
            File('${directory.path}/windows_notification_icon.png');
        if (!await iconFile.exists()) {
          await iconFile.writeAsBytes(byteData.buffer
              .asUint8List(byteData.offsetInBytes, byteData.lengthInBytes));
        }
        _windowsIconPath = iconFile.path;
        AppLogger.d("Windows icon prepared at: $_windowsIconPath",
            tag: 'NotificationService');
      } catch (e) {
        AppLogger.w("⚠️ Іконка '$assetIcon' не знайдена в асетах. Помилка: $e",
            tag: 'NotificationService');
      }
    } catch (e) {
      AppLogger.e("Помилка підготовки іконки Windows",
          tag: 'NotificationService', error: e);
    }
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

      const WindowsNotificationDetails windowsDetails =
          WindowsNotificationDetails();

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

  Future<void> scheduleNotificationsForToday(FullSchedule fullSchedule,
      {String? groupName,
      bool cancelExisting = true,
      bool rethrowOnError = false}) async {
    if (!Platform.isAndroid && !Platform.isWindows) return;
    if (!_isInitialized) await init(requestPermissions: false);
    if (rethrowOnError && !_isInitialized) {
      throw StateError('Notification service could not initialize');
    }
    (Object, StackTrace)? failure;
    void recordFailure(Object error, StackTrace stack) {
      failure ??= (error, stack);
    }

    SharedPreferences? prefs;
    try {
      prefs = await PreferencesHelper.getSafeInstance();
    } catch (e) {
      AppLogger.w(
          "Error getting SharedPreferences in scheduleNotificationsForToday: $e",
          tag: 'NotificationService');
      if (rethrowOnError) rethrow;
    }

    final bool fallback = prefs == null ? false : true;
    final bool notify1hOff = prefs?.getBool('notify_1h_before_off') ?? fallback;
    final bool notify30mOff =
        prefs?.getBool('notify_30m_before_off') ?? fallback;
    final bool notify5mOff = prefs?.getBool('notify_5m_before_off') ?? fallback;
    final bool notify1hOn = prefs?.getBool('notify_1h_before_on') ?? fallback;
    final bool notify30mOn = prefs?.getBool('notify_30m_before_on') ?? fallback;
    final List<String> notificationGroups = prefs != null
        ? PreferencesHelper.getActiveNotificationGroups(prefs)
        : [];

    AppLogger.d("========== ПЛАНУВАННЯ НА ДЕНЬ ($groupName) ==========",
        tag: 'NotificationService');

    if (cancelExisting) {
      if (Platform.isAndroid) {
        try {
          final List<PendingNotificationRequest> pending =
              await _notificationsPlugin.pendingNotificationRequests();
          AppLogger.d("Знайдено ${pending.length} запланованих. Скасовуємо...",
              tag: 'NotificationService');
          for (var p in pending) {
            await _notificationsPlugin.cancel(p.id);
          }
        } catch (e, stack) {
          recordFailure(e, stack);
          AppLogger.e("Помилка скасування",
              tag: 'NotificationService', error: e);
        }
      } else {
        try {
          await _notificationsPlugin.cancelAll();
        } catch (error, stack) {
          recordFailure(error, stack);
          AppLogger.e('Cannot cancel previous reminders',
              tag: 'NotificationService', error: error);
        }
      }
    }

    final now = tz.TZDateTime.now(tz.local);
    AppLogger.d("Поточний час: $now", tag: 'NotificationService');

    final periods = _calculateOutagePeriods(fullSchedule.today,
        nextDaySchedule: fullSchedule.tomorrow);
    AppLogger.d(
        "Знайдено об'єднаних періодів відключення для $groupName: ${periods.length}",
        tag: 'NotificationService');

    final groupIdx = groupName != null ? _getGroupIndex(groupName) : 0;
    final idPrefix = groupIdx * 100000;

    for (var period in periods) {
      final startHour = period['startHour']!;
      final startMinute = period['startMinute']!;
      final endHour = period['endHour']!;
      final endMinute = period['endMinute']!;

      final startTimeStr =
          "${startHour.toString().padLeft(2, '0')}:${startMinute.toString().padLeft(2, '0')}";

      String endTimeStr;
      if (endHour >= 24) {
        final nextDayHour = endHour - 24;
        endTimeStr =
            "${nextDayHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')} (завтра)";
      } else {
        endTimeStr =
            "${endHour.toString().padLeft(2, '0')}:${endMinute.toString().padLeft(2, '0')}";
      }

      String titlePrefix = "";
      if (groupName != null && notificationGroups.length > 1) {
        titlePrefix = "${groupName.replaceAll("GPV", "Гр. ")}: ";
      }

      if (notify1hOff) {
        var dueTime1h = tz.TZDateTime(
                tz.local, now.year, now.month, now.day, startHour, startMinute)
            .subtract(const Duration(hours: 1));

        if (dueTime1h.isAfter(now)) {
          await _scheduleOne(
            id: idPrefix + startHour * 1000 + startMinute * 10 + 1,
            title: "$titlePrefixСкоро відключення",
            body: "О $startTimeStr світла не буде (до $endTimeStr)",
            time: dueTime1h,
            onError: recordFailure,
          );
        }
      }

      if (notify30mOff) {
        var dueTime30m = tz.TZDateTime(
                tz.local, now.year, now.month, now.day, startHour, startMinute)
            .subtract(const Duration(minutes: 30));

        if (dueTime30m.isAfter(now)) {
          await _scheduleOne(
            id: idPrefix + startHour * 1000 + startMinute * 10 + 4,
            title: "$titlePrefixСкоро відключення",
            body:
                "Через 30 хвилин ($startTimeStr) вимкнуть світло (до $endTimeStr)",
            time: dueTime30m,
            onError: recordFailure,
          );
        }
      }

      if (notify5mOff) {
        var dueTime5m = tz.TZDateTime(
                tz.local, now.year, now.month, now.day, startHour, startMinute)
            .subtract(const Duration(minutes: 5));

        if (dueTime5m.isAfter(now)) {
          await _scheduleOne(
            id: idPrefix + startHour * 1000 + startMinute * 10 + 2,
            title: "$titlePrefixУвага!",
            body: "Відключення через 5 хв ($startTimeStr) до $endTimeStr",
            time: dueTime5m,
            onError: recordFailure,
          );
        }
      }

      var endDateTime =
          tz.TZDateTime(tz.local, now.year, now.month, now.day, 0, 0)
              .add(Duration(hours: endHour, minutes: endMinute));

      String onUntilStr = "";
      for (var p in periods) {
        if (p['startHour']! > endHour ||
            (p['startHour'] == endHour && p['startMinute']! > endMinute)) {
          final nextStartHour = p['startHour']!;
          final nextStartMinute = p['startMinute']!;

          if (nextStartHour >= 24) {
            final h = nextStartHour - 24;
            onUntilStr =
                " (до $h:${nextStartMinute.toString().padLeft(2, '0')} завтра)";
          } else {
            onUntilStr =
                " (до $nextStartHour:${nextStartMinute.toString().padLeft(2, '0')})";
          }
          break;
        }
      }

      if (notify1hOn) {
        try {
          var dueTimeOn1h = endDateTime.subtract(const Duration(hours: 1));
          if (dueTimeOn1h.isAfter(now)) {
            await _scheduleOne(
              id: idPrefix + endHour * 1000 + endMinute * 10 + 3,
              title: "$titlePrefixСкоро ввімкнення",
              body: "О $endTimeStr світло мають увімкнути$onUntilStr",
              time: dueTimeOn1h,
              onError: recordFailure,
            );
          }
        } catch (e, stack) {
          AppLogger.w("⚠️ Помилка планування включення 1h: $e",
              tag: 'NotificationService');
          recordFailure(e, stack);
        }
      }

      if (notify30mOn) {
        try {
          var dueTimeOn30m = endDateTime.subtract(const Duration(minutes: 30));
          if (dueTimeOn30m.isAfter(now)) {
            await _scheduleOne(
              id: idPrefix + endHour * 1000 + endMinute * 10 + 5,
              title: "$titlePrefixСкоро ввімкнення",
              body:
                  "Через 30 хвилин ($endTimeStr) світло мають увімкнути$onUntilStr",
              time: dueTimeOn30m,
              onError: recordFailure,
            );
          }
        } catch (e, stack) {
          AppLogger.w("⚠️ Помилка планування включення 30m: $e",
              tag: 'NotificationService');
          recordFailure(e, stack);
        }
      }
    }

    AppLogger.i("Планування для $groupName завершено",
        tag: 'NotificationService');
    if (rethrowOnError) {
      if (failure case final captured?) {
        Error.throwWithStackTrace(captured.$1, captured.$2);
      }
    }
  }

  /// Отримати числовий індекс групи (0..11) для детермінованих ID сповіщень.
  static int getGroupIndex(String groupName) {
    int idx = ParserService.allGroups.indexOf(groupName);
    return idx >= 0 ? idx : 0;
  }

  int _getGroupIndex(String groupName) => getGroupIndex(groupName);

  List<Map<String, int>> _calculateOutagePeriods(DailySchedule schedule,
      {DailySchedule? nextDaySchedule}) {
    final periods = <Map<String, int>>[];
    bool inOutage = false;
    int startIndex = -1;

    for (int i = 0; i < 48; i++) {
      int hour = i ~/ 2;
      bool isSecondHalf = (i % 2) == 1;
      LightStatus status = schedule.hours[hour];

      bool isStrict = false;
      if (status == LightStatus.off) {
        isStrict = true;
      } else if (status == LightStatus.semiOn && !isSecondHalf) {
        isStrict = true;
      } else if (status == LightStatus.semiOff && isSecondHalf) {
        isStrict = true;
      }

      bool isContinuity = isStrict || (status == LightStatus.maybe);

      if (!inOutage) {
        if (isStrict) {
          inOutage = true;
          startIndex = i;
        }
      } else {
        if (!isContinuity) {
          inOutage = false;
          periods.add({
            'startHour': startIndex ~/ 2,
            'startMinute': (startIndex % 2) * 30,
            'endHour': i ~/ 2,
            'endMinute': (i % 2) * 30,
          });
        }
      }
    }

    if (inOutage) {
      int endSlot = 48;

      if (nextDaySchedule != null) {
        for (int j = 0; j < 48; j++) {
          int hour = j ~/ 2;
          bool isSecondHalf = (j % 2) == 1;
          LightStatus status = nextDaySchedule.hours[hour];

          bool isStrict = false;
          if (status == LightStatus.off) {
            isStrict = true;
          } else if (status == LightStatus.semiOn && !isSecondHalf) {
            isStrict = true;
          } else if (status == LightStatus.semiOff && isSecondHalf) {
            isStrict = true;
          }

          bool isContinuity = isStrict || (status == LightStatus.maybe);

          if (isContinuity) {
            endSlot++;
          } else {
            break;
          }
        }
      }

      periods.add({
        'startHour': startIndex ~/ 2,
        'startMinute': (startIndex % 2) * 30,
        'endHour': endSlot ~/ 2,
        'endMinute': (endSlot % 2) * 30,
      });
    }

    return periods;
  }

  Future<void> _scheduleOne({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime time,
    void Function(Object, StackTrace)? onError,
  }) async {
    try {
      await _notificationsPlugin.zonedSchedule(
        id,
        title,
        body,
        time,
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
          windows: const WindowsNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
      AppLogger.d("✅ Заплановано: ID=$id, time=$time",
          tag: 'NotificationService');
    } catch (e, stack) {
      AppLogger.e("Помилка планування ID=$id",
          tag: 'NotificationService', error: e);
      onError?.call(e, stack);
    }
  }

  Future<void> testNotifications() async {
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
    await showImmediate("Тест", "Миттєве сповіщення працює!");
    AppLogger.d("[1/4] ✅ Миттєве відправлено", tag: 'NotificationService');

    if (Platform.isWindows) {
      AppLogger.d("Windows: тест запланованих...", tag: 'NotificationService');
    }

    if (Platform.isAndroid || Platform.isWindows) {
      AppLogger.d("[2/4] Очистка старих тестових сповіщень...",
          tag: 'NotificationService');

      AppLogger.d("[2/4] ✅ Очищено", tag: 'NotificationService');

      final now = tz.TZDateTime.now(tz.local);
      AppLogger.d("Поточний час: $now", tag: 'NotificationService');

      AppLogger.d("[3/4] Планування: через 10 сек...",
          tag: 'NotificationService');
      final in10sec = now.add(const Duration(seconds: 10));
      await _scheduleTest(99991, "Тест 10 сек", "Минуло 10 секунд!", in10sec);

      AppLogger.d("[3/4] Планування: через 1 мин...",
          tag: 'NotificationService');
      final in1min = now.add(const Duration(minutes: 1));
      await _scheduleTest(99993, "Тест 1 хв", "Минула 1 хвилина!", in1min);

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
    final diffSec = time.difference(tz.TZDateTime.now(tz.local)).inSeconds;
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
          windows: const WindowsNotificationDetails(),
        ),
        androidScheduleMode: AndroidScheduleMode.exactAllowWhileIdle,
      );
      AppLogger.d("  ✅ ID=$id успішно заплановано", tag: 'NotificationService');
    } catch (e, stackTrace) {
      AppLogger.e("ID=$id помилка",
          tag: 'NotificationService', error: e, stackTrace: stackTrace);
    }
  }

  Future<void> cancelAllScheduled() async {
    if (Platform.isAndroid) {
      try {
        final pending =
            await _notificationsPlugin.pendingNotificationRequests();
        for (var p in pending) {
          await _notificationsPlugin.cancel(p.id);
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
