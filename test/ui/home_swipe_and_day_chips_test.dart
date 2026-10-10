import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/ui/home_screen.dart';
import 'package:lumen/ui/state/app_update_notifier.dart';
import '../helpers/idle_app_update_notifier.dart';
import 'package:lumen/ui/state/home_notifier.dart';
import 'package:lumen/ui/widgets/home/data_source_toggle.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => '.';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PathProviderPlatform.instance = MockPathProviderPlatform();
    await AchievementService().loadAllStates();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'selected_group': 'GPV1.1',
      'power_monitor_enabled': false,
    });
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

  group('HomeScreen Day Chips & Swipe Navigation Tests', () {
    testWidgets(
        'ChoiceChip "Вчора" is removed; only "Минуле", "Сьогодні", "Завтра" exist',
        (tester) async {
      final container = ProviderContainer(overrides: [
        appUpdateProvider.overrideWith(IdleAppUpdateNotifier.new)
      ]);
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      expect(find.widgetWithText(ChoiceChip, 'Вчора'), findsNothing);
      expect(find.widgetWithText(ChoiceChip, 'Минуле'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Сьогодні'), findsOneWidget);
      expect(find.widgetWithText(ChoiceChip, 'Завтра'), findsOneWidget);

      await drainTimers(tester);
    });

    testWidgets('When viewMode is yesterday, "Минуле" chip is selected',
        (tester) async {
      final container = ProviderContainer(overrides: [
        appUpdateProvider.overrideWith(IdleAppUpdateNotifier.new)
      ]);
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      container.read(homeNotifierProvider.notifier).state =
          container.read(homeNotifierProvider).copyWith(
                viewMode: ScheduleViewMode.yesterday,
              );

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      final pastChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Минуле'),
      );
      final todayChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Сьогодні'),
      );
      final tomorrowChip = tester.widget<ChoiceChip>(
        find.widgetWithText(ChoiceChip, 'Завтра'),
      );

      expect(pastChip.selected, isTrue);
      expect(todayChip.selected, isFalse);
      expect(tomorrowChip.selected, isFalse);

      await drainTimers(tester);
    });

    testWidgets(
        'Swiping left (<-) advances day forward, swiping right (->) moves day backward',
        (tester) async {
      final container = ProviderContainer(overrides: [
        appUpdateProvider.overrideWith(IdleAppUpdateNotifier.new)
      ]);
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Start on today
      container.read(homeNotifierProvider.notifier).state =
          container.read(homeNotifierProvider).copyWith(
                viewMode: ScheduleViewMode.today,
              );

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.today));

      // 1. Swipe Left (<-) from right to left -> Should go forward to tomorrow
      await tester.fling(find.byType(Scaffold), const Offset(-300, 0), 1000);
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.tomorrow));

      // 2. Swipe Right (->) from left to right -> Should go backward to today
      await tester.fling(find.byType(Scaffold), const Offset(300, 0), 1000);
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.today));

      // 3. Swipe Right (->) again -> Should go backward to yesterday
      await tester.fling(find.byType(Scaffold), const Offset(300, 0), 1000);
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.yesterday));

      await drainTimers(tester);
    });

    testWidgets(
        'Swiping over DataSourceToggle switches DataSourceMode and preserves ScheduleViewMode',
        (tester) async {
      final container = ProviderContainer(overrides: [
        appUpdateProvider.overrideWith(IdleAppUpdateNotifier.new)
      ]);
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Enable power monitor so DataSourceToggle is rendered
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('power_monitor_enabled', true);
      container.read(homeNotifierProvider.notifier).state =
          container.read(homeNotifierProvider).copyWith(
                powerMonitorEnabled: true,
                dataSourceMode: DataSourceMode.predicted,
                viewMode: ScheduleViewMode.today,
              );

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.predicted));
      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.today));

      // 1. Swipe Left (<-) over DataSourceToggle -> Should switch to Real, day remains today
      await tester.fling(
          find.byType(DataSourceToggle), const Offset(-200, 0), 1000);
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.real));
      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.today));

      // 2. Swipe Right (->) over DataSourceToggle -> Should switch back to Predicted, day remains today
      await tester.fling(
          find.byType(DataSourceToggle), const Offset(200, 0), 1000);
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.predicted));
      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.today));

      await drainTimers(tester);
    });

    testWidgets(
        'Slow drag over DataSourceToggle switches DataSourceMode without high fling velocity',
        (tester) async {
      final container = ProviderContainer(overrides: [
        appUpdateProvider.overrideWith(IdleAppUpdateNotifier.new)
      ]);
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('power_monitor_enabled', true);
      container.read(homeNotifierProvider.notifier).state =
          container.read(homeNotifierProvider).copyWith(
                powerMonitorEnabled: true,
                dataSourceMode: DataSourceMode.predicted,
                viewMode: ScheduleViewMode.today,
              );

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.predicted));

      // Slow drag left by -80px -> switches to Real
      await tester.drag(find.byType(DataSourceToggle), const Offset(-80, 0));
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.real));

      // Slow drag right by 80px -> switches back to Predicted
      await tester.drag(find.byType(DataSourceToggle), const Offset(80, 0));
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.predicted));

      await drainTimers(tester);
    });

    testWidgets(
        'Slow drag (without high fling velocity) advances day forward and backward based on distance',
        (tester) async {
      final container = ProviderContainer(overrides: [
        appUpdateProvider.overrideWith(IdleAppUpdateNotifier.new)
      ]);
      addTearDown(container.dispose);

      tester.view.physicalSize = const Size(800, 1000);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      // Start on today
      container.read(homeNotifierProvider.notifier).state =
          container.read(homeNotifierProvider).copyWith(
                viewMode: ScheduleViewMode.today,
              );

      await tester.pumpWidget(buildTestApp(container));
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.today));

      // 1. Slow drag Left (<-) by -100px -> Should advance to tomorrow
      await tester.drag(find.byType(Scaffold), const Offset(-100, 0));
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.tomorrow));

      // 2. Slow drag Right (->) by 100px -> Should go back to today
      await tester.drag(find.byType(Scaffold), const Offset(100, 0));
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.today));

      // 3. Small drag below threshold (30px) should NOT change day
      await tester.drag(find.byType(Scaffold), const Offset(-30, 0));
      await pumpHome(tester);

      expect(container.read(homeNotifierProvider).viewMode,
          equals(ScheduleViewMode.today));

      await drainTimers(tester);
    });
  });
}
