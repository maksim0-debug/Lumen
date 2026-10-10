import 'dart:async';
import 'dart:convert';
import 'dart:io' show HttpDate;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:lumen/models/app_update_info.dart';
import 'package:lumen/services/app_info_service.dart';
import 'package:lumen/services/app_update_service.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';

class _RejectWrites extends InMemorySharedPreferencesStore {
  _RejectWrites() : super.empty();
  @override
  Future<bool> setValue(String valueType, String key, Object value) async =>
      false;
}

class _Launcher extends UrlLauncherPlatform {
  bool called = false;
  @override
  get linkDelegate => null;
  @override
  Future<bool> canLaunch(String url) async => false;
  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    called = true;
    expect(options.mode, PreferredLaunchMode.externalApplication);
    return true;
  }
}

class _WaitingClient extends http.BaseClient {
  final entered = Completer<void>();
  bool aborted = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    entered.complete();
    await (request as http.Abortable).abortTrigger;
    aborted = true;
    throw http.RequestAbortedException(request.url);
  }
}

class _ChunkClient extends http.BaseClient {
  bool cancelled = false;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final stream = StreamController<List<int>>();
    stream.onCancel = () => cancelled = true;
    stream.onListen = () {
      stream.add(List.filled(AppUpdateService.maxResponseBytes, 32));
      stream.add([32]);
      unawaited(stream.close());
    };
    return http.StreamedResponse(stream.stream, 200);
  }
}

Map<String, Object?> releaseJson(String version) => {
      'tag_name': 'v$version',
      'name': 'Lumen v$version',
      'body': 'Український опис ⚡',
      'html_url':
          'https://github.com/maksim0-debug/Lumen/releases/tag/v$version',
      'published_at': '2026-10-10T12:00:00Z',
      'draft': false,
      'prerelease': false,
    };

