import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/desktop_sync_service.dart';
import 'package:lumen/services/app_logger.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/models/emergency_status.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'desktop forwards status-only observations when no schedule is available',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final received = <String>[];
    final subscription = server.listen((request) async {
      received.add(await utf8.decoder.bind(request).join());
      request.response.write(jsonEncode({
        'status': 'emergency_only',
        'checkedGroups': 0,
        'emergencyProcessed': true,
        'errors': []
      }));
      await request.response.close();
    });
    final client = DesktopSyncService.forTesting(
      fetch: () async => ParserFetchResult({}, 'status-only-canonical-payload',
          emergency: EmergencyObservation(
              true, DateTime.now().millisecondsSinceEpoch)),
      loadConfig: () async => DesktopAdminConfig(
          adminKey: 'test-key', workerUrl: 'http://127.0.0.1:${server.port}'),
    );
    try {
      await client.syncNow();
      expect(received, ['status-only-canonical-payload']);
    } finally {
      client.dispose();
      await server.close(force: true);
      await subscription.cancel();
    }
  });
  setUp(() => HttpOverrides.global = null);
  DesktopSyncService service({Duration timeout = const Duration(seconds: 1)}) =>
      DesktopSyncService.forTesting(
          fetch: () async => const ParserFetchResult({}, null),
          loadConfig: () async => null,
          requestTimeout: timeout);
  test('configuration fallback survives corrupt first file and UTF8 BOM',
      () async {
    final dir = await Directory.systemTemp.createTemp('lumen-config-');
    final previousLogger = AppLogger.onLog;
    final messages = <String>[];
    AppLogger.onLog =
        (level, message, tag, error, stack) => messages.add(message);
    try {
      final first = File('${dir.path}/first.json')
        ..writeAsStringSync('{"admin_key":"do-not-log-this-secret","broken":}');
      final second = File('${dir.path}/second.json')
        ..writeAsStringSync(
            '\uFEFF{"admin_key":" key ","worker_url":"https://example.com"}');
      final config =
          await DesktopAdminConfig.loadFromFile(candidates: [first, second]);
      expect(config!.adminKey, 'key');
      expect(config.endpoint.toString(), 'https://example.com/check-html');
      expect(messages.join('\n'), isNot(contains('do-not-log-this-secret')));
    } finally {
      AppLogger.onLog = previousLogger;
      await dir.delete(recursive: true);
    }
  });
  test('keys cannot be sent over remote HTTP or credential-bearing URLs', () {
    for (final url in [
      'http://example.com',
      'https://user:password@example.com',
      'https://example.com?key=a',
      'https://example.com#frag'
    ]) {
      expect(() => DesktopAdminConfig(adminKey: 'key', workerUrl: url).endpoint,
          throwsFormatException);
    }
    expect(
        const DesktopAdminConfig(
                adminKey: 'key', workerUrl: 'http://127.0.0.1:8000/')
            .endpoint
            .path,
        '/check-html');
  });
  test(
      'HTTP 200 without successful JSON report is a failure; redirects are not followed',
      () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var visits = 0;
    final subscription = server.listen((request) async {
      visits++;
      await request.drain<void>();
      final source = request.uri.queryParameters['source'];
      expect(source, 'desktop_bridge');
      if (request.uri.path.startsWith('/redirect')) {
        request.response.statusCode = 302;
        request.response.headers.set('Location', '/destination');
      } else if (request.uri.path.startsWith('/html')) {
        request.response.write('<html>login</html>');
      } else if (request.uri.path.startsWith('/error')) {
        request.response.write(jsonEncode({
          'status': 'success',
          'errors': ['FCM failed']
        }));
      } else if (request.uri.path.startsWith('/emergency')) {
        request.response.write(jsonEncode({
          'status': 'emergency_only',
          'errors': [],
          'checkedGroups': 0,
          'emergencyProcessed': true
        }));
      } else {
        request.response.write(jsonEncode(
            {'status': 'success', 'errors': [], 'checkedGroups': 12}));
      }
      await request.response.close();
    });
    final client = service();
    try {
      for (final path in ['redirect', 'html', 'error']) {
        final config = DesktopAdminConfig(
            adminKey: 'secret',
            workerUrl: 'http://127.0.0.1:${server.port}/$path');
        await expectLater(
            client.pushToWorker(config, 'schedule'), throwsA(anything));
      }
      await client.pushToWorker(
          DesktopAdminConfig(
              adminKey: 'secret',
              workerUrl: 'http://127.0.0.1:${server.port}/ok'),
          'schedule');
      await client.pushToWorker(
          DesktopAdminConfig(
              adminKey: 'secret',
              workerUrl: 'http://127.0.0.1:${server.port}/emergency'),
          'observation');
      expect(visits, 5);
    } finally {
      client.dispose();
      await server.close(force: true);
      await subscription.cancel();
    }
  });
  test('total timeout covers a response whose body never completes', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final subscription = server.listen((request) async {
      await request.drain<void>();
      request.response.bufferOutput = false;
      request.response.write('{');
      await request.response.flush();
    });
    final client = service(timeout: const Duration(milliseconds: 80));
    try {
      await expectLater(
          client.pushToWorker(
              DesktopAdminConfig(
                  adminKey: 'key',
                  workerUrl: 'http://127.0.0.1:${server.port}'),
              'schedule'),
          throwsA(isA<TimeoutException>()));
    } finally {
      client.dispose();
      await server.close(force: true);
      await subscription.cancel();
    }
  });
  test('repeated init creates one timer; dispose cancels the initial callback',
      () async {
    var fetches = 0;
    final client = DesktopSyncService.forTesting(
        fetch: () async {
          fetches++;
          return const ParserFetchResult({}, null);
        },
        loadConfig: () async => null,
        startDelay: const Duration(milliseconds: 15),
        interval: const Duration(hours: 1));
    await client.init();
    expect(client.isInitialized, true);
    await client.init();
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(fetches, 1);
    client.dispose();
    expect(client.isInitialized, false);
    await client.init();
    client.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 45));
    expect(fetches, 1);
  });
  test(
      'concurrent synchronization does not overlap and failure releases its lock',
      () async {
    final completer = Completer<ParserFetchResult>();
    var fetches = 0;
    final client = DesktopSyncService.forTesting(
        fetch: () {
          fetches++;
          return completer.future;
        },
        loadConfig: () async => null);
    final first = client.syncNow();
    await client.syncNow();
    expect(fetches, 1);
    expect(client.isSyncing, true);
    completer.completeError(StateError('test failure'));
    await first;
    expect(client.isSyncing, false);
    client.dispose();
  });
}
