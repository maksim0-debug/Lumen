import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/services/emergency_status_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/services/schedule_notification_coordinator.dart';
import 'package:lumen/services/schedule_sync_service.dart';
import 'package:lumen/ui/state/home_notifier.dart';
import 'package:lumen/utils/app_formatters.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _Parser extends ParserService {
  _Parser() : super.forTesting();
  ({ParserFetchResult value, int completedAt})? recent;
  Future<({ParserFetchResult value, int completedAt})?>? pending;
  Object? recentError;
  int fetches = 0;
  Map<String, FullSchedule> data = {};
  @override
  Future<({ParserFetchResult value, int completedAt})?>
      recentAndroidSnapshot() async {
    if (recentError != null) throw recentError!;
    return pending != null ? await pending : recent;
  }

  @override
  Future<Map<String, FullSchedule>> fetchAllSchedules() async {
    fetches++;
    return data;
  }
}

class _Notifications extends Fake implements ScheduleNotificationCoordinator {
  final applied = <Map<String, FullSchedule>>[];
  @override
  Future<void> handleScheduleUpdate(
      {required Map<String, FullSchedule> allSchedules,
      required String currentGroup,
      Iterable<String>? notificationGroups}) async {
    applied.add(allSchedules);
  }
}

class _Achievements extends Fake implements AchievementService {
  @override
  Future<void> checkAll(
      {Map<String, FullSchedule>? schedules, String? currentGroup}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late ProviderContainer container;
  late HomeNotifier home;
  late _Parser parser;
  late ScheduleSyncService sync;
  late _Notifications notifications;
  late DateTime now;
  setUp(() async {
    now = ScheduleClock.now();
    SharedPreferences.setMockInitialValues({'enable_logging': false});
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
        'CREATE TABLE schedule_history (id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'group_key TEXT, target_date TEXT, schedule_code TEXT, dtek_updated_at TEXT)');
    await db
        .execute('CREATE TABLE app_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'timestamp TEXT, level TEXT, message TEXT)');
    final history = HistoryService.forTesting(db);
    parser = _Parser()
      ..data = {
        'GPV2.1': FullSchedule(
            today: DailySchedule.fromEncodedString('1' * 24),
            tomorrow: DailySchedule.empty())
      };
    sync = ScheduleSyncService(parser: parser, historyService: history);
    notifications = _Notifications();
    container = ProviderContainer(overrides: [
      homeNotifierProvider.overrideWith(() => HomeNotifier(
          now: () => now,
          scheduleSyncService: sync,
          historyService: history,
          emergencyStatusService:
              EmergencyStatusService.forTesting(() async => db),
          scheduleNotificationCoordinator: notifications,
          achievementService: _Achievements()))
    ]);
    home = container.read(homeNotifierProvider.notifier);
  });
  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<void> seedCache({String update = '10.10.2026 00:01'}) async {
    await db.insert('schedule_history', {
      'group_key': 'GPV2.1',
      'target_date': AppFormatters.formatDateKey(ScheduleClock.now()),
      'schedule_code': '1' * 24,
      'dtek_updated_at': update,
    });
  }

  test('Unchanged resume cache preserves its offline status and skips effects',
      () async {
    await seedCache();
    home.state = home.state.copyWith(
      allSchedules: await sync.loadCachedData(),
      isCachedData: true,
      wasUpdated: false,
      statusMessage: "З пам'яті",
      statusColor: Colors.orange,
    );
    final before = home.state;
    await home.refreshReceivedSchedules();
    expect(home.state, same(before));
    expect(notifications.applied, isEmpty);
    expect(parser.fetches, 0);
  });

  test('Unchanged live cache does not repeat update effects on resume',
      () async {
    await seedCache();
    home.state = home.state.copyWith(
      allSchedules: await sync.loadCachedData(),
      isCachedData: false,
      wasUpdated: false,
    );
    final before = home.state;
    await home.refreshReceivedSchedules();
    expect(home.state, same(before));
    expect(notifications.applied, isEmpty);
    expect(parser.fetches, 0);
  });

  test(
      'New cached source publication updates resume UI without a network fetch',
      () async {
    await seedCache();
    home.state = home.state.copyWith(
      allSchedules: await sync.loadCachedData(),
      isCachedData: true,
      wasUpdated: false,
    );
    await seedCache(update: '10.10.2026 00:02');
    await home.refreshReceivedSchedules();
    expect(home.state.allSchedules['GPV2.1']!.lastUpdatedSource,
        '10.10.2026 00:02');
    expect(home.state.isCachedData, false);
    expect(home.state.wasUpdated, true);
    expect(notifications.applied, hasLength(1));
    expect(parser.fetches, 0);
  });

