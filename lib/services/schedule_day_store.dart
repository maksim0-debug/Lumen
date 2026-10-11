import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/schedule_status.dart';
import 'schedule_clock.dart';

/// Source observations and current availability are independent of publications.
/// Adding these tables never rewrites or deletes legacy schedule history.
class ScheduleDayStore {
  static const unavailableCode = DailySchedule.emptyCode;
  static final _sourceCode = RegExp(r'^(?:[0-4]{24}|9{24})$');

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS dtek_day_observations ('
        'group_key TEXT NOT NULL, target_date TEXT NOT NULL, '
        'snapshot_date TEXT NOT NULL, source_version INTEGER NOT NULL, '
        'schedule_code TEXT NOT NULL, dtek_updated_at TEXT NOT NULL, '
        'history_id INTEGER, '
        'PRIMARY KEY (group_key, target_date, snapshot_date, source_version))');
    await db.execute('CREATE TABLE IF NOT EXISTS dtek_current_day_state ('
        'group_key TEXT NOT NULL, target_date TEXT NOT NULL, '
        'snapshot_date TEXT NOT NULL, source_version INTEGER NOT NULL, '
        'schedule_code TEXT NOT NULL, dtek_updated_at TEXT NOT NULL, '
        'history_id INTEGER, manual_after_id INTEGER NOT NULL, '
        'PRIMARY KEY (group_key, target_date))');
  }

  static int? sourceVersion(Object? value) {
    if (value is! String) return null;
    try {
      return ScheduleClock.parseVersion(value);
    } on FormatException {
      return null;
    }
  }

  /// Called inside the caller's transaction for both live ingestion and backfill.
  /// Absence is recorded without manufacturing a schedule_history publication.
  static Future<int?> record(
    DatabaseExecutor db, {
    required String group,
    required String targetDate,
    required String snapshotDate,
    required int version,
    required String updatedAt,
    required DailySchedule schedule,
    required List<Map<String, Object?>> historyRows,
  }) async {
    final code = schedule.scheduleHash;
    if (!_sourceCode.hasMatch(code)) {
      throw const FormatException('Invalid source schedule code');
    }
    final observations = await db.query('dtek_day_observations',
        where:
            'group_key=? AND target_date=? AND snapshot_date=? AND source_version=?',
        whereArgs: [group, targetDate, snapshotDate, version]);
    if (observations.isNotEmpty) {
      final existing = observations.single;
      if (existing['schedule_code'] != code) {
        throw const FormatException('Conflicting source day observation');
      }
      return existing['history_id'] as int?;
    }

    int? historyId;
    if (!schedule.isEmpty) {
      for (final row in historyRows) {
        if (!DailySchedule.isValidCode(row['schedule_code']) ||
            sourceVersion(row['dtek_updated_at']) != version ||
            row['schedule_code'] == unavailableCode) {
          continue;
        }
        if (row['schedule_code'] != code) {
          throw const FormatException('Conflicting archived publication');
        }
        historyId ??= row['id'] as int;
      }
      historyId ??= await db.insert('schedule_history', {
        'group_key': group,
        'target_date': targetDate,
        'schedule_code': code,
        'dtek_updated_at': updatedAt,
      });
    }

    await db.insert('dtek_day_observations', {
      'group_key': group,
      'target_date': targetDate,
      'snapshot_date': snapshotDate,
      'source_version': version,
      'schedule_code': code,
      'dtek_updated_at': updatedAt,
      'history_id': historyId,
    });
    return historyId;
  }

  static Future<bool> hasSchema(DatabaseExecutor db) async =>
      (await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' "
              "AND name='dtek_day_observations'"))
          .isNotEmpty;

  /// History-compatible shape; an absence has no publication record identity.
  static Map<String, Object?> historyRow(Map<String, Object?> state) => {
        'id': state['history_id'],
        'group_key': state['group_key'],
        'target_date': state['target_date'],
        'schedule_code': state['schedule_code'],
        'dtek_updated_at': state['dtek_updated_at'],
        'snapshot_date': state['snapshot_date'],
      };

  /// Portable observations omit local SQLite identities. Import never changes
  /// current pointers, notification delivery, or the live source watermark.
  static Future<List<Map<String, Object?>>> exportObservations(
      DatabaseExecutor db,
      {String? where,
      List<Object?>? whereArgs}) async {
    if (!await hasSchema(db)) return [];
    return db.query('dtek_day_observations',
        columns: [
          'group_key',
          'target_date',
          'snapshot_date',
          'source_version',
          'schedule_code',
          'dtek_updated_at'
        ],
        where: where,
        whereArgs: whereArgs,
        orderBy: 'snapshot_date ASC, source_version ASC, group_key ASC');
  }

  static Future<void> importObservations(
      DatabaseExecutor db, Object? raw) async {
    if (raw == null) return;
    if (raw is! List) {
      throw const FormatException('Invalid source observations');
    }
    await createSchema(db);
    for (final value in raw) {
      if (value is! Map ||
          value['group_key'] is! String ||
          (value['group_key'] as String).isEmpty ||
          value['target_date'] is! String ||
          value['snapshot_date'] is! String ||
          value['source_version'] is! int ||
          value['schedule_code'] is! String ||
          value['dtek_updated_at'] is! String) {
        throw const FormatException('Invalid source observation');
      }
      final target = value['target_date'] as String;
      final calendar = value['snapshot_date'] as String;
      final date = DateTime.tryParse(calendar);
      final targetValue = DateTime.tryParse(target);
      final version = value['source_version'] as int;
      final code = value['schedule_code'] as String;
      if (date == null ||
          targetValue == null ||
          date.toIso8601String().substring(0, 10) != calendar ||
          targetValue.toIso8601String().substring(0, 10) != target ||
          (target != calendar &&
              target !=
                  DateTime(date.year, date.month, date.day + 1)
                      .toIso8601String()
                      .substring(0, 10)) ||
          version <= 0 ||
          sourceVersion(value['dtek_updated_at']) != version ||
          !_sourceCode.hasMatch(code)) {
        throw const FormatException('Invalid source observation metadata');
      }
      final group = value['group_key'] as String;
      final rows = await db.query('schedule_history',
          where: 'group_key=? AND target_date=?', whereArgs: [group, target]);
      await record(db,
          group: group,
          targetDate: target,
          snapshotDate: calendar,
          version: version,
          updatedAt: value['dtek_updated_at'] as String,
          schedule: DailySchedule.fromEncodedString(code),
          historyRows: rows);
    }
  }
}
