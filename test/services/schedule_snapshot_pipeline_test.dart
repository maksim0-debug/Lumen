import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/schedule_snapshot.dart';
import 'package:lumen/services/fcm_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/services/schedule_change_notification_service.dart';
import 'package:lumen/services/schedule_change_notification_store.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/services/schedule_ingestion_service.dart';
import 'package:lumen/services/worker_schedule_service.dart';
import 'package:lumen/utils/app_formatters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late HistoryService history;
  late ScheduleIngestionService ingestion;
  late DateTime now;
  late List<String> shown;
  Map<String, Object?> fixture(int sequence, String code,
      {bool tomorrow = true, int alerts = 16}) {
    final source =
        ScheduleClock.from(now.subtract(Duration(minutes: 30 - sequence)));
    final update = '${source.day.toString().padLeft(2, '0')}.'
        '${source.month.toString().padLeft(2, '0')}.${source.year} '
        '${source.hour.toString().padLeft(2, '0')}:${source.minute.toString().padLeft(2, '0')}';
    return {
      'v': 1,
      'journalId': 'test-journal',
      'sequence': sequence,
      'todayDate': AppFormatters.formatDateKey(ScheduleClock.from(now)),
      'tomorrowDate': AppFormatters.formatDateKey(ScheduleClock.day(now, 1)),
      'sourceVersion': ScheduleClock.parseVersion(update),
      'sourceUpdatedAt': update,
      'alerts': alerts,
      'groups': {
        for (final group in ParserService.allGroups)
          group: [code, tomorrow ? code : null]
      }
    };
  }

  ScheduleSnapshot snapshot(int sequence, String code,
          {bool tomorrow = true}) =>
      ScheduleSnapshot.parse(fixture(sequence, code, tomorrow: tomorrow),
          now: now);
  Map<String, dynamic> push(ScheduleSnapshot value, {bool global = false}) => {
        'type': global ? 'schedule_snapshot' : 'schedule_updated',
        'schemaVersion': '2',
        'group': 'GPV2.1',
        'dayType': 'today',
        'targetDate': value.todayDate,
        'sourceVersion': '${value.sourceVersion}',
        'scheduleHash': value.schedules['GPV2.1']!.today.scheduleHash,
        'eventId': 'GPV2.1:${value.todayDate}:${value.sourceVersion}:'
            '${value.schedules['GPV2.1']!.today.scheduleHash}',
        'snapshot': jsonEncode(value.toJson()),
      };
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'notification_groups': ['GPV2.1']
    });
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
        'CREATE TABLE schedule_history (id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'group_key TEXT, target_date TEXT, schedule_code TEXT, dtek_updated_at TEXT)');
    await ScheduleChangeNotificationStore.createSchema(db);
    history = HistoryService.forTesting(db);
    now = ScheduleClock.now();
    shown = [];
    final changes = ScheduleChangeNotificationService(
        store: ScheduleChangeNotificationStore(database: () async => db),
        now: () => now,
        show: (claim) async => shown.add(claim.identity));
    ingestion = ScheduleIngestionService(
        history: history, changes: changes, now: () => now);
  });
  tearDown(() async => db.close());

  test('all 12 groups, half hours and unknown tomorrow round trip exactly', () {
    final value = snapshot(1, '012340123401234012340123', tomorrow: false);
    expect(value.schedules.length, 12);
    expect(value.schedules.values.every((v) => v.tomorrow.isEmpty), isTrue);
    expect(value.schedules['GPV6.2']!.today.totalOutageMinutes, 600);
    expect(
        ScheduleSnapshot.parse(jsonEncode(value.toJson()), now: now).toJson(),
        value.toJson());
  });
  test('random complete encodings retain every status for every group', () {
    final random = Random(17);
    for (var i = 0; i < 100; i++) {
      final code = List.generate(24, (_) => '${random.nextInt(5)}').join();
      final value = snapshot(1, code);
      expect(value.schedules.values.map((s) => s.today.scheduleHash).toSet(),
          {code});
    }
  });
  test('malformed or partial snapshot never reaches storage', () async {
    for (final mutate in <void Function(Map<String, dynamic>)>[
      (v) => v['v'] = 2,
      (v) => v['todayDate'] = '2026-02-30',
      (v) => v['sourceVersion'] = 1,
      (v) => v['sequence'] = -1,
      (v) => (v['groups'] as Map).remove('GPV6.2'),
      (v) => (v['groups'] as Map)['GPV6.2'] = ['0' * 23, '0' * 24],
      (v) => (v['groups'] as Map)['GPV6.2'] = ['9' * 24, '0' * 24],
      (v) => (v['groups'] as Map)['GPV6.2'] = ['0' * 24, null],
    ]) {
      final raw = Map<String, dynamic>.from(fixture(1, '0' * 24));
      mutate(raw);
      expect(
          () => ScheduleSnapshot.parse(raw, now: now), throwsFormatException);
    }
    expect(await db.query('schedule_history'), isEmpty);
  });
  for (final globalFirst in [false, true]) {
    test(
        'global/group delivery in order $globalFirst stores all groups and alerts once',
        () async {
      final value = snapshot(1, '1' * 24);
      var network = 0;
      var applications = 0;
      Future<bool> apply() => ingestion.applyPending((schedules) async {
            applications++;
            expect(schedules.length, 12);
            await ingestion.changes.observeSchedules(schedules);
          });
      for (final global in [globalFirst, !globalFirst, globalFirst]) {
        expect(
            await handleSnapshotPush(push(value, global: global),
                ingestion: ingestion, applyLocal: apply, recover: () async {
              network++;
            }),
            isTrue);
      }
      expect(network, 0);
      expect(applications, 1);
      expect(shown.length, 1);
      expect((await db.query('schedule_history')).length, 24);
      expect((await db.query('schedule_notification_state')).length, 2);
    });
  }
  test(
      'A to B to A preserves all history and both changes without stale rollback',
      () async {
    final a = snapshot(1, '0' * 24),
        b = snapshot(2, '1' * 24),
        again = snapshot(3, '0' * 24);
    await ingestion.ingest(a);
    await ingestion.applyPending(ingestion.changes.observeSchedules);
    for (final value in [b, again]) {
      await ingestion.ingest(value, fromPush: true);
      await ingestion.applyPending(ingestion.changes.observeSchedules);
    }
    expect(shown.toSet(), {
      for (final value in [b, again])
        for (final date in [value.todayDate, value.tomorrowDate])
          'GPV2.1:$date:${value.sourceVersion}:${value.schedules['GPV2.1']!.today.scheduleHash}',
    });
    await expectLater(ingestion.ingest(b), throwsFormatException);
    expect(
        (await history.getLastKnownSchedules())['GPV2.1']!.today.scheduleHash,
        '0' * 24);
    expect((await db.query('schedule_history')).length, 72);
  });
  test('same-version conflict rolls back all groups and pending work',
      () async {
    final first = snapshot(1, '0' * 24);
    await ingestion.ingest(first);
    final raw = first.toJson();
    (raw['groups'] as Map)['GPV6.2'] = ['1' * 24, '0' * 24];
    await expectLater(ingestion.ingest(ScheduleSnapshot.parse(raw, now: now)),
        throwsFormatException);
    expect((await db.query('schedule_history')).length, 24);
    expect((await db.query('schedule_local_work')).single['revision'], 1);
  });
  test('event/snapshot mismatch does not commit or alert', () async {
    final data = push(snapshot(1, '0' * 24));
    data['snapshot'] = jsonEncode(snapshot(2, '1' * 24).toJson());
    var recovery = 0;
    await handleSnapshotPush(data,
        ingestion: ingestion,
        applyLocal: () async => true,
        recover: () async {
          recovery++;
        });
    expect(recovery, 1);
    expect(await db.query('schedule_history'), isEmpty);
    expect(shown, isEmpty);
  });
  test(
      'widget failure keeps durable work retryable without any network request',
      () async {
    var queued = 0, recovered = 0;
    await handleSnapshotPush(push(snapshot(1, '1' * 24)),
        ingestion: ingestion,
        applyLocal: () =>
            ingestion.applyPending((_) async => throw StateError('widget')),
        enqueueLocal: () async {
          queued++;
        },
        recover: () async {
          recovered++;
        });
    expect(queued, 1);
    expect(recovered, 0);
    expect((await db.query('schedule_local_work')).single['processed'], 0);
    await ingestion.applyPending(ingestion.changes.observeSchedules);
    expect(shown.length, 1);
    expect((await db.query('schedule_local_work')).single['processed'], 1);
  });
  test(
      'new revision during local work is drained without acknowledging the wrong revision',
      () async {
    await ingestion.ingest(snapshot(1, '0' * 24));
    var applications = 0;
    await ingestion.applyPending((_) async {
      if (++applications == 1) await ingestion.ingest(snapshot(2, '1' * 24));
    });
    expect(applications, 2);
    expect((await db.query('schedule_local_work')).single['processed'], 2);
  });
  test('concurrent local workers do not perform duplicate effects', () async {
    await ingestion.ingest(snapshot(1, '0' * 24));
    final entered = Completer<void>(), release = Completer<void>();
    final first = ingestion.applyPending((_) async {
      entered.complete();
      await release.future;
    });
    await entered.future;
    expect(await ingestion.applyPending((_) async => fail('Concurrent effect')),
        isFalse);
    release.complete();
    expect(await first, isTrue);
  });
  test(
      'withdrawn tomorrow stays absent and republishing remains a new transition',
      () async {
    await ingestion.ingest(snapshot(1, '1' * 24));
    await ingestion.applyPending(ingestion.changes.observeSchedules);
    await ingestion.ingest(snapshot(2, '0' * 24, tomorrow: false));
    await ingestion.applyPending(ingestion.changes.observeSchedules);
    expect((await history.getLastKnownSchedules())['GPV2.1']!.tomorrow.isEmpty,
        isTrue);
    await expectLater(
        ingestion.ingest(snapshot(1, '1' * 24)), throwsFormatException);
    await ingestion.ingest(snapshot(3, '0' * 24));
    await ingestion.applyPending(ingestion.changes.observeSchedules);
    expect(shown.length, 2);
  });
  test('disabled alerts still ingest all groups and do not notify', () async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('notify_schedule_change', false);
    await prefs.setBool('notify_tomorrow_schedule', false);
    await ingestion.ingest(snapshot(1, '1' * 24), fromPush: true);
    await ingestion.applyPending(ingestion.changes.observeSchedules);
    expect((await db.query('schedule_history')).length, 24);
    expect(shown, isEmpty);
    expect(FcmService.topicsForPreferences(prefs),
        contains(FcmService.scheduleSyncTopic));
  });
  test(
      'API backfills missed A B A while keeping current A and no historical alerts',
      () async {
    final values = [
      snapshot(1, '0' * 24),
      snapshot(2, '1' * 24),
      snapshot(3, '0' * 24)
    ];
    final worker = WorkerScheduleService(
        ingestion: ingestion,
        request: (uri) async {
          if (uri.path.endsWith('snapshot')) {
            return {
              'snapshot': values.last.toJson(),
              'lastCheckedAt': now.millisecondsSinceEpoch
            };
          }
          return {
            'journalId': 'test-journal',
            'publications': values.map((v) => v.toJson()).toList(),
            'gap': false,
            'reset': false,
            'oldestSequence': 1,
            'latestSequence': 3,
            'nextAfter': 3,
            'hasMore': false
          };
        });
    expect((await worker.fetch())['GPV2.1']!.today.scheduleHash, '0' * 24);
    expect((await db.query('schedule_history')).length, 72);
    expect((await db.query('schedule_journal_cursor')).single['sequence'], 3);
    expect(shown, isEmpty);
    await ingestion.ingest(values.last);
    expect((await db.query('schedule_history')).length, 72);
    expect(
        (await history.getLastKnownSchedules())['GPV2.1']!.today.scheduleHash,
        '0' * 24);
  });
  test('journal missing a sequence does not advance the durable cursor',
      () async {
    final worker = WorkerScheduleService(
        ingestion: ingestion,
        request: (_) async => {
              'journalId': 'test-journal',
              'publications': [snapshot(2, '1' * 24).toJson()],
              'gap': false,
              'reset': false,
              'oldestSequence': 1,
              'latestSequence': 2,
              'nextAfter': 2,
              'hasMore': false
            });
    await expectLater(worker.syncHistory(), throwsFormatException);
    expect(await db.query('schedule_journal_cursor'), isEmpty);
    expect(await db.query('schedule_history'), isEmpty);
  });
  test('inconsistent journal metadata cannot consume missing publications',
      () async {
    for (final overrides in <Map<String, Object?>>[
      {'hasMore': false, 'latestSequence': 2},
      {'gap': true},
      {'oldestSequence': 0},
      {'journalId': 'invalid journal'},
      {'nextAfter': -1},
    ]) {
      final worker = WorkerScheduleService(
          ingestion: ingestion,
          request: (_) async => {
                'journalId': 'test-journal',
                'publications': [snapshot(1, '0' * 24).toJson()],
                'gap': false,
                'reset': false,
                'oldestSequence': 1,
                'latestSequence': 1,
                'nextAfter': 1,
                'hasMore': false,
                ...overrides,
              });
      await expectLater(worker.syncHistory(), throwsFormatException);
      expect(await db.query('schedule_history'), isEmpty);
      expect(await db.query('schedule_journal_cursor'), isEmpty);
    }
  });
  test('archive cursor compares journal and sequence before committing a page',
      () async {
    final a = snapshot(1, '0' * 24);
    final b = snapshot(2, '1' * 24);
    await ingestion.archivePage([a],
        endpoint: 'qa', journalId: a.journalId, previous: 0, next: 1);
    await ingestion.archivePage([b],
        endpoint: 'qa',
        journalId: b.journalId,
        expectedJournalId: a.journalId,
        previous: 0,
        next: 2);
    expect((await db.query('schedule_history')).length, 24);
    final replacement = Map<String, Object?>.from(b.toJson())
      ..['journalId'] = 'replacement-journal'
      ..['sequence'] = 1;
    final newer = ScheduleSnapshot.parse(replacement, now: now);
    await ingestion.archivePage([newer],
        endpoint: 'qa',
        journalId: newer.journalId,
        expectedJournalId: a.journalId,
        previous: 1,
        next: 1);
    await ingestion.archivePage([b],
        endpoint: 'qa',
        journalId: b.journalId,
        expectedJournalId: a.journalId,
        previous: 1,
        next: 2);
    expect((await db.query('schedule_journal_cursor')).single['journal_id'],
        'replacement-journal');
    expect((await db.query('schedule_history')).length, 48);
  });
  test('backfill source order cannot make an older publication the latest',
      () async {
    final values = [
      snapshot(3, '0' * 24),
      snapshot(1, '1' * 24),
      snapshot(2, '2' * 24)
    ];
    await ingestion.archivePage(values,
        endpoint: 'qa', journalId: 'test-journal', previous: 0, next: 3);
    expect(
        (await history.getLastKnownSchedules())['GPV6.2']!.today.scheduleHash,
        '0' * 24);
    final versions = await history.getVersionsForDate(now, 'GPV6.2');
    expect(versions.map((v) => v.hash), ['1' * 24, '2' * 24, '0' * 24]);
    expect(await db.query('schedule_notification_state'), isEmpty);
  });
  test('archive conflict rolls back the entire page and cursor', () async {
    final first = snapshot(1, '0' * 24);
    await ingestion.archivePage([first],
        endpoint: 'qa', journalId: first.journalId, previous: 0, next: 1);
    final conflict = Map<String, Object?>.from(snapshot(3, '2' * 24).toJson())
      ..['sourceVersion'] = first.sourceVersion
      ..['sourceUpdatedAt'] = first.sourceUpdatedAt;
    await expectLater(
        ingestion.archivePage(
            [snapshot(2, '1' * 24), ScheduleSnapshot.parse(conflict, now: now)],
            endpoint: 'qa',
            journalId: first.journalId,
            expectedJournalId: first.journalId,
            previous: 1,
            next: 3),
        throwsFormatException);
    expect((await db.query('schedule_history')).length, 24);
    expect((await db.query('schedule_journal_cursor')).single['sequence'], 1);
  });
  test('stale Worker checks fail before mutating the local graph', () async {
    final worker = WorkerScheduleService(
        ingestion: ingestion,
        request: (_) async => {
              'snapshot': snapshot(1, '0' * 24).toJson(),
              'lastCheckedAt': now
                  .subtract(const Duration(minutes: 16))
                  .millisecondsSinceEpoch
            });
    await expectLater(worker.fetch(), throwsFormatException);
    expect(await db.query('schedule_history'), isEmpty);
  });
  test('an expired local lease recovers after a terminated background engine',
      () async {
    await ingestion.ingest(snapshot(1, '0' * 24));
    await db.update('schedule_local_work', {
      'claim_until':
          now.subtract(const Duration(seconds: 1)).millisecondsSinceEpoch
    });
    var calls = 0;
    expect(
        await ingestion.applyPending((_) async {
          calls++;
        }),
        isTrue);
    expect(calls, 1);
    final row = (await db.query('schedule_local_work')).single;
    expect(row['processed'], row['revision']);
    expect(row['claim_until'], 0);
  });
}
