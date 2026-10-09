import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/schedule_change_event.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/fcm_service.dart';
import 'package:lumen/services/android_fetch_diagnostics.dart';
import 'package:lumen/services/schedule_change_notification_service.dart';
import 'package:lumen/services/schedule_change_notification_store.dart';
import 'package:lumen/services/schedule_clock.dart';

class _CountingStore extends ScheduleChangeNotificationStore {
  int claims = 0;
  _CountingStore(Database database) : super(database: () async => database);
  @override
  Future<ScheduleNotificationClaim?> claim(ScheduleChangeEvent event,
      {required int nowMs}) {
    claims++;
    return super.claim(event, nowMs: nowMs);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late SharedPreferences prefs;
  late ScheduleChangeNotificationStore store;
  late ScheduleChangeNotificationService service;
  late List<ScheduleNotificationClaim> shown;
  late DateTime now;
  const a = '111111000000000000000000';
  const b = '111111110000000000000000';
  const c = '011111000000000000000000';

  ScheduleChangeEvent event(
    String hash,
    int hour, {
    String group = 'GPV2.1',
    String date = '2026-10-09',
    String dayType = 'today',
  }) =>
      ScheduleChangeEvent(
          group: group,
          targetDate: date,
          sourceVersion:
              ScheduleClock.calendar(2026, 10, 9, hour).millisecondsSinceEpoch,
          hash: hash,
          dayType: dayType);
  Map<String, dynamic> push(ScheduleChangeEvent e) => {
        'type': 'schedule_updated',
        'schemaVersion': '2',
        'group': e.group,
        'targetDate': e.targetDate,
        'sourceVersion': '${e.sourceVersion}',
        'scheduleHash': e.hash,
        'dayType': e.dayType,
        'eventId': e.id,
        'title': e.title(),
        'body': 'Server change',
      };
  Map<String, FullSchedule> snapshot(String hash, int hour,
          {String? tomorrow, int minute = 0}) =>
      {
        'GPV2.1': FullSchedule(
            today: DailySchedule.fromEncodedString(hash),
            tomorrow: DailySchedule.fromEncodedString(tomorrow ?? '9' * 24),
            lastUpdatedSource:
                '09.10.2026 ${hour.toString().padLeft(2, '0')}:${minute.toString().padLeft(2, '0')}'),
      };
  ScheduleChangeNotificationService makeService(
          ScheduleChangeNotificationStore s,
          {Future<void> Function(ScheduleNotificationClaim)? show}) =>
      ScheduleChangeNotificationService(
          store: s,
          preferences: () async => prefs,
          now: () => now,
          show: show ??
              (claim) async {
                shown.add(claim);
              });

  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'selected_group': 'GPV2.1',
      'notify_schedule_change': true,
      'notify_tomorrow_schedule': true,
      'fcm_initialized': true,
      'fcm_subscribed_topics': ['group_gpv2_1_v2', 'group_gpv2_1_v2_tomorrow'],
    });
    prefs = await SharedPreferences.getInstance();
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await ScheduleChangeNotificationStore.createSchema(db);
    store = ScheduleChangeNotificationStore(database: () async => db);
    shown = [];
    now = ScheduleClock.calendar(2026, 10, 9, 12);
    service = makeService(store);
  });
  tearDown(() async => db.close());

  test(
      'Diagnostics distinguish unchanged data from completed notification delivery',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    final records = <Map<String, dynamic>>[];
    final diagnostics = AndroidFetchDiagnostics(
        enabled: true,
        modeLoader: () async => AndroidDiagnosticMode.verbose,
        snapshot: (_) async => {},
        sink: (message, _) async => records.add(jsonDecode(message)));
    await diagnostics.run(
        source: 'periodic_poll',
        execution: 'workmanager',
        action: () async {
          await service.observeSchedules(snapshot(a, 0));
          await service.observeSchedules(snapshot(b, 1));
        });
    expect(shown, hasLength(1));
    expect(
        records.where((r) => r['stage'] == 'notification_skipped'), isNotEmpty);
    expect(
        records.singleWhere(
            (r) => r['stage'] == 'notification_show_returned')['group'],
        'GPV2.1');
    expect(records.map((r) => r['operationId']).toSet(), hasLength(1));
    expect(jsonEncode(records), isNot(contains(b)));
  });

  test('background push queues recovery even when platform delivery fails',
      () async {
    var refreshes = 0;
    final failing = makeService(store,
        show: (_) async => throw StateError('Platform display failed'));
    await handleFcmBackgroundMessage(RemoteMessage(data: push(event(b, 1))),
        scheduleChanges: failing,
        initializeFirebase: () async {}, refreshSchedules: () async {
      refreshes++;
    });
    expect(refreshes, 1);
    expect(
        (await db.query('schedule_notification_state')).single['pending_since'],
        isNotNull);
    await service.observeSchedules(snapshot(b, 1));
    expect(shown, hasLength(1));
  });

  test('conflicting poll cannot block tomorrow or another group', () async {
    await prefs.setStringList('notification_groups', ['GPV2.1', 'GPV1.1']);
    await service.observeSchedules({
      ...snapshot(a, 0, tomorrow: a),
      'GPV1.1': snapshot(a, 0)['GPV2.1']!,
    });
    await service.acknowledge(event(a, 1));
    await service.observeSchedules({
      ...snapshot(b, 1, tomorrow: c),
      'GPV1.1': snapshot(c, 1)['GPV2.1']!,
    });
    expect(shown.map((claim) => '${claim.event.group}/${claim.event.dayType}'),
        ['GPV2.1/tomorrow', 'GPV1.1/today']);
    final row = (await db.query('schedule_notification_state',
            where: 'group_key = ? AND target_date = ?',
            whereArgs: ['GPV2.1', '2026-10-09']))
        .single;
    expect(row['schedule_hash'], a);
    await service.observeSchedules(snapshot(b, 2, tomorrow: c));
    expect(shown.last.event.hash, b);
  });

  test('unchanged settled observations do not write SQLite rows', () async {
    await service.observeSchedules(snapshot(a, 0));
    final before =
        (await db.rawQuery('SELECT total_changes() AS count')).single['count'];
    for (var i = 0; i < 5; i++) {
      await service.observeSchedules(snapshot(a, 0));
    }
    final after =
        (await db.rawQuery('SELECT total_changes() AS count')).single['count'];
    expect(after, before);
    expect(shown, isEmpty);
  });

  test(
      '12 idle groups need no delivery claims and only one preference load per poll',
      () async {
    final groups = [
      for (var group = 1; group <= 6; group++)
        for (final part in [1, 2]) 'GPV$group.$part'
    ];
    await prefs.setStringList('notification_groups', groups);
    final counted = _CountingStore(db);
    var preferenceLoads = 0;
    service = ScheduleChangeNotificationService(
        store: counted,
        now: () => now,
        preferences: () async {
          preferenceLoads++;
          return prefs;
        },
        show: (claim) async {
          shown.add(claim);
        });
    final schedules = {
      for (final group in groups) group: snapshot(a, 0, tomorrow: c)['GPV2.1']!
    };
    await service.observeSchedules(schedules);
    final before =
        (await db.rawQuery('SELECT total_changes() AS count')).single['count'];
    preferenceLoads = 0;
    for (var i = 0; i < 5; i++) {
      await service.observeSchedules(schedules);
    }
    expect(preferenceLoads, 5);
    expect(counted.claims, 0);
    expect(
        (await db.rawQuery('SELECT total_changes() AS count')).single['count'],
        before);
    expect(shown, isEmpty);
  });

  test(
      'failed group remains pending while independent group and tomorrow deliver',
      () async {
    await prefs.setStringList('notification_groups', ['GPV2.1', 'GPV1.1']);
    await service.observeSchedules({
      ...snapshot(a, 0),
      'GPV1.1': snapshot(a, 0)['GPV2.1']!,
    });
    final failing = makeService(store, show: (claim) async {
      if (claim.event.group == 'GPV2.1' && claim.event.dayType == 'today') {
        throw StateError('Display unavailable for one notification');
      }
      shown.add(claim);
    });
    final updated = {
      ...snapshot(b, 1, tomorrow: c),
      'GPV1.1': snapshot(b, 1)['GPV2.1']!,
    };
    await expectLater(failing.observeSchedules(updated), throwsStateError);
    expect(shown.map((claim) => '${claim.event.group}/${claim.event.dayType}'),
        ['GPV2.1/tomorrow', 'GPV1.1/today']);
    await service.observeSchedules(updated);
    expect(shown, hasLength(3));
    expect(shown.last.event.group, 'GPV2.1');
    expect(shown.last.event.dayType, 'today');
  });

  test('background push still queues recovery when database cannot be opened',
      () async {
    var refreshes = 0;
    final unavailable = makeService(ScheduleChangeNotificationStore(
        database: () async => throw StateError('Database unavailable')));
    await handleFcmBackgroundMessage(RemoteMessage(data: push(event(b, 1))),
        scheduleChanges: unavailable,
        initializeFirebase: () async {}, refreshSchedules: () async {
      refreshes++;
    });
    expect(refreshes, 1);
    await service.handlePush(push(event(b, 1)));
    expect(shown, hasLength(1));
  });

  test('background timeout releases the lease and still queues recovery',
      () async {
    var refreshes = 0;
    final unavailable = makeService(store,
        show: (_) async =>
            throw TimeoutException('Platform notification timed out'));
    await handleFcmBackgroundMessage(RemoteMessage(data: push(event(b, 1))),
        scheduleChanges: unavailable,
        initializeFirebase: () async {}, refreshSchedules: () async {
      refreshes++;
    });
    expect(refreshes, 1);
    final row = (await db.query('schedule_notification_state')).single;
    expect(row['pending_since'], isNotNull);
    expect(row['claim_key'], isNull);
    await service.handlePush(push(event(b, 1)));
    expect(shown, hasLength(1));
  });

  test('malformed background push does not queue a refresh or create state',
      () async {
    var refreshes = 0;
    await handleFcmBackgroundMessage(
        RemoteMessage(data: {
          ...push(event(b, 1)),
          'scheduleHash': 'invalid',
        }),
        scheduleChanges: service,
        initializeFirebase: () async {}, refreshSchedules: () async {
      refreshes++;
    });
    expect(refreshes, 0);
    expect(await db.query('schedule_notification_state'), isEmpty);
  });

  test(
      '15:01 publication detected at 15:15 alerts during that same poll with FCM configured',
      () async {
    now = ScheduleClock.calendar(2026, 10, 9, 15);
    await service.observeSchedules(snapshot(a, 14));
    expect(shown, isEmpty);
    now = ScheduleClock.calendar(2026, 10, 9, 15, 15);
    await service.observeSchedules(snapshot(b, 15, minute: 1));
    expect(shown, hasLength(1));
    expect(shown.single.event.sourceVersion,
        ScheduleClock.calendar(2026, 10, 9, 15, 1).millisecondsSinceEpoch);
    expect(shown.single.previousHash, a);
    expect(
        (await db.query('schedule_notification_state',
                where: "target_date = '2026-10-09'"))
            .single['pending_since'],
        isNull);
  });

  test(
      'real incident: local 6 to 5 fallback, then late PC background FCM, shows once',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(c, 1));
    expect(shown, hasLength(1));
    await service.observeSchedules(snapshot(c, 1));
    expect(shown, hasLength(1));
    expect(shown.single.event.body(shown.single.previousHash),
        'Світла стало БІЛЬШЕ на 1 год. 🎉');
    var refreshes = 0;
    await handleFcmBackgroundMessage(RemoteMessage(data: push(event(c, 1))),
        scheduleChanges: service,
        initializeFirebase: () async {}, refreshSchedules: () async {
      refreshes++;
    });
    expect(shown, hasLength(1));
    expect(refreshes, 1);
  });

  test('FCM first cancels fallback and repeated foreground/background delivery',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await FcmService().handleForegroundMessage(
        RemoteMessage(data: push(event(b, 1))),
        scheduleChanges: service);
    await service.observeSchedules(snapshot(b, 1));
    await handleFcmBackgroundMessage(RemoteMessage(data: push(event(b, 1))),
        scheduleChanges: service,
        initializeFirebase: () async {},
        refreshSchedules: () async {});
    now = now.add(const Duration(minutes: 30));
    await service.observeSchedules(snapshot(b, 1));
    expect(shown, hasLength(1));
  });

  test('6 to 8 to 6 emits two changes and retains distinct event identities',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.handlePush(push(event(b, 1)));
    await service.handlePush(push(event(a, 2)));
    await service.handlePush(push(event(a, 2)));
    expect(shown.map((x) => x.event.hash), [b, a]);
    expect(shown.map((x) => x.identity).toSet(), hasLength(2));
    expect(shown[0].event.body(shown[0].previousHash),
        'Світла стало МЕНШЕ на 2 год. 😔');
    expect(shown[1].event.body(shown[1].previousHash),
        'Світла стало БІЛЬШЕ на 2 год. 🎉');
  });

  test('local polling 6 to 8 to 6 delivers each transition immediately',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(b, 1));
    expect(shown.map((claim) => claim.event.hash), [b]);
    await service.observeSchedules(snapshot(a, 2));
    await service.observeSchedules(snapshot(a, 2));
    expect(shown.map((claim) => claim.event.hash), [b, a]);
    expect(shown.last.previousHash, b);
    expect(shown.map((claim) => claim.identity).toSet(), hasLength(2));
  });

  test(
      'fresh persisted pending state delivers on the first poll after service restart',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(b, 1), deliver: false);
    final before = (await db.query('schedule_notification_state',
            where: "target_date = '2026-10-09'"))
        .single;
    expect(before['pending_since'], now.millisecondsSinceEpoch);
    expect(shown, isEmpty);
    service =
        makeService(ScheduleChangeNotificationStore(database: () async => db));
    await service.observeSchedules(snapshot(b, 1));
    expect(shown.single.identity, before['event_key']);
    expect(shown.single.previousHash, a);
    await service.handlePush(push(event(b, 1)));
    expect(shown, hasLength(1));
  });

  test(
      'failed immediate polling display releases its claim and retries without delay',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    final failing = makeService(store,
        show: (_) async => throw StateError('platform unavailable'));
    await expectLater(
        failing.observeSchedules(snapshot(b, 1)), throwsStateError);
    final row = (await db.query('schedule_notification_state',
            where: "target_date = '2026-10-09'"))
        .single;
    expect(row['handled_hash'], a);
    expect(row['pending_since'], now.millisecondsSinceEpoch);
    expect(row['claim_key'], isNull);
    await service.observeSchedules(snapshot(b, 1));
    await service.handlePush(push(event(b, 1)));
    expect(shown, hasLength(1));
    expect(shown.single.previousHash, a);
  });

  test('local equal-duration shift alerts immediately with FCM configured',
      () async {
    await service.observeSchedules(snapshot('1${'0' * 23}', 0));
    await service.observeSchedules(snapshot('01${'0' * 22}', 1));
    expect(shown, hasLength(1));
    expect(shown.single.event.body(shown.single.previousHash),
        'Змінився час відключень на сьогодні ⚡');
  });

  test('every one-hour shift is a change even with equal total outage duration',
      () async {
    for (var hour = 0; hour < 23; hour++) {
      final left = '${'0' * hour}1${'0' * (23 - hour)}';
      final right = '${'0' * (hour + 1)}1${'0' * (22 - hour)}';
      final e1 = ScheduleChangeEvent(
          group: 'GPV2.1',
          targetDate: '2026-10-09',
          sourceVersion: event(a, 0).sourceVersion + hour * 2000,
          hash: left,
          dayType: 'today');
      final e2 = ScheduleChangeEvent(
          group: e1.group,
          targetDate: e1.targetDate,
          sourceVersion: e1.sourceVersion + 1000,
          hash: right,
          dayType: 'today');
      await store.observe(e1, nowMs: now.millisecondsSinceEpoch, handled: true);
      await service.handlePush(push(e2));
      expect(shown.last.event.body(shown.last.previousHash),
          'Змінився час відключень на сьогодні ⚡');
    }
    expect(shown, hasLength(23));
  });

  test('half-hour changes and maybe statuses use the complete schedule code',
      () async {
    await service.observeSchedules(snapshot('2${'0' * 23}', 0));
    await service.handlePush(push(event('3${'0' * 23}', 1)));
    await service.handlePush(push(event('4${'0' * 23}', 2)));
    expect(shown, hasLength(2));
    expect(shown.first.event.body(shown.first.previousHash),
        'Змінився час відключень на сьогодні ⚡');
  });

  test(
      'content-equivalent republication preserves pending time and never repeats a handled change',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(b, 1), deliver: false);
    final pending = (await db.query('schedule_notification_state',
            where: "target_date = '2026-10-09'"))
        .single;
    now = now.add(const Duration(minutes: 6));
    await service.observeSchedules(snapshot(b, 2), deliver: false);
    final advanced = (await db.query('schedule_notification_state',
            where: "target_date = '2026-10-09'"))
        .single;
    expect(advanced['pending_since'], pending['pending_since']);
    expect(advanced['event_key'], pending['event_key']);
    now = now.add(const Duration(minutes: 4));
    await service.observeSchedules(snapshot(b, 2));
    await service.handlePush(push(event(b, 3)));
    expect(shown, hasLength(1));
  });

  test(
      'unnotified cache A to B to A cancels B, later polling B alerts immediately',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(b, 1), deliver: false);
    await service.observeSchedules(snapshot(a, 2), deliver: false);
    expect(shown, isEmpty);
    await service.observeSchedules(snapshot(b, 3));
    expect(shown, hasLength(1));
    expect(shown.single.identity, event(b, 3).id);
  });

  test(
      'viewing a graph consumes its change; a background cache update does not',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(b, 1), deliver: false);
    await service.acknowledge(event(b, 1));
    await service.handlePush(push(event(b, 1)));
    expect(shown, isEmpty);
    await service.observeSchedules(snapshot(c, 2), deliver: false);
    await service.handlePush(push(event(c, 2)));
    expect(shown, hasLength(1));
  });

  test('stale FCM and equal-version conflicts cannot revert notification state',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.handlePush(push(event(c, 2)));
    expect(await service.handlePush(push(event(b, 1))), false);
    await expectLater(
        service.handlePush(push(event(b, 2))), throwsFormatException);
    expect(shown, hasLength(1));
    expect(
        (await db.query('schedule_notification_state',
                where: "target_date = '2026-10-09'"))
            .single['schedule_hash'],
        c);
  });

  test(
      'tomorrow FCM cannot consume today pending; other groups are independent',
      () async {
    await prefs.setStringList('notification_groups', ['GPV2.1', 'GPV1.1']);
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(b, 1), deliver: false);
    await service
        .handlePush(push(event(c, 2, date: '2026-10-10', dayType: 'tomorrow')));
    await service.handlePush(push(event(c, 2, group: 'GPV1.1')));
    await service.observeSchedules(snapshot(b, 3, tomorrow: c));
    expect(shown.map((x) => '${x.event.group}:${x.event.targetDate}'),
        ['GPV2.1:2026-10-10', 'GPV1.1:2026-10-09', 'GPV2.1:2026-10-09']);
  });

  test('withdrawal cancels pending tomorrow and republication alerts again',
      () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(a, 1, tomorrow: b), deliver: false);
    await service.observeSchedules(snapshot(a, 2));
    now = now.add(const Duration(minutes: 20));
    await service.observeSchedules(snapshot(a, 2));
    expect(shown, isEmpty);
    await service
        .handlePush(push(event(b, 3, date: '2026-10-10', dayType: 'tomorrow')));
    expect(shown, hasLength(1));
    expect(shown.single.event.title(published: true),
        'Опубліковано графік на ЗАВТРА! (Група 2.1)');
  });

  test(
      'midnight reuses target-date state without repeating yesterday tomorrow publication',
      () async {
    await service
        .handlePush(push(event(b, 1, date: '2026-10-10', dayType: 'tomorrow')));
    now = ScheduleClock.calendar(2026, 10, 10, 8);
    final today = ScheduleChangeEvent(
        group: 'GPV2.1',
        targetDate: '2026-10-10',
        sourceVersion:
            ScheduleClock.calendar(2026, 10, 10, 1).millisecondsSinceEpoch,
        hash: b,
        dayType: 'today');
    await service.handlePush(push(today));
    expect(shown, hasLength(1));
  });

  test(
      'disabled settings and unrelated group never display; enabling allows future changes',
      () async {
    await prefs.setBool('notify_schedule_change', false);
    await service.handlePush(push(event(b, 1)));
    await prefs.setBool('notify_schedule_change', true);
    await service.handlePush(push(event(b, 1)));
    await service.handlePush(push(event(a, 2, group: 'GPV1.1')));
    expect(shown, isEmpty);
    await service.handlePush(push(event(a, 2)));
    expect(shown, hasLength(1));
  });

  test('missing FCM subscription delivers fallback immediately', () async {
    await prefs.setStringList('fcm_subscribed_topics', []);
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(b, 1));
    expect(shown, hasLength(1));
  });

  test(
      'show failure retains pending and a restarted service retries successfully',
      () async {
    final failing = makeService(store,
        show: (_) async => throw StateError('platform unavailable'));
    await expectLater(failing.handlePush(push(event(b, 1))), throwsStateError);
    expect(
        (await db.query('schedule_notification_state')).single['pending_since'],
        isNotNull);
    service =
        makeService(ScheduleChangeNotificationStore(database: () async => db));
    await service.handlePush(push(event(b, 1)));
    await service.handlePush(push(event(b, 1)));
    expect(shown, hasLength(1));
    expect(
        (await db.query('schedule_notification_state')).single['pending_since'],
        isNull);
  });

  test('concurrent FCM and fallback have only one winner', () async {
    await service.observeSchedules(snapshot(a, 0));
    await service.observeSchedules(snapshot(b, 1), deliver: false);
    expect(shown, isEmpty);
    await Future.wait(List.generate(
        20,
        (i) => i.isEven
            ? service.handlePush(push(event(b, 1)))
            : service.observeSchedules(snapshot(b, 1))));
    expect(shown, hasLength(1));
  });

  test('newer change during display is not falsely acknowledged or lost',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    service = makeService(store, show: (claim) async {
      shown.add(claim);
      if (shown.length == 1) {
        started.complete();
        await release.future;
      }
    });
    await service.observeSchedules(snapshot(a, 0));
    final first = service.handlePush(push(event(b, 1)));
    await started.future;
    await service.handlePush(push(event(c, 2)));
    release.complete();
    await first;
    expect(shown.map((x) => x.event.hash), [b, c]);
    expect(
        (await db.query('schedule_notification_state',
                where: "target_date = '2026-10-09'"))
            .single['handled_hash'],
        c);
  });

  test('expired lease recovers with the same notification identity', () async {
    final e = event(b, 1);
    await store.observe(e, nowMs: now.millisecondsSinceEpoch, fromPush: true);
    final abandoned = await store.claim(e, nowMs: now.millisecondsSinceEpoch);
    await service.handlePush(push(e));
    expect(shown, isEmpty);
    now = now.add(const Duration(minutes: 2));
    await service.handlePush(push(e));
    expect(shown.single.identity, abandoned!.identity);
  });

  test(
      'viewing a newer graph while an older notification displays retains acknowledgment',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    service = makeService(store, show: (claim) async {
      shown.add(claim);
      started.complete();
      await release.future;
    });
    await service.observeSchedules(snapshot(a, 0));
    final inFlight = service.handlePush(push(event(b, 1)));
    await started.future;
    await service.acknowledge(event(c, 2));
    release.complete();
    await inFlight;
    await service.handlePush(push(event(c, 2)));
    expect(shown.map((claim) => claim.event.hash), [b]);
    final row = (await db.query('schedule_notification_state',
            where: "target_date = '2026-10-09'"))
        .single;
    expect(row['handled_hash'], c);
    expect(row['handled_version'], event(c, 2).sourceVersion);
    expect(row['pending_since'], isNull);
  });

  test(
      'unseen return to A during B display reports the return after B completes',
      () async {
    final started = Completer<void>();
    final release = Completer<void>();
    service = makeService(store, show: (claim) async {
      shown.add(claim);
      if (shown.length == 1) {
        started.complete();
        await release.future;
      }
    });
    await service.observeSchedules(snapshot(a, 0));
    final inFlight = service.handlePush(push(event(b, 1)));
    await started.future;
    await service.handlePush(push(event(a, 2)));
    release.complete();
    await inFlight;
    expect(shown.map((claim) => claim.event.hash), [b, a]);
    expect(shown.last.previousHash, b);
    expect(shown.last.event.body(shown.last.previousHash),
        'Світла стало БІЛЬШЕ на 2 год. 🎉');
  });

  test(
      'legacy OS-displayed push acknowledges only its own event without showing again',
      () async {
    await handleFcmBackgroundMessage(
        RemoteMessage(
            data: push(event(b, 1)),
            notification: const RemoteNotification(title: 'Old transport')),
        scheduleChanges: service,
        initializeFirebase: () async {},
        refreshSchedules: () async {});
    await service.handlePush(push(event(b, 1)));
    expect(shown, isEmpty);
  });

  test(
      'invalid hashes, groups, dates, identity and future versions have no side effects',
      () async {
    for (final fields in [
      {'scheduleHash': '1' * 23},
      {'scheduleHash': '9' * 24},
      {'group': 'GPV7.1'},
      {'targetDate': '2026-10-08'},
      {'dayType': 'unknown'},
      {'eventId': 'other'},
      {'sourceVersion': '9999999999999'},
      {'schemaVersion': '3'},
      {'sourceVersion': 'NaN'},
    ]) {
      await expectLater(service.handlePush({...push(event(b, 1)), ...fields}),
          throwsFormatException);
    }
    expect(await db.query('schedule_notification_state'), isEmpty);
    expect(shown, isEmpty);
  });

  test(
      'legacy local state bootstraps delta but unknown/manual metadata cannot advance state',
      () async {
    await prefs.setString('prev_hash_GPV2.1_today', a);
    await prefs.setString('prev_date_GPV2.1_today', '2026-10-09');
    await prefs.setStringList('fcm_subscribed_topics', []);
    await service.observeSchedules(snapshot(c, 1));
    expect(shown.single.previousHash, a);
    final before = await db.query('schedule_notification_state');
    await service.observeSchedules({
      'GPV2.1': FullSchedule(
          today: DailySchedule.fromEncodedString(b),
          tomorrow: DailySchedule.empty(),
          lastUpdatedSource: '09.10.2026 02:00 (Manual)')
    });
    expect(await db.query('schedule_notification_state'), before);
  });

  test('two real SQLite connections arbitrate claims and survive reopening',
      () async {
    final dir =
        await Directory.systemTemp.createTemp('lumen-notification-test-');
    final path = '${dir.path}/state.db';
    final first = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    final second = await databaseFactoryFfi.openDatabase(path,
        options: OpenDatabaseOptions(singleInstance: false));
    try {
      await ScheduleChangeNotificationStore.createSchema(first);
      final s1 = ScheduleChangeNotificationStore(database: () async => first);
      final s2 = ScheduleChangeNotificationStore(database: () async => second);
      final e = event(b, 1);
      await s1.observe(e, nowMs: now.millisecondsSinceEpoch, fromPush: true);
      final claims = await Future.wait([
        s1.claim(e, nowMs: now.millisecondsSinceEpoch),
        s2.claim(e, nowMs: now.millisecondsSinceEpoch)
      ]);
      expect(claims.whereType<ScheduleNotificationClaim>(), hasLength(1));
      await s1.finish(claims.whereType<ScheduleNotificationClaim>().single,
          success: true);
      await ScheduleChangeNotificationStore.createSchema(second);
      expect(await s2.claim(e, nowMs: now.millisecondsSinceEpoch), isNull);
    } finally {
      await first.close();
      await second.close();
      await dir.delete(recursive: true);
    }
  });
}
