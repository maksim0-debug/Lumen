import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/schedule_change_event.dart';
import 'history_service.dart';

enum ScheduleNotificationObservation { rejected, settled, pending }

class ScheduleNotificationClaim {
  final ScheduleChangeEvent event;
  final String identity;
  final int lease;
  final String? previousHash;
  ScheduleNotificationClaim(
      this.event, this.identity, this.lease, this.previousHash);
}

/// SQLite transactions arbitrate foreground, FCM and Workmanager connections.
/// Platform notification calls run outside the transaction.
class ScheduleChangeNotificationStore {
  final Future<Database> Function() _database;
  ScheduleChangeNotificationStore({Future<Database> Function()? database})
      : _database = database ?? (() => HistoryService().database);

  static Future<void> createSchema(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS schedule_notification_state (
      group_key TEXT NOT NULL, target_date TEXT NOT NULL,
      source_version INTEGER NOT NULL, schedule_hash TEXT NOT NULL,
      event_key TEXT NOT NULL, handled_hash TEXT, handled_version INTEGER NOT NULL,
      previous_hash TEXT,
      pending_since INTEGER, claim_key TEXT, claim_until INTEGER,
      PRIMARY KEY (group_key, target_date)
    )
  ''');

  static List<Object?> _args(ScheduleChangeEvent event) =>
      [event.group, event.targetDate];
  static const _where = 'group_key = ? AND target_date = ?';

  Future<T> _transaction<T>(Future<T> Function(Transaction) action) async {
    final db = await _database();
    for (var attempt = 0;; attempt++) {
      try {
        return await db.transaction(action);
      } on DatabaseException catch (error) {
        // Independent background connections can contend for SQLite's writer.
        // Retry only rolled-back transactions, never platform notification calls.
        final code = error.getResultCode();
        if (attempt >= 5 || code == null || ![5, 6].contains(code & 0xff)) {
          rethrow;
        }
        await Future<void>.delayed(Duration(milliseconds: 20 * (1 << attempt)));
      }
    }
  }

  Future<ScheduleNotificationObservation> observe(ScheduleChangeEvent event,
      {required int nowMs,
      bool fromPush = false,
      bool handled = false,
      String? legacyHash}) async {
    return _transaction((txn) async {
      final rows = await txn.query('schedule_notification_state',
          where: _where, whereArgs: _args(event));
      final old = rows.isEmpty ? null : rows.single;
      if (old != null) {
        final version = old['source_version'] as int;
        if (event.sourceVersion < version) {
          return ScheduleNotificationObservation.rejected;
        }
        if (event.sourceVersion == version &&
            event.hash != old['schedule_hash']) {
          throw const FormatException(
              'Conflicting schedule notification version');
        }
      }
      final validLegacy =
          legacyHash != null && RegExp(r'^[0-4]{24}$').hasMatch(legacyHash);
      final previous =
          old?['schedule_hash'] as String? ?? (validLegacy ? legacyHash : null);
      final same = previous == event.hash;
      final handledHash =
          old?['handled_hash'] as String? ?? (validLegacy ? legacyHash : null);
      final baseline = old == null && !fromPush && !validLegacy;
      final consume = handled ||
          baseline ||
          event.isWithdrawal ||
          handledHash == event.hash;
      final next = <String, Object?>{
        'group_key': event.group, 'target_date': event.targetDate,
        'source_version': event.sourceVersion, 'schedule_hash': event.hash,
        // Content-equivalent republications retain the pending transition.
        'event_key': same && old != null ? old['event_key'] : event.id,
        'handled_hash': consume ? event.hash : handledHash,
        'handled_version': handled || baseline || event.isWithdrawal
            ? event.sourceVersion
            : old?['handled_version'] ?? 0,
        'previous_hash': same && old != null ? old['previous_hash'] : previous,
        'pending_since': consume
            ? null
            : ((same && old != null ? old['pending_since'] : null) ?? nowMs),
        'claim_key': old?['claim_key'], 'claim_until': old?['claim_until'],
      };
      final result = next['pending_since'] == null
          ? ScheduleNotificationObservation.settled
          : ScheduleNotificationObservation.pending;
      // Repeated polls and pushes must still expose pending recovery, but an
      // identical settled observation needs neither a write nor a new claim.
      if (old != null &&
          next.entries.every((entry) => old[entry.key] == entry.value)) {
        return result;
      }
      await txn.insert('schedule_notification_state', next,
          conflictAlgorithm: ConflictAlgorithm.replace);
      // State is bounded by calendar dates, not an evictable event-ID cache.
      await txn.delete('schedule_notification_state',
          where: 'target_date < ?',
          whereArgs: [
            DateTime.fromMillisecondsSinceEpoch(nowMs, isUtc: true)
                .subtract(const Duration(days: 7))
                .toIso8601String()
                .substring(0, 10)
          ]);
      return result;
    });
  }

  Future<ScheduleNotificationClaim?> claim(ScheduleChangeEvent event,
      {required int nowMs}) async {
    return _transaction((txn) async {
      final rows = await txn.query('schedule_notification_state',
          where: _where, whereArgs: _args(event));
      if (rows.isEmpty) return null;
      final row = rows.single;
      final pending = row['pending_since'] as int?;
      if (pending == null || (row['claim_until'] as int? ?? 0) > nowMs) {
        return null;
      }
      final current = ScheduleChangeEvent(
          group: event.group,
          targetDate: event.targetDate,
          dayType: event.dayType,
          hash: row['schedule_hash'] as String,
          sourceVersion: row['source_version'] as int);
      final identity = row['event_key'] as String;
      final lease = nowMs + const Duration(minutes: 1).inMilliseconds;
      await txn.update('schedule_notification_state',
          {'claim_key': identity, 'claim_until': lease},
          where: _where, whereArgs: _args(event));
      return ScheduleNotificationClaim(
          current, identity, lease, row['previous_hash'] as String?);
    });
  }

  Future<void> finish(ScheduleNotificationClaim claim,
      {required bool success}) async {
    await _transaction((txn) async {
      final rows = await txn.query('schedule_notification_state',
          where: _where, whereArgs: _args(claim.event));
      if (rows.isEmpty) return;
      final row = rows.single;
      if (row['claim_key'] != claim.identity ||
          row['claim_until'] != claim.lease) {
        return;
      }
      final canAcknowledge = success &&
          (row['handled_version'] as int) <= claim.event.sourceVersion;
      final superseded = row['schedule_hash'] != claim.event.hash;
      await txn.update(
          'schedule_notification_state',
          {
            'claim_key': null,
            'claim_until': null,
            if (canAcknowledge) 'handled_hash': claim.event.hash,
            if (canAcknowledge) 'handled_version': claim.event.sourceVersion,
            if (canAcknowledge && superseded) 'previous_hash': claim.event.hash,
            if (canAcknowledge)
              'pending_since': superseded
                  ? row['pending_since'] ??
                      claim.lease - const Duration(minutes: 1).inMilliseconds
                  : null,
          },
          where: _where,
          whereArgs: _args(claim.event));
    });
  }
}
