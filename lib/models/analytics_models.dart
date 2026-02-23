import 'package:fl_chart/fl_chart.dart';
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
    if (h > 0 && m > 0) return '$hг $mхв';
    if (h > 0) return '$hг';
    return '$mхв';
  }

  String get avgFormatted {
    final h = avgDurationMinutes ~/ 60;
    final m = avgDurationMinutes % 60;
    if (h > 0 && m > 0) return '$hг $mхв';
    if (h > 0) return '$hг';
    return '$mхв';
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
    if (h > 0 && m > 0) return '$hг $mхв';
    if (h > 0) return '$hг';
    return '$mхв';
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
  final double avgOffLagMinutes; // позитивне = раніше графіка
  final int sampleCount;

  SwitchLag({
    required this.avgOnLagMinutes,
    required this.avgOffLagMinutes,
    required this.sampleCount,
  });
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
    if (h > 0 && m > 0) return '$hг $mхв';
    if (h > 0) return '$hг';
    return '$mхв';
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

  /// Форматований рядок тривалості (напр. "14г 30хв").
  String get totalFormatted {
    final h = totalOffMinutes ~/ 60;
    final m = totalOffMinutes % 60;
    if (h > 0 && m > 0) return '$hг $mхв';
    if (h > 0) return '${h}г';
    return '${m}хв';
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
