import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/app_info_service.dart';
import 'package:lumen/services/power_monitor_service.dart';
import 'package:lumen/services/windows_startup_service.dart';
import 'package:lumen/ui/settings_page.dart';
import 'package:lumen/ui/widgets/windows_startup_settings.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({'enable_logging': false});
    AppInfoService.setMockPackageInfo(PackageInfo(
      appName: 'Lumen',
      packageName: 'lumen',
      version: '1.4.0',
      buildNumber: '15',
    ));
    binding.defaultBinaryMessenger.setMockMethodCallHandler(
        WindowsStartupService.channel, (_) async => 'disabled');
  });

  tearDown(() {
    AppInfoService.setMockPackageInfo(null);
    PowerMonitorService().stopPolling();
    binding.defaultBinaryMessenger
        .setMockMethodCallHandler(WindowsStartupService.channel, null);
  });

  for (final platform in TargetPlatform.values) {
    testWidgets('startup settings visibility on ${platform.name}',
        (tester) async {
      await tester.pumpWidget(
          const ProviderScope(child: MaterialApp(home: SettingsPage())));
      await tester.pumpAndSettle();
      expect(find.byType(WindowsStartupSettings),
          platform == TargetPlatform.windows ? findsOneWidget : findsNothing);
      if (platform == TargetPlatform.windows) {
        expect(find.text('Автозапуск разом із Windows'), findsOneWidget);
        expect(find.text('У треї'), findsOneWidget);
        expect(find.text('Згорнуто на панелі завдань'), findsOneWidget);
      }
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    }, variant: TargetPlatformVariant.only(platform));
  }
}
