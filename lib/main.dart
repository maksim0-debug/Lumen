import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart';

import 'services/background_service.dart';
import 'services/notification_service.dart';
import 'services/parser_service.dart';
import 'services/widget_service.dart';
import 'services/history_service.dart';
import 'services/power_monitor_service.dart';
import 'services/preferences_helper.dart';
import 'models/schedule_status.dart';
import 'models/power_event.dart';
import 'ui/settings_page.dart';

@pragma('vm:entry-point')
Future<void> backgroundCallback(Uri? uri) async {
  if (uri?.host == 'refresh') {
    print("[Background] Refresh triggered from widget");
    final widgetService = WidgetService();
    try {
      final parser = ParserService();
      final allSchedules = await parser.fetchAllSchedules();
      if (allSchedules.isNotEmpty) {
        // History saved in ParserService
        // try {
        //   await HistoryService().saveHistory(allSchedules);
        // } catch (e) {
        //   print("[Background] Error saving history: $e");
        // }
        await widgetService.updateWidget(allSchedules);
      } else {
        await widgetService.clearAllLoadingStates();
      }
    } catch (e) {
      print("[Background] Error refreshing widget: $e");

      await widgetService.clearAllLoadingStates();
    }
  }
}

void main() async {
  print("[MAIN] ========================================");
  print("[MAIN] ВЕРСИЯ ПРИЛОЖЕНИЯ: 2.3.4 (Fix Saving & UI)");
  print("[MAIN] ========================================");
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    HomeWidget.registerBackgroundCallback(backgroundCallback);
  }

  if (Platform.isWindows) {
    try {
      await windowManager.ensureInitialized();
      WindowOptions windowOptions = const WindowOptions(
        size: Size(900, 600),
        center: true,
        skipTaskbar: false,
        title: "Люмен",
      );
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
        await windowManager.setPreventClose(true);
      });
    } catch (e) {
      print("[MAIN] Ошибка Window Manager: $e");
    }

    try {
      PackageInfo packageInfo = await PackageInfo.fromPlatform();

      if (packageInfo.appName != "Lumen") {
        launchAtStartup.setup(
          appName: packageInfo.appName,
          appPath: Platform.resolvedExecutable,
        );
        await launchAtStartup.disable();
      }

      launchAtStartup.setup(
        appName: "Lumen",
        appPath: Platform.resolvedExecutable,
      );
    } catch (e) {
      print("[MAIN] Ошибка автозапуска: $e");
    }
  }

  try {
    final notificationService = NotificationService();
    await notificationService.init();
  } catch (e) {
    print("[MAIN] Ошибка уведомлений: $e");
  }

  if (Platform.isAndroid) {
    try {
      final bgManager = BackgroundManager();
      await bgManager.init();
      bgManager.registerPeriodicTask();
    } catch (e) {
      print("[MAIN] Ошибка Background: $e");
    }
  }

  runApp(const MyApp());
}

class MyApp extends StatefulWidget {
  const MyApp({super.key});

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  bool _isDarkMode = true;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _isDarkMode = prefs.getBool('is_dark_mode') ?? true;
        });
      }
    } catch (e) {
      print("Error loading theme: $e");
    }
  }

  void _toggleTheme() {
    _loadTheme();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Люмен',
      debugShowCheckedModeBanner: false,
      theme: _isDarkMode ? _darkTheme : _lightTheme,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('uk', 'UA'),
      ],
      home: HomeScreen(onThemeChanged: _toggleTheme),
    );
  }

  final ThemeData _darkTheme = ThemeData(
    brightness: Brightness.dark,
    scaffoldBackgroundColor: const Color(0xFF121212),
    colorScheme: ColorScheme.fromSeed(
      seedColor: Colors.orange,
      brightness: Brightness.dark,
      primary: Colors.orange,
      secondary: Colors.grey,
      surface: const Color(0xFF1E1E1E),
    ),
    appBarTheme: const AppBarTheme(
      backgroundColor: Color(0xFF1F1F1F),
      foregroundColor: Colors.orange,
    ),
    useMaterial3: true,
  );

  final ThemeData _lightTheme = ThemeData(
    brightness: Brightness.light,
    colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
    useMaterial3: true,
  );
}

enum SlotStatus { on, off, maybe, unknown }

enum ScheduleViewMode { yesterday, today, tomorrow, history }

/// Режим джерела даних: прогноз (ДТЕК) або реальний (Firebase сенсор).
enum DataSourceMode { predicted, real }

class IntervalInfo {
  final String timeRange;
  final String statusText;
  final String duration;
  final Color color;
  final int? startEventId;
  final int? endEventId;

  IntervalInfo(this.timeRange, this.statusText, this.duration, this.color,
      {this.startEventId, this.endEventId});
}

/// Сегмент всередині однієї години для пропорційної візуалізації.
class HourSegment {
  final double startFraction; // 0.0–1.0 (0 мін – 60 мін)
  final double endFraction; // 0.0–1.0
  final Color color;

  HourSegment(this.startFraction, this.endFraction, this.color);

  double get width => endFraction - startFraction;
}

/// Допоміжний клас для діапазону відключення всередині години.
class _OffRange {
  final double start;
  final double end;
  _OffRange(this.start, this.end);
}

class HomeScreen extends StatefulWidget {
  final VoidCallback? onThemeChanged;

  const HomeScreen({super.key, this.onThemeChanged});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WindowListener, TrayListener {
  final ParserService _parser = ParserService();
  final NotificationService _notifier = NotificationService();
  final WidgetService _widgetService = WidgetService();

  Map<String, FullSchedule> _allSchedules = {};
  String _currentGroup = "GPV2.1";
  List<String> _notificationGroups = [];
  bool _isLoading = true;
  String _statusMessage = "Завантаження...";
  ScheduleViewMode _viewMode = ScheduleViewMode.today;
  DateTime? _historyDate;
  DailySchedule? _historySchedule;
  List<ScheduleVersion> _historyVersions = [];
  int _selectedVersionIndex = -1;

  int _lastNotifiedMinute = -1;
  int _lastAutoRefreshMinute = -1;
  Timer? _timer;

  final Map<String, int> _lastUpdateOldStats = {};
  bool _wasUpdated = false;

  static const bool _showNotificationTestButton = false;

  // --- Power Monitor ---
  final PowerMonitorService _powerMonitor = PowerMonitorService();
  DataSourceMode _dataSourceMode = DataSourceMode.predicted;
  bool _powerMonitorEnabled = false;
  List<PowerOutageInterval> _realOutageIntervals = [];
  String _powerStatus = 'unknown'; // 'online' / 'offline' / 'unknown'

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray();
    }

    _loadPreferencesAndData();
    _initPowerMonitor();

