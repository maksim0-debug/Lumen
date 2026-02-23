import '../models/analytics_models.dart';
import '../models/power_event.dart';
import '../models/schedule_status.dart';
import 'power_monitor_service.dart';
import 'history_service.dart';
import 'parser_service.dart';

enum DataSourceMode { real, predicted }

/// Сервіс агрегації аналітичних даних про відключення.
/// Всі дані беруться з локальної БД (power_events + schedule_history).
class AnalyticsService {
  final PowerMonitorService _powerMonitor = PowerMonitorService();
  final HistoryService _historyService = HistoryService();

  // ===========================================================
  // ENUMS & HELPERS
  // ===========================================================

  Future<List<PowerOutageInterval>> _getIntervalsForDate(
      DateTime date, DataSourceMode mode,
      {String groupKey = 'GPV1.1'}) async {
    if (mode == DataSourceMode.real) {
      return await _powerMonitor.getOutageIntervalsForDate(date);
    } else {
      final versions = await _historyService.getVersionsForDate(date, groupKey);
      if (versions.isNotEmpty) {
        final schedule = versions.last.toSchedule();
        return _convertScheduleToIntervals(schedule, date);
      }
      return [];
    }
  }

  List<PowerOutageInterval> _convertScheduleToIntervals(
      DailySchedule schedule, DateTime date) {
    List<PowerOutageInterval> intervals = [];
    final dayStart = DateTime(date.year, date.month, date.day);

    DateTime? currentStart;

    for (int h = 0; h < 24; h++) {
      final status = schedule.hours[h];

      // Determine if this hour is "Off" for analytics purposes
      // Rules: Off -> Off, Else -> On
      bool isOff = (status == LightStatus.off);

      // Special case: SemiOff (30 min on, 30 min off)
      if (status == LightStatus.semiOff) {
        final start = dayStart.add(Duration(hours: h, minutes: 30));
        if (currentStart != null) {
          intervals.add(PowerOutageInterval(
            start: currentStart,
            end: start,
          ));
        }
        currentStart = start;
        continue;
      }

      // Special case: SemiOn (30 min off, 30 min on)
      if (status == LightStatus.semiOn) {
        // First half is OFF
        final start = dayStart.add(Duration(hours: h));
        final mid = start.add(const Duration(minutes: 30));

        // If we were already tracking an outage, continue it until mid
        if (currentStart != null) {
          intervals.add(PowerOutageInterval(
            start: currentStart,
            end: mid,
          ));
          currentStart = null;
        } else {
          intervals.add(PowerOutageInterval(
            start: start,
            end: mid,
          ));
        }
        // Second half is ON, so we are definitely not in an outage at the end of this hour
        continue;
      }

      if (isOff) {
        if (currentStart == null) {
          currentStart = dayStart.add(Duration(hours: h));
        }
      } else {
        if (currentStart != null) {
          // Close the interval
          intervals.add(PowerOutageInterval(
            start: currentStart,
            end: dayStart.add(Duration(hours: h)),
          ));
          currentStart = null;
        }
      }
    }

    // Close any open interval at the end of the day
    if (currentStart != null) {
      intervals.add(PowerOutageInterval(
        start: currentStart,
        end: dayStart.add(const Duration(hours: 24)),
      ));
    }

    return intervals;
  }

  // ===========================================================
  // OUTAGE STATS (Статистика відключень)
  // ===========================================================

