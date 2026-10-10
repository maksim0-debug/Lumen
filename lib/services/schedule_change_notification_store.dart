import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import '../models/schedule_change_event.dart';
import 'history_service.dart';
import 'parser_service.dart';
import 'preferences_helper.dart';
import 'schedule_clock.dart';
import 'app_logger.dart';

class ScheduleNotificationPolicy {
  final List<Map<String, Object?>> rows;
  ScheduleNotificationPolicy(this.rows);

  Map<String, Object?>? _row(ScheduleChangeEvent event) {
    for (final row in rows) {
      if (row['group_key'] == event.group && row['day_type'] == event.dayType) {
        return row;
      }
    }
    return null;
  }

  bool allows(ScheduleChangeEvent event) => _row(event)?['enabled'] == 1;
  bool needsBaseline(ScheduleChangeEvent event) => rows.any((row) =>
      row['group_key'] == event.group &&
      row['baseline_date'] == event.targetDate);
}

enum ScheduleNotificationObservation { rejected, settled, pending }

class ScheduleNotificationClaim {
  final ScheduleChangeEvent event;
  final String identity;
  final int lease;
  final String? previousHash;
  final int? generation;
  ScheduleNotificationClaim(
      this.event, this.identity, this.lease, this.previousHash,
      {this.generation});
}

/// SQLite transactions arbitrate foreground, FCM and Workmanager connections.
/// Platform notification calls run outside the transaction.
class ScheduleChangeNotificationStore {
  final Future<Database> Function() _database;
  ScheduleChangeNotificationStore({Future<Database> Function()? database})
      : _database = database ?? (() => HistoryService().database);

  static Future<void> createSchema(DatabaseExecutor db) async {
    await db.execute('''
    CREATE TABLE IF NOT EXISTS schedule_notification_state (
      group_key TEXT NOT NULL, target_date TEXT NOT NULL,
      source_version INTEGER NOT NULL, schedule_hash TEXT NOT NULL,
      event_key TEXT NOT NULL, handled_hash TEXT, handled_version INTEGER NOT NULL,
      previous_hash TEXT,
      pending_since INTEGER, claim_key TEXT, claim_until INTEGER,
      PRIMARY KEY (group_key, target_date)
    )
  ''');
    await db.execute('''
      CREATE TABLE IF NOT EXISTS schedule_notification_policy (
        group_key TEXT NOT NULL, day_type TEXT NOT NULL,
        enabled INTEGER NOT NULL, generation INTEGER NOT NULL,
        baseline_date TEXT,
        PRIMARY KEY (group_key, day_type)
      )
    ''');
  }

  /// Preferences are reloaded while holding the same writer lock used by
  /// settings changes. A late isolate cannot restore an older activation.
  Future<T> withPreferences<T>(
          Future<SharedPreferences> Function() preferences,
          DateTime now,
          Future<T> Function(DatabaseExecutor, SharedPreferences,
                  ScheduleNotificationPolicy)
              action) =>
      _transaction((txn) async {
        final prefs = await preferences();
        await prefs.reload();
        final policy = await synchronizePolicyIn(txn, prefs, now);
        return action(txn, prefs, policy);
      });