  test('Midnight with identical codes refreshes cached display without effects',
      () async {
    await seedCache();
    await home.refreshReceivedSchedules();
    final before = home.state;
    now = ScheduleClock.day(now, 1);
    await home.refreshReceivedSchedules();
    expect(home.state, isNot(same(before)));
    expect(home.state.isCachedData, true);
    expect(home.state.wasUpdated, false);
    expect(notifications.applied, isEmpty);
  });

  test('Changed cache with the same publication stays offline', () async {
    await seedCache();
    await home.refreshReceivedSchedules();
    await db.insert('schedule_history', {
      'group_key': 'GPV2.1',
      'target_date': AppFormatters.formatDateKey(ScheduleClock.now()),
      'schedule_code': '0' * 24,
      'dtek_updated_at': '10.10.2026 00:01',
    });
    await home.refreshReceivedSchedules();
    expect(home.state.allSchedules['GPV2.1']!.today.scheduleHash, '0' * 24);
    expect(home.state.isCachedData, true);
    expect(home.state.wasUpdated, false);
    expect(home.state.statusColor, Colors.orange);
    expect(notifications.applied, isEmpty);
  });

  test('The same live map can restore state after a different cached graph',
      () async {
    parser.recent = (
      value: ParserFetchResult(parser.data, null),
      completedAt: DateTime.now().millisecondsSinceEpoch
    );
    await home.refreshAfterResume();
    await seedCache();
    await home.refreshReceivedSchedules();
    await home.refreshAfterResume();
    expect(home.state.allSchedules, same(parser.data));
    expect(home.state.isCachedData, false);
  });

  for (final update in ['09.10.2026 23:59', 'Unknown publication']) {
    test('Changed cached source $update cannot establish a newer publication',
        () async {
      await seedCache();
      await home.refreshReceivedSchedules();
      await seedCache(update: update);
      await home.refreshReceivedSchedules();
      expect(home.state.isCachedData, true);
      expect(home.state.wasUpdated, false);
      expect(notifications.applied, isEmpty);
    });
  }

  test('Midnight with changed codes cannot promote an old cached publication',
      () async {
    await seedCache();
    await home.refreshReceivedSchedules();
    now = ScheduleClock.day(now, 1);
    await db.insert('schedule_history', {
      'group_key': 'GPV2.1',
      'target_date': AppFormatters.formatDateKey(ScheduleClock.now()),
      'schedule_code': '0' * 24,
      'dtek_updated_at': '10.10.2026 00:01',
    });
    await home.refreshReceivedSchedules();
    expect(home.state.allSchedules['GPV2.1']!.today.scheduleHash, '0' * 24);
    expect(home.state.isCachedData, true);
    expect(home.state.wasUpdated, false);
    expect(notifications.applied, isEmpty);
  });

  test('Resume displays SQLite data before waiting for a coordinated fetch',
      () async {
    await seedCache();
    final completion =
        Completer<({ParserFetchResult value, int completedAt})?>();
    parser.pending = completion.future;
    final resumed = home.refreshAfterResume();
    // Wait for the queued cache read/application, not an arbitrary timer.
    await Future.doWhile(() async {
      await Future<void>.delayed(Duration.zero);
      return home.state.allSchedules.isEmpty;
    }).timeout(const Duration(seconds: 5));
    expect(home.state.isCachedData, true);
    expect(notifications.applied, isEmpty);
    completion.complete((
      value: ParserFetchResult(parser.data, null),
      completedAt: DateTime.now().millisecondsSinceEpoch
    ));
    await resumed;
    expect(home.state.isCachedData, false);
    expect(home.state.allSchedules, same(parser.data));
    expect(parser.fetches, 0);
  });

  test('Initial resume cache without a known live state stays marked cached',
      () async {
    await seedCache();
    await home.refreshReceivedSchedules();
    expect(home.state.allSchedules, isNotEmpty);
    expect(home.state.isCachedData, true);
    expect(home.state.wasUpdated, false);
    expect(home.state.statusColor, Colors.orange);
    expect(notifications.applied, isEmpty);
    expect(parser.fetches, 0);
  });

