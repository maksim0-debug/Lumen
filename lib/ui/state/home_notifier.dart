import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/data_source_mode.dart';
import '../../models/hour_segment.dart';
import '../../models/power_event.dart';
import '../../models/schedule_status.dart';
import '../../models/schedule_view_mode.dart';
import '../../services/achievement_service.dart';
import '../../services/app_logger.dart';
import '../../services/darkness_theme_service.dart';
import '../../services/fcm_service.dart';
import '../../services/history_service.dart';
import '../../services/hour_segment_service.dart';
import '../../services/notification_service.dart';
import '../../services/parser_service.dart';
import '../../services/power_monitor_service.dart';
import '../../services/preferences_helper.dart';
import '../../services/schedule_calculation_service.dart';
import '../../services/schedule_notification_coordinator.dart';
import '../../services/schedule_sync_service.dart';
import '../../utils/app_formatters.dart';
import 'home_state.dart';

export 'home_state.dart';

class HomeNotifier extends Notifier<HomeState> {
  final NotificationService? _customNotifier;
  final ScheduleNotificationCoordinator? _customScheduleNotificationCoordinator;
  final ScheduleSyncService? _customScheduleSyncService;
  final PowerMonitorService? _customPowerMonitor;
  final AchievementService? _customAchievementService;

  HomeNotifier({
    NotificationService? notifier,
    ScheduleNotificationCoordinator? scheduleNotificationCoordinator,
    ScheduleSyncService? scheduleSyncService,
    PowerMonitorService? powerMonitor,
    AchievementService? achievementService,
  })  : _customNotifier = notifier,
        _customScheduleNotificationCoordinator =
            scheduleNotificationCoordinator,
        _customScheduleSyncService = scheduleSyncService,
        _customPowerMonitor = powerMonitor,
        _customAchievementService = achievementService;

  late final NotificationService _notifier;
  late final ScheduleNotificationCoordinator _scheduleNotificationCoordinator;
  late final ScheduleSyncService _scheduleSyncService;
  late final PowerMonitorService _powerMonitor;
  late final AchievementService _achievementService;

  int _realOutageLoadRequestId = 0;
  int _historyLoadRequestId = 0;

  StreamSubscription? _fcmSubscription;

  @override
  HomeState build() {
    _notifier = _customNotifier ?? NotificationService();
    _scheduleNotificationCoordinator = _customScheduleNotificationCoordinator ??
        ScheduleNotificationCoordinator(notifier: _notifier);
    _scheduleSyncService = _customScheduleSyncService ?? ScheduleSyncService();
    _powerMonitor = _customPowerMonitor ?? PowerMonitorService();
    _achievementService = _customAchievementService ?? AchievementService();

    _fcmSubscription = FcmService.onMessageStream.listen((message) {
      if (!ref.mounted) return;
      AppLogger.i(
          "🔄 FCM оновлення отримано у foreground. Оновлюємо розклад...",
          tag: 'HomeNotifier');
      if (!state.isHistoryMode) {
        loadData(force: true);
      }
    });

    ref.onDispose(() {
      _powerMonitor.onStatusChanged = null;
      _fcmSubscription?.cancel();
    });

    return const HomeState();
  }

  PowerMonitorService get powerMonitor => _powerMonitor;
  NotificationService get notifier => _notifier;
  AchievementService get achievementService => _achievementService;