  /// Статистика відключень за [days] днів (включаючи сьогодні).
  Future<OutageStats> getOutageStatsForPeriod(int days,
      {DataSourceMode mode = DataSourceMode.real,
      String groupKey = 'GPV1.1'}) async {
    final now = DateTime.now();
    int totalOutageSeconds = 0;
    int outageCount = 0;
    List<int> durations = [];

    for (int d = 0; d < days; d++) {
      final date =
          DateTime(now.year, now.month, now.day).subtract(Duration(days: d));
      final intervals =
          await _getIntervalsForDate(date, mode, groupKey: groupKey);

      for (final interval in intervals) {
        final dayStart = DateTime(date.year, date.month, date.day);
        final dayEnd = dayStart.add(const Duration(days: 1));
        final effectiveEnd =
            interval.end ?? (now.isBefore(dayEnd) ? now : dayEnd);

        final start =
            interval.start.isBefore(dayStart) ? dayStart : interval.start;
        final end = effectiveEnd.isAfter(dayEnd) ? dayEnd : effectiveEnd;

        if (end.isAfter(start)) {
          final seconds = end.difference(start).inSeconds;
          totalOutageSeconds += seconds;
          outageCount++;
          durations.add(seconds ~/ 60);
        }
      }
    }

    final totalMinutes = (totalOutageSeconds / 60).round();
    final totalPossibleMinutes = days * 24 * 60;
    final percentage = totalPossibleMinutes > 0
        ? (totalMinutes / totalPossibleMinutes * 100)
        : 0.0;
    final avgDuration =
        outageCount > 0 ? (totalMinutes / outageCount).round() : 0;

    return OutageStats(
      totalMinutes: totalMinutes,
      percentage: percentage,
      avgDurationMinutes: avgDuration,
      count: outageCount,
    );
  }

  /// Статистика за сьогодні.
  Future<OutageStats> getOutageStatsForToday(
          {DataSourceMode mode = DataSourceMode.real,
          String groupKey = 'GPV1.1'}) =>
      getOutageStatsForPeriod(1, mode: mode, groupKey: groupKey);

  // ============================================================
  // RECORDS (Рекорди)
  // ============================================================

  /// Рекорди за весь період наявних даних.
  Future<OutageRecords> getRecords(
      {DataSourceMode mode = DataSourceMode.real,
      String groupKey = 'GPV1.1'}) async {
    List<_IntervalData> offlineIntervals = [];
    List<_IntervalData> onlineIntervals = [];
    final now = DateTime.now();

    if (mode == DataSourceMode.real) {
      // REAL MODE: Use events as before (most accurate for records)
      final allEvents = await _powerMonitor.getLocalEvents();
      if (allEvents.isEmpty) return OutageRecords();

      DateTime? lastOfflineStart;
      DateTime? lastOnlineStart;

      for (int i = 0; i < allEvents.length; i++) {
        final event = allEvents[i];
        if (event.isOffline) {
          if (lastOnlineStart != null) {
            onlineIntervals
                .add(_IntervalData(lastOnlineStart, event.timestamp));
            lastOnlineStart = null;
          }
          lastOfflineStart ??= event.timestamp;
        } else {
          if (lastOfflineStart != null) {
            offlineIntervals
                .add(_IntervalData(lastOfflineStart, event.timestamp));
            lastOfflineStart = null;
          }
          lastOnlineStart ??= event.timestamp;
        }
      }

      // Поточний стан
      if (lastOfflineStart != null) {
        offlineIntervals.add(_IntervalData(lastOfflineStart, now));
      }
      if (lastOnlineStart != null) {
        onlineIntervals.add(_IntervalData(lastOnlineStart, now));
      }
    } else {
      // FORECAST MODE: Stitch intervals from last 60 days
      // Iterate from 60 days ago to today
      final startDate = now.subtract(const Duration(days: 60));
      // Need continuous timeline.
      // We will perform a simplified simulation:
      // Concat all intervals from all days.
      // Merge adjacent intervals if they touch.
      // Then invert to find online intervals.

      List<PowerOutageInterval> allOutages = [];
      for (int i = 0; i <= 60; i++) {
        final date = startDate.add(Duration(days: i));
        // Don't go into future too much, but schedule might exist.
        // Limit to "today" + 1 day? Or just up to today.
        // Analytics usually is about history/past.
        if (date.isAfter(now.add(const Duration(days: 2)))) break;

        final dayIntervals = await _getIntervalsForDate(
            date, DataSourceMode.predicted,
            groupKey: groupKey);
        allOutages.addAll(dayIntervals);
      }

      // Now we have a list of outages. We need to process them into continuous blocks.
      // Sorting is important (though they should be timely ordered by loop)
      allOutages.sort((a, b) => a.start.compareTo(b.start));

      DateTime? currentOutageStart;
      DateTime? currentOutageEnd;

      for (final outage in allOutages) {
        if (currentOutageStart == null) {
          currentOutageStart = outage.start;
          currentOutageEnd = outage.end ??
              outage.start.add(const Duration(hours: 4)); // Fallback
        } else {
          // Check if overlaps or touches
          // Touching: end == start.
          // Since we use DateTime, strictly equal might be rare due to ms?
          // Our converter uses exact hours.
          if (outage.start.difference(currentOutageEnd!).inMinutes.abs() <= 1) {
            // Merge
            currentOutageEnd = outage.end ?? currentOutageEnd; // Extend
          } else {
            // Gap found -> This is an Online interval between valid outages!
            // Push previous outage
            offlineIntervals
                .add(_IntervalData(currentOutageStart, currentOutageEnd!));

            // Push online interval
            onlineIntervals.add(_IntervalData(currentOutageEnd, outage.start));

            // Start new outage
            currentOutageStart = outage.start;
            currentOutageEnd =
                outage.end ?? outage.start.add(const Duration(hours: 4));
          }
        }
      }

      // Push last
      if (currentOutageStart != null && currentOutageEnd != null) {
        offlineIntervals
            .add(_IntervalData(currentOutageStart, currentOutageEnd));
      }
    }

    // Найдовше відключення
    OutageRecord? longestOutage;
    if (offlineIntervals.isNotEmpty) {
      offlineIntervals.sort((a, b) => b.duration.compareTo(a.duration));
      final longest = offlineIntervals.first;
      longestOutage = OutageRecord(
        start: longest.start,
        end: longest.end,
        duration: longest.duration,
      );
    }

    // Найкоротший проміжок світла
    OutageRecord? shortestUptime;
    if (onlineIntervals.length > 1) {
      // Виключаємо поточний (може бути неповним)
      final completed = onlineIntervals
          .where(
              (i) => i.end.isBefore(now.subtract(const Duration(minutes: 1))))
          .toList();
      if (completed.isNotEmpty) {
        completed.sort((a, b) => a.duration.compareTo(b.duration));
        final shortest = completed.first;
        shortestUptime = OutageRecord(
          start: shortest.start,
          end: shortest.end,
          duration: shortest.duration,
        );
      }
    }

    // Найдовший безперервний аптайм
    OutageRecord? longestUptime;
    if (onlineIntervals.isNotEmpty) {
      onlineIntervals.sort((a, b) => b.duration.compareTo(a.duration));
      final longest = onlineIntervals.first;
      longestUptime = OutageRecord(
        start: longest.start,
        end: longest.end,
        duration: longest.duration,
      );
    }

    return OutageRecords(
      longestOutage: longestOutage,
      shortestUptime: shortestUptime,
      longestUptime: longestUptime,
    );
  }

