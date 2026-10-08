import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/ui/widgets/home/data_source_toggle.dart';
import 'package:lumen/ui/widgets/home/emergency_alert_banner.dart';
import 'package:lumen/ui/widgets/home/power_status_badge.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<void> pumpNotice(WidgetTester tester,
      {double width = 900,
      double textScale = 1,
      bool monitorEnabled = true,
      bool stale = false,
      String powerStatus = 'online',
      ValueChanged<DataSourceMode>? onModeChanged}) async {
    tester.view.physicalSize = Size(width, 700);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(textScaler: TextScaler.linear(textScale)),
        child: Scaffold(
          body: Column(children: [
            DataSourceToggle(
              powerMonitorEnabled: monitorEnabled,
              currentMode: DataSourceMode.predicted,
              onModeChanged: onModeChanged ?? (_) {},
              powerStatus: powerStatus,
              leadingNotice:
                  EmergencyAlertBanner(isActive: true, isStale: stale),
            ),
          ]),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  for (final status in ['online', 'offline', 'unknown']) {
    testWidgets('notice sits left of centered controls with $status power',
        (tester) async {
      DataSourceMode? selectedMode;
      await pumpNotice(tester,
          powerStatus: status, onModeChanged: (mode) => selectedMode = mode);
      final notice = tester.getRect(find.byType(EmergencyAlertBanner));
      final forecast =
          tester.getRect(find.widgetWithText(ChoiceChip, '📋 Прогноз'));
      final real = tester.getRect(find.widgetWithText(ChoiceChip, '⚡ Реальне'));
      final badge = tester.getRect(find.byType(PowerStatusBadge));
      expect((forecast.left + real.right) / 2, closeTo(450, 0.01));
      expect(notice.left, 16);
      expect(notice.right, lessThan(forecast.left));
      expect(notice.center.dy, closeTo(real.center.dy, 0.01));
      expect(badge.left, greaterThan(real.right));
      expect(badge.right, lessThanOrEqualTo(884));
      expect(
          tester.getSize(find.byType(DataSourceToggle)).height, lessThan(350));
      expect(tester.takeException(), null);

      await tester.tap(find.widgetWithText(ChoiceChip, '⚡ Реальне'));
      expect(selectedMode, DataSourceMode.real);
      selectedMode = null;
      await tester.fling(find.widgetWithText(ChoiceChip, '📋 Прогноз'),
          const Offset(-80, 0), 800);
      expect(selectedMode, DataSourceMode.real);
      await tester.tap(find.byType(PowerStatusBadge));
      await tester.pump();
      expect(find.byType(SnackBar), findsOneWidget);
    });
  }

  for (final scenario in [
    (width: 360.0, textScale: 1.0),
    (width: 320.0, textScale: 2.0),
    (width: 900.0, textScale: 2.0),
  ]) {
    testWidgets('notice stacks without clipping at $scenario', (tester) async {
      await pumpNotice(tester,
          width: scenario.width, textScale: scenario.textScale, stale: true);
      final notice = tester.getRect(find.byType(EmergencyAlertBanner));
      for (final finder in [
        find.widgetWithText(ChoiceChip, '📋 Прогноз'),
        find.widgetWithText(ChoiceChip, '⚡ Реальне'),
        find.byType(PowerStatusBadge),
      ]) {
        final rect = tester.getRect(finder);
        expect(rect.top, greaterThanOrEqualTo(notice.bottom));
        expect(rect.left, greaterThanOrEqualTo(16));
        expect(rect.right, lessThanOrEqualTo(scenario.width - 16));
      }
      expect(notice.width, lessThanOrEqualTo(280));
      expect(find.text('Не вдалося отримати актуальні дані'), findsOneWidget);
      expect(tester.takeException(), null);
    });
  }

  testWidgets('notice remains visible with monitoring disabled',
      (tester) async {
    await pumpNotice(tester, monitorEnabled: false);
    expect(find.text('Зараз діють екстрені відключення'), findsOneWidget);
    expect(find.byType(ChoiceChip), findsNothing);
    expect(find.byType(PowerStatusBadge), findsNothing);
    expect(tester.getRect(find.byType(EmergencyAlertBanner)).left, 16);
    expect(tester.takeException(), null);
  });

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
