import '../../services/schedule_clock.dart';
import 'package:flutter/material.dart';

import '../../models/data_source_mode.dart';
import '../../models/hour_segment.dart';
import '../../models/interval_info.dart';
import '../../models/power_event.dart';
import '../../models/schedule_status.dart';
import '../../models/schedule_view_mode.dart';
import '../../services/schedule_version_filter.dart';

@immutable
class HomeState {
  final Map<String, FullSchedule> allSchedules;
  final String currentGroup;
  final List<String> notificationGroups;
  final bool isLoading;
  final String statusMessage;
  final Color statusColor;
  final ScheduleViewMode viewMode;
  final DateTime? historyDate;
  final DailySchedule? historySchedule;
  final List<ScheduleVersion> historyVersions;
  final int selectedVersionIndex;
  final bool hideUnchangedScheduleVersions;
  final Map<String, int> lastUpdateOldStats;
  final bool wasUpdated;
  final bool isCachedData;
  final DataSourceMode dataSourceMode;
  final bool powerMonitorEnabled;
  final List<PowerOutageInterval> realOutageIntervals;
  final String powerStatus;
  final List<List<HourSegment>>? realHourSegments;
  final DailySchedule? currentDisplaySchedule;
  final List<IntervalInfo> cachedIntervals;
  final bool isRealSourceConfigured;
  final bool hasRealCoverage;
  final bool isEmergencyActive;
  final bool isEmergencyStatusStale;

  const HomeState({
    this.allSchedules = const {},
    this.currentGroup = "GPV2.1",
    this.notificationGroups = const [],
    this.isLoading = true,
    this.statusMessage = "Завантаження...",
    this.statusColor = Colors.grey,
    this.viewMode = ScheduleViewMode.today,
    this.historyDate,
    this.historySchedule,
    this.historyVersions = const [],
    this.selectedVersionIndex = -1,
    this.hideUnchangedScheduleVersions = true,
    this.lastUpdateOldStats = const {},
    this.wasUpdated = false,
    this.isCachedData = false,
    this.dataSourceMode = DataSourceMode.predicted,
    this.powerMonitorEnabled = false,
    this.realOutageIntervals = const [],
    this.powerStatus = 'unknown',
    this.realHourSegments,
    this.currentDisplaySchedule,
    this.cachedIntervals = const [],
    this.isRealSourceConfigured = false,
    this.hasRealCoverage = false,
    this.isEmergencyActive = false,
    this.isEmergencyStatusStale = false,
  });

  bool get isHistoryMode =>
      viewMode == ScheduleViewMode.history ||
      viewMode == ScheduleViewMode.yesterday;

  ScheduleVersionProjection get versionProjection =>
      ScheduleVersionFilter.project(historyVersions,
          hideUnchanged: hideUnchangedScheduleVersions);

  DateTime get displayDate {
    final now = ScheduleClock.now();
    if (viewMode == ScheduleViewMode.today) {
      return DateTime(now.year, now.month, now.day);
    }
    if (viewMode == ScheduleViewMode.tomorrow) {
      return DateTime(now.year, now.month, now.day + 1);
    }
    if (viewMode == ScheduleViewMode.yesterday) {
      return DateTime(now.year, now.month, now.day - 1);
    }
    return historyDate ?? DateTime(now.year, now.month, now.day);
  }

  bool get isAtEarliestDate {
    final firstAllowed = DateTime(2024);
    return displayDate.isBefore(firstAllowed) ||
        DateUtils.isSameDay(displayDate, firstAllowed);
  }

  /// Whether the real data source is missing when in real mode for today.
  bool get isMissingRealDataSource {
    if (!powerMonitorEnabled || dataSourceMode != DataSourceMode.real) {
      return false;
    }
    if (viewMode != ScheduleViewMode.today) {
      return false;
    }
    if (realOutageIntervals.isNotEmpty) {
      return false;
    }
    return !isRealSourceConfigured;
  }

