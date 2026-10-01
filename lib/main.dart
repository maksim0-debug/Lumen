import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:launch_at_startup/launch_at_startup.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:home_widget/home_widget.dart';

import 'package:path/path.dart' as p;

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
import 'services/countdown_service.dart';
import 'services/hour_segment_service.dart';
import 'models/schedule_status.dart';
import 'models/power_event.dart';
import 'models/hour_segment.dart';
import 'models/data_source_mode.dart';
import 'models/schedule_view_mode.dart';
import 'models/interval_info.dart';
import 'theme/darkness_stage_style.dart';
import 'ui/settings_page.dart';
import 'ui/analytics_screen.dart';
import 'ui/achievements_screen.dart';
import 'ui/widgets/theme_animated_cell.dart';

@pragma('vm:entry-point')
Future<void> backgroundCallback(Uri? uri) async {
  WidgetsFlutterBinding.ensureInitialized();
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
  AppLogger.i("ВЕРСІЯ ДОДАТКУ: 2.3.4 (Fix Saving & UI)", tag: 'MAIN');
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
  }

  // Не блокуємо рендеринг інтерфейсу запуском повільних нативних сервісів
  unawaited(_initBackgroundServices());

  runApp(const MyApp());
}

Future<void> _initBackgroundServices() async {
  if (Platform.isWindows) {
    try {
      final packageInfo =
          await PackageInfo.fromPlatform().timeout(const Duration(seconds: 3));

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
    await notificationService.init().timeout(const Duration(seconds: 4));
  } catch (e) {
    AppLogger.e("Помилка сповіщень", tag: 'MAIN', error: e);
  }

  if (Platform.isAndroid) {
    try {
      final bgManager = BackgroundManager();
      await bgManager.init().timeout(const Duration(seconds: 4));
      bgManager.registerPeriodicTask();
    } catch (e) {
      AppLogger.e("Помилка Background", tag: 'MAIN', error: e);
    }
  }
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

  @override
  void dispose() {
    _darknessThemeService.onStageChanged = null;
    super.dispose();
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
      final prefs = await PreferencesHelper.getSafeInstance();
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
      final prefs = await PreferencesHelper.getSafeInstance();
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

class CountdownCard extends StatefulWidget {
  final FullSchedule? fullSchedule;

  const CountdownCard({
    super.key,
    required this.fullSchedule,
  });

  @override
  State<CountdownCard> createState() => _CountdownCardState();
}

class _CountdownCardState extends State<CountdownCard> {
  Timer? _ticker;
  int _lastRenderedMinute = -1;

  @override
  void initState() {
    super.initState();
    _lastRenderedMinute = DateTime.now().minute;
    _scheduleNextMinuteTick();
  }

  void _scheduleNextMinuteTick() {
    _ticker?.cancel();
    final now = DateTime.now();
    final msToNextMinute = (60 - now.second) * 1000 - now.millisecond + 100;
    _ticker = Timer(Duration(milliseconds: msToNextMinute), () {
      if (mounted) {
        if (widget.fullSchedule != null) {
          final currentMinute = DateTime.now().minute;
          if (currentMinute != _lastRenderedMinute) {
            _lastRenderedMinute = currentMinute;
            setState(() {});
          }
        }
        _scheduleNextMinuteTick();
      }
    });
  }

  @override
  void didUpdateWidget(covariant CountdownCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fullSchedule != widget.fullSchedule) {
      _lastRenderedMinute = DateTime.now().minute;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fullSchedule == null) {
      return const SizedBox.shrink();
    }

    final countdown = CountdownService.calculateCountdown(
      today: widget.fullSchedule!.today,
      tomorrow: widget.fullSchedule!.tomorrow,
      now: DateTime.now(),
    );

    if (countdown == null) return const SizedBox.shrink();

    final msg = countdown.message;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final darknessService = DarknessThemeService();
    final stage =
        darknessService.isEnabled ? darknessService.currentStage : null;

    final style = DarknessStageStyle.of(stage).countdownStyle(isDark);

    final baseTextStyle = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.bold,
      color: style.textColor,
    );
    final finalTextStyle = style.extraStyle != null
        ? baseTextStyle.merge(style.extraStyle)
        : baseTextStyle;

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: style.containerColor,
          borderRadius: BorderRadius.circular(style.borderRadius),
          border: style.border,
          boxShadow: style.shadows,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, color: style.iconColor, size: 24),
            const SizedBox(width: 8),
            Text(msg, style: finalTextStyle),
          ],
        ),
      ),
    );
  }
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
  bool get _isHistoryMode =>
      _viewMode == ScheduleViewMode.history ||
      _viewMode == ScheduleViewMode.yesterday;
  DateTime? _historyDate;
  DailySchedule? _historySchedule;
  List<ScheduleVersion> _historyVersions = [];
  int _selectedVersionIndex = -1;

  int _lastAutoRefreshMinute = -1;
  int _lastRenderedMinute = -1;
  Timer? _timer;

  final Map<String, int> _lastUpdateOldStats = {};
  bool _wasUpdated = false;

  bool _isCachedData = false;
  Color _statusColor = Colors.grey;

  bool _isFetching = false;
  DateTime? _lastFetchTime;
  static const Duration _fetchCooldown = Duration(seconds: 30);

  static const bool _showNotificationTestButton = false;

  // --- Power Monitor ---
  final PowerMonitorService _powerMonitor = PowerMonitorService();
  DataSourceMode _dataSourceMode = DataSourceMode.predicted;
  bool _powerMonitorEnabled = false;
  List<PowerOutageInterval> _realOutageIntervals = [];
  String _powerStatus = 'unknown'; // 'online' / 'offline' / 'unknown'
  List<List<HourSegment>>? _realHourSegments;

  // --- Precomputed Display Data ---
  DailySchedule? _currentDisplaySchedule;
  List<IntervalInfo> _cachedIntervals = [];

  final AchievementService _achievementService = AchievementService();
  final FocusNode _focusNode = FocusNode();

  String _formatDateKey(DateTime dt) {
    return "${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}";
  }

  void _recalculateDisplayData() {
    final displayDate = _getDisplayDate();
    DailySchedule? currentDisplay;

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
    } else if (_viewMode == ScheduleViewMode.yesterday ||
        _viewMode == ScheduleViewMode.history) {
      currentDisplay = _historySchedule;
    }

    if (_powerMonitorEnabled && _dataSourceMode == DataSourceMode.real) {
      _currentDisplaySchedule = _buildRealScheduleFromIntervals(
        _realOutageIntervals,
        displayDate,
        baseSchedule: currentDisplay,
      );
      _cachedIntervals =
          _generateRealIntervals(_realOutageIntervals, displayDate);
      _realHourSegments = _computeAllHourSegments(
          _realOutageIntervals, displayDate,
          baseSchedule: currentDisplay);
    } else {
      _currentDisplaySchedule = currentDisplay;
      _cachedIntervals = _generateIntervals(currentDisplay);
      _realHourSegments = null;
    }
  }

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
    _schedulePeriodicUpdates();
  }

  void _schedulePeriodicUpdates() {
    _timer?.cancel();
    final now = DateTime.now();
    final msToNextMinute = (60 - now.second) * 1000 - now.millisecond + 100;
    _timer = Timer(Duration(milliseconds: msToNextMinute), () {
      if (!mounted) return;
      final current = DateTime.now();

      if (current.minute % 15 == 0 &&
          current.minute != _lastAutoRefreshMinute) {
        _lastAutoRefreshMinute = current.minute;
        _loadData(silent: true);
      }

      if (current.minute != _lastRenderedMinute) {
        _lastRenderedMinute = current.minute;
        setState(() {
          _recalculateDisplayData();
        });
      }
      _schedulePeriodicUpdates();
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
    if (!mounted) return;
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
    if (!mounted) return;

    _powerMonitorEnabled = prefs?.getBool('power_monitor_enabled') ?? false;

    _powerMonitor.onStatusChanged = (status) {
      if (mounted) {
        // Also reload the outage data so the list updates immediately
        _loadRealOutageData(_getDisplayDate()).then((_) {
          if (mounted) {
            setState(() {
              _powerStatus = status;
              _recalculateDisplayData();
            });
          }
          // Оновити стадію тьми при зміні статусу живлення
          DarknessThemeService().refresh();
        });
      }
    };

    if (_powerMonitorEnabled) {
      await _powerMonitor.init();
      if (!mounted) return;
      _powerStatus = _powerMonitor.currentStatus;
      await _loadRealOutageData(_getDisplayDate());
      if (mounted) {
        setState(() {
          _recalculateDisplayData();
        });
      }
    } else {
      _dataSourceMode = DataSourceMode.predicted;
      _powerStatus = 'unknown';
      if (mounted) {
        setState(() {
          _recalculateDisplayData();
        });
      }
    }
  }

  int _realOutageLoadRequestId = 0;

  Future<void> _loadRealOutageData(DateTime date) async {
    if (!_powerMonitorEnabled) return;
    final requestId = ++_realOutageLoadRequestId;
    final dateAtCall = date;
    try {
      final intervals = await _powerMonitor.getOutageIntervalsForDate(date);
      if (!mounted || requestId != _realOutageLoadRequestId) return;
      if (!DateUtils.isSameDay(dateAtCall, _getDisplayDate())) return;
      _realOutageIntervals = intervals;
    } catch (e) {
      AppLogger.e('Error loading real outage data', tag: 'Main', error: e);
      if (mounted &&
          requestId == _realOutageLoadRequestId &&
          DateUtils.isSameDay(dateAtCall, _getDisplayDate())) {
        _realOutageIntervals = [];
      }
    }
  }

  Future<void> _loadPreferencesAndData() async {
    SharedPreferences? prefs;
    try {
      prefs = await PreferencesHelper.getSafeInstance();
    } catch (e) {
      AppLogger.e("Error loading SharedPreferences", tag: 'Main', error: e);
      // If SharedPreferences is corrupt, we might want to let the app continue with defaults
      // or show an error. For now, just logging.
    }
    if (!mounted) return;

    final previousGroup = _currentGroup;
    bool groupChanged = false;

    if (prefs != null) {
      final p = prefs;
      final savedGroup = p.getString('selected_group') ?? "GPV2.1";
      final savedNotifGroups = p.getStringList('notification_groups') ?? [];
      groupChanged = savedGroup != previousGroup;

      setState(() {
        _currentGroup = savedGroup;
        _notificationGroups = savedNotifGroups;
      });
    }

    _updateNotificationsOnly();

    if (_isHistoryMode) {
      if (groupChanged) {
        final targetDate = _getDisplayDate();
        await _loadHistoryData(targetDate);
        if (!mounted) return;
      }
      await _loadData(silent: true);
    } else {
      if (groupChanged) {
        await _refreshVersionsForCurrentMode();
        if (!mounted) return;
        _updateStatusDate();
      }
      await _loadData(silent: false, force: groupChanged);
    }
  }

  Future<void> _changeGroup(String? newGroup) async {
    if (newGroup == null || newGroup == _currentGroup) return;

    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setString('selected_group', newGroup);

      List<String> notifGroups =
          prefs.getStringList('notification_groups') ?? [];
      if (notifGroups.isEmpty ||
          (notifGroups.length == 1 && notifGroups.contains(_currentGroup))) {
        await prefs.setStringList('notification_groups', [newGroup]);
        if (mounted) {
          setState(() {
            _notificationGroups = [newGroup];
          });
        }
      }
    } catch (e) {
      AppLogger.e("Error saving group preference", tag: 'Main', error: e);
    }
    if (!mounted) return;

    _wasUpdated = false;
    setState(() {
      _currentGroup = newGroup;
      _historyVersions = [];
      _selectedVersionIndex = -1;
      _historySchedule = null;
      _recalculateDisplayData();
    });
    // Трекер для ачівки "Громадянин"
    _achievementService.trackGroupChange();

    if (_viewMode == ScheduleViewMode.today ||
        _viewMode == ScheduleViewMode.tomorrow) {
      final now = DateTime.now();
      await _refreshVersionsForCurrentMode();
      if (!mounted) return;

      try {
        final prefs = await PreferencesHelper.getSafeInstance();
        if (_allSchedules.containsKey(newGroup)) {
          final schedule = _allSchedules[newGroup]!;
          final keyHash = "prev_hash_${newGroup}_today";
          final keyDate = "prev_date_${newGroup}_today";
          final todayStr = _formatDateKey(now);

          await prefs.setString(keyHash, schedule.today.scheduleHash);
          await prefs.setString(keyDate, todayStr);
        }
      } catch (e) {
        AppLogger.e("Error syncing hash", tag: 'Main', error: e);
      }
    } else if (_isHistoryMode) {
      final targetDate = _getDisplayDate();
      await _loadHistoryData(targetDate);
      if (!mounted) return;
    }

    _updateNotificationsOnly();
    _updateStatusDate();
    if (mounted) {
      setState(() {
        _recalculateDisplayData();
      });
    }
  }

  Future<void> _loadCachedData() async {
    try {
      final cached = await HistoryService().getLastKnownSchedules();
      if (cached.isNotEmpty && mounted) {
        _wasUpdated = false;
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
          _recalculateDisplayData();
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
    _achievementService.onAchievementUnlocked = null;
    _powerMonitor.onStatusChanged = null;
    super.dispose();
  }

  Future<void> _initTray() async {
    if (Platform.isWindows) {
      final exeDir = p.dirname(Platform.resolvedExecutable);
      final iconPath = p.join(exeDir, 'app_icon.ico');
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
    final groupAtCall = _currentGroup;
    final versions =
        await HistoryService().getVersionsForDate(targetDate, _currentGroup);
    if (!mounted) return;
    if (_currentGroup != groupAtCall) return;
    if (!DateUtils.isSameDay(targetDate, _getDisplayDate())) return;
    setState(() {
      _historyVersions = versions;
      if (_historyVersions.isNotEmpty) {
        _selectedVersionIndex = _historyVersions.length - 1;
        _historySchedule = _historyVersions.last.toSchedule();
      } else {
        _selectedVersionIndex = -1;
        _historySchedule = null;
      }
      _recalculateDisplayData();
    });
  }

  Future<void> _updateStatusDate() async {
    final now = DateTime.now();
    DateTime targetDate;
    if (_viewMode == ScheduleViewMode.today) {
      targetDate = DateTime(now.year, now.month, now.day);
    } else if (_viewMode == ScheduleViewMode.tomorrow) {
      targetDate = DateTime(now.year, now.month, now.day + 1);
    } else {
      return;
    }

    final dateStr = _formatDateKey(targetDate);
    final updateTime = await HistoryService().getLatestUpdatedAt(
      groupKey: _currentGroup,
      targetDate: dateStr,
    );

    if (mounted) {
      String msg = "Оновлено ДТЕК: Невідомо";
      Color color = Colors.grey;

      if (_historyVersions.isNotEmpty) {
        final version = (_selectedVersionIndex >= 0 &&
                _selectedVersionIndex < _historyVersions.length)
            ? _historyVersions[_selectedVersionIndex]
            : _historyVersions.last;
        msg = "Оновлено ДТЕК: ${version.timeString}";
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

  Future<void> _loadData({bool silent = false, bool force = false}) async {
    if (_isFetching) {
      AppLogger.d("⏳ Fetch already in progress, skipping duplicate request",
          tag: 'Main');
      return;
    }

    if (!force &&
        _allSchedules.isNotEmpty &&
        _lastFetchTime != null &&
        DateTime.now().difference(_lastFetchTime!) < _fetchCooldown) {
      AppLogger.d("⏳ Data is fresh (cooldown active), skipping fetch",
          tag: 'Main');
      if (!silent && !_isHistoryMode) {
        _updateStatusDate();
        if (_isLoading && mounted) {
          setState(() => _isLoading = false);
        }
      }
      return;
    }

    _isFetching = true;

    try {
      if (!silent) {
        // First, try to load from cache if we are empty
        if (_allSchedules.isEmpty) {
          await _loadCachedData();
          if (!mounted) return;
        }

        if (mounted && !_isHistoryMode) {
          setState(() {
            if (_allSchedules.isEmpty) {
              _isLoading = true; // Show spinner only if no data at all
            }
            _statusMessage = _isCachedData
                ? "Оновлення... (показано архів)"
                : "Оновлення...";
            _statusColor = Colors.orange;
          });
        }
      }
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

      _lastFetchTime = DateTime.now();

      if (mounted) {
        final currentIsHistory = _isHistoryMode;
        setState(() {
          _allSchedules = allData;
          _isCachedData = false;
          _wasUpdated = true;
          if (!currentIsHistory) {
            _isLoading = false;
            _statusColor = Colors.green;
          }
          _recalculateDisplayData();
        });

        if (!currentIsHistory) {
          await _refreshVersionsForCurrentMode();
          if (mounted) _updateStatusDate();
        }
      }

      try {
        final prefs = await PreferencesHelper.getSafeInstance();
        final notifyChange = prefs.getBool('notify_schedule_change') ?? true;
        final now = DateTime.now();

        final groupsToCheck = <String>{..._notificationGroups, _currentGroup};

        for (final group in groupsToCheck) {
          if (!allData.containsKey(group)) continue;

          final schedule = allData[group]!;
          final keyHash = "prev_hash_${group}_today";
          final keyDate = "prev_date_${group}_today";
          final todayStr = _formatDateKey(now);

          final oldHash = prefs.getString(keyHash);
          final savedDate = prefs.getString(keyDate);
          final newHash = schedule.today.scheduleHash;

          if (notifyChange &&
              savedDate == todayStr &&
              oldHash != null &&
              oldHash != newHash) {
            if (Platform.isWindows) {
              final newMinutes = schedule.today.totalOutageMinutes;
              final oldMinutes =
                  DailySchedule.fromEncodedString(oldHash).totalOutageMinutes;

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
        if (!_isHistoryMode) {
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
      }
      AppLogger.e("Error loading data", tag: 'Main', error: e);
    } finally {
      _isFetching = false;
    }
  }

  int _historyLoadRequestId = 0;

  Future<void> _loadHistoryData(DateTime date) async {
    final requestId = ++_historyLoadRequestId;
    final groupAtCall = _currentGroup;
    final dateAtCall = date;
    setState(() {
      _isLoading = true;
      _statusMessage = "Завантаження архіву...";
      _historyVersions = [];
      _selectedVersionIndex = -1;
    });

    try {
      final versions =
          await HistoryService().getVersionsForDate(date, _currentGroup);
      if (!mounted || requestId != _historyLoadRequestId) return;
      if (_currentGroup != groupAtCall) return;
      if (!DateUtils.isSameDay(dateAtCall, _getDisplayDate())) return;

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
        _recalculateDisplayData();
      });
    } catch (e) {
      if (mounted &&
          requestId == _historyLoadRequestId &&
          _currentGroup == groupAtCall &&
          DateUtils.isSameDay(dateAtCall, _getDisplayDate())) {
        setState(() {
          _isLoading = false;
          _historySchedule = null;
          _historyVersions = [];
          _selectedVersionIndex = -1;
          _statusMessage = "Помилка завантаження архіву";
          _recalculateDisplayData();
        });
      }
    }
  }

  String _pluralVersions(int count) {
    final mod10 = count % 10;
    final mod100 = count % 100;
    if (mod100 >= 11 && mod100 <= 14) return "версій";
    if (mod10 == 1) return "версія";
    if (mod10 >= 2 && mod10 <= 4) return "версії";
    return "версій";
  }

  void _selectVersion(int index) {
    if (index < 0 || index >= _historyVersions.length) return;
    setState(() {
      _selectedVersionIndex = index;
      _historySchedule = _historyVersions[index].toSchedule();
      if (!_isHistoryMode) {
        _statusMessage = "Оновлено ДТЕК: ${_historyVersions[index].timeString}";
      }
      _recalculateDisplayData();
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
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final firstAllowed = DateTime(2024);
    DateTime defaultInitial =
        _historyDate ?? DateTime(now.year, now.month, now.day - 2);
    if (defaultInitial.isAfter(today)) {
      defaultInitial = today;
    }
    if (defaultInitial.isBefore(firstAllowed)) {
      defaultInitial = firstAllowed;
    }

    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: defaultInitial,
      firstDate: firstAllowed,
      lastDate: today,
      locale: const Locale("uk", "UA"),
    );
    if (picked != null) {
      _wasUpdated = false;
      setState(() {
        _viewMode = ScheduleViewMode.history;
        _historyDate = picked;
        _historyVersions = [];
        _selectedVersionIndex = -1;
        _historySchedule = null;
        _recalculateDisplayData();
      });
      await _loadHistoryData(picked);
      if (!mounted) return;
      // Трекер для ачівки "Архіваріус"
      _achievementService.trackHistoryView(picked);
    } else {
      if (_viewMode == ScheduleViewMode.history && _historyDate == null) {
        setState(() {
          _viewMode = ScheduleViewMode.today;
          _historyVersions = [];
          _selectedVersionIndex = -1;
          _historySchedule = null;
          _recalculateDisplayData();
        });
      }
    }
  }

  int _calculateOutageMinutes(DailySchedule schedule) {
    return schedule.totalOutageMinutes;
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
    return HourSegmentService.computeRealOutageMinutes(intervals, date);
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
    return schedule.toSlots();
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
      List<PowerOutageInterval> intervals, DateTime date,
      {DailySchedule? baseSchedule}) {
    DailySchedule? forecast = baseSchedule;
    if (forecast == null || forecast.isEmpty) {
      final now = DateTime.now();
      final isToday = date.year == now.year &&
          date.month == now.month &&
          date.day == now.day;
      if (_allSchedules.containsKey(_currentGroup)) {
        if (isToday) {
          forecast = _allSchedules[_currentGroup]!.today;
        } else {
          final tomorrow = DateTime.now().add(const Duration(days: 1));
          if (date.year == tomorrow.year &&
              date.month == tomorrow.month &&
              date.day == tomorrow.day) {
            forecast = _allSchedules[_currentGroup]!.tomorrow;
          }
        }
      }
    }
    return HourSegmentService.computeAllHourSegments(intervals, date,
        forecast: forecast);
  }

  List<IntervalInfo> _generateRealIntervals(
      List<PowerOutageInterval> intervals, DateTime date) {
    final dayStart = DateTime(date.year, date.month, date.day);
    final dayEnd = dayStart.add(const Duration(days: 1));
    final now = DateTime.now();

    List<IntervalInfo> result = [];
    DateTime cursor = dayStart;

    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;

    // Если интервалов нет вообще
    if (intervals.isEmpty) {
      if (isToday && _powerMonitor.isOffline) {
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
                _setDataSourceMode(DataSourceMode.predicted);
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
                _setDataSourceMode(DataSourceMode.real);
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
    final now = DateTime.now();
    if (_viewMode == ScheduleViewMode.today) {
      return DateTime(now.year, now.month, now.day);
    }
    if (_viewMode == ScheduleViewMode.tomorrow) {
      return DateTime(now.year, now.month, now.day + 1);
    }
    if (_viewMode == ScheduleViewMode.yesterday) {
      return DateTime(now.year, now.month, now.day - 1);
    }
    return _historyDate ?? DateTime(now.year, now.month, now.day);
  }

  void _setDataSourceMode(DataSourceMode mode) async {
    if (!_powerMonitorEnabled) return;
    if (_dataSourceMode == mode) return;

    setState(() {
      _dataSourceMode = mode;
      _recalculateDisplayData();
    });
    if (mode == DataSourceMode.real) {
      await _loadRealOutageData(_getDisplayDate());
      if (mounted) {
        setState(() {
          _recalculateDisplayData();
        });
      }
    }
  }

  bool get _isAtEarliestDate {
    final displayDate = _getDisplayDate();
    final firstAllowed = DateTime(2024);
    return displayDate.isBefore(firstAllowed) ||
        DateUtils.isSameDay(displayDate, firstAllowed);
  }

  Future<void> _navigateDate(int offset) async {
    if (offset == 0) return;

    final now = DateTime.now();
    final firstAllowed = DateTime(2024);
    DateTime current;
    switch (_viewMode) {
      case ScheduleViewMode.today:
        current = DateTime(now.year, now.month, now.day);
        break;
      case ScheduleViewMode.yesterday:
        current = DateTime(now.year, now.month, now.day - 1);
        break;
      case ScheduleViewMode.tomorrow:
        current = DateTime(now.year, now.month, now.day + 1);
        break;
      case ScheduleViewMode.history:
        current = _historyDate ?? DateTime(now.year, now.month, now.day - 2);
        break;
    }

    final newDate = DateTime(current.year, current.month, current.day + offset);
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);

    if (offset > 0 &&
        (_viewMode == ScheduleViewMode.tomorrow || newDate.isAfter(tomorrow))) {
      return;
    }
    if (offset < 0 && (newDate.isBefore(firstAllowed) || _isAtEarliestDate)) {
      return;
    }

    _wasUpdated = false;

    if (DateUtils.isSameDay(newDate, today)) {
      setState(() {
        _viewMode = ScheduleViewMode.today;
        _historyVersions = [];
        _selectedVersionIndex = -1;
        _historySchedule = null;
        _recalculateDisplayData();
      });
      await _refreshVersionsForCurrentMode();
      if (!mounted) return;
      _updateStatusDate();

      if (_dataSourceMode == DataSourceMode.real) {
        await _loadRealOutageData(newDate);
        if (mounted) setState(() => _recalculateDisplayData());
      }
    } else if (DateUtils.isSameDay(newDate, yesterday)) {
      setState(() {
        _viewMode = ScheduleViewMode.yesterday;
        _historyDate = newDate;
        _historyVersions = [];
        _selectedVersionIndex = -1;
        _historySchedule = null;
        _recalculateDisplayData();
      });
      await _loadHistoryData(newDate);
      if (!mounted) return;
      if (_dataSourceMode == DataSourceMode.real) {
        await _loadRealOutageData(newDate);
        if (mounted) setState(() => _recalculateDisplayData());
      }
    } else if (DateUtils.isSameDay(newDate, tomorrow)) {
      setState(() {
        _viewMode = ScheduleViewMode.tomorrow;
        _historyVersions = [];
        _selectedVersionIndex = -1;
        _historySchedule = null;
        _recalculateDisplayData();
      });
      await _refreshVersionsForCurrentMode();
      if (!mounted) return;
      _updateStatusDate();

      if (_dataSourceMode == DataSourceMode.real) {
        await _loadRealOutageData(newDate);
        if (mounted) setState(() => _recalculateDisplayData());
      }
    } else {
      setState(() {
        _viewMode = ScheduleViewMode.history;
        _historyDate = newDate;
        _historyVersions = [];
        _selectedVersionIndex = -1;
        _historySchedule = null;
        _recalculateDisplayData();
      });
      await _loadHistoryData(newDate);
      if (!mounted) return;
      if (_dataSourceMode == DataSourceMode.real) {
        await _loadRealOutageData(newDate);
        if (mounted) setState(() => _recalculateDisplayData());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final screenWidth = MediaQuery.of(context).size.width;
    final int cols = screenWidth > 800 ? 8 : (screenWidth > 600 ? 6 : 4);

    final currentDisplay = _currentDisplaySchedule;
    final intervals = _cachedIntervals;

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
                onPressed: () async {
                  if (_isHistoryMode) {
                    final targetDate = _getDisplayDate();
                    await _loadHistoryData(targetDate);
                  } else {
                    await _loadData(force: true);
                  }
                  if (_powerMonitorEnabled) {
                    _powerMonitor.forceRefresh();
                    if (_dataSourceMode == DataSourceMode.real) {
                      await _loadRealOutageData(_getDisplayDate());
                      if (mounted) setState(() => _recalculateDisplayData());
                    }
                  }
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
                  if (!mounted) return;
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
                              color: _isAtEarliestDate
                                  ? (Theme.of(context)
                                              .textTheme
                                              .titleLarge
                                              ?.color ??
                                          Colors.white)
                                      .withValues(alpha: 0.3)
                                  : (Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.color ??
                                      Colors.white),
                            ),
                            onPressed: _isAtEarliestDate
                                ? null
                                : () => _navigateDate(-1),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
                            child: ChoiceChip(
                              label: const Text('Минуле'),
                              selected: _viewMode == ScheduleViewMode.history,
                              onSelected: (bool selected) async {
                                await _selectDateAndLoad();
                                if (!mounted) return;
                                if (_dataSourceMode == DataSourceMode.real) {
                                  await _loadRealOutageData(_getDisplayDate());
                                  if (mounted) {
                                    setState(() => _recalculateDisplayData());
                                  }
                                }
                              },
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 4.0),
                            child: ChoiceChip(
                              label: const Text('Вчора'),
                              selected: _viewMode == ScheduleViewMode.yesterday,
                              onSelected: (bool selected) async {
                                if (selected) {
                                  final now = DateTime.now();
                                  final yDate = DateTime(
                                      now.year, now.month, now.day - 1);
                                  _wasUpdated = false;
                                  setState(() {
                                    _viewMode = ScheduleViewMode.yesterday;
                                    _historyDate = yDate;
                                    _historyVersions = [];
                                    _selectedVersionIndex = -1;
                                    _historySchedule = null;
                                    _recalculateDisplayData();
                                  });
                                  await _loadHistoryData(yDate);
                                  if (!mounted) return;
                                  if (_dataSourceMode == DataSourceMode.real) {
                                    await _loadRealOutageData(yDate);
                                    if (mounted) {
                                      setState(() => _recalculateDisplayData());
                                    }
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
                              onSelected: (bool selected) async {
                                if (selected &&
                                    _viewMode != ScheduleViewMode.today) {
                                  _wasUpdated = false;
                                  setState(() {
                                    _viewMode = ScheduleViewMode.today;
                                    _historyVersions = [];
                                    _selectedVersionIndex = -1;
                                    _historySchedule = null;
                                    _recalculateDisplayData();
                                  });
                                  await _refreshVersionsForCurrentMode();
                                  if (!mounted) return;
                                  _updateStatusDate();
                                  if (_dataSourceMode == DataSourceMode.real) {
                                    await _loadRealOutageData(DateTime.now());
                                    if (mounted) {
                                      setState(() => _recalculateDisplayData());
                                    }
                                  }
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
                              onSelected: (bool selected) async {
                                if (selected &&
                                    _viewMode != ScheduleViewMode.tomorrow) {
                                  final now = DateTime.now();
                                  final tDate = DateTime(
                                      now.year, now.month, now.day + 1);
                                  _wasUpdated = false;
                                  setState(() {
                                    _viewMode = ScheduleViewMode.tomorrow;
                                    _historyVersions = [];
                                    _selectedVersionIndex = -1;
                                    _historySchedule = null;
                                    _recalculateDisplayData();
                                  });
                                  await _refreshVersionsForCurrentMode();
                                  if (!mounted) return;
                                  _updateStatusDate();
                                  if (_dataSourceMode == DataSourceMode.real) {
                                    await _loadRealOutageData(tDate);
                                    if (mounted) {
                                      setState(() => _recalculateDisplayData());
                                    }
                                  }
                                }
                              },
                            ),
                          ),
                          IconButton(
                            icon: DarknessThemeService().buildArrowIcon(
                              forward: true,
                              color: _viewMode == ScheduleViewMode.tomorrow
                                  ? (Theme.of(context)
                                              .textTheme
                                              .titleLarge
                                              ?.color ??
                                          Colors.white)
                                      .withValues(alpha: 0.3)
                                  : (Theme.of(context)
                                          .textTheme
                                          .titleLarge
                                          ?.color ??
                                      Colors.white),
                            ),
                            onPressed: _viewMode == ScheduleViewMode.tomorrow
                                ? null
                                : () => _navigateDate(1),
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
                    if (_viewMode == ScheduleViewMode.today) ...[
                      const SizedBox(height: 8),
                      CountdownCard(
                        fullSchedule: _allSchedules[_currentGroup],
                      ),
                    ],
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
                              if (_isHistoryMode) {
                                final targetDate = _getDisplayDate();
                                await _loadHistoryData(targetDate);
                              } else {
                                await _loadData(silent: true, force: true);
                              }
                              if (_powerMonitorEnabled &&
                                  _dataSourceMode == DataSourceMode.real) {
                                _powerMonitor.forceRefresh();
                                await _loadRealOutageData(_getDisplayDate());
                                if (mounted) {
                                  setState(() => _recalculateDisplayData());
                                }
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
          if (_isHistoryMode) {
            final targetDate = _getDisplayDate();
            await _loadHistoryData(targetDate);
          } else {
            await _loadData(silent: true, force: true);
          }
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
    final stageStyle = DarknessStageStyle.of(stage);
    final textStyle = stageStyle.cellTextStyle;
    final nowLineColor = stageStyle.nowLineColor;

    // Build timeline segments
    Widget timeline = LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth;
      List<Widget> children = [];

      for (final segment in segments) {
        // Handle split for current hour
        double start = segment.startFraction;
        double end = segment.endFraction;

        List<_RenderSegment> distinctParts = [];

        if (isCurrentHour) {
          // 1. Part before NOW (Past/Fact)
          if (start < nowFraction) {
            final effectiveEnd = end < nowFraction ? end : nowFraction;
            distinctParts.add(_RenderSegment(
                start, effectiveEnd, segment.color, false,
                status: segment.status));
          }
          // 2. Part after NOW (Future/Forecast)
          if (end > nowFraction) {
            final effectiveStart = start > nowFraction ? start : nowFraction;
            distinctParts.add(_RenderSegment(
                effectiveStart, end, segment.color, true,
                status: segment.status));
          }
        } else {
          bool isFuture = false;
          if (_viewMode == ScheduleViewMode.today) {
            if (hour > now.hour) isFuture = true;
          } else if (_viewMode == ScheduleViewMode.tomorrow) {
            isFuture = true;
          } else if (_viewMode == ScheduleViewMode.yesterday ||
              _viewMode == ScheduleViewMode.history) {
            isFuture = false;
          }

          distinctParts.add(_RenderSegment(start, end, segment.color, isFuture,
              status: segment.status));
        }

        for (final part in distinctParts) {
          final w = (part.end - part.start) * totalWidth;
          if (w < 0.5) continue;

          leftOffset() => part.start * totalWidth;

          final isSegmentOn = part.isOn;
          final themeColor = isSegmentOn
              ? stageStyle.onColor
              : (part.status == LightStatus.maybe
                  ? Colors.grey.shade500
                  : (part.status == LightStatus.unknown
                      ? Colors.grey.shade700
                      : stageStyle.offColor));

          final segResult = stageStyle.segmentDecoration(
            isFuture: part.isFuture,
            isSegmentOn: isSegmentOn,
            themeColor: themeColor,
            seed: hour * 100 + (part.start * 100).toInt(),
          );

          Widget segmentWidget = Container(
              decoration: segResult.decoration, child: segResult.overlay);

          // Overlays for Fact parts (Diesel stripes OFF etc)
          if (!part.isFuture) {
            List<Widget> extras = [segmentWidget];
            // Dieselpunk: diagonal stripes for OFF FACT
            if (stage == DarknessStage.dieselpunk && !isSegmentOn) {
              extras.add(Positioned.fill(
                child: ClipRect(
                  child: CustomPaint(
                    painter: DiagonalStripesPainter(
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
                  painter: ScanlinePainter(
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

    final BoxDecoration containerDecoration = stageStyle.emptyBoxDecoration();

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
    final style = DarknessStageStyle.of(stage);
    final color = isOn ? style.onColor : style.offColor;
    final radius = style.borderRadius;
    final textStyle = style.cellTextStyle;
    final iconStyle = style.cellIcon(isOn);
    final decoration = style.colorBoxDecoration(isOn, color);

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
          if (iconStyle.icon != null)
            Positioned(
              right: 3,
              bottom: 2,
              child: Icon(iconStyle.icon,
                  size: 16, color: iconStyle.color ?? Colors.white24),
            ),
          // Stalker scanline overlay for OFF cells
          if (stage == DarknessStage.stalker && !isOn)
            Positioned.fill(
              child: CustomPaint(
                painter: ScanlinePainter(
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
                  painter: DiagonalStripesPainter(
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
    final style = DarknessStageStyle.of(stage);
    final onColor = style.onColor;
    final offColor = style.offColor;
    final radius = style.borderRadius;
    final textStyle = style.cellTextStyle;
    final colors = isSemiOn ? [offColor, onColor] : [onColor, offColor];

    final iconOff = style.cellIcon(false);
    final iconOn = style.cellIcon(true);
    final iconLeft = isSemiOn ? iconOff.icon : iconOn.icon;
    final iconColorLeft = isSemiOn ? iconOff.color : iconOn.color;
    final iconRight = isSemiOn ? iconOn.icon : iconOff.icon;
    final iconColorRight = isSemiOn ? iconOn.color : iconOff.color;

    final decoration = style.gradientBoxDecoration(isSemiOn, colors, onColor);

    String displayText = text;
    if (stage == DarknessStage.solarpunk ||
        stage == DarknessStage.dieselpunk ||
        stage == DarknessStage.cyberpunk ||
        stage == null) {
      displayText = isSemiOn ? '$text ⚡' : text;
    } else if (stage == DarknessStage.stalker) {
      displayText = isSemiOn ? '$text ?' : text;
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
              child: Icon(iconLeft,
                  size: 14, color: iconColorLeft ?? Colors.white24),
            ),
          if (iconRight != null)
            Positioned(
              right: 4,
              bottom: 4,
              child: Icon(iconRight,
                  size: 14, color: iconColorRight ?? Colors.white24),
            ),

          if (stage == DarknessStage.stalker)
            Positioned.fill(
              child: CustomPaint(
                painter: ScanlinePainter(
                  color: const Color(0xFFFFD600).withValues(alpha: 0.04),
                ),
              ),
            ),
          if (stage == DarknessStage.stalker)
            Positioned(
              right: 3,
              bottom: 2,
              child: Icon(
                iconRight ?? Icons.help_outline,
                size: 12,
                color: iconColorRight ?? Colors.white24,
              ),
            ),

          // 2) Dieselpunk: diagonal stripes for semiOff (right half is OFF)
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
                        painter: DiagonalStripesPainter(
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
                        painter: DiagonalStripesPainter(
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
    final style = DarknessStageStyle.of(stage);
    final textStyle = style.cellTextStyle;
    final decoration = style.maybeBoxDecoration();

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
    final style = DarknessStageStyle.of(stage).currentHourStyle();
    return Stack(children: [
      Container(
        decoration: BoxDecoration(
          border:
              Border.all(color: style.borderColor, width: style.borderWidth),
          borderRadius: BorderRadius.circular(style.radius),
          boxShadow: style.shadows,
        ),
        child: child,
      ),
      Positioned(
        top: 3,
        right: 3,
        child: Icon(style.dotIcon, size: style.dotSize, color: style.dotColor),
      ),
    ]);
  }

  void _showHourDetailTooltip(int hour) {
    if (_realHourSegments == null || hour >= _realHourSegments!.length) return;
    final segs = _realHourSegments![hour];

    showDialog(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: Text("Деталі за $hour:00"),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: segs.map((s) {
              final startM = (s.start * 60).toInt();
              final endM = (s.end * 60).toInt();
              return ListTile(
                leading: CircleAvatar(backgroundColor: s.color, radius: 8),
                title: Text("${_fmtHM(hour, startM)} - ${_fmtHM(hour, endM)}"),
                subtitle: Text(s.isFuture ? "Прогноз" : "Фактичні дані"),
              );
            }).toList(),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text("Закрити"),
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
      const SnackBar(content: Text("Меню не підтримується для цього режиму")),
    );
  }
}

//End of _HomeScreenState

// --- HELPERS ---

class _RenderSegment {
  final double start;
  final double end;
  final Color color;
  final bool isFuture;
  final LightStatus status;

  _RenderSegment(this.start, this.end, this.color, this.isFuture,
      {this.status = LightStatus.unknown});

  bool get isOn => status == LightStatus.on;
}

class _SwitchModeIntent extends Intent {
  final DataSourceMode mode;
  const _SwitchModeIntent(this.mode);
}
