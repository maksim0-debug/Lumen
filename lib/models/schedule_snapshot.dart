import 'dart:convert';

import '../services/parser_service.dart';
import '../services/schedule_clock.dart';
import '../utils/app_formatters.dart';
import 'schedule_status.dart';

/// Complete source publication, shared by FCM and the recovery API.
class ScheduleSnapshot {
  final String journalId;
  final int sequence;
  final String todayDate;
  final String tomorrowDate;
  final int sourceVersion;
  final String sourceUpdatedAt;
  final int alerts;
  final Map<String, FullSchedule> schedules;

  ScheduleSnapshot._(
      this.journalId,
      this.sequence,
      this.todayDate,
      this.tomorrowDate,
      this.sourceVersion,
      this.sourceUpdatedAt,
      this.alerts,
      this.schedules);

  static String _date(Object? raw) {
    if (raw is! String) throw const FormatException('Missing snapshot date');
    final date = DateTime.tryParse(raw);
    if (date == null || AppFormatters.formatDateKey(date) != raw) {
      throw const FormatException('Invalid snapshot date');
    }
    return raw;
  }

  factory ScheduleSnapshot.parse(Object? raw, {DateTime? now}) {
    if (raw is String) {
      if (utf8.encode(raw).length > 4096) {
        throw const FormatException('Snapshot exceeds size limit');
      }
      raw = jsonDecode(raw);
    }
    if (raw is! Map || raw['v'] != 1) {
      throw const FormatException('Unsupported snapshot schema');
    }
    final journal = raw['journalId'];
    final sequence = raw['sequence'];
    final version = raw['sourceVersion'];
    final update = raw['sourceUpdatedAt'];
    final alerts = raw['alerts'];
    final groups = raw['groups'];
    final today = _date(raw['todayDate']);
    final tomorrow = _date(raw['tomorrowDate']);
    final todayValue = DateTime.parse(today);
    if (tomorrow !=
            AppFormatters.formatDateKey(DateTime(
                todayValue.year, todayValue.month, todayValue.day + 1)) ||
        journal is! String ||
        !RegExp(r'^[a-zA-Z0-9-]{1,64}$').hasMatch(journal) ||
        sequence is! int ||
        sequence < 1 ||
        sequence > 9007199254740991 ||
        version is! int ||
        version <= 0 ||
        version >
            (now ?? DateTime.now()).millisecondsSinceEpoch + 4 * 3600000 ||
        update is! String ||
        ScheduleClock.parseVersion(update) != version ||
        alerts is! int ||
        alerts < 0 ||
        alerts > 0xffffff ||
        groups is! Map ||
        groups.length != ParserService.allGroups.length) {
      throw const FormatException('Invalid snapshot metadata');
    }
    final schedules = <String, FullSchedule>{};
    bool? tomorrowPublished;
    final code = RegExp(r'^[0-4]{24}$');
    for (final group in ParserService.allGroups) {
      final pair = groups[group];
      if (pair is! List ||
          pair.length != 2 ||
          pair[0] is! String ||
          !code.hasMatch(pair[0] as String) ||
          (pair[1] != null &&
              (pair[1] is! String || !code.hasMatch(pair[1] as String)))) {
        throw const FormatException('Incomplete snapshot group');
      }
      final published = pair[1] != null;
      if (tomorrowPublished != null && tomorrowPublished != published) {
        throw const FormatException('Partial tomorrow publication');
      }
      tomorrowPublished = published;
      DailySchedule immutable(String encoded) => DailySchedule(
          List.unmodifiable(DailySchedule.fromEncodedString(encoded).hours));
      schedules[group] = FullSchedule(
        today: immutable(pair[0] as String),
        tomorrow:
            published ? immutable(pair[1] as String) : immutable('9' * 24),
        lastUpdatedSource: update,
      );
    }
    return ScheduleSnapshot._(journal, sequence, today, tomorrow, version,
        update, alerts, Map.unmodifiable(schedules));
  }

  bool alertsFor(String group, String dayType) =>
      alerts &
          (1 <<
              (ParserService.allGroups.indexOf(group) * 2 +
                  (dayType == 'tomorrow' ? 1 : 0))) !=
      0;

  bool isCurrent(DateTime now) =>
      todayDate == AppFormatters.formatDateKey(ScheduleClock.from(now));

  Map<String, Object?> toJson() => {
        'v': 1,
        'journalId': journalId,
        'sequence': sequence,
        'todayDate': todayDate,
        'tomorrowDate': tomorrowDate,
        'sourceVersion': sourceVersion,
        'sourceUpdatedAt': sourceUpdatedAt,
        'alerts': alerts,
        'groups': {
          for (final e in schedules.entries)
            e.key: [
              e.value.today.scheduleHash,
              e.value.tomorrow.isEmpty ? null : e.value.tomorrow.scheduleHash,
            ]
        },
      };
}
