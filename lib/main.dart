import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:ui';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart';

import 'services/app_logger.dart';
import 'services/background_service.dart';
import 'services/notification_service.dart';
import 'services/parser_service.dart';
import 'services/widget_service.dart';
import 'services/history_service.dart';
import 'services/power_monitor_service.dart';
import 'services/preferences_helper.dart';
import 'services/achievement_service.dart';
import 'services/darkness_theme_service.dart';
import 'models/schedule_status.dart';
import 'models/power_event.dart';
import 'ui/settings_page.dart';
import 'ui/analytics_screen.dart';
import 'ui/achievements_screen.dart';
import 'ui/widgets/theme_animated_cell.dart';

@pragma('vm:entry-point')
Future<void> backgroundCallback(Uri? uri) async {
  if (uri?.host == 'refresh') {
    AppLogger.d("Refresh triggered from widget", tag: 'Background');
    // Трекер для ачівки "Завжди перед очима"
    try {
      AchievementService().trackWidgetOpen();
    } catch (_) {}
    final widgetService = WidgetService();
    try {
      final parser = ParserService();
      final allSchedules = await parser.fetchAllSchedules();
      if (allSchedules.isNotEmpty) {
        await widgetService.updateWidget(allSchedules);
      } else {
        await widgetService.clearAllLoadingStates();
      }
    } catch (e) {
      AppLogger.e("Error refreshing widget", tag: 'Background', error: e);

      await widgetService.clearAllLoadingStates();
    }
  }
}

void main() async {
  AppLogger.i("========================================", tag: 'MAIN');
  AppLogger.i("ВЕРСИЯ ПРИЛОЖЕНИЯ: 2.3.4 (Fix Saving & UI)", tag: 'MAIN');
  AppLogger.i("========================================", tag: 'MAIN');
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid) {
    HomeWidget.registerInteractivityCallback(backgroundCallback);
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
      AppLogger.e("Помилка Window Manager", tag: 'MAIN', error: e);
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
      AppLogger.e("Помилка автозапуску", tag: 'MAIN', error: e);
    }
  }

  try {
    final notificationService = NotificationService();
    await notificationService.init();
  } catch (e) {
    AppLogger.e("Помилка сповіщень", tag: 'MAIN', error: e);
  }

  if (Platform.isAndroid) {
    try {
      final bgManager = BackgroundManager();
      await bgManager.init();
      bgManager.registerPeriodicTask();
    } catch (e) {
      AppLogger.e("Помилка Background", tag: 'MAIN', error: e);
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
  bool _autoDarknessTheme = false;
  double _uiScale = 1.0;
  final DarknessThemeService _darknessThemeService = DarknessThemeService();
  DarknessStage _currentDarknessStage = DarknessStage.solarpunk;

  @override
  void initState() {
    super.initState();
    _loadTheme();
    _initDarknessTheme();
  }

  Future<void> _initDarknessTheme() async {
    _darknessThemeService.onStageChanged = (stage) {
      if (mounted) {
        setState(() {
          _currentDarknessStage = stage;
        });
      }
    };
    await _darknessThemeService.init();
    if (mounted) {
      setState(() {
        _autoDarknessTheme = _darknessThemeService.isEnabled;
        _currentDarknessStage = _darknessThemeService.currentStage;
      });
    }
  }

  Future<void> _loadTheme() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _isDarkMode = prefs.getBool('is_dark_mode') ?? true;
          _uiScale = prefs.getDouble('ui_scale') ?? 1.0;
          _autoDarknessTheme = _darknessThemeService.isEnabled;
          _currentDarknessStage = _darknessThemeService.currentStage;
        });
      }
    } catch (e) {
      AppLogger.e("Error loading theme", tag: 'Main', error: e);
    }
  }

  void _toggleTheme() {
    _loadTheme();
    // Також оновити стадію тьми
    _darknessThemeService.refresh();
    if (mounted) {
      setState(() {
        _autoDarknessTheme = _darknessThemeService.isEnabled;
        _currentDarknessStage = _darknessThemeService.currentStage;
      });
    }
  }

  void _reloadScale() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (mounted) {
        setState(() {
          _uiScale = prefs.getDouble('ui_scale') ?? 1.0;
        });
      }
    } catch (e) {
      AppLogger.e("Error reloading scale", tag: 'Main', error: e);
    }
  }

  ThemeData get _activeTheme {
    if (_autoDarknessTheme) {
      return _darknessThemeService.getThemeForStage(_currentDarknessStage);
    }
    return _isDarkMode ? _darkTheme : _lightTheme;
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Люмен',
      debugShowCheckedModeBanner: false,
      theme: _activeTheme,
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      supportedLocales: const [
        Locale('uk', 'UA'),
      ],
      builder: (context, child) {
        return MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(_uiScale),
          ),
          child: child!,
        );
      },
      home: HomeScreen(
        onThemeChanged: _toggleTheme,
        onScaleChanged: _reloadScale,
      ),
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
  final bool isFuture;

  HourSegment(this.startFraction, this.endFraction, this.color,
      {this.isFuture = false});

  double get width => endFraction - startFraction;
  double get start => startFraction;
  double get end => endFraction;
}

/// Допоміжний клас для діапазону відключення всередині години.
class _OffRange {
  final double start;
  final double end;
  _OffRange(this.start, this.end);
}

class HomeScreen extends StatefulWidget {
  final VoidCallback? onThemeChanged;
  final VoidCallback? onScaleChanged;

  const HomeScreen({super.key, this.onThemeChanged, this.onScaleChanged});

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

  int _lastAutoRefreshMinute = -1;
  Timer? _timer;

  final Map<String, int> _lastUpdateOldStats = {};
  bool _wasUpdated = false;

  bool _isCachedData = false;
  Color _statusColor = Colors.grey;

  static const bool _showNotificationTestButton = false;

  // --- Power Monitor ---
  final PowerMonitorService _powerMonitor = PowerMonitorService();
  DataSourceMode _dataSourceMode = DataSourceMode.predicted;
  bool _powerMonitorEnabled = false;
  List<PowerOutageInterval> _realOutageIntervals = [];
  String _powerStatus = 'unknown'; // 'online' / 'offline' / 'unknown'
  List<List<HourSegment>>? _realHourSegments;

  final AchievementService _achievementService = AchievementService();
  final FocusNode _focusNode = FocusNode();

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
    _initAchievements();

