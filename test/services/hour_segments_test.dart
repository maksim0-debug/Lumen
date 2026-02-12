import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:vikl/models/power_event.dart';

// ================================================================
// Standalone test helpers that replicate the core logic from main.dart
// These don't depend on Flutter widgets, only on the data model.
// ================================================================

/// Replicates HourSegment from main.dart for testing.
class HourSegment {
  final double startFraction;
  final double endFraction;
  final Color color;

  HourSegment(this.startFraction, this.endFraction, this.color);
  double get width => endFraction - startFraction;
}

class _OffRange {
  final double start;
  final double end;
  _OffRange(this.start, this.end);
}

/// Computes proportional segments for a single hour cell.
/// This is the core logic extracted from _computeAllHourSegments.
List<HourSegment> computeHourSegments(
    List<PowerOutageInterval> intervals, DateTime date, int hour,
    {DateTime? nowOverride}) {
  final now = nowOverride ?? DateTime.now();
  final hourStart = DateTime(date.year, date.month, date.day, hour);
  final hourEnd = hourStart.add(const Duration(hours: 1));

  final redColor = Colors.red.shade400;
  final greenColor = Colors.green.shade400;

  final isToday =
      date.year == now.year && date.month == now.month && date.day == now.day;

  double factEndFraction = 1.0;
  if (isToday && now.hour == hour) {
    factEndFraction = now.minute / 60.0;
  }

  // If hour is entirely in the future for today, skip (handled separately in UI)
  if (isToday && hourStart.isAfter(now)) {
    return [HourSegment(0, 1, Colors.grey.shade800)]; // No data
  }

  List<HourSegment> segments = [];
  double cursor = 0.0;

  List<_OffRange> offRanges = [];
  for (final interval in intervals) {
    final intervalEnd = interval.end ?? now;
    if (interval.start.isAfter(hourEnd) || intervalEnd.isBefore(hourStart)) {
      continue;
    }

    final effectiveStart =
        interval.start.isAfter(hourStart) ? interval.start : hourStart;
    final effectiveEnd = intervalEnd.isBefore(hourEnd) ? intervalEnd : hourEnd;

    double startFrac = effectiveStart.difference(hourStart).inSeconds / 3600.0;
    double endFrac = effectiveEnd.difference(hourStart).inSeconds / 3600.0;
    startFrac = startFrac.clamp(0.0, 1.0);
    endFrac = endFrac.clamp(0.0, 1.0);

    if (startFrac >= factEndFraction) continue;
    if (endFrac > factEndFraction) endFrac = factEndFraction;

    if (endFrac > startFrac + 0.01) {
      offRanges.add(_OffRange(startFrac, endFrac));
    }
  }

  for (final r in offRanges) {
    if (r.start > cursor + 0.005) {
      segments.add(HourSegment(cursor, r.start, greenColor));
    }
    segments.add(HourSegment(r.start, r.end, redColor));
    cursor = r.end;
  }
  if (cursor < factEndFraction - 0.005) {
    segments.add(HourSegment(cursor, factEndFraction, greenColor));
  }

  if (segments.isEmpty) {
    segments.add(HourSegment(0, 1, greenColor));
  }

  return segments;
}

/// Computes total outage minutes with second-level precision.
int computeRealOutageMinutes(List<PowerOutageInterval> intervals, DateTime date,
    {DateTime? nowOverride}) {
  final dayStart = DateTime(date.year, date.month, date.day);
  final dayEnd = dayStart.add(const Duration(days: 1));
  final now = nowOverride ?? DateTime.now();
  int totalSeconds = 0;

  for (final interval in intervals) {
    final effectiveStart =
        interval.start.isBefore(dayStart) ? dayStart : interval.start;
    DateTime effectiveEnd;
    if (interval.end == null) {
      effectiveEnd = now.isBefore(dayEnd) ? now : dayEnd;
    } else {
      effectiveEnd = interval.end!.isAfter(dayEnd) ? dayEnd : interval.end!;
    }
    if (effectiveEnd.isAfter(effectiveStart)) {
      totalSeconds += effectiveEnd.difference(effectiveStart).inSeconds;
    }
  }
  return (totalSeconds / 60).round();
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
