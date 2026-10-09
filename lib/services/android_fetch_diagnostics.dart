import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/widgets.dart';
import 'package:lumen_android_diagnostics/lumen_android_diagnostics.dart';

import 'app_logger.dart';
import 'android_diagnostic_settings.dart';

export 'android_diagnostic_settings.dart';

typedef DiagnosticSink = Future<void> Function(
    String message, AppLogLevel level);
typedef DiagnosticBatchSink = Future<void> Function(
    List<({String message, AppLogLevel level})> entries);
typedef DiagnosticSnapshot = Future<Map<String, dynamic>> Function(
    bool includeHistory);

/// Observation only: never schedules work, acquires locks, or probes the network.
class AndroidFetchDiagnostics with WidgetsBindingObserver {
  static final instance = AndroidFetchDiagnostics();
  static final _zoneKey = Object();
  static int _counter = 0;
  static final _engineId = '$pid-${Isolate.current.hashCode}';
  static AndroidDiagnosticTrace? get current {
    final trace = Zone.current[_zoneKey] as AndroidDiagnosticTrace?;
    return trace?._closed == false ? trace : null;
  }

  final bool enabled;
  final DiagnosticBatchSink _sink;
  final Future<AndroidDiagnosticMode> Function() _modeLoader;
  final DiagnosticSnapshot _snapshot;
  final Duration snapshotTimeout;
  final Duration flushTimeout;
  bool _observing = false;

  AndroidFetchDiagnostics({
    bool? enabled,
    DiagnosticSink? sink,
    DiagnosticBatchSink? batchSink,
    Future<AndroidDiagnosticMode> Function()? modeLoader,
    DiagnosticSnapshot? snapshot,
    this.snapshotTimeout = const Duration(milliseconds: 600),
    this.flushTimeout = const Duration(milliseconds: 500),
  })  : enabled = enabled ?? Platform.isAndroid,
        _sink = batchSink ??
            (sink == null
                ? _persistBatch
                : (entries) async {
                    for (final entry in entries) {
                      await sink(entry.message, entry.level);
                    }
                  }),
        _modeLoader = modeLoader ?? AndroidDiagnosticSettings.read,
        _snapshot = snapshot ??
            ((history) =>
                AndroidSystemDiagnostics.snapshot(includeHistory: history));

  static Future<void> _persistBatch(
          List<({String message, AppLogLevel level})> entries) =>
      AppLogger.diagnosticBatch(entries);

  Future<AndroidDiagnosticMode> _readMode() async {
    try {
      // Cold headless engines can take longer to initialize preferences on MIUI.
      return await _modeLoader().timeout(const Duration(seconds: 1));
    } catch (error) {
      AppLogger.w('Cannot read diagnostic mode (${error.runtimeType})',
          tag: 'AndroidParser', persistToHistory: false);
      return AndroidDiagnosticMode.off;
    }
  }

  void startLifecycleLogging() {
    if (!enabled || _observing) return;
    _observing = true;
    WidgetsBinding.instance.addObserver(this);
    _lifecycle('startup', includeHistory: true);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) =>
      _lifecycle(state.name);

  void _lifecycle(String state, {bool includeHistory = false}) {
    unawaited(_recordLifecycle(state, includeHistory));
  }

  Future<void> _recordLifecycle(String state, bool includeHistory) async {
    if (!enabled) return;
    final mode = await _readMode();
    if (mode == AndroidDiagnosticMode.off) return;
    final trace = AndroidDiagnosticTrace._(
        '${DateTime.now().microsecondsSinceEpoch}-${++_counter}',
        'app_lifecycle',
        'ui',
        this,
        mode);
    trace.event('lifecycle', {'state': state});
    if (mode == AndroidDiagnosticMode.verbose && includeHistory) {
      await trace.sample('startup', true);
    }
    await trace.flush();
    trace._closed = true;
  }

