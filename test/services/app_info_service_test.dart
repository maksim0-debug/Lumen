import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:lumen/services/app_info_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    AppInfoService.setMockPackageInfo(null);
  });

  tearDown(() {
    AppInfoService.setMockPackageInfo(null);
  });

  group('AppInfoService Tests', () {
    test('returns formatted version string with build number', () async {
      AppInfoService.setMockPackageInfo(
        PackageInfo(
          appName: 'Lumen',
          packageName: 'lumen',
          version: '2.92.18',
          buildNumber: '19',
          buildSignature: '',
        ),
      );

      final version = await AppInfoService.getAppVersion();
      expect(version, equals('2.92.18+19'));
    });

    test('returns version string without build number if build number is empty',
        () async {
      AppInfoService.setMockPackageInfo(
        PackageInfo(
          appName: 'Lumen',
          packageName: 'lumen',
          version: '2.92.18',
          buildNumber: '',
          buildSignature: '',
        ),
      );

      final version = await AppInfoService.getAppVersion();
      expect(version, equals('2.92.18'));
    });

    test(
        'does not duplicate plus sign if version already contains build number',
        () async {
      AppInfoService.setMockPackageInfo(
        PackageInfo(
          appName: 'Lumen',
          packageName: 'lumen',
          version: '2.92.18+19',
          buildNumber: '19',
          buildSignature: '',
        ),
      );

      final version = await AppInfoService.getAppVersion();
      expect(version, equals('2.92.18+19'));
    });

    test('caches package info on repeated calls', () async {
      final info = PackageInfo(
        appName: 'Lumen',
        packageName: 'lumen',
        version: '1.0.0',
        buildNumber: '1',
        buildSignature: '',
      );
      AppInfoService.setMockPackageInfo(info);

      final retrieved1 = await AppInfoService.getPackageInfo();
      final retrieved2 = await AppInfoService.getPackageInfo();

      expect(identical(retrieved1, retrieved2), isTrue);
    });

    test('returns fallback safe values when platform channel fails', () async {
      // In flutter_test environment without platform mock set, PackageInfo.fromPlatform throws MissingPluginException
      // or times out, so AppInfoService should safely return fallback instead of throwing.
      final info = await AppInfoService.getPackageInfo();
      expect(info, isNotNull);
      expect(info.appName, isNotEmpty);

      final version = await AppInfoService.getAppVersion();
      expect(version, isNotEmpty);
    });

    test(
        'caches fallback safe values on subsequent calls when platform channel fails',
        () async {
      final info1 = await AppInfoService.getPackageInfo();
      final info2 = await AppInfoService.getPackageInfo();
      expect(identical(info1, info2), isTrue);
    });

    test(
        'handles concurrent getPackageInfo calls gracefully without duplicate requests',
        () async {
      final results = await Future.wait([
        AppInfoService.getPackageInfo(),
        AppInfoService.getPackageInfo(),
      ]);
      expect(identical(results[0], results[1]), isTrue);
    });
  });
}