  Future<ScheduleNotificationPolicy> synchronizePolicyIn(
      DatabaseExecutor txn, SharedPreferences prefs, DateTime now) async {
    await createSchema(txn);
    final oldRows = await txn.query('schedule_notification_policy');
    final groups = PreferencesHelper.getActiveNotificationGroups(prefs).toSet();
    for (final group in ParserService.allGroups) {
      for (final dayType in ['today', 'tomorrow']) {
        final enabled = groups.contains(group) &&
            (prefs.getBool(dayType == 'today'
                    ? 'notify_schedule_change'
                    : 'notify_tomorrow_schedule') ??
                true);
        final matching = oldRows.where(
            (row) => row['group_key'] == group && row['day_type'] == dayType);
        final old = matching.isEmpty ? null : matching.single;
        if (old != null && (old['enabled'] == 1) == enabled) continue;
        String? baselineDate;
        if (old != null) {
          final date = ScheduleClock.day(now, dayType == 'tomorrow' ? 1 : 0)
              .toIso8601String()
              .substring(0, 10);
          // Invalidate an old delivery lease even when the content is equal.
          await txn.rawUpdate(
              'UPDATE schedule_notification_state SET '
              'handled_hash=schedule_hash, handled_version=source_version, '
              'pending_since=NULL, claim_key=NULL, claim_until=NULL '
              'WHERE group_key=? AND target_date=?',
              [group, date]);
          if (enabled &&
              !await _seedBaselineIn(txn, group, date, dayType, now)) {
            baselineDate = date;
          }
        }
        // Bootstrap preserves legitimate pending work from older app versions.
        await txn.insert(
            'schedule_notification_policy',
            {
              'group_key': group,
              'day_type': dayType,
              'enabled': enabled ? 1 : 0,
              'generation': (old?['generation'] as int? ?? 0) + 1,
              'baseline_date': baselineDate,
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
    }
    return ScheduleNotificationPolicy(
        await txn.query('schedule_notification_policy'));
  }

  Future<bool> _seedBaselineIn(DatabaseExecutor txn, String group, String date,
      String dayType, DateTime now) async {
    try {
      return await _readBaselineIn(txn, group, date, dayType, now);
    } on FormatException catch (error) {
      AppLogger.w('Cannot use cached notification baseline for $group/$date',
          tag: 'ScheduleNotifications', error: error, persistToHistory: false);
      return false;
    } on TypeError catch (error) {
      AppLogger.w('Malformed cached notification baseline for $group/$date',
          tag: 'ScheduleNotifications', error: error, persistToHistory: false);
      return false;
    }
  }

  Future<bool> _readBaselineIn(DatabaseExecutor txn, String group, String date,
      String dayType, DateTime now) async {
    final tables = await txn.rawQuery("SELECT name FROM sqlite_master "
        "WHERE type='table' AND name='dtek_snapshot_state'");
    if (tables.isEmpty) return false;
    final metadata = await txn.query('dtek_snapshot_state', where: 'id=1');
    if (metadata.isEmpty) return false;
    final row = metadata.single;
    final fingerprint = jsonDecode(row['fingerprint'] as String);
    if (fingerprint is! List || fingerprint.length < 3) {
      throw const FormatException('Invalid notification baseline snapshot');
    }
    final index = fingerprint[0] == date
        ? 1
        : fingerprint[1] == date
            ? 2
            : null;
    if (index == null) return false;
    for (final item in fingerprint.skip(2)) {
      if (item is! List || item.length != 3) {
        throw const FormatException('Invalid notification baseline group');
      }
      final entry = item;
      if (entry[0] != group) continue;
      final hash = entry[index] as String;
      // Unknown current-day data is not a published baseline.
      if (dayType == 'today' && hash == '9' * 24) return false;
      final event = ScheduleChangeEvent(
          group: group,
          targetDate: date,
          sourceVersion: row['version'] as int,
          hash: hash,
          dayType: dayType,
          allowWithdrawal: true);
      return await observeIn(txn, event,
              nowMs: now.millisecondsSinceEpoch, handled: true) !=
          ScheduleNotificationObservation.rejected;
    }
    return false;
  }

  Future<ScheduleNotificationObservation> observeConfiguredIn(
      DatabaseExecutor txn,
      ScheduleChangeEvent event,
      ScheduleNotificationPolicy policy,
      {required int nowMs,
      bool fromPush = false,
      bool handled = false,
      String? legacyHash}) async {
    final result = await observeIn(txn, event,
        nowMs: nowMs,
        fromPush: fromPush,
        handled: handled ||
            !policy.allows(event) ||
            (policy.needsBaseline(event) && !fromPush),
        legacyHash: legacyHash);
    if (result != ScheduleNotificationObservation.rejected) {
      await txn.update('schedule_notification_policy', {'baseline_date': null},
          where: 'group_key=? AND baseline_date=?',
          whereArgs: [event.group, event.targetDate]);
    }
    return result;
  }

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
    return _transaction((txn) => observeIn(txn, event,
        nowMs: nowMs,
        fromPush: fromPush,
        handled: handled,
        legacyHash: legacyHash));
  }

  Future<ScheduleNotificationObservation> observeIn(
      DatabaseExecutor txn, ScheduleChangeEvent event,
      {required int nowMs,
      bool fromPush = false,
      bool handled = false,
      String? legacyHash}) async {
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
    final consume =
        handled || baseline || event.isWithdrawal || handledHash == event.hash;
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
  }

  Future<ScheduleNotificationClaim?> claim(ScheduleChangeEvent event,
      {required int nowMs}) async {
    return _transaction((txn) async {
      final rows = await txn.query('schedule_notification_state',
          where: _where, whereArgs: _args(event));
      if (rows.isEmpty) return null;
      final row = rows.single;
      final policies = await txn.query('schedule_notification_policy',
          where: 'group_key=? AND day_type=?',
          whereArgs: [event.group, event.dayType]);
      final policy = policies.isEmpty ? null : policies.single;
      if (policy != null && policy['enabled'] != 1) return null;
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
          current, identity, lease, row['previous_hash'] as String?,
          generation: policy?['generation'] as int?);
    });
  }

  Future<bool> isCurrentClaim(ScheduleNotificationClaim claim) =>
      _transaction((txn) async {
        final rows = await txn.query('schedule_notification_state',
            where: _where, whereArgs: _args(claim.event));
        if (rows.isEmpty ||
            rows.single['claim_key'] != claim.identity ||
            rows.single['claim_until'] != claim.lease ||
            rows.single['pending_since'] == null) {
          return false;
        }
        if (claim.generation == null) return true;
        final policies = await txn.query('schedule_notification_policy',
            where: 'group_key=? AND day_type=?',
            whereArgs: [claim.event.group, claim.event.dayType]);
        return policies.isNotEmpty &&
            policies.single['enabled'] == 1 &&
            policies.single['generation'] == claim.generation;
      });

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
      if (claim.generation != null) {
        final policies = await txn.query('schedule_notification_policy',
            where: 'group_key=? AND day_type=?',
            whereArgs: [claim.event.group, claim.event.dayType]);
        if (policies.isEmpty ||
            policies.single['enabled'] != 1 ||
            policies.single['generation'] != claim.generation) {
          return;
        }
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
