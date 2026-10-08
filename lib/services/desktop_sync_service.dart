import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'parser_service.dart';
import 'schedule_sync_service.dart';

class DesktopAdminConfig {
  static const defaultWorkerUrl =
      'https://lumen-schedule-monitor.maksim0.workers.dev';
  final String adminKey;
  final String workerUrl;
  const DesktopAdminConfig(
      {required this.adminKey, this.workerUrl = defaultWorkerUrl});

  Uri get endpoint {
    final uri = Uri.parse(workerUrl);
    final local = const ['localhost', '127.0.0.1', '::1'].contains(uri.host);
    if (uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.scheme != 'https' && !(uri.scheme == 'http' && local))) {
      throw const FormatException(
          'Worker URL must use HTTPS without credentials, query or fragment');
    }
    return uri.replace(
        path: '${uri.path.replaceAll(RegExp(r'/+$'), '')}/check-html');
  }

  static Future<DesktopAdminConfig?> loadFromFile(
      {Iterable<File>? candidates}) async {
    final files = candidates ??
        [
          File(
              '${File(Platform.resolvedExecutable).parent.path}${Platform.pathSeparator}lumen_admin.json'),
          File('lumen_admin.json'),
        ];
    for (final file in files) {
      try {
        if (!await file.exists()) continue;
        final text = (await file.readAsString())
            .replaceFirst(RegExp(r'^\uFEFF'), '')
            .trim();
        final parsed = jsonDecode(text);
        if (parsed is! Map<String, dynamic>) {
          throw const FormatException('Expected a configuration object');
        }
        final key = parsed['admin_key'];
        final url = parsed['worker_url'] ?? defaultWorkerUrl;
        if (key is! String || key.trim().isEmpty || url is! String) {
          throw const FormatException('Invalid admin_key or worker_url');
        }
        final config =
            DesktopAdminConfig(adminKey: key.trim(), workerUrl: url.trim());
        config.endpoint; // Validate before enabling the bridge.
        return config;
      } catch (error) {
        // FormatException can include the raw JSON and therefore the admin key.
        AppLogger.w(
            'Cannot load admin configuration ${file.path} (${error.runtimeType})',
            tag: 'DesktopSync');
      }
    }
    return null;
  }
}

/// Publishes desktop fetches through the same stream used by UI and SSE.
class DesktopSyncService {
  static final DesktopSyncService _instance = DesktopSyncService._internal();
  factory DesktopSyncService() => _instance;
  DesktopSyncService._internal()
      : startDelay = const Duration(seconds: 20),
        interval = const Duration(minutes: 5),
        requestTimeout = const Duration(seconds: 75),
        _fetch = ScheduleSyncService().fetchSnapshotAndPublish,
        _loadConfig = DesktopAdminConfig.loadFromFile;

  @visibleForTesting
  DesktopSyncService.forTesting({
    required Future<ParserFetchResult> Function() fetch,
    required Future<DesktopAdminConfig?> Function() loadConfig,
    this.startDelay = const Duration(seconds: 20),
    this.interval = const Duration(minutes: 5),
    this.requestTimeout = const Duration(seconds: 75),
  })  : _fetch = fetch,
        _loadConfig = loadConfig;

  final Future<ParserFetchResult> Function() _fetch;
  final Future<DesktopAdminConfig?> Function() _loadConfig;
  final Duration startDelay;
  final Duration interval;
  final Duration requestTimeout;
  Timer? _startTimer;
  Timer? _periodicTimer;
  HttpClient? _activeClient;
  bool _isSyncing = false;
  bool _initialized = false;
  int _generation = 0;
  bool get isSyncing => _isSyncing;
  bool get isInitialized => _initialized;
  bool get isSupported =>
      !kIsWeb && (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

  Future<void> init() async {
    if (!isSupported || _initialized) return;
    _initialized = true;
    _startTimer = Timer(startDelay, () => unawaited(syncNow()));
    _periodicTimer = Timer.periodic(interval, (_) => unawaited(syncNow()));
  }

  Future<void> syncNow() async {
    if (!isSupported || _isSyncing) return;
    _isSyncing = true;
    final generation = _generation;
    try {
      final result = await _fetch().timeout(const Duration(seconds: 90));
      if (generation != _generation ||
          (result.schedules.isEmpty && result.emergency == null)) {
        return;
      }
      final config = await _loadConfig().timeout(const Duration(seconds: 10));
      if (generation != _generation || config == null || result.html == null) {
        return;
      }
      await pushToWorker(config, result.html!);
    } catch (error) {
      AppLogger.w('Desktop synchronization failed: $error', tag: 'DesktopSync');
    } finally {
      _isSyncing = false;
    }
  }

  @visibleForTesting
  Future<void> pushToWorker(DesktopAdminConfig config, String html) async {
    final bytes = utf8.encode(html);
    if (bytes.isEmpty || bytes.length > 2 * 1024 * 1024) {
      throw const FormatException('HTML body must be between 1 byte and 2 MiB');
    }
    final client = HttpClient()
      ..connectionTimeout = const Duration(seconds: 15);
    _activeClient = client;
    try {
      await (() async {
        final request = await client.postUrl(config.endpoint
            .replace(queryParameters: {'source': 'desktop_bridge'}));
        request.followRedirects = false;
        request.headers.contentType =
            ContentType('text', 'html', charset: 'utf-8');
        request.headers.set('X-Admin-Key', config.adminKey);
        request.contentLength = bytes.length;
        request.add(bytes);
        final response = await request.close();
        final chunks = <int>[];
        await for (final chunk in response) {
          if (chunks.length + chunk.length > 64 * 1024) {
            throw const FormatException('Worker response exceeds 64 KiB');
          }
          chunks.addAll(chunk);
        }
        final dynamic report = jsonDecode(utf8.decode(chunks));
        if (report is! Map<String, dynamic> ||
            report['errors'] is! List ||
            report['checkedGroups'] is! int ||
            ((report['checkedGroups'] as int) <= 0 &&
                report['emergencyProcessed'] != true) ||
            !['success', 'emergency_only'].contains(report['status']) ||
            (report['errors'] as List).isNotEmpty ||
            response.statusCode != 200) {
          throw HttpException(
              'Worker did not complete synchronization (HTTP ${response.statusCode})');
        }
        AppLogger.i('Desktop schedule synchronized with Worker',
            tag: 'DesktopSync');
      })()
          .timeout(requestTimeout);
    } finally {
      client.close(force: true);
      if (identical(_activeClient, client)) _activeClient = null;
    }
  }

  void dispose() {
    _generation++;
    _initialized = false;
    _startTimer?.cancel();
    _periodicTimer?.cancel();
    _startTimer = null;
    _periodicTimer = null;
    _activeClient?.close(force: true);
  }
}