    _timer = Timer.periodic(const Duration(seconds: 2), (timer) {
      final now = DateTime.now();

      if (now.minute % 15 == 0 && now.minute != _lastAutoRefreshMinute) {
        _lastAutoRefreshMinute = now.minute;
        _loadData(silent: true);
      }

      if (mounted) setState(() {});
    });
  }

  Future<void> _initAchievements() async {
    _achievementService.onAchievementUnlocked = (achievement) {
      if (mounted) {
        AchievementUnlockedOverlay.show(context, achievement);
      }
    };
    // Початкове завантаження стану
    await _achievementService.loadAllStates();
    // Трекер сесії ("Контроль ситуації")
    _achievementService.trackAppSession();
  }

  Future<void> _initPowerMonitor() async {
    SharedPreferences? prefs;
    try {
      prefs = await PreferencesHelper.getSafeInstance();
    } catch (e) {
      AppLogger.w("Error loading SharedPreferences in _initPowerMonitor: $e",
          tag: 'Main');
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
          // Оновити стадію тьми при зміні статусу живлення
          DarknessThemeService().refresh();
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
      AppLogger.e('Error loading real outage data', tag: 'Main', error: e);
      _realOutageIntervals = [];
    }
  }

  Future<void> _loadPreferencesAndData() async {
    SharedPreferences? prefs;
    try {
      prefs = await SharedPreferences.getInstance();
    } catch (e) {
      AppLogger.e("Error loading SharedPreferences", tag: 'Main', error: e);
      // If SharedPreferences is corrupt, we might want to let the app continue with defaults
      // or show an error. For now, just logging.
    }

    if (prefs != null) {
      final p = prefs;
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
      AppLogger.e("Error saving group preference", tag: 'Main', error: e);
    }

    setState(() => _currentGroup = newGroup);
    // Трекер для ачівки "Громадянин"
    _achievementService.trackGroupChange();

    if (_viewMode == ScheduleViewMode.today ||
        _viewMode == ScheduleViewMode.tomorrow) {
      final now = DateTime.now();
      await _refreshVersionsForCurrentMode();

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
        AppLogger.e("Error syncing hash", tag: 'Main', error: e);
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

  Future<void> _loadCachedData() async {
    try {
      final cached = await HistoryService().getLastKnownSchedules();
      if (cached.isNotEmpty && mounted) {
        setState(() {
          _allSchedules = cached;
          _isLoading = false;
          _isCachedData = true;
          _statusColor = Colors.orange;

          final current = cached[_currentGroup];
          if (current != null) {
            _statusMessage = "З пам'яті: ${current.lastUpdatedSource}";
          } else {
            _statusMessage = "З пам'яті (дані завантажено)";
          }
        });

        // Load history versions for the cached data to populate dropdown if needed
        await _refreshVersionsForCurrentMode();
      }
    } catch (e) {
      AppLogger.e("Error loading cached data", tag: 'Main', error: e);
    }
  }

  @override
  void dispose() {
    _focusNode.dispose();
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
    } else if (menuItem.key == 'exit_app') {
      windowManager.destroy();
    }
  }

  @override
  void onWindowClose() async {
    if (await windowManager.isPreventClose()) windowManager.hide();
  }

  Future<void> _refreshVersionsForCurrentMode() async {
    final targetDate = _getDisplayDate();
    final versions =
        await HistoryService().getVersionsForDate(targetDate, _currentGroup);
    if (mounted) {
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
    }
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
      Color color = Colors.grey;

      if (_historyVersions.isNotEmpty) {
        // Prefer history version time string which includes date
        msg = "Оновлено ДТЕК: ${_historyVersions.last.timeString}";
        color = Colors.green;
      } else if (updateTime != null) {
        msg = "Оновлено ДТЕК: $updateTime";
        color = Colors.green;
      } else if (_allSchedules.containsKey(_currentGroup)) {
        msg =
            "Оновлено ДТЕК: ${_allSchedules[_currentGroup]!.lastUpdatedSource}";
        color = _isCachedData ? Colors.orange : Colors.green;
      }

      if (_isCachedData) {
        if (msg.contains("Оновлено ДТЕК")) {
          msg = msg.replaceAll("Оновлено ДТЕК", "З пам'яті");
        } else {
          msg = "$msg (З пам'яті)";
        }
        color = Colors.orange;
      }

      setState(() {
        _statusMessage = msg;
        _statusColor = color;
      });
    }
  }

  Future<void> _loadData({bool silent = false}) async {
    if (!silent) {
      // First, try to load from cache if we are empty
      if (_allSchedules.isEmpty) {
        await _loadCachedData();
      }

      setState(() {
        if (_allSchedules.isEmpty) {
          _isLoading = true; // Show spinner only if no data at all
        }
        _statusMessage =
            _isCachedData ? "Оновлення... (показано архів)" : "Оновлення...";
        _statusColor = Colors.orange;
      });
    }

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

      setState(() {
        _allSchedules = allData;
        _isLoading = false;
        _isCachedData = false;
        _wasUpdated = true;
        _statusColor = Colors.green;
      });
      await _refreshVersionsForCurrentMode();
      _updateStatusDate();

      try {
        final prefs = await SharedPreferences.getInstance();
        final notifyChange = prefs.getBool('notify_schedule_change') ?? true;
        final now = DateTime.now();

        final groupsToCheck = <String>{..._notificationGroups, _currentGroup};

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
            if (Platform.isWindows) {
              final newMinutes = _calculateOutageMinutes(schedule.today);
              int oldMinutes = 0;

              for (int i = 0; i < oldHash.length && i < 24; i++) {
                final char = oldHash[i];
                if (char == '1') {
                  oldMinutes += 60;
                } else if (char == '2' || char == '3') {
                  oldMinutes += 30;
                }
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

                _notifier.showImmediate("Графік змінено!", msg,
                    groupName: group);
              }
            }
          }

          await prefs.setString(keyHash, newHash);
          await prefs.setString(keyDate, todayStr);
        }
      } catch (e) {
        AppLogger.e("Error syncing hash", tag: 'Main', error: e);
      }

      _updateNotificationsOnly();
      if (Platform.isAndroid) await _widgetService.updateWidget(_allSchedules);

      // Перевірка досягнень після завантаження даних
      _achievementService.checkAll(
        schedules: _allSchedules,
        currentGroup: _currentGroup,
      );
    } catch (e) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          if (_isCachedData) {
            _statusMessage = "Немає зв'язку (Архів)";
            _statusColor = Colors.red;
          } else {
            _statusMessage = "Помилка оновлення";
            _statusColor = Colors.red;
          }
        });
      }
      AppLogger.e("Error loading data", tag: 'Main', error: e);
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
      // Трекер для ачівки "Архіваріус"
      _achievementService.trackHistoryView(picked);
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
        timeStr = '$hг $mхв';
      } else if (h > 0) {
        timeStr = '$hг';
      } else {
        timeStr = '$mхв';
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
      AppLogger.w(
          "Error loading SharedPreferences in _updateNotificationsOnly: $e",
          tag: 'Main');
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
    if (hours > 0 && minutes > 0) return "$hoursг $minutesхв";
    if (hours > 0) return "$hoursг";
    return "$minutesхв";
  }

  /// Побудувати DailySchedule з реальних інтервалів відключень (для grid).
  /// Використовується тільки для інтервального списку та нотифікацій (fallback).
  DailySchedule _buildRealScheduleFromIntervals(
      List<PowerOutageInterval> intervals, DateTime date,
      {DailySchedule? baseSchedule}) {
    // Якщо є прогноз, беремо його за основу, інакше все зелене
    List<LightStatus> hours = baseSchedule != null
        ? List.from(baseSchedule.hours)
        : List.filled(24, LightStatus.on);

    final now = DateTime.now();
    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;

    // Якщо це сьогодні - перезаписуємо минуле і поточну годину реальними даними.
    // Майбутнє залишаємо як у прогнозі (або зеленим якщо прогнозу немає).
    // Якщо день у минулому - перезаписуємо весь день (limitHour = 24).
    // Якщо день у майбутньому - все залишається прогнозом (loop не виконається або limitHour=0).

    int limitHour = 24;
    if (isToday) {
      // Перезаписуємо все ДО поточної години включно.
      // Поточна година теж формується тут, але в GridView вона перекривається _buildRealModeCell.
      // Для total outage minutes важливо порахувати і поточну годину з оффлайном.
      limitHour = now.hour + 1;
    } else if (date.isAfter(now)) {
      // Майбутній день - повністю прогноз
      limitHour = 0;
    }

    for (int h = 0; h < limitHour; h++) {
      // Скидаємо статус на On перед розрахунком реального,
      // бо ми хочемо порахувати суто по факту відключень.
      // (Хоча якщо там було semiOn/off в прогнозі, а світло було 100% часу - воно стане On.
      // А якщо світло було 0% часу - стане Off).
      // Але логіку нижче треба перевірити.
      // Логіка нижче базується на offMinutes.
      hours[h] = LightStatus.on;

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
    final noDataColor = Colors.grey.shade800.withValues(alpha: 0.3);

    List<List<HourSegment>> allSegments = [];

    for (int h = 0; h < 24; h++) {
      final hourStart = DateTime(date.year, date.month, date.day, h);
      final hourEnd = hourStart.add(const Duration(hours: 1));

      // Година в майбутньому
      if (isToday && hourStart.isAfter(now)) {
        // Повністю в майбутньому — використовуємо прогноз або порожньо
        if (forecast != null && !forecast.isEmpty) {
          final fStatus = forecast.hours[h];
          switch (fStatus) {
            case LightStatus.on:
              allSegments
                  .add([HourSegment(0, 1, greenColor.withValues(alpha: 0.3))]);
              break;
            case LightStatus.off:
              allSegments
                  .add([HourSegment(0, 1, redColor.withValues(alpha: 0.3))]);
              break;
            case LightStatus.semiOn:
              // Red -> Green
              allSegments.add([
                HourSegment(0, 0.5, redColor.withValues(alpha: 0.3)),
                HourSegment(0.5, 1, greenColor.withValues(alpha: 0.3))
              ]);
              break;
            case LightStatus.semiOff:
              // Green -> Red
              allSegments.add([
                HourSegment(0, 0.5, greenColor.withValues(alpha: 0.3)),
                HourSegment(0.5, 1, redColor.withValues(alpha: 0.3))
              ]);
              break;
            case LightStatus.maybe:
              allSegments
                  .add([HourSegment(0, 1, greyColor.withValues(alpha: 0.4))]);
              break;
            default:
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
        if (interval.start.isAfter(hourEnd) ||
            intervalEnd.isBefore(hourStart)) {
          continue;
        }

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

        if (endFrac > startFrac + 0.001) {
          offRanges.add(_OffRange(startFrac, endFrac));
        }
      }

      // Побудувати зелені/червоні сегменти (ФАКТ)
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

      // ---------------------------------------------------------
      // ПРОГНОЗ для залишку години (після factEndFraction)
      // ---------------------------------------------------------
      if (isToday && now.hour == h && factEndFraction < 0.99) {
        // Якщо є прогноз — беремо його
        if (forecast != null && !forecast.isEmpty) {
          final fStatus = forecast.hours[h];

          // Helper to add segment if it overlaps with [factEndFraction, 1.0]
          void addForecastSegment(double start, double end, Color c) {
            final double s = start < factEndFraction ? factEndFraction : start;
            final double e = end; // end is always 0.5 or 1.0
            if (e > s) {
              segments.add(HourSegment(s, e, c.withValues(alpha: 0.3)));
            }
          }

          switch (fStatus) {
            case LightStatus.on:
              addForecastSegment(0.0, 1.0, greenColor);
              break;
            case LightStatus.off:
              addForecastSegment(0.0, 1.0, redColor);
              break;
            case LightStatus.semiOn:
              // 0.0-0.5 OFF (Red), 0.5-1.0 ON (Green)
              addForecastSegment(0.0, 0.5, redColor);
              addForecastSegment(0.5, 1.0, greenColor);
              break;
            case LightStatus.semiOff:
              // 0.0-0.5 ON (Green), 0.5-1.0 OFF (Red)
              addForecastSegment(0.0, 0.5, greenColor);
              addForecastSegment(0.5, 1.0, redColor);
              break;
            case LightStatus.maybe:
              addForecastSegment(0.0, 1.0, greyColor);
              break;
            default:
              addForecastSegment(0.0, 1.0, noDataColor);
          }
        } else {
          // Немає прогнозу - малюємо "невідомо" або "зелене" (залежить від логіки,
          // але зазвичай краще показати noData/Unknown)
          segments.add(HourSegment(factEndFraction, 1.0, noDataColor));
        }
      }

      // Якщо взагалі нема сегментів (не повинно бути, але на всяк випадок)
      if (segments.isEmpty) {
        segments.add(HourSegment(0, 1, greenColor)); // Default fallback
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
      bgColor = Colors.green.withValues(alpha: 0.15);
      textColor = Colors.green;
      label = "ON";
      icon = Icons.power;
    } else if (isOffline) {
      bgColor = Colors.red.withValues(alpha: 0.15);
      textColor = Colors.red;
      label = "OFF";
      icon = Icons.power_off;
    } else {
      bgColor = Colors.grey.withValues(alpha: 0.15);
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
        border: Border.all(color: textColor.withValues(alpha: 0.3)),
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

  /// Банер поточної стадії тьми (показується коли автотема ввімкнена).
  Widget _buildDarknessStageBar() {
    final darknessService = DarknessThemeService();
    if (!darknessService.isEnabled) return const SizedBox.shrink();

    final stage = darknessService.currentStage;
    final icon = DarknessThemeService.stageIcon(stage);
    final name = DarknessThemeService.stageName(stage);
    final subtitle = DarknessThemeService.stageSubtitle(stage);
    final accent = DarknessThemeService.stageAccentColor(stage);
    final secondary = DarknessThemeService.stageSecondaryColor(stage);
    final flutterIcon = DarknessThemeService.stageFlutterIcon(stage);

    // Stalker mode: более жёсткий и тревожный стиль
    final isStalker = stage == DarknessStage.stalker;
    final isCyberpunk = stage == DarknessStage.cyberpunk;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: EdgeInsets.symmetric(
        horizontal: isStalker ? 8 : 12,
        vertical: isStalker ? 8 : 6,
      ),
      decoration: BoxDecoration(
        color: isStalker
            ? Colors.black
            : isCyberpunk
                ? const Color(0xFF08081A)
                : accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(isStalker ? 2 : 10),
        border: Border.all(
          color: isStalker
              ? accent.withValues(alpha: 0.6)
              : accent.withValues(alpha: 0.3),
          width: isStalker ? 1.5 : 1,
        ),
        boxShadow: isCyberpunk || isStalker
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: isStalker ? 0.15 : 0.2),
                  blurRadius: isStalker ? 8 : 12,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            flutterIcon,
            color: isStalker ? secondary : accent,
            size: isStalker ? 18 : 16,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isStalker ? '[ $name ]' : '$icon $name',
                  style: TextStyle(
                    fontSize: isStalker ? 11 : 12,
                    color: accent,
                    fontWeight: FontWeight.bold,
                    fontFamily: isStalker ? 'monospace' : null,
                    letterSpacing: isStalker ? 2 : (isCyberpunk ? 1 : 0),
                  ),
                ),
                Text(
                  isStalker ? subtitle.toUpperCase() : subtitle,
                  style: TextStyle(
                    fontSize: 9,
                    color: accent.withValues(alpha: 0.6),
                    fontFamily: isStalker ? 'monospace' : null,
                    letterSpacing: isStalker ? 1.5 : 0,
                  ),
                ),
              ],
            ),
          ),
          if (isStalker) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.warning_amber,
              color: secondary,
              size: 14,
            ),
          ],
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
            selectedColor: Colors.orange.withValues(alpha: 0.3),
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
            selectedColor: Colors.amber.withValues(alpha: 0.3),
            onSelected: (selected) {
              if (selected) {
                setState(() => _dataSourceMode = DataSourceMode.real);
                _loadRealOutageData(_getDisplayDate()).then((_) {
                  if (mounted) setState(() {});
                });
              }
            },
          ),
          const SizedBox(width: 4),
          _buildPowerIndicator(),
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
    if (fullSchedule == null || _viewMode != ScheduleViewMode.today) {
      return const SizedBox.shrink();
    }

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
    if (hours > 0) timeStr += "$hoursг ";
    timeStr += "$minutesхв";

    String msg = "";
    if (currentStatus == SlotStatus.on) {
      msg = "До відключення: $timeStr";
    } else if (currentStatus == SlotStatus.off) {
      msg = "До ввімкнення: $timeStr";
    } else {
      msg = "До зміни статусу: $timeStr";
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final darknessService = DarknessThemeService();
    final stage =
        darknessService.isEnabled ? darknessService.currentStage : null;

    // Resolve colors per theme
    Color containerColor;
    Color textColor;
    Color iconColor;
    double borderRadiusVal;
    Border? border;
    List<BoxShadow>? shadows;
    TextStyle? extraStyle;

    switch (stage) {
      case DarknessStage.solarpunk:
        containerColor = const Color(0xFF1B5E20).withValues(alpha: 0.85);
        textColor = const Color(0xFFE8F5E9);
        iconColor = const Color(0xFF66BB6A);
        borderRadiusVal = 16;
        shadows = [
          BoxShadow(
            color: const Color(0xFF66BB6A).withValues(alpha: 0.2),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ];
        break;
      case DarknessStage.dieselpunk:
        containerColor = const Color(0xFF1A1A1A);
        textColor = const Color(0xFFFFD54F);
        iconColor = const Color(0xFFFF9800);
        borderRadiusVal = 4;
        border = Border.all(
          color: const Color(0xFFFF9800).withValues(alpha: 0.35),
          width: 1.5,
        );
        shadows = [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 4,
            offset: const Offset(2, 2),
          ),
        ];
        extraStyle = const TextStyle(
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
        );
        break;
      case DarknessStage.cyberpunk:
        containerColor = const Color(0xFF0A0E21);
        textColor = const Color(0xFF00FFFF);
        iconColor = const Color(0xFFFF0080);
        borderRadiusVal = 8;
        border = Border.all(
          color: const Color(0xFF00FFFF).withValues(alpha: 0.4),
          width: 1,
        );
        shadows = [
          BoxShadow(
            color: const Color(0xFF00FFFF).withValues(alpha: 0.2),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ];
        extraStyle = const TextStyle(
          fontWeight: FontWeight.bold,
          letterSpacing: 1.5,
        );
        break;
      case DarknessStage.stalker:
        containerColor = const Color(0xFF050505);
        textColor = const Color(0xFF39FF14);
        iconColor = const Color(0xFF39FF14);
        borderRadiusVal = 2;
        border = Border.all(
          color: const Color(0xFF39FF14).withValues(alpha: 0.3),
          width: 1,
        );
        extraStyle = const TextStyle(
          fontWeight: FontWeight.bold,
          fontFamily: 'monospace',
          letterSpacing: 2,
          shadows: [
            Shadow(blurRadius: 4, color: Color(0xFF39FF14)),
          ],
        );
        break;
      default:
        containerColor =
            isDark ? const Color(0xFF2C2C2C) : Colors.grey.shade300;
        textColor = isDark ? Colors.white : Colors.black87;
        iconColor = Colors.orange;
        borderRadiusVal = 12;
    }

    final baseTextStyle = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.bold,
      color: textColor,
    );
    final finalTextStyle =
        extraStyle != null ? baseTextStyle.merge(extraStyle) : baseTextStyle;

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: containerColor,
          borderRadius: BorderRadius.circular(borderRadiusVal),
          border: border,
          boxShadow: shadows,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, color: iconColor, size: 24),
            const SizedBox(width: 8),
            Text(msg, style: finalTextStyle),
          ],
        ),
      ),
    );
  }

  void _setDataSourceMode(DataSourceMode mode) {
    if (!_powerMonitorEnabled) return;
    if (_dataSourceMode == mode) return;

    setState(() => _dataSourceMode = mode);
    if (mode == DataSourceMode.real) {
      _loadRealOutageData(_getDisplayDate()).then((_) {
        if (mounted) setState(() {});
      });
    }
  }

  Future<void> _navigateDate(int offset) async {
    if (offset == 0) return;

    DateTime current;
    switch (_viewMode) {
      case ScheduleViewMode.today:
        current = DateTime.now();
        break;
      case ScheduleViewMode.yesterday:
        current = DateTime.now().subtract(const Duration(days: 1));
        break;
      case ScheduleViewMode.tomorrow:
        current = DateTime.now().add(const Duration(days: 1));
        break;
      case ScheduleViewMode.history:
        current =
            _historyDate ?? DateTime.now().subtract(const Duration(days: 2));
        break;
    }

    final newDate = current.add(Duration(days: offset));
    final now = DateTime.now();
    final yesterday = now.subtract(const Duration(days: 1));
    final tomorrow = now.add(const Duration(days: 1));

    if (DateUtils.isSameDay(newDate, now)) {
      setState(() => _viewMode = ScheduleViewMode.today);
      _updateStatusDate();
      await _refreshVersionsForCurrentMode();

      if (_dataSourceMode == DataSourceMode.real) {
        _loadRealOutageData(newDate).then((_) => setState(() {}));
      }
    } else if (DateUtils.isSameDay(newDate, yesterday)) {
      setState(() {
        _viewMode = ScheduleViewMode.yesterday;
        _historyDate = newDate;
      });
      _loadHistoryData(newDate);
      if (_dataSourceMode == DataSourceMode.real) {
        _loadRealOutageData(newDate).then((_) => setState(() {}));
      }
    } else if (DateUtils.isSameDay(newDate, tomorrow)) {
      setState(() => _viewMode = ScheduleViewMode.tomorrow);
      _updateStatusDate();
      await _refreshVersionsForCurrentMode();
      if (_dataSourceMode == DataSourceMode.real) {
        _loadRealOutageData(newDate).then((_) => setState(() {}));
      }
    } else {
      setState(() {
        _viewMode = ScheduleViewMode.history;
        _historyDate = newDate;
      });
      _loadHistoryData(newDate);
      if (_dataSourceMode == DataSourceMode.real) {
        _loadRealOutageData(newDate).then((_) => setState(() {}));
      }
    }
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
      if (_historyVersions.isNotEmpty &&
          _selectedVersionIndex >= 0 &&
          _historySchedule != null) {
        currentDisplay = _historySchedule;
      } else {
        currentDisplay = _allSchedules[_currentGroup]?.tomorrow;
      }
    } else if (_viewMode == ScheduleViewMode.yesterday) {
      currentDisplay = _historySchedule;
    } else if (_viewMode == ScheduleViewMode.history) {
      currentDisplay = _historySchedule;
    }

    // Override with real data if in real mode
    List<IntervalInfo> intervals;
    _realHourSegments = null;
    if (_powerMonitorEnabled && _dataSourceMode == DataSourceMode.real) {
      currentDisplay = _buildRealScheduleFromIntervals(
          _realOutageIntervals, displayDate,
          baseSchedule: currentDisplay);
      intervals = _generateRealIntervals(_realOutageIntervals, displayDate);
      _realHourSegments =
          _computeAllHourSegments(_realOutageIntervals, displayDate);
    } else {
      intervals = _generateIntervals(currentDisplay);
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;

    return FocusableActionDetector(
      focusNode: _focusNode,
      autofocus: true,
      shortcuts: {
        LogicalKeySet(LogicalKeyboardKey.keyA):
            const _SwitchModeIntent(DataSourceMode.predicted),
        LogicalKeySet(LogicalKeyboardKey.arrowLeft):
            const _SwitchModeIntent(DataSourceMode.predicted),
        LogicalKeySet(LogicalKeyboardKey.numpad4):
            const _SwitchModeIntent(DataSourceMode.predicted),
        LogicalKeySet(LogicalKeyboardKey.keyD):
            const _SwitchModeIntent(DataSourceMode.real),
        LogicalKeySet(LogicalKeyboardKey.arrowRight):
            const _SwitchModeIntent(DataSourceMode.real),
        LogicalKeySet(LogicalKeyboardKey.numpad6):
            const _SwitchModeIntent(DataSourceMode.real),
      },
      actions: {
        _SwitchModeIntent: CallbackAction<_SwitchModeIntent>(
          onInvoke: (intent) {
            _setDataSourceMode(intent.mode);
            return null;
          },
        ),
      },
      child: GestureDetector(
        onHorizontalDragEnd: (details) {
          if (details.primaryVelocity! > 0) {
            // Swipe Right -> Forecast
            _setDataSourceMode(DataSourceMode.predicted);
          } else if (details.primaryVelocity! < 0) {
            // Swipe Left -> Real
            _setDataSourceMode(DataSourceMode.real);
          }
        },
        child: Scaffold(
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
                    if (context.mounted) {
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
                  _achievementService.trackRefresh();
                },
              ),
              IconButton(
                icon: Icon(Icons.analytics_outlined,
                    color: isDark ? Colors.orange : Colors.deepPurple),
                tooltip: 'Аналітика',
                onPressed: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) =>
                          AnalyticsScreen(groupKey: _currentGroup),
                    ),
                  );
                },
              ),
              IconButton(
                icon: Icon(Icons.settings,
                    color: isDark ? Colors.white : Colors.black87),
                onPressed: () async {
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (context) => SettingsPage(
                            onThemeChanged: widget.onThemeChanged,
                            onScaleChanged: widget.onScaleChanged)),
                  );
                  _loadPreferencesAndData();
                  _initPowerMonitor();
                },
              ),
            ],
          ),
          body: Stack(
            children: [
              Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12.0),
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          IconButton(
                            icon: DarknessThemeService().buildArrowIcon(
                              forward: false,
                              color: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.color ??
                                  Colors.white,
                            ),
                            onPressed: () => _navigateDate(-1),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
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
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
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
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
                            child: ChoiceChip(
                              label: const Text('Сьогодні'),
                              selected: _viewMode == ScheduleViewMode.today,
                              onSelected: (bool selected) {
                                setState(() {
                                  _viewMode = ScheduleViewMode.today;
                                });
                                _updateStatusDate();
                                _refreshVersionsForCurrentMode();
                                if (_dataSourceMode == DataSourceMode.real) {
                                  _loadRealOutageData(DateTime.now())
                                      .then((_) => setState(() {}));
                                }
                              },
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
                            child: ChoiceChip(
                              label: const Text('Завтра'),
                              selected: _viewMode == ScheduleViewMode.tomorrow,
                              onSelected: (bool selected) {
                                setState(() {
                                  _viewMode = ScheduleViewMode.tomorrow;
                                });
                                _updateStatusDate();
                                _refreshVersionsForCurrentMode();
                                if (_dataSourceMode == DataSourceMode.real) {
                                  _loadRealOutageData(DateTime.now()
                                          .add(const Duration(days: 1)))
                                      .then((_) => setState(() {}));
                                }
                              },
                            ),
                          ),
                          IconButton(
                            icon: DarknessThemeService().buildArrowIcon(
                              forward: true,
                              color: Theme.of(context)
                                      .textTheme
                                      .titleLarge
                                      ?.color ??
                                  Colors.white,
                            ),
                            onPressed: () => _navigateDate(1),
                          ),
                        ],
                      ),
                    ),
                  ),
                  _buildDataSourceToggle(),
                  _buildDarknessStageBar(),
                  GestureDetector(
                    onTap: (_historyVersions.isNotEmpty)
                        ? _showVersionPicker
                        : null,
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(_statusMessage,
                            style: TextStyle(
                                color: _statusColor,
                                fontSize: 12,
                                fontWeight: FontWeight.bold)),
                        if (_historyVersions.isNotEmpty)
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
                        _getOutageInfoText(currentDisplay,
                            _viewMode == ScheduleViewMode.tomorrow),
                        style: TextStyle(
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                            color:
                                Theme.of(context).textTheme.bodyLarge?.color ??
                                    Colors.black87),
                      ),
                    ),
                  ],
                  Expanded(
                    child: _isLoading
                        ? const Center(
                            child:
                                CircularProgressIndicator(color: Colors.orange))
                        : RefreshIndicator(
                            color: Colors.orange,
                            onRefresh: () async {
                              _achievementService.trackRefresh();
                              if (_viewMode == ScheduleViewMode.history ||
                                  _viewMode == ScheduleViewMode.yesterday) {
                                if (_historyDate != null) {
                                  await _loadHistoryData(_historyDate!);
                                }
                              } else {
                                await _loadData(silent: true);
                              }
                            },
                            child: ListView(
                              physics: const AlwaysScrollableScrollPhysics(),
                              children: [
                                Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 12.0),
                                  child: _buildGrid(currentDisplay, cols,
                                      realHourSegments: _realHourSegments),
                                ),
                                if (intervals.isNotEmpty)
                                  const Padding(
                                    padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
                                    child: Text("Розклад інтервалами:",
                                        style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                            fontSize: 16)),
                                  ),
                                if (intervals.isNotEmpty)
                                  Padding(
                                    padding: const EdgeInsets.fromLTRB(
                                        12, 0, 12, 40),
                                    child: Card(
                                      child: Column(
                                        children: intervals.map((interval) {
                                          return GestureDetector(
                                            onLongPress: () =>
                                                _showIntervalMenu(
                                                    context, interval),
                                            child: Container(
                                              decoration: const BoxDecoration(
                                                  border: Border(
                                                      bottom: BorderSide(
                                                          color:
                                                              Colors.white10))),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                      vertical: 12,
                                                      horizontal: 16),
                                              child: Row(
                                                children: [
                                                  SizedBox(
                                                      width: 120,
                                                      child: Text(
                                                          interval.timeRange,
                                                          style: TextStyle(
                                                              fontSize: 16,
                                                              fontWeight:
                                                                  FontWeight
                                                                      .w500,
                                                              color: interval
                                                                      .statusText
                                                                      .contains(
                                                                          "OFF")
                                                                  ? Colors.red
                                                                  : (Theme.of(context)
                                                                              .brightness ==
                                                                          Brightness
                                                                              .dark
                                                                      ? Colors
                                                                          .white
                                                                      : Colors
                                                                          .black87)))),
                                                  Container(
                                                    padding: const EdgeInsets
                                                        .symmetric(
                                                        horizontal: 8,
                                                        vertical: 2),
                                                    decoration: BoxDecoration(
                                                        color: interval.color
                                                            .withValues(
                                                                alpha: 0.2),
                                                        borderRadius:
                                                            BorderRadius
                                                                .circular(4)),
                                                    child: Text(
                                                        interval.statusText,
                                                        style: TextStyle(
                                                            color:
                                                                interval.color,
                                                            fontWeight:
                                                                FontWeight
                                                                    .bold)),
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
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGrid(DailySchedule? schedule, int columns,
      {List<List<HourSegment>>? realHourSegments}) {
    final bool isRealMode =
        _powerMonitorEnabled && _dataSourceMode == DataSourceMode.real;

    if (isRealMode &&
        (_powerMonitor.customUrl == null ||
            _powerMonitor.customUrl!.trim().isEmpty)) {
      return const SizedBox(
        height: 500,
        child: Center(
          child: Padding(
            padding: EdgeInsets.all(40),
            child: Text(
              "URL бази даних не налаштовано. Перейдіть в Налаштування.",
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 16),
            ),
          ),
        ),
      );
    }

    if (!isRealMode && (schedule == null || schedule.isEmpty)) {
      return RefreshIndicator(
        onRefresh: () async {
          _achievementService.trackRefresh();
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

        final darknessService = DarknessThemeService();
        final stage =
            darknessService.isEnabled ? darknessService.currentStage : null;

        switch (status) {
          case LightStatus.on:
            cellContent = _themedColorBox(true, "$index:00", stage);
            break;
          case LightStatus.off:
            cellContent = _themedColorBox(false, "$index:00", stage);
            break;
          case LightStatus.semiOn:
            cellContent = _themedGradientBox(true, "$index:00", stage);
            break;
          case LightStatus.semiOff:
            cellContent = _themedGradientBox(false, "$index:00", stage);
            break;
          case LightStatus.maybe:
            cellContent = _themedMaybeBox("$index:00", stage);
            break;
          default:
            cellContent = _themedMaybeBox("$index:00", stage);
        }

        // Wrap with animation
        final animated = ThemeAnimatedCell(
          stage: stage,
          child: cellContent,
        );

        if (isCurrentHour) {
          return _themedCurrentHourWrap(animated, stage);
        }
        return animated;
      },
    );
  }

  /// Ячейка Real Mode: пропорційна заливка кольорами (themed) + анімації + Future Styling.
  Widget _buildRealModeCell(
      int hour, List<HourSegment> segments, bool isCurrentHour) {
    final darknessService = DarknessThemeService();
    final stage =
        darknessService.isEnabled ? darknessService.currentStage : null;
    final now = DateTime.now();
    final bool showNowLine = isCurrentHour;
    final double nowFraction = showNowLine ? now.minute / 60.0 : 0;
    final radius = _themedBorderRadius(stage);
    final textStyle = _themedCellTextStyle(stage);

    // Resolve now-line color per theme
    Color nowLineColor;
    switch (stage) {
      case DarknessStage.solarpunk:
        nowLineColor = const Color(0xFF2E7D32);
        break;
      case DarknessStage.dieselpunk:
        nowLineColor = const Color(0xFFFF9800);
        break;
      case DarknessStage.cyberpunk:
        nowLineColor = const Color(0xFFFF0080);
        break;
      case DarknessStage.stalker:
        nowLineColor = const Color(0xFFFF1744);
        break;
      default:
        nowLineColor = Colors.white.withValues(alpha: 0.9);
    }

    // Helper to determine if a color represents "ON" state
    bool isOn(Color c) {
      return (c.g * 255.0).round().clamp(0, 255) > 100 &&
          (c.r * 255.0).round().clamp(0, 255) < 150;
    }

    // Build timeline segments
    Widget timeline = LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth;
      List<Widget> children = [];

      for (final segment in segments) {
        // Handle split for current hour
        double start = segment.startFraction;
        double end = segment.endFraction;

        // If this segment is entirely in the past (left of now line) or entirely future (right)
        // Or if it crosses.
        // We render it as one piece, BUT we apply "Future" styling if it is effectively "Future".
        // HOWEVER, the user wants a sharp visual split at `nowFraction`.
        // So we strictly split segments at `nowFraction` if they overlap.

        List<_RenderSegment> distinctParts = [];

        if (isCurrentHour) {
          // 1. Part before NOW (Past/Fact)
          if (start < nowFraction) {
            final effectiveEnd = end < nowFraction ? end : nowFraction;
            distinctParts.add(_RenderSegment(
                start, effectiveEnd, segment.color, false)); // isFuture=false
          }
          // 2. Part after NOW (Future/Forecast)
          if (end > nowFraction) {
            final effectiveStart = start > nowFraction ? start : nowFraction;
            distinctParts.add(_RenderSegment(
                effectiveStart, end, segment.color, true)); // isFuture=true
          }
        } else {
          // Past hour or Future hour
          // If hour is today and > now.hour => Future
          // If hour is tomorrow => Future (but we only show 24h usually, assumes index 0..23 is today)
          // Wait, _buildRealModeCell is used in today view?
          // The grid builder says: `final bool isCurrentHour = _viewMode == ScheduleViewMode.today && DateTime.now().hour == index;`
          // And index is 0..23.
          // So if index > now.hour, it's future. if index < now.hour, it's past.
          bool isFuture = false;
          if (_viewMode == ScheduleViewMode.today) {
            if (hour > now.hour) isFuture = true;
          } else if (_viewMode == ScheduleViewMode.tomorrow) {
            isFuture = true;
          } else if (_viewMode == ScheduleViewMode.yesterday ||
              _viewMode == ScheduleViewMode.history) {
            isFuture = false;
          }

          distinctParts
              .add(_RenderSegment(start, end, segment.color, isFuture));
        }

        for (final part in distinctParts) {
          final w = (part.end - part.start) * totalWidth;
          if (w < 0.5) continue;

          leftOffset() => part.start * totalWidth;

          final isSegmentOn = isOn(part.color);
          final themeColor =
              isSegmentOn ? _themedOnColor(stage) : _themedOffColor(stage);

          // Decoration for segment
          BoxDecoration segDecoration;
          Widget? overlay;

          if (part.isFuture) {
            // --- FUTURE STYLING ---
            switch (stage) {
              case DarknessStage.solarpunk:
                // Blueprint / Potential: Semi-transparent grid
                segDecoration = BoxDecoration(
                    color: themeColor.withValues(alpha: 0.35),
                    border: Border.all(
                        color: themeColor.withValues(alpha: 0.5), width: 0.5));
                overlay = CustomPaint(
                    painter: _GridOverlayPainter(
                        color: themeColor.withValues(alpha: 0.15)));
                break;
              case DarknessStage.dieselpunk:
                // Draft / Paper: Diagonal hatching (dense)
                segDecoration = BoxDecoration(
                  color: themeColor.withValues(alpha: 0.5),
                );
                overlay = ClipRect(
                  child: CustomPaint(
                    painter: _DiagonalStripesPainter(
                      color: Colors.black.withValues(alpha: 0.2), // Darker etch
                      spacing: 4, // Denser
                    ),
                  ),
                );
                break;
              case DarknessStage.cyberpunk:
                // Simulation / Hologram: Vertical scanlines
                segDecoration = BoxDecoration(
                  color: themeColor.withValues(alpha: 0.2),
                  border: Border.all(color: themeColor, width: 1),
                );
                overlay = Column(
                  children: List.generate(
                      10,
                      (index) => Expanded(
                              child: Container(
                            margin: const EdgeInsets.only(bottom: 1),
                            color: themeColor.withValues(alpha: 0.1),
                          ))),
                );
                break;
              case DarknessStage.stalker:
                // Fog / Anomaly: Static noise + Desaturated
                segDecoration = BoxDecoration(
                  color: Color.lerp(themeColor, Colors.grey, 0.7)!
                      .withValues(alpha: 0.4),
                );
                overlay = CustomPaint(
                  painter: _NoisePainter(
                      seed: hour * 100 + part.start.toInt()), // Static seed
                );
                break;
              default:
                segDecoration = BoxDecoration(
                  color: themeColor.withValues(alpha: 0.4),
                );
                overlay = const Icon(Icons.help_outline,
                    size: 12, color: Colors.white24);
            }
          } else {
            // --- FACT STYLING (Standard) ---
            switch (stage) {
              case DarknessStage.solarpunk:
                segDecoration = BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: isSegmentOn
                        ? [const Color(0xFF66BB6A), const Color(0xFF43A047)]
                        : [const Color(0xFFE57373), const Color(0xFFBF360C)],
                  ),
                );
                break;
              case DarknessStage.dieselpunk:
                segDecoration = BoxDecoration(
                  color: themeColor,
                );
                break;
              case DarknessStage.cyberpunk:
                segDecoration = BoxDecoration(
                  color: themeColor,
                  border: Border(
                    top: BorderSide(
                      color: (isSegmentOn
                              ? const Color(0xFF00FFFF)
                              : const Color(0xFFFF0080))
                          .withValues(alpha: 0.5),
                      width: 1,
                    ),
                  ),
                );
                break;
              case DarknessStage.stalker:
                segDecoration = BoxDecoration(
                  color: themeColor, // already mapped to dark storage colors
                );
                break;
              default:
                segDecoration = BoxDecoration(color: themeColor);
            }
          }

          Widget segmentWidget =
              Container(decoration: segDecoration, child: overlay);

          // Legacy overlays for Fact parts (Diesel stripes OFF etc)
          if (!part.isFuture) {
            List<Widget> extras = [segmentWidget];
            // Dieselpunk: diagonal stripes for OFF FACT
            if (stage == DarknessStage.dieselpunk && !isSegmentOn) {
              extras.add(Positioned.fill(
                child: ClipRect(
                  child: CustomPaint(
                    painter: _DiagonalStripesPainter(
                      color: const Color(0xFFFF9800).withValues(alpha: 0.08),
                    ),
                  ),
                ),
              ));
            }
            // Stalker: scanlines for OFF FACT
            if (stage == DarknessStage.stalker && !isSegmentOn) {
              extras.add(Positioned.fill(
                child: CustomPaint(
                  painter: _ScanlinePainter(
                    color: const Color(0xFFFF1744).withValues(alpha: 0.06),
                  ),
                ),
              ));
            }

            children.add(Positioned(
              left: leftOffset(),
              width: w,
              top: 0,
              bottom: 0,
              child: Stack(children: extras),
            ));
          } else {
            // Future widget already has overlay inside
            children.add(Positioned(
              left: leftOffset(),
              width: w,
              top: 0,
              bottom: 0,
              child: segmentWidget,
            ));
          }
        }
      }

      return Stack(
        children: [
          ...children, // Positioned widgets

          // Stalker: global scanline overlay (subtle) - ONLY FOR FACT PARTS?
          // Actually, let's keep it global for cohesion, or maybe restrict?
          // User said "Future... must be unique".
          // Let's keep global effects minimal on Future to not conflict.

          // "Now" vertical line
          if (showNowLine)
            Positioned(
              left: nowFraction * totalWidth - 1,
              top: 0,
              bottom: 0,
              child: Container(
                width: stage == DarknessStage.stalker ? 1.5 : 2,
                decoration: BoxDecoration(
                  color: nowLineColor,
                  boxShadow: stage == DarknessStage.cyberpunk
                      ? [
                          BoxShadow(
                            color: nowLineColor.withValues(alpha: 0.6),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
              ),
            ),

          // Timestamp
          Center(
            child: Text(
              "$hour:00",
              style: textStyle.copyWith(
                shadows: [
                  const Shadow(
                      blurRadius: 4,
                      color: Colors.black87,
                      offset: Offset(0, 0)),
                  const Shadow(
                      blurRadius: 8,
                      color: Colors.black54,
                      offset: Offset(0, 0)),
                  if (stage == DarknessStage.stalker)
                    const Shadow(
                        blurRadius: 4,
                        color: Color(0xFF39FF14),
                        offset: Offset(0, 0)),
                ],
              ),
            ),
          ),

          // Stalker: small radiation icon
          if (stage == DarknessStage.stalker)
            Positioned(
              right: 2,
              bottom: 1,
              child: Icon(
                Icons.radio_button_checked,
                size: 8,
                color: const Color(0xFF39FF14).withValues(alpha: 0.2),
              ),
            ),
        ],
      );
    });

    // Container styling (outer shell)
    BoxDecoration containerDecoration;
    switch (stage) {
      case DarknessStage.solarpunk:
        // Solarpunk cells usually have shadow, dealt with by ThemeAnimatedCell mostly?
        // But we need the rounded corners and base background
        containerDecoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xFF2E2E2E), // Base background
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        );
        break;
      case DarknessStage.dieselpunk:
        containerDecoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xFF1A1A1A),
          border: Border.all(
            color: const Color(0xFFFF9800).withValues(alpha: 0.2),
            width: 1,
          ),
        );
        break;
      case DarknessStage.cyberpunk:
        containerDecoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xFF0A0E21),
          border: Border.all(
            color: const Color(0xFF2A2A4A),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF00FFFF).withValues(alpha: 0.08),
              blurRadius: 6,
            ),
          ],
        );
        break;
      case DarknessStage.stalker:
        containerDecoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xFF050505),
          border: Border.all(
            color: const Color(0xFF39FF14).withValues(alpha: 0.2),
            width: 1,
          ),
        );
        break;
      default:
        containerDecoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: Colors.grey.shade900,
        );
    }

    // Wrap with gesture detector and tooltip
    Widget cell = GestureDetector(
      onLongPress: () => _showHourDetailTooltip(hour),
      child: Container(
        decoration: containerDecoration,
        clipBehavior: Clip.antiAlias, // Ensure segments don't overflow
        child: timeline,
      ),
    );

    // Wrap with animation
    final animated = ThemeAnimatedCell(
      stage: stage,
      child: cell,
    );

    if (isCurrentHour) {
      return _themedCurrentHourWrap(animated, stage);
    }
    return animated;
  }

  /// Themed ON/OFF cell.
  Widget _themedColorBox(bool isOn, String text, DarknessStage? stage) {
    final color = isOn ? _themedOnColor(stage) : _themedOffColor(stage);
    final radius = _themedBorderRadius(stage);
    final textStyle = _themedCellTextStyle(stage);

    // Determine decorative icon
    IconData? icon;
    Color iconColor = Colors.white24;
    switch (stage) {
      case DarknessStage.solarpunk:
        icon = isOn ? Icons.wb_sunny_outlined : Icons.cloud_outlined;
        iconColor = Colors.white.withValues(alpha: 0.25);
        break;
      case DarknessStage.dieselpunk:
        icon = isOn
            ? Icons.settings_outlined
            : Icons.local_fire_department_outlined;
        iconColor = const Color(0xFFFF9800).withValues(alpha: 0.2);
        break;
      case DarknessStage.cyberpunk:
        icon = isOn ? Icons.bolt_outlined : Icons.visibility_off_outlined;
        iconColor = const Color(0xFFFF0080).withValues(alpha: 0.25);
        break;
      case DarknessStage.stalker:
        icon = isOn ? Icons.radio_button_checked : Icons.warning_amber_rounded;
        iconColor = isOn
            ? const Color(0xFF39FF14).withValues(alpha: 0.15)
            : const Color(0xFFFF1744).withValues(alpha: 0.25);
        break;
      default:
        icon = null;
    }

    // Build decoration
    BoxDecoration decoration;
    switch (stage) {
      case DarknessStage.solarpunk:
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: isOn
                ? [const Color(0xFF66BB6A), const Color(0xFF43A047)]
                : [const Color(0xFFE57373), const Color(0xFFBF360C)],
          ),
          boxShadow: [
            BoxShadow(
              color: color.withValues(alpha: 0.25),
              blurRadius: 6,
              offset: const Offset(0, 2),
            ),
          ],
        );
        break;
      case DarknessStage.dieselpunk:
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: color,
          border: Border.all(
            color: const Color(0xFFFF9800).withValues(alpha: 0.3),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 4,
              offset: const Offset(2, 2),
            ),
          ],
        );
        break;
      case DarknessStage.cyberpunk:
        final neonColor =
            isOn ? const Color(0xFF00FFFF) : const Color(0xFFFF0080);
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: color,
          border: Border.all(
            color: neonColor.withValues(alpha: 0.5),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: neonColor.withValues(alpha: 0.2),
              blurRadius: 10,
              spreadRadius: 1,
            ),
          ],
        );
        break;
      case DarknessStage.stalker:
        final borderColor = isOn
            ? const Color(0xFF39FF14).withValues(alpha: 0.4)
            : const Color(0xFFFF1744).withValues(alpha: 0.5);
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: isOn ? const Color(0xFF0A1F0A) : const Color(0xFF1A0000),
          border: Border.all(color: borderColor, width: 1),
        );
        break;
      default:
        decoration = BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(radius),
        );
    }

    // Stalker: override text for OFF cells
    String displayText = text;
    TextStyle displayStyle = textStyle;
    if (stage == DarknessStage.stalker && !isOn) {
      displayStyle = textStyle.copyWith(
        color: const Color(0xFFFF1744),
        shadows: [
          const Shadow(blurRadius: 4, color: Color(0xFFFF1744)),
        ],
      );
    }

    return Container(
      decoration: decoration,
      child: Stack(
        children: [
          // Background decorative icon
          if (icon != null)
            Positioned(
              right: 3,
              bottom: 2,
              child: Icon(icon, size: 16, color: iconColor),
            ),
          // Stalker scanline overlay for OFF cells
          if (stage == DarknessStage.stalker && !isOn)
            Positioned.fill(
              child: CustomPaint(
                painter: _ScanlinePainter(
                  color: const Color(0xFFFF1744).withValues(alpha: 0.06),
                ),
              ),
            ),
          // Stalker: radiation icon top-left for OFF
          if (stage == DarknessStage.stalker && !isOn)
            Positioned(
              left: 3,
              top: 2,
              child: Icon(
                Icons.warning_amber_rounded,
                size: 10,
                color: const Color(0xFFFF1744).withValues(alpha: 0.4),
              ),
            ),
          // Cyberpunk: subtle inner glow line at top
          if (stage == DarknessStage.cyberpunk)
            Positioned(
              top: 0,
              left: 4,
              right: 4,
              child: Container(
                height: 1,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      Colors.transparent,
                      (isOn ? const Color(0xFF00FFFF) : const Color(0xFFFF0080))
                          .withValues(alpha: 0.5),
                      Colors.transparent,
                    ],
                  ),
                ),
              ),
            ),
          // Dieselpunk: diagonal stripes for OFF
          if (stage == DarknessStage.dieselpunk && !isOn)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(radius),
                child: CustomPaint(
                  painter: _DiagonalStripesPainter(
                    color: const Color(0xFFFF9800).withValues(alpha: 0.08),
                  ),
                ),
              ),
            ),
          // Main text
          Center(child: Text(displayText, style: displayStyle)),
        ],
      ),
    );
  }

  /// Themed gradient box for semi-on / semi-off status.
  Widget _themedGradientBox(bool isSemiOn, String text, DarknessStage? stage) {
    final onColor = _themedOnColor(stage);
    final offColor = _themedOffColor(stage);
    final radius = _themedBorderRadius(stage);
    final textStyle = _themedCellTextStyle(stage);
    final colors = isSemiOn ? [offColor, onColor] : [onColor, offColor];

    // Determine icons for both halves
    IconData? iconLeft;
    IconData? iconRight;
    Color iconColorLeft = Colors.white24;
    Color iconColorRight = Colors.white24;

    // Helper to pick icon per theme & state
    (IconData?, Color) getThemeIcon(bool isOn, DarknessStage? s) {
      switch (s) {
        case DarknessStage.solarpunk:
          return (
            isOn ? Icons.wb_sunny_outlined : Icons.cloud_outlined,
            Colors.white.withValues(alpha: 0.25)
          );
        case DarknessStage.dieselpunk:
          return (
            isOn
                ? Icons.settings_outlined
                : Icons.local_fire_department_outlined,
            const Color(0xFFFF9800).withValues(alpha: 0.2)
          );
        case DarknessStage.cyberpunk:
          return (
            isOn ? Icons.bolt_outlined : Icons.visibility_off_outlined,
            const Color(0xFFFF0080).withValues(alpha: 0.25)
          );
        case DarknessStage.stalker:
          return (
            isOn ? Icons.radio_button_checked : Icons.warning_amber_rounded,
            isOn
                ? const Color(0xFF39FF14).withValues(alpha: 0.15)
                : const Color(0xFFFF1744).withValues(alpha: 0.25)
          );
        default:
          return (null, Colors.white24);
      }
    }

    // Assign icons based on semiOn/semiOff logic
    // semiOn: First half OFF, Second half ON
    // semiOff: First half ON, Second half OFF
    if (isSemiOn) {
      final (iL, cL) = getThemeIcon(false, stage); // Left is OFF
      final (iR, cR) = getThemeIcon(true, stage); // Right is ON
      iconLeft = iL;
      iconColorLeft = cL;
      iconRight = iR;
      iconColorRight = cR;
    } else {
      final (iL, cL) = getThemeIcon(true, stage); // Left is ON
      final (iR, cR) = getThemeIcon(false, stage); // Right is OFF
      iconLeft = iL;
      iconColorLeft = cL;
      iconRight = iR;
      iconColorRight = cR;
    }

    // Stalker uses harsh split, cyberpunk uses neon glow
    BoxDecoration decoration;
    String displayText = text;
    switch (stage) {
      case DarknessStage.solarpunk:
        displayText = isSemiOn ? '$text ⚡' : text;
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
            colors: colors,
            stops: const [0.45, 0.55],
          ),
          boxShadow: [
            BoxShadow(
              color: onColor.withValues(alpha: 0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        );
        break;
      case DarknessStage.dieselpunk:
        displayText = isSemiOn ? '$text ⚡' : text;
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            colors: colors,
            stops: const [0.5, 0.5],
          ),
          border: Border.all(
            color: const Color(0xFFFF9800).withValues(alpha: 0.3),
            width: 1.5,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 3,
              offset: const Offset(1, 1),
            ),
          ],
        );
        break;
      case DarknessStage.cyberpunk:
        displayText = isSemiOn ? '$text ⚡' : text;
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            colors: colors,
            stops: const [0.5, 0.5],
          ),
          border: Border.all(
            color: const Color(0xFFBB86FC).withValues(alpha: 0.4),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFBB86FC).withValues(alpha: 0.15),
              blurRadius: 8,
              spreadRadius: 1,
            ),
          ],
        );
        break;
      case DarknessStage.stalker:
        displayText = isSemiOn ? '$text ?' : text;
        const cOn = Color(0xFF0A1F0A);
        const cOff = Color(0xFF1A0000);
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(
            colors: isSemiOn ? [cOff, cOn] : [cOn, cOff],
            stops: const [0.5, 0.5],
          ),
          border: Border.all(
            color: const Color(0xFFFFD600).withValues(alpha: 0.4),
            width: 1,
          ),
        );
        break;
      default:
        displayText = isSemiOn ? '$text ⚡' : text;
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          gradient: LinearGradient(colors: colors, stops: const [0.5, 0.5]),
        );
    }

    return Container(
      decoration: decoration,
      child: Stack(
        children: [
          // 1) Icons for left/right halves
          if (iconLeft != null)
            Positioned(
              left: 4,
              bottom: 4,
              child: Icon(iconLeft, size: 14, color: iconColorLeft),
            ),
          if (iconRight != null)
            Positioned(
              right: 4,
              bottom: 4,
              child: Icon(iconRight, size: 14, color: iconColorRight),
            ),

          if (stage == DarknessStage.stalker)
            Positioned.fill(
              child: CustomPaint(
                painter: _ScanlinePainter(
                  color: const Color(0xFFFFD600).withValues(alpha: 0.04),
                ),
              ),
            ),
          if (stage == DarknessStage.stalker)
            Positioned(
              right: 3,
              bottom: 2,
              child: Icon(
                iconRight ?? Icons.help_outline, // Use derived icon or fallback
                size: 12,
                color: iconColorRight,
              ),
            ),

          // 2) Dieselpunk: diagonal stripes for semiOff (right half is OFF)
          // semiOff -> !isSemiOn -> [ON, OFF] -> right half is OFF
          if (stage == DarknessStage.dieselpunk && !isSemiOn)
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(child: Container()), // Empty left half (ON)
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.only(
                          topRight: Radius.circular(radius),
                          bottomRight: Radius.circular(radius)),
                      child: CustomPaint(
                        painter: _DiagonalStripesPainter(
                          color:
                              const Color(0xFFFF9800).withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Dieselpunk: diagonal stripes for semiOn (left half is OFF)
          // semiOn -> [OFF, ON] -> left half is OFF
          if (stage == DarknessStage.dieselpunk && isSemiOn)
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.only(
                          topLeft: Radius.circular(radius),
                          bottomLeft: Radius.circular(radius)),
                      child: CustomPaint(
                        painter: _DiagonalStripesPainter(
                          color:
                              const Color(0xFFFF9800).withValues(alpha: 0.08),
                        ),
                      ),
                    ),
                  ),
                  Expanded(child: Container()), // Empty right half (ON)
                ],
              ),
            ),

          Center(
            child: Text(
              displayText,
              style: stage == DarknessStage.stalker
                  ? textStyle.copyWith(
                      color: const Color(0xFFFFD600),
                      shadows: [
                        const Shadow(blurRadius: 4, color: Color(0xFFFFD600)),
                      ],
                    )
                  : textStyle,
            ),
          ),
        ],
      ),
    );
  }

  /// Themed maybe/unknown cell.
  Widget _themedMaybeBox(String text, DarknessStage? stage) {
    final radius = _themedBorderRadius(stage);
    final textStyle = _themedCellTextStyle(stage);

    BoxDecoration decoration;
    switch (stage) {
      case DarknessStage.solarpunk:
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xFFBDBDBD),
          boxShadow: [
            BoxShadow(
              color: Colors.grey.withValues(alpha: 0.2),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        );
        break;
      case DarknessStage.dieselpunk:
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xFF3E2723),
          border: Border.all(
            color: const Color(0xFF795548).withValues(alpha: 0.4),
            width: 1,
          ),
        );
        break;
      case DarknessStage.cyberpunk:
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xFF12122A),
          border: Border.all(
            color: const Color(0xFF2A2A4A),
            width: 1,
          ),
        );
        break;
      case DarknessStage.stalker:
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: const Color(0xFF0A0A0A),
          border: Border.all(
            color: const Color(0xFF39FF14).withValues(alpha: 0.15),
            width: 1,
          ),
        );
        break;
      default:
        decoration = BoxDecoration(
          borderRadius: BorderRadius.circular(radius),
          color: Colors.grey.shade300,
        );
    }

    return Container(
      decoration: decoration,
      child: Stack(
        children: [
          if (stage == DarknessStage.stalker)
            Positioned(
              right: 3,
              bottom: 2,
              child: Icon(
                Icons.help_outline,
                size: 12,
                color: const Color(0xFF39FF14).withValues(alpha: 0.15),
              ),
            ),
          Center(
            child: Text(
              '$text ?',
              style: stage == DarknessStage.stalker
                  ? textStyle.copyWith(
                      color: const Color(0xFF39FF14).withValues(alpha: 0.5),
                    )
                  : (stage == DarknessStage.cyberpunk
                      ? textStyle.copyWith(
                          color: const Color(0xFF4A4A6A),
                        )
                      : textStyle.copyWith(color: Colors.white70)),
            ),
          ),
        ],
      ),
    );
  }

  /// Themed current-hour wrapper.
  Widget _themedCurrentHourWrap(Widget child, DarknessStage? stage) {
    Color borderColor;
    double borderWidth;
    double radius;
    List<BoxShadow>? shadows;
    IconData dotIcon = Icons.circle;
    Color dotColor;
    double dotSize = 8;

    switch (stage) {
      case DarknessStage.solarpunk:
        borderColor = const Color(0xFF2E7D32);
        borderWidth = 2.5;
        radius = 14;
        dotColor = const Color(0xFF2E7D32);
        dotIcon = Icons.access_time_filled;
        dotSize = 10;
        shadows = [
          BoxShadow(
            color: const Color(0xFF2E7D32).withValues(alpha: 0.3),
            blurRadius: 8,
            spreadRadius: 1,
          ),
        ];
        break;
      case DarknessStage.dieselpunk:
        borderColor = const Color(0xFFFF9800);
        borderWidth = 3;
        radius = 4;
        dotColor = const Color(0xFFFF9800);
        dotIcon = Icons.circle;
        shadows = [
          BoxShadow(
            color: const Color(0xFFFF9800).withValues(alpha: 0.3),
            blurRadius: 6,
          ),
        ];
        break;
      case DarknessStage.cyberpunk:
        borderColor = const Color(0xFF00FFFF);
        borderWidth = 2;
        radius = 8;
        dotColor = const Color(0xFFFF0080);
        dotIcon = Icons.circle;
        dotSize = 6;
        shadows = [
          BoxShadow(
            color: const Color(0xFF00FFFF).withValues(alpha: 0.4),
            blurRadius: 12,
            spreadRadius: 2,
          ),
          BoxShadow(
            color: const Color(0xFFFF0080).withValues(alpha: 0.15),
            blurRadius: 8,
          ),
        ];
        break;
      case DarknessStage.stalker:
        borderColor = const Color(0xFFFF1744);
        borderWidth = 2;
        radius = 2;
        dotColor = const Color(0xFFFF1744);
        dotIcon = Icons.warning_amber_rounded;
        dotSize = 10;
        shadows = [
          BoxShadow(
            color: const Color(0xFFFF1744).withValues(alpha: 0.3),
            blurRadius: 6,
          ),
        ];
        break;
      default:
        borderColor = Colors.blue;
        borderWidth = 3;
        radius = 8;
        dotColor = Colors.blue;
        shadows = null;
    }

    return Stack(children: [
      Container(
        decoration: BoxDecoration(
          border: Border.all(color: borderColor, width: borderWidth),
          borderRadius: BorderRadius.circular(radius),
          boxShadow: shadows,
        ),
        child: child,
      ),
      Positioned(
        top: 3,
        right: 3,
        child: Icon(dotIcon, size: dotSize, color: dotColor),
      ),
    ]);
  }

  // ========================================================
  // THEMED GRID CELLS HELPERS
  // ========================================================

  /// Resolve ON/OFF colors for the current DarknessStage.
  Color _themedOnColor(DarknessStage? stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return const Color(0xFF4CAF50);
      case DarknessStage.dieselpunk:
        return const Color(0xFFB8860B); // dark goldenrod
      case DarknessStage.cyberpunk:
        return const Color(0xFF00BFA5); // neon teal
      case DarknessStage.stalker:
        return const Color(0xFF1B5E20); // dark toxic green
      default:
        return Colors.green.shade400;
    }
  }

  Color _themedOffColor(DarknessStage? stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return const Color(0xFFBF360C); // warm terracotta
      case DarknessStage.dieselpunk:
        return const Color(0xFF4E342E); // dark soot/rust
      case DarknessStage.cyberpunk:
        return const Color(0xFFAD1457); // deep magenta
      case DarknessStage.stalker:
        return const Color(0xFF8B0000); // blood dark red
      default:
        return Colors.red.shade400;
    }
  }

  double _themedBorderRadius(DarknessStage? stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return 14;
      case DarknessStage.dieselpunk:
        return 4;
      case DarknessStage.cyberpunk:
        return 8;
      case DarknessStage.stalker:
        return 2;
      default:
        return 6;
    }
  }

  TextStyle _themedCellTextStyle(DarknessStage? stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          color: Colors.white,
          shadows: [
            Shadow(blurRadius: 2, color: Color(0x66000000)),
          ],
        );
      case DarknessStage.dieselpunk:
        return const TextStyle(
          fontWeight: FontWeight.w900,
          fontSize: 12,
          color: Color(0xFFFFD54F),
          letterSpacing: 0.5,
          shadows: [
            Shadow(blurRadius: 3, color: Color(0x88000000)),
          ],
        );
      case DarknessStage.cyberpunk:
        return const TextStyle(
          fontFamily: 'Courier',
          fontWeight: FontWeight.bold,
          fontSize: 13,
          color: Color(0xFF00FFFF),
          shadows: [
            Shadow(blurRadius: 4, color: Color(0xFF00FFFF)),
          ],
        );
      case DarknessStage.stalker:
        return const TextStyle(
          fontFamily: 'RobotoMono',
          fontWeight: FontWeight.bold,
          fontSize: 12,
          color: Color(0xFF39FF14),
          shadows: [
            Shadow(blurRadius: 2, color: Color(0xFF39FF00)),
            Shadow(blurRadius: 8, color: Colors.black),
          ],
        );
      default:
        return const TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          color: Colors.white,
        );
    }
  }

  void _showHourDetailTooltip(int hour) {
    if (_realHourSegments == null || hour >= _realHourSegments!.length) return;
    final segs = _realHourSegments![hour];

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text("Hour $hour Details"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: segs.map((s) {
              final startM = (s.start * 60).toInt();
              final endM = (s.end * 60).toInt();
              return ListTile(
                leading: CircleAvatar(backgroundColor: s.color, radius: 8),
                title: Text("${_fmtHM(hour, startM)} - ${_fmtHM(hour, endM)}"),
                subtitle: Text(s.isFuture ? "Forecast" : "Real Data"),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("Close"),
            ),
          ],
        );
      },
    );
  }

  String _fmtHM(int h, int m) {
    return "${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}";
  }

  void _showIntervalMenu(BuildContext context, dynamic interval) {
    // Placeholder for interval menu used in other modes
    // interval is likely IntervalInfo or similar
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Menu not implemented for this view")),
    );
  }
}

