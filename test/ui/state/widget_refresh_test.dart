import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/models/emergency_status.dart';
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
import 'package:shared_preferences/shared_preferences.dart';

class _Parser extends Fake implements ParserService {
  int calls = 0;
  Future<Map<String, FullSchedule>> Function()? fetch;
  final data = {
    'GPV2.1': FullSchedule(
        today: DailySchedule.fromEncodedString('1' * 24),
        tomorrow: DailySchedule.fromEncodedString('0' * 24),
        lastUpdatedSource: '11.10.2026 12:00'),
  };

  @override
  Future<Map<String, FullSchedule>> fetchAllSchedules() async {
    calls++;
    if (fetch == null) return data;
    return await fetch!();
  }
}

class _History extends Fake implements HistoryService {
  Completer<List<ScheduleVersion>>? archive;
  @override
  Future<Map<String, FullSchedule>> getLastKnownSchedules() async => {};
  @override
  Future<List<ScheduleVersion>> getVersionsForDate(
      DateTime date, String groupKey) async {
    if (date.isBefore(ScheduleClock.day(ScheduleClock.now())) &&
        archive != null) {
      return archive!.future;
    }
    return [];
  }

  @override
  Future<String?> getLatestUpdatedAt(
          {required String groupKey, required String targetDate}) async =>
      null;
  @override
  Future<void> logAction(String message, {String level = 'INFO'}) async {}
}

class _Effects extends Fake implements ScheduleNotificationCoordinator {
  int applied = 0;
  @override
  Future<void> handleScheduleUpdate(
      {required Map<String, FullSchedule> allSchedules,
      required String currentGroup}) async {
    applied++;
  }

  @override
  Future<void> updateNotificationsOnly(
      {required Map<String, FullSchedule> allSchedules,
      required String currentGroup}) async {}
}

class _Achievements extends Fake implements AchievementService {
  int widgetOpens = 0;
  bool failWidgetTracking = false;
  @override
  Future<void> trackWidgetOpen() async {
    widgetOpens++;
    if (failWidgetTracking) throw StateError('achievement storage unavailable');
  }

  @override
  Future<void> trackRefresh() async {}
  @override
  Future<void> checkAll(
      {Map<String, FullSchedule>? schedules, String? currentGroup}) async {}
}

class _Emergency extends Fake implements EmergencyStatusService {
  @override
  Stream<EmergencyStatus> get changes => const Stream.empty();
  @override
  Future<EmergencyStatus> read() async => const EmergencyStatus();
}