  // --- RECALCULATE DISPLAY DATA ---
  void recalculateDisplayData() {
    final displayDate = state.displayDate;
    DailySchedule? currentDisplay;

    if (state.viewMode == ScheduleViewMode.today) {
      if (state.historyVersions.isNotEmpty &&
          state.selectedVersionIndex >= 0 &&
          state.historySchedule != null) {
        currentDisplay = state.historySchedule;
      } else {
        currentDisplay = state.allSchedules[state.currentGroup]?.today;
      }
    } else if (state.viewMode == ScheduleViewMode.tomorrow) {
      if (state.historyVersions.isNotEmpty &&
          state.selectedVersionIndex >= 0 &&
          state.historySchedule != null) {
        currentDisplay = state.historySchedule;
      } else {
        currentDisplay = state.allSchedules[state.currentGroup]?.tomorrow;
      }
    } else if (state.viewMode == ScheduleViewMode.yesterday ||
        state.viewMode == ScheduleViewMode.history) {
      currentDisplay = state.historySchedule;
    }

    if (state.powerMonitorEnabled &&
        state.dataSourceMode == DataSourceMode.real) {
      final realSchedule =
          ScheduleCalculationService.buildRealScheduleFromIntervals(
        state.realOutageIntervals,
        displayDate,
        baseSchedule: currentDisplay,
      );
      final now = DateTime.now();
      final isFuture = !DateUtils.isSameDay(displayDate, now) &&
          DateTime(displayDate.year, displayDate.month, displayDate.day)
              .isAfter(DateTime(now.year, now.month, now.day));
      final cachedIntervals = isFuture
          ? ScheduleCalculationService.generateIntervals(currentDisplay)
          : ScheduleCalculationService.generateRealIntervals(
              state.realOutageIntervals,
              displayDate,
              isOffline: _powerMonitor.isOffline,
              baseSchedule: currentDisplay,
            );
      final realHourSegments = _computeAllHourSegments(
        state.realOutageIntervals,
        displayDate,
        baseSchedule: currentDisplay,
      );
      state = state.copyWith(
        currentDisplaySchedule: realSchedule,
        cachedIntervals: cachedIntervals,
        realHourSegments: realHourSegments,
        isRealSourceConfigured: _powerMonitor.isSourceConfigured,
      );
    } else {
      final cachedIntervals =
          ScheduleCalculationService.generateIntervals(currentDisplay);
      state = state.copyWith(
        currentDisplaySchedule: currentDisplay,
        clearCurrentDisplaySchedule: currentDisplay == null,
        cachedIntervals: cachedIntervals,
        clearRealHourSegments: true,
        isRealSourceConfigured: _powerMonitor.isSourceConfigured,
      );
    }
  }

  List<List<HourSegment>> _computeAllHourSegments(
    List<PowerOutageInterval> intervals,
    DateTime date, {
    DailySchedule? baseSchedule,
  }) {
    DailySchedule? forecast = baseSchedule;
    if (forecast == null || forecast.isEmpty) {
      final now = DateTime.now();
      final isToday = date.year == now.year &&
          date.month == now.month &&
          date.day == now.day;
      if (state.allSchedules.containsKey(state.currentGroup)) {
        if (isToday) {
          forecast = state.allSchedules[state.currentGroup]!.today;
        } else {
          final tomorrow = DateTime.now().add(const Duration(days: 1));
          if (date.year == tomorrow.year &&
              date.month == tomorrow.month &&
              date.day == tomorrow.day) {
            forecast = state.allSchedules[state.currentGroup]!.tomorrow;
          }
        }
      }
    }
    return HourSegmentService.computeAllHourSegments(intervals, date,
        forecast: forecast);
  }

  // --- 1. CHANGE GROUP ---
  Future<void> changeGroup(String? newGroup) async {
    if (newGroup == null || newGroup == state.currentGroup) return;

    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.setString('selected_group', newGroup);

      List<String> notifGroups =
          prefs.getStringList('notification_groups') ?? [];
      if (notifGroups.isEmpty ||
          (notifGroups.length == 1 &&
              notifGroups.contains(state.currentGroup))) {
        await prefs.setStringList('notification_groups', [newGroup]);
        state = state.copyWith(notificationGroups: [newGroup]);
      }
      unawaited(FcmService().syncTopicSubscriptions());
    } catch (e) {
      AppLogger.e("Error saving group preference", tag: 'Main', error: e);
    }
    if (!ref.mounted) return;

