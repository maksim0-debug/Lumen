import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/models/hour_segment.dart';
import 'package:lumen/models/interval_info.dart';
import 'package:lumen/models/power_event.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/ui/home_screen.dart';
import 'package:lumen/ui/state/home_notifier.dart';
import 'package:lumen/ui/widgets/home/real_mode_grid_cell.dart';
import 'package:lumen/ui/widgets/home/schedule_intervals_list.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String documentsPath;
  MockPathProviderPlatform(this.documentsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getTemporaryPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir =
        await Directory.systemTemp.createTemp('lumen_home_real_past_test_');
    PathProviderPlatform.instance = MockPathProviderPlatform(tempDir.path);
    await AchievementService().loadAllStates();
  });

  tearDownAll(() async {
    try {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    } catch (_) {}
  });

  Widget buildTestApp(ProviderContainer container) {
    return UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(
        home: HomeScreen(),
      ),
    );
  }

  Future<void> pumpHome(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  Future<void> drainTimers(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 11));
  }

  group('Real Mode Past Schedule View Tests (Without DB URL)', () {
    testWidgets(
        'In history mode with real outage data and NO custom DB URL, renders grid cells and intervals instead of URL warning',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'selected_group': 'GPV2.1',
        'power_monitor_enabled': true,
        // Notice: custom_power_monitor_url is not set!
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      final notifier = container.read(homeNotifierProvider.notifier);

      // Simulate past date with real outage data and real mode
      final pastDate = DateTime(2026, 2, 17);
      final sampleSegments = List.generate(
        24,
        (i) => [
          const HourSegment(0, 1, Colors.green,
              status: LightStatus.on, isFuture: false)
        ],
      );
      final sampleIntervals = [
        PowerOutageInterval(
          start: DateTime(2026, 2, 17, 3, 0),
          end: DateTime(2026, 2, 17, 6, 9),
        ),
      ];

      notifier.state = container.read(homeNotifierProvider).copyWith(
        isLoading: false,
        powerMonitorEnabled: true,
        dataSourceMode: DataSourceMode.real,
        viewMode: ScheduleViewMode.history,
        historyDate: pastDate,
        realOutageIntervals: sampleIntervals,
        realHourSegments: sampleSegments,
        cachedIntervals: [
          IntervalInfo("00:00 - 03:00", "ON", "3г", Colors.green),
          IntervalInfo("03:00 - 06:09", "OFF", "3г 9хв", Colors.red),
          IntervalInfo("06:09 - 24:00", "ON", "17г 51хв", Colors.green),
        ],
      );

      await tester.pumpAndSettle();

      // Must NOT show the missing URL message
      expect(
        find.text("URL бази даних не налаштовано. Перейдіть в Налаштування."),
        findsNothing,
      );

      // Must show RealModeGridCell widgets (all 24 hours)
      expect(find.byType(RealModeGridCell), findsNWidgets(24));

      // Must show ScheduleIntervalsList
      expect(find.byType(ScheduleIntervalsList), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets(
        'On today with NO custom DB URL and NO outage data, displays URL warning',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'selected_group': 'GPV2.1',
        'power_monitor_enabled': true,
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      final notifier = container.read(homeNotifierProvider.notifier);

      notifier.state = container.read(homeNotifierProvider).copyWith(
        isLoading: false,
        powerMonitorEnabled: true,
        dataSourceMode: DataSourceMode.real,
        viewMode: ScheduleViewMode.today,
        realOutageIntervals: const [],
      );

      await tester.pumpAndSettle();

      // Must show the missing URL message
      expect(
        find.text("URL бази даних не налаштовано. Перейдіть в Налаштування."),
        findsOneWidget,
      );

      // Grid cells and intervals list should not be shown
      expect(find.byType(RealModeGridCell), findsNothing);
      expect(find.byType(ScheduleIntervalsList), findsNothing);

      await drainTimers(tester);
    });

    testWidgets(
        'On tomorrow in Real Mode with forecast schedule and NO custom DB URL, renders grid cells and intervals',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'selected_group': 'GPV2.1',
        'power_monitor_enabled': true,
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      final notifier = container.read(homeNotifierProvider.notifier);

      final sampleSegments = List.generate(
        24,
        (i) => [
          const HourSegment(0, 1, Colors.green,
              status: LightStatus.on, isFuture: true)
        ],
      );
      final forecastSchedule = DailySchedule(List.filled(24, LightStatus.on));

      notifier.state = container.read(homeNotifierProvider).copyWith(
            isLoading: false,
            powerMonitorEnabled: true,
            dataSourceMode: DataSourceMode.real,
            viewMode: ScheduleViewMode.tomorrow,
            currentDisplaySchedule: forecastSchedule,
            realOutageIntervals: const [],
            historyVersions: const [],
            realHourSegments: sampleSegments,
            cachedIntervals: [
              IntervalInfo("00:00 - 24:00", "ON", "24г", Colors.green),
            ],
          );

      await tester.pumpAndSettle();

      // Must NOT show the missing URL message
      expect(
        find.text("URL бази даних не налаштовано. Перейдіть в Налаштування."),
        findsNothing,
      );

      // Must NOT show "Дані відсутні"
      expect(
        find.text("Дані відсутні"),
        findsNothing,
      );

      // Must show RealModeGridCell widgets (all 24 hours)
      expect(find.byType(RealModeGridCell), findsNWidgets(24));

      // Must show ScheduleIntervalsList
      expect(find.byType(ScheduleIntervalsList), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets(
        'In history mode with NO outages and NO history versions, renders "Дані відсутні" and hides ScheduleIntervalsList',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'selected_group': 'GPV2.1',
        'power_monitor_enabled': true,
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      final notifier = container.read(homeNotifierProvider.notifier);

      notifier.state = container.read(homeNotifierProvider).copyWith(
        isLoading: false,
        powerMonitorEnabled: true,
        dataSourceMode: DataSourceMode.real,
        viewMode: ScheduleViewMode.history,
        historyDate: DateTime(2024, 1, 1),
        realOutageIntervals: const [],
        historyVersions: const [],
        cachedIntervals: [
          IntervalInfo("00:00 - 24:00", "ON", "24г", Colors.green),
        ],
      );

      await tester.pumpAndSettle();

      // Must show "Дані відсутні"
      expect(find.text("Дані відсутні"), findsOneWidget);

      // Must NOT show intervals list
      expect(find.byType(ScheduleIntervalsList), findsNothing);

      await drainTimers(tester);
    });

    testWidgets(
        'In history mode with NO outages BUT active monitoring coverage (hasRealCoverage == true), renders green cells and intervals list',
        (tester) async {
      SharedPreferences.setMockInitialValues({
        'selected_group': 'GPV2.1',
        'power_monitor_enabled': true,
      });

      final container = ProviderContainer();
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      final notifier = container.read(homeNotifierProvider.notifier);

      final sampleSegments = List.generate(
        24,
        (i) => [
          const HourSegment(0, 1, Colors.green,
              status: LightStatus.on, isFuture: false)
        ],
      );

      notifier.state = container.read(homeNotifierProvider).copyWith(
            isLoading: false,
            powerMonitorEnabled: true,
            dataSourceMode: DataSourceMode.real,
            viewMode: ScheduleViewMode.yesterday,
            historyDate: DateTime(2026, 10, 2),
            realOutageIntervals: const [],
            historyVersions: const [],
            hasRealCoverage: true,
            realHourSegments: sampleSegments,
            cachedIntervals: [
              IntervalInfo("00:00 - 24:00", "ON", "24г", Colors.green),
            ],
          );

      await tester.pumpAndSettle();

      // Must NOT show "Дані відсутні"
      expect(find.text("Дані відсутні"), findsNothing);

      // Must show 24 RealModeGridCell
      expect(find.byType(RealModeGridCell), findsNWidgets(24));

      // Must show ScheduleIntervalsList
      expect(find.byType(ScheduleIntervalsList), findsOneWidget);

      await drainTimers(tester);
    });
  });
}
