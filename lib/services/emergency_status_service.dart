import 'dart:async';
import 'dart:convert';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/emergency_status.dart';
import 'history_service.dart';
import 'app_logger.dart';

/// SQLite transactions serialize foreground/background writers across isolates.
/// No SharedPreferences cache is used for operational state.
class EmergencyStatusService {
  static final _instance = EmergencyStatusService._();
  factory EmergencyStatusService() => _instance;
  EmergencyStatusService._() : _database = (() => HistoryService().database);
  EmergencyStatusService.forTesting(Future<Database> Function() database)
      : _database = database;
  final Future<Database> Function() _database;
  final _schemaInitializations = Expando<Future<void>>();
  final _changes = StreamController<EmergencyStatus>.broadcast();
  Stream<EmergencyStatus> get changes => _changes.stream;
  EmergencyStatus _latest = const EmergencyStatus();

  Future<Database> _open() async {
    final database = await _database();
    // Cache per connection, not per service: backup import replaces the DB.
    // Concurrent callers await the same migration, and failures remain retryable.
    final initialization =
        _schemaInitializations[database] ??= _initializeSchema(database);
    try {
      await initialization;
    } catch (_) {
      if (identical(_schemaInitializations[database], initialization)) {
        _schemaInitializations[database] = null;
      }
      rethrow;
    }
    return database;
  }

  Future<void> _initializeSchema(Database database) =>
      database.transaction((transaction) async {
        await transaction
            .execute('CREATE TABLE IF NOT EXISTS emergency_status ('
                'id INTEGER PRIMARY KEY CHECK (id = 1), payload TEXT NOT NULL, '
                'notified_at INTEGER NOT NULL DEFAULT 0, '
                'claim_version INTEGER NOT NULL DEFAULT 0, '
                'claim_until INTEGER NOT NULL DEFAULT 0)');
        final columns =
            (await transaction.rawQuery('PRAGMA table_info(emergency_status)'))
                .map((column) => column['name'])
                .toSet();
        for (final name in ['claim_version', 'claim_until']) {
          if (!columns.contains(name)) {
            await transaction.execute(
                'ALTER TABLE emergency_status ADD COLUMN $name INTEGER NOT NULL DEFAULT 0');
          }
        }
      });

  EmergencyStatus _decode(List<Map<String, Object?>> rows) {
    if (rows.isEmpty) return const EmergencyStatus();
    try {
      return EmergencyStatus.fromJson(
          jsonDecode(rows.single['payload'] as String) as Map<String, dynamic>);
    } catch (error) {
      AppLogger.w(
          'Invalid cached emergency state; awaiting a fresh observation',
          tag: 'Emergency',
          error: error);
      return const EmergencyStatus();
    }
  }

  Future<EmergencyStatus> read() async {
    try {
      final database = await _open();
      final stored =
          _decode(await database.query('emergency_status', where: 'id = 1'));
      if (stored.seenAt >= _latest.seenAt) _latest = stored;
    } catch (error) {
      AppLogger.w('Cannot read emergency state; retaining the last observation',
          tag: 'Emergency', error: error);
    }
    return _latest;
  }

  Future<EmergencyStatus> observe(EmergencyObservation observation,
      {int? now}) async {
    EmergencyStatus result;
    try {
      final database = await _open();
      result = await database.transaction((transaction) async {
        final rows =
            await transaction.query('emergency_status', where: 'id = 1');
        final stored = _decode(rows);
        final previous = stored.seenAt >= _latest.seenAt ? stored : _latest;
        final next = previous.accept(
            observation, now ?? DateTime.now().millisecondsSinceEpoch);
        if (!identical(previous, next)) {
          final values = <String, Object?>{
            'payload': jsonEncode(next.toJson())
          };
          if (previous.active == null && next.active == false) {
            // Establishing an inactive baseline is not a cancellation event.
            values['notified_at'] = next.changedAt;
          }
          if (rows.isEmpty) {
            await transaction.insert('emergency_status', {'id': 1, ...values});
          } else {
            await transaction.update('emergency_status', values,
                where: 'id = 1');
          }
        }
        return next;
      });
    } catch (error) {
      AppLogger.w(
          'Cannot persist emergency state; retaining it for this session',
          tag: 'Emergency',
          error: error);
      result = _latest.accept(
          observation, now ?? DateTime.now().millisecondsSinceEpoch);
    }
    if (result.seenAt >= _latest.seenAt) _latest = result;
    _changes.add(result);
    return result;
  }

  /// A short lease deduplicates isolates without holding a DB transaction while
  /// awaiting OS APIs. Failed displays release it; a crashed isolate expires it.
  Future<bool> deliverNotification(
      EmergencyStatus status, Future<void> Function() show) async {
    final database = await _open();
    final claimedUntil = DateTime.now().millisecondsSinceEpoch + 30000;
    final claimed = await database.transaction((transaction) async {
      final rows = await transaction.query('emergency_status', where: 'id = 1');
      final current = _decode(rows);
      if (rows.isEmpty ||
          current.active != status.active ||
          current.changedAt != status.changedAt ||
          !current.isFreshAt(DateTime.now().millisecondsSinceEpoch) ||
          status.changedAt <= (rows.single['notified_at'] as int) ||
          (rows.single['claim_until'] as int) >
              DateTime.now().millisecondsSinceEpoch) {
        return false;
      }
      await transaction.update('emergency_status',
          {'claim_version': status.changedAt, 'claim_until': claimedUntil},
          where: 'id = 1');
      return true;
    });
    if (!claimed) return false;
    var displayed = false;
    try {
      final current = await read();
      if (current.changedAt != status.changedAt ||
          current.active != status.active) {
        return false;
      }
      await show().timeout(const Duration(seconds: 10));
      displayed = true;
      return true;
    } finally {
      await database.update(
          'emergency_status',
          {
            if (displayed) 'notified_at': status.changedAt,
            'claim_version': 0,
            'claim_until': 0,
          },
          where: 'id = 1 AND claim_version = ? AND claim_until = ?',
          whereArgs: [status.changedAt, claimedUntil]);
    }
  }
}
