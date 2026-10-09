import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/services/emergency_status_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/services/schedule_notification_coordinator.dart';
import 'package:lumen/services/schedule_sync_service.dart';
import 'package:lumen/ui/state/home_notifier.dart';
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
  setUp(() async {
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