  Future<T> run<T>({
    required String source,
    required String execution,
    required Future<T> Function() action,
    Map<String, Object?> fields = const {},
    bool includeHistory = false,
  }) async {
    if (!enabled) return action();
    final existing = current;
    if (existing != null) {
      existing.event('trigger', {'triggerSource': source, ...fields});
      return action();
    }
    final mode = await _readMode();
    // Gate before collecting native observations, formatting or allocating a trace.
    if (mode == AndroidDiagnosticMode.off) return action();
    final trace = AndroidDiagnosticTrace._(
        '${DateTime.now().microsecondsSinceEpoch}-${++_counter}',
        source,
        execution,
        this,
        mode);
    return runZoned(() async {
      trace.event('operation_start', fields);
      final startSample = mode == AndroidDiagnosticMode.verbose
          ? trace.sample('start', includeHistory)
          : Future<void>.value();
      try {
        return await action();
      } catch (error) {
        trace.event('operation_exception', errorFields(error),
            level: AppLogLevel.error);
        rethrow;
      } finally {
        final operationMs = trace.elapsedMs;
        if (mode == AndroidDiagnosticMode.verbose || trace.failed) {
          await Future.wait([startSample, trace.sample('end', trace.failed)]);
        }
        trace.event('operation_end', {
          'operationMs': operationMs,
          'lastStage': trace.lastStage,
          'droppedEvents': trace.droppedEvents,
        });
        await trace.flush();
        trace._closed = true;
      }
    }, zoneValues: {_zoneKey: trace});
  }

  /// Never export exception messages, addresses, URLs, payloads, or cookies.
  static Map<String, Object?> errorFields(Object error) {
    String category = 'exception';
    int? code;
    if (error is SocketException) {
      code = error.osError?.errorCode;
      final text = error.message.toLowerCase();
      category = text.contains('host lookup') ||
              text.contains('name or service not known') ||
              text.contains('no address associated')
          ? 'dns_lookup'
          : switch (code) {
              101 || 10051 => 'network_unreachable',
              113 || 10065 => 'host_unreachable',
              111 || 10061 => 'connection_refused',
              110 || 10060 => 'socket_timeout',
              _ => 'socket_error',
            };
    } else if (error is TimeoutException) {
      category = 'timeout';
    } else if (error is HandshakeException) {
      category = 'tls_handshake';
    } else if (error is FormatException) {
      category = 'invalid_data';
    } else if (error is HttpException) {
      category = 'http_exception';
    }
    return {
      'errorType': error.runtimeType.toString(),
      'errorCategory': category,
      if (error is FormatException) 'validationReason': validationReason(error),
      if (code != null) 'osErrorCode': code,
    };
  }

  static String validationReason(FormatException error) {
    final message = error.message;
    // Map only known internal validators; never export arbitrary input text.
    const reasons = {
      'Expected schedule object': 'expected_object',
      'Invalid today timestamp': 'invalid_today_timestamp',
      'Snapshot is not for current Kyiv midnight': 'stale_today_date',
      'Missing update time': 'missing_update_time',
      'Future update time too far in advance': 'future_update_time',
      'Missing data': 'missing_data',
      'Invalid schedule day': 'invalid_day',
      'Invalid or ambiguous tomorrow date': 'invalid_tomorrow_date',
      'Older DTEK snapshot rejected': 'older_source_version',
      'Conflicting DTEK snapshot version': 'conflicting_source_version',
      'DTEK response exceeds 2 MiB': 'response_size_limit',
    };
    if (reasons.containsKey(message)) return reasons[message]!;
    if (message.startsWith('Incomplete schedule for GPV')) {
      return 'incomplete_group';
    }
    if (message.startsWith('Invalid hour ')) return 'invalid_hour';
    return 'unclassified_format';
  }

  static String safeUrl(Uri uri) => Uri(
          scheme: uri.scheme,
          host: uri.host,
          port: uri.hasPort ? uri.port : null,
          path: uri.path)
      .toString();
}

class AndroidDiagnosticTrace {
  final String id;
  final String source;
  final String execution;
  final AndroidFetchDiagnostics _owner;
  final Stopwatch _elapsed = Stopwatch()..start();
  final AndroidDiagnosticMode mode;
  final List<({Map<String, Object?> record, AppLogLevel level})> _records = [];
  final Map<String, Object?> _summary = {};
  final List<Map<String, Object?>> _recent = [];
  Map<String, dynamic>? _failureState;
  bool failed = false;
  bool _persistentFailure = false;
  int _sequence = 0;
  int droppedEvents = 0;
  int _overflowErrors = 0;
  bool _closed = false;
  bool _ended = false;
  String lastStage = 'start';
  static const maxEvents = 64;
  int get elapsedMs => _elapsed.elapsedMilliseconds;

  AndroidDiagnosticTrace._(
      this.id, this.source, this.execution, this._owner, this.mode);

