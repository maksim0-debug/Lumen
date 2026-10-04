import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/models/interval_info.dart';
import 'package:lumen/models/power_event.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/schedule_calculation_service.dart';

void main() {
  group('ScheduleCalculationService Tests', () {
    final testDate = DateTime(2026, 10, 1);

    test('calculateOutageMinutes calculates total outage minutes correctly',
        () {
      final hours = List.filled(24, LightStatus.on);
      hours[0] = LightStatus.off; // 60 mins
      hours[1] = LightStatus.semiOff; // 30 mins
      hours[2] = LightStatus.semiOn; // 30 mins
      final schedule = DailySchedule(hours);

      expect(ScheduleCalculationService.calculateOutageMinutes(schedule),
          equals(120));
    });

    test('generateIntervals returns empty list for null or empty schedule', () {
      expect(ScheduleCalculationService.generateIntervals(null), isEmpty);
      expect(
          ScheduleCalculationService.generateIntervals(DailySchedule.empty()),
          isEmpty);
    });

    test('generateIntervals aggregates contiguous slot statuses into intervals',
        () {
      final hours = List.filled(24, LightStatus.on);
      hours[10] = LightStatus.off;
      hours[11] = LightStatus.off;
      final schedule = DailySchedule(hours);

      final intervals = ScheduleCalculationService.generateIntervals(schedule);
      expect(intervals.length, equals(3));

      // 00:00 - 10:00 ON (10г)
      expect(intervals[0].timeRange, equals('00:00 - 10:00'));
      expect(intervals[0].statusText, equals('ON'));
      expect(intervals[0].duration, equals('10г'));
      expect(intervals[0].color, equals(Colors.green));

      // 10:00 - 12:00 OFF (2г)
      expect(intervals[1].timeRange, equals('10:00 - 12:00'));
      expect(intervals[1].statusText, equals('OFF'));
      expect(intervals[1].duration, equals('2г'));
      expect(intervals[1].color, equals(Colors.red));

      // 12:00 - 24:00 ON (12г)
      expect(intervals[2].timeRange, equals('12:00 - 24:00'));
      expect(intervals[2].statusText, equals('ON'));
      expect(intervals[2].duration, equals('12г'));
      expect(intervals[2].color, equals(Colors.green));
    });

    test('generateRealIntervals handles empty intervals correctly', () {
      final resOnline = ScheduleCalculationService.generateRealIntervals(
        [],
        testDate,
        isOffline: false,
        nowOverride: DateTime(2026, 10, 1, 15, 0),
      );
      expect(resOnline.length, equals(1));
      expect(resOnline.first.timeRange, equals('00:00 - 24:00'));
      expect(resOnline.first.statusText, equals('ON'));

      final resOffline = ScheduleCalculationService.generateRealIntervals(
        [],
        testDate,
        isOffline: true,
        nowOverride: DateTime(2026, 10, 1, 15, 0),
      );
      expect(resOffline.length, equals(1));
      expect(resOffline.first.timeRange, equals('00:00 - 24:00'));
      expect(resOffline.first.statusText, equals('OFF ⏳'));
    });

    test('generateRealIntervals splits green and red intervals properly', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 10, 1, 9, 0),
          end: DateTime(2026, 10, 1, 11, 30),
          startEventId: 1,
          endEventId: 2,
        ),
      ];

      final result = ScheduleCalculationService.generateRealIntervals(
        intervals,
        testDate,
        nowOverride: DateTime(2026, 10, 1, 15, 0),
      );

      expect(result.length, equals(3));
      // First segment: 00:00 - 09:00 ON
      expect(result[0].timeRange, equals('00:00 - 09:00'));
      expect(result[0].statusText, equals('ON'));
      expect(result[0].duration, equals('9г'));

      // Second segment: 09:00 - 11:30 OFF
      expect(result[1].timeRange, equals('09:00 - 11:30'));
      expect(result[1].statusText, equals('OFF'));
      expect(result[1].duration, equals('2г 30хв'));
      expect(result[1].startEventId, equals(1));
      expect(result[1].endEventId, equals(2));

      // Third segment: 11:30 - 24:00 ON
      expect(result[2].timeRange, equals('11:30 - 24:00'));
      expect(result[2].statusText, equals('ON'));
      expect(result[2].duration, equals('12г 30хв'));
    });

    test('buildRealScheduleFromIntervals updates hours based on actual outages',
        () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 10, 1, 2, 0),
          end: DateTime(2026, 10, 1, 3, 0),
        ),
      ];

      final schedule =
          ScheduleCalculationService.buildRealScheduleFromIntervals(
        intervals,
        testDate,
        nowOverride: DateTime(2026, 10, 1, 5, 0),
      );

      expect(schedule.hours[0], equals(LightStatus.on));
      expect(schedule.hours[1], equals(LightStatus.on));
      expect(schedule.hours[2], equals(LightStatus.off));
      expect(schedule.hours[3], equals(LightStatus.on));
    });

    test('getOutageInfoText formats predicted mode text and updates correctly',
        () {
      final hours = List.filled(24, LightStatus.on);
      hours[0] = LightStatus.off; // 60 mins -> 60 / 1440 * 100 = 4%
      final schedule = DailySchedule(hours);

      final text = ScheduleCalculationService.getOutageInfoText(
        schedule,
        false,
        powerMonitorEnabled: false,
        dataSourceMode: DataSourceMode.predicted,
      );

      expect(text, equals('Час без світла: 1:00 (4%)'));

      // With updates diff
      final textUpdated = ScheduleCalculationService.getOutageInfoText(
        schedule,
        false,
        powerMonitorEnabled: false,
        dataSourceMode: DataSourceMode.predicted,
        wasUpdated: true,
        currentGroup: 'group1',
        lastUpdateOldStats: {
          'group1_today': 120
        }, // diff = 60 - 120 = -60 mins (-4%)
      );

      expect(textUpdated, contains('Графік оновився:'));
      expect(textUpdated, contains('(-4%)'));
    });

    test('getOutageInfoText formats real mode text correctly', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 10, 1, 1, 0),
          end: DateTime(2026, 10, 1, 2, 30),
        ),
      ];

      final text = ScheduleCalculationService.getOutageInfoText(
        null,
        false,
        powerMonitorEnabled: true,
        dataSourceMode: DataSourceMode.real,
        realOutageIntervals: intervals,
        displayDate: testDate,
      );

      // 90 mins -> 1г 30хв (6%)
      expect(text, equals('Час без світла: 1г 30хв (6%)'));
    });

    test('formatGroupName correctly formats group identifiers', () {
      expect(ScheduleCalculationService.formatGroupName('GPV2.1'),
          equals('Група 2.1'));
      expect(ScheduleCalculationService.formatGroupName('GPV1.2'),
          equals('Група 1.2'));
      expect(ScheduleCalculationService.formatGroupName('2.1'),
          equals('Група 2.1'));
      expect(ScheduleCalculationService.formatGroupName('Група 3.1'),
          equals('Група 3.1'));
      expect(ScheduleCalculationService.formatGroupName(''), equals(''));
    });

    test('formatIntervalText formats interval into aligned string', () {
      final off = IntervalInfo('00:00 - 03:30', 'OFF', '3г 30хв', Colors.red);
      expect(ScheduleCalculationService.formatIntervalText(off),
          equals('00:00 - 03:30  OFF  (3г 30хв)'));

      final on = IntervalInfo('03:30 - 10:30', 'ON', '7г', Colors.green);
      expect(ScheduleCalculationService.formatIntervalText(on),
          equals('03:30 - 10:30  ON  (7г)'));

      final ongoing = IntervalInfo('12:00 - зараз', 'OFF ⏳', '1г', Colors.red);
      expect(ScheduleCalculationService.formatIntervalText(ongoing),
          equals('12:00 - зараз  OFF ⏳  (1г)'));
    });

    test('formatScheduleClipboardSummary builds complete clipboard text', () {
      final intervals = [
        IntervalInfo('00:00 - 03:30', 'OFF', '3г 30хв', Colors.red),
        IntervalInfo('03:30 - 10:30', 'ON', '7г', Colors.green),
        IntervalInfo('10:30 - 17:30', 'OFF', '7г', Colors.red),
      ];

      final text = ScheduleCalculationService.formatScheduleClipboardSummary(
        group: 'GPV2.1',
        date: DateTime(2026, 2, 19),
        outageInfoText: 'Час без світла: 13:30 (56%)',
        intervals: intervals,
      );

      const expected = 'Група 2.1 — 19.02.2026\n'
          'Час без світла: 13:30 (56%)\n\n'
          'Розклад інтервалами:\n'
          '00:00 - 03:30  OFF  (3г 30хв)\n'
          '03:30 - 10:30  ON  (7г)\n'
          '10:30 - 17:30  OFF  (7г)';

      expect(text, equals(expected));

      // With predicted mode and version
      final textWithVersion =
          ScheduleCalculationService.formatScheduleClipboardSummary(
        group: 'GPV2.1',
        date: DateTime(2026, 2, 19),
        dataSourceMode: DataSourceMode.predicted,
        scheduleVersion: '04.09 14:09',
        outageInfoText: 'Час без світла: 13:30 (56%)',
        intervals: intervals,
      );

      const expectedWithVersion = 'Група 2.1 — 19.02.2026\n'
          'Графік (Версія 04.09 14:09)\n'
          'Час без світла: 13:30 (56%)\n\n'
          'Розклад інтервалами:\n'
          '00:00 - 03:30  OFF  (3г 30хв)\n'
          '03:30 - 10:30  ON  (7г)\n'
          '10:30 - 17:30  OFF  (7г)';

      expect(textWithVersion, equals(expectedWithVersion));

      // With predicted mode without version
      final textPredictedNoVersion =
          ScheduleCalculationService.formatScheduleClipboardSummary(
        group: 'GPV2.1',
        date: DateTime(2026, 2, 19),
        dataSourceMode: DataSourceMode.predicted,
        outageInfoText: 'Час без світла: 13:30 (56%)',
        intervals: intervals,
      );

      const expectedPredictedNoVersion = 'Група 2.1 — 19.02.2026\n'
          'Графік\n'
          'Час без світла: 13:30 (56%)\n\n'
          'Розклад інтервалами:\n'
          '00:00 - 03:30  OFF  (3г 30хв)\n'
          '03:30 - 10:30  ON  (7г)\n'
          '10:30 - 17:30  OFF  (7г)';

      expect(textPredictedNoVersion, equals(expectedPredictedNoVersion));

      // With real mode
      final textReal =
          ScheduleCalculationService.formatScheduleClipboardSummary(
        group: 'GPV2.1',
        date: DateTime(2026, 2, 19),
        dataSourceMode: DataSourceMode.real,
        outageInfoText: 'Час без світла: 1г 30хв (6%)',
        intervals: [
          IntervalInfo('00:00 - 01:00', 'ON', '1г', Colors.green),
          IntervalInfo('01:00 - 02:30', 'OFF', '1г 30хв', Colors.red),
          IntervalInfo('02:30 - 24:00', 'ON', '21г 30хв', Colors.green),
        ],
      );

      const expectedReal = 'Група 2.1 — 19.02.2026\n'
          'Реальні відключення\n'
          'Час без світла: 1г 30хв (6%)\n\n'
          'Розклад інтервалами:\n'
          '00:00 - 01:00  ON  (1г)\n'
          '01:00 - 02:30  OFF  (1г 30хв)\n'
          '02:30 - 24:00  ON  (21г 30хв)';

      expect(textReal, equals(expectedReal));
    });

    test(
        'formatScheduleClipboardSummary handles missing optional fields gracefully',
        () {
      // No intervals
      final textNoIntervals =
          ScheduleCalculationService.formatScheduleClipboardSummary(
        group: 'GPV2.1',
        date: DateTime(2026, 2, 19),
        outageInfoText: 'Час без світла: 0:00 (0%)',
        intervals: const [],
      );
      expect(textNoIntervals,
          equals('Група 2.1 — 19.02.2026\nЧас без світла: 0:00 (0%)'));

      // No group and no date
      final intervals = [
        IntervalInfo('00:00 - 03:30', 'OFF', '3г 30хв', Colors.red),
      ];
      final textNoHeader =
          ScheduleCalculationService.formatScheduleClipboardSummary(
        outageInfoText: 'Час без світла: 3:30 (15%)',
        intervals: intervals,
      );
      expect(
          textNoHeader,
          equals('Час без світла: 3:30 (15%)\n\n'
              'Розклад інтервалами:\n'
              '00:00 - 03:30  OFF  (3г 30хв)'));

      // Empty all
      final empty = ScheduleCalculationService.formatScheduleClipboardSummary(
        outageInfoText: '',
        intervals: const [],
      );
      expect(empty, equals(''));

      // Group and date provided, but no outage text and no intervals (empty schedule)
      final emptySchedule =
          ScheduleCalculationService.formatScheduleClipboardSummary(
        group: 'GPV2.1',
        date: DateTime(2026, 10, 3),
        outageInfoText: '',
        intervals: const [],
      );
      expect(emptySchedule, equals(''));

      // Invalid scheduleVersion ("Невідомо" or "Немає даних") falls back to "Графік"
      final textUnknownVersion =
          ScheduleCalculationService.formatScheduleClipboardSummary(
        group: 'GPV2.1',
        date: DateTime(2026, 2, 19),
        dataSourceMode: DataSourceMode.predicted,
        scheduleVersion: 'Невідомо',
        outageInfoText: 'Час без світла: 0:00 (0%)',
        intervals: const [],
      );
      expect(
          textUnknownVersion,
          equals('Група 2.1 — 19.02.2026\n'
              'Графік\n'
              'Час без світла: 0:00 (0%)'));
    });

    group('generateRealIntervals Tests', () {
      test('returns 24h ON when intervals are empty and not offline', () {
        final date = DateTime(2026, 2, 17);
        final intervals =
            ScheduleCalculationService.generateRealIntervals([], date);
        expect(intervals.length, equals(1));
        expect(intervals.first.timeRange, equals('00:00 - 24:00'));
        expect(intervals.first.statusText, equals('ON'));
        expect(intervals.first.color, equals(Colors.green));
      });

      test('returns 24h OFF when intervals are empty on today and offline', () {
        final now = DateTime(2026, 10, 3, 12, 0);
        final date = DateTime(2026, 10, 3);
        final intervals = ScheduleCalculationService.generateRealIntervals(
          [],
          date,
          isOffline: true,
          nowOverride: now,
        );
        expect(intervals.length, equals(1));
        expect(intervals.first.timeRange, equals('00:00 - 24:00'));
        expect(intervals.first.statusText, equals('OFF ⏳'));
        expect(intervals.first.color, equals(Colors.red));
      });

      test(
          'past ongoing interval (end == null) caps at 24:00 even if day matches now.day',
          () {
        // Today is Oct 3, test date is Sep 3 (same day number, but past month)
        final now = DateTime(2026, 10, 3, 14, 0);
        final pastDate = DateTime(2026, 9, 3);
        final outage = PowerOutageInterval(
          start: DateTime(2026, 9, 3, 20, 0),
          end: null, // ongoing into next day
        );

        final intervals = ScheduleCalculationService.generateRealIntervals(
          [outage],
          pastDate,
          nowOverride: now,
        );

        // Expect: 00:00 - 20:00 ON, 20:00 - 24:00 OFF
        expect(intervals.length, equals(2));
        expect(intervals[0].timeRange, equals('00:00 - 20:00'));
        expect(intervals[0].statusText, equals('ON'));
        expect(intervals[1].timeRange, equals('20:00 - 24:00'));
        expect(intervals[1].statusText, equals('OFF'));
      });

      test('today ongoing interval (end == null) labels as зараз', () {
        final now = DateTime(2026, 10, 3, 14, 0);
        final today = DateTime(2026, 10, 3);
        final outage = PowerOutageInterval(
          start: DateTime(2026, 10, 3, 10, 0),
          end: null,
        );

        final intervals = ScheduleCalculationService.generateRealIntervals(
          [outage],
          today,
          nowOverride: now,
        );

        expect(intervals.length, equals(2));
        expect(intervals[0].timeRange, equals('00:00 - 10:00'));
        expect(intervals[0].statusText, equals('ON'));
        expect(intervals[1].timeRange, equals('10:00 - зараз'));
        expect(intervals[1].statusText, equals('OFF ⏳'));
      });

      test(
          'future day with empty intervals and baseSchedule generates intervals from baseSchedule',
          () {
        final now = DateTime(2026, 10, 3, 12, 0);
        final tomorrow = DateTime(2026, 10, 4);
        final hours = List.filled(24, LightStatus.on);
        hours[12] = LightStatus.off;
        hours[13] = LightStatus.off;
        final base = DailySchedule(hours);

        final intervals = ScheduleCalculationService.generateRealIntervals(
          [],
          tomorrow,
          nowOverride: now,
          baseSchedule: base,
        );

        expect(intervals.length, equals(3));
        expect(intervals[0].timeRange, equals('00:00 - 12:00'));
        expect(intervals[0].statusText, equals('ON'));
        expect(intervals[1].timeRange, equals('12:00 - 14:00'));
        expect(intervals[1].statusText, equals('OFF'));
        expect(intervals[2].timeRange, equals('14:00 - 24:00'));
        expect(intervals[2].statusText, equals('ON'));
      });

      test(
          'future day with empty intervals and NO baseSchedule returns empty list',
          () {
        final now = DateTime(2026, 10, 3, 12, 0);
        final tomorrow = DateTime(2026, 10, 4);

        final intervals = ScheduleCalculationService.generateRealIntervals(
          [],
          tomorrow,
          nowOverride: now,
        );

        expect(intervals, isEmpty);
      });

      test(
          'future day with non-empty carried-over intervals and baseSchedule STILL generates intervals from baseSchedule',
          () {
        final now = DateTime(2026, 10, 3, 23, 0);
        final tomorrow = DateTime(2026, 10, 4);
        final phantomOutage = PowerOutageInterval(
          start: DateTime(2026, 10, 4, 0, 0),
          end: null,
        );
        final hours = List.filled(24, LightStatus.on);
        hours[8] = LightStatus.off;
        hours[9] = LightStatus.off;
        final base = DailySchedule(hours);

        final intervals = ScheduleCalculationService.generateRealIntervals(
          [phantomOutage],
          tomorrow,
          nowOverride: now,
          baseSchedule: base,
        );

        expect(intervals.length, equals(3));
        expect(intervals[0].timeRange, equals('00:00 - 08:00'));
        expect(intervals[0].statusText, equals('ON'));
        expect(intervals[1].timeRange, equals('08:00 - 10:00'));
        expect(intervals[1].statusText, equals('OFF'));
        expect(intervals[2].timeRange, equals('10:00 - 24:00'));
        expect(intervals[2].statusText, equals('ON'));
      });

      test(
          'buildRealScheduleFromIntervals on future day without baseSchedule returns unknown',
          () {
        final now = DateTime(2026, 10, 3, 12, 0);
        final tomorrow = DateTime(2026, 10, 4);

        final schedule =
            ScheduleCalculationService.buildRealScheduleFromIntervals(
          [],
          tomorrow,
          nowOverride: now,
        );

        expect(schedule.hours.every((h) => h == LightStatus.unknown), isTrue);
      });

      test(
          'buildRealScheduleFromIntervals on future day with baseSchedule retains base hours',
          () {
        final now = DateTime(2026, 10, 3, 12, 0);
        final tomorrow = DateTime(2026, 10, 4);
        final baseHours = List.filled(24, LightStatus.on);
        baseHours[10] = LightStatus.off;
        final base = DailySchedule(baseHours);

        final schedule =
            ScheduleCalculationService.buildRealScheduleFromIntervals(
          [],
          tomorrow,
          baseSchedule: base,
          nowOverride: now,
        );

        expect(schedule.hours[10], equals(LightStatus.off));
        expect(schedule.hours[0], equals(LightStatus.on));
      });
    });
  });
}
