import 'dart:async';
import 'dart:convert';
import 'dart:io' hide Cookie;
import 'dart:io' as io show Cookie;

import 'package:flutter_inappwebview/flutter_inappwebview.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/app_logger.dart';
import 'package:lumen/services/android_fetch_diagnostics.dart';
import 'package:lumen/services/dtek_snapshot.dart';
import 'package:lumen/services/emergency_status_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/services/android_fetch_coordinator.dart';
import 'package:lumen/services/parser_transport_policy.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/ui/logs_page.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

const _policy = ParserFetchPolicy(
  totalTimeout: Duration(seconds: 3),
  httpTimeout: Duration(milliseconds: 250),
  webViewTimeout: Duration(seconds: 2),
  controllerTimeout: Duration(milliseconds: 300),
  cookieTimeout: Duration(milliseconds: 60),
  pollInterval: Duration(milliseconds: 5),
  challengeGrace: Duration(milliseconds: 15),
  recoveryDelay: Duration(milliseconds: 40),
  httpRetryDelay: Duration(milliseconds: 5),
  rateLimitDelay: Duration(seconds: 5),
  pollAttempts: 40,
);

class _Paths extends PathProviderPlatform {
  final String directory;
  _Paths(this.directory);
  @override
  Future<String?> getApplicationDocumentsPath() async => directory;
  @override
  Future<String?> getApplicationSupportPath() async => directory;
}

// TestWidgetsFlutterBinding normally replaces HTTP with an always-400 client.
// Restore real sockets only for the loopback server boundary in these tests.
class _SocketOverrides extends HttpOverrides {}

class _Browser extends InAppWebViewPlatform {
  final Uri target;
  _Browser(this.target);
  late _Headless view;
  int views = 0;
  int loads = 0;
  int captures = 0;
  int disposals = 0;
  int cookieReads = 0;
  bool cached = false;
  bool reuseHtml = false;
  String? previousHtml;
  bool failStartup = false;
  String startupFailureMessage = 'startup failed';
  bool failController = false;
  bool failCookies = false;
  bool failDevTools = false;
  String html = '<html><body>Runtime schedule</body></html>';
  String? captureUrl;
  dynamic fact;
  Completer<void>? startupGate;
  Completer<dynamic>? captureGate;
  Completer<List<Cookie>>? cookieGate;
  List<Cookie> cookies = [Cookie(name: 'session', value: 'browser-session')];
  final loaded = Completer<void>();
  final cookieStarted = Completer<void>();
  final requests = <URLRequest>[];
  final devToolsCalls = <String>[];
  Future<void> Function(int)? navigate;

  dynamic capture() {
    final unchanged = reuseHtml && previousHtml == html;
    previousHtml = html;
    return jsonEncode({
      'fact': fact,
      'html': unchanged ? null : html,
      'htmlUnchanged': unchanged,
      'url': captureUrl ?? target.toString(),
      'fromCache': cached,
    });
  }

  @override
  PlatformHeadlessInAppWebView createPlatformHeadlessInAppWebView(
      PlatformHeadlessInAppWebViewCreationParams params) {
    views++;
    return view = _Headless(params, this);
  }

  @override
  PlatformCookieManager createPlatformCookieManager(
          PlatformCookieManagerCreationParams params) =>
      _Cookies(params);
}

class _Headless extends PlatformHeadlessInAppWebView {
  final _Browser browser;
  late final _Controller controller;
  late final dynamic facade;
  _Headless(super.params, this.browser) : super.implementation() {
    controller = _Controller(
        PlatformInAppWebViewControllerCreationParams(
            id: 'parser-transport-test', webviewParams: params),
        browser);
    facade = params.controllerFromPlatform!(controller);
  }
  @override
  Future<void> run() async {
    if (browser.failStartup) throw StateError(browser.startupFailureMessage);
    await browser.startupGate?.future;
    params.onWebViewCreated!(facade);
  }

  @override
  Future<void> dispose() async => browser.disposals++;
  @override
  String get id => 'parser-transport-test';
  @override
  PlatformInAppWebViewController get webViewController => controller;

  void start() =>
      params.onLoadStart!(facade, WebUri(browser.target.toString()));
  void stop() => params.onLoadStop!(facade, WebUri(browser.target.toString()));
  void httpError(int status,
          {bool main = true, Uri? url, Map<String, String>? headers}) =>
      params.onReceivedHttpError!(
          facade,
          WebResourceRequest(
              url: WebUri((url ?? browser.target).toString()),
              isForMainFrame: main,
              method: 'GET'),
          WebResourceResponse(
              statusCode: status,
              headers: headers,
              reasonPhrase: 'test response'));
  void navigationError(WebResourceErrorType type, {bool main = true}) =>
      params.onReceivedError!(
          facade,
          WebResourceRequest(
              url: WebUri(browser.target.toString()),
              isForMainFrame: main,
              method: 'GET'),
          WebResourceError(type: type, description: 'test navigation error'));
}

class _Controller extends PlatformInAppWebViewController {
  final _Browser browser;
  _Controller(super.params, this.browser) : super.implementation();
  @override
  Future<dynamic> evaluateJavascript(
      {required String source, ContentWorld? contentWorld}) async {
    if (source == 'navigator.userAgent') return 'NativeBrowser/1.0';
    browser.captures++;
    if (browser.failController) throw StateError('capture failed');
    final gate = browser.captureGate;
    if (gate != null) return gate.future;
    return browser.capture();
  }