  void event(String stage, Map<String, Object?> fields,
      {AppLogLevel level = AppLogLevel.info}) {
    if (_closed) return;
    if (stage == 'operation_end') {
      if (_ended) return;
      _ended = true;
    }
    if (stage != 'operation_end' &&
        mode == AndroidDiagnosticMode.verbose &&
        _sequence >= maxEvents) {
      const terminal = {
        'operation_end',
        'fetch_end',
        'system_state',
        'operation_exception',
        'worker_result',
        'sync_applied',
        'sync_error',
        'widget_fetch_result',
      };
      if (!terminal.contains(stage) || _sequence >= maxEvents + 12) {
        if (level == AppLogLevel.error && _overflowErrors < 8) {
          _overflowErrors++;
        } else {
          droppedEvents++;
          return;
        }
      }
    }
    _sequence++;
    Map<String, Object?> record() => {
          'schema': 1,
          'operationId': id,
          'engineId': AndroidFetchDiagnostics._engineId,
          'pid': pid,
          'sequence': _sequence,
          'at': DateTime.now().toUtc().toIso8601String(),
          'elapsedMs': elapsedMs,
          'source': source,
          'execution': execution,
          'flutterLifecycle':
              WidgetsBinding.instance.lifecycleState?.name ?? 'unknown',
          'stage': stage,
          ...fields,
        };
    if (stage != 'system_state' && stage != 'operation_end') lastStage = stage;
    if (level == AppLogLevel.error) {
      failed = true;
      if (stage != 'http_error' && stage != 'webview_read_error') {
        _persistentFailure = true;
      }
    }
    if (stage == 'fetch_end') {
      // A recovered HTTP/WAF error does not make a successful fetch a failure.
      failed = _persistentFailure || fields['outcome'] != 'schedule_received';
    }
    if ((stage == 'worker_result' && fields['result'] != 'success') ||
        stage == 'sync_error' ||
        stage == 'widget_fetch_error' ||
        (stage == 'widget_fetch_result' && fields['groups'] == 0)) {
      failed = true;
    }
    if (mode == AndroidDiagnosticMode.verbose || source == 'app_lifecycle') {
      _records.add((record: record(), level: level));
      return;
    }
    if (stage == 'system_state') {
      _failureState = Map<String, dynamic>.from(fields);
    } else if (stage == 'operation_end') {
      _records.add((
        record: {
          ...record(),
          'mode': 'compact',
          'failed': failed,
          'details': _summary,
          if (failed) 'recentEvents': List.of(_recent),
          if (_failureState != null) 'system': _failureState,
        },
        level: failed ? AppLogLevel.error : AppLogLevel.info
      ));
    } else {
      const summaries = {
        'operation_start',
        'fetch_start',
        'fetch_end',
        'snapshot_valid',
        'worker_result',
        'sync_applied',
        'sync_skipped',
        'sync_error',
        'widget_fetch_result',
        'widget_fetch_error',
        'operation_exception',
        'fetch_shared',
        'fetch_lease',
        'fetch_wait_timeout',
        'network_unavailable',
        'snapshot_storage_error',
        'background_effect_error',
        'notification_show_error',
      };
      if (summaries.contains(stage)) _summary[stage] = fields;
      if (stage == 'network_state') {
        _summary['network'] = {
          for (final key in [
            'networkPresent',
            'networkBlocked',
            'networkValidated',
            'transports',
            'visibleActivities',
            'interactive',
            'deviceIdle'
          ])
            if (fields.containsKey(key)) key: fields[key],
        };
      }
      if (_recent.length == 16) _recent.removeAt(0);
      _recent.add({'stage': stage, 'elapsedMs': elapsedMs, ...fields});
    }
  }

  Future<void> sample(String phase, bool includeHistory) async {
    try {
      final state = await _owner
          ._snapshot(includeHistory)
          .timeout(_owner.snapshotTimeout);
      event('system_state', {'phase': phase, 'android': state});
    } catch (error) {
      event(
          'system_state',
          {
            'phase': phase,
            'available': false,
            ...AndroidFetchDiagnostics.errorFields(error),
          },
          level: AppLogLevel.warning);
    }
  }

  Future<void> flush() async {
    final entries = <({String message, AppLogLevel level})>[];
    for (final entry in _records) {
      try {
        entries.add((message: jsonEncode(entry.record), level: entry.level));
      } catch (error) {
        AppLogger.w('Diagnostic serialization failed (${error.runtimeType})',
            tag: 'AndroidParser', persistToHistory: false);
      }
    }
    _records.clear();
    if (entries.isEmpty) return;
    try {
      await _owner._sink(entries).timeout(_owner.flushTimeout);
    } catch (error) {
      AppLogger.w('Diagnostic persistence failed (${error.runtimeType})',
          tag: 'AndroidParser', persistToHistory: false);
    }
  }
}
