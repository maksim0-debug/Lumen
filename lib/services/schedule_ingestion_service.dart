import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/schedule_change_event.dart';
import '../models/schedule_snapshot.dart';
import '../models/schedule_status.dart';
import 'history_service.dart';
import 'schedule_change_notification_service.dart';
import 'schedule_clock.dart';

/// SQLite is authoritative across foreground and background isolates.
class ScheduleIngestionService {
  final HistoryService history;
  final ScheduleChangeNotificationService changes;
  final DateTime Function() now;

  ScheduleIngestionService(
      {HistoryService? history,
      ScheduleChangeNotificationService? changes,
      DateTime Function()? now})
      : history = history ?? HistoryService(),
        changes = changes ?? ScheduleChangeNotificationService(),
        now = now ?? ScheduleClock.now;

  static Future<void> _schema(DatabaseExecutor db) async {
    await db.execute('CREATE TABLE IF NOT EXISTS schedule_local_work ('
        'id INTEGER PRIMARY KEY CHECK(id=1), identity TEXT NOT NULL, '
        'revision INTEGER NOT NULL, processed INTEGER NOT NULL DEFAULT 0, '
        'claim_until INTEGER NOT NULL DEFAULT 0)');
  }

  static Future<void> createCursorSchema(DatabaseExecutor db) => db.execute(
      'CREATE TABLE IF NOT EXISTS schedule_journal_cursor ('
      'endpoint TEXT PRIMARY KEY, journal_id TEXT NOT NULL, sequence INTEGER NOT NULL)');

  /// Backfill is append-only: it cannot move current pointers or delivery state.
  Future<void> archivePage(List<ScheduleSnapshot> publications,
      {required String endpoint,
      required String journalId,
      required int previous,
      required int next,
      String? expectedJournalId}) async {
    final db = await history.database;
    await createCursorSchema(db);
    await db.transaction((txn) async {
      final cursor = await txn.query('schedule_journal_cursor',
          where: 'endpoint=?', whereArgs: [endpoint]);
      if ((cursor.isNotEmpty &&
              (cursor.single['journal_id'] != expectedJournalId ||
                  cursor.single['sequence'] != previous)) ||
          (cursor.isEmpty && previous != 0)) {
        return;
      }
      for (final snapshot in publications) {
        for (final e in snapshot.schedules.entries) {
          for (final day in [
            (snapshot.todayDate, e.value.today),
            (snapshot.tomorrowDate, e.value.tomorrow)
          ]) {
            final rows = await txn.query('schedule_history',
                where: 'group_key=? AND target_date=? AND dtek_updated_at=?',
                whereArgs: [e.key, day.$1, snapshot.sourceUpdatedAt]);
            if (rows.any((r) => r['schedule_code'] != day.$2.scheduleHash)) {
              throw const FormatException('Conflicting archived publication');
            }
            if (rows.isEmpty) {
              await txn.insert('schedule_history', {
                'group_key': e.key,
                'target_date': day.$1,
                'schedule_code': day.$2.scheduleHash,
                'dtek_updated_at': snapshot.sourceUpdatedAt,
              });
            }
          }
        }
      }
      await txn.insert(
          'schedule_journal_cursor',
          {
            'endpoint': endpoint,
            'journal_id': journalId,
            'sequence': next,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
    });
  }

  Future<void> ingest(ScheduleSnapshot snapshot,
      {bool fromPush = false,
      ScheduleChangeEvent? trigger,
      bool alreadyDisplayed = false}) async {
    if (!snapshot.isCurrent(now())) {
      throw const FormatException('Snapshot is not for current Kyiv date');
    }
    if (trigger != null &&
        (trigger.sourceVersion != snapshot.sourceVersion ||
            trigger.targetDate !=
                (trigger.dayType == 'today'
                    ? snapshot.todayDate
                    : snapshot.tomorrowDate) ||
            trigger.hash !=
                (trigger.dayType == 'today'
                    ? snapshot.schedules[trigger.group]?.today.scheduleHash
                    : snapshot
                        .schedules[trigger.group]?.tomorrow.scheduleHash))) {
      throw const FormatException('Push event does not match snapshot');
    }
    await history.persistSnapshot(
        schedules: snapshot.schedules,
        todayDate: snapshot.todayDate,
        tomorrowDate: snapshot.tomorrowDate,
        dtekUpdatedAt: snapshot.sourceUpdatedAt,
        afterPersist: (txn) async {
          await changes.stageSnapshot(txn, snapshot,
              fromPush: fromPush,
              trigger: trigger,
              alreadyDisplayed: alreadyDisplayed);
          await _schema(txn);
          final identity = jsonEncode([
            snapshot.todayDate,
            snapshot.sourceVersion,
            for (final e in snapshot.schedules.entries)
              [e.key, e.value.today.scheduleHash, e.value.tomorrow.scheduleHash]
          ]);
          final rows = await txn.query('schedule_local_work', where: 'id=1');
          if (rows.isEmpty) {
            await txn.insert('schedule_local_work',
                {'id': 1, 'identity': identity, 'revision': 1});
          } else if (rows.single['identity'] != identity) {
            await txn.update(
                'schedule_local_work',
                {
                  'identity': identity,
                  'revision': (rows.single['revision'] as int) + 1,
                },
                where: 'id=1');
          }
        });
  }

  /// A bounded lease serializes local effects. A newer revision remains pending
  /// even if an earlier worker finishes, and failures never consume the work.
  Future<bool> applyPending(
      Future<void> Function(Map<String, FullSchedule>) apply) async {
    final db = await history.database;
    await _schema(db);
    for (var pass = 0; pass < 4; pass++) {
      final stamp = now().millisecondsSinceEpoch;
      final lease = stamp + const Duration(minutes: 2).inMilliseconds;
      final revision = await db.transaction<int?>((txn) async {
        final rows = await txn.query('schedule_local_work', where: 'id=1');
        if (rows.isEmpty ||
            rows.single['revision'] == rows.single['processed']) {
          return null;
        }
        if ((rows.single['claim_until'] as int) > stamp) return -1;
        await txn.update('schedule_local_work', {'claim_until': lease},
            where: 'id=1');
        return rows.single['revision'] as int;
      });
      if (revision == null) return true;
      if (revision == -1) return false;
      var success = false;
      try {
        final schedules = await history.getLastKnownSchedules();
        if (schedules.isNotEmpty) await apply(schedules);
        success = true;
      } finally {
        await db.transaction((txn) async {
          await txn.update(
              'schedule_local_work',
              {
                'claim_until': 0,
                if (success) 'processed': revision,
              },
              where: 'id=1 AND claim_until=?',
              whereArgs: [lease]);
        });
      }
    }
    return false;
  }
}
