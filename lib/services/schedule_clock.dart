import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Calendar and wall-clock interpretation of DTEK schedules, independent of device zone.
class ScheduleClock {
  static tz.Location get location {
    if (!tz.timeZoneDatabase.isInitialized) tzdata.initializeTimeZones();
    return tz.getLocation('Europe/Kyiv');
  }

  static tz.TZDateTime calendar(int year, int month, int day,
          [int hour = 0, int minute = 0]) =>
      tz.TZDateTime(location, year, month, day, hour, minute);

  static tz.TZDateTime now() => tz.TZDateTime.now(location);
  static tz.TZDateTime from(DateTime value) =>
      tz.TZDateTime.from(value, location);
  static tz.TZDateTime day(DateTime value, [int offset = 0]) {
    final local = from(value);
    return tz.TZDateTime(location, local.year, local.month, local.day + offset);
  }

  /// Source timestamps without an offset cannot identify the repeated autumn hour.
  static int parseVersion(String value) {
    final match = RegExp(
            r'^(\d{1,2})\.(\d{1,2})\.(\d{4})[\s,]+(?:[ов]\s+|at\s+)?(\d{1,2}):(\d{2})(?::(\d{2}))?$')
        .firstMatch(value.trim());
    if (match == null) throw const FormatException('Invalid DTEK update time');
    final fields = [3, 2, 1, 4, 5, 6]
        .map((i) => int.parse(match.group(i) ?? '0'))
        .toList();
    final wall = DateTime.utc(
        fields[0], fields[1], fields[2], fields[3], fields[4], fields[5]);
    final offsets = [-36, 0, 36]
        .map((hours) => from(wall.add(Duration(hours: hours)))
            .timeZoneOffset
            .inMilliseconds)
        .toSet();
    final candidates = <int>{};
    for (final offset in offsets) {
      final instant = wall.millisecondsSinceEpoch - offset;
      final local = tz.TZDateTime.fromMillisecondsSinceEpoch(location, instant);
      if (local.year == fields[0] &&
          local.month == fields[1] &&
          local.day == fields[2] &&
          local.hour == fields[3] &&
          local.minute == fields[4] &&
          local.second == fields[5]) {
        candidates.add(instant);
      }
    }
    if (candidates.isEmpty) {
      throw const FormatException('Invalid Kyiv update time');
    }
    return candidates.reduce((a, b) => a > b ? a : b);
  }
}