  // ============================================================
  // ACCURACY (Точність графіка ДТЕК)
  // ============================================================

  /// Точність графіка за конкретну дату.
  /// Повертає 0.0–1.0 (частка збігу).
  Future<double> getAccuracyScore(DateTime date, String groupKey) async {
    // Отримати прогноз ДТЕК
    final versions = await _historyService.getVersionsForDate(date, groupKey);
    if (versions.isEmpty) return -1; // Немає прогнозу

    // Беремо останню версію графіка
    final schedule = versions.last.toSchedule();

    // Отримати реальні інтервали
    final intervals = await _powerMonitor.getOutageIntervalsForDate(date);

    final now = DateTime.now();
    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;
    final maxHour = isToday ? now.hour : 24;

    if (maxHour == 0) return -1;

    int matchingMinutes = 0;
    int totalMinutes = 0;

    for (int h = 0; h < maxHour; h++) {
      // Чи обіцяв ДТЕК світло в цю годину
      final status = schedule.hours[h];
      final minutesScheduledOff = _getScheduledOffMinutes(status);

      // Порахувати реальний час offline
      int realOffMinutes = 0;
      for (final interval in intervals) {
        realOffMinutes += interval.minutesOfflineInHour(date, h);
      }

      // Обмежуємо поточну годину до поточної хвилини
      int minutesInHour = 60;
      if (isToday && h == now.hour) {
        minutesInHour = now.minute;
        if (minutesInHour == 0) continue;
      }

      // Порівнюємо по хвилинах
      final scheduledOnMinutes =
          minutesInHour - (minutesScheduledOff * minutesInHour / 60).round();
      final realOnMinutes =
          minutesInHour - realOffMinutes.clamp(0, minutesInHour);

      // Різниця
      final diff = (scheduledOnMinutes - realOnMinutes).abs();
      matchingMinutes += (minutesInHour - diff);
      totalMinutes += minutesInHour;
    }

    return totalMinutes > 0 ? matchingMinutes / totalMinutes : -1;
  }

