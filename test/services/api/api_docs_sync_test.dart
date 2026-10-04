import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/api/openapi_specs.dart';
import 'package:lumen/services/parser_service.dart';

void main() {
  group('Zero-Trust API Documentation Contract & Anti-Stale Tests', () {
    test('All expected routes exist in OpenAPI specification', () {
      final spec = OpenApiSpecs.generateSpec(port: 18080);
      final paths = (spec['paths'] as Map<String, dynamic>).keys.toSet();

      final expectedEndpoints = [
        '/status',
        '/health',
        '/docs',
        '/openapi.json',
        '/stream',
        '/power/current',
        '/power/events',
        '/power/intervals',
        '/power/refresh',
        '/schedule/today',
        '/schedule/tomorrow',
        '/schedule/group/{id}',
        '/schedule/countdown',
        '/schedule/groups',
        '/schedule/sync',
        '/history/versions',
        '/history/dates',
        '/history/export',
        '/history/logs',
        '/analytics/stats',
        '/analytics/accuracy',
        '/analytics/switch-lag',
        '/analytics/records',
      ];

      for (final endpoint in expectedEndpoints) {
        expect(paths.contains(endpoint), isTrue,
            reason: 'Missing endpoint in OpenAPI spec: $endpoint');
      }
    });

    test('All documentation files and assets exist and are populated', () {
      final requiredFiles = [
        'docs/api/README.md',
        'docs/api/quickstart.md',
        'docs/api/architecture-security.md',
        'docs/api/openapi.yaml',
        'docs/api/openapi.json',
        'docs/api/llms.txt',
        'docs/api/llms-full.txt',
        'docs/api/integrations/home-assistant.md',
        'docs/api/integrations/desktop-widgets-and-scripts.md',
        'docs/api/endpoints/01-system.md',
        'docs/api/endpoints/02-power.md',
        'docs/api/endpoints/03-schedule.md',
        'docs/api/endpoints/04-realtime-sse.md',
        'docs/api/endpoints/05-history.md',
        'docs/api/endpoints/06-analytics.md',
        'docs/api/schemas/responses-and-errors.md',
        'docs/api/schemas/models-and-enums.md',
        'docs/index.html',
        'docs/llms.txt',
        'docs/assets/icon.png',
        'docs/.nojekyll',
      ];

      for (final relPath in requiredFiles) {
        final file = File(relPath);
        expect(file.existsSync(), isTrue, reason: 'Missing doc file: $relPath');
        if (relPath != 'docs/.nojekyll') {
          expect(file.lengthSync(), greaterThan(50),
              reason: 'Doc file is empty or suspiciously small: $relPath');
        }
      }
    });

    test('openapi.json matches the generated spec from OpenApiSpecs', () {
      final jsonFile = File('docs/api/openapi.json');
      expect(jsonFile.existsSync(), isTrue);

      final fileContent = jsonFile.readAsStringSync();
      final parsedJson = jsonDecode(fileContent) as Map<String, dynamic>;

      final liveSpec = OpenApiSpecs.generateSpec(port: 18080);
      expect(parsedJson['openapi'], equals(liveSpec['openapi']));
      expect(parsedJson['paths'].keys, equals(liveSpec['paths'].keys));
      expect(parsedJson['components']['schemas'].keys,
          equals(liveSpec['components']['schemas'].keys));
    });

    test('All 24 component schemas exist in OpenAPI specification', () {
      final spec = OpenApiSpecs.generateSpec(port: 18080);
      final schemas = (spec['components']['schemas'] as Map<String, dynamic>);

      expect(schemas.length, equals(24));
      expect(schemas.containsKey('StatusSnapshotResponse'), isTrue);
      expect(schemas.containsKey('PowerCurrentResponse'), isTrue);
      expect(schemas.containsKey('ScheduleCountdownResponse'), isTrue);
      expect(schemas.containsKey('HistoryLogsResponse'), isTrue);

      final logsProp = schemas['HistoryLogsResponse']['properties']['data']
          ['properties']['logs']['items'];
      expect(logsProp['type'], equals('string'),
          reason: 'HistoryLogsResponse logs must be an array of strings');

      final countdownProps = schemas['ScheduleCountdownResponse']['properties']
          ['data']['properties'];
      expect(countdownProps['minutes_remaining']['type'],
          equals(['integer', 'null']));
      expect(
          countdownProps['target_status']['type'], equals(['string', 'null']));
      expect(countdownProps['target_time']['type'], equals(['string', 'null']));
      expect(countdownProps['formatted_remaining']['type'],
          equals(['string', 'null']));
    });

    test(
        'openapi.yaml and openapi.json have synchronized version and endpoints',
        () {
      final jsonFile = File('docs/api/openapi.json');
      final yamlFile = File('docs/api/openapi.yaml');
      expect(jsonFile.existsSync(), isTrue);
      expect(yamlFile.existsSync(), isTrue);

      final parsedJson =
          jsonDecode(jsonFile.readAsStringSync()) as Map<String, dynamic>;
      final yamlContent = yamlFile.readAsStringSync();

      expect(parsedJson['openapi'], equals('3.1.0'));
      expect(yamlContent.contains('openapi: 3.1.0'), isTrue);
      expect(yamlContent.contains('/openapi.json'), isTrue);
      expect(yamlContent.contains('StatusSnapshotResponse'), isTrue);
    });

    test('All 12 GPV groups are documented and match ParserService.allGroups',
        () {
      final modelsDoc =
          File('docs/api/schemas/models-and-enums.md').readAsStringSync();
      for (final group in ParserService.allGroups) {
        expect(modelsDoc.contains(group), isTrue,
            reason: 'Group $group must be documented in models-and-enums.md');
      }
      expect(ParserService.allGroups.length, equals(12));
    });

    test(
        'All error codes used in API code are documented in responses-and-errors.md',
        () {
      final errorsDoc =
          File('docs/api/schemas/responses-and-errors.md').readAsStringSync();

      final knownErrorCodes = [
        'INVALID_HOST',
        'INVALID_GROUP',
        'INVALID_DATE_FORMAT',
        'INVALID_DATE_ORDER',
        'INCOMPLETE_DATE_RANGE',
        'BODY_TOO_LARGE',
        'EMPTY_BODY',
        'INVALID_JSON',
        'INVALID_STATUS',
        'INVALID_TIMESTAMP',
        'ROUTE_NOT_FOUND',
        'METHOD_NOT_ALLOWED',
        'INTERNAL_ERROR',
        'SERVICE_UNAVAILABLE',
      ];

      for (final code in knownErrorCodes) {
        expect(errorsDoc.contains(code), isTrue,
            reason:
                'Error code $code is used in API code but missing from responses-and-errors.md');
      }
    });

    test('llms.txt contains concise reference to key endpoints and enums', () {
      final llmsTxt = File('docs/api/llms.txt').readAsStringSync();
      expect(llmsTxt.contains('/status'), isTrue);
      expect(llmsTxt.contains('/stream'), isTrue);
      expect(llmsTxt.contains('/power/current'), isTrue);
      expect(llmsTxt.contains('/schedule/today'), isTrue);
      expect(llmsTxt.contains('GPV1.1'), isTrue);
      expect(llmsTxt.contains('GPV6.2'), isTrue);
      expect(llmsTxt.contains('127.0.0.1:18080'), isTrue);
    });
  });
}
