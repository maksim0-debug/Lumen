import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/services/app_info_service.dart';
import 'package:lumen/ui/settings_page.dart';
import 'package:lumen/models/app_update_info.dart';
import 'package:lumen/ui/state/app_update_notifier.dart';

class _SkippedUpdateNotifier extends AppUpdateNotifier {
  @override
  AppUpdateState build() => const AppUpdateState(
        status: AppUpdateStatus.available,
        isIgnored: true,
        updateInfo: AppUpdateInfo(
          currentVersion: '1.2.1',
          latestVersion: '1.3.0',
          releaseTitle: 'Lumen',
          releaseNotes: '',
          releaseUrl:
              'https://github.com/maksim0-debug/Lumen/releases/tag/v1.3.0',
          hasUpdate: true,
        ),
      );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues(
        {'settings_card_update_expanded': true});
    AppInfoService.setMockPackageInfo(
      PackageInfo(
        appName: 'Lumen',
        packageName: 'lumen',
        version: '1.2.1',
        buildNumber: '10',
        buildSignature: '',
      ),
    );
  });

  tearDown(() {
    AppInfoService.setMockPackageInfo(null);
  });

  testWidgets('ignored release is visibly skipped and remains accessible',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {'settings_card_update_expanded': true});
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(ProviderScope(
      overrides: [appUpdateProvider.overrideWith(_SkippedUpdateNotifier.new)],
      child: const MaterialApp(home: SettingsPage()),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Версію v1.3.0 пропущено'), findsWidgets);
    expect(find.text('Доступне оновлення: v1.3.0'), findsNothing);
    expect(find.byIcon(Icons.notifications_off_outlined), findsOneWidget);
    final tile = tester.widget<ListTile>(find.ancestor(
        of: find.byIcon(Icons.notifications_off_outlined),
        matching: find.byType(ListTile)));
    expect(tile.onTap, isNotNull);
  });

  testWidgets(
      'SettingsPage renders dynamic app version from pubspec/AppInfoService',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const ProviderScope(
          child: MaterialApp(
        home: SettingsPage(),
      )),
    );

    // Allow async _loadSettings to complete
    await tester.pump();
    await tester.pumpAndSettle();

    final versionFinder = find.text('Lumen v1.2.1+10');
    expect(versionFinder, findsOneWidget);
    // Local metadata is displayed with an idle updater and no release request.
    expect(find.text('Поточна версія: v1.2.1+10'), findsOneWidget);

    final authorFinder = find.text('Розробник: @maksim0-debug');
    expect(authorFinder, findsOneWidget);
  });
}
