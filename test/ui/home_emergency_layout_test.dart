import 'dart:io';
import '../helpers/idle_app_update_notifier.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/models/app_update_info.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/ui/home_screen.dart';
import 'package:lumen/ui/state/home_notifier.dart';
import 'package:lumen/ui/state/app_update_notifier.dart';
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

class _AvailableUpdateNotifier extends IdleAppUpdateNotifier {
  @override
  AppUpdateState build() => const AppUpdateState(
        status: AppUpdateStatus.available,
        updateInfo: AppUpdateInfo(
          currentVersion: '1.2.1',
          latestVersion: '1.3.0',
          releaseTitle: 'Lumen v1.3.0',
          releaseNotes: 'Release notes',
          releaseUrl:
              'https://github.com/maksim0-debug/Lumen/releases/tag/v1.3.0',
          hasUpdate: true,
        ),
      );
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
      bool includeAppBar = false,
      double textScale = 1,
      bool emergency = true,
      Brightness brightness = Brightness.dark}) async {
    tester.view.physicalSize = const Size(1000, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final container = ProviderContainer(overrides: [
      homeNotifierProvider.overrideWith(() =>
          _LayoutHomeNotifier(monitoring: monitoring, emergency: emergency)),
      appUpdateProvider.overrideWith(includeAppBar
          ? _AvailableUpdateNotifier.new
          : IdleAppUpdateNotifier.new),
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
    // Keep body layout coverage isolated from the toolbar. Dedicated cases
    // below exercise the full toolbar with an available update.
    final scaffold = tester.widget<Scaffold>(find.byType(Scaffold));
    final body = scaffold.body!;
    tester.view.physicalSize = size;
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: ThemeData(brightness: brightness, platform: platform),
        home: Builder(
            builder: (context) => MediaQuery(
                  data: MediaQuery.of(context)
                      .copyWith(textScaler: TextScaler.linear(textScale)),
                  child:
                      includeAppBar ? const HomeScreen() : Scaffold(body: body),
                )),
      ),
    ));
    await tester.pump();
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  for (final width in [320.0, 375.0]) {
    testWidgets('home toolbar fits with an available update at width $width',
        (tester) async {
      await pumpHome(tester,
          platform: TargetPlatform.android,
          size: Size(width, 812),
          monitoring: false,
          textScale: 1.5,
          includeAppBar: true);
      expect(tester.takeException(), isNull);
      expect(find.byType(DropdownButton<String>), findsOneWidget);
      expect(find.byTooltip('Доступне оновлення Lumen v1.3.0'), findsOneWidget);
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
