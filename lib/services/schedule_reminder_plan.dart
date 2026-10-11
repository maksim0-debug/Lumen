import 'dart:convert';

import 'package:timezone/timezone.dart' as tz;

import '../models/schedule_status.dart';
import 'schedule_clock.dart';

class ScheduleReminder {
  final int id;
  final String title;
  final String body;
  final tz.TZDateTime time;

  const ScheduleReminder(this.id, this.title, this.body, this.time);

  // Windows pending requests expose only IDs, so retain the full identity locally.
  String get identity => jsonEncode([time.millisecondsSinceEpoch, title, body]);
}

class ReminderPreferences {
  final bool off1h;
  final bool off30m;
  final bool off5m;
  final bool on1h;
  final bool on30m;

  const ReminderPreferences({
    required this.off1h,
    required this.off30m,
    required this.off5m,
    required this.on1h,
    required this.on30m,
  });
}

class _OutagePeriod {
  final int startSlot;
  final int endSlot;
  final bool hasKnownEnd;

  const _OutagePeriod(this.startSlot, this.endSlot, this.hasKnownEnd);
}

/// Pure construction of reminders; system cancellation and delivery live in the service.
class ScheduleReminderPlan {
  static List<ScheduleReminder> build({
    required FullSchedule schedule,
    required DateTime day,
    required int groupIndex,
    required ReminderPreferences preferences,
    String titlePrefix = '',
  }) {
    final today = schedule.today.toSlots();
    final slots = [...today, ...schedule.tomorrow.toSlots()];
    final periods = <_OutagePeriod>[];
    int? start;
    for (var i = 0; i < slots.length; i++) {
      final status = slots[i];
      if (start == null) {
        // Only today's outage starts are scheduled. Tomorrow may extend their ends.
        if (i >= today.length) break;
        if (status == SlotStatus.off) start = i;
      } else if (status != SlotStatus.off && status != SlotStatus.maybe) {
        periods.add(_OutagePeriod(start, i, status == SlotStatus.on));
        start = null;
      }
    }
    if (start != null) {
      periods.add(_OutagePeriod(start, slots.length, false));
    }

    final localDay = ScheduleClock.from(day);
    tz.TZDateTime atSlot(int slot) => ScheduleClock.calendar(
        localDay.year,
        localDay.month,
        localDay.day + slot ~/ 48,
        slot % 48 ~/ 2,
        slot % 2 * 30);
    String formatSlot(int slot) {
      final hour = (slot % 48 ~/ 2).toString().padLeft(2, '0');
      final minute = (slot % 2 * 30).toString().padLeft(2, '0');
      return '$hour:$minute${slot >= 48 ? ' (завтра)' : ''}';
    }

    final result = <ScheduleReminder>[];
    final prefix = groupIndex * 100000;
    int idFor(int slot, int kind) =>
        prefix + slot ~/ 2 * 1000 + slot % 2 * 300 + kind;

    for (final period in periods) {
      final startText = formatSlot(period.startSlot);
      final endText = formatSlot(period.endSlot);
      final durationText = period.hasKnownEnd
          ? 'до $endText'
          : 'час відновлення ще не опублікований';
      final startTime = atSlot(period.startSlot);
      if (preferences.off1h) {
        result.add(ScheduleReminder(
            idFor(period.startSlot, 1),
            '$titlePrefixСкоро відключення',
            'О $startText світла не буде ($durationText)',
            startTime.subtract(const Duration(hours: 1))));
      }
      if (preferences.off30m) {
        result.add(ScheduleReminder(
            idFor(period.startSlot, 4),
            '$titlePrefixСкоро відключення',
            'Через 30 хвилин ($startText) вимкнуть світло ($durationText)',
            startTime.subtract(const Duration(minutes: 30))));
      }
      if (preferences.off5m) {
        result.add(ScheduleReminder(
            idFor(period.startSlot, 2),
            '$titlePrefixУвага!',
            'Відключення через 5 хв ($startText), $durationText',
            startTime.subtract(const Duration(minutes: 5))));
      }
      if (!period.hasKnownEnd) continue;

      // Do not promise continuous light across an unknown or uncertain slot.
      String untilText = '';
      var nextSlot = period.endSlot;
      while (nextSlot < slots.length && slots[nextSlot] == SlotStatus.on) {
        nextSlot++;
      }
      if (nextSlot < slots.length && slots[nextSlot] == SlotStatus.off) {
        untilText = ' (до ${formatSlot(nextSlot)})';
      }
      final endTime = atSlot(period.endSlot);
      if (preferences.on1h) {
        result.add(ScheduleReminder(
            idFor(period.endSlot, 3),
            '$titlePrefixСкоро ввімкнення',
            'О $endText світло мають увімкнути$untilText',
            endTime.subtract(const Duration(hours: 1))));
      }
      if (preferences.on30m) {
        result.add(ScheduleReminder(
            idFor(period.endSlot, 5),
            '$titlePrefixСкоро ввімкнення',
            'Через 30 хвилин ($endText) світло мають увімкнути$untilText',
            endTime.subtract(const Duration(minutes: 30))));
      }
    }
    return result;
  }
}
