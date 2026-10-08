import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/services/api/api_response.dart';
import 'package:lumen/services/api/local_api_service.dart';
import 'package:lumen/services/api/openapi_specs.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => '.';

  @override
  Future<String?> getApplicationSupportPath() async => '.';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ApiResponse Tests', () {
    test('ok factory returns 200 with success: true and valid payload', () {
      final response = ApiResponse.ok(
        {'status': 'online'},
        meta: {'cached': false},
      );

      expect(response.statusCode, HttpStatus.ok);
      expect(response.success, isTrue);

      final map = response.toMap();
      expect(map['success'], isTrue);
      expect(map['data']['status'], 'online');
      expect(map['meta']['cached'], isFalse);
      expect(map.containsKey('timestamp'), isTrue);
    });

    test('badRequest factory returns 400 with error details', () {
      final response = ApiResponse.badRequest(
        'Invalid group parameter',
        code: 'INVALID_GROUP',
        details: {'field': 'group'},
      );

      expect(response.statusCode, HttpStatus.badRequest);
      expect(response.success, isFalse);

      final map = response.toMap();
      expect(map['success'], isFalse);
      expect(map['error']['code'], 'INVALID_GROUP');
      expect(map['error']['message'], 'Invalid group parameter');
      expect(map['error']['details']['field'], 'group');
    });

    test('notFound factory returns 404', () {
      final response = ApiResponse.notFound('Route not found');
      expect(response.statusCode, HttpStatus.notFound);
      expect(response.success, isFalse);
      expect(response.toMap()['error']['code'], 'NOT_FOUND');
    });

    test('internalError factory returns 500 with exception string', () {
      final response = ApiResponse.internalError(
        'Server failed',
        exception: Exception('Database disconnected'),
      );
      expect(response.statusCode, HttpStatus.internalServerError);
      expect(response.success, isFalse);
      expect(response.toMap()['error']['details']['exception'],
          contains('Database disconnected'));
    });
  });

  group('OpenApiSpecs Tests', () {
    test('generates valid OpenAPI 3.0.3 schema with all endpoints', () {
      final spec = OpenApiSpecs.generateSpec(port: 18080);

      expect(spec['openapi'], '3.0.3');
      expect(spec['info']['title'], contains('Lumen'));
      expect(spec['info']['version'], '1.2.0');

      final paths = spec['paths'] as Map<String, dynamic>;
      expect(paths.containsKey('/status'), isTrue);
      expect(paths.containsKey('/health'), isTrue);
      expect(paths.containsKey('/power/current'), isTrue);
      expect(paths.containsKey('/power/events'), isTrue);
      expect(paths.containsKey('/power/intervals'), isTrue);
      expect(paths.containsKey('/schedule/today'), isTrue);
      expect(paths.containsKey('/schedule/tomorrow'), isTrue);
      expect(paths.containsKey('/schedule/countdown'), isTrue);
      expect(paths.containsKey('/schedule/groups'), isTrue);
      expect(paths.containsKey('/schedule/sync'), isTrue);
      expect(paths.containsKey('/history/versions'), isTrue);
      expect(paths.containsKey('/history/export'), isTrue);
      expect(paths.containsKey('/analytics/stats'), isTrue);
      expect(paths.containsKey('/analytics/accuracy'), isTrue);
      expect(paths.containsKey('/analytics/switch-lag'), isTrue);
      expect(paths.containsKey('/analytics/records'), isTrue);
    });
  });

  group('LocalApiService HTTP Server Lifecycle & Routing Tests', () {
    final service = LocalApiService();
    const testPort = 18888;

    setUpAll(() async {
      HttpOverrides.global = null;
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
      PathProviderPlatform.instance = MockPathProviderPlatform();
      await service.start(port: testPort);
    });

    tearDownAll(() async {
      await service.stop();
    });

    test('server runs on 127.0.0.1 and test port', () {
      expect(service.isRunning, isTrue);
      expect(service.port, testPort);
      expect(service.lastError, isNull);
      expect(service.uptime.inSeconds >= 0, isTrue);
    });

    test('GET /api/v1/health returns healthy status and metadata', () async {
      final url = Uri.parse('http://127.0.0.1:$testPort/api/v1/health');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      expect(res.headers['access-control-allow-origin'], '*');
      expect(res.headers['content-type'], contains('application/json'));

      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data']['status'], 'healthy');
      expect(body['data']['port'], testPort);
      expect(body['data']['host'], '127.0.0.1');
    });

    test('GET /api/v1/openapi.json returns valid specification', () async {
      final url = Uri.parse('http://127.0.0.1:$testPort/api/v1/openapi.json');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['openapi'], '3.0.3');
    });

    test(
        'GET /api/v1/status returns combined snapshot (power + schedule + countdown)',
        () async {
      final url = Uri.parse('http://127.0.0.1:$testPort/api/v1/status');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data'].containsKey('power'), isTrue);
      expect(body['data'].containsKey('schedule_today'), isTrue);
      expect(body['data'].containsKey('countdown'), isTrue);
    });

    test('OPTIONS pre-flight request returns 204 with CORS headers', () async {
      final request = await HttpClient().openUrl(
        'OPTIONS',
        Uri.parse('http://127.0.0.1:$testPort/api/v1/power/current'),
      );
      final res = await request.close();

      expect(res.statusCode, HttpStatus.noContent);
      expect(res.headers.value('access-control-allow-origin'), '*');
      expect(
          res.headers.value('access-control-allow-methods'), contains('GET'));
    });

    test('GET request with duplicate and trailing slashes is normalized',
        () async {
      final url = Uri.parse('http://127.0.0.1:$testPort/api//v1///health//');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
    });

    test('GET /api/v1/power/current returns power state and sensor snapshot',
        () async {
      final url = Uri.parse('http://127.0.0.1:$testPort/api/v1/power/current');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data'].containsKey('state'), isTrue);
      expect(body['data'].containsKey('sensor'), isTrue);
    });

    test('GET /api/v1/power/events returns events list', () async {
      final url =
          Uri.parse('http://127.0.0.1:$testPort/api/v1/power/events?limit=10');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data'].containsKey('events'), isTrue);
    });

    test('GET /api/v1/power/intervals returns intervals structure', () async {
      final url =
          Uri.parse('http://127.0.0.1:$testPort/api/v1/power/intervals');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data'].containsKey('intervals'), isTrue);
    });

    test('GET /api/v1/schedule/today returns valid schedule payload', () async {
      final url = Uri.parse(
          'http://127.0.0.1:$testPort/api/v1/schedule/today?group=GPV2.1');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data']['group'], 'GPV2.1');
      expect(body['data'].containsKey('is_available'), isTrue);
    });

    test('GET /api/v1/schedule/tomorrow returns tomorrow status', () async {
      final url = Uri.parse(
          'http://127.0.0.1:$testPort/api/v1/schedule/tomorrow?group=GPV2.1');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data']['group'], 'GPV2.1');
      expect(body['data'].containsKey('status'), isTrue);
    });

    test('GET /api/v1/schedule/countdown returns countdown info', () async {
      final url = Uri.parse(
          'http://127.0.0.1:$testPort/api/v1/schedule/countdown?group=GPV2.1');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data'].containsKey('has_countdown'), isTrue);
    });

    test('GET /api/v1/schedule/groups returns all 12 groups', () async {
      final url =
          Uri.parse('http://127.0.0.1:$testPort/api/v1/schedule/groups');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data']['total_groups'], 12);
      expect(body['data']['groups'].containsKey('GPV1.1'), isTrue);
      expect(body['data']['groups'].containsKey('GPV6.2'), isTrue);
    });

    test('GET /api/v1/history/versions returns versions data', () async {
      final url = Uri.parse(
          'http://127.0.0.1:$testPort/api/v1/history/versions?group=GPV2.1');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data'].containsKey('versions'), isTrue);
    });

    test('GET /api/v1/history/export returns exported database JSON', () async {
      final url = Uri.parse('http://127.0.0.1:$testPort/api/v1/history/export');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
    });

    test('GET /api/v1/analytics/stats returns period stats', () async {
      final url =
          Uri.parse('http://127.0.0.1:$testPort/api/v1/analytics/stats?days=7');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data']['period_days'], 7);
      expect(body['data'].containsKey('total_outage_minutes'), isTrue);
    });

    test('GET /api/v1/analytics/accuracy returns accuracy score', () async {
      final url = Uri.parse(
          'http://127.0.0.1:$testPort/api/v1/analytics/accuracy?days=7');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data'].containsKey('accuracy_percentage'), isTrue);
    });

    test('GET /api/v1/analytics/switch-lag returns switch lag metrics',
        () async {
      final url = Uri.parse(
          'http://127.0.0.1:$testPort/api/v1/analytics/switch-lag?days=7');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data'].containsKey('avg_on_lag_minutes'), isTrue);
      expect(body['data'].containsKey('avg_off_lag_minutes'), isTrue);
    });

    test('GET /api/v1/analytics/records returns records summary', () async {
      final url =
          Uri.parse('http://127.0.0.1:$testPort/api/v1/analytics/records');
      final res = await http.get(url);

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data'].containsKey('longest_outage'), isTrue);
    });

    test('GET /api/v1/status?group=UNKNOWN returns 400 with INVALID_GROUP',
        () async {
      final url = Uri.parse(
          'http://127.0.0.1:$testPort/api/v1/status?group=UNKNOWN_GROUP');
      final res = await http.get(url);

      expect(res.statusCode, 400);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isFalse);
      expect(body['error']['code'], 'INVALID_GROUP');
    });

    test('Host header with IPv6 format [::1] is accepted', () async {
      final client = HttpClient();
      final req = await client
          .getUrl(Uri.parse('http://127.0.0.1:$testPort/api/v1/health'));
      req.headers.set('host', '[::1]:$testPort');
      final res = await req.close();

      expect(res.statusCode, 200);
    });

    test(
        'POST /api/v1/power/events creates manual event with safe device parsing',
        () async {
      final url = Uri.parse('http://127.0.0.1:$testPort/api/v1/power/events');
      final res = await http.post(
        url,
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'status': 'offline',
          'device': 'CustomUPS-100',
        }),
      );

      expect(res.statusCode, 200);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isTrue);
      expect(body['data']['created'], isTrue);
      expect(body['data']['status'], 'offline');
      expect(body['data']['device'], 'CustomUPS-100');
      expect(body['data']['is_manual'], isTrue);
      expect(body['data']['firebase_key'], contains('manual_'));
    });

    test('GET /api/v1/unknown_route returns 404 with structured error',
        () async {
      final url =
          Uri.parse('http://127.0.0.1:$testPort/api/v1/non_existent_route');
      final res = await http.get(url);

      expect(res.statusCode, 404);
      final body = jsonDecode(res.body) as Map<String, dynamic>;
      expect(body['success'], isFalse);
      expect(body['error']['code'], 'ROUTE_NOT_FOUND');
    });
  });

  group('LocalApiService Safe Shutdown & Port Guard Lifecycle Tests', () {
    final service = LocalApiService();
    const cyclePort = 18889;

    test('accessing port while or after stopping does not throw HttpException',
        () async {
      final started = await service.start(port: cyclePort);
      expect(started, isTrue);
      expect(service.isRunning, isTrue);
      expect(service.port, cyclePort);

      // Trigger stop and concurrently verify properties without awaiting completion
      final stopFuture = service.stop();
      expect(service.isRunning, isFalse);
      expect(() => service.port, returnsNormally);
      expect(service.port, cyclePort);

      await stopFuture;
      expect(service.isRunning, isFalse);
      expect(() => service.port, returnsNormally);
      expect(service.port, cyclePort);
    });

    test('rapid sequential stop and start calls do not conflict or throw',
        () async {
      final start1 = await service.start(port: cyclePort);
      expect(start1, isTrue);

      // Rapidly initiate stop followed immediately by start
      final stopFuture = service.stop();
      final startFuture = service.start(port: cyclePort);

      await stopFuture;
      final start2 = await startFuture;
      expect(start2, isTrue);
      expect(service.isRunning, isTrue);
      expect(service.port, cyclePort);

      await service.stop();
      expect(service.isRunning, isFalse);
    });
  });
}