  /// Середня точність за [days] днів.
  Future<double> getAccuracyScoreForPeriod(int days, String groupKey) async {
    final now = DateTime.now();
    double totalScore = 0;
    int validDays = 0;

    for (int d = 0; d < days; d++) {
      final date =
          DateTime(now.year, now.month, now.day).subtract(Duration(days: d));
      final score = await getAccuracyScore(date, groupKey);
      if (score >= 0) {
        totalScore += score;
        validDays++;
      }
    }

    return validDays > 0 ? totalScore / validDays : -1;
  }

  int _getScheduledOffMinutes(LightStatus status) {
    switch (status) {
      case LightStatus.off:
        return 60;
      case LightStatus.semiOn:
      case LightStatus.semiOff:
        return 30;
      case LightStatus.maybe:
        return 30;
      default:
        return 0;
    }
  }

  // ============================================================
  // HEATMAP (Хітмеп за днями тижня × години)
  // ============================================================

  /// Хітмеп: повертає матрицю [день тижня 1-7][година 0-23] = % часу без світла.
  Future<List<List<double>>> getHeatmapData(int days,
      {DataSourceMode mode = DataSourceMode.real,
      String groupKey = 'GPV1.1'}) async {
    final now = DateTime.now();
    // [weekday 0-6][hour 0-23] -> total offline minutes
    List<List<double>> totalOff = List.generate(7, (_) => List.filled(24, 0.0));
    List<List<int>> counts = List.generate(7, (_) => List.filled(24, 0));

    for (int d = 0; d < days; d++) {
      final date =
          DateTime(now.year, now.month, now.day).subtract(Duration(days: d));
      final weekday = (date.weekday - 1) % 7; // 0=Monday ... 6=Sunday
      final intervals =
          await _getIntervalsForDate(date, mode, groupKey: groupKey);

      final isToday = d == 0;
      final maxHour = isToday ? now.hour + 1 : 24;

      for (int h = 0; h < maxHour; h++) {
        int offMinutes = 0;
        for (final interval in intervals) {
          offMinutes += interval.minutesOfflineInHour(date, h);
        }
        totalOff[weekday][h] += offMinutes;
        counts[weekday][h]++;
      }
    }

    // Середній % offline
    List<List<double>> result = List.generate(7, (_) => List.filled(24, 0.0));
    for (int wd = 0; wd < 7; wd++) {
      for (int h = 0; h < 24; h++) {
        if (counts[wd][h] > 0) {
          result[wd][h] = (totalOff[wd][h] / counts[wd][h]) / 60.0; // 0.0–1.0
        }
      }
    }

    return result;
  }

  // ============================================================
  // DAILY OUTAGE HOURS (Тренди)
  // ============================================================

  /// Годин без світла по дням за [days] днів.
  Future<List<DailyOutage>> getDailyOutageHours(int days,
      {DataSourceMode mode = DataSourceMode.real,
      String groupKey = 'GPV1.1'}) async {
    final now = DateTime.now();
    List<DailyOutage> result = [];

    for (int d = days - 1; d >= 0; d--) {
      final date =
          DateTime(now.year, now.month, now.day).subtract(Duration(days: d));
      final intervals =
          await _getIntervalsForDate(date, mode, groupKey: groupKey);

      int totalSeconds = 0;
      final dayStart = DateTime(date.year, date.month, date.day);
      final dayEnd = dayStart.add(const Duration(days: 1));
      final effectiveNow =
          (mode == DataSourceMode.predicted || d > 0) ? dayEnd : now;

      for (final interval in intervals) {
        final start =
            interval.start.isBefore(dayStart) ? dayStart : interval.start;
        final end = (interval.end ?? effectiveNow).isAfter(dayEnd)
            ? dayEnd
            : (interval.end ?? effectiveNow);
        if (end.isAfter(start)) {
          totalSeconds += end.difference(start).inSeconds;
        }
      }

      // Clamp to 24 hours (1440 minutes) to prevent crazy values
      int minutes = (totalSeconds / 60).round();
      if (minutes > 1440) {
        print(
            '[AnalyticalService] WARNING: Day $date has $minutes minutes outage! Clamping to 1440.');
        minutes = 1440;
      }

      result.add(DailyOutage(
        date: date,
        outageMinutes: minutes,
      ));
    }

    return result;
  }