  @override
  Future<dynamic> callDevToolsProtocolMethod(
      {required String methodName, Map<String, dynamic>? parameters}) async {
    browser.devToolsCalls.add(methodName);
    if (browser.failDevTools) throw StateError('DevTools setup failed');
    return {};
  }

  @override
  Future<void> loadUrl(
      {required URLRequest urlRequest,
      Uri? iosAllowingReadAccessTo,
      WebUri? allowingReadAccessTo}) async {
    browser.requests.add(urlRequest);
    browser.loads++;
    browser.view.start();
    if (!browser.loaded.isCompleted) browser.loaded.complete();
    if (browser.navigate != null) {
      await browser.navigate!(browser.loads);
    } else {
      browser.view.stop();
    }
  }
}

class _Cookies extends PlatformCookieManager {
  _Cookies(super.params) : super.implementation();
  @override
  Future<List<Cookie>> getCookies(
      {required WebUri url,
      PlatformInAppWebViewController? iosBelow11WebViewController,
      PlatformInAppWebViewController? webViewController}) async {
    // CookieManager caches a platform instance; delegate to this test's browser.
    final browser = InAppWebViewPlatform.instance as _Browser;
    browser.cookieReads++;
    if (!browser.cookieStarted.isCompleted) browser.cookieStarted.complete();
    if (browser.failCookies) throw StateError('cookie read failed');
    if (browser.cookieGate != null) return browser.cookieGate!.future;
    return browser.cookies;
  }
}

Map<String, dynamic> _fact({String status = 'yes', int minute = 0}) {
  final day = ScheduleClock.day(ScheduleClock.now());
  final stamp = day.millisecondsSinceEpoch ~/ 1000;
  return {
    'today': stamp,
    'update':
        '${day.day}.${day.month}.${day.year} 00:${minute.toString().padLeft(2, '0')}',
    'data': {
      '$stamp': {
        for (final group in ParserService.allGroups)
          group: {for (var h = 1; h <= 24; h++) '$h': status}
      }
    },
  };
}