  /// Whether valid data is available to display the schedule in the current view mode.
  bool get hasDisplayData {
    final schedule = currentDisplaySchedule;
    final bool isRealMode =
        powerMonitorEnabled && dataSourceMode == DataSourceMode.real;

    if (!isRealMode) {
      return schedule != null && !schedule.isEmpty;
    }

    if (viewMode == ScheduleViewMode.today) {
      return realHourSegments != null;
    }

    if (viewMode == ScheduleViewMode.tomorrow) {
      return realHourSegments != null && schedule != null && !schedule.isEmpty;
    }

    // Yesterday or archived date in history: valid if active monitoring coverage or recorded outages
    return realHourSegments != null &&
        (hasRealCoverage || realOutageIntervals.isNotEmpty);
  }

  HomeState copyWith({
    Map<String, FullSchedule>? allSchedules,
    String? currentGroup,
    List<String>? notificationGroups,
    bool? isLoading,
    String? statusMessage,
    Color? statusColor,
    ScheduleViewMode? viewMode,
    DateTime? historyDate,
    bool clearHistoryDate = false,
    DailySchedule? historySchedule,
    bool clearHistorySchedule = false,
    List<ScheduleVersion>? historyVersions,
    int? selectedVersionIndex,
    bool? hideUnchangedScheduleVersions,
    Map<String, int>? lastUpdateOldStats,
    bool? wasUpdated,
    bool? isCachedData,
    DataSourceMode? dataSourceMode,
    bool? powerMonitorEnabled,
    List<PowerOutageInterval>? realOutageIntervals,
    String? powerStatus,
    List<List<HourSegment>>? realHourSegments,
    bool clearRealHourSegments = false,
    DailySchedule? currentDisplaySchedule,
    bool clearCurrentDisplaySchedule = false,
    List<IntervalInfo>? cachedIntervals,
    bool? isRealSourceConfigured,
    bool? hasRealCoverage,
    bool? isEmergencyActive,
    bool? isEmergencyStatusStale,
  }) {
    return HomeState(
      allSchedules: allSchedules ?? this.allSchedules,
      currentGroup: currentGroup ?? this.currentGroup,
      notificationGroups: notificationGroups ?? this.notificationGroups,
      isLoading: isLoading ?? this.isLoading,
      statusMessage: statusMessage ?? this.statusMessage,
      statusColor: statusColor ?? this.statusColor,
      viewMode: viewMode ?? this.viewMode,
      historyDate: clearHistoryDate ? null : (historyDate ?? this.historyDate),
      historySchedule: clearHistorySchedule
          ? null
          : (historySchedule ?? this.historySchedule),
      historyVersions: historyVersions ?? this.historyVersions,
      selectedVersionIndex: selectedVersionIndex ?? this.selectedVersionIndex,
      hideUnchangedScheduleVersions:
          hideUnchangedScheduleVersions ?? this.hideUnchangedScheduleVersions,
      lastUpdateOldStats: lastUpdateOldStats ?? this.lastUpdateOldStats,
      wasUpdated: wasUpdated ?? this.wasUpdated,
      isCachedData: isCachedData ?? this.isCachedData,
      dataSourceMode: dataSourceMode ?? this.dataSourceMode,
      powerMonitorEnabled: powerMonitorEnabled ?? this.powerMonitorEnabled,
      realOutageIntervals: realOutageIntervals ?? this.realOutageIntervals,
      powerStatus: powerStatus ?? this.powerStatus,
      realHourSegments: clearRealHourSegments
          ? null
          : (realHourSegments ?? this.realHourSegments),
      currentDisplaySchedule: clearCurrentDisplaySchedule
          ? null
          : (currentDisplaySchedule ?? this.currentDisplaySchedule),
      cachedIntervals: cachedIntervals ?? this.cachedIntervals,
      isRealSourceConfigured:
          isRealSourceConfigured ?? this.isRealSourceConfigured,
      hasRealCoverage: hasRealCoverage ?? this.hasRealCoverage,
      isEmergencyActive: isEmergencyActive ?? this.isEmergencyActive,
      isEmergencyStatusStale:
          isEmergencyStatusStale ?? this.isEmergencyStatusStale,
    );
  }
}