    state = state.copyWith(
      currentGroup: newGroup,
      historyVersions: const [],
      selectedVersionIndex: -1,
      clearHistorySchedule: true,
      wasUpdated: false,
    );
    recalculateDisplayData();

    // Трекер для ачівки "Громадянин"
    _achievementService.trackGroupChange();

    if (state.viewMode == ScheduleViewMode.today ||
        state.viewMode == ScheduleViewMode.tomorrow) {
      final now = DateTime.now();
      await refreshVersionsForCurrentMode();
      if (!ref.mounted) return;

      try {
        final prefs = await PreferencesHelper.getSafeInstance();
        if (state.allSchedules.containsKey(newGroup)) {
          final schedule = state.allSchedules[newGroup]!;
          final keyHash = "prev_hash_${newGroup}_today";
          final keyDate = "prev_date_${newGroup}_today";
          final todayStr = AppFormatters.formatDateKey(now);

          await prefs.setString(keyHash, schedule.today.scheduleHash);
          await prefs.setString(keyDate, todayStr);
        }
      } catch (e) {
        AppLogger.e("Error syncing hash", tag: 'Main', error: e);
      }
    } else if (state.isHistoryMode) {
      final targetDate = state.displayDate;
      await loadHistoryData(targetDate);
      if (!ref.mounted) return;
    }

