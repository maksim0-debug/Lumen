import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/ui/widgets/home/data_source_toggle.dart';
import 'package:lumen/ui/widgets/home/power_status_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'DataSourceToggle: Forecast and Real buttons stay strictly centered regardless of powerStatus',
      (WidgetTester tester) async {
    const screenWidth = 900.0;
    const screenHeight = 600.0;
    tester.view.physicalSize = const Size(screenWidth, screenHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    double getChipsCenter() {
      final forecastRect =
          tester.getRect(find.widgetWithText(ChoiceChip, '📋 Прогноз'));
      final realRect =
          tester.getRect(find.widgetWithText(ChoiceChip, '⚡ Реальне'));
      return (forecastRect.left + realRect.right) / 2.0;
    }

    // 1. Render with 'online' (ON badge)
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataSourceToggle(
            powerMonitorEnabled: true,
            currentMode: DataSourceMode.predicted,
            onModeChanged: (_) {},
            powerStatus: 'online',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final centerOnline = getChipsCenter();

    // 2. Render with 'unknown' (compact N/A badge)
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataSourceToggle(
            powerMonitorEnabled: true,
            currentMode: DataSourceMode.predicted,
            onModeChanged: (_) {},
            powerStatus: 'unknown',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final centerUnknown = getChipsCenter();

    // 3. Render with 'offline' (OFF badge)
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataSourceToggle(
            powerMonitorEnabled: true,
            currentMode: DataSourceMode.predicted,
            onModeChanged: (_) {},
            powerStatus: 'offline',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final centerOffline = getChipsCenter();

    // The chips center must be at screenWidth / 2 (450.0) in all states
    expect(centerOnline, closeTo(screenWidth / 2, 1.0),
        reason: 'Forecast/Real chips must be centered when status is online');
    expect(centerUnknown, closeTo(screenWidth / 2, 1.0),
        reason: 'Forecast/Real chips must be centered when status is unknown');
    expect(centerOffline, closeTo(screenWidth / 2, 1.0),
        reason: 'Forecast/Real chips must be centered when status is offline');

    // Position of buttons must not shift when status changes
    expect(centerOnline, closeTo(centerUnknown, 0.01),
        reason: 'Buttons must not shift between online and unknown');
    expect(centerUnknown, closeTo(centerOffline, 0.01),
        reason: 'Buttons must not shift between unknown and offline');

    // PowerStatusBadge must be to the right of the 'Реальне' button
    final realRect =
        tester.getRect(find.widgetWithText(ChoiceChip, '⚡ Реальне'));
    final visibleBadge = find.byType(PowerStatusBadge).last;
    final badgeRect = tester.getRect(visibleBadge);
    expect(badgeRect.left, greaterThan(realRect.right),
        reason: 'Status badge must be positioned to the right of Real button');
  });

  testWidgets('DataSourceToggle: buttons and badge are interactive',
      (WidgetTester tester) async {
    DataSourceMode? selectedMode;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataSourceToggle(
            powerMonitorEnabled: true,
            currentMode: DataSourceMode.predicted,
            onModeChanged: (mode) => selectedMode = mode,
            powerStatus: 'online',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // Tap on Real mode chip
    await tester.tap(find.widgetWithText(ChoiceChip, '⚡ Реальне'));
    await tester.pumpAndSettle();
    expect(selectedMode, DataSourceMode.real);

    // Tap on PowerStatusBadge opens SnackBar
    final visibleBadge = find.byType(PowerStatusBadge).last;
    await tester.tap(visibleBadge);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets(
      'DataSourceToggle: on mobile screens (360dp) elements fit and badge is visible without offscreen cutoff',
      (WidgetTester tester) async {
    const mobileWidth = 360.0;
    const mobileHeight = 700.0;
    tester.view.physicalSize = const Size(mobileWidth, mobileHeight);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataSourceToggle(
            powerMonitorEnabled: true,
            currentMode: DataSourceMode.predicted,
            onModeChanged: (_) {},
            powerStatus: 'online',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    final forecastRect =
        tester.getRect(find.widgetWithText(ChoiceChip, '📋 Прогноз'));
    final realRect =
        tester.getRect(find.widgetWithText(ChoiceChip, '⚡ Реальне'));
    final visibleBadge = find.byType(PowerStatusBadge).last;
    final badgeRect = tester.getRect(visibleBadge);

    expect(forecastRect.left, lessThan(100.0),
        reason: 'Forecast chip should not have massive phantom offset');
    expect(badgeRect.left, greaterThan(realRect.right),
        reason: 'Badge must be positioned to the right of Real chip');
    expect(find.byType(SingleChildScrollView), findsOneWidget,
        reason:
            'SingleChildScrollView protects against RenderFlex overflow on mobile');
  });
}
