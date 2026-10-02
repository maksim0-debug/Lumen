import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/power_event.dart';

import 'package:lumen/models/hour_segment.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/hour_segment_service.dart';

// Test wrapper delegating to production HourSegmentService
List<HourSegment> computeHourSegments(
    List<PowerOutageInterval> intervals, DateTime date, int hour,
    {DailySchedule? forecast, DateTime? nowOverride}) {
  return HourSegmentService.computeHourSegments(
    intervals,
    date,
    hour,
    forecast: forecast,
    nowOverride: nowOverride,
  );
}

int computeRealOutageMinutes(List<PowerOutageInterval> intervals, DateTime date,
    {DateTime? nowOverride}) {
  return HourSegmentService.computeRealOutageMinutes(
    intervals,
    date,
    nowOverride: nowOverride,
  );
}

void main() {
  final date = DateTime(2026, 2, 11);
  final redColor = Colors.red.shade400;
  final greenColor = Colors.green.shade400;

  group('computeHourSegments - Past Hours', () {
    test('All-green hour (no outages)', () {
      final segments = computeHourSegments([], date, 10,
          nowOverride: DateTime(2026, 2, 11, 23, 0));

      expect(segments.length, 1);
      expect(segments.first.startFraction, 0.0);
      expect(segments.first.endFraction, 1.0);
      expect(segments.first.color, greenColor);
    });

    test('All-red hour (60 min outage)', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 11, 10, 0),
          end: DateTime(2026, 2, 11, 11, 0),
        ),
      ];

      final segments = computeHourSegments(intervals, date, 10,
          nowOverride: DateTime(2026, 2, 11, 23, 0));

      expect(segments.length, 1);
      expect(segments.first.startFraction, closeTo(0.0, 0.01));
      expect(segments.first.endFraction, closeTo(1.0, 0.01));
      expect(segments.first.color, redColor);
    });

    test('Mixed: outage 14:15 -> 14:50', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 11, 14, 15),
          end: DateTime(2026, 2, 11, 14, 50),
        ),
      ];

      final segments = computeHourSegments(intervals, date, 14,
          nowOverride: DateTime(2026, 2, 11, 23, 0));

      // Expect: green(0–0.25), red(0.25–0.833), green(0.833–1.0)
      expect(segments.length, 3);

      expect(segments[0].color, greenColor);
      expect(segments[0].startFraction, closeTo(0.0, 0.01));
      expect(segments[0].endFraction, closeTo(0.25, 0.02));

      expect(segments[1].color, redColor);
      expect(segments[1].startFraction, closeTo(0.25, 0.02));
      expect(segments[1].endFraction, closeTo(0.833, 0.02));

      expect(segments[2].color, greenColor);
      expect(segments[2].startFraction, closeTo(0.833, 0.02));
      expect(segments[2].endFraction, closeTo(1.0, 0.01));
    });

    test('Short outage in the middle: 10:20–10:30', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 11, 10, 20),
          end: DateTime(2026, 2, 11, 10, 30),
        ),
      ];

      final segments = computeHourSegments(intervals, date, 10,
          nowOverride: DateTime(2026, 2, 11, 23, 0));

      // green(0–0.333), red(0.333–0.5), green(0.5–1.0)
      expect(segments.length, 3);
      expect(segments[0].color, greenColor);
      expect(segments[1].color, redColor);
      expect(segments[2].color, greenColor);
    });

    test('Multiple outages in one hour', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 11, 10, 5),
          end: DateTime(2026, 2, 11, 10, 15),
        ),
        PowerOutageInterval(
          start: DateTime(2026, 2, 11, 10, 40),
          end: DateTime(2026, 2, 11, 10, 55),
        ),
      ];

      final segments = computeHourSegments(intervals, date, 10,
          nowOverride: DateTime(2026, 2, 11, 23, 0));

      // green, red, green, red, green = 5 segments
      expect(segments.length, 5);
      expect(segments[0].color, greenColor); // 0:00-0:05
      expect(segments[1].color, redColor); // 0:05-0:15
      expect(segments[2].color, greenColor); // 0:15-0:40
      expect(segments[3].color, redColor); // 0:40-0:55
      expect(segments[4].color, greenColor); // 0:55-1:00
    });

    test('Outage spanning into this hour from previous', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 11, 9, 30),
          end: DateTime(2026, 2, 11, 10, 15),
        ),
      ];

      final segments = computeHourSegments(intervals, date, 10,
          nowOverride: DateTime(2026, 2, 11, 23, 0));

      // red(0–0.25), green(0.25–1.0)
      expect(segments.length, 2);
      expect(segments[0].color, redColor);
      expect(segments[0].startFraction, closeTo(0.0, 0.01));
      expect(segments[0].endFraction, closeTo(0.25, 0.02));
      expect(segments[1].color, greenColor);
    });
  });

  group('computeHourSegments - Future Hours & Tomorrow', () {
    test('Future hour today uses forecast', () {
      final hours = List.filled(24, LightStatus.on);
      hours[15] = LightStatus.off;
      final forecast = DailySchedule(hours);

      final segments = computeHourSegments([], date, 15,
          forecast: forecast, nowOverride: DateTime(2026, 2, 11, 10, 0));

      expect(segments.length, 1);
      expect(segments.first.isFuture, isTrue);
      expect(segments.first.status, LightStatus.off);
      expect(segments.first.color, redColor.withValues(alpha: 0.3));
    });

    test('Tomorrow hour with forecast uses forecast', () {
      final tomorrow = date.add(const Duration(days: 1));
      final hours = List.filled(24, LightStatus.on);
      hours[8] = LightStatus.semiOn; // red 0-0.5, green 0.5-1.0
      final forecast = DailySchedule(hours);

      final segments = computeHourSegments([], tomorrow, 8,
          forecast: forecast, nowOverride: DateTime(2026, 2, 11, 10, 0));

      expect(segments.length, 2);
      expect(segments[0].isFuture, isTrue);
      expect(segments[0].status, LightStatus.off);
      expect(segments[0].endFraction, 0.5);
      expect(segments[1].isFuture, isTrue);
      expect(segments[1].status, LightStatus.on);
      expect(segments[1].startFraction, 0.5);
    });

    test('Tomorrow hour without forecast defaults to ON (no outages)', () {
      final tomorrow = date.add(const Duration(days: 1));
      final segments = computeHourSegments([], tomorrow, 8,
          forecast: null, nowOverride: DateTime(2026, 2, 11, 10, 0));

      expect(segments.length, 1);
      expect(segments.first.isFuture, isTrue);
      expect(segments.first.status, LightStatus.on);
    });
  });

  group('computeRealOutageMinutes', () {
    test('No outages = 0 minutes', () {
      expect(computeRealOutageMinutes([], date), 0);
    });

    test('Single 2-hour outage', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 11, 3, 0),
          end: DateTime(2026, 2, 11, 5, 0),
        ),
      ];
      expect(computeRealOutageMinutes(intervals, date), 120);
    });

    test('Outage spanning midnight (clamped to day)', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 10, 22, 0),
          end: DateTime(2026, 2, 11, 2, 0),
        ),
      ];
      // Only 00:00–02:00 counted = 120 min
      expect(computeRealOutageMinutes(intervals, date), 120);
    });

    test('Multiple outages sum correctly (257 min)', () {
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 11, 3, 14),
          end: DateTime(2026, 2, 11, 7, 31), // 4h 17m = 257 min
        ),
      ];
      expect(computeRealOutageMinutes(intervals, date), 257);
    });

    test('Ongoing outage uses now as end', () {
      final fakeNow = DateTime(2026, 2, 11, 15, 30);
      final intervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 11, 14, 0),
          end: null, // ongoing
        ),
      ];
      expect(
          computeRealOutageMinutes(intervals, date, nowOverride: fakeNow), 90);
    });
  });
}

