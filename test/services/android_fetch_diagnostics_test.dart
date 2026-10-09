import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/android_fetch_diagnostics.dart';
import 'package:lumen/services/app_logger.dart';
import 'package:lumen_android_diagnostics/lumen_android_diagnostics.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late List<Map<String, dynamic>> records;
  late List<bool> samples;
  late AndroidFetchDiagnostics diagnostics;
  setUp(() {
    records = [];
    samples = [];
    diagnostics = AndroidFetchDiagnostics(
      enabled: true,
      modeLoader: () async => AndroidDiagnosticMode.verbose,
      sink: (message, _) async => records.add(jsonDecode(message)),
      snapshot: (history) async {
        samples.add(history);
        return {'deviceIdle': true, 'networkValidated': false};
      },
    );
  });

  test('Correlates stages and system samples without changing the result',
      () async {
    final result = await diagnostics.run(
        source: 'periodic_poll',
        execution: 'workmanager',
        action: () async {
          AndroidFetchDiagnostics.current!.event(
              'http_error', {'osErrorCode': 101},
              level: AppLogLevel.error);
          return false;
        });
    expect(result, false);
    expect(samples, [false, true]);
    expect(records.map((r) => r['operationId']).toSet(), hasLength(1));
    expect(records.map((r) => r['sequence']), orderedEquals([1, 2, 3, 4, 5]));
    expect(
        records.map((r) => r['stage']),
        containsAll([
          'operation_start',
          'http_error',
          'system_state',
          'operation_end',
        ]));
    expect(records.where((r) => r['stage'] == 'system_state'), hasLength(2));
    expect(records.last['lastStage'], 'http_error');
    expect(records, everyElement(containsPair('source', 'periodic_poll')));
    expect(AndroidFetchDiagnostics.current, isNull);
  });

  test('Nested parser work shares the outer worker correlation', () async {
    await diagnostics.run(
        source: 'widget_refresh',
        execution: 'widget',
        action: () async {
          final id = AndroidFetchDiagnostics.current!.id;
          await diagnostics.run(
              source: 'parser_direct',
              execution: 'parser',
              action: () async {
                expect(AndroidFetchDiagnostics.current!.id, id);
              });
        });
    expect(samples, hasLength(2));
    expect(records.where((r) => r['stage'] == 'operation_start'), hasLength(1));
    expect(records.singleWhere((r) => r['stage'] == 'trigger')['triggerSource'],
        'parser_direct');
  });

  test('Failure in persistence or sampling preserves the original exception',
      () async {
    final original = StateError('private failure');
    diagnostics = AndroidFetchDiagnostics(
        enabled: true,
        modeLoader: () async => AndroidDiagnosticMode.verbose,
        sink: (_, __) async => throw StateError('storage unavailable'),
        snapshot: (_) async => throw MissingPluginException());
    await expectLater(
        diagnostics.run(
            source: 'direct',
            execution: 'parser',
            action: () async => throw original),
        throwsA(same(original)));
  });

  test('Native snapshot and persistence waits have a bounded deadline',
      () async {
    diagnostics = AndroidFetchDiagnostics(
        enabled: true,
        modeLoader: () async => AndroidDiagnosticMode.verbose,
        snapshotTimeout: const Duration(milliseconds: 15),
        flushTimeout: const Duration(milliseconds: 15),
        sink: (_, __) => Completer<void>().future,
        snapshot: (_) => Completer<Map<String, dynamic>>().future);
    final watch = Stopwatch()..start();
    expect(
        await diagnostics.run(
            source: 'direct', execution: 'parser', action: () async => 12),
        12);
    expect(watch.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test('Event volume is bounded and terminal result survives truncation',
      () async {
    await diagnostics.run(
        source: 'direct',
        execution: 'parser',
        action: () async {
          for (var i = 0; i < 200; i++) {
            AndroidFetchDiagnostics.current!.event('poll', {'attempt': i});
          }
          AndroidFetchDiagnostics.current!
              .event('fetch_end', {'reason': 'total_budget_exhausted'});
          AndroidFetchDiagnostics.current!
              .event('worker_result', {'result': 'retry'});
        });
    expect(records.length,
        lessThanOrEqualTo(AndroidDiagnosticTrace.maxEvents + 5));
    expect(records.last['droppedEvents'], greaterThan(100));
    expect(records.singleWhere((r) => r['stage'] == 'fetch_end')['reason'],
        'total_budget_exhausted');
    expect(records.singleWhere((r) => r['stage'] == 'worker_result')['result'],
        'retry');
  });

  test('Callbacks inherited from a completed zone create a fresh operation',
      () async {
    final release = Completer<void>();
    late Future<void> lateCallback;
    await diagnostics.run(
        source: 'first',
        execution: 'main',
        action: () async {
          lateCallback = release.future.then((_) => diagnostics.run(
              source: 'later', execution: 'main', action: () async {}));
        });
    release.complete();
    await lateCallback;
    expect(
        records
            .where((r) => r['stage'] == 'operation_start')
            .map((r) => r['operationId'])
            .toSet(),
        hasLength(2));
  });

  test('Disabled platforms perform no sampling or logging', () async {
    final disabled = AndroidFetchDiagnostics(
        enabled: false,
        sink: (_, __) async => fail('Unexpected log'),
        snapshot: (_) async => throw StateError('Unexpected sample'));
    expect(
        await disabled.run(
            source: 'desktop', execution: 'main', action: () async => 7),
        7);
  });

  test('Diagnostic serialization failure cannot fail the parser', () async {
    expect(
        await diagnostics.run(
            source: 'direct',
            execution: 'parser',
            action: () async {
              AndroidFetchDiagnostics.current!
                  .event('bad_field', {'unsupported': Object()});
              return 12;
            }),
        12);
    expect(records.last['stage'], 'operation_end');
  });

  test('Error classification exports useful codes without private input', () {
    const error = SocketException("Failed host lookup: 'secret.example'",
        osError: OSError('private address', 7));
    final fields = AndroidFetchDiagnostics.errorFields(error);
    expect(fields['errorCategory'], 'dns_lookup');
    expect(fields['osErrorCode'], 7);
    expect(jsonEncode(fields), isNot(contains('secret')));
    expect(jsonEncode(fields), isNot(contains('private')));
    expect(
        AndroidFetchDiagnostics.errorFields(const FormatException(
            'Older DTEK snapshot rejected'))['validationReason'],
        'older_source_version');
    expect(
        AndroidFetchDiagnostics.errorFields(
            const FormatException('secret input'))['validationReason'],
        'unclassified_format');
    final url = AndroidFetchDiagnostics.safeUrl(Uri.parse(
        'https://user:secret@example.org/ua/shutdowns?key=secret#secret'));
    expect(url, 'https://example.org/ua/shutdowns');
  });

  test('Native channel passes history flag and returns typed observations',
      () async {
    const channel = MethodChannel('ua.maksim0.lumen/android_diagnostics');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'snapshot');
      expect(call.arguments, {'includeHistory': true});
      return {'deviceIdle': false, 'runAttemptCount': 2};
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    expect(await AndroidSystemDiagnostics.snapshot(includeHistory: true),
        {'deviceIdle': false, 'runAttemptCount': 2});
  });
  group('Budgeted release diagnostics', () {
    setUp(() {
      diagnostics = AndroidFetchDiagnostics(
          enabled: true,
          modeLoader: () async => AndroidDiagnosticMode.compact,
          snapshot: (history) async {
            samples.add(history);
            return {'networkPresent': false};
          },
          sink: (message, _) async => records.add(jsonDecode(message)));
    });

    test('Success writes one summary without native sampling', () async {
      final result = await diagnostics.run(
          source: 'periodic_poll',
          execution: 'workmanager',
          action: () async {
            for (var i = 0; i < 100; i++) {
              AndroidFetchDiagnostics.current!.event('poll', {'attempt': i});
            }
            AndroidFetchDiagnostics.current!.event('snapshot_valid',
                {'groups': 12, 'sourceVersion': '09.10.2026 18:24'});
            AndroidFetchDiagnostics.current!
                .event('fetch_end', {'outcome': 'schedule_received'});
            AndroidFetchDiagnostics.current!
                .event('worker_result', {'result': 'success'});
            return 12;
          });
      expect(result, 12);
      expect(samples, isEmpty);
      expect(records, hasLength(1));
      expect(records.single['mode'], 'compact');
      expect(records.single['failed'], false);
      expect(records.single['details']['snapshot_valid']['groups'], 12);
      expect(records.single.containsKey('recentEvents'), false);
    });

    test('Recovered socket error does not collect expensive success samples',
        () async {
      await diagnostics.run(
          source: 'periodic_poll',
          execution: 'workmanager',
          action: () async {
            AndroidFetchDiagnostics.current!.event(
                'http_error', {'errorCategory': 'socket_timeout'},
                level: AppLogLevel.error);
            AndroidFetchDiagnostics.current!
                .event('fetch_end', {'outcome': 'schedule_received'});
          });
      expect(samples, isEmpty);
      expect(records.single['failed'], false);
    });

    test('Failure flushes a bounded ring and one historical system observation',
        () async {
      await diagnostics.run(
          source: 'periodic_poll',
          execution: 'workmanager',
          action: () async {
            for (var i = 0; i < 200; i++) {
              AndroidFetchDiagnostics.current!.event('poll', {'attempt': i});
            }
            AndroidFetchDiagnostics.current!
                .event('fetch_end', {'outcome': 'no_schedule'});
            AndroidFetchDiagnostics.current!
                .event('worker_result', {'result': 'retry'});
          });
      expect(samples, [true]);
      expect(records, hasLength(1));
      expect(records.single['failed'], true);
      expect(records.single['recentEvents'], hasLength(16));
      expect(records.single['system']['android']['networkPresent'], false);
    });

    test('Storage and side-effect errors survive a successful fetch outcome',
        () async {
      await diagnostics.run(
          source: 'periodic_poll',
          execution: 'workmanager',
          action: () async {
            AndroidFetchDiagnostics.current!
                .event('snapshot_storage_error', {}, level: AppLogLevel.error);
            AndroidFetchDiagnostics.current!
                .event('fetch_end', {'outcome': 'schedule_received'});
          });
      expect(samples, [true]);
      expect(records.single['failed'], true);
      expect(records.single['details'], contains('snapshot_storage_error'));
    });

    test('Disabled preference stops native sampling and message persistence',
        () async {
      SharedPreferences.setMockInitialValues({
        'enable_logging': false,
        AndroidDiagnosticSettings.verboseUntilKey:
            DateTime.now().add(const Duration(hours: 1)).millisecondsSinceEpoch
      });
      diagnostics = AndroidFetchDiagnostics(
          enabled: true,
          snapshot: (_) async => fail('Disabled native snapshot'),
          sink: (_, __) async => fail('Disabled diagnostic write'));
      expect(
          await diagnostics.run(
              source: 'periodic_poll',
              execution: 'workmanager',
              action: () async {
                expect(AndroidFetchDiagnostics.current, isNull);
                return 12;
              }),
          12);
    });

    test('Failure to read the preference cannot fail the original operation',
        () async {
      diagnostics = AndroidFetchDiagnostics(
          enabled: true,
          modeLoader: () async => throw StateError('prefs unavailable'),
          snapshot: (_) async => fail('Native call after failed gate'),
          sink: (_, __) async => fail('Write after failed gate'));
      final failure = StateError('original');
      await expectLater(
          diagnostics.run(
              source: 'direct',
              execution: 'main',
              action: () async => throw failure),
          throwsA(same(failure)));
    });

    test('Compact persistence uses one batch for the whole operation',
        () async {
      var batches = 0;
      diagnostics = AndroidFetchDiagnostics(
          enabled: true,
          modeLoader: () async => AndroidDiagnosticMode.compact,
          batchSink: (entries) async {
            batches++;
            expect(entries, hasLength(1));
          });
      await diagnostics.run(
          source: 'direct', execution: 'main', action: () async => 7);
      expect(batches, 1);
    });

    test('Ordinary lifecycle transitions never request system snapshots',
        () async {
      diagnostics.didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(samples, isEmpty);
      expect(records, hasLength(1));
      expect(records.single['stage'], 'lifecycle');
      expect(records.single['state'], 'paused');
    });

    test('Verbose mode expires and disabled logging takes priority', () {
      const now = 10000000;
      expect(
          AndroidDiagnosticSettings.resolve(
              loggingEnabled: true, verboseUntilMs: 0, nowMs: now),
          AndroidDiagnosticMode.compact);
      expect(
          AndroidDiagnosticSettings.resolve(
              loggingEnabled: true, verboseUntilMs: now + 1000, nowMs: now),
          AndroidDiagnosticMode.verbose);
      expect(
          AndroidDiagnosticSettings.resolve(
              loggingEnabled: true, verboseUntilMs: now, nowMs: now),
          AndroidDiagnosticMode.compact);
      expect(
          AndroidDiagnosticSettings.resolve(
              loggingEnabled: false, verboseUntilMs: now + 1000, nowMs: now),
          AndroidDiagnosticMode.off);
      expect(
          AndroidDiagnosticSettings.resolve(
              loggingEnabled: true,
              verboseUntilMs: now + const Duration(hours: 3).inMilliseconds,
              nowMs: now),
          AndroidDiagnosticMode.compact);
    });
  });
}
