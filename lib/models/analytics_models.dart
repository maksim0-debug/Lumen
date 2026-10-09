import 'schedule_status.dart';
import 'power_event.dart';

class OutageStats {
  final int totalMinutes;
  final double percentage; // 0–100
  final int avgDurationMinutes;
  final int count; // кількість відключень

  OutageStats({
    required this.totalMinutes,
    required this.percentage,
    required this.avgDurationMinutes,
    required this.count,
  });

  String get totalFormatted {
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (h > 0 && m > 0) return '$h год $m хв';
    if (h > 0) return '$h год';
    return '$m хв';
  }

  String get avgFormatted {
    final h = avgDurationMinutes ~/ 60;
    final m = avgDurationMinutes % 60;
    if (h > 0 && m > 0) return '$h год $m хв';
    if (h > 0) return '$h год';
    return '$m хв';
  }
}

class OutageRecords {
  final OutageRecord? longestOutage;
  final OutageRecord? shortestUptime;
  final OutageRecord? longestUptime;

  OutageRecords({this.longestOutage, this.shortestUptime, this.longestUptime});
}

class OutageRecord {
  final DateTime start;
  final DateTime end;
  final Duration duration;

  OutageRecord(
      {required this.start, required this.end, required this.duration});

  String get durationFormatted {
    final h = duration.inHours;
    final m = duration.inMinutes % 60;
    if (h > 0 && m > 0) return '$h год $m хв';
    if (h > 0) return '$h год';
    return '$m хв';
  }

  String get dateFormatted {
    return '${start.day.toString().padLeft(2, '0')}.${start.month.toString().padLeft(2, '0')}';
  }
}

class DailyOutage {
  final DateTime date;
  final int outageMinutes;

  DailyOutage({required this.date, required this.outageMinutes});

  double get outageHours => outageMinutes / 60.0;
}

class SwitchLag {
  final double avgOnLagMinutes; // позитивне = пізніше графіка
  final double avgOffLagMinutes; // Positive means later than scheduled.
  final int sampleCount;
  final int onSampleCount;
  final int offSampleCount;

  const SwitchLag({
    required this.avgOnLagMinutes,
    required this.avgOffLagMinutes,
    required this.sampleCount,
    this.onSampleCount = 0,
    this.offSampleCount = 0,
  });
}

enum ScheduleDeviationPeriod {
  today,
  yesterday,
  week,
  month;

  int get dayCount => switch (this) {
        week => 7,
        month => 30,
        _ => 1,
      };
}

enum LightBalanceExclusion {
  missingSchedule,
  uncertainSchedule,
  incompleteActual
}

/// Totals cover exactly the same eligible days on both sides of the comparison.
class LightBalanceStats {
  final ScheduleDeviationPeriod period;
  final DateTime start;
  final DateTime end;
  final int plannedOnSeconds;
  final int actualOnSeconds;
  final int validDays;
  final Map<LightBalanceExclusion, int> exclusions;

  LightBalanceStats({
    required this.period,
    required this.start,
    required this.end,
    required this.plannedOnSeconds,
    required this.actualOnSeconds,
    required this.validDays,
    required Map<LightBalanceExclusion, int> exclusions,
  }) : exclusions = Map.unmodifiable(exclusions);

  bool get hasData => validDays > 0;
  int get excludedDays =>
      exclusions.values.fold(0, (sum, count) => sum + count);
  int get deltaSeconds => actualOnSeconds - plannedOnSeconds;
  double? get averageDeltaMinutes =>
      hasData ? deltaSeconds / 60 / validDays : null;
  double? get relativePercentage => hasData && plannedOnSeconds > 0
      ? deltaSeconds / plannedOnSeconds * 100
      : null;
}

class ScheduleDeviationStats {
  final LightBalanceStats balance;
  final SwitchLag lag;

  const ScheduleDeviationStats({required this.balance, required this.lag});
}

class ProductivityStats {
  final int lostWorkMinutes;
  final int totalWorkMinutes;
  final int ruinedEvenings;
  final int totalEvenings;

  ProductivityStats({
    required this.lostWorkMinutes,
    required this.totalWorkMinutes,
    required this.ruinedEvenings,
    required this.totalEvenings,
  });

  String get lostWorkFormatted {
    final h = lostWorkMinutes ~/ 60;
    final m = lostWorkMinutes % 60;
    if (h > 0 && m > 0) return '$h год $m хв';
    if (h > 0) return '$h год';
    return '$m хв';
  }

  double get lostWorkPercentage =>
      totalWorkMinutes > 0 ? (lostWorkMinutes / totalWorkMinutes * 100) : 0;
}

/// Дані для порівняльного таймлайна (штрихкод).
class TimelineSlot {
  final int hour;
  final bool scheduledOn; // Чи обіцяв ДТЕК світло
  final bool actuallyOn; // Чи було світло насправді
  final double? actualFraction; // Частка години зі світлом (0.0–1.0)

  TimelineSlot({
    required this.hour,
    required this.scheduledOn,
    required this.actuallyOn,
    this.actualFraction,
  });
}

class TimelineComparisonData {
  final List<TimelineSlot> slots;
  final DailySchedule? schedule;
  final List<PowerOutageInterval> realityIntervals;

  TimelineComparisonData({
    required this.slots,
    this.schedule,
    required this.realityIntervals,
  });
}

/// Статистика однієї групи для порівняння.
class GroupStats {
  final String groupKey;
  final int totalOffMinutes;
  final int daysWithData;

  GroupStats({
    required this.groupKey,
    required this.totalOffMinutes,
    required this.daysWithData,
  });

  /// Назва групи для UI (напр. "GPV1.1" -> "Група 1.1").
  String get displayName {
    final num = groupKey.replaceFirst('GPV', '');
    return 'Група $num';
  }

  /// Відсоток часу без світла відносно загального можливого часу.
  double get offPercentage {
    if (daysWithData == 0) return 0;
    final totalPossible = daysWithData * 24 * 60;
    return totalOffMinutes / totalPossible * 100;
  }

  /// Форматований рядок тривалості (напр. "14 год 30 хв").
  String get totalFormatted {
    final h = totalOffMinutes ~/ 60;
    final m = totalOffMinutes % 60;
    if (h > 0 && m > 0) return '$h год $m хв';
    if (h > 0) return '$h год';
    return '$m хв';
  }
}

/// Результат порівняння всіх груп за певний період.
class GroupComparisonResult {
  final List<GroupStats> ranked; // відсортовано від кращої до гіршої
  final String bestGroup;
  final String worstGroup;
  final double averageOffMinutes;

  GroupComparisonResult({
    required this.ranked,
    required this.bestGroup,
    required this.worstGroup,
    required this.averageOffMinutes,
  });
}