String _page(Map<String, dynamic> fact, {String extra = ''}) =>
    '<html><body><script>DisconSchedule.fact = ${jsonEncode(fact)};</script>$extra</body></html>';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory scratch;
  late HttpServer server;
  late Uri target;
  late _Browser browser;
  late ParserService parser;
  late Future<void> Function(HttpRequest, int) respond;
  late List<Map<String, String>> httpRequests;
  final originalPlatform = InAppWebViewPlatform.instance;
  final originalPaths = PathProviderPlatform.instance;

  ParserService service(
          {ParserFetchPolicy policy = _policy,
          bool windows = false,
          Future<WebViewEnvironment?> Function()? environmentFactory}) =>
      ParserService.forTesting(
          target: target,
          policy: policy,
          windows: windows,
          environmentFactory: environmentFactory,
          httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
              HttpClient.new, _SocketOverrides()));

  Future<int> storedSchedules() async =>
      (await (await HistoryService().database)
              .rawQuery('SELECT COUNT(*) AS n FROM schedule_history'))
          .single['n'] as int;

  Future<List<Map<String, dynamic>>> waitForLog(String message) async {
    final deadline = Stopwatch()..start();
    while (deadline.elapsed < const Duration(seconds: 2)) {
      final logs = await HistoryService().getLogs(limit: 200);
      if (logs.any((row) => (row['message'] as String).contains(message))) {
        return logs;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('Parser diagnostic did not reach SQLite: $message');
  }

  Future<void> expectVisibleError(String message) async {
    final logs = await waitForLog(message);
    expect(logs.where((row) => (row['message'] as String).contains(message)),
        everyElement(containsPair('level', 'ERROR')));
    final grouped = groupConsecutiveLogs(logs);
    for (final category in [
      LogFilterCategory.errors,
      LogFilterCategory.parser
    ]) {
      expect(filterGroupedLogs(grouped, category).map((entry) => entry.message),
          contains(contains(message)));
    }
  }

  setUpAll(() async {
    scratch = await Directory.systemTemp.createTemp('lumen-parser-transport-');
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PathProviderPlatform.instance = _Paths(scratch.path);
    SharedPreferences.setMockInitialValues({'enable_logging': false});
    await HistoryService().database;
    await EmergencyStatusService().read();
  });
  setUp(() async {
    await (await SharedPreferences.getInstance())
        .setBool('enable_logging', false);
    final db = await HistoryService().database;
    final tables =
        (await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table'"))
            .map((row) => row['name'])
            .toSet();
    for (final name in [
      'schedule_history',
      'dtek_snapshot_state',
      'dtek_current_schedule',
      'emergency_status',
      'app_logs'
    ]) {
      if (tables.contains(name)) await db.delete(name);
    }
    httpRequests = [];
    respond = (request, _) async {
      request.response.statusCode = 403;
      await request.response.close();
    };
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    target = Uri.parse('http://127.0.0.1:${server.port}/ua/shutdowns');
    server.listen((request) {
      httpRequests.add({
        'cookie': request.headers.value('cookie') ?? '',
        'cache-control': request.headers.value('cache-control') ?? '',
        'user-agent': request.headers.value('user-agent') ?? '',
        for (final name in [
          'sec-fetch-dest',
          'sec-fetch-mode',
          'sec-fetch-site',
          'sec-fetch-user',
          'upgrade-insecure-requests',
          'sec-ch-ua',
          'sec-ch-ua-platform'
        ])
          name: request.headers.value(name) ?? '',
      });
      unawaited(respond(request, httpRequests.length));
    });
    browser = _Browser(target)..fact = _fact();
    InAppWebViewPlatform.instance = browser;
    parser = service();
  });
  tearDown(() async {
    AppLogger.onLog = null;
    await server.close(force: true);
  });
  tearDownAll(() async {
    if (originalPlatform != null) {
      InAppWebViewPlatform.instance = originalPlatform;
    }
    PathProviderPlatform.instance = originalPaths;
    await (await HistoryService().database).close();
    await scratch.delete(recursive: true);
  });

  group('Android diagnostic transport boundaries', () {
    late List<Map<String, dynamic>> records;
    late AndroidFetchDiagnostics diagnostics;
    setUp(() {
      records = [];
      diagnostics = AndroidFetchDiagnostics(
          enabled: true,
          modeLoader: () async => AndroidDiagnosticMode.verbose,
          snapshot: (_) async => {'deviceIdle': true, 'networkValidated': true},
          sink: (message, _) async => records.add(jsonDecode(message)));
    });

    test('HTTP success records validation and persistence without browser work',
        () async {
      respond = (request, _) async {
        request.response.write(_page(_fact()));
        await request.response.close();
      };
      final result = await diagnostics.run(
          source: 'periodic_poll',
          execution: 'workmanager',
          action: parser.fetchSnapshot);
      expect(result.schedules, hasLength(12));
      // This fixture publishes today's 12 groups and an empty tomorrow.
      expect(await storedSchedules(), 12);
      expect(browser.views, 0);
      final summary = records.singleWhere((r) => r['stage'] == 'fetch_end');
      expect(summary['reason'], 'http_success');
      expect(summary['httpAttempts'], 1);
      expect(summary['webViewStarted'], false);
      expect(
          records.map((r) => r['stage']),
          containsAllInOrder([
            'http_start',
            'http_connected',
            'http_response',
            'http_body',
            'snapshot_valid',
            'snapshot_persisted',
            'fetch_end',
          ]));
      expect(records.map((r) => r['operationId']).toSet(), hasLength(1));
      expect(jsonEncode(records), isNot(contains('browser-session')));
      expect(jsonEncode(records), isNot(contains('<html')));
    });

    test('WAF fallback success distinguishes HTTP from runtime browser data',
        () async {
      respond = (request, _) async {
        request.response
            .write('<script src="/_Incapsula_Resource?id=secret"></script>');
        await request.response.close();
      };
      expect(
          (await diagnostics.run(
                  source: 'manual_refresh',
                  execution: 'main_engine',
                  action: parser.fetchSnapshot))
              .schedules,
          hasLength(12));
      final summary = records.singleWhere((r) => r['stage'] == 'fetch_end');
      expect(summary['reason'], 'webview_success');
      expect(summary['webViewStarted'], true);
      expect(
          records.singleWhere(
              (r) => r['stage'] == 'webview_schedule_received')['dataSource'],
          'runtime_js');
      expect(
          records.singleWhere((r) => r['stage'] == 'http_body')['protection'],
          isNot('none'));
      expect(jsonEncode(records), isNot(contains('secret')));
      expect(browser.disposals, 1);
    });

    test('Main-frame DNS failure records the browser error and empty result',
        () async {
      browser.navigate = (_) async =>
          browser.view.navigationError(WebResourceErrorType.HOST_LOOKUP);
      final result = await diagnostics.run(
          source: 'periodic_poll',
          execution: 'workmanager',
          action: parser.fetchSnapshot);
      expect(result.schedules, isEmpty);
      expect(
          records.singleWhere(
              (r) => r['stage'] == 'webview_network_error')['webResourceError'],
          contains('HOST_LOOKUP'));
      expect(records.singleWhere((r) => r['stage'] == 'fetch_end')['outcome'],
          'no_schedule');
      expect(records.singleWhere((r) => r['stage'] == 'fetch_end')['reason'],
          contains('HOST_LOOKUP'));
    });

    test('Total deadline records the interrupted stage and keeps its outcome',
        () async {
      browser.startupGate = Completer<void>();
      final bounded = service(
          policy: const ParserFetchPolicy(
        totalTimeout: Duration(milliseconds: 170),
        httpTimeout: Duration(milliseconds: 70),
        webViewTimeout: Duration(seconds: 2),
      ));
      final result = await diagnostics.run(
          source: 'periodic_poll',
          execution: 'workmanager',
          action: bounded.fetchSnapshot);
      expect(result.schedules, isEmpty);
      final timeout = records.singleWhere((r) => r['stage'] == 'fetch_timeout');
      expect(timeout['interruptedStage'], 'webview_platform_run');
      expect(records.singleWhere((r) => r['stage'] == 'fetch_end')['reason'],
          'total_budget_exhausted');
      browser.startupGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(browser.disposals, 1);
    });
  });

  group('Real HTTP boundary', () {
    test('A cold parser sends the compatibility UA and navigation headers',
        () async {
      respond = (request, _) async {
        final userAgent = request.headers.value('user-agent') ?? '';
        if (userAgent.startsWith('Dart/')) {
          request.response.statusCode = 403;
        } else {
          request.response.write(_page(_fact()));
        }
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(browser.views, 0);
      expect(httpRequests, hasLength(1));
      final headers = httpRequests.single;
      expect(headers['user-agent'], startsWith('Mozilla/5.0'));
      expect(headers['sec-fetch-dest'], 'document');
      expect(headers['sec-fetch-mode'], 'navigate');
      expect(headers['sec-fetch-site'], 'none');
      expect(headers['sec-fetch-user'], '?1');
      expect(headers['upgrade-insecure-requests'], '1');
    });

    test('Fresh parser instances never depend on a previously captured session',
        () async {
      respond = (request, _) async {
        request.response.write(_page(_fact()));
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect((await service().fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests, hasLength(2));
      for (final request in httpRequests) {
        expect(request['user-agent'], startsWith('Mozilla/5.0'));
        expect(request['cookie'], isEmpty);
      }
      expect(browser.views, 0);
    });
    test('Full schedule with an Imperva footer succeeds without WebView',
        () async {
      respond = (request, _) async {
        request.response.write(_page(_fact(),
            extra: '<footer>Protected by Imperva Incapsula</footer>'));
        await request.response.close();
      };
      final result = await parser.fetchSnapshot();
      expect(result.schedules, hasLength(12));
      expect(result.isEmergency, false);
      expect(browser.views, 0);
      expect(await storedSchedules(), 12);
      expect(httpRequests.single['cache-control'], contains('no-store'));
    });
    test('Concurrent callers share one complete HTTP snapshot', () async {
      respond = (request, _) async {
        await Future<void>.delayed(const Duration(milliseconds: 15));
        request.response.write(_page(_fact()));
        await request.response.close();
      };
      final results = await Future.wait([
        parser.fetchSnapshot(),
        parser.fetchSnapshot(),
        parser.fetchSnapshot()
      ]);
      expect(httpRequests, hasLength(1));
      expect(identical(results[0], results[1]), true);
      expect(identical(results[0], results[2]), true);
      expect(await storedSchedules(), 12);
    });
    test('Transient 503 retries once and then accepts a valid response',
        () async {
      respond = (request, attempt) async {
        request.response.statusCode = attempt == 1 ? 503 : 200;
        if (attempt == 2) request.response.write(_page(_fact()));
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests, hasLength(2));
      expect(browser.views, 0);
    });
    test(
        '429 respects Retry-After across fetches and does not bypass it with WebView',
        () async {
      respond = (request, _) async {
        request.response.statusCode = 429;
        request.response.headers.set('Retry-After', '60');
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(httpRequests, hasLength(1));
      expect(browser.views, 0);
    });
    test('429 with Retry-After zero allows one bounded retry', () async {
      respond = (request, attempt) async {
        if (attempt == 1) {
          request.response.statusCode = 429;
          request.response.headers.set('Retry-After', '0');
        } else {
          request.response.write(_page(_fact()));
        }
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests, hasLength(2));
    });
    test('Gzip is decoded by the real client', () async {
      respond = (request, _) async {
        request.response.headers.set('Content-Encoding', 'gzip');
        request.response.add(gzip.encode(utf8.encode(_page(_fact()))));
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(browser.views, 0);
    });
    test('Invalid UTF-8 falls back without publishing partial data', () async {
      respond = (request, _) async {
        request.response.add([0xff, 0xfe]);
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests, hasLength(2));
      expect(browser.views, 1);
      expect(await storedSchedules(), 12);
    });
    test('Oversized HTML is rejected and recovery still works', () async {
      respond = (request, _) async {
        request.response.write('x' * (2 * 1024 * 1024 + 1));
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(browser.views, 1);
    });
    test('A stalled HTTP body is aborted before browser fallback', () async {
      respond = (request, _) async {
        request.response.write('<html>');
        await request.response.flush();
      };
      final clock = Stopwatch()..start();
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests, hasLength(2));
      expect(clock.elapsed, lessThan(_policy.totalTimeout));
    });
    test('HTTP emergency survives a later browser response with unknown status',
        () async {
      respond = (request, _) async {
        request.response.write(
            '<div id="modal-attention">Введені екстрені відключення.</div>');
        await request.response.close();
      };
      final result = await parser.fetchSnapshot();
      expect(result.schedules, hasLength(12));
      expect(result.isEmergency, true);
      expect(result.html, contains('lumen-emergency'));
    });
    test('A stale cached HTTP notice cannot acquire a fresh timestamp',
        () async {
      respond = (request, _) async {
        request.response.headers.set('Age', '86400');
        request.response.write(_page(_fact(),
            extra:
                '<div id="modal-attention">Введені екстрені відключення.</div>'));
        await request.response.close();
      };
      final result = await parser.fetchSnapshot();
      expect(result.schedules, hasLength(12));
      expect(result.emergency, isNull);
      expect(result.html, isNot(contains('lumen-emergency')));
    });
    test('HTTP cookie rotation is used on the next request', () async {
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      respond = (request, attempt) async {
        request.response.cookies
            .add(io.Cookie('session', 'rotated')..path = '/');
        request.response.write(_page(_fact()));
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests.last['cookie'], 'session=browser-session');
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests.last['cookie'], 'session=rotated');
    });
    test('Browser recovery refreshes the HTTP session after a 403', () async {
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      browser.cookies = [Cookie(name: 'session', value: 'renewed-session')];
      // The next direct HTTP attempt is still 403, but browser recovery succeeds.
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests.last['cookie'], 'session=browser-session');
      respond = (request, _) async {
        request.response.write(_page(_fact()));
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests.last['cookie'], 'session=renewed-session');
      expect(httpRequests.last['user-agent'], 'NativeBrowser/1.0');
      expect(browser.views, 2);
    });
    test(
        'A rejected HTTP cookie is not reused when browser cookie capture fails',
        () async {
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      browser.failCookies = true;
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests.last['cookie'], 'session=browser-session');
      respond = (request, _) async {
        request.response.write(_page(_fact()));
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests.last['cookie'], isEmpty);
      expect(httpRequests.last['user-agent'], 'NativeBrowser/1.0');
    });
  });

  group('Android coordination and network availability', () {
    test('Known offline state performs neither HTTP nor WebView work',
        () async {
      final offline = ParserService.forTesting(
          target: target,
          policy: _policy,
          networkAvailable: () async => false,
          httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
              HttpClient.new, _SocketOverrides()));
      expect((await offline.fetchSnapshot()).schedules, isEmpty);
      expect(httpRequests, isEmpty);
      expect(browser.views, 0);
    });

    test(
        'Unknown/unavailable native network state still tries the real connection',
        () async {
      respond = (request, _) async {
        request.response.write(_page(_fact()));
        await request.response.close();
      };
      for (final probe in <Future<bool?> Function()>[
        () async => null,
        () async => throw StateError('native unavailable')
      ]) {
        final online = ParserService.forTesting(
            target: target,
            policy: _policy,
            networkAvailable: probe,
            httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
                HttpClient.new, _SocketOverrides()));
        expect((await online.fetchSnapshot()).schedules, hasLength(12));
      }
      expect(httpRequests, hasLength(2));
      expect(browser.views, 0);
    });

    test('Lost network after WAF response suppresses futile browser fallback',
        () async {
      var checks = 0;
      final disconnected = ParserService.forTesting(
          target: target,
          policy: _policy,
          networkAvailable: () async => ++checks == 1,
          httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
              HttpClient.new, _SocketOverrides()));
      expect((await disconnected.fetchSnapshot()).schedules, isEmpty);
      expect(httpRequests, hasLength(1));
      expect(browser.views, 0);
    });

    test('Two separate parsers share one real HTTP response and all 12 groups',
        () async {
      final started = Completer<void>();
      final release = Completer<void>();
      respond = (request, _) async {
        started.complete();
        await release.future;
        request.response.write(_page(_fact(),
            extra:
                '<div id="modal-attention">Введені екстрені відключення.</div>'));
        await request.response.close();
      };
      final db = await HistoryService().database;
      ParserService coordinated() => ParserService.forTesting(
          target: target,
          policy: _policy,
          coordinator: AndroidFetchCoordinator(() async => db,
              pollInterval: const Duration(milliseconds: 5)),
          httpClientFactory: () => HttpOverrides.runWithHttpOverrides(
              HttpClient.new, _SocketOverrides()));
      final owner = coordinated().fetchSnapshot();
      await started.future;
      final other = coordinated();
      final waiter = other.fetchSnapshot();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      release.complete();
      final results = await Future.wait([owner, waiter]);
      expect(httpRequests, hasLength(1));
      expect(results.map((r) => r.schedules.length), [12, 12]);
      expect(results.map((r) => r.isEmergency), [true, true]);
      expect(results.last.emergency!.observedAt,
          results.first.emergency!.observedAt);
      final recent = await other.recentAndroidSnapshot();
      expect(recent!.value.schedules, hasLength(12));
      expect(recent.value.isEmergency, true);
      expect(await storedSchedules(), 12);
    });
  });

  group('Browser lifecycle and recovery', () {
    test('Runtime data appearing after page load is still captured', () async {
      browser.fact = null;
      browser.html =
          '<div id="modal-attention">Введені екстрені відключення.</div>';
      final fetched = parser.fetchSnapshot();
      await browser.loaded.future;
      await Future<void>.delayed(const Duration(milliseconds: 35));
      browser.fact = _fact();
      final result = await fetched;
      expect(result.schedules, hasLength(12));
      expect(result.isEmergency, true);
      expect(browser.loads, 1);
      expect(await storedSchedules(), 12);
    });

    test(
        'Unchanged HTML is reused while late runtime data still updates the graph',
        () async {
      browser.reuseHtml = true;
      browser.fact = null;
      browser.html =
          '<div id="modal-attention">Введені екстрені відключення.</div>';
      final fetched = parser.fetchSnapshot();
      await browser.loaded.future;
      await Future<void>.delayed(const Duration(milliseconds: 35));
      browser.fact = _fact();
      final result = await fetched;
      expect(browser.captures, greaterThan(1));
      expect(result.schedules, hasLength(12));
      expect(result.isEmergency, true);
    });

    test('Changed DOM replaces the reused emergency observation', () async {
      browser.reuseHtml = true;
      browser.fact = null;
      browser.html =
          '<div id="modal-attention">Введені екстрені відключення.</div>';
      final fetched = parser.fetchSnapshot();
      await browser.loaded.future;
      await Future<void>.delayed(const Duration(milliseconds: 35));
      browser.html = _page(_fact(),
          extra:
              '<div id="modal-attention">Екстрені відключення скасовано.</div>');
      browser.fact = _fact();
      final result = await fetched;
      expect(result.schedules, hasLength(12));
      expect(result.isEmergency, false);
    });

    test('Inline HTML data is used when the runtime variable is absent',
        () async {
      browser.fact = null;
      browser.html = _page(_fact());
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(browser.loads, 1);
    });
    test('Persistent challenges exhaust exactly two actual reloads', () async {
      browser.fact = null;
      browser.html = '<script src="/_Incapsula_Resource?id=1"></script>';
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(browser.loads, 3);
      expect(browser.disposals, 1);
      expect(await storedSchedules(), 0);
    });
    test('A main-frame 403 without onLoadStop recovers once', () async {
      browser.navigate = (count) async {
        if (count == 1) {
          browser.view.httpError(403);
        } else {
          browser.view.stop();
        }
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(browser.loads, 2);
      expect(browser.disposals, 1);
      expect(browser.view.params.initialSettings!.cacheEnabled, false);
      expect(
          browser.requests.every((request) =>
              request.headers!['Cache-Control']!.contains('no-store')),
          true);
    });
    test('Navigation during a queued recovery cancels it and can recover again',
        () async {
      browser.fact = null;
      browser.html = '<script src="/_Incapsula_Resource?id=1"></script>';
      browser.navigate = (count) async {
        if (count > 1) {
          browser.fact = _fact();
          browser.html = '<html><body>Runtime schedule</body></html>';
        }
        browser.view.stop();
      };
      final fetched = parser.fetchSnapshot();
      await browser.loaded.future;
      await Future<void>.delayed(const Duration(milliseconds: 25));
      browser.view.start();
      browser.view.stop();
      expect((await fetched).schedules, hasLength(12));
      expect(browser.loads, 2);
    });
    test('Automatic completion during reload logging does not spend a reload',
        () async {
      browser.fact = null;
      browser.html = '<script src="/_Incapsula_Resource?id=1"></script>';
      var intervened = false;
      AppLogger.onLog = (level, message, tag, error, stack) {
        if (message.contains('Перезавантаження після захисту') && !intervened) {
          intervened = true;
          browser.fact = _fact();
          browser.html = '<html><body>Loaded automatically</body></html>';
          browser.view.start();
          browser.view.stop();
        }
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(intervened, true);
      expect(browser.loads, 1);
    });
    test('Cookies that never finish cannot lose a validated schedule',
        () async {
      browser.cookieGate = Completer<List<Cookie>>();
      final result = await parser.fetchSnapshot();
      expect(result.schedules, hasLength(12));
      expect(await storedSchedules(), 12);
      expect(browser.disposals, 1);
    });
    test('The total deadline also preserves an already validated schedule',
        () async {
      browser.cookieGate = Completer<List<Cookie>>();
      parser = service(
          policy: const ParserFetchPolicy(
              totalTimeout: Duration(milliseconds: 200),
              cookieTimeout: Duration(seconds: 1)));
      final result = await parser.fetchSnapshot();
      expect(browser.cookieReads, 1);
      expect(result.schedules, hasLength(12));
      expect(await storedSchedules(), 12);
      expect(browser.disposals, 1);
    });
    test('Cookie exceptions do not invalidate a schedule', () async {
      browser.failCookies = true;
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
    });
    test('Late cookie completion cannot populate the next HTTP request',
        () async {
      browser.cookieGate = Completer<List<Cookie>>();
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      browser.cookieGate!.complete([Cookie(name: 'late', value: 'obsolete')]);
      await Future<void>.delayed(const Duration(milliseconds: 5));
      respond = (request, _) async {
        request.response.write(_page(_fact()));
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests.last['cookie'], isEmpty);
    });
    test('Browser cookies and native UA are reused by direct HTTP', () async {
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      respond = (request, _) async {
        request.response.write(_page(_fact()));
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(httpRequests.last['cookie'], 'session=browser-session');
      expect(httpRequests.last['user-agent'], 'NativeBrowser/1.0');
      expect(httpRequests.last['sec-ch-ua'], isEmpty);
      expect(httpRequests.last['sec-ch-ua-platform'], isEmpty);
      expect(browser.views, 1);
    });
    test(
        'Subresource errors and foreign main-frame errors cannot reload the document',
        () async {
      browser.navigate = (_) async {
        browser.view.httpError(403, main: false);
        browser.view
            .httpError(403, url: Uri.parse('https://other.test/ua/shutdowns'));
        browser.view
            .httpError(429, main: false, headers: {'Retry-After': '60'});
        browser.view.navigationError(WebResourceErrorType.UNKNOWN, main: false);
        browser.view.stop();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(browser.loads, 1);
    });
    test('Cancellation generated by a replacement navigation is ignored',
        () async {
      browser.navigate = (_) async {
        browser.view.navigationError(WebResourceErrorType.CANCELLED);
        browser.view.stop();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
    });
    test('A real main-frame navigation error finishes and disposes', () async {
      browser.navigate = (_) async =>
          browser.view.navigationError(WebResourceErrorType.UNKNOWN);
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(browser.disposals, 1);
    });
    test('Cached emergency and graph are rejected before persistence',
        () async {
      browser.cached = true;
      browser.html =
          '<div id="modal-attention">Введені екстрені відключення.</div>';
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(await storedSchedules(), 0);
      expect(browser.cookieReads, 0);
      expect(browser.loads, 3);
      final db = await HistoryService().database;
      expect(await db.query('emergency_status'), isEmpty);
    });
    test('A fresh response after a cached response is accepted', () async {
      browser.navigate = (count) async {
        browser.cached = count == 1;
        browser.view.stop();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(browser.loads, 2);
    });
    test('Country policy denial stops without repeated requests', () async {
      browser.html = '<title>Access Denied</title><h1>Error 15</h1>';
      browser.fact = null;
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(browser.loads, 1);
    });
    test('A branded denial stops after one capture without storing a graph',
        () async {
      browser.html = '<title>ДТЕК</title><header>DTEK</header>'
          '<h1>Error 15</h1><p>Access denied</p>';
      // Even a runtime object left on the denial page must not be accepted.
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(browser.loads, 1);
      expect(browser.captures, 1);
      expect(browser.disposals, 1);
      expect(await storedSchedules(), 0);
    });
    test('A browser 429 honors Retry-After even when onLoadStop follows it',
        () async {
      browser.navigate = (_) async {
        browser.view.httpError(429, headers: {'ReTrY-AfTeR': '60'});
        browser.view.stop();
      };
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(browser.loads, 1);
      expect(await storedSchedules(), 0);
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(httpRequests, hasLength(1));
    });
    test('Obsolete JavaScript replies cannot overwrite a newer navigation',
        () async {
      browser.captureGate = Completer<dynamic>();
      final fetched = parser.fetchSnapshot();
      await browser.loaded.future;
      while (browser.captures == 0) {
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }
      final oldReply = browser.capture();
      final gate = browser.captureGate!;
      browser.captureGate = null;
      browser.fact = _fact(status: 'no', minute: 1);
      browser.view.start();
      browser.view.stop();
      final result = await fetched;
      gate.complete(oldReply);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(result.schedules['GPV1.1']!.today.hours,
          everyElement(LightStatus.off));
      expect(await storedSchedules(), 12);
    });
    test('An unexpected document URL cannot publish its runtime object',
        () async {
      browser.captureUrl = 'https://other.test/ua/shutdowns';
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(await storedSchedules(), 0);
    });
    test('Windows cache and service worker bypass precede navigation',
        () async {
      parser = service(windows: true, environmentFactory: () async => null);
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(browser.devToolsCalls,
          ['Network.setCacheDisabled', 'Network.setBypassServiceWorker']);
      expect(browser.loads, 1);
    });
    test('Windows refuses navigation when cache policy cannot be installed',
        () async {
      browser.failDevTools = true;
      parser = service(windows: true, environmentFactory: () async => null);
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(browser.loads, 0);
      expect(browser.disposals, 1);
    });
    test('Late environment creation is reused after a timeout', () async {
      final gate = Completer<WebViewEnvironment?>();
      var creations = 0;
      parser = service(
          windows: true,
          environmentFactory: () {
            creations++;
            return gate.future;
          });
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      gate.complete(null);
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(creations, 1);
      expect(browser.views, 1);
    });
    test('Failed environment creation permits a subsequent retry', () async {
      var creations = 0;
      parser = service(
          windows: true,
          environmentFactory: () async {
            creations++;
            if (creations == 1) throw StateError('Environment creation failed');
            return null;
          });
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      expect(creations, 2);
    });
    test('A JavaScript reply after the total timeout cannot write history',
        () async {
      browser.captureGate = Completer<dynamic>();
      parser = service(
          policy: const ParserFetchPolicy(
              totalTimeout: Duration(milliseconds: 150),
              controllerTimeout: Duration(seconds: 1)));
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      browser.captureGate!.complete(browser.capture());
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(await storedSchedules(), 0);
      expect(browser.disposals, 1);
    });
    test('Late native creation is disposed after the caller has timed out',
        () async {
      browser.startupGate = Completer<void>();
      parser = service(
          policy: const ParserFetchPolicy(
              totalTimeout: Duration(milliseconds: 150),
              webViewTimeout: Duration(milliseconds: 100),
              controllerTimeout: Duration(milliseconds: 50)));
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      browser.startupGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(browser.loads, 0);
      expect(browser.disposals, 1);
    });
    test('Startup failure returns cleanly and a later fetch can succeed',
        () async {
      browser.failStartup = true;
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      browser.failStartup = false;
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
    });
    test('Controller errors exhaust a bounded poll and dispose', () async {
      browser.failController = true;
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      expect(browser.captures, _policy.pollAttempts);
      expect(browser.disposals, 1);
    });
  });

  group('Application log persistence', () {
    test('HTTP decoding errors remain visible when routine logging is disabled',
        () async {
      respond = (request, _) async {
        request.response.add([0xff, 0xfe]);
        await request.response.close();
      };
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      await expectVisibleError(
          'Помилка HTTP запиту (спроба 2, FormatException)');
      final logs = await HistoryService().getLogs(limit: 200);
      expect(
          logs.map((row) => row['message']),
          contains(
              contains('Помилка HTTP запиту (спроба 1, FormatException)')));
    });

    test('Startup errors reach SQLite without exposing exception credentials',
        () async {
      browser
        ..failStartup = true
        ..startupFailureMessage = 'password=private-test-secret';
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      await expectVisibleError('Помилка запуску WebView (StateError)');
      final logs = await HistoryService().getLogs(limit: 200);
      expect(logs.map((row) => row['message']).join('\n'),
          isNot(contains('private-test-secret')));
    });

    test('Main document network errors remain visible in both log filters',
        () async {
      browser.navigate = (_) async {
        browser.view.navigationError(WebResourceErrorType.HOST_LOOKUP);
      };
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      await expectVisibleError('WebView: Помилка мережі');
    });

    test('WebView timeout is persisted even with routine logging disabled',
        () async {
      browser.navigate = (_) async {};
      parser = service(
          policy: const ParserFetchPolicy(
              totalTimeout: Duration(seconds: 2),
              webViewTimeout: Duration(milliseconds: 100)));
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      await expectVisibleError('Тайм-аут WebView');
      expect(browser.disposals, 1);
    });

    test('Total deadline is persisted and late native startup remains harmless',
        () async {
      browser.startupGate = Completer<void>();
      parser = service(
          policy: const ParserFetchPolicy(
              totalTimeout: Duration(milliseconds: 150),
              webViewTimeout: Duration(seconds: 1)));
      expect((await parser.fetchSnapshot()).schedules, isEmpty);
      await expectVisibleError('Вичерпано загальний час');
      browser.startupGate!.complete();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(browser.loads, 0);
      expect(browser.disposals, 1);
    });

    test('Cookie warnings preserve successful schedules and safe diagnostics',
        () async {
      await (await SharedPreferences.getInstance())
          .setBool('enable_logging', true);
      browser.failCookies = true;
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      final logs =
          await waitForLog('Не вдалося отримати cookies або User-Agent');
      final warning = logs.singleWhere((row) =>
          (row['message'] as String).contains('cookies або User-Agent'));
      expect(warning['level'], 'WARN');
      expect(warning['message'], contains('StateError'));
      expect(logs.map((row) => row['message']).join('\n'),
          isNot(contains('browser-session')));
      expect(await storedSchedules(), 12);
    });

    test('Successful HTTP diagnostics include response size and parsed JSON',
        () async {
      await (await SharedPreferences.getInstance())
          .setBool('enable_logging', true);
      final html = _page(_fact());
      respond = (request, _) async {
        request.response.write(html);
        await request.response.close();
      };
      parser = service(
          policy: const ParserFetchPolicy(
              totalTimeout: Duration(seconds: 5),
              httpTimeout: Duration(seconds: 2)));
      expect((await parser.fetchSnapshot()).schedules, hasLength(12));
      final logs = await waitForLog('HTTP метод спрацював');
      final messages = logs.map((row) => row['message']);
      expect(messages, contains(contains('Код відповіді 200 (спроба 1)')));
      expect(
          messages,
          contains(
              'Парсер HTTP: HTML успішно отримано (${utf8.encode(html).length} байт)'));
      expect(messages, contains(contains('Знайдено JSON графіків')));
      expect(messages.join('\n'), isNot(contains('DisconSchedule.fact =')));
      expect(browser.views, 0);
    });
  });

  test(
      'Actual DTEK capture retains all 576 hourly cells and half-hour semantics',
      () async {
    final raw =
        await File('test/fixtures/dtek_fact_2026_10_08.json').readAsString();
    final real = DtekSnapshot.parse(raw, ParserService.allGroups,
        now: DateTime.utc(2026, 10, 8, 12));
    expect(real.update, '08.10.2026 09:06');
    expect(real.schedules, hasLength(12));
    // Golden values independently encoded from the saved site's hourly cells.
    const expected = {
      'GPV1.1': ('111100000031111000000111', '000000000000000000111100'),
      'GPV1.2': ('000000000031111112000111', '311120000000000000111100'),
      'GPV2.1': ('111100000031112000000111', '000000031112000000111100'),
      'GPV2.2': ('111100000031111000000111', '200000031112000000000000'),
      'GPV3.1': ('000000001110001111000000', '000000000001111000000000'),
      'GPV3.2': ('000311121110001111000000', '000000000001112000000000'),
      'GPV4.1': ('000311120000001111000000', '000000000000000000000311'),
      'GPV4.2': ('000311120000001111111000', '000000000000000000000311'),
      'GPV5.1': ('200000011111112003111200', '000000000000003111200000'),
      'GPV5.2': ('200000011111112003111200', '000000030000003111200000'),
      'GPV6.1': ('200000011110000003111200', '000011110000000000000000'),
      'GPV6.2': ('200000011110000003111100', '000000020000003111200000'),
    };
    final adjusted = jsonDecode(raw) as Map<String, dynamic>;
    final originalStamp = '${adjusted['today']}';
    final today = ScheduleClock.day(ScheduleClock.now());
    final tomorrow = ScheduleClock.day(today, 1);
    adjusted['today'] = today.millisecondsSinceEpoch ~/ 1000;
    adjusted['update'] = '${today.day}.${today.month}.${today.year} 00:00';
    final data = adjusted['data'] as Map<String, dynamic>;
    adjusted['data'] = {
      '${adjusted['today']}': data[originalStamp],
      '${tomorrow.millisecondsSinceEpoch ~/ 1000}':
          data['${int.parse(originalStamp) + 86400}'],
    };
    browser.fact = adjusted;
    final result = await parser.fetchSnapshot();
    for (final group in ParserService.allGroups) {
      expect(result.schedules[group]!.today.scheduleHash, expected[group]!.$1);
      expect(
          result.schedules[group]!.tomorrow.scheduleHash, expected[group]!.$2);
      expect(result.schedules[group]!.today.toSlots(),
          real.schedules[group]!.today.toSlots());
      expect(result.schedules[group]!.tomorrow.toSlots(),
          real.schedules[group]!.tomorrow.toSlots());
    }
    expect(await storedSchedules(), 24);
  });
}
