import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/countdown_service.dart';

void main() {
  group('CountdownService - BDD Scenarios (Tier A)', () {
    test(
        'GIVEN today has power all day (all ON) '
        'AND tomorrow has no schedule data (empty / unknown) '
        'WHEN calculating countdown at 22:51 '
        'THEN returns null (card should not be displayed, no false outage at 24:00)',
        () {
      // 24 hours of LightStatus.on
      final today = DailySchedule(List.filled(24, LightStatus.on));
      final tomorrow = DailySchedule.empty(); // all unknown

      final now = DateTime(2026, 9, 30, 22, 51);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: tomorrow,
        now: now,
      );

      expect(result, isNull,
          reason:
              'No countdown should be shown when tomorrow schedule is absent');
    });

    test(
        'GIVEN today has power all day '
        'AND tomorrow has scheduled outage starting at 00:00 '
        'WHEN calculating countdown at 22:51 '
        'THEN returns countdown of 69 minutes with "До відключення: 1г 9хв"',
        () {
      final today = DailySchedule(List.filled(24, LightStatus.on));
      // Tomorrow starts with OFF at 00:00
      final tomorrowHours = List.filled(24, LightStatus.on);
      tomorrowHours[0] = LightStatus.off;
      final tomorrow = DailySchedule(tomorrowHours);

      final now = DateTime(2026, 9, 30, 22, 51);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: tomorrow,
        now: now,
      );

      expect(result, isNotNull);
      expect(result!.minutesRemaining, 69);
      expect(result.targetStatus, SlotStatus.off);
      expect(result.message, 'До відключення: 1г 9хв');
    });

    test(
        'GIVEN today has power all day '
        'AND tomorrow has outage starting at 08:00 '
        'WHEN calculating countdown at 22:00 '
        'THEN returns countdown to tomorrow 08:00 (10 hours = 600 mins)', () {
      final today = DailySchedule(List.filled(24, LightStatus.on));
      final tomorrowHours = List.filled(24, LightStatus.on);
      tomorrowHours[8] = LightStatus.off; // 08:00
      final tomorrow = DailySchedule(tomorrowHours);

      final now = DateTime(2026, 9, 30, 22, 0);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: tomorrow,
        now: now,
      );

      expect(result, isNotNull);
      expect(result!.minutesRemaining, 600); // 2 hours today + 8 hours tomorrow
      expect(result.targetStatus, SlotStatus.off);
      expect(result.message, 'До відключення: 10г 0хв');
    });

    test(
        'GIVEN power is currently OFF at 20:00 '
        'AND power will turn ON at 22:00 today '
        'WHEN calculating countdown '
        'THEN returns countdown of 120 minutes with "До ввімкнення: 2г 0хв"',
        () {
      final hours = List.filled(24, LightStatus.on);
      hours[20] = LightStatus.off;
      hours[21] = LightStatus.off;
      // 22:00 and onwards is ON
      final today = DailySchedule(hours);
      final tomorrow = DailySchedule.empty();

      final now = DateTime(2026, 9, 30, 20, 0);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: tomorrow,
        now: now,
      );

      expect(result, isNotNull);
      expect(result!.minutesRemaining, 120);
      expect(result.targetStatus, SlotStatus.on);
      expect(result.message, 'До ввімкнення: 2г 0хв');
    });

    test(
        'GIVEN power is currently OFF at 22:00 until end of day (24:00) '
        'AND tomorrow has no schedule data '
        'WHEN calculating countdown '
        'THEN returns null (do not falsely promise power restoration at 24:00)',
        () {
      final hours = List.filled(24, LightStatus.on);
      hours[22] = LightStatus.off;
      hours[23] = LightStatus.off;
      final today = DailySchedule(hours);
      final tomorrow = DailySchedule.empty();

      final now = DateTime(2026, 9, 30, 22, 15);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: tomorrow,
        now: now,
      );

      expect(result, isNull);
    });

    test(
        'GIVEN power is ON '
        'AND next slot is maybe (gray zone) '
        'WHEN calculating countdown '
        'THEN message says "До можл. відключення: ..."', () {
      final hours = List.filled(24, LightStatus.on);
      hours[15] = LightStatus.maybe;
      final today = DailySchedule(hours);

      final now = DateTime(2026, 9, 30, 14, 0);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: DailySchedule.empty(),
        now: now,
      );

      expect(result, isNotNull);
      expect(result!.minutesRemaining, 60);
      expect(result.targetStatus, SlotStatus.maybe);
      expect(result.message, 'До можл. відключення: 1г 0хв');
    });

    test(
        'GIVEN both today and tomorrow are fully ON (no outages in entire schedule) '
        'WHEN calculating countdown '
        'THEN returns null (no outages to count down to)', () {
      final today = DailySchedule(List.filled(24, LightStatus.on));
      final tomorrow = DailySchedule(List.filled(24, LightStatus.on));

      final now = DateTime(2026, 9, 30, 12, 0);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: tomorrow,
        now: now,
      );

      expect(result, isNull);
    });
  });

  group('CountdownService - Edge Cases & Validation (Tier C)', () {
    test('returns null when today schedule is null or empty', () {
      final now = DateTime(2026, 9, 30, 12, 0);

      expect(
          CountdownService.calculateCountdown(
            today: null,
            tomorrow: DailySchedule.empty(),
            now: now,
          ),
          isNull);

      expect(
          CountdownService.calculateCountdown(
            today: DailySchedule.empty(),
            tomorrow: DailySchedule.empty(),
            now: now,
          ),
          isNull);
    });

    test('returns null when current hour has unknown status', () {
      final hours = List.filled(24, LightStatus.on);
      hours[12] = LightStatus.unknown;
      final today = DailySchedule(hours);

      final now = DateTime(2026, 9, 30, 12, 10);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: DailySchedule.empty(),
        now: now,
      );

      expect(result, isNull);
    });

    test('handles 23:59 correctly when tomorrow starts with outage', () {
      final today = DailySchedule(List.filled(24, LightStatus.on));
      final tomorrowHours = List.filled(24, LightStatus.on);
      tomorrowHours[0] = LightStatus.off;
      final tomorrow = DailySchedule(tomorrowHours);

      final now = DateTime(2026, 9, 30, 23, 59);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: tomorrow,
        now: now,
      );

      expect(result, isNotNull);
      expect(result!.minutesRemaining, 1);
      expect(result.message, 'До відключення: 1хв');
    });

    test('handles 00:00 exact start of day', () {
      final hours = List.filled(24, LightStatus.on);
      hours[2] = LightStatus.off; // outage at 02:00
      final today = DailySchedule(hours);

      final now = DateTime(2026, 9, 30, 0, 0);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: DailySchedule.empty(),
        now: now,
      );

      expect(result, isNotNull);
      expect(result!.minutesRemaining, 120);
      expect(result.message, 'До відключення: 2г 0хв');
    });

    test('semiOn and semiOff half-hour slots are respected', () {
      final hours = List.filled(24, LightStatus.on);
      // semiOff: first 30 mins ON, second 30 mins OFF
      hours[14] = LightStatus.semiOff;
      final today = DailySchedule(hours);

      // Current time: 14:10 (slot index 28, which is first 30 mins -> ON)
      final now = DateTime(2026, 9, 30, 14, 10);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: DailySchedule.empty(),
        now: now,
      );

      expect(result, isNotNull);
      // Next change is at 14:30 (slot index 29 -> OFF)
      expect(result!.minutesRemaining, 20);
      expect(result.targetStatus, SlotStatus.off);
      expect(result.message, 'До відключення: 20хв');
    });

    test('does not look past an unknown data interruption later in the day',
        () {
      final hours = List.filled(24, LightStatus.on);
      hours[18] = LightStatus.unknown;
      hours[20] = LightStatus.off;
      final today = DailySchedule(hours);

      final now = DateTime(2026, 9, 30, 15, 0);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: DailySchedule.empty(),
        now: now,
      );

      expect(result, isNull,
          reason: 'Cannot predict beyond unknown slot at 18:00');
    });

    test('safely handles truncated today schedule without RangeError', () {
      // Malformed schedule with only 3 hours (6 slots)
      final truncatedHours = [
        LightStatus.on,
        LightStatus.on,
        LightStatus.off,
      ];
      final today = DailySchedule(truncatedHours);

      // Current time is 00:15 (slot 0)
      final now = DateTime(2026, 9, 30, 0, 15);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: DailySchedule.empty(),
        now: now,
      );

      // Next change is at slot 4 (02:00) => 105 minutes remaining
      expect(result, isNotNull);
      expect(result!.minutesRemaining, 105);
      expect(result.targetStatus, SlotStatus.off);
      expect(result.message, 'До відключення: 1г 45хв');

      // Now test truncated schedule with no change within its few slots
      final uniformTruncated = DailySchedule([LightStatus.on, LightStatus.on]);
      final noChangeResult = CountdownService.calculateCountdown(
        today: uniformTruncated,
        tomorrow: DailySchedule(List.filled(24, LightStatus.off)),
        now: now,
      );
      // Because today is truncated before reaching 24 hours, it should treat as interrupted and return null
      expect(noChangeResult, isNull);
    });

    test('safely handles truncated tomorrow schedule without RangeError', () {
      final today = DailySchedule(List.filled(24, LightStatus.on));
      // Tomorrow only has 2 hours (4 slots)
      final tomorrow = DailySchedule([LightStatus.on, LightStatus.off]);

      final now = DateTime(2026, 9, 30, 23, 0);

      final result = CountdownService.calculateCountdown(
        today: today,
        tomorrow: tomorrow,
        now: now,
      );

      // Change at tomorrow slot 2 (01:00) => 1 hour today + 1 hour tomorrow = 120 mins
      expect(result, isNotNull);
      expect(result!.minutesRemaining, 120);
      expect(result.targetStatus, SlotStatus.off);
      expect(result.message, 'До відключення: 2г 0хв');
    });
  });

  group(
      'CountdownInfo & DailySchedule - Value Semantics & Optimization (Tier C)',
      () {
    test(
        'DailySchedule.toSlots pre-allocated buffer maps all statuses accurately',
        () {
      final schedule = DailySchedule([
        LightStatus.on,
        LightStatus.off,
        LightStatus.semiOn,
        LightStatus.semiOff,
        LightStatus.maybe,
        LightStatus.unknown,
      ]);

      final slots = schedule.toSlots();
      expect(slots.length, 12);
      expect(slots, [
        SlotStatus.on,
        SlotStatus.on,
        SlotStatus.off,
        SlotStatus.off,
        SlotStatus.off,
        SlotStatus.on,
        SlotStatus.on,
        SlotStatus.off,
        SlotStatus.maybe,
        SlotStatus.maybe,
        SlotStatus.unknown,
        SlotStatus.unknown,
      ]);
    });

    test('CountdownInfo supports value equality, hashCode and toString', () {
      const info1 = CountdownInfo(
        minutesRemaining: 45,
        currentStatus: SlotStatus.on,
        targetStatus: SlotStatus.off,
        formattedRemaining: '45хв',
        message: 'До відключення: 45хв',
      );

      const info2 = CountdownInfo(
        minutesRemaining: 45,
        currentStatus: SlotStatus.on,
        targetStatus: SlotStatus.off,
        formattedRemaining: '45хв',
        message: 'До відключення: 45хв',
      );

      const infoDiff = CountdownInfo(
        minutesRemaining: 30,
        currentStatus: SlotStatus.on,
        targetStatus: SlotStatus.off,
        formattedRemaining: '30хв',
        message: 'До відключення: 30хв',
      );

      expect(info1, equals(info2));
      expect(info1.hashCode, equals(info2.hashCode));
      expect(info1, isNot(equals(infoDiff)));
      expect(info1.toString(), contains('minutesRemaining: 45'));
      expect(info1.toString(), contains('До відключення: 45хв'));
    });
  });

  group('CountdownService - Property-Based Testing (Tier B)', () {
    test(
        'for any time of day, if tomorrow is empty and remaining today is uniform, returns null',
        () {
      final today = DailySchedule(List.filled(24, LightStatus.on));
      final tomorrow = DailySchedule.empty();

      for (int h = 0; h < 24; h++) {
        for (int m = 0; m < 60; m += 15) {
          final now = DateTime(2026, 9, 30, h, m);
          final result = CountdownService.calculateCountdown(
            today: today,
            tomorrow: tomorrow,
            now: now,
          );
          expect(result, isNull,
              reason:
                  'Failed at time $h:$m - should return null when tomorrow has no data');
        }
      }
    });

    test(
        'for any valid countdown result, minutesRemaining is strictly positive',
        () {
      final hours = List.filled(24, LightStatus.on);
      hours[12] = LightStatus.off;
      final today = DailySchedule(hours);
      final tomorrow = DailySchedule.empty();

      for (int h = 0; h < 12; h++) {
        for (int m = 0; m < 60; m += 10) {
          final now = DateTime(2026, 9, 30, h, m);
          final result = CountdownService.calculateCountdown(
            today: today,
            tomorrow: tomorrow,
            now: now,
          );
          expect(result, isNotNull);
          expect(result!.minutesRemaining, greaterThan(0));
        }
      }
    });
  });
}