class _ControlledSync extends ScheduleSyncService {
  Completer<void>? nextIdle;
  _ControlledSync({required super.parser, required super.historyService});
  @override
  Future<void> waitForIdle() {
    final pending = nextIdle;
    nextIdle = null;
    return pending?.future ?? super.waitForIdle();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Parser parser;
  late _History history;
  late _Effects effects;
  late _ControlledSync sync;
  late ProviderContainer container;
  late HomeNotifier notifier;
  late _Achievements achievements;

  setUp(() {
    SharedPreferences.setMockInitialValues({'selected_group': 'GPV3.2'});
    parser = _Parser();
    history = _History();
    effects = _Effects();
    achievements = _Achievements();
    sync = _ControlledSync(parser: parser, historyService: history);
    container = ProviderContainer(overrides: [
      homeNotifierProvider.overrideWith(() => HomeNotifier(
          scheduleSyncService: sync,
          historyService: history,
          scheduleNotificationCoordinator: effects,
          achievementService: achievements,
          emergencyStatusService: _Emergency())),
    ]);
    notifier = container.read(homeNotifierProvider.notifier);
    notifier.state = notifier.state.copyWith(isLoading: false);
  });
  tearDown(() => container.dispose());

  test('widget entry tracks always-visible achievement even when offline',
      () async {
    parser.fetch = () async => throw StateError('offline');
    await notifier.refreshFromWidget();
    expect(achievements.widgetOpens, 1);
    await notifier.refresh();
    expect(achievements.widgetOpens, 1,
        reason: 'Ordinary refresh is not widget entry');
  });

  test('achievement storage failure does not prevent widget refresh', () async {
    achievements.failWidgetTracking = true;
    await notifier.refreshFromWidget();
    expect(achievements.widgetOpens, 1);
    expect(parser.calls, 1);
    expect(container.read(homeNotifierProvider).statusColor, Colors.green);
  });

  test('widget check proceeds after an overlapping manual operation throws',
      () async {
    final idle = Completer<void>();
    sync.nextIdle = idle;
    final manual = notifier.refresh();
    final manualError = expectLater(manual, throwsA(isA<StateError>()));
    final widget = notifier.refreshFromWidget();
    await Future<void>.delayed(Duration.zero);
    idle.completeError(StateError('previous operation failed'));
    await manualError;
    await widget;
    expect(parser.calls, 1);
    expect(container.read(homeNotifierProvider).isRefreshing, false);
    expect(container.read(homeNotifierProvider).statusColor, Colors.green);
  });

  test('already completed failed manual operation is not retained', () async {
    final idle = Completer<void>();
    sync.nextIdle = idle;
    final manual = notifier.refresh();
    final failure = expectLater(manual, throwsA(isA<StateError>()));
    idle.completeError(StateError('previous operation failed'));
    await failure;
    expect(notifier.refreshOperation, isNull);
    await notifier.refreshFromWidget();
    expect(parser.calls, 1);
  });

  for (final mode in ScheduleViewMode.values) {
    test('widget refresh from $mode checks today and applies fresh schedules',
        () async {
      final archived = DailySchedule.fromEncodedString('0' * 24);
      notifier.state = notifier.state.copyWith(
        viewMode: mode,
        historyDate: DateTime(2025, 1, 1),
        historySchedule: archived,
        currentDisplaySchedule: archived,
        selectedVersionIndex: 0,
        dataSourceMode: DataSourceMode.real,
      );
      sync.lastFetchTime = DateTime.now();
      await notifier.refreshFromWidget();
      final state = container.read(homeNotifierProvider);
      expect(parser.calls, 1, reason: 'Explicit request bypasses cooldown');
      expect(state.viewMode, ScheduleViewMode.today);
      expect(state.historyDate, isNull);
      expect(state.historySchedule, isNull);
      expect(state.selectedVersionIndex, -1);
      expect(state.currentGroup, 'GPV2.1');
      expect(state.dataSourceMode, DataSourceMode.real);
      expect(state.allSchedules, parser.data);
      expect(state.currentDisplaySchedule!.scheduleHash, '1' * 24);
      expect(state.isLoading, false);
      expect(state.statusColor, Colors.green);
      expect(effects.applied, 1);
    });
  }

  test('offline error retains last known graph and displays failure', () async {
    final old = {
      'GPV2.1': FullSchedule(
          today: DailySchedule.fromEncodedString('0' * 24),
          tomorrow: DailySchedule.empty()),
    };
    notifier.state = notifier.state.copyWith(allSchedules: old);
    parser.fetch = () async => throw StateError('offline');
    await notifier.refreshFromWidget();
    final state = container.read(homeNotifierProvider);
    expect(state.allSchedules, old);
    expect(state.currentDisplaySchedule!.scheduleHash, '0' * 24);
    expect(state.statusMessage, 'Помилка оновлення');
    expect(state.statusColor, Colors.red);
    expect(state.isLoading, false);
    expect(effects.applied, 0);
  });

  test('empty result completes loading with error and next tap can recover',
      () async {
    parser.fetch = () async => {};
    await notifier.refreshFromWidget();
    expect(container.read(homeNotifierProvider).isLoading, false);
    expect(container.read(homeNotifierProvider).statusColor, Colors.red);
    parser.fetch = null;
    await notifier.refreshFromWidget();
    expect(parser.calls, 2);
    expect(container.read(homeNotifierProvider).allSchedules, parser.data);
    expect(effects.applied, 1);
  });

  test('overlapping widget requests share a single fetch and effects',
      () async {
    final completed = Completer<Map<String, FullSchedule>>();
    final started = Completer<void>();
    parser.fetch = () {
      started.complete();
      return completed.future;
    };
    final first = notifier.refreshFromWidget();
    final second = notifier.refreshFromWidget();
    await started.future;
    expect(parser.calls, 1);
    expect(container.read(homeNotifierProvider).isRefreshing, true);
    completed.complete(parser.data);
    await Future.wait([first, second]);
    expect(effects.applied, 1);
    expect(achievements.widgetOpens, 1);
    expect(container.read(homeNotifierProvider).isRefreshing, false);
  });

  test('button and pull share refresh and clear activity after timeout',
      () async {
    final response = Completer<Map<String, FullSchedule>>();
    final started = Completer<void>();
    parser.fetch = () {
      started.complete();
      return response.future;
    };
    final button = notifier.refresh();
    final pull = notifier.refresh(silent: true);
    await started.future;
    expect(parser.calls, 1);
    expect(container.read(homeNotifierProvider).isRefreshing, true);
    expect(notifier.refreshOperation, isNotNull);
    response.completeError(TimeoutException('source timeout'));
    await Future.wait([button, pull]);
    expect(container.read(homeNotifierProvider).isRefreshing, false);
    expect(notifier.refreshOperation, isNull);
    expect(container.read(homeNotifierProvider).statusColor, Colors.red);
  });

  test('widget request waits for existing sync instead of being skipped',
      () async {
    final response = Completer<Map<String, FullSchedule>>();
    final started = Completer<void>();
    parser.fetch = () {
      started.complete();
      return response.future;
    };
    final existing = sync.syncSchedules();
    await started.future;
    final widget = notifier.refreshFromWidget();
    await Future<void>.delayed(Duration.zero);
    expect(parser.calls, 1);
    parser.fetch = null;
    response.complete(parser.data);
    await existing;
    await widget;
    expect(parser.calls, 2);
    expect(container.read(homeNotifierProvider).statusColor, Colors.green);
  });

  test('late archive read cannot overwrite current graph after widget refresh',
      () async {
    history.archive = Completer<List<ScheduleVersion>>();
    final yesterday = ScheduleClock.day(ScheduleClock.now(), -1);
    notifier.state =
        notifier.state.copyWith(viewMode: ScheduleViewMode.yesterday);
    final archiveRead = notifier.loadHistoryData(yesterday);
    await notifier.refreshFromWidget();
    history.archive!.complete([
      ScheduleVersion(hash: '0' * 24, savedAt: yesterday, outageMinutes: 0),
    ]);
    await archiveRead;
    final state = container.read(homeNotifierProvider);
    expect(state.viewMode, ScheduleViewMode.today);
    expect(state.currentDisplaySchedule!.scheduleHash, '1' * 24);
    expect(state.historySchedule, isNull);
  });

  test('cold launch loads preferences without extra network fetch', () async {
    await notifier.loadPreferencesAndData(refreshSchedules: false);
    expect(parser.calls, 0);
    expect(container.read(homeNotifierProvider).currentGroup, 'GPV3.2');
    await notifier.refreshFromWidget();
    expect(parser.calls, 1);
    expect(container.read(homeNotifierProvider).currentGroup, 'GPV3.2');
  });

  test('dispose while waiting for active sync prevents another request',
      () async {
    final response = Completer<Map<String, FullSchedule>>();
    final started = Completer<void>();
    parser.fetch = () {
      started.complete();
      return response.future;
    };
    final existing = sync.syncSchedules();
    await started.future;
    final widget = notifier.refreshFromWidget();
    container.dispose();
    response.complete(parser.data);
    await existing;
    await widget;
    expect(parser.calls, 1);
  });

  test('failed active sync releases widget request for a new check', () async {
    final response = Completer<Map<String, FullSchedule>>();
    final started = Completer<void>();
    parser.fetch = () {
      started.complete();
      return response.future;
    };
    final existing = sync.syncSchedules();
    await started.future;
    final widget = notifier.refreshFromWidget();
    parser.fetch = null;
    response.completeError(StateError('offline'));
    expect((await existing).isError, true);
    await widget;
    expect(parser.calls, 2);
    expect(container.read(homeNotifierProvider).statusColor, Colors.green);
  });

  for (final fail in [false, true]) {
    test('dispose during widget fetch handles completion (failure=$fail)',
        () async {
      final response = Completer<Map<String, FullSchedule>>();
      final started = Completer<void>();
      parser.fetch = () {
        started.complete();
        return response.future;
      };
      final widget = notifier.refreshFromWidget();
      await started.future;
      container.dispose();
      if (fail) {
        response.completeError(StateError('offline'));
      } else {
        response.complete(parser.data);
      }
      await widget;
      expect(effects.applied, 0);
      expect(sync.isFetching, false);
    });
  }
}