  // ============================================================
  // WORST DAYS (Худші дні тижня)
  // ============================================================

  /// Середній час без світла по днях тижня за [days] днів.
  /// Повертає Map: weekday (1=Mon..7=Sun) -> average outage hours.
  Future<Map<int, double>> getWorstDays(int days,
      {DataSourceMode mode = DataSourceMode.real,
      String groupKey = 'GPV1.1'}) async {
    final dailyData =
        await getDailyOutageHours(days, mode: mode, groupKey: groupKey);

    Map<int, List<double>> byWeekday = {};
    for (final d in dailyData) {
      final wd = d.date.weekday;
      byWeekday.putIfAbsent(wd, () => []);
      byWeekday[wd]!.add(d.outageMinutes / 60.0);
    }

    Map<int, double> result = {};
    for (final entry in byWeekday.entries) {
      final sum = entry.value.reduce((a, b) => a + b);
      final avg = sum / entry.value.length;
      result[entry.key] = avg;
      print(
          '[WorstDays] Weekday ${entry.key}: count=${entry.value.length}, sum=$sum, avg=$avg, values=${entry.value}');
    }

    return result;
  }

  // ============================================================
  // SWITCH LAG (Лаг включення/виключення)
  // ============================================================

  /// Середній лаг включення/виключення відносно графіка ДТЕК.
  Future<SwitchLag> getSwitchLag(
      int startDayOffset, int endDayOffset, String groupKey) async {
    final now = DateTime.now();
    List<double> onLags = [];
    List<double> offLags = [];

    for (int d = startDayOffset; d <= endDayOffset; d++) {
      final date =
          DateTime(now.year, now.month, now.day).subtract(Duration(days: d));
      final versions = await _historyService.getVersionsForDate(date, groupKey);
      if (versions.isEmpty) continue;

      final schedule = versions.last.toSchedule();
      final events = await _powerMonitor.getEventsForDate(date);

      // Знайти переходи в графіку
      for (int h = 1; h < 24; h++) {
        final prev = schedule.hours[h - 1];
        final curr = schedule.hours[h];

        // Перехід off→on (включення заплановано)
        if (_isOff(prev) && _isOn(curr)) {
          final scheduledTime = DateTime(date.year, date.month, date.day, h);
          final onEvent =
              _findClosestEvent(events, scheduledTime, 'online', 120);
          if (onEvent != null) {
            onLags.add(onEvent.timestamp
                .difference(scheduledTime)
                .inMinutes
                .toDouble());
          }
        }

        // Перехід on→off (виключення заплановано)
        if (_isOn(prev) && _isOff(curr)) {
          final scheduledTime = DateTime(date.year, date.month, date.day, h);
          final offEvent =
              _findClosestEvent(events, scheduledTime, 'offline', 120);
          if (offEvent != null) {
            offLags.add(offEvent.timestamp
                .difference(scheduledTime)
                .inMinutes
                .toDouble());
          }
        }

        // semiOn: off перші 30хв → on
        if (curr == LightStatus.semiOn && _isOff(prev)) {
          final scheduledTime =
              DateTime(date.year, date.month, date.day, h, 30);
          final onEvent =
              _findClosestEvent(events, scheduledTime, 'online', 120);
          if (onEvent != null) {
            onLags.add(onEvent.timestamp
                .difference(scheduledTime)
                .inMinutes
                .toDouble());
          }
        }

        // semiOff: on перші 30хв → off
        if (curr == LightStatus.semiOff && _isOn(prev)) {
          final scheduledTime =
              DateTime(date.year, date.month, date.day, h, 30);
          final offEvent =
              _findClosestEvent(events, scheduledTime, 'offline', 120);
          if (offEvent != null) {
            offLags.add(offEvent.timestamp
                .difference(scheduledTime)
                .inMinutes
                .toDouble());
          }
        }
      }
    }

    return SwitchLag(
      avgOnLagMinutes: onLags.isNotEmpty
          ? onLags.reduce((a, b) => a + b) / onLags.length
          : 0,
      avgOffLagMinutes: offLags.isNotEmpty
          ? offLags.reduce((a, b) => a + b) / offLags.length
          : 0,
      sampleCount: onLags.length + offLags.length,
    );
  }