http.Response release(String version) =>
    http.Response.bytes(utf8.encode(jsonEncode(releaseJson(version))), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SharedPreferences prefs;
  late DateTime now;

  void installed(String version, [String build = '11']) {
    AppInfoService.setMockPackageInfo(PackageInfo(
        appName: 'Lumen',
        packageName: 'ua.maksim0.lumen',
        version: version,
        buildNumber: build));
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    now = DateTime.utc(2026, 10, 10, 12);
    installed('1.2.1');
  });
  tearDown(() => AppInfoService.setMockPackageInfo(null));

  AppUpdateService service(
      Future<http.Response> Function(http.Request) respond) {
    final result = AppUpdateService(
        prefs: prefs, now: () => now, httpClient: MockClient(respond));
    addTearDown(result.dispose);
    return result;
  }

  group('Semantic version precedence', () {
    for (final pair in [
      ('1.2.2', '1.2.1'),
      ('1.10.0', '1.9.9'),
      ('2.0.0', '1.99.99'),
      ('v1.3.0', 'V1.2.1+11'),
      ('1.3.0', '1.3.0-rc.1'),
      ('1.3.0-rc.2', '1.3.0-rc.1'),
      ('1.3.0-beta.11', '1.3.0-beta.2'),
    ]) {
      test('${pair.$1} is newer than ${pair.$2}', () {
        expect(AppUpdateService.isVersionGreater(pair.$1, pair.$2), isTrue);
        expect(AppUpdateService.isVersionGreater(pair.$2, pair.$1), isFalse);
      });
    }
    test('build metadata does not trigger reinstalling the same version', () {
      expect(
          AppUpdateService.isVersionGreater('1.2.1+15', '1.2.1+11'), isFalse);
      expect(AppUpdateService.isVersionGreater('1.2.1', 'v1.2.1'), isFalse);
    });
    for (final version in [
      '',
      'Unknown',
      '2.invalid',
      '1.2',
      '1.2.3.4',
      '1.2.3+'
    ]) {
      test('invalid version $version never claims an update', () {
        expect(AppUpdateService.isVersionGreater(version, '1.2.1'), isFalse);
        expect(AppUpdateService.isVersionGreater('2.0.0', version), isFalse);
      });
    }
    test('unknown fallback version is not treated as up to date', () async {
      installed('0.0.0', '');
      var requests = 0;
      final updater = service((_) async {
        requests++;
        return release('1.3.0');
      });
      expect(await updater.checkForUpdate(force: true), isNull);
      expect(requests, 0);
    });
  });

  test('only release metadata is fetched and UTF-8 is preserved', () async {
    var requests = 0;
    final updater = service((request) async {
      requests++;
      expect(request.url.path, '/repos/maksim0-debug/Lumen/releases/latest');
      expect(request.headers['X-GitHub-Api-Version'], '2026-03-10');
      return release('1.3.0');
    });
    final info = await updater.checkForUpdate();
    expect(info!.hasUpdate, isTrue);
    expect(info.releaseNotes, 'Український опис ⚡');
    expect(info.publishedAt, DateTime.utc(2026, 10, 10, 12));
    expect(requests, 1);
    expect(prefs.getInt(AppUpdateService.prefLastCheckMs),
        now.millisecondsSinceEpoch);
    expect(
        AppUpdateInfo.fromJson(jsonDecode(
            prefs.getString(AppUpdateService.prefCachedReleaseJson)!)),
        info);
    expect(info.toJson().containsKey('provenance'), isFalse);
  });

  test('cache is reused until expiry and manual refresh bypasses it', () async {
    var requests = 0;
    final updater = service((_) async {
      requests++;
      return release('1.3.0');
    });
    await updater.checkForUpdate();
    now = now.add(const Duration(hours: 23));
    expect((await updater.checkForUpdate())!.latestVersion, '1.3.0');
    expect(requests, 1);
    await updater.checkForUpdate(force: true);
    expect(requests, 2);
    now = now.add(AppUpdateService.checkInterval);
    await updater.checkForUpdate();
    expect(requests, 3);
  });

  test('installing a new version invalidates cache and recalculates update',
      () async {
    final updater = service((_) async => release('1.3.0'));
    await updater.checkForUpdate();
    installed('1.3.0', '20');
    expect((await updater.checkForUpdate())!.hasUpdate, isFalse);
  });

  test('cached build number is refreshed without a network request', () async {
    var requests = 0;
    final updater = service((_) async {
      requests++;
      return release('1.3.0');
    });
    await updater.checkForUpdate();
    installed('1.2.1', '22');
    expect((await updater.checkForUpdate())!.currentVersion, '1.2.1+22');
    expect(requests, 1);
  });

  test('legacy provenance cache is ignored and hasUpdate is recomputed',
      () async {
    await prefs.setInt(
        AppUpdateService.prefLastCheckMs, now.millisecondsSinceEpoch);
    await prefs.setString(
        AppUpdateService.prefCachedReleaseJson,
        jsonEncode({
          'currentVersion': '1.2.1+11',
          'latestVersion': '1.3.0',
          'hasUpdate': false,
          'releaseUrl':
              'https://github.com/maksim0-debug/Lumen/releases/tag/v1.3.0',
          'provenance': {'isVerified': true},
        }));
    final updater =
        service((_) async => throw StateError('Cache must be used'));
    expect((await updater.checkForUpdate())!.hasUpdate, isTrue);
  });

  test('corrupt cache does not prevent fetching a release', () async {
    await prefs.setInt(
        AppUpdateService.prefLastCheckMs, now.millisecondsSinceEpoch);
    await prefs.setString(AppUpdateService.prefCachedReleaseJson, '{broken');
    expect(
        (await service((_) async => release('1.3.0')).checkForUpdate())!
            .hasUpdate,
        isTrue);
  });

  test('wall-clock rollback does not make cache indefinitely fresh', () async {
    var requests = 0;
    final updater = service((_) async {
      requests++;
      return release('1.3.0');
    });
    await updater.checkForUpdate();
    now = now.subtract(const Duration(days: 1));
    await updater.checkForUpdate();
    expect(requests, 2);
  });

  test('concurrent forced and silent callers share one network request',
      () async {
    final response = Completer<http.Response>();
    final entered = Completer<void>();
    var requests = 0;
    final updater = service((_) {
      requests++;
      entered.complete();
      return response.future;
    });
    final first = updater.checkForUpdate();
    await entered.future;
    final second = updater.checkForUpdate(force: true);
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    response.complete(release('1.3.0'));
    final results = await Future.wait([first, second]);
    expect(results[0], results[1]);
    expect(results[0]!.latestVersion, '1.3.0');
  });

  for (final status in [403, 429]) {
    test('HTTP $status cooldown survives recreation without a cache', () async {
      var requests = 0;
      Future<http.Response> respond(http.Request _) async {
        requests++;
        return requests == 1
            ? http.Response('limit', status)
            : release('1.3.0');
      }

      await service(respond).checkForUpdate();
      final next = service(respond);
      expect(await next.checkForUpdate(), isNull);
      expect(await next.checkForUpdate(force: true), isNull);
      expect(requests, 1);
      now = now.add(AppUpdateService.rateLimitInterval);
      expect((await next.checkForUpdate())!.hasUpdate, isTrue);
      expect(requests, 2);
    });
  }

  for (final kind in ['seconds', 'date', 'reset']) {
    test('server cooldown uses $kind header', () async {
      var requests = 0;
      final deadline = now.add(const Duration(minutes: 2));
      final headers = switch (kind) {
        'seconds' => {'retry-after': '120'},
        'date' => {'retry-after': HttpDate.format(deadline)},
        _ => {
            'x-ratelimit-reset': '${deadline.millisecondsSinceEpoch ~/ 1000}'
          },
      };
      final updater = service((_) async {
        requests++;
        return requests == 1
            ? http.Response('limit', 429, headers: headers)
            : release('1.3.0');
      });
      await updater.checkForUpdate();
      now = deadline.subtract(const Duration(seconds: 1));
      expect(await updater.checkForUpdate(force: true), isNull);
      now = deadline;
      expect((await updater.checkForUpdate(force: true))!.hasUpdate, isTrue);
      expect(requests, 2);
    });
  }

  test('transient failures back off and recover once online', () async {
    var requests = 0;
    final updater = service((_) async {
      requests++;
      return requests == 1 ? http.Response('offline', 503) : release('1.3.0');
    });
    expect(await updater.checkForUpdate(), isNull);
    expect(await updater.checkForUpdate(), isNull);
    expect(requests, 1);
    now = now.add(AppUpdateService.retryInterval);
    expect((await updater.checkForUpdate())!.hasUpdate, isTrue);
  });

  test('manual refresh bypasses transient backoff', () async {
    var requests = 0;
    final updater = service((_) async {
      requests++;
      return requests == 1 ? http.Response('offline', 503) : release('1.3.0');
    });
    await updater.checkForUpdate();
    expect((await updater.checkForUpdate(force: true))!.hasUpdate, isTrue);
  });

  test('repeated failures use bounded exponential backoff and reset on success',
      () async {
    var failing = true;
    var requests = 0;
    final updater = service((_) async {
      requests++;
      return failing ? http.Response('offline', 503) : release('1.3.0');
    });
    for (final delay in [5, 10, 20, 40, 60, 60]) {
      expect(await updater.checkForUpdate(), isNull);
      final deadline = now.add(Duration(minutes: delay));
      expect(prefs.getInt(AppUpdateService.prefNextAttemptMs),
          deadline.millisecondsSinceEpoch);
      now = deadline.subtract(const Duration(seconds: 1));
      final previousRequests = requests;
      expect(await updater.checkForUpdate(), isNull);
      expect(requests, previousRequests);
      now = deadline;
    }
    failing = false;
    expect((await updater.checkForUpdate())!.hasUpdate, isTrue);
    expect(prefs.getInt(AppUpdateService.prefFailureCount), isNull);
    expect(prefs.getInt(AppUpdateService.prefNextAttemptMs), isNull);
    failing = true;
    expect(await updater.checkForUpdate(force: true), isNull);
    expect(prefs.getInt(AppUpdateService.prefNextAttemptMs),
        now.add(AppUpdateService.retryInterval).millisecondsSinceEpoch);
  });

  for (final override in [
    {'tag_name': '2.invalid'},
    {'tag_name': ''},
    {'tag_name': 'v1.3.0-beta'},
    {'draft': true},
    {'prerelease': true},
    {'html_url': 'https://example.com/release'},
    {'html_url': 'http://github.com/maksim0-debug/Lumen/releases/tag/v1.3.0'},
  ]) {
    test('invalid release $override is not cached as successful', () async {
      final updater = service((_) async => http.Response(
          jsonEncode({...releaseJson('1.3.0'), ...override}), 200));
      expect(await updater.checkForUpdate(), isNull);
      expect(prefs.getInt(AppUpdateService.prefLastCheckMs), isNull);
      expect(prefs.getString(AppUpdateService.prefCachedReleaseJson), isNull);
    });
  }

  test('oversized metadata is rejected without a success cache', () async {
    final updater = service((_) async =>
        http.Response('x' * (AppUpdateService.maxResponseBytes + 1), 200));
    expect(await updater.checkForUpdate(), isNull);
    expect(prefs.getInt(AppUpdateService.prefLastCheckMs), isNull);
  });

  test('chunked responses are bounded even without a content length', () async {
    final client = _ChunkClient();
    final updater = AppUpdateService(prefs: prefs, httpClient: client);
    addTearDown(updater.dispose);
    expect(await updater.checkForUpdate(), isNull);
    expect(client.cancelled, isTrue);
    expect(prefs.getInt(AppUpdateService.prefLastCheckMs), isNull);
  });

  testWidgets('timeout aborts the HTTP request and records a retry deadline',
      (tester) async {
    final client = _WaitingClient();
    final updater = AppUpdateService(prefs: prefs, httpClient: client);
    addTearDown(updater.dispose);
    final pending = updater.checkForUpdate();
    await tester.pump();
    expect(client.entered.isCompleted, isTrue);
    await tester.pump(AppUpdateService.requestTimeout);
    expect(await pending, isNull);
    expect(client.aborted, isTrue);
    expect(prefs.getInt(AppUpdateService.prefNextAttemptMs), isNotNull);
  });

  test('cache write failure does not discard a fetched update', () async {
    final platform = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _RejectWrites();
    addTearDown(() => SharedPreferencesStorePlatform.instance = platform);
    final info = await service((_) async => release('1.3.0')).checkForUpdate();
    expect(info!.hasUpdate, isTrue);
    expect(prefs.getInt(AppUpdateService.prefLastCheckMs), isNull);
  });

  test('failed ignore write rolls back memory cache and reports failure',
      () async {
    final platform = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = _RejectWrites();
    addTearDown(() => SharedPreferencesStorePlatform.instance = platform);
    final updater = service((_) async => release('1.3.0'));
    await expectLater(updater.ignoreVersion('1.3.0'), throwsStateError);
    expect(await updater.isVersionIgnored('1.3.0'), isFalse);
  });

  test('ignored version matches normalized tags but not later releases',
      () async {
    final updater = service((_) async => release('1.3.0'));
    await updater.ignoreVersion('v1.3.0+15');
    expect(await updater.isVersionIgnored('1.3.0'), isTrue);
    expect(await updater.isVersionIgnored('1.4.0'), isFalse);
  });

  test('disposing a service prevents requests and cache writes', () async {
    var requests = 0;
    final response = Completer<http.Response>();
    final entered = Completer<void>();
    final updater = service((_) {
      requests++;
      entered.complete();
      return response.future;
    });
    final pending = updater.checkForUpdate();
    await entered.future;
    updater.dispose();
    response.complete(release('1.3.0'));
    expect(await pending, isNull);
    expect(await updater.checkForUpdate(force: true), isNull);
    expect(requests, 1);
    expect(prefs.getString(AppUpdateService.prefCachedReleaseJson), isNull);
  });

  test('release URL opens without relying on query permission', () async {
    final original = UrlLauncherPlatform.instance;
    final launcher = _Launcher();
    UrlLauncherPlatform.instance = launcher;
    addTearDown(() => UrlLauncherPlatform.instance = original);
    expect(
        await AppUpdateService.openReleaseUrl(
            'https://github.com/maksim0-debug/Lumen/releases/latest'),
        isTrue);
    expect(launcher.called, isTrue);
  });

  for (final url in [
    'javascript:alert(1)',
    'file:///etc/passwd',
    '',
    'https://example.com',
    'http://github.com/maksim0-debug/Lumen/releases/latest',
    'https://github.com.evil.com/maksim0-debug/Lumen/releases/latest',
    'https://github.com/other/repo/releases/latest',
    'https://github.com/maksim0-debug/Lumen/releases/',
    'https://github.com/maksim0-debug/Lumen/releases/../issues'
  ]) {
    test('refuses unrelated or unsafe release URL $url', () async {
      expect(await AppUpdateService.openReleaseUrl(url), isFalse);
    });
  }
}
