import 'dart:io';
import 'package:flutter/services.dart'; 
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:path_provider/path_provider.dart'; 
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:shared_preferences/shared_preferences.dart';
import '../models/schedule_status.dart';
import 'parser_service.dart';

class NotificationService {
  static NotificationService? _instance;

  factory NotificationService() {
    if (_instance == null) {
      print("[NotificationService] Створення нового екземпляра...");
      _instance = NotificationService._internal();
    }
    return _instance!;
  }

  NotificationService._internal() {
    print("[NotificationService] Конструктор викликано");
  }

  final FlutterLocalNotificationsPlugin _notificationsPlugin =
      FlutterLocalNotificationsPlugin();

  bool _isInitialized = false;
  String? _windowsIconPath; 

  Future<void> init() async {
    if (_isInitialized) {
      print("[NotificationService] Вже ініціалізовано");
      return;
    }

    print("[NotificationService] ========== ІНІЦІАЛІЗАЦІЯ ==========");

    try {
      
      print("[NotificationService] Ініціалізація timezone...");
      tz.initializeTimeZones();
      try {
        tz.setLocalLocation(tz.getLocation('Europe/Kiev'));
        print("[NotificationService] ✅ Timezone: Europe/Kiev");
      } catch (e) {
        tz.setLocalLocation(tz.local);
        print("[NotificationService] ⚠️ Timezone: local");
      }

      
      
      const AndroidInitializationSettings androidSettings =
          AndroidInitializationSettings('@mipmap/launcher_icon');

      
      
      final WindowsInitializationSettings windowsSettings =
          WindowsInitializationSettings(
              appName: 'Lumen',
              appUserModelId: 'Vikl.Lumen.App',
              guid: '27042046-8148-4367-9d7a-757877477430' 
              );

      final InitializationSettings settings = InitializationSettings(
        android: androidSettings,
        windows: windowsSettings,
      );

      print("[NotificationService] Виклик initialize()...");
      bool? result = await _notificationsPlugin.initialize(
        settings,
        onDidReceiveNotificationResponse: (details) {
          print(
              "[NotificationService] Клік по сповіщенню: ${details.payload}");
        },
      );
      print("[NotificationService] initialize() повернув: $result");

      
      if (Platform.isAndroid) {
        print("[NotificationService] Платформа: Android. Налаштування каналів...");
        await _createNotificationChannels();
        await _requestPermissions();
      } else if (Platform.isWindows) {
        print("[NotificationService] Платформа: Windows. Підготовка іконки...");
        await _prepareWindowsIcon();
      }

      _isInitialized = true;
      print("[NotificationService] ✅✅✅ ІНІЦІАЛІЗАЦІЯ ЗАВЕРШЕНА");
    } catch (e, stackTrace) {
      print("[NotificationService] ❌ ПОМИЛКА ІНІЦІАЛІЗАЦІЇ: $e");
      print("[NotificationService] StackTrace: $stackTrace");
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
        print(
            "[NotificationService] Windows icon prepared at: $_windowsIconPath");
      } catch (e) {
        print(
            "[NotificationService] ⚠️ Іконка '$assetIcon' не знайдена в асетах. Сповіщення будуть без кастомної іконки. Помилка: $e");
      }
    } catch (e) {
      print("[NotificationService] Помилка підготовки іконки Windows: $e");
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
      print("[NotificationService] ✅ Канал 'immediate_channel' створено");

      await androidImpl.createNotificationChannel(testChannel);
      print("[NotificationService] ✅ Канал 'test_channel' створено");

      await androidImpl.createNotificationChannel(scheduleChannel);
      print("[NotificationService] ✅ Канал 'schedule_channel' створено");
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
          print(
              "[NotificationService] Дозвіл на сповіщення (13+): $notifPerm");
        } catch (e) {
          print(
              "[NotificationService] requestNotificationsPermission не підтримується (Android <13): $e");
        }

        
        try {
          final alarmPerm = await androidImpl.requestExactAlarmsPermission();
          print(
              "[NotificationService] Дозвіл на точні будильники (12+): $alarmPerm");
        } catch (e) {
          print(
              "[NotificationService] requestExactAlarmsPermission помилка: $e");
        }

        
        try {
          final canSchedule = await androidImpl.canScheduleExactNotifications();
          print(
              "[NotificationService] canScheduleExactNotifications: $canSchedule");
          if (canSchedule == false) {
            print(
                "[NotificationService] ⚠️⚠️⚠️ НЕМАЄ ДОЗВОЛУ НА ТОЧНІ СПОВІЩЕННЯ!");
          }
        } catch (e) {
          print(
              "[NotificationService] canScheduleExactNotifications помилка: $e");
        }
      }
    } catch (e) {
      print("[NotificationService] Помилка запиту дозволів: $e");
    }
  }

  
  Future<void> showImmediate(String title, String body,
      {String? groupName}) async {
    print("[NotificationService] ========== showImmediate ==========");
    print(
        "[NotificationService] title: '$title', body: '$body', group: '$groupName'");

    if (!_isInitialized) {
      print("[NotificationService] Не ініціалізовано, викликаємо init()...");
      await init();
    }

    try {
      final prefs = await SharedPreferences.getInstance();
      final List<String> notificationGroups =
          prefs.getStringList('notification_groups') ?? [];

      String finalTitle = title;
      if (groupName != null && notificationGroups.length > 1) {
        finalTitle = "$groupName: $title";
      }

      print("[NotificationService] Створення Platform-specific details...");

      
      const AndroidNotificationDetails androidDetails =
          AndroidNotificationDetails(
        'immediate_channel',
        'Миттєві сповіщення',
        channelDescription: 'Канал для миттєвих сповіщень',
        importance: Importance.max,
        priority: Priority.high,
        icon: '@mipmap/launcher_icon',
      );

      
      final WindowsNotificationDetails windowsDetails = WindowsNotificationDetails(
          
          );

      final NotificationDetails details = NotificationDetails(
        android: androidDetails,
        windows: windowsDetails,
      );

      
      final uniqueGroupFactor = (groupName?.hashCode ?? 0) % 1000;
      final timeFactor = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final notificationId = timeFactor + uniqueGroupFactor;

      print("[NotificationService] Виклик show() з ID: $notificationId");

      await _notificationsPlugin.show(
        notificationId,
        finalTitle,
        body,
        details,
      );

      print("[NotificationService] ✅ show() успішно виконано");
    } catch (e, stackTrace) {
      print("[NotificationService] ❌ ПОМИЛКА show(): $e");
      print("[NotificationService] StackTrace: $stackTrace");
    }
  }

  
  Future<void> scheduleNotificationsForToday(FullSchedule fullSchedule,
      {String? groupName, bool cancelExisting = true}) async {
    if (!_isInitialized) await init();

    
    if (!Platform.isAndroid && !Platform.isWindows) return;

    
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final bool notify1hOff = prefs.getBool('notify_1h_before_off') ?? true;
    final bool notify30mOff = prefs.getBool('notify_30m_before_off') ?? true;
    final bool notify5mOff = prefs.getBool('notify_5m_before_off') ?? true;
    final bool notify1hOn = prefs.getBool('notify_1h_before_on') ?? true;
    final bool notify30mOn = prefs.getBool('notify_30m_before_on') ?? true;
    final List<String> notificationGroups =
        prefs.getStringList('notification_groups') ?? [];

    print(
        "[NotificationService] ========== ПЛАНУВАННЯ НА ДЕНЬ ($groupName) ==========");

    if (cancelExisting) {
      if (Platform.isAndroid) {
        try {
          final List<PendingNotificationRequest> pending =
              await _notificationsPlugin.pendingNotificationRequests();
          print(
              "[NotificationService] Знайдено ${pending.length} запланованих. Скасовуємо...");
          for (var p in pending) {
            await _notificationsPlugin.cancel(p.id);
          }
        } catch (e) {
          print("[NotificationService] Помилка скасування: $e");
          await _notificationsPlugin.cancelAll();
        }
      } else {
        
        await _notificationsPlugin.cancelAll();
      }
    }

    final now = tz.TZDateTime.now(tz.local);
    print("[NotificationService] Поточний час: $now");

    
    final periods = _calculateOutagePeriods(fullSchedule.today,
        nextDaySchedule: fullSchedule.tomorrow);
    print(
        "[NotificationService] Знайдено об'єднаних періодів відключення для $groupName: ${periods.length}");

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
            title: "${titlePrefix}Скоро відключення",
            body: "О $startTimeStr світла не буде (до $endTimeStr)",
            time: dueTime1h,
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
            title: "${titlePrefix}Скоро відключення",
            body:
                "Через 30 хвилин ($startTimeStr) вимкнуть світло (до $endTimeStr)",
            time: dueTime30m,
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
            title: "${titlePrefix}Увага!",
            body: "Відключення через 5 хв ($startTimeStr) до $endTimeStr",
            time: dueTime5m,
          );
        }
      }

      

      var endDateTime =
          tz.TZDateTime(tz.local, now.year, now.month, now.day, 0, 0)
              .add(Duration(hours: endHour, minutes: endMinute));
      
      
      
      
      
      String onUntilStr = "";
      for (var p in periods) {
         
         
         
         
         
         
         if (p['startHour']! > endHour || (p['startHour'] == endHour && p['startMinute']! > endMinute)) {
             final nextStartHour = p['startHour']!;
             final nextStartMinute = p['startMinute']!;
             
             if (nextStartHour >= 24) {
                 final h = nextStartHour - 24;
                 onUntilStr = " (до $h:${nextStartMinute.toString().padLeft(2, '0')} завтра)";
             } else {
                 onUntilStr = " (до $nextStartHour:${nextStartMinute.toString().padLeft(2, '0')})";
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
              title: "${titlePrefix}Скоро ввімкнення",
              body: "О $endTimeStr світло мають увімкнути${onUntilStr}",
              time: dueTimeOn1h,
            );
          }
        } catch (e) {
          print(
              "[NotificationService] ⚠️ Помилка планування включення 1h: $e");
        }
      }

      
      if (notify30mOn) {
        try {
          var dueTimeOn30m = endDateTime.subtract(const Duration(minutes: 30));
          if (dueTimeOn30m.isAfter(now)) {
            await _scheduleOne(
              id: idPrefix + endHour * 1000 + endMinute * 10 + 5,
              title: "${titlePrefix}Скоро ввімкнення",
              body: "Через 30 хвилин ($endTimeStr) світло мають увімкнути${onUntilStr}",
              time: dueTimeOn30m,
            );
          }
        } catch (e) {
          print(
              "[NotificationService] ⚠️ Помилка планування включення 30m: $e");
        }
      }
    }

    print("[NotificationService] Планування для $groupName завершено");
  }

  int _getGroupIndex(String groupName) {
    int idx = ParserService.allGroups.indexOf(groupName);
    return idx >= 0 ? idx : 0;
  }

  
  
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
      if (status == LightStatus.off)
        isStrict = true;
      else if (status == LightStatus.semiOn && !isSecondHalf)
        isStrict = true;
      else if (status == LightStatus.semiOff && isSecondHalf) isStrict = true;

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
          if (status == LightStatus.off)
            isStrict = true;
          else if (status == LightStatus.semiOn && !isSecondHalf)
            isStrict = true;
          else if (status == LightStatus.semiOff && isSecondHalf)
            isStrict = true;

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

  
  bool _isOff(LightStatus status) {
    return status == LightStatus.off || status == LightStatus.semiOff;
  }

  bool _isOn(LightStatus status) {
    return status == LightStatus.on || status == LightStatus.semiOn;
  }

  String _statusName(LightStatus status) {
    switch (status) {
      case LightStatus.on:
        return 'ON';
      case LightStatus.off:
        return 'OFF';
      case LightStatus.semiOn:
        return 'SEMI_ON';
      case LightStatus.semiOff:
        return 'SEMI_OFF';
      default:
        return 'UNKNOWN';
    }
  }

  Future<void> _scheduleOne({
    required int id,
    required String title,
    required String body,
    required tz.TZDateTime time,
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
      print("[NotificationService] ✅ Заплановано: ID=$id, time=$time");
    } catch (e) {
      print("[NotificationService] ❌ Помилка планування ID=$id: $e");
    }
  }

  
  Future<void> testNotifications() async {
    print("[NotificationService] ========================================");
    print("[NotificationService] ========== ТЕСТ СПОВІЩЕНЬ ==========");
    print("[NotificationService] ========================================");

    if (!_isInitialized) {
      print("[NotificationService] Виклик init()...");
      await init();
    }

    print("[NotificationService] Статус ініціалізації: $_isInitialized");

    
    print("[NotificationService] [1/4] Відправка миттєвого сповіщення...");
    await showImmediate("Тест", "Миттєве сповіщення працює!");
    print("[NotificationService] [1/4] ✅ Миттєве відправлено");

    if (Platform.isWindows) {
      
      print("[NotificationService] Windows: тест запланованих...");
    }

    
    if (Platform.isAndroid || Platform.isWindows) {
      print("[NotificationService] [2/4] Очистка старих тестових сповіщень...");
      
      
      print("[NotificationService] [2/4] ✅ Очищено");

      final now = tz.TZDateTime.now(tz.local);
      print("[NotificationService] Поточний час: $now");

      
      print("[NotificationService] [3/4] Планування: через 10 сек...");
      final in10sec = now.add(const Duration(seconds: 10));
      await _scheduleTest(99991, "Тест 10 сек", "Минуло 10 секунд!", in10sec);

      
      print("[NotificationService] [3/4] Планування: через 1 мин...");
      final in1min = now.add(const Duration(minutes: 1));
      await _scheduleTest(99993, "Тест 1 хв", "Минула 1 хвилина!", in1min);

      print("[NotificationService] [3/4] ✅ Все заплановано");
    }

    
    print("[NotificationService] [4/4] Перевірка списку запланованих...");
    try {
      final pending = await _notificationsPlugin.pendingNotificationRequests();
      print(
          "[NotificationService] [4/4] Заплановано сповіщень: ${pending.length}");
      for (var p in pending) {
        print(
            "[NotificationService]   - ID: ${p.id}, Title: '${p.title}', Body: '${p.body}'");
      }
    } catch (e) {
      print("[NotificationService] [4/4] ❌ Помилка отримання списку: $e");
    }

    print("[NotificationService] ========================================");
    print("[NotificationService] ========== ТЕСТ ЗАВЕРШЕНО ==========");
    print("[NotificationService] ========================================");
  }

  Future<void> _scheduleTest(
      int id, String title, String body, tz.TZDateTime time) async {
    final diffSec = time.difference(tz.TZDateTime.now(tz.local)).inSeconds;
    print(
        "[NotificationService]   Планування ID=$id на $time (через $diffSec сек)");

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
      print("[NotificationService]   ✅ ID=$id успішно заплановано");
    } catch (e, stackTrace) {
      print("[NotificationService]   ❌ ID=$id помилка: $e");
      print("[NotificationService]   StackTrace: $stackTrace");
    }
  }
}