    updateNotificationsOnly();
    await updateStatusDate();
    if (!ref.mounted) return;
    recalculateDisplayData();
  }

  // --- 2. SWITCH MODE ---
  Future<void> switchMode(DataSourceMode mode) async {
    if (!state.powerMonitorEnabled) return;
    if (state.dataSourceMode == mode) return;

    state = state.copyWith(dataSourceMode: mode);
    recalculateDisplayData();

    if (mode == DataSourceMode.real) {
      await loadRealOutageData(state.displayDate);
      if (!ref.mounted) return;
      recalculateDisplayData();
    }
  }

  Future<void> setDataSourceMode(DataSourceMode mode) => switchMode(mode);

  Future<void> toggleDataSourceMode() async {
    if (!state.powerMonitorEnabled) return;
    final next = state.dataSourceMode == DataSourceMode.real
        ? DataSourceMode.predicted
        : DataSourceMode.real;
    await switchMode(next);
  }

  Future<void> cycleGroup(int direction) async {
    if (direction == 0) return;
    final nextGroup = ParserService.cycleGroup(state.currentGroup, direction);
    await changeGroup(nextGroup);
  }

  Future<void> selectGroupByIndex(int groupNumber) async {
    if (groupNumber < 1 || groupNumber > 6) return;
    final matching = ParserService.allGroups
        .where(
            (g) => g.startsWith("GPV$groupNumber.") || g == "GPV$groupNumber")
        .toList();
    if (matching.isEmpty) return;
    if (matching.length == 1) {
      await changeGroup(matching.first);
      return;
    }
    final currentSubIdx = matching.indexOf(state.currentGroup);
    if (currentSubIdx != -1) {
      final nextSubIdx = (currentSubIdx + 1) % matching.length;
      await changeGroup(matching[nextSubIdx]);
    } else {
      await changeGroup(matching.first);
    }
  }

  // --- 3. NAVIGATE DATE ---
  Future<void> navigateDate(int offset) async {
    if (offset == 0) return;

    final now = DateTime.now();
    final firstAllowed = DateTime(2024);
    DateTime current;
    switch (state.viewMode) {
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
        current =
            state.historyDate ?? DateTime(now.year, now.month, now.day - 1);
        break;
    }

    final newDate = DateTime(current.year, current.month, current.day + offset);
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    final tomorrow = DateTime(now.year, now.month, now.day + 1);

    if (offset > 0 &&
        (state.viewMode == ScheduleViewMode.tomorrow ||
            newDate.isAfter(tomorrow))) {
      return;
    }
    if (offset < 0 &&
        (newDate.isBefore(firstAllowed) || state.isAtEarliestDate)) {
      return;
    }

    state = state.copyWith(wasUpdated: false);

    if (DateUtils.isSameDay(newDate, today)) {
      state = state.copyWith(
        viewMode: ScheduleViewMode.today,
        historyVersions: const [],
        selectedVersionIndex: -1,
        clearHistorySchedule: true,
      );
      recalculateDisplayData();
      await refreshVersionsForCurrentMode();
      if (!ref.mounted) return;
      await updateStatusDate();
      if (!ref.mounted) return;

      if (state.dataSourceMode == DataSourceMode.real) {
        await loadRealOutageData(newDate);
        if (!ref.mounted) return;
        recalculateDisplayData();
      }
    } else if (DateUtils.isSameDay(newDate, yesterday)) {
      state = state.copyWith(
        viewMode: ScheduleViewMode.yesterday,
        historyDate: newDate,
        historyVersions: const [],
        selectedVersionIndex: -1,
        clearHistorySchedule: true,
      );
      recalculateDisplayData();
      await loadHistoryData(newDate);
      if (!ref.mounted) return;
      if (state.dataSourceMode == DataSourceMode.real) {
        await loadRealOutageData(newDate);
        if (!ref.mounted) return;
        recalculateDisplayData();
      }
    } else if (DateUtils.isSameDay(newDate, tomorrow)) {
      state = state.copyWith(
        viewMode: ScheduleViewMode.tomorrow,
        historyVersions: const [],
        selectedVersionIndex: -1,
        clearHistorySchedule: true,
      );
      recalculateDisplayData();
      await refreshVersionsForCurrentMode();
      if (!ref.mounted) return;
      await updateStatusDate();
      if (!ref.mounted) return;

      if (state.dataSourceMode == DataSourceMode.real) {
        await loadRealOutageData(tomorrow);
        if (!ref.mounted) return;
        recalculateDisplayData();
      }
    } else {
      state = state.copyWith(
        viewMode: ScheduleViewMode.history,
        historyDate: newDate,
        historyVersions: const [],
        selectedVersionIndex: -1,
        clearHistorySchedule: true,
      );
      recalculateDisplayData();
      await loadHistoryData(newDate);
      if (!ref.mounted) return;
      if (state.dataSourceMode == DataSourceMode.real) {
        await loadRealOutageData(newDate);
        if (!ref.mounted) return;
        recalculateDisplayData();
      }
    }
  }

  // --- 4. SELECT VERSION ---
  void selectVersion(int index) {
    if (index < 0 || index >= state.historyVersions.length) return;
    final selectedVer = state.historyVersions[index];
    state = state.copyWith(
      selectedVersionIndex: index,
      historySchedule: selectedVer.toSchedule(),
      statusMessage: !state.isHistoryMode
          ? "Оновлено ДТЕК: ${selectedVer.timeString}"
          : state.statusMessage,
    );
    recalculateDisplayData();
  }

  /// Cycle through available schedule versions (+1 newer/next, -1 older/previous).
  void cycleVersion(int direction) {
    if (state.historyVersions.length <= 1 || direction == 0) return;
    final currentIndex = state.selectedVersionIndex >= 0
        ? state.selectedVersionIndex
        : state.historyVersions.length - 1;
    final count = state.historyVersions.length;
    final newIndex = (currentIndex + direction) % count;
    final targetIndex = newIndex < 0 ? newIndex + count : newIndex;
    selectVersion(targetIndex);
  }

  // --- SELECT DATE ---
  Future<void> selectDate(DateTime picked) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (DateUtils.isSameDay(picked, today)) {
      await setViewMode(ScheduleViewMode.today);
      return;
    }
    final yesterday = DateTime(now.year, now.month, now.day - 1);
    if (DateUtils.isSameDay(picked, yesterday)) {
      await setViewMode(ScheduleViewMode.yesterday);
      _achievementService.trackHistoryView(picked);
      return;
    }

    state = state.copyWith(
      wasUpdated: false,
      viewMode: ScheduleViewMode.history,
      historyDate: picked,
      historyVersions: const [],
      selectedVersionIndex: -1,
      clearHistorySchedule: true,
    );
    recalculateDisplayData();
    await loadHistoryData(picked);
    if (!ref.mounted) return;
    _achievementService.trackHistoryView(picked);
    if (state.dataSourceMode == DataSourceMode.real) {
      await loadRealOutageData(picked);
      if (!ref.mounted) return;
      recalculateDisplayData();
    }
  }

  void cancelDateSelection() {
    if (state.viewMode == ScheduleViewMode.history &&
        state.historyDate == null) {
      state = state.copyWith(
        viewMode: ScheduleViewMode.today,
        historyVersions: const [],
        selectedVersionIndex: -1,
        clearHistorySchedule: true,
      );
      recalculateDisplayData();
    }
  }

  // --- SET VIEW MODE ---
  Future<void> setViewMode(ScheduleViewMode mode) async {
    if (state.viewMode == mode && mode != ScheduleViewMode.history) return;

    final now = DateTime.now();
    DateTime targetDate;
    if (mode == ScheduleViewMode.today) {
      targetDate = DateTime(now.year, now.month, now.day);
    } else if (mode == ScheduleViewMode.tomorrow) {
      targetDate = DateTime(now.year, now.month, now.day + 1);
    } else if (mode == ScheduleViewMode.yesterday) {
      targetDate = DateTime(now.year, now.month, now.day - 1);
    } else {
      targetDate =
          state.historyDate ?? DateTime(now.year, now.month, now.day - 1);
    }

    state = state.copyWith(
      wasUpdated: false,
      viewMode: mode,
      historyDate: (mode == ScheduleViewMode.history ||
              mode == ScheduleViewMode.yesterday)
          ? targetDate
          : null,
      clearHistoryDate:
          (mode == ScheduleViewMode.today || mode == ScheduleViewMode.tomorrow),
      historyVersions: const [],
      selectedVersionIndex: -1,
      clearHistorySchedule: true,
    );
    recalculateDisplayData();

    if (mode == ScheduleViewMode.today || mode == ScheduleViewMode.tomorrow) {
      await refreshVersionsForCurrentMode();
      if (!ref.mounted) return;
      await updateStatusDate();
      if (!ref.mounted) return;
    } else {
      await loadHistoryData(targetDate);
      if (!ref.mounted) return;
    }

    if (state.dataSourceMode == DataSourceMode.real) {
      await loadRealOutageData(targetDate);
      if (!ref.mounted) return;
      recalculateDisplayData();
    }
  }

  // --- LOAD PREFERENCES & DATA ---
  Future<void> loadPreferencesAndData() async {
    SharedPreferences? prefs;
    try {
      prefs = await PreferencesHelper.getSafeInstance();
    } catch (e) {
      AppLogger.e("Error loading SharedPreferences", tag: 'Main', error: e);
    }

    final previousGroup = state.currentGroup;
    bool groupChanged = false;

    if (prefs != null) {
      final savedGroup = prefs.getString('selected_group') ?? "GPV2.1";
      final savedNotifGroups = prefs.getStringList('notification_groups') ?? [];
      groupChanged = savedGroup != previousGroup;

      state = state.copyWith(
        currentGroup: savedGroup,
        notificationGroups: savedNotifGroups,
      );
    }

    updateNotificationsOnly();

    if (state.isHistoryMode) {
      if (groupChanged) {
        final targetDate = state.displayDate;
        await loadHistoryData(targetDate);
        if (!ref.mounted) return;
      }
      await loadData(silent: true);
      if (!ref.mounted) return;
    } else {
      if (groupChanged) {
        await refreshVersionsForCurrentMode();
        if (!ref.mounted) return;
        await updateStatusDate();
        if (!ref.mounted) return;
      }
      await loadData(silent: false, force: groupChanged);
      if (!ref.mounted) return;
    }
  }

  // --- LOAD DATA (SYNC) ---
  Future<void> loadData({bool silent = false, bool force = false}) async {
    await _scheduleSyncService.sync(
      silent: silent,
      force: force,
      hasExistingData: state.allSchedules.isNotEmpty,
      isHistoryMode: state.isHistoryMode,
      onCooldownSkipped: () async {
        updateStatusDate();
        if (state.isLoading) {
          state = state.copyWith(isLoading: false);
        }
      },
      onEnsureCache: () async {
        if (state.allSchedules.isEmpty) {
          await loadCachedData();
        }
        return true;
      },
      onFetchStart: () {
        if (!state.isHistoryMode) {
          state = state.copyWith(
            isLoading: state.allSchedules.isEmpty ? true : state.isLoading,
            statusMessage: state.isCachedData
                ? "Оновлення... (показано архів)"
                : "Оновлення...",
            statusColor: Colors.orange,
          );
        }
      },
      onBeforeFetch: () {
        if (state.allSchedules.isNotEmpty) {
          final oldStats = Map<String, int>.from(state.lastUpdateOldStats)
            ..addAll(_scheduleSyncService.computeOldStats(state.allSchedules));
          state = state.copyWith(lastUpdateOldStats: oldStats);
        }
      },
      onFetchSuccess: (allData) async {
        final currentIsHistory = state.isHistoryMode;
        state = state.copyWith(
          allSchedules: allData,
          isCachedData: false,
          wasUpdated: true,
          isLoading: currentIsHistory ? state.isLoading : false,
          statusColor: currentIsHistory ? state.statusColor : Colors.green,
        );
        recalculateDisplayData();

        if (!currentIsHistory) {
          await refreshVersionsForCurrentMode();
          updateStatusDate();
        }

        await _scheduleNotificationCoordinator.handleScheduleUpdate(
          allSchedules: allData,
          currentGroup: state.currentGroup,
          notificationGroups: state.notificationGroups,
        );

        _achievementService.checkAll(
          schedules: state.allSchedules,
          currentGroup: state.currentGroup,
        );
      },
      onFetchError: (e) {
        if (!state.isHistoryMode) {
          state = state.copyWith(
            isLoading: false,
            statusMessage: state.isCachedData
                ? "Немає зв'язку (Архів)"
                : "Помилка оновлення",
            statusColor: Colors.red,
          );
        }
      },
    );
  }

  // --- LOAD CACHED DATA ---
  Future<void> loadCachedData() async {
    final cached = await _scheduleSyncService.loadCachedData();
    if (cached.isNotEmpty) {
      final current = cached[state.currentGroup];
      final msg = current != null
          ? "З пам'яті: ${current.lastUpdatedSource}"
          : "З пам'яті (дані завантажено)";

      state = state.copyWith(
        allSchedules: cached,
        isLoading: false,
        isCachedData: true,
        statusColor: Colors.orange,
        statusMessage: msg,
        wasUpdated: false,
      );
      recalculateDisplayData();
      await refreshVersionsForCurrentMode();
    }
  }

  // --- REFRESH VERSIONS ---
  Future<void> refreshVersionsForCurrentMode() async {
    final targetDate = state.displayDate;
    final groupAtCall = state.currentGroup;
    final versions = await HistoryService()
        .getVersionsForDate(targetDate, state.currentGroup);
    if (!ref.mounted) return;
    if (state.currentGroup != groupAtCall) return;
    if (!DateUtils.isSameDay(targetDate, state.displayDate)) return;

    if (versions.isNotEmpty) {
      state = state.copyWith(
        historyVersions: versions,
        selectedVersionIndex: versions.length - 1,
        historySchedule: versions.last.toSchedule(),
      );
    } else {
      state = state.copyWith(
        historyVersions: const [],
        selectedVersionIndex: -1,
        clearHistorySchedule: true,
      );
    }
    recalculateDisplayData();
  }

  // --- UPDATE STATUS DATE ---
  Future<void> updateStatusDate() async {
    final now = DateTime.now();
    DateTime targetDate;
    if (state.viewMode == ScheduleViewMode.today) {
      targetDate = DateTime(now.year, now.month, now.day);
    } else if (state.viewMode == ScheduleViewMode.tomorrow) {
      targetDate = DateTime(now.year, now.month, now.day + 1);
    } else {
      return;
    }

    final dateStr = AppFormatters.formatDateKey(targetDate);
    final updateTime = await HistoryService().getLatestUpdatedAt(
      groupKey: state.currentGroup,
      targetDate: dateStr,
    );
    if (!ref.mounted) return;

    String msg = "Оновлено ДТЕК: Невідомо";
    Color color = Colors.grey;

    if (state.historyVersions.isNotEmpty) {
      final version = (state.selectedVersionIndex >= 0 &&
              state.selectedVersionIndex < state.historyVersions.length)
          ? state.historyVersions[state.selectedVersionIndex]
          : state.historyVersions.last;
      msg = "Оновлено ДТЕК: ${version.timeString}";
      color = Colors.green;
    } else if (updateTime != null) {
      msg = "Оновлено ДТЕК: $updateTime";
      color = Colors.green;
    } else if (state.allSchedules.containsKey(state.currentGroup)) {
      msg =
          "Оновлено ДТЕК: ${state.allSchedules[state.currentGroup]!.lastUpdatedSource}";
      color = state.isCachedData ? Colors.orange : Colors.green;
    }

    if (state.isCachedData) {
      if (msg.contains("Оновлено ДТЕК")) {
        msg = msg.replaceAll("Оновлено ДТЕК", "З пам'яті");
      } else {
        msg = "$msg (З пам'яті)";
      }
      color = Colors.orange;
    }

    state = state.copyWith(
      statusMessage: msg,
      statusColor: color,
    );
  }

  // --- LOAD HISTORY DATA ---
  Future<void> loadHistoryData(DateTime date) async {
    final requestId = ++_historyLoadRequestId;
    final groupAtCall = state.currentGroup;
    final dateAtCall = date;

    state = state.copyWith(
      isLoading: true,
      statusMessage: "Завантаження архіву...",
      historyVersions: const [],
      selectedVersionIndex: -1,
    );

    try {
      final versions =
          await HistoryService().getVersionsForDate(date, state.currentGroup);
      if (!ref.mounted) return;
      if (requestId != _historyLoadRequestId) return;
      if (state.currentGroup != groupAtCall) return;
      if (!DateUtils.isSameDay(dateAtCall, state.displayDate)) return;

      final dateStr = "${date.day}.${date.month}.${date.year}";
      if (versions.isEmpty) {
        state = state.copyWith(
          historyVersions: const [],
          isLoading: false,
          clearHistorySchedule: true,
          selectedVersionIndex: -1,
          statusMessage: "Немає даних за $dateStr",
        );
      } else {
        final versionCount = versions.length;
        state = state.copyWith(
          historyVersions: versions,
          isLoading: false,
          selectedVersionIndex: versions.length - 1,
          historySchedule: versions.last.toSchedule(),
          statusMessage:
              "Архів за $dateStr ($versionCount ${AppFormatters.pluralVersions(versionCount)})",
        );
      }
      recalculateDisplayData();
    } catch (e) {
      if (!ref.mounted) return;
      if (requestId == _historyLoadRequestId &&
          state.currentGroup == groupAtCall &&
          DateUtils.isSameDay(dateAtCall, state.displayDate)) {
        state = state.copyWith(
          isLoading: false,
          clearHistorySchedule: true,
          historyVersions: const [],
          selectedVersionIndex: -1,
          statusMessage: "Помилка завантаження архіву",
        );
        recalculateDisplayData();
      }
    }
  }

  // --- LOAD REAL OUTAGE DATA ---
  Future<void> loadRealOutageData(DateTime date) async {
    if (!state.powerMonitorEnabled) return;
    final requestId = ++_realOutageLoadRequestId;
    final dateAtCall = date;
    try {
      final allEvents = await _powerMonitor.getLocalEvents();
      if (!ref.mounted) return;
      if (requestId != _realOutageLoadRequestId) return;
      if (!DateUtils.isSameDay(dateAtCall, state.displayDate)) return;

      final intervals = await _powerMonitor.getOutageIntervalsForDate(
        date,
        preloadedEvents: allEvents,
      );
      final hasCoverage = await _powerMonitor.hasCoverageForDate(
        date,
        preloadedEvents: allEvents,
      );
      if (!ref.mounted) return;
      if (requestId != _realOutageLoadRequestId) return;
      if (!DateUtils.isSameDay(dateAtCall, state.displayDate)) return;
      state = state.copyWith(
        realOutageIntervals: intervals,
        hasRealCoverage: hasCoverage,
      );
    } catch (e) {
      AppLogger.e('Error loading real outage data', tag: 'Main', error: e);
      if (!ref.mounted) return;
      if (requestId == _realOutageLoadRequestId &&
          DateUtils.isSameDay(dateAtCall, state.displayDate)) {
        state = state.copyWith(
          realOutageIntervals: const [],
          hasRealCoverage: false,
        );
      }
    }
  }

  // --- INIT POWER MONITOR ---
  Future<void> initPowerMonitor() async {
    SharedPreferences? prefs;
    try {
      prefs = await PreferencesHelper.getSafeInstance();
    } catch (e) {
      AppLogger.w("Error loading SharedPreferences in initPowerMonitor: $e",
          tag: 'Main');
    }

    final enabled = prefs?.getBool('power_monitor_enabled') ?? false;

    _powerMonitor.onStatusChanged = (status) {
      if (!ref.mounted) return;
      loadRealOutageData(state.displayDate).then((_) {
        if (!ref.mounted) return;
        state = state.copyWith(powerStatus: status);
        recalculateDisplayData();
        DarknessThemeService().refresh();
      });
    };

    if (enabled) {
      await _powerMonitor.init();
      if (!ref.mounted) return;
      state = state.copyWith(
        powerMonitorEnabled: true,
        powerStatus: _powerMonitor.currentStatus,
      );
      await loadRealOutageData(state.displayDate);
      if (!ref.mounted) return;
      recalculateDisplayData();
    } else {
      state = state.copyWith(
        powerMonitorEnabled: false,
        dataSourceMode: DataSourceMode.predicted,
        powerStatus: 'unknown',
      );
      recalculateDisplayData();
    }
  }

  // --- REFRESH ---
  Future<void> refresh({bool silent = false}) async {
    _achievementService.trackRefresh();
    if (state.isHistoryMode) {
      final targetDate = state.displayDate;
      await loadHistoryData(targetDate);
      if (!ref.mounted) return;
    } else {
      await loadData(silent: silent, force: true);
      if (!ref.mounted) return;
    }
    if (state.powerMonitorEnabled) {
      _powerMonitor.forceRefresh();
      if (state.dataSourceMode == DataSourceMode.real) {
        await loadRealOutageData(state.displayDate);
        if (!ref.mounted) return;
        recalculateDisplayData();
      }
    }
  }

  // --- UPDATE NOTIFICATIONS ONLY ---
  void updateNotificationsOnly() =>
      _scheduleNotificationCoordinator.updateNotificationsOnly(
        allSchedules: state.allSchedules,
        currentGroup: state.currentGroup,
      );
}

final homeNotifierProvider =
    NotifierProvider<HomeNotifier, HomeState>(HomeNotifier.new);
