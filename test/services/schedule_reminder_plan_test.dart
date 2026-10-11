import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/services/schedule_reminder_plan.dart';

const allEnabled = ReminderPreferences(
    off1h: true, off30m: true, off5m: true, on1h: true, on30m: true);

FullSchedule scheduleWithOutage(int start, int end, {DailySchedule? tomorrow}) {
  final hours = List.filled(24, LightStatus.on);
  for (var i = start; i < end; i++) {
    hours[i] = LightStatus.off;
  }
  return FullSchedule(
      today: DailySchedule(hours), tomorrow: tomorrow ?? DailySchedule.empty());
}

void main() {
  List<ScheduleReminder> plan(FullSchedule schedule, DateTime day,
          {ReminderPreferences preferences = allEnabled}) =>
      ScheduleReminderPlan.build(
          schedule: schedule,
          day: day,
          groupIndex: 2,
          preferences: preferences);

  test('known outage keeps deterministic IDs and all five reminder kinds', () {
    final reminders =
        plan(scheduleWithOutage(18, 20), ScheduleClock.calendar(2026, 10, 11));
    expect(
        reminders.map((r) => r.id), [218001, 218004, 218002, 220003, 220005]);
    expect(reminders.map((r) => '${r.time.hour}:${r.time.minute}'),
        ['17:0', '17:30', '17:55', '19:0', '19:30']);
  });

  test('unknown tomorrow cannot invent a midnight restoration', () {
    final reminders =
        plan(scheduleWithOutage(22, 24), ScheduleClock.calendar(2026, 10, 11));
    expect(reminders, hasLength(3));
    expect(reminders.every((r) => r.id % 10 != 3 && r.id % 10 != 5), isTrue);
    expect(reminders.map((r) => r.body),
        everyElement(contains('час відновлення ще не опублікований')));
    expect(
        reminders.map((r) => r.body), everyElement(isNot(contains('00:00'))));
  });

  test('unknown within today is also not a known restoration', () {
    final schedule = scheduleWithOutage(12, 14);
    schedule.today.hours[14] = LightStatus.unknown;
    expect(plan(schedule, ScheduleClock.calendar(2026, 10, 11)), hasLength(3));
  });

  test('two full outage days have no fabricated end at the data horizon', () {
    final off = DailySchedule.fromEncodedString('1' * 24);
    final reminders = plan(FullSchedule(today: off, tomorrow: off),
        ScheduleClock.calendar(2026, 10, 11));
    expect(reminders, hasLength(3));
    expect(reminders.map((r) => r.body),
        everyElement(contains('час відновлення ще не опублікований')));
  });

  test('known light at midnight permits restoration reminders', () {
    final reminders = plan(
        scheduleWithOutage(22, 24,
            tomorrow: DailySchedule.fromEncodedString('0' * 24)),
        ScheduleClock.calendar(2026, 10, 11));
    expect(reminders, hasLength(5));
    expect(reminders.last.body, contains('00:00 (завтра)'));
    expect(reminders.last.time, ScheduleClock.calendar(2026, 10, 11, 23, 30));
  });

  for (final date in [(2026, 3, 29), (2026, 10, 25)]) {
    test('restoration stays at wall-clock 20:00 across DST on $date', () {
      final day = ScheduleClock.calendar(date.$1, date.$2, date.$3);
      final reminders = plan(scheduleWithOutage(18, 20), day);
      expect(reminders[3].time,
          ScheduleClock.calendar(date.$1, date.$2, date.$3, 19));
      expect(reminders[4].time,
          ScheduleClock.calendar(date.$1, date.$2, date.$3, 19, 30));
      expect(reminders[3].body, contains('20:00'));
    });
  }

  test('overnight restoration uses the next calendar date across DST', () {
    final tomorrow = DailySchedule.fromEncodedString('${'1' * 5}${'0' * 19}');
    final reminders = plan(scheduleWithOutage(22, 24, tomorrow: tomorrow),
        ScheduleClock.calendar(2026, 3, 28));
    expect(reminders[3].time, ScheduleClock.calendar(2026, 3, 29, 4));
    expect(reminders[4].time, ScheduleClock.calendar(2026, 3, 29, 4, 30));
  });

  test('half-hour boundaries retain the existing notification IDs', () {
    final schedule = scheduleWithOutage(18, 20);
    schedule.today.hours[18] = LightStatus.semiOff;
    schedule.today.hours[20] = LightStatus.semiOn;
    final reminders = plan(schedule, ScheduleClock.calendar(2026, 10, 11));
    expect(
        reminders.map((r) => r.id), [218301, 218304, 218302, 220303, 220305]);
    expect(reminders[2].time.minute, 25);
    expect(reminders.last.body, contains('20:30'));
  });

  test('uncertain continuity does not create a new outage or promise light',
      () {
    final schedule = scheduleWithOutage(12, 14);
    schedule.today.hours[14] = LightStatus.maybe;
    schedule.today.hours[16] = LightStatus.unknown;
    schedule.today.hours[18] = LightStatus.off;
    final reminders = plan(schedule, ScheduleClock.calendar(2026, 10, 11));
    expect(reminders[3].body, contains('15:00'));
    expect(reminders[3].body, isNot(contains('(до')));
  });

  test('disabled reminder preferences produce no notifications', () {
    expect(
        plan(scheduleWithOutage(18, 20), ScheduleClock.calendar(2026, 10, 11),
            preferences: const ReminderPreferences(
                off1h: false,
                off30m: false,
                off5m: false,
                on1h: false,
                on30m: false)),
        isEmpty);
  });
}