//End of _HomeScreenState

// --- PAINTERS & HELPERS ---

class _RenderSegment {
  final double start;
  final double end;
  final Color color;
  final bool isFuture;

  _RenderSegment(this.start, this.end, this.color, this.isFuture);
}

class _GridOverlayPainter extends CustomPainter {
  final Color color;
  _GridOverlayPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    const step = 6.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _ScanlinePainter extends CustomPainter {
  final Color color;
  _ScanlinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _ScanlinePainter old) => old.color != color;
}

class _DiagonalStripesPainter extends CustomPainter {
  final Color color;
  final double spacing;
  _DiagonalStripesPainter({required this.color, this.spacing = 10.0});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    for (double i = -size.height; i < size.width + size.height; i += spacing) {
      canvas.drawLine(
          Offset(i, 0), Offset(i + size.height, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DiagonalStripesPainter old) =>
      old.color != color || old.spacing != spacing;
}

class _NoisePainter extends CustomPainter {
  final int seed;
  _NoisePainter({required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(seed);
    final paint = Paint()..strokeWidth = 1;

    for (int i = 0; i < 100; i++) {
      paint.color = Colors.white.withValues(alpha: random.nextDouble() * 0.1);
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      canvas.drawPoints(PointMode.points, [Offset(x, y)], paint);
    }
  }

  @override
  bool shouldRepaint(covariant _NoisePainter old) => old.seed != seed;
}

class _SwitchModeIntent extends Intent {
  final DataSourceMode mode;
  const _SwitchModeIntent(this.mode);
}