  bool _isOff(LightStatus s) =>
      s == LightStatus.off ||
      s == LightStatus.semiOn ||
      s == LightStatus.semiOff;

  bool _isOn(LightStatus s) => s == LightStatus.on;

  PowerEvent? _findClosestEvent(List<PowerEvent> events, DateTime target,
      String status, int maxDiffMinutes) {
    PowerEvent? closest;
    int minDiff = maxDiffMinutes * 60;

    for (final e in events) {
      if (e.status.toLowerCase() != status) continue;
      final diff = (e.timestamp.difference(target).inSeconds).abs();
      if (diff < minDiff) {
        minDiff = diff;
        closest = e;
      }
    }

    return closest;
  }

  // ============================================================
  // PRODUCTIVITY (Продуктивність)
  // ============================================================

  /// Вплив відключень на робочі години та вечірній відпочинок.
  Future<ProductivityStats> getProductivityImpact(int days,
      {DataSourceMode mode = DataSourceMode.real,
      String groupKey = 'GPV1.1'}) async {
    final now = DateTime.now();
    int lostWorkMinutes = 0;
    int totalWorkMinutes = 0;
    int ruinedEvenings = 0;
    int totalEvenings = 0;

    for (int d = 0; d < days; d++) {
      final date =
          DateTime(now.year, now.month, now.day).subtract(Duration(days: d));
      // Тільки робочі дні (пн-пт)
      final isWorkday = date.weekday <= 5;
      final isToday = d == 0;

      final intervals =
          await _getIntervalsForDate(date, mode, groupKey: groupKey);

      if (isWorkday) {
        // Робочий час: 9:00–18:00
        final workStart = DateTime(date.year, date.month, date.day, 9);
        final workEnd = DateTime(date.year, date.month, date.day, 18);
        final effectiveWorkEnd =
            isToday && now.isBefore(workEnd) ? now : workEnd;

        if (!isToday || now.isAfter(workStart)) {
          final workDuration = effectiveWorkEnd.difference(workStart).inMinutes;
          totalWorkMinutes += workDuration > 0 ? workDuration : 0;

          for (final interval in intervals) {
            final start =
                interval.start.isBefore(workStart) ? workStart : interval.start;
            final end = (interval.end ?? now).isAfter(effectiveWorkEnd)
                ? effectiveWorkEnd
                : (interval.end ?? now);
            if (end.isAfter(start)) {
              lostWorkMinutes += end.difference(start).inMinutes;
            }
          }
        }
      }

      // Вечірній досуг: 19:00–23:00
      final eveningStart = DateTime(date.year, date.month, date.day, 19);
      final eveningEnd = DateTime(date.year, date.month, date.day, 23);

      if (!isToday || now.isAfter(eveningStart)) {
        totalEvenings++;
        final effectiveEveningEnd =
            isToday && now.isBefore(eveningEnd) ? now : eveningEnd;

        int eveningOffMinutes = 0;
        for (final interval in intervals) {
          final start = interval.start.isBefore(eveningStart)
              ? eveningStart
              : interval.start;
          final end = (interval.end ?? now).isAfter(effectiveEveningEnd)
              ? effectiveEveningEnd
              : (interval.end ?? now);
          if (end.isAfter(start)) {
            eveningOffMinutes += end.difference(start).inMinutes;
          }
        }
        // Вважаємо вечір "зіпсованим" якщо > 30 хв без світла
        if (eveningOffMinutes > 30) {
          ruinedEvenings++;
        }
      }
    }

    return ProductivityStats(
      lostWorkMinutes: lostWorkMinutes,
      totalWorkMinutes: totalWorkMinutes,
      ruinedEvenings: ruinedEvenings,
      totalEvenings: totalEvenings,
    );
  }

  // ============================================================
  // TIMELINE COMPARISON (Порівняння Прогноз vs Реальність)
  // ============================================================

