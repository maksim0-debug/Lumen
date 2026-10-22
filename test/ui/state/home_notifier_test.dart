import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/ui/state/home_notifier.dart';

import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/services/history_service.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  MockPathProviderPlatform(this.path);
  final String path;
  @override
  Future<String?> getApplicationDocumentsPath() async {
    return path;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  final originalPaths = PathProviderPlatform.instance;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    scratch = await Directory.systemTemp.createTemp('lumen-home-state-');
    PathProviderPlatform.instance = MockPathProviderPlatform(scratch.path);
    await AchievementService().loadAllStates();
  });

  tearDownAll(() async {
    await (await HistoryService().database).close();
    PathProviderPlatform.instance = originalPaths;
    await scratch.delete(recursive: true);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'selected_group': 'GPV2.1',
      'notification_groups': ['GPV2.1'],
      'power_monitor_enabled': true,
    });
  });

  group('HomeState Tests', () {
    test('Default values are correct', () {
      const state = HomeState();
      expect(state.currentGroup, equals('GPV2.1'));
      expect(state.isLoading, isTrue);
      expect(state.viewMode, equals(ScheduleViewMode.today));
      expect(state.selectedVersionIndex, equals(-1));
      expect(state.isHistoryMode, isFalse);
      expect(state.dataSourceMode, equals(DataSourceMode.predicted));
    });

    test('isHistoryMode reflects viewMode correctly', () {
      const stateToday = HomeState(viewMode: ScheduleViewMode.today);
      expect(stateToday.isHistoryMode, isFalse);

      const stateYesterday = HomeState(viewMode: ScheduleViewMode.yesterday);
      expect(stateYesterday.isHistoryMode, isTrue);

      const stateHistory = HomeState(viewMode: ScheduleViewMode.history);
      expect(stateHistory.isHistoryMode, isTrue);

      const stateTomorrow = HomeState(viewMode: ScheduleViewMode.tomorrow);
      expect(stateTomorrow.isHistoryMode, isFalse);
    });

    test('displayDate calculation', () {
      final now = DateTime.now();

      const stateToday = HomeState(viewMode: ScheduleViewMode.today);
      expect(stateToday.displayDate.day, equals(now.day));

      const stateTomorrow = HomeState(viewMode: ScheduleViewMode.tomorrow);
      final tomorrow = now.add(const Duration(days: 1));
      expect(stateTomorrow.displayDate.day, equals(tomorrow.day));

      const stateYesterday = HomeState(viewMode: ScheduleViewMode.yesterday);
      final yesterday = now.subtract(const Duration(days: 1));
      expect(stateYesterday.displayDate.day, equals(yesterday.day));

      final customDate = DateTime(2025, 5, 20);
      final stateCustom = HomeState(
        viewMode: ScheduleViewMode.history,
        historyDate: customDate,
      );
      expect(stateCustom.displayDate, equals(customDate));
    });

    test('copyWith updates fields properly', () {
      const state = HomeState();
      final updated = state.copyWith(
        currentGroup: 'GPV3.2',
        isLoading: false,
        statusMessage: 'Готово',
        statusColor: Colors.green,
        dataSourceMode: DataSourceMode.real,
      );

      expect(updated.currentGroup, equals('GPV3.2'));
      expect(updated.isLoading, isFalse);
      expect(updated.statusMessage, equals('Готово'));
      expect(updated.statusColor, equals(Colors.green));
      expect(updated.dataSourceMode, equals(DataSourceMode.real));
    });
  });

  group('HomeNotifier Tests via ProviderContainer', () {
    test('Initial build returns default HomeState', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final state = container.read(homeNotifierProvider);
      expect(state.currentGroup, equals('GPV2.1'));
      expect(state.isLoading, isTrue);
    });

    test('changeGroup changes currentGroup and resets version state', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);
      await notifier.changeGroup('GPV1.1');

      final state = container.read(homeNotifierProvider);
      expect(state.currentGroup, equals('GPV1.1'));
      expect(state.selectedVersionIndex, equals(-1));
      expect(state.historyVersions, isEmpty);
    });

    for (final groups in <List<String>?>[
      ['GPV2.1'],
      ['GPV1.2'],
      ['GPV2.1', 'GPV1.2'],
      [],
      null,
    ]) {
      test('view changes preserve notification groups $groups', () async {
        SharedPreferences.setMockInitialValues({
          'selected_group': 'GPV2.1',
          if (groups != null) 'notification_groups': groups,
        });
        final expected = groups == null || groups.isEmpty ? ['GPV2.1'] : groups;
        final container = ProviderContainer();
        addTearDown(container.dispose);
        final notifier = container.read(homeNotifierProvider.notifier);
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('prev_hash_GPV1.1_today', '0' * 24);
        notifier.state = notifier.state.copyWith(allSchedules: {
          'GPV1.1': FullSchedule(
            today: DailySchedule.fromEncodedString('1' * 24),
            tomorrow: DailySchedule.empty(),
          ),
        });

        for (final viewed in ['GPV1.1', 'GPV3.2', 'GPV2.1']) {
          await notifier.changeGroup(viewed);
          expect(container.read(homeNotifierProvider).currentGroup, viewed);
          expect(container.read(homeNotifierProvider).notificationGroups,
              expected);
          expect(prefs.getString('selected_group'), viewed);
          expect(prefs.getStringList('notification_groups'), expected);
          expect(prefs.getString('prev_hash_GPV1.1_today'), '0' * 24,
              reason: 'Viewing a schedule must not acknowledge its changes');
        }

        await notifier.loadPreferencesAndData(refreshSchedules: false);
        expect(
            container.read(homeNotifierProvider).notificationGroups, expected);
      });
    }

    test('switchMode toggles DataSourceMode when enabled', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);
      // Enable power monitor in state first
      notifier.state = notifier.state.copyWith(powerMonitorEnabled: true);

      await notifier.switchMode(DataSourceMode.real);
      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.real));

      await notifier.switchMode(DataSourceMode.predicted);
      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.predicted));
    });

    test('selectVersion updates selectedVersionIndex and historySchedule', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);
      final dummyVersion = ScheduleVersion(
        hash: '0:0,1:0,2:0',
        savedAt: DateTime(2026, 1, 1, 12, 0),
        outageMinutes: 120,
      );

      notifier.state = notifier.state.copyWith(
        historyVersions: [dummyVersion],
        selectedVersionIndex: -1,
      );

      notifier.selectVersion(0);

      final state = container.read(homeNotifierProvider);
      expect(state.selectedVersionIndex, equals(0));
      expect(state.historySchedule, isNotNull);
      expect(state.statusMessage, contains('12:00'));
    });

    test('navigateDate handles transitions correctly', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);

      // Start at today
      notifier.state = notifier.state.copyWith(
        viewMode: ScheduleViewMode.today,
      );

      // Navigate to tomorrow (+1)
      await notifier.navigateDate(1);
      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.tomorrow));

      // Tomorrow cannot navigate forward
      await notifier.navigateDate(1);
      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.tomorrow));

      // Navigate back to today (-1)
      await notifier.navigateDate(-1);
      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.today));

      // Navigate back to yesterday (-1)
      await notifier.navigateDate(-1);
      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.yesterday));
    });

    test(
        'recalculateDisplayData clears currentDisplaySchedule when schedule is null',
        () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);
      final dummySchedule = DailySchedule(List.filled(24, LightStatus.on));

      // Set non-null schedule first
      notifier.state = notifier.state.copyWith(
        currentDisplaySchedule: dummySchedule,
      );
      expect(container.read(homeNotifierProvider).currentDisplaySchedule,
          isNotNull);

      // Recalculate with no schedules available
      notifier.recalculateDisplayData();
      expect(
          container.read(homeNotifierProvider).currentDisplaySchedule, isNull);
    });
  });
}
