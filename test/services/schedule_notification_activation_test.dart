import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_change_event.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/schedule_change_notification_service.dart';
import 'package:lumen/services/schedule_change_notification_store.dart';
import 'package:lumen/services/schedule_clock.dart';

class _PausedClaimStore extends ScheduleChangeNotificationStore {
  final claimed = Completer<void>();
  final resume = Completer<void>();
  _PausedClaimStore(Database database) : super(database: () async => database);

  @override
  Future<ScheduleNotificationClaim?> claim(ScheduleChangeEvent event,
      {required int nowMs}) async {
    final result = await super.claim(event, nowMs: nowMs);
    if (result != null && !claimed.isCompleted) {
      claimed.complete();
      await resume.future;
    }
    return result;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late SharedPreferences prefs;
  late HistoryService history;
  late ScheduleChangeNotificationService service;
  late ScheduleChangeNotificationStore store;
  late List<ScheduleNotificationClaim> shown;
  late DateTime now;
  const a = '000000000000000111100000';
  const b = '000000000000001111100000';

  Map<String, FullSchedule> snapshot(String hash, String version,
          {String? tomorrow}) =>
      {
        for (final group in ['GPV1.2', 'GPV2.1'])
          group: FullSchedule(
              today: DailySchedule.fromEncodedString(hash),
              tomorrow: DailySchedule.fromEncodedString(tomorrow ?? '9' * 24),
              lastUpdatedSource: version),
      };
  Future<void> persist(Map<String, FullSchedule> schedules) =>
      history.persistSnapshot(
          schedules: schedules,
          todayDate: ScheduleClock.day(now).toIso8601String().substring(0, 10),
          tomorrowDate:
              ScheduleClock.day(now, 1).toIso8601String().substring(0, 10),
          dtekUpdatedAt: schedules.values.first.lastUpdatedSource);

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'selected_group': 'GPV1.2',
      'notification_groups': ['GPV1.2'],
    });
    prefs = await SharedPreferences.getInstance();
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE schedule_history ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, group_key TEXT, '
        'target_date TEXT, schedule_code TEXT, dtek_updated_at TEXT)');
    await ScheduleChangeNotificationStore.createSchema(db);
    history = HistoryService.forTesting(db);
    now = ScheduleClock.calendar(2026, 10, 9, 17, 30);
    shown = [];
    store = ScheduleChangeNotificationStore(database: () async => db);
    service = ScheduleChangeNotificationService(
        store: store,
        preferences: () async => prefs,
        now: () => now,
        show: (claim) async => shown.add(claim));
  });

  Future<void> initializeToday() async {
    now = ScheduleClock.calendar(2026, 10, 10, 7, 40);
    final initial = snapshot(a, '10.10.2026 07:37');
    await persist(initial);
    await service.observeSchedules(initial);
  }

  ScheduleChangeEvent change(String hash, String version,
          {String dayType = 'today'}) =>
      ScheduleChangeEvent.fromSchedule('GPV1.2',
          snapshot(hash, version, tomorrow: hash)['GPV1.2']!, dayType, now);
  Map<String, dynamic> push(ScheduleChangeEvent event) => {
        'type': 'schedule_updated',
        'schemaVersion': '2',
        'group': event.group,
        'targetDate': event.targetDate,
        'sourceVersion': '${event.sourceVersion}',
        'scheduleHash': event.hash,
        'dayType': event.dayType,
        'eventId': event.id,
      };

  test('off/on between source observations establishes a fresh baseline',
      () async {
    await initializeToday();
    await service.updatePreferences(notifyToday: false);
    now = ScheduleClock.calendar(2026, 10, 10, 9, 44);
    final current = snapshot(b, '10.10.2026 09:38');
    await persist(current);
    await service.updatePreferences(notifyToday: true);
    await service.observeSchedules(current);
    await service.handlePush(push(change(b, '10.10.2026 09:38')));
    expect(shown, isEmpty);
    final next = snapshot(a, '10.10.2026 09:45');
    await persist(next);
    await service.observeSchedules(next);
    expect(shown, hasLength(1));
    expect(shown.single.previousHash, b);
  });

  test('removing and adding a group without a poll suppresses stale pending',
      () async {
    await initializeToday();
    final pending = snapshot(b, '10.10.2026 07:38');
    await persist(pending);
    await service.observeSchedules(pending, deliver: false);
    await service.updatePreferences(groups: ['GPV2.1']);
    await service.updatePreferences(groups: ['GPV2.1', 'GPV1.2']);
    await service.observeSchedules(pending);
    expect(shown, isEmpty);
    expect(
        (await db.query('schedule_notification_state',
                where: 'group_key=? AND target_date=?',
                whereArgs: ['GPV1.2', '2026-10-10']))
            .single['pending_since'],
        isNull);
  });

  test(
      'adding a group does not consume another active group pending transition',
      () async {
    await initializeToday();
    final pending = snapshot(b, '10.10.2026 07:38');
    await persist(pending);
    await service.observeSchedules(pending, deliver: false);
    await service.updatePreferences(groups: ['GPV1.2', 'GPV2.1']);
    await service.observeSchedules(pending);
    expect(shown.map((c) => c.event.group), ['GPV1.2']);
    expect(shown.single.previousHash, a);
  });

  test('today toggle leaves a pending tomorrow publication retryable',
      () async {
    await initializeToday();
    final pending = snapshot(b, '10.10.2026 07:38', tomorrow: b);
    await persist(pending);
    await service.observeSchedules(pending, deliver: false);
    await service.updatePreferences(notifyToday: false);
    await service.updatePreferences(notifyToday: true);
    await service.observeSchedules(pending);
    expect(shown.map((c) => c.event.dayType), ['tomorrow']);
    expect(shown.single.event.hash, b);
  });

  test(
      'without a verified snapshot first poll baselines but a later change alerts',
      () async {
    now = ScheduleClock.calendar(2026, 10, 10, 7, 40);
    await service.observeSchedules(snapshot(a, '10.10.2026 07:37'));
    await service.updatePreferences(groups: ['GPV2.1']);
    await service.updatePreferences(groups: ['GPV1.2']);
    await service.observeSchedules(snapshot(b, '10.10.2026 07:38'));
    expect(shown, isEmpty);
    await service.observeSchedules(snapshot(a, '10.10.2026 07:39'));
    expect(shown.single.previousHash, b);
  });

  test('first new push after activation without a snapshot is still delivered',
      () async {
    now = ScheduleClock.calendar(2026, 10, 10, 7, 40);
    await service.observeSchedules(snapshot(a, '10.10.2026 07:37'));
    await service.updatePreferences(notifyToday: false);
    await service.updatePreferences(notifyToday: true);
    await service.handlePush(push(change(b, '10.10.2026 07:38')));
    await service.observeSchedules(snapshot(b, '10.10.2026 07:38'));
    expect(shown, hasLength(1));
    expect(shown.single.event.hash, b);
  });

  test(
      'selected group switch and empty group fallback initialize the effective group',
      () async {
    await initializeToday();
    await service.updatePreferences(selectedGroup: 'GPV2.1');
    expect(prefs.getString('selected_group'), 'GPV2.1');
    expect(prefs.getStringList('notification_groups'), ['GPV2.1']);
    await service.observeSchedules(snapshot(a, '10.10.2026 07:37'));
    await service.updatePreferences(groups: []);
    await service.observeSchedules(snapshot(b, '10.10.2026 07:38'));
    expect(shown.map((c) => c.event.group), ['GPV2.1']);
    await service.updatePreferences(groups: ['GPV1.2', 'GPV2.1']);
    await service.updatePreferences(selectedGroup: 'GPV3.1');
    expect(prefs.getStringList('notification_groups'), ['GPV1.2', 'GPV2.1']);
  });

  test(
      'late completion from the previous activation cannot acknowledge a new claim',
      () async {
    await initializeToday();
    final pending = snapshot(b, '10.10.2026 07:38');
    await persist(pending);
    await service.observeSchedules(pending, deliver: false);
    final old = (await store.claim(change(b, '10.10.2026 07:38'),
        nowMs: now.millisecondsSinceEpoch))!;
    expect(await store.isCurrentClaim(old), isTrue);
    await service.updatePreferences(notifyToday: false);
    await service.updatePreferences(notifyToday: true);
    expect(await store.isCurrentClaim(old), isFalse);
    final next = snapshot(a, '10.10.2026 07:39');
    await persist(next);
    await service.observeSchedules(next, deliver: false);
    final current = (await store.claim(change(a, '10.10.2026 07:39'),
        nowMs: now.millisecondsSinceEpoch))!;
    expect(current.generation, isNot(old.generation));
    await store.finish(old, success: true);
    expect(await store.isCurrentClaim(current), isTrue);
    await store.finish(current, success: false);
    await service.observeSchedules(next);
    expect(shown.single.event.hash, a);
    expect(shown.single.previousHash, b);
  });

  test(
      'rapid preference updates retain each transition and snapshot the group list',
      () async {
    await initializeToday();
    final groups = ['GPV2.1'];
    final off = service.updatePreferences(groups: groups);
    groups.add('GPV1.2');
    final on = service.updatePreferences(groups: groups);
    await Future.wait([off, on]);
    expect(prefs.getStringList('notification_groups'), ['GPV2.1', 'GPV1.2']);
    final policy = (await db.query('schedule_notification_policy',
            where: 'group_key=? AND day_type=?',
            whereArgs: ['GPV1.2', 'today']))
        .single;
    expect(policy['generation'], 3);
    expect(policy['enabled'], 1);
  });

  test('malformed cache falls back to first observation without crashing',
      () async {
    await initializeToday();
    await service.updatePreferences(notifyToday: false);
    await db.update('dtek_snapshot_state', {'fingerprint': '{invalid'});
    await service.updatePreferences(notifyToday: true);
    await service.observeSchedules(snapshot(b, '10.10.2026 07:38'));
    expect(shown, isEmpty);
    await service.observeSchedules(snapshot(a, '10.10.2026 07:39'));
    expect(shown, hasLength(1));
  });

  test('settings transaction failure recovers before any stale delivery',
      () async {
    await initializeToday();
    await db.execute('CREATE TRIGGER fail_notification_policy '
        'BEFORE INSERT ON schedule_notification_policy '
        "WHEN NEW.group_key='GPV1.2' AND NEW.enabled=0 "
        "BEGIN SELECT RAISE(ABORT, 'injected policy write failure'); END");
    await expectLater(service.updatePreferences(notifyToday: false),
        throwsA(isA<DatabaseException>()));
    final row = (await db.query('schedule_notification_policy',
            where: 'group_key=? AND day_type=?',
            whereArgs: ['GPV1.2', 'today']))
        .single;
    expect(row['enabled'], 1);
    expect(prefs.getBool('notify_schedule_change'), isFalse);
    await db.execute('DROP TRIGGER fail_notification_policy');
    final current = snapshot(b, '10.10.2026 07:38');
    await persist(current);
    await service.observeSchedules(current);
    expect(shown, isEmpty);
    await service.updatePreferences(notifyToday: true);
    await service.observeSchedules(current);
    expect(shown, isEmpty);
    await service.observeSchedules(snapshot(a, '10.10.2026 07:39'));
    expect(shown.single.previousHash, b);
  });

  test(
      'activation without cache survives midnight and baselines the same target date',
      () async {
    await service.observeSchedules(snapshot('0' * 24, '09.10.2026 17:22'));
    await service.updatePreferences(notifyTomorrow: false);
    await service.updatePreferences(notifyTomorrow: true);
    now = ScheduleClock.calendar(2026, 10, 10, 7, 40);
    await service.observeSchedules(snapshot(a, '10.10.2026 07:37'));
    expect(shown, isEmpty);
    await service.observeSchedules(snapshot(b, '10.10.2026 07:38'));
    expect(shown, hasLength(1));
    expect(shown.single.previousHash, a);
  });

  test(
      'two connections cancel a claimed old activation before display and survive reopening',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('lumen-activation-');
    final path = '${directory.path}/state.db';
    final first = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final second = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await ScheduleChangeNotificationStore.createSchema(first);
      await first.execute('CREATE TABLE schedule_history ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, group_key TEXT, '
          'target_date TEXT, schedule_code TEXT, dtek_updated_at TEXT)');
      final diskHistory = HistoryService.forTesting(first);
      Future<void> save(Map<String, FullSchedule> schedules) =>
          diskHistory.persistSnapshot(
              schedules: schedules,
              todayDate: '2026-10-10',
              tomorrowDate: '2026-10-11',
              dtekUpdatedAt: schedules.values.first.lastUpdatedSource);
      now = ScheduleClock.calendar(2026, 10, 10, 7, 40);
      final paused = _PausedClaimStore(first);
      ScheduleChangeNotificationService make(
              ScheduleChangeNotificationStore s) =>
          ScheduleChangeNotificationService(
              store: s,
              preferences: () async => prefs,
              now: () => now,
              show: (claim) async => shown.add(claim));
      final foreground = make(paused);
      final background =
          make(ScheduleChangeNotificationStore(database: () async => second));
      final initial = snapshot(a, '10.10.2026 07:37');
      await save(initial);
      await foreground.observeSchedules(initial);
      final pending = snapshot(b, '10.10.2026 07:38');
      await save(pending);
      final delivery = foreground.observeSchedules(pending);
      await paused.claimed.future.timeout(const Duration(seconds: 5));
      await background.updatePreferences(notifyToday: false);
      await background.updatePreferences(notifyToday: true);
      paused.resume.complete();
      await delivery;
      expect(shown, isEmpty);
      expect(
          (await first.query('schedule_notification_state',
                  where: 'group_key=? AND target_date=?',
                  whereArgs: ['GPV1.2', '2026-10-10']))
              .single['handled_hash'],
          b);
      await first.close();
      await second.close();
      final reopened = await databaseFactoryFfi.openDatabase(path);
      try {
        final restarted = make(
            ScheduleChangeNotificationStore(database: () async => reopened));
        await restarted.observeSchedules(pending);
        expect(shown, isEmpty);
        await restarted.observeSchedules(snapshot(a, '10.10.2026 07:39'));
        expect(shown.single.previousHash, b);
        final persisted =
            jsonEncode(await reopened.query('schedule_notification_policy'));
        expect(persisted, contains('"generation":3'));
      } finally {
        await reopened.close();
      }
    } finally {
      if (first.isOpen) await first.close();
      if (second.isOpen) await second.close();
      await directory.delete(recursive: true);
    }
  });
  tearDown(() async => db.close());

  test(
      'reactivating an inactive placeholder never announces an old publication',
      () async {
    final initial = snapshot('0' * 24, '09.10.2026 17:22');
    await persist(initial);
    await service.observeSchedules(initial, deliver: false);
    await prefs.setStringList('notification_groups', ['GPV2.1']);
    now = ScheduleClock.calendar(2026, 10, 9, 19, 55);
    final tomorrow = snapshot('0' * 24, '09.10.2026 19:49', tomorrow: a);
    await persist(tomorrow);
    await service.observeSchedules(tomorrow, deliver: false);
    now = ScheduleClock.calendar(2026, 10, 10, 9, 44);
    final current = snapshot(a, '10.10.2026 09:38');
    await persist(current);
    await service.observeSchedules(current);
    await prefs.setStringList('notification_groups', ['GPV2.1', 'GPV1.2']);
    await service.observeSchedules(current, deliver: false);
    now = ScheduleClock.calendar(2026, 10, 10, 10, 1);
    await service.observeSchedules(current);
    expect(shown, isEmpty);
    final row = (await db.query('schedule_notification_state',
            where: 'group_key=? AND target_date=?',
            whereArgs: ['GPV1.2', '2026-10-10']))
        .single;
    expect(row['handled_hash'], a);
    expect(row['pending_since'], isNull);
    final next = snapshot(b, '10.10.2026 10:05');
    await persist(next);
    await service.observeSchedules(next);
    expect(shown.map((c) => c.event.group), ['GPV2.1', 'GPV1.2']);
    expect(shown.every((c) => c.previousHash == a), isTrue);
  });

  test('reactivating a real stale schedule uses current content as baseline',
      () async {
    now = ScheduleClock.calendar(2026, 10, 10, 7, 40);
    final initial = snapshot(a, '10.10.2026 07:37');
    await persist(initial);
    await service.observeSchedules(initial);
    await prefs.setStringList('notification_groups', ['GPV2.1']);
    final current = snapshot(b, '10.10.2026 09:38');
    now = ScheduleClock.calendar(2026, 10, 10, 9, 44);
    await persist(current);
    await service.observeSchedules(current);
    await prefs.setStringList('notification_groups', ['GPV2.1', 'GPV1.2']);
    await service.observeSchedules(current);
    expect(shown, isEmpty);
  });
}