  test('Tomorrow-only cache change is applied even if today and source match',
      () async {
    await seedCache();
    home.state = home.state.copyWith(allSchedules: await sync.loadCachedData());
    await db.insert('schedule_history', {
      'group_key': 'GPV2.1',
      'target_date': AppFormatters.formatDateKey(
          ScheduleClock.day(ScheduleClock.now(), 1)),
      'schedule_code': '0' * 24,
      'dtek_updated_at': '10.10.2026 00:02',
    });
    await home.refreshReceivedSchedules();
    expect(home.state.allSchedules['GPV2.1']!.tomorrow.scheduleHash, '0' * 24);
    expect(notifications.applied, isEmpty);
    expect(home.state.isCachedData, true);
    expect(parser.fetches, 0);
  });

  test('New unselected subgroup is loaded without changing history selection',
      () async {
    await seedCache();
    home.state = home.state.copyWith(
      allSchedules: await sync.loadCachedData(),
      viewMode: ScheduleViewMode.yesterday,
      historySchedule: DailySchedule.fromEncodedString('0' * 24),
    );
    await db.insert('schedule_history', {
      'group_key': 'GPV6.2',
      'target_date': AppFormatters.formatDateKey(ScheduleClock.now()),
      'schedule_code': '2' * 24,
      'dtek_updated_at': '10.10.2026 00:02',
    });
    await home.refreshReceivedSchedules();
    expect(home.state.allSchedules['GPV6.2']!.today.scheduleHash, '2' * 24);
    expect(home.state.viewMode, ScheduleViewMode.yesterday);
    expect(home.state.currentDisplaySchedule!.scheduleHash, '0' * 24);
    expect(notifications.applied, hasLength(1));
    expect(parser.fetches, 0);
  });

  test(
      'Resume applies a recently completed worker snapshot without another network fetch',
      () async {
    final completedAt = DateTime.now().millisecondsSinceEpoch - 1000;
    parser.recent =
        (value: ParserFetchResult(parser.data, null), completedAt: completedAt);
    await home.refreshAfterResume();
    expect(parser.fetches, 0);
    expect(home.state.allSchedules, same(parser.data));
    expect(home.state.isCachedData, false);
    expect(home.state.isLoading, false);
    expect(sync.lastFetchTime!.millisecondsSinceEpoch, completedAt);
    expect(notifications.applied, [parser.data]);
  });

  test(
      'Without a fresh completed worker snapshot resume performs a normal fetch',
      () async {
    await home.refreshAfterResume();
    expect(parser.fetches, 1);
    expect(home.state.allSchedules, same(parser.data));
  });

  test(
      'An empty worker result does not replace data and triggers a real refresh',
      () async {
    parser.recent = (
      value: const ParserFetchResult({}, null),
      completedAt: DateTime.now().millisecondsSinceEpoch
    );
    await home.refreshAfterResume();
    expect(parser.fetches, 1);
    expect(home.state.allSchedules, same(parser.data));
  });

  test('Failure to read coordination state falls back to normal fetching',
      () async {
    parser.recentError = StateError('coordination unavailable');
    await home.refreshAfterResume();
    expect(parser.fetches, 1);
    expect(home.state.allSchedules, same(parser.data));
  });

  test(
      'A history selection stays selected while live schedules update on resume',
      () async {
    home.state = home.state.copyWith(
        viewMode: ScheduleViewMode.yesterday,
        historySchedule: DailySchedule.fromEncodedString('0' * 24));
    parser.recent = (
      value: ParserFetchResult(parser.data, null),
      completedAt: DateTime.now().millisecondsSinceEpoch
    );
    await home.refreshAfterResume();
    expect(home.state.viewMode, ScheduleViewMode.yesterday);
    expect(home.state.currentDisplaySchedule!.toEncodedString(), '0' * 24);
    expect(home.state.allSchedules, same(parser.data));
    expect(parser.fetches, 0);
  });

  test('Disposal during a resume read does not fetch or mutate a dead provider',
      () async {
    final result = Completer<({ParserFetchResult value, int completedAt})?>();
    parser.pending = result.future;
    final resumed = home.refreshAfterResume();
    container.dispose();
    result.complete((
      value: ParserFetchResult(parser.data, null),
      completedAt: DateTime.now().millisecondsSinceEpoch
    ));
    await resumed;
    expect(parser.fetches, 0);
    expect(notifications.applied, isEmpty);
  });
}