    _timer = Timer.periodic(const Duration(seconds: 2), (timer) {
      final now = DateTime.now();

      if (now.minute % 15 == 0 && now.minute != _lastAutoRefreshMinute) {
        _lastAutoRefreshMinute = now.minute;
        _loadData(silent: true);
      }

      _checkNotificationsManually();

      if (mounted) setState(() {});
    });
  }

  Future<void> _initPowerMonitor() async {
    SharedPreferences? prefs;
    try {
      prefs = await PreferencesHelper.getSafeInstance();
    } catch (e) {
      print("Error loading SharedPreferences in _initPowerMonitor: $e");
    }

    _powerMonitorEnabled = prefs?.getBool('power_monitor_enabled') ?? false;

    _powerMonitor.onStatusChanged = (status) {
      if (mounted) {
        // Also reload the outage data so the list updates immediately
        _loadRealOutageData(_getDisplayDate()).then((_) {
          if (mounted) {
            setState(() {
              _powerStatus = status;
            });
          }
        });
      }
    };

    if (_powerMonitorEnabled) {
      await _powerMonitor.init();
      _powerStatus = _powerMonitor.currentStatus;
      await _loadRealOutageData(DateTime.now());
      if (mounted) setState(() {});
    }
  }

  Future<void> _loadRealOutageData(DateTime date) async {
    if (!_powerMonitorEnabled) return;
    try {
      _realOutageIntervals =
          await _powerMonitor.getOutageIntervalsForDate(date);
    } catch (e) {
      print('[Main] Error loading real outage data: $e');
      _realOutageIntervals = [];
    }
  }

  Future<void> _loadPreferencesAndData() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      print("Error loading SharedPreferences: $e");
      // If SharedPreferences is corrupt, we might want to let the app continue with defaults
      // or show an error. For now, just logging.
    }

    if (prefs != null) {
      final p = prefs!;
      setState(() {
        _currentGroup = p.getString('selected_group') ?? "GPV2.1";
        _notificationGroups = p.getStringList('notification_groups') ?? [];
      });
    }
    _loadData();
  }

  Future<void> _changeGroup(String? newGroup) async {
    if (newGroup == null || newGroup == _currentGroup) return;

    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('selected_group', newGroup);

      List<String> notifGroups =
          prefs.getStringList('notification_groups') ?? [];
      if (notifGroups.isEmpty ||
          (notifGroups.length == 1 && notifGroups.contains(_currentGroup))) {
        await prefs.setStringList('notification_groups', [newGroup]);
        setState(() {
          _notificationGroups = [newGroup];
        });
      }
    } catch (e) {
      print("Error saving group preference: $e");
    }

    setState(() => _currentGroup = newGroup);

    if (_viewMode == ScheduleViewMode.today ||
        _viewMode == ScheduleViewMode.tomorrow) {
      final now = DateTime.now();
      final versions = await HistoryService().getVersionsForDate(now, newGroup);
      setState(() {
        _historyVersions = versions;
        if (_historyVersions.isNotEmpty) {
          _selectedVersionIndex = _historyVersions.length - 1;
          _historySchedule = _historyVersions.last.toSchedule();
        } else {
          _selectedVersionIndex = -1;
          _historySchedule = null;
        }
      });

      try {
        final prefs = await SharedPreferences.getInstance();
        if (_allSchedules.containsKey(newGroup)) {
          final schedule = _allSchedules[newGroup]!;
          final keyHash = "prev_hash_${newGroup}_today";
          final keyDate = "prev_date_${newGroup}_today";
          final todayStr = "${now.year}-${now.month}-${now.day}";

          await prefs.setString(keyHash, schedule.today.scheduleHash);
          await prefs.setString(keyDate, todayStr);
        }
      } catch (e) {
        print("Error syncing hash: $e");
      }
    } else if (_viewMode == ScheduleViewMode.history ||
        _viewMode == ScheduleViewMode.yesterday) {
      if (_historyDate != null) {
        _loadHistoryData(_historyDate!);
      }
    }

    _updateNotificationsOnly();
    _updateStatusDate();
  }

  @override
  void dispose() {
    if (Platform.isWindows) {
      windowManager.removeListener(this);
      trayManager.removeListener(this);
    }
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _initTray() async {
    if (Platform.isWindows) {
      final exePath = Platform.resolvedExecutable;
      final exeDir = exePath.substring(0, exePath.lastIndexOf('\\'));
      final iconPath = '$exeDir\\app_icon.ico';
      await trayManager.setIcon(iconPath);
      Menu menu = Menu(items: [
        MenuItem(key: 'show_window', label: 'Відкрити'),
        MenuItem.separator(),
        MenuItem(key: 'exit_app', label: 'Закрити'),
      ]);
      await trayManager.setContextMenu(menu);
      await trayManager.setToolTip('Люмен');
    }
  }

  @override
  void onTrayIconMouseDown() => windowManager.show();
  @override
  void onTrayIconRightMouseDown() => trayManager.popUpContextMenu();
  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    if (menuItem.key == 'show_window') {
      windowManager.show();
      windowManager.focus();
    } else if (menuItem.key == 'exit_app') windowManager.destroy();
  }

  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) windowManager.hide();
  }

  void _checkNotificationsManually() {
    List<String> groupsToNotify =
        _notificationGroups.isEmpty ? [_currentGroup] : _notificationGroups;

    final now = DateTime.now();
    final hour = now.hour;
    final minute = now.minute;

    if (_lastNotifiedMinute == minute) return;

    for (String group in groupsToNotify) {
      final schedule = _allSchedules[group];
      if (schedule == null) continue;

      final todaySchedule = schedule.today;

      if (minute == 25) {
        if (todaySchedule.hours[hour] == LightStatus.semiOn) {
          _notifier.showImmediate(
              "Скоро світло!", "О $hour:30 мають увімкнути!",
              groupName: group);
        }
      }
    }
    _lastNotifiedMinute = minute;
  }

  Future<void> _updateStatusDate() async {
    DateTime targetDate;
    if (_viewMode == ScheduleViewMode.today) {
      targetDate = DateTime.now();
    } else if (_viewMode == ScheduleViewMode.tomorrow) {
      targetDate = DateTime.now().add(const Duration(days: 1));
    } else {
      return;
    }

    final dateStr =
        "${targetDate.year}-${targetDate.month.toString().padLeft(2, '0')}-${targetDate.day.toString().padLeft(2, '0')}";
    final updateTime = await HistoryService().getLatestUpdatedAt(
      groupKey: _currentGroup,
      targetDate: dateStr,
    );

    if (mounted) {
      String msg = "Оновлено ДТЕК: Невідомо";

      if (_historyVersions.isNotEmpty) {
        // Prefer history version time string which includes date
        msg = "Оновлено ДТЕК: ${_historyVersions.last.timeString}";
      } else if (updateTime != null) {
        msg = "Оновлено ДТЕК: $updateTime";
      } else if (_allSchedules.containsKey(_currentGroup)) {
        msg =
            "Оновлено ДТЕК: ${_allSchedules[_currentGroup]!.lastUpdatedSource}";
      }

      setState(() {
        _statusMessage = msg;
      });
    }
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!silent)
      setState(() {
        _isLoading = true;
        _statusMessage = "Оновлення...";
      });

    try {
      if (_allSchedules.isNotEmpty) {
        for (var entry in _allSchedules.entries) {
          final group = entry.key;
          final schedule = entry.value;
          _lastUpdateOldStats["${group}_today"] =
              _calculateOutageMinutes(schedule.today);
          _lastUpdateOldStats["${group}_tomorrow"] =
              _calculateOutageMinutes(schedule.tomorrow);
        }
      }

      final allData = await _parser.fetchAllSchedules();
      if (allData.isEmpty) throw Exception("Пустий список");

      // await HistoryService().saveHistory(allData);

      final now = DateTime.now();
      final todayVersions =
          await HistoryService().getVersionsForDate(now, _currentGroup);

      setState(() {
        _allSchedules = allData;
        _isLoading = false;
        _wasUpdated = true;

        _historyVersions = todayVersions;
        if (_historyVersions.isNotEmpty) {
          _selectedVersionIndex = _historyVersions.length - 1;
          _historySchedule = _historyVersions.last.toSchedule();
        } else {
          _selectedVersionIndex = -1;
          _historySchedule = null;
        }

        // final updateTime = allData.values.first.lastUpdatedSource;
        // _statusMessage = "Оновлено ДТЕК: $updateTime";
      });
      _updateStatusDate();

      try {
        final prefs = await SharedPreferences.getInstance();
        final notifyChange = prefs.getBool('notify_schedule_change') ?? true;

        final groupsToCheck =
            Set<String>.from([..._notificationGroups, _currentGroup]);

        for (final group in groupsToCheck) {
          if (!allData.containsKey(group)) continue;

          final schedule = allData[group]!;
          final keyHash = "prev_hash_${group}_today";
          final keyDate = "prev_date_${group}_today";
          final todayStr = "${now.year}-${now.month}-${now.day}";

          final oldHash = prefs.getString(keyHash);
          final savedDate = prefs.getString(keyDate);
          final newHash = schedule.today.scheduleHash;

          if (notifyChange &&
              savedDate == todayStr &&
              oldHash != null &&
              oldHash != newHash) {
            final newMinutes = _calculateOutageMinutes(schedule.today);
            int oldMinutes = 0;

            for (int i = 0; i < oldHash.length && i < 24; i++) {
              final char = oldHash[i];
              if (char == '1')
                oldMinutes += 60;
              else if (char == '2' || char == '3') oldMinutes += 30;
            }

            final diff = newMinutes - oldMinutes;
            if (diff != 0) {
              final diffHours = (diff.abs() / 60);
              final diffStr = diffHours == diffHours.toInt()
                  ? diffHours.toInt().toString()
                  : diffHours.toStringAsFixed(1);
              final msg = diff > 0
                  ? "Світла стало МЕНШЕ на $diffStr год. 😔"
                  : "Світла стало БІЛЬШЕ на $diffStr год. 🎉";

              _notifier.showImmediate("Графік змінено ($group)!", msg,
                  groupName: group);
            }
          }

          await prefs.setString(keyHash, newHash);
          await prefs.setString(keyDate, todayStr);
        }
      } catch (e) {
        print("Error syncing hash: $e");
      }

      _updateNotificationsOnly();
      if (Platform.isAndroid) await _widgetService.updateWidget(_allSchedules);
    } catch (e) {
      if (mounted)
        setState(() {
          _isLoading = false;
          _statusMessage = "Помилка оновлення";
        });
      print("Error loading data: $e");
    }
  }

  Future<void> _loadHistoryData(DateTime date) async {
    setState(() {
      _isLoading = true;
      _statusMessage = "Завантаження архіву...";
      _historyVersions = [];
      _selectedVersionIndex = -1;
    });

    try {
      final versions =
          await HistoryService().getVersionsForDate(date, _currentGroup);
      setState(() {
        _historyVersions = versions;
        _isLoading = false;
        final dateStr = "${date.day}.${date.month}.${date.year}";
        if (versions.isEmpty) {
          _historySchedule = null;
          _selectedVersionIndex = -1;
          _statusMessage = "Немає даних за $dateStr";
        } else {
          _selectedVersionIndex = versions.length - 1;
          _historySchedule = versions.last.toSchedule();
          final versionCount = versions.length;
          _statusMessage =
              "Архів за $dateStr ($versionCount ${_pluralVersions(versionCount)})";
        }
      });
    } catch (e) {
      setState(() {
        _isLoading = false;
        _statusMessage = "Помилка завантаження архіву";
      });
    }
  }

  String _pluralVersions(int count) {
    if (count == 1) return "версія";
    if (count >= 2 && count <= 4) return "версії";
    return "версій";
  }

  void _selectVersion(int index) {
    if (index < 0 || index >= _historyVersions.length) return;
    setState(() {
      _selectedVersionIndex = index;
      _historySchedule = _historyVersions[index].toSchedule();
    });
  }

  void _showVersionPicker() {
    if (_historyVersions.isEmpty) return;

    showModalBottomSheet(
      context: context,
      builder: (BuildContext context) {
        final isDark = Theme.of(context).brightness == Brightness.dark;
        return Container(
          color: isDark ? const Color(0xFF1E1E1E) : Colors.white,
          padding: const EdgeInsets.only(top: 16, bottom: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text("Оберіть версію",
                    style:
                        TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  itemCount: _historyVersions.length,
                  separatorBuilder: (context, index) => const Divider(),
                  itemBuilder: (context, index) {
                    final versionIndex = _historyVersions.length - 1 - index;
                    final version = _historyVersions[versionIndex];
                    final isSelected = versionIndex == _selectedVersionIndex;
                    return ListTile(
                      leading: const Icon(Icons.history, color: Colors.orange),
                      title: Text(version.timeString,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text("(${version.outageString})"),
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                      onTap: () {
                        _selectVersion(versionIndex);
                        Navigator.pop(context);
                      },
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _selectDateAndLoad() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate:
          _historyDate ?? DateTime.now().subtract(const Duration(days: 2)),
      firstDate: DateTime(2024),
      lastDate: DateTime.now().subtract(const Duration(days: 0)),
      locale: const Locale("uk", "UA"),
    );
    if (picked != null) {
      setState(() {
        _viewMode = ScheduleViewMode.history;
        _historyDate = picked;
      });
      await _loadHistoryData(picked);
    } else {
      if (_viewMode == ScheduleViewMode.history && _historyDate == null) {
        setState(() => _viewMode = ScheduleViewMode.today);
      }
    }
  }

  int _calculateOutageMinutes(DailySchedule schedule) {
    int totalMinutes = 0;
    for (var status in schedule.hours) {
      if (status == LightStatus.off) {
        totalMinutes += 60;
      } else if (status == LightStatus.semiOn ||
          status == LightStatus.semiOff) {
        totalMinutes += 30;
      }
    }
    return totalMinutes;
  }

  String _getOutageInfoText(DailySchedule? schedule, bool isTomorrow) {
    // Real mode: precise minutes from intervals
    if (_powerMonitorEnabled && _dataSourceMode == DataSourceMode.real) {
      final realMinutes =
          _computeRealOutageMinutes(_realOutageIntervals, _getDisplayDate());
      if (realMinutes == 0 && _realOutageIntervals.isEmpty) return "";
      final percent = (realMinutes / 1440 * 100).round();
      final h = realMinutes ~/ 60;
      final m = realMinutes % 60;
      String timeStr;
      if (h > 0 && m > 0) {
        timeStr = '${h}г ${m}хв';
      } else if (h > 0) {
        timeStr = '${h}г';
      } else {
        timeStr = '${m}хв';
      }
      return "Час без світла: $timeStr ($percent%)";
    }

    if (schedule == null || schedule.isEmpty) return "";

    final currentMinutes = _calculateOutageMinutes(schedule);
    final currentPercent = (currentMinutes / (24 * 60) * 100).round();

    final hours = currentMinutes ~/ 60;
    final minutes = currentMinutes % 60;
    final timeStr = "$hours:${minutes.toString().padLeft(2, '0')}";

    String baseText = "Час без світла: $timeStr ($currentPercent%)";

    if (_wasUpdated) {
      final key = "${_currentGroup}_${isTomorrow ? 'tomorrow' : 'today'}";
      if (_lastUpdateOldStats.containsKey(key)) {
        final oldMinutes = _lastUpdateOldStats[key]!;
        final diffMinutes = currentMinutes - oldMinutes;

        if (diffMinutes != 0) {
          final diffPercent = (diffMinutes / (24 * 60) * 100).round();
          final sign = diffPercent > 0 ? "+" : "";
          return "Графік оновився: $baseText ($sign$diffPercent%)";
        }
      }
    }

    return baseText;
  }

  /// Точний підрахунок хвилин без світла з реальних інтервалів.
  int _computeRealOutageMinutes(
      List<PowerOutageInterval> intervals, DateTime date) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final now = DateTime.now();
    int totalSeconds = 0;

    for (final interval in intervals) {
      final effectiveStart =
          interval.start.isBefore(dayStart) ? dayStart : interval.start;
      DateTime effectiveEnd;
      if (interval.end == null) {
        effectiveEnd = now.isBefore(dayEnd) ? now : dayEnd;
      } else {
        effectiveEnd = interval.end!.isAfter(dayEnd) ? dayEnd : interval.end!;
      }
      if (effectiveEnd.isAfter(effectiveStart)) {
        totalSeconds += effectiveEnd.difference(effectiveStart).inSeconds;
      }
    }
    return (totalSeconds / 60).round();
  }

  void _updateNotificationsOnly() async {
    if (!Platform.isAndroid) return;

    SharedPreferences? prefs;
    try {
      prefs = await PreferencesHelper.getSafeInstance();
    } catch (e) {
      print("Error loading SharedPreferences in _updateNotificationsOnly: $e");
      return;
    }

    List<String> notificationGroups =
        prefs.getStringList('notification_groups') ?? [];

    if (notificationGroups.isEmpty) {
      notificationGroups = [_currentGroup];
    }

    bool first = true;
    for (String group in notificationGroups) {
      final schedule = _allSchedules[group];
      if (schedule != null) {
        await _notifier.scheduleNotificationsForToday(schedule,
            groupName: group, cancelExisting: first);
        first = false;
      }
    }
  }

  List<SlotStatus> _convertScheduleToSlots(DailySchedule schedule) {
    List<SlotStatus> slots = [];
    for (var status in schedule.hours) {
      if (status == LightStatus.on) {
        slots.add(SlotStatus.on);
        slots.add(SlotStatus.on);
      } else if (status == LightStatus.off) {
        slots.add(SlotStatus.off);
        slots.add(SlotStatus.off);
      } else if (status == LightStatus.semiOn) {
        slots.add(SlotStatus.off);
        slots.add(SlotStatus.on);
      } else if (status == LightStatus.semiOff) {
        slots.add(SlotStatus.on);
        slots.add(SlotStatus.off);
      } else if (status == LightStatus.maybe) {
        slots.add(SlotStatus.maybe);
        slots.add(SlotStatus.maybe);
      } else {
        slots.add(SlotStatus.unknown);
        slots.add(SlotStatus.unknown);
      }
    }
    return slots;
  }

  List<IntervalInfo> _generateIntervals(DailySchedule? schedule) {
    if (schedule == null || schedule.isEmpty) return [];
    final slots = _convertScheduleToSlots(schedule);
    List<IntervalInfo> intervals = [];
    int i = 0;
    while (i < slots.length) {
      final currentStatus = slots[i];
      int j = i + 1;
      while (j < slots.length && slots[j] == currentStatus) {
        j++;
      }
      final startTime = _formatTime(i * 30);
      final endTime = _formatTime(j * 30);
      final durationMins = (j - i) * 30;
      final durationStr = _formatDuration(durationMins);
      String statusStr = "";
      Color color = Colors.grey;
      switch (currentStatus) {
        case SlotStatus.on:
          statusStr = "ON";
          color = Colors.green;
          break;
        case SlotStatus.off:
          statusStr = "OFF";
          color = Colors.red;
          break;
        case SlotStatus.maybe:
          statusStr = "MAYBE";
          color = Colors.grey;
          break;
        case SlotStatus.unknown:
          statusStr = "?";
          color = Colors.grey.shade800;
          break;
      }
      intervals.add(
          IntervalInfo("$startTime - $endTime", statusStr, durationStr, color));
      i = j;
    }
    return intervals;
  }

  String _formatTime(int minutesFromStart) {
    int hours = minutesFromStart ~/ 60;
    int minutes = minutesFromStart % 60;
    return "${hours.toString().padLeft(2, '0')}:${minutes.toString().padLeft(2, '0')}";
  }

  String _formatDuration(int totalMinutes) {
    int hours = totalMinutes ~/ 60;
    int minutes = totalMinutes % 60;
    if (hours > 0 && minutes > 0) return "${hours}г ${minutes}хв";
    if (hours > 0) return "${hours}г";
    return "${minutes}хв";
  }

  /// Побудувати DailySchedule з реальних інтервалів відключень (для grid).
  /// Використовується тільки для інтервального списку та нотифікацій (fallback).
  DailySchedule _buildRealScheduleFromIntervals(
      List<PowerOutageInterval> intervals, DateTime date) {
    List<LightStatus> hours = List.filled(24, LightStatus.on);

    for (int h = 0; h < 24; h++) {
      int offMinutes = 0;
      for (final interval in intervals) {
        offMinutes += interval.minutesOfflineInHour(date, h);
      }

      if (offMinutes >= 55) {
        hours[h] = LightStatus.off;
      } else if (offMinutes >= 30) {
        final hourStart = DateTime(date.year, date.month, date.day, h);
        final hourMid = hourStart.add(const Duration(minutes: 30));
        int firstHalfOff = 0;
        int secondHalfOff = 0;
        for (final interval in intervals) {
          final intervalEnd = interval.end ?? DateTime.now();
          final s1 =
              interval.start.isAfter(hourStart) ? interval.start : hourStart;
          final e1 = intervalEnd.isBefore(hourMid) ? intervalEnd : hourMid;
          if (e1.isAfter(s1)) firstHalfOff += e1.difference(s1).inMinutes;
          final hourEnd = hourStart.add(const Duration(hours: 1));
          final s2 = interval.start.isAfter(hourMid) ? interval.start : hourMid;
          final e2 = intervalEnd.isBefore(hourEnd) ? intervalEnd : hourEnd;
          if (e2.isAfter(s2)) secondHalfOff += e2.difference(s2).inMinutes;
        }
        if (firstHalfOff > secondHalfOff) {
          hours[h] = LightStatus.semiOn;
        } else {
          hours[h] = LightStatus.semiOff;
        }
      } else if (offMinutes >= 5) {
        hours[h] = LightStatus.semiOff;
      }
    }
    return DailySchedule(hours);
  }

  // ============================================================
  // REAL MODE: Пропорційна візуалізація годинних ячійок
  // ============================================================

  /// Обчислити сегменти для кожної години на основі реальних інтервалів + прогнозу.
  List<List<HourSegment>> _computeAllHourSegments(
      List<PowerOutageInterval> intervals, DateTime date) {
    final now = DateTime.now();
    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;

    // Отримати прогноз DTEK якщо є
    DailySchedule? forecast;
    if (_allSchedules.containsKey(_currentGroup)) {
      if (isToday) {
        forecast = _allSchedules[_currentGroup]!.today;
      } else {
        // Для завтра
        final tomorrow = DateTime.now().add(const Duration(days: 1));
        if (date.year == tomorrow.year &&
            date.month == tomorrow.month &&
            date.day == tomorrow.day) {
          forecast = _allSchedules[_currentGroup]!.tomorrow;
        }
      }
    }

    final redColor = Colors.red.shade400;
    final greenColor = Colors.green.shade400;
    final greyColor = Colors.grey.shade500;
    final noDataColor = Colors.grey.shade800.withOpacity(0.3);

    List<List<HourSegment>> allSegments = [];

    for (int h = 0; h < 24; h++) {
      final hourStart = DateTime(date.year, date.month, date.day, h);
      final hourEnd = hourStart.add(const Duration(hours: 1));

      // Година в майбутньому
      if (isToday && hourStart.isAfter(now)) {
        // Повністю в майбутньому — використовуємо прогноз або порожньо
        if (_powerStatus == 'offline') {
          // Свет выключен — сірий прогноз
          if (forecast != null && !forecast.isEmpty) {
            final fStatus = forecast.hours[h];
            if (fStatus == LightStatus.on) {
              // Прогноз каже: тут має бути світло (значить повинні увімкнути)
              allSegments.add([HourSegment(0, 1, greenColor.withOpacity(0.3))]);
            } else {
              allSegments.add([HourSegment(0, 1, greyColor.withOpacity(0.4))]);
            }
          } else {
            allSegments.add([HourSegment(0, 1, noDataColor)]);
          }
        } else if (_powerStatus == 'online') {
          // Свет есть — перевіряємо чи прогноз обіцяє відключення
          if (forecast != null && !forecast.isEmpty) {
            final fStatus = forecast.hours[h];
            if (fStatus == LightStatus.off ||
                fStatus == LightStatus.semiOff ||
                fStatus == LightStatus.semiOn) {
              allSegments.add([HourSegment(0, 1, greyColor.withOpacity(0.4))]);
            } else {
              allSegments.add([HourSegment(0, 1, greenColor.withOpacity(0.3))]);
            }
          } else {
            allSegments.add([HourSegment(0, 1, noDataColor)]);
          }
        } else {
          allSegments.add([HourSegment(0, 1, noDataColor)]);
        }
        continue;
      }

      // Визначити кінець факту для поточної години
      double factEndFraction = 1.0; // для минулих годин — повні факти
      if (isToday && now.hour == h) {
        factEndFraction = now.minute / 60.0;
      }

      // Побудувати факт-сегменти (зелені/червоні) від 0 до factEndFraction
      List<HourSegment> segments = [];
      double cursor = 0.0;

      // Знайти перетини інтервалів з цією годиною
      List<_OffRange> offRanges = [];
      for (final interval in intervals) {
        final intervalEnd = interval.end ?? now;
        if (interval.start.isAfter(hourEnd) || intervalEnd.isBefore(hourStart))
          continue;

        final effectiveStart =
            interval.start.isAfter(hourStart) ? interval.start : hourStart;
        final effectiveEnd =
            intervalEnd.isBefore(hourEnd) ? intervalEnd : hourEnd;

        double startFrac =
            effectiveStart.difference(hourStart).inSeconds / 3600.0;
        double endFrac = effectiveEnd.difference(hourStart).inSeconds / 3600.0;
        startFrac = startFrac.clamp(0.0, 1.0);
        endFrac = endFrac.clamp(0.0, 1.0);

        // Обрізати по factEndFraction
        if (startFrac >= factEndFraction) continue;
        if (endFrac > factEndFraction) endFrac = factEndFraction;

        if (endFrac > startFrac + 0.01) {
          offRanges.add(_OffRange(startFrac, endFrac));
        }
      }

      // Побудувати зелені/червоні сегменти
      for (final r in offRanges) {
        if (r.start > cursor + 0.005) {
          segments.add(HourSegment(cursor, r.start, greenColor));
        }
        segments.add(HourSegment(r.start, r.end, redColor));
        cursor = r.end;
      }
      if (cursor < factEndFraction - 0.005) {
        segments.add(HourSegment(cursor, factEndFraction, greenColor));
      }

      // Додати прогноз-хвіст для поточної години (після now)
      if (isToday && now.hour == h && factEndFraction < 0.99) {
        if (_powerStatus == 'offline') {
          // Спочатку перевіряємо прогноз: чи є обіцянка включення в цю годину?
          bool forecastSaysOn = false;
          if (forecast != null && !forecast.isEmpty) {
            final fs = forecast.hours[h];
            if (fs == LightStatus.semiOn) {
              // Прогноз: вимкнено першу половину, увімкнено другу
              forecastSaysOn = factEndFraction >= 0.5;
            } else if (fs == LightStatus.on) {
              forecastSaysOn = true;
            }
          }
          if (forecastSaysOn) {
            segments.add(
                HourSegment(factEndFraction, 1.0, greenColor.withOpacity(0.3)));
          } else {
            segments.add(
                HourSegment(factEndFraction, 1.0, greyColor.withOpacity(0.4)));
          }
        } else if (_powerStatus == 'online') {
          // Свет є — перевіряємо чи прогноз каже що скоро відключать
          bool forecastSaysOff = false;
          if (forecast != null && !forecast.isEmpty) {
            final fs = forecast.hours[h];
            if (fs == LightStatus.semiOff) {
              forecastSaysOff = factEndFraction >= 0.5;
            } else if (fs == LightStatus.off) {
              forecastSaysOff = true;
            }
          }
          if (forecastSaysOff) {
            segments.add(
                HourSegment(factEndFraction, 1.0, greyColor.withOpacity(0.4)));
          } else {
            segments.add(
                HourSegment(factEndFraction, 1.0, greenColor.withOpacity(0.3)));
          }
        } else {
          segments.add(HourSegment(factEndFraction, 1.0, noDataColor));
        }
      }

      // Якщо взагалі нема сегментів (не повинно бути, але на всяк випадок)
      if (segments.isEmpty) {
        segments.add(HourSegment(0, 1, greenColor));
      }

      allSegments.add(segments);
    }
    return allSegments;
  }

  List<IntervalInfo> _generateRealIntervals(
      List<PowerOutageInterval> intervals, DateTime date) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final now = DateTime.now();

    List<IntervalInfo> result = [];
    DateTime cursor = dayStart;

    // Если интервалов нет вообще
    if (intervals.isEmpty) {
      // Проверяем текущий статус сервиса. Если статус неизвестен или Offline,
      // но интервалов нет (значит база пустая), можно показать "?".
      // Но если мы уверены, что синхронизация прошла, и интервалов нет -> значит свет был весь день.

      // ВАЖНО: Если мониторинг выключен или данных нет, не показываем 24ч ON просто так.
      // Но для этого примера предположим ON.
      if (_powerMonitor.isOffline) {
        // Весь день нет света?
        return [IntervalInfo("00:00 - 24:00", "OFF ⏳", "24г", Colors.red)];
      }
      return [IntervalInfo("00:00 - 24:00", "ON", "24г", Colors.green)];
    }

    for (final interval in intervals) {
      // 1. Зеленый интервал (ДО начала отключения)
      // Если начало отключения (interval.start) позже, чем курсор -> значит был свет
      if (interval.start.isAfter(cursor)) {
        final onDiff = interval.start.difference(cursor).inMinutes;
        if (onDiff > 0) {
          result.add(IntervalInfo(
            "${_fmtTime(cursor)} - ${_fmtTime(interval.start)}",
            "ON",
            _formatDuration(onDiff),
            Colors.green,
          ));
        }
      }

      // 2. Красный интервал (Отключение)
      DateTime intervalEnd =
          interval.end ?? (now.isBefore(dayEnd) ? now : dayEnd);

      // Визуальный фикс: если интервал продолжается, но мы смотрим вчерашний день,
      // он должен заканчиваться в 24:00, а не "зараз"
      String endLabel;
      bool isOngoing = interval.isOngoing;

      if (interval.end == null) {
        // Это текущее отключение
        if (date.day != now.day) {
          // Если смотрим историю (вчера), то отключение шло до конца дня
          intervalEnd = dayEnd;
          endLabel = "24:00";
          isOngoing = false;
        } else {
          endLabel = "зараз";
        }
      } else {
        endLabel = _fmtTime(intervalEnd);
      }

      final offDiff = intervalEnd.difference(interval.start).inMinutes;
      result.add(IntervalInfo(
        "${_fmtTime(interval.start)} - $endLabel",
        isOngoing ? "OFF ⏳" : "OFF",
        _formatDuration(offDiff),
        Colors.red,
        startEventId: interval.startEventId,
        endEventId: interval.endEventId,
      ));

      cursor = intervalEnd;
    }

    // 3. Финальный зеленый хвост (после последнего отключения до конца дня)
    if (cursor.isBefore(dayEnd)) {
      // Если последнее событие было "Свет дали" и оно закончилось раньше 24:00
      // ИЛИ если интервалов не было.
      // Важно проверить, не продолжается ли отключение.
      final lastInterval = intervals.last;
      if (lastInterval.end != null) {
        // Отключение закончилось, значит дальше свет есть
        // Но нужно обрезать по "сейчас", если смотрим сегодня
        DateTime tailEnd = dayEnd;
        if (date.year == now.year &&
            date.month == now.month &&
            date.day == now.day) {
          // Если сегодня, то зеленый рисуем "до сейчас" или прогнозом до конца
          // Обычно ON рисуют до 24:00 как прогноз "будет свет"
          tailEnd = dayEnd;
        }

        final tailDiff = tailEnd.difference(cursor).inMinutes;
        if (tailDiff > 0) {
          result.add(IntervalInfo(
            "${_fmtTime(cursor)} - 24:00",
            "ON",
            _formatDuration(tailDiff),
            Colors.green,
          ));
        }
      }
    }

    return result;
  }

  String _fmtTime(DateTime dt) {
    return "${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}";
  }

  /// Віджет індикатора реального часу (220В статус).
  Widget _buildPowerIndicator() {
    if (!_powerMonitorEnabled) return const SizedBox.shrink();

    final isOnline = _powerStatus == 'online';
    final isOffline = _powerStatus == 'offline';

    final Color bgColor;
    final Color textColor;
    final String label;
    final IconData icon;

    if (isOnline) {
      bgColor = Colors.green.withOpacity(0.15);
      textColor = Colors.green;
      label = "ON";
      icon = Icons.power;
    } else if (isOffline) {
      bgColor = Colors.red.withOpacity(0.15);
      textColor = Colors.red;
      label = "OFF";
      icon = Icons.power_off;
    } else {
      bgColor = Colors.grey.withOpacity(0.15);
      textColor = Colors.grey;
      label = "...";
      icon = Icons.pending;
    }

    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: textColor.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: textColor, size: 16),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(
                  color: textColor, fontSize: 12, fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  /// Віджет перемикача "Прогноз / Реальне".
  Widget _buildDataSourceToggle() {
    if (!_powerMonitorEnabled) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ChoiceChip(
            label: const Text('📋 Прогноз'),
            selected: _dataSourceMode == DataSourceMode.predicted,
            selectedColor: Colors.orange.withOpacity(0.3),
            onSelected: (selected) {
              if (selected) {
                setState(() => _dataSourceMode = DataSourceMode.predicted);
              }
            },
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('⚡ Реальне'),
            selected: _dataSourceMode == DataSourceMode.real,
            selectedColor: Colors.amber.withOpacity(0.3),
            onSelected: (selected) {
              if (selected) {
                setState(() => _dataSourceMode = DataSourceMode.real);
                _loadRealOutageData(_getDisplayDate()).then((_) {
                  if (mounted) setState(() {});
                });
              }
            },
          ),
        ],
      ),
    );
  }

  /// Отримати дату, яку зараз переглядає користувач.
  DateTime _getDisplayDate() {
    if (_viewMode == ScheduleViewMode.today) return DateTime.now();
    if (_viewMode == ScheduleViewMode.tomorrow) {
      return DateTime.now().add(const Duration(days: 1));
    }
    if (_viewMode == ScheduleViewMode.yesterday) {
      return DateTime.now().subtract(const Duration(days: 1));
    }
    return _historyDate ?? DateTime.now();
  }

  Widget _buildCountdownWidget(FullSchedule? fullSchedule) {
    if (fullSchedule == null || _viewMode != ScheduleViewMode.today)
      return const SizedBox.shrink();

    final now = DateTime.now();
    final currentMinuteOfDay = now.hour * 60 + now.minute;
    final currentSlotIndex = currentMinuteOfDay ~/ 30;
    if (currentSlotIndex >= 48) return const SizedBox.shrink();

    final todaySlots = _convertScheduleToSlots(fullSchedule.today);

    final tomorrowSlots = _convertScheduleToSlots(fullSchedule.tomorrow);

    final currentStatus = todaySlots[currentSlotIndex];
    int nextChangeIndex = -1;
    bool foundInToday = false;

    for (int i = currentSlotIndex + 1; i < 48; i++) {
      if (todaySlots[i] != currentStatus) {
        nextChangeIndex = i;
        foundInToday = true;
        break;
      }
    }

    if (!foundInToday) {
      for (int i = 0; i < 48; i++) {
        if (tomorrowSlots[i] != currentStatus) {
          nextChangeIndex = i + 48;
          break;
        }
      }
    }

    if (nextChangeIndex == -1) return const SizedBox.shrink();

    final minutesToNextChange = (nextChangeIndex * 30) - currentMinuteOfDay;
    if (minutesToNextChange <= 0) return const SizedBox.shrink();

    final hours = minutesToNextChange ~/ 60;
    final minutes = minutesToNextChange % 60;

    String timeStr = "";
    if (hours > 0) timeStr += "${hours}г ";
    timeStr += "${minutes}хв";

    String msg = "";
    if (currentStatus == SlotStatus.on) {
      msg = "До відключення: $timeStr";
    } else if (currentStatus == SlotStatus.off) {
      msg = "До ввімкнення: $timeStr";
    } else {
      msg = "До зміни статусу: $timeStr";
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final containerColor =
        isDark ? const Color(0xFF2C2C2C) : Colors.grey.shade300;
    final textColor = isDark ? Colors.white : Colors.black87;

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: containerColor,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.timer_outlined, color: Colors.orange, size: 24),
            const SizedBox(width: 8),
            Text(
              msg,
              style: TextStyle(
                  fontSize: 18, fontWeight: FontWeight.bold, color: textColor),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final int cols = screenWidth > 800 ? 8 : (screenWidth > 600 ? 6 : 4);

    DailySchedule? currentDisplay;
    final displayDate = _getDisplayDate();

    if (_viewMode == ScheduleViewMode.today) {
      if (_historyVersions.isNotEmpty &&
          _selectedVersionIndex >= 0 &&
          _historySchedule != null) {
        currentDisplay = _historySchedule;
      } else {
        currentDisplay = _allSchedules[_currentGroup]?.today;
      }
    } else if (_viewMode == ScheduleViewMode.tomorrow) {
      currentDisplay = _allSchedules[_currentGroup]?.tomorrow;
    } else if (_viewMode == ScheduleViewMode.yesterday) {
      currentDisplay = _historySchedule;
    } else if (_viewMode == ScheduleViewMode.history) {
      currentDisplay = _historySchedule;
    }

    // Override with real data if in real mode
    List<IntervalInfo> intervals;
    List<List<HourSegment>>? realHourSegments;
    if (_powerMonitorEnabled && _dataSourceMode == DataSourceMode.real) {
      currentDisplay =
          _buildRealScheduleFromIntervals(_realOutageIntervals, displayDate);
      intervals = _generateRealIntervals(_realOutageIntervals, displayDate);
      realHourSegments =
          _computeAllHourSegments(_realOutageIntervals, displayDate);
    } else {
      intervals = _generateIntervals(currentDisplay);
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return Scaffold(
      appBar: AppBar(
        title: DropdownButton<String>(
          value: _currentGroup,
          dropdownColor: isDark ? const Color(0xFF2C2C2C) : Colors.white,
          icon: Icon(Icons.arrow_drop_down,
              color: isDark ? Colors.orange : Colors.deepPurple),
          underline: Container(),
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: isDark ? Colors.white : Colors.black87),
          onChanged: (newGroup) async {
            await _changeGroup(newGroup);

            if (_viewMode == ScheduleViewMode.yesterday &&
                _historyDate != null) {
              _loadHistoryData(_historyDate!);
            } else if (_viewMode == ScheduleViewMode.history &&
                _historyDate != null) {
              _loadHistoryData(_historyDate!);
            }
          },
          items: ParserService.allGroups.map((String value) {
            return DropdownMenuItem(
                value: value,
                child: Text("Група ${value.replaceFirst('GPV', '')}"));
          }).toList(),
        ),
        centerTitle: true,
        actions: [
          if (_showNotificationTestButton)
            IconButton(
              icon: Icon(Icons.notifications_active,
                  color: isDark ? Colors.orange : Colors.deepPurple),
              tooltip: "Тест сповіщень",
              onPressed: () async {
                await _notifier.testNotifications();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text('Тестові сповіщення відправлено')),
                  );
                }
              },
            ),
          IconButton(
            icon: Icon(Icons.refresh,
                color: isDark ? Colors.white : Colors.black87),
            onPressed: () {
              _loadData();
              if (_powerMonitorEnabled) _powerMonitor.forceRefresh();
            },
          ),
          _buildPowerIndicator(),
          IconButton(
            icon: Icon(Icons.settings,
                color: isDark ? Colors.white : Colors.black87),
            onPressed: () async {
              await Navigator.push(
                context,
                MaterialPageRoute(
                    builder: (context) =>
                        SettingsPage(onThemeChanged: widget.onThemeChanged)),
              );
              _loadPreferencesAndData();
              _initPowerMonitor();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12.0),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: ChoiceChip(
                      label: const Text('Минуле'),
                      selected: _viewMode == ScheduleViewMode.history,
                      onSelected: (bool selected) {
                        _selectDateAndLoad().then((_) {
                          if (_dataSourceMode == DataSourceMode.real) {
                            _loadRealOutageData(_getDisplayDate())
                                .then((_) => setState(() {}));
                          }
                        });
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: ChoiceChip(
                      label: const Text('Вчора'),
                      selected: _viewMode == ScheduleViewMode.yesterday,
                      onSelected: (bool selected) {
                        if (selected) {
                          setState(() {
                            _viewMode = ScheduleViewMode.yesterday;
                            _historyDate = DateTime.now()
                                .subtract(const Duration(days: 1));
                          });
                          _loadHistoryData(_historyDate!);
                          if (_dataSourceMode == DataSourceMode.real) {
                            _loadRealOutageData(_historyDate!)
                                .then((_) => setState(() {}));
                          }
                        }
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: ChoiceChip(
                      label: const Text('Сьогодні'),
                      selected: _viewMode == ScheduleViewMode.today,
                      onSelected: (bool selected) {
                        setState(() {
                          _viewMode = ScheduleViewMode.today;
                        });
                        _updateStatusDate();

                        HistoryService()
                            .getVersionsForDate(DateTime.now(), _currentGroup)
                            .then((versions) {
                          if (mounted) {
                            setState(() {
                              _historyVersions = versions;
                              if (_historyVersions.isNotEmpty) {
                                _selectedVersionIndex =
                                    _historyVersions.length - 1;
                                _historySchedule =
                                    _historyVersions.last.toSchedule();
                              } else {
                                _selectedVersionIndex = -1;
                                _historySchedule = null;
                              }
                            });
                          }
                        });
                        if (_dataSourceMode == DataSourceMode.real) {
                          _loadRealOutageData(DateTime.now())
                              .then((_) => setState(() {}));
                        }
                      },
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 4.0),
                    child: ChoiceChip(
                      label: const Text('Завтра'),
                      selected: _viewMode == ScheduleViewMode.tomorrow,
                      onSelected: (bool selected) {
                        setState(() {
                          _viewMode = ScheduleViewMode.tomorrow;
                        });
                        _updateStatusDate();
                        if (_dataSourceMode == DataSourceMode.real) {
                          _loadRealOutageData(
                                  DateTime.now().add(const Duration(days: 1)))
                              .then((_) => setState(() {}));
                        }
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
          _buildDataSourceToggle(),
          GestureDetector(
            onTap: (_historyVersions.isNotEmpty) ? _showVersionPicker : null,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(_statusMessage,
                    style: const TextStyle(color: Colors.grey, fontSize: 12)),
                if (_historyVersions.length > 0)
                  const Icon(Icons.arrow_drop_down,
                      color: Colors.grey, size: 16),
              ],
            ),
          ),
          if (!_isLoading) ...[
            const SizedBox(height: 8),
            if (_viewMode == ScheduleViewMode.today ||
                _viewMode == ScheduleViewMode.tomorrow)
              _buildCountdownWidget(_allSchedules[_currentGroup]),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 8.0),
              child: Text(
                _getOutageInfoText(
                    currentDisplay, _viewMode == ScheduleViewMode.tomorrow),
                style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 14,
                    color: Theme.of(context).textTheme.bodyLarge?.color ??
                        Colors.black87),
              ),
            ),
          ],
          Expanded(
            child: _isLoading
                ? const Center(
                    child: CircularProgressIndicator(color: Colors.orange))
                : RefreshIndicator(
                    color: Colors.orange,
                    onRefresh: () async {
                      if (_viewMode == ScheduleViewMode.history ||
                          _viewMode == ScheduleViewMode.yesterday) {
                        if (_historyDate != null)
                          await _loadHistoryData(_historyDate!);
                      } else {
                        await _loadData(silent: true);
                      }
                    },
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      children: [
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12.0),
                          child: _buildGrid(currentDisplay, cols,
                              realHourSegments: realHourSegments),
                        ),
                        if (intervals.isNotEmpty)
                          const Padding(
                            padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
                            child: Text("Розклад інтервалами:",
                                style: TextStyle(
                                    fontWeight: FontWeight.bold, fontSize: 16)),
                          ),
                        if (intervals.isNotEmpty)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(12, 0, 12, 40),
                            child: Card(
                              child: Column(
                                children: intervals.map((interval) {
                                  return GestureDetector(
                                    onLongPress: () =>
                                        _showIntervalMenu(context, interval),
                                    child: Container(
                                      decoration: const BoxDecoration(
                                          border: Border(
                                              bottom: BorderSide(
                                                  color: Colors.white10))),
                                      padding: const EdgeInsets.symmetric(
                                          vertical: 12, horizontal: 16),
                                      child: Row(
                                        children: [
                                          SizedBox(
                                              width: 120,
                                              child: Text(interval.timeRange,
                                                  style: TextStyle(
                                                      fontSize: 16,
                                                      fontWeight:
                                                          FontWeight.w500,
                                                      color: interval.statusText
                                                              .contains("OFF")
                                                          ? Colors.red
                                                          : (Theme.of(context)
                                                                      .brightness ==
                                                                  Brightness
                                                                      .dark
                                                              ? Colors.white
                                                              : Colors
                                                                  .black87)))),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                                horizontal: 8, vertical: 2),
                                            decoration: BoxDecoration(
                                                color: interval.color
                                                    .withOpacity(0.2),
                                                borderRadius:
                                                    BorderRadius.circular(4)),
                                            child: Text(interval.statusText,
                                                style: TextStyle(
                                                    color: interval.color,
                                                    fontWeight:
                                                        FontWeight.bold)),
                                          ),
                                          const SizedBox(width: 8),
                                          Text("(${interval.duration})",
                                              style: const TextStyle(
                                                  color: Colors.grey)),
                                        ],
                                      ),
                                    ),
                                  );
                                }).toList(),
                              ),
                            ),
                          )
                      ],
                    ),
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildGrid(DailySchedule? schedule, int columns,
      {List<List<HourSegment>>? realHourSegments}) {
    final bool isRealMode =
        _powerMonitorEnabled && _dataSourceMode == DataSourceMode.real;

    if (!isRealMode && (schedule == null || schedule.isEmpty)) {
      return RefreshIndicator(
        onRefresh: () async {
          await _loadData(silent: true);
        },
        child: const SingleChildScrollView(
          physics: AlwaysScrollableScrollPhysics(),
          child: SizedBox(
            height: 500,
            child: Center(
                child: Padding(
                    padding: EdgeInsets.all(40), child: Text("Дані відсутні"))),
          ),
        ),
      );
    }

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      padding: const EdgeInsets.all(12),
      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: columns,
        childAspectRatio: 1.5,
        crossAxisSpacing: 8,
        mainAxisSpacing: 8,
      ),
      itemCount: 24,
      itemBuilder: (context, index) {
        final bool isCurrentHour =
            _viewMode == ScheduleViewMode.today && DateTime.now().hour == index;

        // Real mode: proportional cell
        if (isRealMode &&
            realHourSegments != null &&
            index < realHourSegments.length) {
          return _buildRealModeCell(
              index, realHourSegments[index], isCurrentHour);
        }

        // Predicted mode: classic LightStatus rendering
        final status = schedule?.hours[index] ?? LightStatus.unknown;
        Widget cellContent;

        final redColor = Colors.red.shade400;
        final greenColor = Colors.green.shade400;

        switch (status) {
          case LightStatus.on:
            cellContent = _colorBox(greenColor, "$index:00");
            break;
          case LightStatus.off:
            cellContent = _colorBox(redColor, "$index:00");
            break;
          case LightStatus.semiOn:
            cellContent = _gradientBox([redColor, greenColor], "$index:00 ⚡");
            break;
          case LightStatus.semiOff:
            cellContent = _gradientBox([greenColor, redColor], "$index:00");
            break;
          case LightStatus.maybe:
            cellContent = _colorBox(Colors.grey.shade400, "$index:00 ?");
            break;
          default:
            cellContent = _colorBox(Colors.grey.shade300, "$index:00");
        }

        if (isCurrentHour) {
          return Stack(children: [
            Container(
                decoration: BoxDecoration(
                    border: Border.all(color: Colors.blue, width: 3),
                    borderRadius: BorderRadius.circular(8)),
                child: cellContent),
            const Positioned(
                top: 4,
                right: 4,
                child: Icon(Icons.circle, size: 8, color: Colors.blue))
          ]);
        }
        return cellContent;
      },
    );
  }

  /// Ячейка Real Mode: пропорційна заливка кольорами.
  Widget _buildRealModeCell(
      int hour, List<HourSegment> segments, bool isCurrentHour) {
    final now = DateTime.now();
    final bool showNowLine = isCurrentHour;
    final double nowFraction = showNowLine ? now.minute / 60.0 : 0;

    // Побудувати мини-таймлайн
    Widget timeline = LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth;
      List<Widget> children = [];

      for (final segment in segments) {
        final w = segment.width * totalWidth;
        if (w < 0.5) continue;
        children.add(Container(
          width: w,
          color: segment.color,
        ));
      }

      return Stack(
        children: [
          Row(children: children),
          // "Now" вертикальна лінія
          if (showNowLine)
            Positioned(
              left: nowFraction * totalWidth - 1,
              top: 0,
              bottom: 0,
              child: Container(
                width: 2,
                color: Colors.white.withOpacity(0.9),
              ),
            ),
          // Мітка часу
          Center(
            child: Text(
              "$hour:00",
              style: TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 13,
                color: Colors.white,
                shadows: [
                  Shadow(
                      blurRadius: 4,
                      color: Colors.black87,
                      offset: const Offset(0, 0)),
                  Shadow(
                      blurRadius: 8,
                      color: Colors.black54,
                      offset: const Offset(0, 0)),
                ],
              ),
            ),
          ),
        ],
      );
    });

    // Обгортка GestureDetector для тултіпа
    Widget cell = GestureDetector(
      onLongPress: () => _showHourDetailTooltip(hour),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(6),
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            color: Colors.grey.shade900,
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: timeline,
          ),
        ),
      ),
    );

    if (isCurrentHour) {
      return Container(
        decoration: BoxDecoration(
          border: Border.all(color: Colors.blue, width: 3),
          borderRadius: BorderRadius.circular(8),
        ),
        child: cell,
      );
    }
    return cell;
  }

  /// Тултіп з деталями по годині.
  void _showHourDetailTooltip(int hour) {
    final date = _getDisplayDate();
    final hourStart = DateTime(date.year, date.month, date.day, hour);
    final hourEnd = hourStart.add(const Duration(hours: 1));
    final now = DateTime.now();

    List<String> lines = [];

    // Collect OFF ranges in this hour
    List<_OffRange> offRanges = [];
    for (final interval in _realOutageIntervals) {
      final intervalEnd = interval.end ?? now;
      if (interval.start.isAfter(hourEnd) || intervalEnd.isBefore(hourStart))
        continue;

      final effectiveStart =
          interval.start.isAfter(hourStart) ? interval.start : hourStart;
      final effectiveEnd =
          intervalEnd.isBefore(hourEnd) ? intervalEnd : hourEnd;
      offRanges.add(_OffRange(
        effectiveStart.difference(hourStart).inMinutes / 60.0,
        effectiveEnd.difference(hourStart).inMinutes / 60.0,
      ));
    }

    double cursorMin = 0;
    for (final r in offRanges) {
      final startMin = (r.start * 60).round();
      final endMin = (r.end * 60).round();
      if (startMin > cursorMin) {
        lines.add(
            "${_fmtHM(hour, cursorMin.round())} - ${_fmtHM(hour, startMin)}: Світло є ✅");
      }
      lines.add(
          "${_fmtHM(hour, startMin)} - ${_fmtHM(hour, endMin)}: Світла немає ❌");
      cursorMin = endMin.toDouble();
    }
    // Tail
    final endOfView =
        (date.day == now.day && hour == now.hour) ? now.minute : 60;
    if (cursorMin < endOfView) {
      lines.add(
          "${_fmtHM(hour, cursorMin.round())} - ${_fmtHM(hour, endOfView)}: Світлоє ✅");
    }

    if (lines.isEmpty) {
      lines.add("Дані відсутні");
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text("$hour:00 — ${hour + 1 > 23 ? 0 : hour + 1}:00"),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: lines
              .map((l) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(l, style: const TextStyle(fontSize: 14)),
                  ))
              .toList(),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text("OK")),
        ],
      ),
    );
  }

  String _fmtHM(int hour, int minute) {
    return "${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}";
  }

  Widget _colorBox(Color color, String text) {
    return Container(
        decoration:
            BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
        child: Center(
            child: Text(text,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Colors.white))));
  }

  Widget _gradientBox(List<Color> colors, String text) {
    return Container(
        decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            gradient: LinearGradient(colors: colors, stops: const [0.5, 0.5])),
        child: Center(
            child: Text(text,
                style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 13,
                    color: Colors.white))));
  }

  void _showIntervalMenu(BuildContext context, IntervalInfo interval) {
    // Allow modification even if ID is missing (try referencing by timestamp)
    // For END event: if it's "ON" (green), the END of this interval is the timestamp of the NEXT event (which is ON).
    // So interval.timeRange "10:00 - 11:00". 11:00 is the ON event.
    // If status is OFF/Red, the start is the OFF event.

    // Actually, IntervalInfo stores `start` and `end` times implicitly in string, but we don't have the raw DateTime here easily
    // without parsing or passing it.
    // Let's rely on IDs primarily, but if ID is missing for an OFF segment, it means we have a phantom start.
    // We can't robustly delete by timestamp without passing DateTime.

    // Better approach: If ID is null, show "Fix/Delete" that deletes by timestamp derived from timeRange?
    // Parsing "HH:mm" is risky if dates differ.

    // However, cleanupPhantomEvents() should fix the null IDs on restart.
    // If user is live, maybe we just advise restart?
    // Or we assume ID null means it's a gap-filler that shouldn't exist as OFF.

    if (interval.startEventId == null && interval.endEventId == null) {
      // Check if it's a real OFF interval (Red)
      if (interval.statusText.contains("OFF")) {
        // This is a phantom OFF.
        // We should allow deleting it.
        // But we need the start time.
        // Let's parse the start time from the string string "HH:mm - HH:mm"
        // This is a hack but effective for this context.
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
              content: Text("Цей інтервал не можна змінити (системний)")),
        );
        return;
      }
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final bgColor = isDark ? const Color(0xFF1E1E1E) : Colors.white;

    // Parse times for fallback deletion
    final times = interval.timeRange.split(' - ');
    DateTime? startTimeFallback;
    if (times.length == 2 && _viewMode == ScheduleViewMode.today) {
      final now = DateTime.now();
      final startParts = times[0].split(':');

      if (startParts.length == 2) {
        startTimeFallback = DateTime(now.year, now.month, now.day,
            int.parse(startParts[0]), int.parse(startParts[1]));
      }
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: bgColor,
      builder: (BuildContext context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (interval.startEventId != null)
                ListTile(
                  leading: const Icon(Icons.edit, color: Colors.blue),
                  title: const Text('Змінити час початку'),
                  onTap: () {
                    Navigator.pop(context);
                    _editEventTime(interval.startEventId!);
                  },
                ),
              if (interval.endEventId != null)
                ListTile(
                  leading: const Icon(Icons.edit_calendar, color: Colors.blue),
                  title: const Text('Змінити час завершення'),
                  onTap: () {
                    Navigator.pop(context);
                    _editEventTime(interval.endEventId!);
                  },
                ),
              if (interval.startEventId != null ||
                  (interval.startEventId == null &&
                      startTimeFallback != null &&
                      interval.statusText.contains("OFF")))
                ListTile(
                  leading: const Icon(Icons.delete, color: Colors.red),
                  title: Text(interval.startEventId == null
                      ? 'Видалити (FORCE)'
                      : 'Видалити подію початку'),
                  subtitle: interval.startEventId == null
                      ? const Text("Видалити за часом (без ID)")
                      : null,
                  onTap: () {
                    Navigator.pop(context);
                    if (interval.startEventId != null) {
                      _deleteEvent(interval.startEventId!);
                    } else if (startTimeFallback != null) {
                      _deleteEventByTime(startTimeFallback);
                    }
                  },
                ),
              if (interval.endEventId != null)
                ListTile(
                  leading: const Icon(Icons.delete_forever, color: Colors.red),
                  title: const Text('Видалити подію завершення'),
                  onTap: () {
                    Navigator.pop(context);
                    _deleteEvent(interval.endEventId!);
                  },
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _deleteEventByTime(DateTime ts) async {
    await _powerMonitor.deleteEventByTimestamp(ts);
    await _loadRealOutageData(_getDisplayDate());
    setState(() {});
  }

  Future<void> _deleteEvent(int id) async {
    await _powerMonitor.deleteEvent(id);
    await _loadRealOutageData(_getDisplayDate());
    setState(() {});
  }

  Future<void> _editEventTime(int id) async {
    final event = await _powerMonitor.getEvent(id);
    if (event == null) return;

    final TimeOfDay? picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(event.timestamp),
      builder: (BuildContext context, Widget? child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(alwaysUse24HourFormat: true),
          child: child!,
        );
      },
    );

    if (picked != null) {
      final newDateTime = DateTime(
        event.timestamp.year,
        event.timestamp.month,
        event.timestamp.day,
        picked.hour,
        picked.minute,
      );
      await _powerMonitor.updateEventTimestamp(id, newDateTime);
      await _loadRealOutageData(_getDisplayDate());
      setState(() {});
    }
  }
}