  /// Дані для порівняльного таймлайна за дату.
  Future<TimelineComparisonData> getTimelineComparison(
      DateTime date, String groupKey) async {
    final versions = await _historyService.getVersionsForDate(date, groupKey);
    final intervals = await _powerMonitor.getOutageIntervalsForDate(date);

    DailySchedule? schedule;
    if (versions.isNotEmpty) {
      schedule = versions.last.toSchedule();
    }

    // Keep old slot logic for compatibility or remove if not needed.
    // For now, let's keep it to avoid breaking other things if they used it,
    // but the UI will switch to using intervals.

    final now = DateTime.now();
    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;
    final maxHour = isToday ? now.hour + 1 : 24;

    List<TimelineSlot> slots = [];
    for (int h = 0; h < 24; h++) {
      bool scheduledOn = true;
      if (schedule != null) {
        final status = schedule.hours[h];
        scheduledOn = status == LightStatus.on;
      }

      if (h >= maxHour) {
        slots.add(TimelineSlot(
          hour: h,
          scheduledOn: scheduledOn,
          actuallyOn: true,
          actualFraction: null,
        ));
        continue;
      }

      int offMinutes = 0;
      for (final interval in intervals) {
        offMinutes += interval.minutesOfflineInHour(date, h);
      }

      int minutesInHour = 60;
      if (isToday && h == now.hour) {
        minutesInHour = now.minute > 0 ? now.minute : 1;
      }

      final onFraction =
          1.0 - (offMinutes.clamp(0, minutesInHour) / minutesInHour);

      slots.add(TimelineSlot(
        hour: h,
        scheduledOn: scheduledOn,
        actuallyOn: offMinutes < 30,
        actualFraction: onFraction,
      ));
    }

    return TimelineComparisonData(
      slots: slots,
      schedule: schedule,
      realityIntervals: intervals,
    );
  }

  // ============================================================
  // GROUP COMPARISON (Порівняння груп)
  // ============================================================

  /// Порівняння всіх груп за [days] днів.
  /// Використовує лише дані графіків (predicted/forecast) з БД.
  Future<GroupComparisonResult> getGroupComparison(int days) async {
    final now = DateTime.now();
    final allGroups = ParserService.allGroups;
    final Map<String, int> totalOff = {};
    final Map<String, int> daysCount = {};

    for (final group in allGroups) {
      totalOff[group] = 0;
      daysCount[group] = 0;
    }

    for (int d = 0; d < days; d++) {
      final date =
          DateTime(now.year, now.month, now.day).subtract(Duration(days: d));

      for (final group in allGroups) {
        final versions = await _historyService.getVersionsForDate(date, group);
        if (versions.isEmpty) continue;

        final schedule = versions.last.toSchedule();
        int offMinutes = 0;
        for (int h = 0; h < 24; h++) {
          final status = schedule.hours[h];
          switch (status) {
            case LightStatus.off:
              offMinutes += 60;
              break;
            case LightStatus.semiOn:
              offMinutes += 30; // перші 30хв без світла
              break;
            case LightStatus.semiOff:
              offMinutes += 30; // другі 30хв без світла
              break;
            case LightStatus.maybe:
              offMinutes += 30; // песимістичний: рахуємо як 50%
              break;
            default:
              break;
          }
        }
        totalOff[group] = totalOff[group]! + offMinutes;
        daysCount[group] = daysCount[group]! + 1;
      }
    }

    // Формуємо список GroupStats
    final List<GroupStats> statsList = allGroups.map((g) {
      return GroupStats(
        groupKey: g,
        totalOffMinutes: totalOff[g]!,
        daysWithData: daysCount[g]!,
      );
    }).toList();

    // Сортуємо за хвилинами без світла (менше = краще)
    statsList.sort((a, b) => a.totalOffMinutes.compareTo(b.totalOffMinutes));

    // Середнє
    final totalAll =
        statsList.fold<int>(0, (sum, s) => sum + s.totalOffMinutes);
    final avg = statsList.isNotEmpty ? totalAll / statsList.length : 0.0;

    return GroupComparisonResult(
      ranked: statsList,
      bestGroup: statsList.isNotEmpty ? statsList.first.groupKey : '',
      worstGroup: statsList.isNotEmpty ? statsList.last.groupKey : '',
      averageOffMinutes: avg,
    );
  }
}

/// Допоміжний клас для підрахунку інтервалів.
class _IntervalData {
  final DateTime start;
  final DateTime end;

  _IntervalData(this.start, this.end);

  Duration get duration => end.difference(start);
}
