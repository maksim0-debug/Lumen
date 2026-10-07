import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/analytics_models.dart';
import 'package:lumen/models/power_event.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/light_balance_calculator.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/utils/app_formatters.dart';

void main() {
  final day = ScheduleClock.calendar(2026, 10, 6);
  final tomorrow = ScheduleClock.day(day, 1);
  PowerEvent event(DateTime time, String state) => PowerEvent(
      firebaseKey: time.toIso8601String(), status: state, timestamp: time);
  DailySchedule schedule(String code) => DailySchedule.fromEncodedString(code);
  ScheduleDeviationStats calculate({
    DailySchedule? plan,
    List<PowerEvent>? events,
    DateTime? now,
    DateTime? through,
    ScheduleDeviationPeriod period = ScheduleDeviationPeriod.yesterday,
    Map<String, DailySchedule>? plans,
  }) =>
      LightBalanceCalculator.calculate(
          period: period,
          now: now ?? tomorrow.add(const Duration(hours: 12)),
          schedules: plans ??
              {AppFormatters.formatDateKey(day): plan ?? schedule('0' * 24)},
          events: events ?? [event(day, 'online')],
          observedThrough: through ?? tomorrow);

  test('early restoration adds forty minutes relative to twelve planned hours',
      () {
    final data = calculate(plan: schedule('1' * 12 + '0' * 12), events: [
      event(day, 'offline'),
      event(day.add(const Duration(hours: 11, minutes: 20)), 'online')
    ]);
    expect(data.balance.plannedOnSeconds, 720 * 60);
    expect(data.balance.actualOnSeconds, 760 * 60);
    expect(data.balance.averageDeltaMinutes, 40);
    expect(data.balance.relativePercentage, closeTo(5.555555, 0.00001));
    expect(data.lag.onSampleCount, 1);
    expect(data.lag.offSampleCount, 0);
    expect(data.lag.avgOnLagMinutes, -40);
  });

  test('late restoration reports a negative difference and percentage', () {
    final data = calculate(plan: schedule('1' * 12 + '0' * 12), events: [
      event(day, 'offline'),
      event(day.add(const Duration(hours: 12, minutes: 40)), 'online')
    ]);
    expect(data.balance.actualOnSeconds, 680 * 60);
    expect(data.balance.averageDeltaMinutes, -40);
    expect(data.balance.relativePercentage, closeTo(-5.555555, 0.00001));
    expect(data.lag.avgOnLagMinutes, 40);
  });

  test('equal total durations can have displaced switching times', () {
    final data =
        calculate(plan: schedule('0' * 10 + '1' * 2 + '0' * 12), events: [
      event(day, 'online'),
      event(day.add(const Duration(hours: 11)), 'offline'),
      event(day.add(const Duration(hours: 13)), 'online')
    ]);
    expect(data.balance.deltaSeconds, 0);
    expect(data.balance.relativePercentage, 0);
    expect(data.lag.avgOnLagMinutes, 60);
    expect(data.lag.avgOffLagMinutes, 60);
    expect(data.lag.sampleCount, 2);
  });

  test('cancelled outage still has a balance with no switching samples', () {
    final data = calculate(plan: schedule('0' * 10 + '1' * 2 + '0' * 12));
    expect(data.balance.averageDeltaMinutes, 120);
    expect(data.lag.sampleCount, 0);
  });

  test('today clips the forecast and ongoing outage to the same precise time',
      () {
    final now = day.add(const Duration(hours: 8, minutes: 15, seconds: 30));
    final data = calculate(
        period: ScheduleDeviationPeriod.today,
        now: now,
        through: now,
        events: [
          event(day, 'online'),
          event(day.add(const Duration(hours: 8)), 'offline')
        ]);
    expect(data.balance.plannedOnSeconds, 8 * 3600 + 15 * 60 + 30);
    expect(data.balance.deltaSeconds, -(15 * 60 + 30));
    expect(data.balance.averageDeltaMinutes, -15.5);
  });

  test('unknown future slots do not invalidate known elapsed time today', () {
    final now = day.add(const Duration(hours: 8));
    final data = calculate(
        period: ScheduleDeviationPeriod.today,
        now: now,
        through: now,
        plan: schedule('0' * 8 + '9' * 16));
    expect(data.balance.validDays, 1);
    expect(data.balance.plannedOnSeconds, 8 * 3600);
  });

  test('half-hour transitions respect which half is offline', () {
    final data = calculate(plan: schedule("23${'0' * 22}"), events: [
      event(day, 'offline'),
      event(day.add(const Duration(minutes: 30)), 'online'),
      event(day.add(const Duration(minutes: 90)), 'offline'),
      event(day.add(const Duration(hours: 2)), 'online')
    ]);
    expect(data.balance.plannedOnSeconds, 23 * 3600);
    expect(data.balance.deltaSeconds, 0);
    expect(data.lag.onSampleCount, 2);
    expect(data.lag.offSampleCount, 1);
    expect(data.lag.avgOnLagMinutes, 0);
    expect(data.lag.avgOffLagMinutes, 0);
  });

  test(
      'week excludes today and averages only eligible days with a weighted percent',
      () {
    final first = ScheduleClock.day(tomorrow, -7);
    final plans = {
      AppFormatters.formatDateKey(first): schedule('1' * 14 + '0' * 10),
      AppFormatters.formatDateKey(ScheduleClock.day(first, 1)):
          schedule('1' * 4 + '0' * 20),
      AppFormatters.formatDateKey(tomorrow): schedule('1' * 24),
    };
    final events = <PowerEvent>[];
    for (int i = 0; i < 2; i++) {
      final date = ScheduleClock.day(first, i);
      events.addAll([
        event(date, 'offline'),
        event(date.add(const Duration(hours: 9)), 'online')
      ]);
    }
    final data = calculate(
        period: ScheduleDeviationPeriod.week, plans: plans, events: events);
    expect(data.balance.start, first);
    expect(data.balance.end, tomorrow);
    expect(data.balance.validDays, 2);
    expect(data.balance.excludedDays, 5);
    expect(data.balance.plannedOnSeconds, 30 * 3600);
    expect(data.balance.actualOnSeconds, 30 * 3600);
    expect(data.balance.averageDeltaMinutes, 0);
    expect(data.balance.relativePercentage, 0);
  });

  test('month uses thirty calendar days across year boundaries', () {
    final now = ScheduleClock.calendar(2027, 1, 2, 12);
    expect(
        LightBalanceCalculator.periodStart(ScheduleDeviationPeriod.month, now),
        ScheduleClock.calendar(2026, 12, 3));
    expect(LightBalanceCalculator.periodEnd(ScheduleDeviationPeriod.month, now),
        ScheduleClock.calendar(2027, 1, 2));
  });

  test('empty event history is missing data rather than a fully online day',
      () {
    final data = calculate(events: []);
    expect(data.balance.hasData, isFalse);
    expect(data.balance.exclusions[LightBalanceExclusion.incompleteActual], 1);
    expect(data.balance.averageDeltaMinutes, isNull);
    expect(data.balance.relativePercentage, isNull);
  });

  test('first event in the middle of a day cannot establish its initial state',
      () {
    final data = calculate(
        events: [event(day.add(const Duration(hours: 12)), 'online')]);
    expect(data.balance.hasData, isFalse);
  });

  test('state before midnight carries through a day without any events', () {
    final data =
        calculate(events: [event(ScheduleClock.day(day, -1), 'online')]);
    expect(data.balance.actualOnSeconds, 24 * 3600);
    expect(data.balance.validDays, 1);
  });

  test('state and coverage cannot be extended beyond the last observation', () {
    final data = calculate(through: day.add(const Duration(hours: 23)));
    expect(data.balance.hasData, isFalse);
  });

  test('future observation timestamps and events cannot supply future data',
      () {
    final now = day.add(const Duration(hours: 12));
    final data = calculate(
        period: ScheduleDeviationPeriod.today,
        now: now,
        through: tomorrow,
        events: [event(day, 'online'), event(tomorrow, 'offline')]);
    expect(data.balance.actualOnSeconds, 12 * 3600);
    expect(data.lag.sampleCount, 0);
  });

  test('a later event establishes coverage of a completed historical day', () {
    final data = LightBalanceCalculator.calculate(
        period: ScheduleDeviationPeriod.yesterday,
        now: tomorrow.add(const Duration(hours: 1)),
        schedules: {AppFormatters.formatDateKey(day): schedule('0' * 24)},
        events: [event(day, 'online'), event(tomorrow, 'offline')]);
    expect(data.balance.actualOnSeconds, 24 * 3600);
  });

  test('unknown and conflicting simultaneous states exclude the affected day',
      () {
    for (final unknownEvents in [
      [event(day.add(const Duration(hours: 1)), 'unknown')],
      [
        event(day.add(const Duration(hours: 1)), 'online'),
        event(day.add(const Duration(hours: 1)), 'offline')
      ],
    ]) {
      final data = calculate(events: [
        event(day, 'online'),
        ...unknownEvents,
        event(day.add(const Duration(hours: 2)), 'online')
      ]);
      expect(data.balance.hasData, isFalse);
    }
  });

  test('unsorted and duplicate heartbeats do not double-count time or lag', () {
    final data =
        calculate(plan: schedule('0' * 10 + '1' * 2 + '0' * 12), events: [
      event(day.add(const Duration(hours: 12)), 'online'),
      event(day.add(const Duration(hours: 10)), 'offline'),
      event(day, 'online'),
      event(day.add(const Duration(hours: 11)), 'offline'),
      event(day.add(const Duration(hours: 12)), 'online')
    ]);
    expect(data.balance.deltaSeconds, 0);
    expect(data.lag.sampleCount, 2);
  });

  test('subsecond event boundaries retain complete coverage and round once',
      () {
    final data = calculate(events: [
      event(day, 'online'),
      event(day.add(const Duration(hours: 1, microseconds: 100)), 'offline'),
      event(day.add(const Duration(hours: 1, seconds: 30, microseconds: 100)),
          'online')
    ]);
    expect(data.balance.hasData, isTrue);
    expect(data.balance.deltaSeconds, -30);
  });

  test('outage crossing midnight is clipped to the selected day', () {
    final data = calculate(events: [
      event(day.subtract(const Duration(hours: 1)), 'offline'),
      event(day.add(const Duration(hours: 2)), 'online')
    ]);
    expect(data.balance.actualOnSeconds, 22 * 3600);
    expect(data.balance.averageDeltaMinutes, -120);
  });

  test(
      'zero planned online time has a meaningful absolute delta and no percent',
      () {
    final data = calculate(plan: schedule('1' * 24));
    expect(data.balance.averageDeltaMinutes, 1440);
    expect(data.balance.relativePercentage, isNull);
  });

  test('relative percentages greater than one hundred are not clamped', () {
    final data = calculate(plan: schedule('1' * 23 + '0'));
    expect(data.balance.relativePercentage, 2300);
  });

  for (final status in ['4', '9']) {
    test('uncertain elapsed schedule status $status excludes the day', () {
      final data = calculate(plan: schedule('0' * 12 + status + '0' * 11));
      expect(data.balance.hasData, isFalse);
      expect(
          data.balance.exclusions[LightBalanceExclusion.uncertainSchedule], 1);
    });
  }
  test('missing or malformed schedules have a distinct exclusion reason', () {
    for (final plans in [
      <String, DailySchedule>{},
      {AppFormatters.formatDateKey(day): DailySchedule.empty()},
      {AppFormatters.formatDateKey(day): DailySchedule([])}
    ]) {
      final data = calculate(plans: plans);
      expect(data.balance.exclusions[LightBalanceExclusion.missingSchedule], 1);
    }
  });

  test('exact midnight today has no elapsed data', () {
    final data = calculate(
        period: ScheduleDeviationPeriod.today, now: day, through: day);
    expect(data.balance.hasData, isFalse);
    expect(data.lag.sampleCount, 0);
  });

  test('lag matches a midnight transition against the previous schedule', () {
    final previous = ScheduleClock.day(day, -1);
    final data = calculate(plans: {
      AppFormatters.formatDateKey(previous): schedule('1' * 24),
      AppFormatters.formatDateKey(day): schedule('0' * 24),
    }, events: [
      event(previous, 'offline'),
      event(day.subtract(const Duration(minutes: 10)), 'online')
    ]);
    expect(data.lag.onSampleCount, 1);
    expect(data.lag.avgOnLagMinutes, -10);
  });

  test('lag never matches future planned transitions or unknown initial states',
      () {
    final now = day.add(const Duration(hours: 10));
    final data = calculate(
        period: ScheduleDeviationPeriod.today,
        now: now,
        through: now,
        plan: schedule('1' * 11 + '0' * 13),
        events: [event(day.add(const Duration(hours: 9)), 'online')]);
    expect(data.lag.sampleCount, 0);
  });

  test('one real switching event cannot be reused for two planned transitions',
      () {
    final data =
        calculate(plan: schedule("${'0' * 10}101${'0' * 11}"), events: [
      event(day, 'online'),
      event(day.add(const Duration(hours: 11)), 'offline'),
      event(day.add(const Duration(hours: 12)), 'online')
    ]);
    expect(data.lag.onSampleCount, 1);
    expect(data.lag.offSampleCount, 1);
  });

  test('switching outside the two hour window still contributes to the balance',
      () {
    final data = calculate(plan: schedule('1' * 12 + '0' * 12), events: [
      event(day, 'offline'),
      event(day.add(const Duration(hours: 15)), 'online')
    ]);
    expect(data.balance.averageDeltaMinutes, -180);
    expect(data.lag.sampleCount, 0);
  });

  for (final entry in [(3, 29, 23), (10, 25, 25)]) {
    test('Kyiv DST ${entry.$1} day uses ${entry.$3} actual hours', () {
      final date = ScheduleClock.calendar(2026, entry.$1, entry.$2);
      final end = ScheduleClock.day(date, 1);
      final data = LightBalanceCalculator.calculate(
          period: ScheduleDeviationPeriod.yesterday,
          now: end,
          observedThrough: end,
          schedules: {AppFormatters.formatDateKey(date): schedule('0' * 24)},
          events: [event(date, 'online')]);
      expect(data.balance.plannedOnSeconds, entry.$3 * 3600);
      expect(data.balance.actualOnSeconds, entry.$3 * 3600);
      expect(data.balance.deltaSeconds, 0);
    });
  }

  test('repeated autumn hour applies its offline schedule twice', () {
    final date = ScheduleClock.calendar(2026, 10, 25),
        end = ScheduleClock.calendar(2026, 10, 26);
    final data = LightBalanceCalculator.calculate(
        period: ScheduleDeviationPeriod.yesterday,
        now: end,
        observedThrough: end,
        schedules: {
          AppFormatters.formatDateKey(date): schedule("0001${'0' * 20}")
        },
        events: [
          event(date, 'online')
        ]);
    expect(data.balance.plannedOnSeconds, 23 * 3600);
    expect(data.balance.deltaSeconds, 2 * 3600);
  });

  test(
      'today ends at the last poll rather than treating its tail as missing data',
      () {
    final now = day.add(const Duration(hours: 12, seconds: 30));
    final through = day.add(const Duration(hours: 12));
    final data = calculate(
        period: ScheduleDeviationPeriod.today, now: now, through: through);
    expect(data.balance.hasData, isTrue);
    expect(data.balance.end, through);
    expect(data.balance.actualOnSeconds, 12 * 3600);
    expect(data.balance.plannedOnSeconds, 12 * 3600);
  });

  test('today with only old observations does not silently switch to yesterday',
      () {
    final data = calculate(
        period: ScheduleDeviationPeriod.today,
        now: day.add(const Duration(hours: 12)),
        through: ScheduleClock.day(day, -1),
        events: [event(ScheduleClock.day(day, -1), 'online')]);
    expect(data.balance.start, day);
    expect(data.balance.end, day);
    expect(data.balance.hasData, isFalse);
  });

  test('UTC inputs produce the same Kyiv calendar period and durations', () {
    final data = LightBalanceCalculator.calculate(
        period: ScheduleDeviationPeriod.yesterday,
        now: tomorrow.toUtc(),
        observedThrough: tomorrow.toUtc(),
        schedules: {AppFormatters.formatDateKey(day): schedule('0' * 24)},
        events: [event(day.toUtc(), 'online')]);
    expect(data.balance.start, day);
    expect(data.balance.actualOnSeconds, 24 * 3600);
  });

  test(
      'a transition exactly two hours late matches, one microsecond beyond does not',
      () {
    for (final microseconds in [0, 1]) {
      final data = calculate(plan: schedule('1' * 12 + '0' * 12), events: [
        event(day, 'offline'),
        event(
            day.add(Duration(hours: 14, microseconds: microseconds)), 'online')
      ]);
      expect(data.lag.onSampleCount, microseconds == 0 ? 1 : 0);
    }
  });

  test('fractional-second switching lag retains its sign and precision', () {
    final data = calculate(plan: schedule('1' * 12 + '0' * 12), events: [
      event(day, 'offline'),
      event(
          day
              .add(const Duration(hours: 12))
              .subtract(const Duration(microseconds: 500000)),
          'online')
    ]);
    expect(data.lag.avgOnLagMinutes, closeTo(-0.5 / 60, 0.000000001));
  });

  test('randomized records agree with an independent per-minute time ledger',
      () {
    final random = Random(20261007);
    for (int run = 0; run < 40; run++) {
      final code =
          List.generate(24, (_) => random.nextInt(4).toString()).join();
      final plan = schedule(code);
      final records = <PowerEvent>[];
      bool online = true;
      int actualMinutes = 0;
      for (int minute = 0; minute < 1440; minute++) {
        if (minute == 0 || random.nextInt(50) == 0) {
          if (minute != 0) online = !online;
          records.add(event(day.add(Duration(minutes: minute)),
              online ? 'online' : 'offline'));
        }
        if (online) actualMinutes++;
      }
      final data = calculate(plan: plan, events: records);
      expect(data.balance.actualOnSeconds, actualMinutes * 60,
          reason: 'run $run');
      expect(
          data.balance.plannedOnSeconds, (1440 - plan.totalOutageMinutes) * 60);
      expect(data.balance.deltaSeconds,
          (actualMinutes - (1440 - plan.totalOutageMinutes)) * 60);
      expect(data.lag.sampleCount, lessThanOrEqualTo(records.length - 1));
    }
  });
}
