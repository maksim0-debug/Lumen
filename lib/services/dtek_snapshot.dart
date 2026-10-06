import 'dart:convert';
import 'schedule_clock.dart';
import 'package:timezone/timezone.dart' as tz;
import '../models/schedule_status.dart';
import '../utils/app_formatters.dart';

/// Validates a complete snapshot before any cache or history is changed.
class DtekSnapshot {
  static tz.Location get _kyiv => ScheduleClock.location;

  final Map<String, dynamic> fact;
  final Map<String, FullSchedule> schedules;
  final String todayDate;
  final String tomorrowDate;
  final String update;
  DtekSnapshot._(this.fact, this.schedules, this.todayDate, this.tomorrowDate,
      this.update);

  static String dateKey(DateTime value) => AppFormatters.formatDateKey(value);

  static String notificationDate(String dayType, {DateTime? now}) {
    final current = tz.TZDateTime.from(now ?? DateTime.now(), _kyiv);
    return dateKey(dayType == 'tomorrow'
        ? tz.TZDateTime(_kyiv, current.year, current.month, current.day + 1)
        : current);
  }

  factory DtekSnapshot.parse(String raw, List<String> groups, {DateTime? now}) {
    dynamic decoded = jsonDecode(raw);
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Expected schedule object');
    }
    final fact = decoded;
    final current = tz.TZDateTime.from(now ?? DateTime.now(), _kyiv);
    final timestamp = int.tryParse('${fact['today']}');
    if (timestamp == null || timestamp <= 0 || timestamp > 8640000000000) {
      throw const FormatException('Invalid today timestamp');
    }
    final today =
        tz.TZDateTime.fromMillisecondsSinceEpoch(_kyiv, timestamp * 1000);
    if (dateKey(today) != dateKey(current) ||
        today.hour != 0 ||
        today.minute != 0 ||
        today.second != 0) {
      throw const FormatException('Snapshot is not for current Kyiv midnight');
    }
    final tomorrow =
        tz.TZDateTime(_kyiv, today.year, today.month, today.day + 1);
    final update = fact['update'];
    if (update is! String) throw const FormatException('Missing update time');
    final version = ScheduleClock.parseVersion(update);
    if (version >
        current.millisecondsSinceEpoch +
            const Duration(hours: 4).inMilliseconds) {
      throw const FormatException('Future update time too far in advance');
    }
    final data = fact['data'];
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Missing data');
    }
    Map<String, DailySchedule>? parseDay(dynamic day,
        {required bool optional}) {
      if (optional && (day == null || (day is Map && day.isEmpty))) return null;
      if (day is! Map<String, dynamic>) {
        throw const FormatException('Invalid schedule day');
      }
      if (optional &&
          groups.every((g) =>
              day[g] == null || (day[g] is Map && (day[g] as Map).isEmpty))) {
        return null;
      }
      final result = <String, DailySchedule>{};
      const values = {
        'yes': LightStatus.on,
        'no': LightStatus.off,
        'first': LightStatus.semiOn,
        'second': LightStatus.semiOff,
        'maybe': LightStatus.maybe,
        'mfirst': LightStatus.maybe,
        'msecond': LightStatus.maybe
      };
      for (final group in groups) {
        final hours = day[group];
        if (hours is! Map || hours.length != 24) {
          throw FormatException('Incomplete schedule for $group');
        }
        final statuses = <LightStatus>[];
        for (var hour = 1; hour <= 24; hour++) {
          final rawStatus = hours['$hour'];
          final status = rawStatus is String
              ? values[rawStatus.trim().toLowerCase()]
              : null;
          if (status == null) {
            throw FormatException('Invalid hour $hour for $group');
          }
          statuses.add(status);
        }
        result[group] = DailySchedule(List.unmodifiable(statuses));
      }
      return result;
    }

    final todaySchedules = parseDay(data['$timestamp'], optional: false)!;
    final tomorrowKeyExact = '${tomorrow.millisecondsSinceEpoch ~/ 1000}';
    final tomorrowKeyFallback = '${timestamp + 86400}';
    final tomorrowKeys = data.keys.where((key) {
      final stamp = int.tryParse(key);
      return stamp != null &&
          (stamp * 1000 - current.millisecondsSinceEpoch).abs() <
              3 * 86400000 &&
          dateKey(tz.TZDateTime.fromMillisecondsSinceEpoch(
                  _kyiv, stamp * 1000)) ==
              dateKey(tomorrow);
    }).toList();
    if (tomorrowKeys.length > 1 ||
        (tomorrowKeys.isNotEmpty &&
            tomorrowKeys.single != tomorrowKeyExact &&
            tomorrowKeys.single != tomorrowKeyFallback)) {
      throw const FormatException('Invalid or ambiguous tomorrow date');
    }
    final tomorrowRawData = data[tomorrowKeyExact] ?? data[tomorrowKeyFallback];
    final tomorrowSchedules = parseDay(tomorrowRawData, optional: true);
    return DtekSnapshot._(
        fact,
        {
          for (final g in groups)
            g: FullSchedule(
                today: todaySchedules[g]!,
                tomorrow: tomorrowSchedules?[g] ?? DailySchedule.empty(),
                lastUpdatedSource: update.trim())
        },
        dateKey(today),
        dateKey(tomorrow),
        update.trim());
  }

  /// Extract JSON literals, skipping null assignments and unrelated JavaScript.
  static String extractJson(String html) {
    for (final assignment
        in RegExp(r'DisconSchedule\.fact\s*=\s*').allMatches(html)) {
      final start = assignment.end;
      var depth = 0;
      var quoted = false;
      var escaped = false;
      for (var i = start; i < html.length; i++) {
        final c = html[i];
        var complete = false;
        if (quoted) {
          if (escaped) {
            escaped = false;
          } else if (c == r'\') {
            escaped = true;
          } else if (c == '"') {
            quoted = false;
            complete = depth == 0;
          }
        } else if (c == '"') {
          quoted = true;
        } else if (c == '{' || c == '[') {
          depth++;
        } else if (c == '}' || c == ']') {
          depth--;
          complete = depth == 0;
        } else if (depth == 0) {
          break;
        }
        if (complete) {
          final literal = html.substring(start, i + 1);
          try {
            jsonDecode(literal);
            return literal;
          } catch (_) {
            break;
          }
        }
      }
    }
    return '';
  }
}
