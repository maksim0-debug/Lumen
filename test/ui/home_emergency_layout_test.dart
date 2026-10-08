import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/ui/home_screen.dart';
import 'package:lumen/ui/state/home_notifier.dart';
import 'package:lumen/ui/widgets/home/countdown_card.dart';
import 'package:lumen/ui/widgets/home/data_source_toggle.dart';
import 'package:lumen/ui/widgets/home/emergency_alert_banner.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class _TestPathProvider extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String path;
  _TestPathProvider(this.path);

  @override
  Future<String?> getApplicationDocumentsPath() async => path;
}

class _LayoutHomeNotifier extends HomeNotifier {
  final bool monitoring;
  final bool emergency;
  _LayoutHomeNotifier({required this.monitoring, required this.emergency});

  @override
  HomeState build() {
    super.build();
    return HomeState(
      isLoading: false,
      statusMessage: 'Оновлено ДТЕК: 08.10 20:42',
      powerMonitorEnabled: monitoring,
      isEmergencyActive: emergency,
      isEmergencyPossible: true,
      emergencyNoticeText: 'Повний текст повідомлення ДТЕК.',
    );
  }

  @override
  Future<void> loadPreferencesAndData() async {}

  @override
  Future<void> initPowerMonitor() async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tempDir;

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    tempDir = await Directory.systemTemp.createTemp('lumen_emergency_layout_');
    PathProviderPlatform.instance = _TestPathProvider(tempDir.path);
    await AchievementService().loadAllStates();
  });

  tearDownAll(() async {
    await HistoryService().close();
    await tempDir.delete(recursive: true);
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
            const MethodChannel('tray_manager'), (_) async => null);
  });

  Future<void> pumpHome(WidgetTester tester,
      {required TargetPlatform platform,
      required Size size,
      required bool monitoring,
      bool emergency = true,
      Brightness brightness = Brightness.dark}) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(overrides: [
      homeNotifierProvider.overrideWith(() =>
          _LayoutHomeNotifier(monitoring: monitoring, emergency: emergency)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness, platform: platform),
        home: const HomeScreen(),
      ),
    ));
    await tester.pump();
    // Exercise the actual home body separately from the unrelated app bar,
    // whose group title overflows with Flutter's square test font on phones.
    final body = tester.widget<Scaffold>(find.byType(Scaffold)).body!;
    tester.view.physicalSize = size;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness, platform: platform),
        home: Scaffold(body: body),
      ),
    ));
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    for (final size in [
      const Size(320, 640),
      const Size(375, 812),
      const Size(430, 932),
      const Size(900, 430),
    ]) {
      for (final monitoring in [false, true]) {
        for (final brightness in Brightness.values) {
          testWidgets(
              'mobile notice follows update time: $platform $size monitoring=$monitoring $brightness',
              (tester) async {
            await pumpHome(tester,
                platform: platform,
                size: size,
                monitoring: monitoring,
                brightness: brightness);
            final banner = find.byType(EmergencyAlertBanner);
            expect(banner, findsOneWidget);
            final toggle =
                tester.widget<DataSourceToggle>(find.byType(DataSourceToggle));
            expect(toggle.leadingNotice, isNull);
            final updateRect =
                tester.getRect(find.text('Оновлено ДТЕК: 08.10 20:42'));
            final bannerRect = tester.getRect(banner);
            expect(bannerRect.top, greaterThanOrEqualTo(updateRect.bottom));
            expect(
                bannerRect.bottom,
                lessThanOrEqualTo(
                    tester.getTopLeft(find.byType(CountdownCard)).dy));
            expect(bannerRect.center.dx, closeTo(size.width / 2, 1));
            expect(bannerRect.left, greaterThanOrEqualTo(0));
            expect(bannerRect.right, lessThanOrEqualTo(size.width));
            expect(tester.takeException(), isNull);

            await tester.tap(banner);
            await tester.pumpAndSettle();
            expect(find.byType(AlertDialog), findsOneWidget);
            expect(
                tester.widget<SelectableText>(find.byType(SelectableText)).data,
                'Повний текст повідомлення ДТЕК.');
            await tester.tap(find.text('Закрити'));
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
          });
        }
      }
    }
  }

  for (final platform in [
    TargetPlatform.windows,
    TargetPlatform.linux,
    TargetPlatform.macOS,
  ]) {
    for (final width in [420.0, 886.0]) {
      for (final monitoring in [false, true]) {
        testWidgets(
            'desktop notice stays in toggle: $platform width=$width monitoring=$monitoring',
            (tester) async {
          await pumpHome(tester,
              platform: platform,
              size: Size(width, 800),
              monitoring: monitoring);
          expect(find.byType(EmergencyAlertBanner), findsOneWidget);
          expect(
              find.descendant(
                  of: find.byType(DataSourceToggle),
                  matching: find.byType(EmergencyAlertBanner)),
              findsOneWidget);
          expect(
              tester.getBottomLeft(find.byType(EmergencyAlertBanner)).dy,
              lessThanOrEqualTo(tester
                  .getTopLeft(find.text('Оновлено ДТЕК: 08.10 20:42'))
                  .dy));
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('inactive mobile notice leaves no banner', (tester) async {
    await pumpHome(tester,
        platform: TargetPlatform.android,
        size: const Size(375, 812),
        monitoring: true,
        emergency: false);
    expect(find.byType(EmergencyAlertBanner), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
