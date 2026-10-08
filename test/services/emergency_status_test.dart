import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/emergency_status.dart';
import 'package:lumen/services/emergency_status_service.dart';
import 'package:lumen/services/emergency_notification_service.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/services/schedule_clock.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late EmergencyStatusService service;
  late int now;
  setUp(() async {
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    service = EmergencyStatusService.forTesting(() async => db);
    now = DateTime.now().millisecondsSinceEpoch;
  });
  tearDown(() async => db.close());

  test(
      'schema migration is shared by concurrent reads and cached per connection',
      () async {
    await db.execute('CREATE TABLE emergency_status ('
        'id INTEGER PRIMARY KEY, payload TEXT NOT NULL, '
        'notified_at INTEGER NOT NULL DEFAULT 0)');
    final tracked = _TrackingDatabase(db);
    final repository = EmergencyStatusService.forTesting(() async => tracked);
    await Future.wait(List.generate(8, (_) => repository.read()));
    await repository.read();
    expect(tracked.transactions, 1);
    final columns = (await db.rawQuery('PRAGMA table_info(emergency_status)'))
        .map((column) => column['name']);
    expect(columns, containsAll(['claim_version', 'claim_until']));
  });

  test('schema initialization retries after a failed migration', () async {
    final tracked = _TrackingDatabase(db)..failNextTransaction = true;
    final repository = EmergencyStatusService.forTesting(() async => tracked);
    await repository.read();
    expect(
        await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE name = 'emergency_status'"),
        isEmpty);
    await repository.read();
    await repository.read();
    expect(tracked.transactions, 2);
    expect(
        await db.rawQuery(
            "SELECT name FROM sqlite_master WHERE name = 'emergency_status'"),
        hasLength(1));
  });

  test('replacement database is migrated even after a previous successful read',
      () async {
    final replacement = await databaseFactoryFfi.openDatabase(
        inMemoryDatabasePath,
        options: OpenDatabaseOptions(singleInstance: false));
    addTearDown(replacement.close);
    final first = _TrackingDatabase(db);
    final second = _TrackingDatabase(replacement);
    Database current = first;
    final repository = EmergencyStatusService.forTesting(() async => current);
    await repository.read();
    current = second;
    await repository.read();
    await repository.read();
    expect(first.transactions, 1);
    expect(second.transactions, 1);
    expect(await replacement.rawQuery('PRAGMA table_info(emergency_status)'),
        hasLength(5));
  });

  test(
      'delivery lease does not block writes and the newer status replaces the displayed message',
      () async {
    final active =
        await service.observe(EmergencyObservation(true, now - 1000));
    final shown = <bool>[];
    final notifications = EmergencyNotificationService(
        statusService: service,
        enabled: () async => true,
        show: (value) async {
          shown.add(value);
          if (value) {
            // This would deadlock if delivery held the SQLite transaction open.
            await service
                .observe(EmergencyObservation(false, now, confirmed: true));
          }
        });
    await notifications
        .notifyStatus(active)
        .timeout(const Duration(seconds: 2));
    expect(shown, [true, false]);
    final state = await service.read();
    expect(
        await service.deliverNotification(state, () async => fail('Duplicate')),
        false);
  });

  test('inactive baseline stays silent and an abandoned delivery lease expires',
      () async {
    final inactive =
        await service.observe(EmergencyObservation(false, now - 1000));
    expect(
        await service.deliverNotification(
            inactive, () async => fail('Baseline')),
        false);
    final active = await service.observe(EmergencyObservation(true, now));
    await db.update(
        'emergency_status', {'claim_version': now, 'claim_until': now + 30000});
    expect(
        await service.deliverNotification(
            active, () async => fail('Lease in use')),
        false);
    await db.update('emergency_status', {'claim_until': now - 1});
    expect(await service.deliverNotification(active, () async {}), true);
  });

  test(
      'runtime fact and HTML are decoded from one capture, including platform encoding',
      () {
    final capture = {
      'fact': {
        'data': {'runtime': true}
      },
      'html': '<script>DisconSchedule.fact=null;</script>'
    };
    for (final value in [
      capture,
      jsonEncode(capture),
      jsonEncode(jsonEncode(capture))
    ]) {
      final decoded = ParserService.decodeRuntimeCapture(value);
      expect(jsonDecode(decoded.json), capture['fact']);
      expect(decoded.html, capture['html']);
    }
    expect(() => ParserService.decodeRuntimeCapture('null'),
        throwsFormatException);
  });

  test(
      'schedule fallback retains status-only observation without duplicating metadata',
      () {
    final earlier =
        ParserFetchResult({}, null, emergency: EmergencyObservation(true, now));
    const schedule =
        ParserFetchResult({}, '<script>DisconSchedule.fact={};</script>');
    final merged = schedule.retainEmergencyFrom(earlier);
    expect(merged.emergency!.observedAt, now);
    expect(merged.html, contains('DisconSchedule.fact={}'));
    expect(RegExp('lumen-emergency').allMatches(merged.html!).length, 1);
    expect(identical(merged.retainEmergencyFrom(earlier), merged), true);
    final cachedRetry =
        const ParserFetchResult({}, '<script>DisconSchedule.fact={};</script>')
            .retainEmergencyFrom(ParserFetchResult({}, null,
                emergency: EmergencyObservation(false, now - 1000)));
    final latest = cachedRetry.retainEmergencyFrom(earlier);
    expect(latest.emergency!.active, true);
    expect(latest.emergency!.observedAt, now);
    expect(RegExp('lumen-emergency').allMatches(latest.html!).length, 1);
    expect(latest.html, isNot(contains('"active":false')));
  });

  Map<String, dynamic> push(bool active, int observedAt) => {
        'group': 'EMERGENCY',
        'type': 'emergency_alert',
        'isEmergency': '$active',
        'observedAt': '$observedAt',
        'expiresAt':
            '${observedAt + EmergencyObservation.maxAge.inMilliseconds}',
      };

  test('push normalization preserves native and string boolean states', () {
    for (final active in [true, false]) {
      for (final value in [active, '$active']) {
        final parsed = EmergencyPush.parse(
            {...push(active, now), 'isEmergency': value}, now);
        expect(parsed, isNotNull);
        expect(parsed!.observation.active, active);
        expect(parsed.observation.confirmed, true);
      }
    }
    for (final invalid in [null, 0, 1, 'TRUE', 'False', ' true ', [], {}]) {
      expect(
          EmergencyPush.parse(
              {...push(true, now), 'isEmergency': invalid}, now),
          null);
    }
  });

  test(
      'unknown, active, cancellation confirmation, reactivation and stale order',
      () async {
    expect((await service.read()).active, null);
    var state =
        await service.observe(EmergencyObservation(true, now), now: now);
    expect(state.active, true);
    state = await service.observe(EmergencyObservation(false, now + 1000),
        now: now + 1000);
    expect(state.active, true);
    expect(state.cancellationSince, now + 1000);
    state = await service.observe(EmergencyObservation(false, now + 5000),
        now: now + 5000);
    expect(state.active, true);
    state = await service.observe(EmergencyObservation(false, now + 31000),
        now: now + 31000);
    expect(state.active, false);
    expect(state.changedAt, now + 31000);
    state = await service.observe(EmergencyObservation(true, now + 30000),
        now: now + 32000);
    expect(state.active, false,
        reason: 'Late earlier observation cannot revert cancellation');
    state = await service.observe(EmergencyObservation(true, now + 32000),
        now: now + 32000);
    expect(state.active, true);
    expect(state.cancellationSince, null);
    expect(state.isFreshAt(now + 32 * 60000), false);
    expect(state.active, true, reason: 'Staleness is not a cancellation');
  });

  test('confirmation expires; active refresh clears a cancellation candidate',
      () {
    final active =
        const EmergencyStatus().accept(EmergencyObservation(true, now), now);
    final candidate =
        active.accept(EmergencyObservation(false, now + 1000), now + 1000);
    final refreshed =
        candidate.accept(EmergencyObservation(true, now + 2000), now + 2000);
    expect(refreshed.cancellationSince, null);
    expect(refreshed.changedAt, now);
    final late = candidate.accept(
        EmergencyObservation(false, now + 21 * 60000), now + 21 * 60000);
    expect(late.active, true);
    expect(late.cancellationSince, now + 21 * 60000);
  });

  test(
      'worker confirmation can confirm a local cancellation candidate at the same capture time',
      () async {
    await service.observe(EmergencyObservation(true, now - 1000));
    final pending = await service.observe(EmergencyObservation(false, now));
    expect(pending.active, true);
    final confirmed = await service
        .observe(EmergencyObservation(false, now, confirmed: true));
    expect(confirmed.active, false);
    expect(confirmed.cancellationSince, null);
    expect(confirmed.changedAt, now);
  });

  test(
      'old/future observations do not replace persisted state; independent readers agree',
      () async {
    await service.observe(EmergencyObservation(true, now));
    for (final time in [now - 16 * 60000, now + 61000]) {
      await service.observe(EmergencyObservation(false, time));
    }
    final another = EmergencyStatusService.forTesting(() async => db);
    expect((await another.read()).active, true);
    await another
        .observe(EmergencyObservation(false, now + 1, confirmed: true));
    expect((await service.read()).active, false);
  });

  test('SQLite serializes competing observations and notification claims',
      () async {
    await Future.wait(List.generate(
        8,
        (i) => service.observe(
            EmergencyObservation(i.isEven, now + i, confirmed: true))));
    final state = await service.read();
    expect(state.seenAt, now + 7);
    expect(state.active, false);
    var shown = 0;
    final claims = await Future.wait(List.generate(
        8,
        (_) => service.deliverNotification(state, () async {
              shown++;
            })));
    expect(shown, 1);
    expect(claims.where((accepted) => accepted).length, 1);
  });

  test(
      'failed notification remains retryable and superseded status cannot display',
      () async {
    final active = await service.observe(EmergencyObservation(true, now));
    await expectLater(
        service.deliverNotification(active, () async {
          throw StateError('platform unavailable');
        }),
        throwsStateError);
    expect(await service.deliverNotification(active, () async {}), true);
    await service
        .observe(EmergencyObservation(false, now + 1, confirmed: true));
    expect(
        await service.deliverNotification(active, () async {
          fail('A superseded status must not display');
        }),
        false);
  });

  test('pushes honor settings, expiry, ordering, duplicates, and midnight',
      () async {
    var enabled = false;
    final shown = <bool>[];
    final notifications = EmergencyNotificationService(
        statusService: service,
        enabled: () async => enabled,
        show: (active) async => shown.add(active));
    expect(await notifications.handlePush(push(true, now - 100)), true);
    expect((await service.read()).active, true);
    expect(shown, isEmpty);
    enabled = true;
    await notifications.handlePush(push(true, now - 100));
    await notifications.handlePush(push(true, now - 100));
    expect(shown, [true]);
    await notifications.handlePush(push(false, now - 200));
    expect((await service.read()).active, true);
    await notifications.handlePush(push(false, now - 50));
    expect(shown, [true, false]);
    expect(await notifications.handlePush(push(true, now - 16 * 60000)), false);
    expect(
        await notifications.handlePush({'type': 'emergency_cancelled'}), false);
    final midnight = DateTime.utc(2026, 10, 7, 21).millisecondsSinceEpoch;
    expect(EmergencyPush.parse(push(true, midnight - 1000), midnight + 1000),
        isNotNull);
    expect(
        EmergencyPush.parse(
            {...push(true, now), 'expiresAt': '${now + 16 * 60000}'}, now),
        null);
  });

  test('fresh status remains available if persistence temporarily fails',
      () async {
    var failing = true;
    final repository = EmergencyStatusService.forTesting(() async {
      if (failing) throw StateError('database unavailable');
      return db;
    });
    await repository.observe(EmergencyObservation(true, now));
    expect((await repository.read()).active, true);
    failing = false;
    await repository.observe(EmergencyObservation(true, now + 1));
    expect(
        (await EmergencyStatusService.forTesting(() async => db).read()).active,
        true);
  });

  test('bad schedules and history failures cannot erase emergency observations',
      () async {
    final parser = ParserService();
    const notice =
        "<div id='modal-attention'>Введені екстрені відключення.</div>";
    final emergencyOnly = await parser.parseFetchedPage('null',
        originalHtml: notice,
        emergencyService: service,
        observedAt: now,
        persistSchedules: (_) async =>
            fail('Invalid schedule must not persist'));
    expect(emergencyOnly.schedules, isEmpty);
    expect(emergencyOnly.emergency!.active, true);
    expect(emergencyOnly.html, contains('lumen-emergency'));
    final today = ScheduleClock.day(ScheduleClock.now());
    final stamp = today.millisecondsSinceEpoch ~/ 1000;
    final fact = {
      'today': stamp,
      'update': '${today.day}.${today.month}.${today.year} 00:00',
      'data': {
        '$stamp': {
          for (final group in ParserService.allGroups)
            group: {for (var hour = 1; hour <= 24; hour++) '$hour': 'yes'}
        }
      }
    };
    final result = await parser.parseFetchedPage(jsonEncode(fact),
        originalHtml:
            '<html><body><script>DisconSchedule.fact=null;</script>$notice</body></html>',
        observedAt: now + 1,
        emergencyService: service,
        persistSchedules: (_) async =>
            throw StateError('Database unavailable'));
    expect(result.schedules.length, 12);
    expect(jsonDecode(parser.extractJsonFromHtml(result.html!)), fact);
    expect(result.html, isNot(contains('fact=null')));
    expect(result.html, isNot(contains('<body>')));
    expect((await service.read()).active, true);
    for (final reason in [
      'Older DTEK snapshot rejected',
      'Conflicting DTEK snapshot version'
    ]) {
      final rejected = await parser.parseFetchedPage(jsonEncode(fact),
          originalHtml: notice,
          observedAt: now + 2,
          emergencyService: service,
          persistSchedules: (_) async => throw FormatException(reason));
      expect(rejected.schedules, isEmpty);
      expect(rejected.html, contains('lumen-emergency'));
      expect(rejected.html, isNot(contains('DisconSchedule.fact')));
      expect(rejected.emergency!.active, true);
    }
  });
}

/// Counts actual SQLite transactions while retaining real migration/query behavior.
class _TrackingDatabase extends Fake implements Database {
  final Database delegate;
  var transactions = 0;
  var failNextTransaction = false;
  _TrackingDatabase(this.delegate);

  @override
  Future<T> transaction<T>(Future<T> Function(Transaction) action,
      {bool? exclusive}) {
    transactions++;
    if (failNextTransaction) {
      failNextTransaction = false;
      return Future.error(StateError('Database temporarily unavailable'));
    }
    return delegate.transaction(action, exclusive: exclusive);
  }

  @override
  Future<void> execute(String sql, [List<Object?>? arguments]) =>
      delegate.execute(sql, arguments);

  @override
  Future<List<Map<String, Object?>>> query(String table,
          {bool? distinct,
          List<String>? columns,
          String? where,
          List<Object?>? whereArgs,
          String? groupBy,
          String? having,
          String? orderBy,
          int? limit,
          int? offset}) =>
      delegate.query(table,
          distinct: distinct,
          columns: columns,
          where: where,
          whereArgs: whereArgs,
          groupBy: groupBy,
          having: having,
          orderBy: orderBy,
          limit: limit,
          offset: offset);
}
