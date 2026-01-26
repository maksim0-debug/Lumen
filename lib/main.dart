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
import 'models/schedule_status.dart';
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
        
        try {
          await HistoryService().saveHistory(allSchedules);
        } catch (e) {
          print("[Background] Error saving history: $e");
        }
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
    final prefs = await SharedPreferences.getInstance();
    if (mounted) {
      setState(() {
        _isDarkMode = prefs.getBool('is_dark_mode') ?? true;
      });
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

class IntervalInfo {
  final String timeRange;
  final String statusText;
  final String duration;
  final Color color;

  IntervalInfo(this.timeRange, this.statusText, this.duration, this.color);
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

  @override
  void initState() {
    super.initState();
    if (Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray();
    }

    _loadPreferencesAndData();

    
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

  Future<void> _loadPreferencesAndData() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _currentGroup = prefs.getString('selected_group') ?? "GPV2.1";
      _notificationGroups = prefs.getStringList('notification_groups') ?? [];
    });
    _loadData();
  }

  Future<void> _changeGroup(String? newGroup) async {
    if (newGroup == null || newGroup == _currentGroup) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('selected_group', newGroup);

    
    
    List<String> notifGroups = prefs.getStringList('notification_groups') ?? [];
    if (notifGroups.isEmpty ||
        (notifGroups.length == 1 && notifGroups.contains(_currentGroup))) {
      await prefs.setStringList('notification_groups', [newGroup]);
      setState(() {
        _notificationGroups = [newGroup];
      });
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

      
      await HistoryService().saveHistory(allData);

      
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

        final updateTime = allData.values.first.lastUpdatedSource;
        _statusMessage = "Оновлено ДТЕК: $updateTime";
      });

      
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

              
              _notifier.showImmediate(
                  "Графік змінено ($group)!", msg,
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
                    final version = _historyVersions[index];
                    final isSelected = index == _selectedVersionIndex;
                    return ListTile(
                      leading: const Icon(Icons.history, color: Colors.orange),
                      title: Text(version.timeString,
                          style: const TextStyle(fontWeight: FontWeight.bold)),
                      subtitle: Text("(${version.outageString})"),
                      trailing: isSelected
                          ? const Icon(Icons.check, color: Colors.green)
                          : null,
                      onTap: () {
                        
                        final reversedIndex = _historyVersions.length - 1 - index;
                        _selectVersion(reversedIndex);
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
      lastDate: DateTime.now().subtract(
          const Duration(days: 0)), 
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

  void _updateNotificationsOnly() async {
    if (!Platform.isAndroid) return;

    final prefs = await SharedPreferences.getInstance();
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

    final intervals = _generateIntervals(currentDisplay);

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
            onPressed: () => _loadData(),
          ),
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
                        
                        _selectDateAndLoad();
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
                          
                          if (_allSchedules.isNotEmpty) {
                            final updateTime =
                                _allSchedules.values.first.lastUpdatedSource;
                            _statusMessage = "Оновлено ДТЕК: $updateTime";
                          }

                          
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
                        });
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
                          
                          if (_allSchedules.isNotEmpty) {
                            final updateTime =
                                _allSchedules.values.first.lastUpdatedSource;
                            _statusMessage = "Оновлено ДТЕК: $updateTime";
                          }
                        });
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
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
                          child: _buildGrid(currentDisplay, cols),
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
                                  return Container(
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
                                                    fontWeight: FontWeight.w500,
                                                    color: interval
                                                                .statusText ==
                                                            "OFF"
                                                        ? Colors
                                                            .red 
                                                        : (Theme.of(context)
                                                                    .brightness ==
                                                                Brightness.dark
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
                                                  fontWeight: FontWeight.bold)),
                                        ),
                                        const SizedBox(width: 8),
                                        
                                        Text("(${interval.duration})",
                                            style: const TextStyle(
                                                color: Colors.grey)),
                                      ],
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

  Widget _buildGrid(DailySchedule? schedule, int columns) {
    if (schedule == null || schedule.isEmpty) {
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
        final status = schedule.hours[index];
        final bool isCurrentHour =
            _viewMode == ScheduleViewMode.today && DateTime.now().hour == index;

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
}
