import 'package:flutter/material.dart';

import '../../models/data_source_mode.dart';
import '../../models/hour_segment.dart';
import '../../models/interval_info.dart';
import '../../models/power_event.dart';
import '../../models/schedule_status.dart';
import '../../models/schedule_view_mode.dart';

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
  });

  bool get isHistoryMode =>
      viewMode == ScheduleViewMode.history ||
      viewMode == ScheduleViewMode.yesterday;

  DateTime get displayDate {
    final now = DateTime.now();
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
    );
  }
}
