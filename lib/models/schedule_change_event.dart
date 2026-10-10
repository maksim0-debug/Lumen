import '../services/dtek_snapshot.dart';
import '../services/parser_service.dart';
import '../services/schedule_clock.dart';
import '../utils/app_formatters.dart';
import 'schedule_status.dart';

/// Identity uses the source publication, never the time a device downloaded it.
class ScheduleChangeEvent {
  final String group;
  final String targetDate;
  final int sourceVersion;
  final String hash;
  final String dayType;

  ScheduleChangeEvent({
    required this.group,
    required this.targetDate,
    required this.sourceVersion,
    required this.hash,
    required this.dayType,
    bool allowWithdrawal = false,
  }) {
    final date = DateTime.tryParse(targetDate);
    if (!ParserService.allGroups.contains(group) ||
        !['today', 'tomorrow'].contains(dayType) ||
        date == null ||
        AppFormatters.formatDateKey(date) != targetDate ||
        sourceVersion <= 0 ||
        (!RegExp(r'^[0-4]{24}$').hasMatch(hash) &&
            !(allowWithdrawal && dayType == 'tomorrow' && hash == '9' * 24))) {
      throw const FormatException('Invalid schedule event');
    }
  }

  String get id => '$group:$targetDate:$sourceVersion:$hash';
  bool get isWithdrawal => hash == '9' * 24;
  DailySchedule get schedule => DailySchedule.fromEncodedString(hash);

  factory ScheduleChangeEvent.fromSchedule(
          String group, FullSchedule value, String dayType, DateTime now) =>
      ScheduleChangeEvent(
        group: group,
        targetDate: DtekSnapshot.notificationDate(dayType, now: now),
        sourceVersion: ScheduleClock.parseVersion(value.lastUpdatedSource),
        hash:
            (dayType == 'tomorrow' ? value.tomorrow : value.today).scheduleHash,
        dayType: dayType,
        allowWithdrawal: true,
      );

  factory ScheduleChangeEvent.fromPush(
      Map<String, dynamic> data, DateTime now) {
    final group = data['group'];
    final date = data['targetDate'];
    final hash = data['scheduleHash'];
    final dayType = data['dayType'];
    final id = data['eventId'];
    final schema = data['schemaVersion'];
    if (![
          'schedule_updated',
          'schedule_update',
          'tomorrow_schedule_updated',
          'tomorrow_published'
        ].contains(data['type']) ||
        group is! String ||
        date is! String ||
        hash is! String ||
        dayType is! String ||
        id is! String ||
        (schema != null && schema != '2')) {
      throw const FormatException('Incomplete schedule push');
    }
    final parts = id.split(':');
    final version = int.tryParse(
        '${data['sourceVersion'] ?? (parts.length == 4 ? parts[2] : '')}');
    if (version == null || version > now.millisecondsSinceEpoch + 4 * 3600000) {
      throw const FormatException('Invalid schedule publication time');
    }
    final event = ScheduleChangeEvent(
        group: group,
        targetDate: date,
        sourceVersion: version,
        hash: hash,
        dayType: dayType);
    if (event.id != id ||
        date != DtekSnapshot.notificationDate(dayType, now: now)) {
      throw const FormatException('Expired or inconsistent schedule push');
    }
    return event;
  }

  String title({bool published = false}) {
    final name = AppFormatters.formatGroupName(group);
    if (published) {
      return 'Опубліковано графік на ${dayType == 'tomorrow' ? 'ЗАВТРА' : 'СЬОГОДНІ'}! ($name)';
    }
    return 'Графік${dayType == 'tomorrow' ? ' на ЗАВТРА' : ''} змінено! ($name)';
  }

  String body(String? previousHash) {
    if (previousHash == null || previousHash == '9' * 24) {
      final minutes = schedule.totalOutageMinutes;
      return minutes == 0
          ? 'Відключень не заплановано 🎉'
          : 'Заплановано відключень: ${AppFormatters.formatHours(minutes)} год. ⚡';
    }
    final message = AppFormatters.formatScheduleChangeMessage(
        oldMinutes:
            DailySchedule.fromEncodedString(previousHash).totalOutageMinutes,
        newMinutes: schedule.totalOutageMinutes);
    return dayType == 'tomorrow'
        ? message.replaceAll('на сьогодні', 'на завтра')
        : message;
  }
}
