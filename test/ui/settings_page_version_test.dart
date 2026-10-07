import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/services/app_info_service.dart';
import 'package:lumen/ui/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppInfoService.setMockPackageInfo(
      PackageInfo(
        appName: 'Lumen',
        packageName: 'lumen',
        version: '2.92.18',
        buildNumber: '19',
        buildSignature: '',
      ),
    );
  });

  tearDown(() {
    AppInfoService.setMockPackageInfo(null);
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

    final versionFinder = find.text('Lumen v2.92.18+19');
    expect(versionFinder, findsOneWidget);

    final authorFinder = find.text('Розробник: @maksim0-debug');
    expect(authorFinder, findsOneWidget);
  });
}
