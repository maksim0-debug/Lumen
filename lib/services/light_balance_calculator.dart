import '../models/analytics_models.dart';
import '../models/power_event.dart';
import '../models/schedule_status.dart';
import '../utils/app_formatters.dart';
import 'schedule_clock.dart';

/// Compares recorded sensor states with the latest stored schedules.
/// Unknown time is never inferred to be online. Event states persist until the
/// next event, but only as far as the last observation/successful synchronization.
class LightBalanceCalculator {
  static DateTime periodStart(ScheduleDeviationPeriod period, DateTime now) =>
      ScheduleClock.day(
          now, period == ScheduleDeviationPeriod.today ? 0 : -period.dayCount);

  static DateTime periodEnd(ScheduleDeviationPeriod period, DateTime now) =>
      period == ScheduleDeviationPeriod.today
          ? ScheduleClock.from(now)
          : ScheduleClock.day(now);

  static ScheduleDeviationStats calculate({
    required ScheduleDeviationPeriod period,
    required DateTime now,
    required Map<String, DailySchedule> schedules,
    required List<PowerEvent> events,
    DateTime? observedThrough,
  }) {
    final start = periodStart(period, now);
    var end = periodEnd(period, now);
    final ordered = events.where((e) => !e.timestamp.isAfter(now)).toList()
      ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    // Conflicting simultaneous states are ambiguous, regardless of DB row order.
    final changes = <_StateChange>[];
    for (final event in ordered) {
      final state = event.isOnline ? true : (event.isOffline ? false : null);
      if (changes.isNotEmpty &&
          changes.last.time.isAtSameMomentAs(event.timestamp)) {
        final previous = changes.removeLast();
        changes.add(_StateChange(
            event.timestamp, previous.state == state ? state : null));
      } else {
        changes.add(_StateChange(event.timestamp, state));
      }
    }
    DateTime? through = observedThrough;
    if (changes.isNotEmpty &&
        (through == null || changes.last.time.isAfter(through))) {
      through = changes.last.time;
    }
    if (through != null && through.isAfter(now)) through = now;
    // A polling source normally lags the wall clock by a few seconds. Compare
    // today's elapsed forecast only through its last recorded observation.
    if (period == ScheduleDeviationPeriod.today &&
        through != null &&
        through.isBefore(end)) {
      end = through.isBefore(start) ? start : through;
    }

    final actual = <_StateSpan>[];
    final switches = <_StateChange>[];
    bool? state;
    DateTime? cursor;
    for (final change in changes) {
      if (cursor != null && change.time.isAfter(cursor)) {
        actual.add(_StateSpan(cursor, change.time, state));
      }
      if (state != null && change.state != null && state != change.state) {
        switches.add(change);
      }
      cursor = change.time;
      state = change.state;
    }
    if (cursor != null && through != null && through.isAfter(cursor)) {
      actual.add(_StateSpan(cursor, through, state));
    }

    final exclusions = <LightBalanceExclusion, int>{};
    void exclude(LightBalanceExclusion reason) =>
        exclusions.update(reason, (count) => count + 1, ifAbsent: () => 1);
    int plannedTotal = 0, actualTotal = 0, validDays = 0, actualIndex = 0;
    final plannedSwitches = <_StateChange>[];
    bool? previousPlannedState;

    // Include the previous day for a genuine transition at midnight.
    for (int offset = -1; offset < period.dayCount; offset++) {
      final day = ScheduleClock.day(start, offset);
      final dayEnd = ScheduleClock.day(day, 1);
      final comparisonEnd = dayEnd.isAfter(end) ? end : dayEnd;
      final schedule = schedules[AppFormatters.formatDateKey(day)];
      final slots = schedule != null && schedule.hours.length == 24
          ? schedule.toSlots()
          : null;
      int plannedOn = 0;
      bool uncertain = false;
      // Iterate real instants: spring's missing hour is skipped; autumn's
      // repeated hour uses the same wall-clock schedule on both occurrences.
      for (DateTime time = day; time.isBefore(comparisonEnd);) {
        final next = time.add(const Duration(minutes: 30));
        final slotEnd = next.isAfter(comparisonEnd) ? comparisonEnd : next;
        final local = ScheduleClock.from(time);
        final slot = slots?[local.hour * 2 + local.minute ~/ 30];
        final on = slot == SlotStatus.on
            ? true
            : (slot == SlotStatus.off ? false : null);
        if (!time.isBefore(start) &&
            previousPlannedState != null &&
            on != null &&
            on != previousPlannedState) {
          plannedSwitches.add(_StateChange(time, on));
        }
        previousPlannedState = on;
        if (on == null) uncertain = true;
        if (on == true) plannedOn += slotEnd.difference(time).inMicroseconds;
        time = slotEnd;
      }
      if (offset < 0) continue;
      if (!comparisonEnd.isAfter(day)) {
        exclude(LightBalanceExclusion.incompleteActual);
        continue;
      }
      if (slots == null || schedule!.isEmpty) {
        exclude(LightBalanceExclusion.missingSchedule);
        continue;
      }
      if (uncertain) {
        exclude(LightBalanceExclusion.uncertainSchedule);
        continue;
      }
      while (actualIndex < actual.length &&
          !actual[actualIndex].end.isAfter(day)) {
        actualIndex++;
      }
      int knownMicros = 0, actualOn = 0;
      for (int i = actualIndex;
          i < actual.length && actual[i].start.isBefore(comparisonEnd);
          i++) {
        final span = actual[i];
        if (span.state == null) continue;
        final from = span.start.isBefore(day) ? day : span.start;
        final to = span.end.isAfter(comparisonEnd) ? comparisonEnd : span.end;
        final micros = to.difference(from).inMicroseconds;
        if (micros <= 0) continue;
        knownMicros += micros;
        if (span.state!) actualOn += micros;
      }
      if (knownMicros != comparisonEnd.difference(day).inMicroseconds) {
        exclude(LightBalanceExclusion.incompleteActual);
        continue;
      }
      validDays++;
      plannedTotal += plannedOn;
      actualTotal += actualOn;
    }

    return ScheduleDeviationStats(
      balance: LightBalanceStats(
        period: period,
        start: start,
        end: end,
        plannedOnSeconds: plannedTotal ~/ Duration.microsecondsPerSecond,
        actualOnSeconds: actualTotal ~/ Duration.microsecondsPerSecond,
        validDays: validDays,
        exclusions: exclusions,
      ),
      lag: _switchLag(plannedSwitches, switches),
    );
  }

