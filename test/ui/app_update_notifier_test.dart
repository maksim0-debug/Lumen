import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/services/app_info_service.dart';
import 'package:lumen/services/app_update_service.dart';
import 'package:lumen/ui/state/app_update_notifier.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

http.Response release(String version) => http.Response(
      jsonEncode({
        'tag_name': 'v$version',
        'html_url':
            'https://github.com/maksim0-debug/Lumen/releases/tag/v$version',
      }),
      200,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    AppInfoService.setMockPackageInfo(PackageInfo(
      appName: 'Lumen',
      packageName: 'ua.maksim0.lumen',
      version: '1.2.1',
      buildNumber: '11',
    ));
  });

  tearDown(() => AppInfoService.setMockPackageInfo(null));

  test('explicit null clears an error instead of retaining stale state', () {
    expect(
      const AppUpdateState(errorMessage: 'old')
          .copyWith(errorMessage: null)
          .errorMessage,
      isNull,
    );
  });

  test('startup check cannot overwrite a subsequent manual result', () async {
    final prefs = await SharedPreferences.getInstance();
    final first = Completer<http.Response>();
    final entered = Completer<void>();
    var requests = 0;
    final service = AppUpdateService(
      prefs: prefs,
      httpClient: MockClient((_) {
        requests++;
        if (requests == 1) {
          entered.complete();
          return first.future;
        }
        return Future.value(release('1.4.0'));
      }),
    );
    final container = ProviderContainer(overrides: [
      appUpdateServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(() {
      container.dispose();
      service.dispose();
    });
    final notifier = container.read(appUpdateProvider.notifier);
    final startup = notifier.checkSilently();
    await entered.future;
    final manual = notifier.checkManually();
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1, reason: 'Manual refresh waits for startup to finish');
    first.complete(release('1.3.0'));
    await Future.wait([startup, manual]);
    expect(
        container.read(appUpdateProvider).updateInfo!.latestVersion, '1.4.0');
    expect(
      jsonDecode(prefs.getString(AppUpdateService.prefCachedReleaseJson)!)[
          'latestVersion'],
      '1.4.0',
    );
  });

  test('rate limit blocks a second silent request without a cached release',
      () async {
    var requests = 0;
    final service = AppUpdateService(
      prefs: await SharedPreferences.getInstance(),
      httpClient: MockClient((_) async {
        requests++;
        return http.Response('rate limit', 403);
      }),
    );
    addTearDown(service.dispose);
    await service.checkForUpdate();
    await service.checkForUpdate();
    expect(requests, 1);
  });

  test('malformed tags are not treated as semantic versions', () {
    expect(AppUpdateService.isVersionGreater('2.invalid', '1.2.1'), isFalse);
  });

  test('ignoring a version does not hide the next silent update', () async {
    final prefs = await SharedPreferences.getInstance();
    var version = '1.3.0';
    final service = AppUpdateService(
      prefs: prefs,
      httpClient: MockClient((_) async => release(version)),
    );
    final container = ProviderContainer(overrides: [
      appUpdateServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(() {
      container.dispose();
      service.dispose();
    });
    final notifier = container.read(appUpdateProvider.notifier);
    await notifier.checkSilently();
    expect(await notifier.ignoreVersion('v1.3.0'), isTrue);
    await notifier.checkSilently();
    expect(container.read(appUpdateProvider).shouldShowBadge, isFalse);
    version = '1.4.0';
    await prefs.setInt(AppUpdateService.prefLastCheckMs, 0);
    await notifier.checkSilently();
    expect(container.read(appUpdateProvider).isIgnored, isFalse);
    expect(container.read(appUpdateProvider).isBadgeDismissed, isFalse);
    expect(container.read(appUpdateProvider).shouldShowBadge, isTrue);
  });

  test('a failed refresh preserves the known update and recovery clears error',
      () async {
    var fail = false;
    final service = AppUpdateService(
      prefs: await SharedPreferences.getInstance(),
      httpClient: MockClient(
          (_) async => fail ? http.Response('offline', 503) : release('1.3.0')),
    );
    final container = ProviderContainer(overrides: [
      appUpdateServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(() {
      container.dispose();
      service.dispose();
    });
    final notifier = container.read(appUpdateProvider.notifier);
    await notifier.checkManually();
    fail = true;
    expect(await notifier.checkManually(), isNull);
    expect(container.read(appUpdateProvider).status, AppUpdateStatus.error);
    expect(container.read(appUpdateProvider).shouldShowBadge, isTrue);
    expect(
        container.read(appUpdateProvider).updateInfo!.latestVersion, '1.3.0');
    fail = false;
    await notifier.checkManually();
    expect(container.read(appUpdateProvider).errorMessage, isNull);
    expect(container.read(appUpdateProvider).status, AppUpdateStatus.available);
  });

  test('dismissal applies to its version and manual refresh resets it',
      () async {
    final service = AppUpdateService(
      prefs: await SharedPreferences.getInstance(),
      httpClient: MockClient((_) async => release('1.3.0')),
    );
    final container = ProviderContainer(overrides: [
      appUpdateServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(() {
      container.dispose();
      service.dispose();
    });
    final notifier = container.read(appUpdateProvider.notifier);
    await notifier.checkManually();
    notifier.dismissBadge('1.2.9');
    expect(container.read(appUpdateProvider).shouldShowBadge, isTrue);
    notifier.dismissBadge('1.3.0');
    expect(container.read(appUpdateProvider).shouldShowBadge, isFalse);
    await notifier.checkSilently();
    expect(container.read(appUpdateProvider).shouldShowBadge, isFalse);
    await notifier.checkManually();
    expect(container.read(appUpdateProvider).shouldShowBadge, isTrue);
  });

  test('multiple manual clicks join one active check', () async {
    var requests = 0;
    final pending = Completer<http.Response>();
    final service = AppUpdateService(
      prefs: await SharedPreferences.getInstance(),
      httpClient: MockClient((_) {
        requests++;
        return pending.future;
      }),
    );
    final container = ProviderContainer(overrides: [
      appUpdateServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(() {
      container.dispose();
      service.dispose();
    });
    final notifier = container.read(appUpdateProvider.notifier);
    final first = notifier.checkManually();
    final second = notifier.checkManually();
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    pending.complete(release('1.3.0'));
    final results = await Future.wait([first, second]);
    expect(results.first, results.last);
  });

  test('disposed provider does not publish a pending result', () async {
    final pending = Completer<http.Response>();
    final entered = Completer<void>();
    final service = AppUpdateService(
      prefs: await SharedPreferences.getInstance(),
      httpClient: MockClient((_) {
        entered.complete();
        return pending.future;
      }),
    );
    final container = ProviderContainer(overrides: [
      appUpdateServiceProvider.overrideWithValue(service),
    ]);
    addTearDown(service.dispose);
    final check = container.read(appUpdateProvider.notifier).checkManually();
    await entered.future;
    container.dispose();
    pending.complete(release('1.3.0'));
    expect(await check, isNull);
  });
}
