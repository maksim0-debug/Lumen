import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_logger.dart';

/// Shares only an overlapping fetch, never a previously completed cached fetch.
/// A SQLite lease coordinates UI, widget and WorkManager engines/processes.
class AndroidFetchCoordinator {
  final Future<Database> Function() database;
  final Duration pollInterval;
  static int _counter = 0;

  AndroidFetchCoordinator(this.database,
      {this.pollInterval = const Duration(milliseconds: 500)});

  static Future<void> createSchema(DatabaseExecutor db) => db.execute('''
    CREATE TABLE IF NOT EXISTS android_schedule_fetch (
      target TEXT PRIMARY KEY,
      owner TEXT,
      expires_at INTEGER NOT NULL,
      completed_owner TEXT,
      completed_at INTEGER,
      payload TEXT
    )
  ''');

  Future<({T value, int completedAt})?> recent<T>({
    required String target,
    required Duration maxAge,
    required T? Function(String) decode,
  }) async {
    final rows = await (await database()).query('android_schedule_fetch',
        where: 'target = ?', whereArgs: [target]);
    if (rows.isEmpty) return null;
    final row = rows.single;
    if (row['owner'] != null) return null;
    final completedAt = row['completed_at'] as int?;
    final payload = row['payload'] as String?;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (completedAt == null ||
        payload == null ||
        completedAt > now ||
        now - completedAt >= maxAge.inMilliseconds) {
      return null;
    }
    final value = decode(payload);
    return value == null ? null : (value: value, completedAt: completedAt);
  }

  Future<T> run<T>({
    required String target,
    required Duration waitTimeout,
    required Duration leaseDuration,
    required Future<T> Function() fetch,
    required String Function(T) encode,
    required T? Function(String) decode,
    void Function(String stage, Map<String, Object?> fields)? observe,
  }) async {
    final db = await database();
    final token = '$pid-${Isolate.current.hashCode}-'
        '${DateTime.now().microsecondsSinceEpoch}-${++_counter}';
    final waiting = Stopwatch()..start();
    String? joinedOwner;
    while (true) {
      final decision = await db.transaction((txn) async {
        final rows = await txn.query('android_schedule_fetch',
            where: 'target = ?', whereArgs: [target]);
        final row = rows.isEmpty ? null : rows.single;
        if (joinedOwner != null && row?['completed_owner'] == joinedOwner) {
          final payload = row?['payload'] as String?;
          if (payload != null) {
            final shared = decode(payload);
            if (shared != null) {
              return (acquired: false, shared: shared, owner: joinedOwner);
            }
          }
        }
        final now = DateTime.now().millisecondsSinceEpoch;
        final owner = row?['owner'] as String?;
        final expiry = row?['expires_at'] as int? ?? 0;
        // Also recover a lease made implausibly long by a wall-clock rollback.
        if (owner != null &&
            expiry > now &&
            expiry <= now + const Duration(minutes: 3).inMilliseconds) {
          return (acquired: false, shared: null as T?, owner: owner);
        }
        if (joinedOwner != null && waiting.elapsed >= waitTimeout) {
          return (acquired: false, shared: null as T?, owner: owner);
        }
        await txn.insert(
            'android_schedule_fetch',
            {
              'target': target,
              'owner': token,
              'expires_at': now + leaseDuration.inMilliseconds,
              'completed_owner': row?['completed_owner'],
              'completed_at': row?['completed_at'],
              'payload': row?['payload'],
            },
            conflictAlgorithm: ConflictAlgorithm.replace);
        return (acquired: true, shared: null as T?, owner: token);
      });
      if (decision.shared != null) {
        observe?.call('fetch_shared', {'sharedLeaseOwner': decision.owner});
        return decision.shared as T;
      }
      if (decision.acquired) {
        observe?.call('fetch_lease', {'leaseOwner': token});
        break;
      }
      if (joinedOwner == null) {
        observe?.call('fetch_wait', {'sharedLeaseOwner': decision.owner});
      }
      joinedOwner = decision.owner;
      if (waiting.elapsed >= waitTimeout) {
        observe
            ?.call('fetch_wait_timeout', {'sharedLeaseOwner': decision.owner});
        throw TimeoutException(
            'Overlapping Android fetch did not finish', waitTimeout);
      }
      final remaining = waitTimeout - waiting.elapsed;
      await Future<void>.delayed(
          remaining < pollInterval ? remaining : pollInterval);
    }

    String? payload;
    try {
      final result = await fetch();
      payload = encode(result);
      return result;
    } finally {
      // Ownership condition prevents a late owner from releasing a replacement.
      try {
        await db.update(
            'android_schedule_fetch',
            {
              'owner': null,
              'expires_at': 0,
              'completed_owner': token,
              'completed_at': DateTime.now().millisecondsSinceEpoch,
              'payload': payload,
            },
            where: 'target = ? AND owner = ?',
            whereArgs: [target, token]);
      } catch (error) {
        // A closed/failed DB must not replace a successful fetch or its exception.
        // The bounded lease allows the next engine to recover.
        AppLogger.w('Cannot release Android fetch lease (${error.runtimeType})',
            tag: 'Parser', persistToHistory: false);
      }
    }
  }
}