  static SwitchLag _switchLag(
      List<_StateChange> planned, List<_StateChange> actual) {
    final on = <double>[], off = <double>[];
    for (final state in [true, false]) {
      final candidates = actual.where((event) => event.state == state).toList();
      int nextCandidate = 0;
      for (final target in planned.where((event) => event.state == state)) {
        const window = Duration(hours: 2);
        while (nextCandidate < candidates.length &&
            candidates[nextCandidate]
                .time
                .isBefore(target.time.subtract(window))) {
          nextCandidate++;
        }
        int? closest;
        int distance = window.inMicroseconds + 1;
        for (int i = nextCandidate; i < candidates.length; i++) {
          final difference =
              candidates[i].time.difference(target.time).inMicroseconds;
          if (difference > window.inMicroseconds) break;
          if (difference.abs() < distance) {
            closest = i;
            distance = difference.abs();
          }
        }
        if (closest != null) {
          final minutes =
              candidates[closest].time.difference(target.time).inMicroseconds /
                  Duration.microsecondsPerMinute;
          (state ? on : off).add(minutes);
          // Match chronologically and use each actual transition only once.
          nextCandidate = closest + 1;
        }
      }
    }
    double average(List<double> values) =>
        values.isEmpty ? 0 : values.reduce((a, b) => a + b) / values.length;
    return SwitchLag(
        avgOnLagMinutes: average(on),
        avgOffLagMinutes: average(off),
        sampleCount: on.length + off.length,
        onSampleCount: on.length,
        offSampleCount: off.length);
  }
}

class _StateChange {
  final DateTime time;
  final bool? state;
  const _StateChange(this.time, this.state);
}

class _StateSpan {
  final DateTime start;
  final DateTime end;
  final bool? state;
  const _StateSpan(this.start, this.end, this.state);
}
