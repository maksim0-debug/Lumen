import 'schedule_clock.dart';
import 'package:flutter/material.dart';
import '../models/hour_segment.dart';
import '../models/power_event.dart';
import '../models/schedule_status.dart';

/// Сервіс розрахунку пропорційних сегментів годин та реального часу відключень.
class HourSegmentService {
  static final Color defaultGreen = Colors.green.shade400;
  static final Color defaultRed = Colors.red.shade400;
  static final Color defaultGrey = Colors.grey.shade500;
  static final Color defaultNoData =
      Colors.grey.shade800.withValues(alpha: 0.3);

  /// Обчислює сегменти для однієї години (0..23).
  static List<HourSegment> computeHourSegments(
    List<PowerOutageInterval> intervals,
    DateTime date,
    int hour, {
    DailySchedule? forecast,
    DateTime? nowOverride,
    Color? greenColor,
    Color? redColor,
    Color? greyColor,
    Color? noDataColor,
  }) {
    final now = nowOverride ?? ScheduleClock.now();
    final green = greenColor ?? defaultGreen;
    final red = redColor ?? defaultRed;
    final grey = greyColor ?? defaultGrey;

    final isToday =
        date.year == now.year && date.month == now.month && date.day == now.day;
    final hourStart =
        ScheduleClock.calendar(date.year, date.month, date.day, hour);
    final hourEnd = hourStart.add(const Duration(hours: 1));

    // Повністю в майбутньому (сьогоднішні майбутні години або дні в майбутньому)
    if (hourStart.isAfter(now)) {
      if (forecast != null && !forecast.isEmpty) {
        final fStatus = forecast.hours[hour];
        switch (fStatus) {
          case LightStatus.on:
            return [
              HourSegment(0, 1, green.withValues(alpha: 0.3),
                  status: LightStatus.on, isFuture: true)
            ];
          case LightStatus.off:
            return [
              HourSegment(0, 1, red.withValues(alpha: 0.3),
                  status: LightStatus.off, isFuture: true)
            ];
          case LightStatus.semiOn:
            return [
              HourSegment(0, 0.5, red.withValues(alpha: 0.3),
                  status: LightStatus.off, isFuture: true),
              HourSegment(0.5, 1, green.withValues(alpha: 0.3),
                  status: LightStatus.on, isFuture: true),
            ];
          case LightStatus.semiOff:
            return [
              HourSegment(0, 0.5, green.withValues(alpha: 0.3),
                  status: LightStatus.on, isFuture: true),
              HourSegment(0.5, 1, red.withValues(alpha: 0.3),
                  status: LightStatus.off, isFuture: true),
            ];
          case LightStatus.maybe:
            return [
              HourSegment(0, 1, grey.withValues(alpha: 0.4),
                  status: LightStatus.maybe, isFuture: true)
            ];
          default:
            return [
              HourSegment(0, 1, green.withValues(alpha: 0.3),
                  status: LightStatus.on, isFuture: true)
            ];
        }
      }
      return [
        HourSegment(0, 1, green.withValues(alpha: 0.3),
            status: LightStatus.on, isFuture: true)
      ];
    }

    // Визначаємо крайню точку факту
    double factEndFraction = 1.0;
    if (isToday && now.hour == hour) {
      factEndFraction = now.minute / 60.0;
    }

    final List<HourOffRange> offRanges = [];
    for (final interval in intervals) {
      final intervalEnd = interval.end ?? now;
      if (interval.start.isAfter(hourEnd) || intervalEnd.isBefore(hourStart)) {
        continue;
      }

      final effectiveStart =
          interval.start.isAfter(hourStart) ? interval.start : hourStart;
      final effectiveEnd =
          intervalEnd.isBefore(hourEnd) ? intervalEnd : hourEnd;

      double startFrac =
          effectiveStart.difference(hourStart).inSeconds / 3600.0;
      double endFrac = effectiveEnd.difference(hourStart).inSeconds / 3600.0;
      startFrac = startFrac.clamp(0.0, 1.0);
      endFrac = endFrac.clamp(0.0, 1.0);

      if (startFrac >= factEndFraction) continue;
      if (endFrac > factEndFraction) endFrac = factEndFraction;

      if (endFrac > startFrac + 0.001) {
        offRanges.add(HourOffRange(startFrac, endFrac));
      }
    }

    final List<HourSegment> segments = [];
    double cursor = 0.0;

    for (final r in offRanges) {
      if (r.start > cursor + 0.005) {
        segments.add(HourSegment(cursor, r.start, green,
            status: LightStatus.on, isFuture: false));
      }
      segments.add(HourSegment(r.start, r.end, red,
          status: LightStatus.off, isFuture: false));
      cursor = r.end;
    }
    if (cursor < factEndFraction - 0.005) {
      segments.add(HourSegment(cursor, factEndFraction, green,
          status: LightStatus.on, isFuture: false));
    }

    // Прогноз для залишку поточної години
    if (isToday && now.hour == hour && factEndFraction < 0.99) {
      if (forecast != null && !forecast.isEmpty) {
        final fStatus = forecast.hours[hour];

        void addForecast(double start, double end, Color c, LightStatus st) {
          final s = start < factEndFraction ? factEndFraction : start;
          final e = end;
          if (e > s) {
            segments.add(HourSegment(s, e, c.withValues(alpha: 0.3),
                status: st, isFuture: true));
          }
        }

        switch (fStatus) {
          case LightStatus.on:
            addForecast(0.0, 1.0, green, LightStatus.on);
            break;
          case LightStatus.off:
            addForecast(0.0, 1.0, red, LightStatus.off);
            break;
          case LightStatus.semiOn:
            addForecast(0.0, 0.5, red, LightStatus.off);
            addForecast(0.5, 1.0, green, LightStatus.on);
            break;
          case LightStatus.semiOff:
            addForecast(0.0, 0.5, green, LightStatus.on);
            addForecast(0.5, 1.0, red, LightStatus.off);
            break;
          case LightStatus.maybe:
            addForecast(0.0, 1.0, grey, LightStatus.maybe);
            break;
          default:
            addForecast(0.0, 1.0, green, LightStatus.on);
            break;
        }
      } else {
        segments.add(HourSegment(
            factEndFraction, 1.0, green.withValues(alpha: 0.3),
            status: LightStatus.on, isFuture: true));
      }
    }

    if (segments.isEmpty) {
      segments.add(
          HourSegment(0, 1, green, status: LightStatus.on, isFuture: false));
    }

    return segments;
  }

  /// Обчислює сегменти для всіх 24 годин доби.
  static List<List<HourSegment>> computeAllHourSegments(
    List<PowerOutageInterval> intervals,
    DateTime date, {
    DailySchedule? forecast,
    DateTime? nowOverride,
    Color? greenColor,
    Color? redColor,
    Color? greyColor,
    Color? noDataColor,
  }) {
    final List<List<HourSegment>> allSegments = [];
    for (int h = 0; h < 24; h++) {
      allSegments.add(computeHourSegments(
        intervals,
        date,
        h,
        forecast: forecast,
        nowOverride: nowOverride,
        greenColor: greenColor,
        redColor: redColor,
        greyColor: greyColor,
        noDataColor: noDataColor,
      ));
    }
    return allSegments;
  }

  /// Точний підрахунок хвилин без світла з реальних інтервалів.
  static int computeRealOutageMinutes(
    List<PowerOutageInterval> intervals,
    DateTime date, {
    DateTime? nowOverride,
  }) {
    final dayStart = ScheduleClock.calendar(date.year, date.month, date.day);
    final dayEnd = ScheduleClock.calendar(date.year, date.month, date.day + 1);
    final now = nowOverride ?? ScheduleClock.now();
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
}
