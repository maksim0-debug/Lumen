import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../app_info_service.dart';
import '../app_logger.dart';
import '../history_service.dart';
import '../preferences_helper.dart';
import 'api_helpers.dart';
import 'api_response.dart';
import 'controllers/analytics_controller.dart';
import 'controllers/history_controller.dart';
import 'controllers/power_controller.dart';
import 'controllers/schedule_controller.dart';
import 'controllers/stream_controller.dart';
import 'openapi_specs.dart';

/// Lightweight, embedded local HTTP REST & SSE API for desktop platforms.
/// Runs exclusively on loopback (127.0.0.1) with 0% CPU footprint when idle.
class LocalApiService {
  static final LocalApiService _instance = LocalApiService._internal();
  factory LocalApiService() => _instance;
  LocalApiService._internal();

  static const int defaultPort = 18080;
  static const String prefsEnabledKey = 'local_api_enabled';
  static const String prefsPortKey = 'local_api_port';

  HttpServer? _server;
  int _configuredPort = defaultPort;
  String? _lastError;
  DateTime? _startedAt;

  late final PowerController _powerController = PowerController();
  late final ScheduleController _scheduleController = ScheduleController();
  late final HistoryController _historyController = HistoryController();
  late final AnalyticsController _analyticsController = AnalyticsController();
  SseStreamController? _streamController;

  bool get isRunning => _server != null;
  int get port => _server?.port ?? _configuredPort;
  String? get lastError => _lastError;
  DateTime? get startedAt => _startedAt;
  Duration get uptime => _startedAt != null
      ? DateTime.now().difference(_startedAt!)
      : Duration.zero;

  /// Initializes the service according to preferences and platform checks.
  Future<void> init() async {
    // Available on all desktop platforms
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      return;
    }

    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final isEnabled = prefs.getBool(prefsEnabledKey) ?? true;
      final port = prefs.getInt(prefsPortKey) ?? defaultPort;
      _configuredPort = port;

      if (isEnabled) {
        await start(port: port);
      }
    } catch (e, stack) {
      AppLogger.e('Failed to initialize LocalApiService',
          tag: 'LocalApi', error: e, stackTrace: stack);
    }
  }

  /// Starts the HTTP server on 127.0.0.1 with the designated port.
  Future<bool> start({int? port}) async {
    if (!Platform.isWindows && !Platform.isLinux && !Platform.isMacOS) {
      _lastError =
          'Локальний API підтримується лише на настільних ОС (Windows/Linux/macOS)';
      return false;
    }

    if (_server != null) {
      await stop();
    }

    final targetPort = port ?? _configuredPort;
    _lastError = null;

    try {
      // Strictly bind to IPv4 loopback (127.0.0.1) with shared: false for true single-instance ownership
      _server = await HttpServer.bind(
        InternetAddress.loopbackIPv4,
        targetPort,
        shared: false,
      );

      _configuredPort = _server!.port;
      _startedAt = DateTime.now();
      _streamController = SseStreamController();

      AppLogger.i(
          'Local REST API started at http://127.0.0.1:$_configuredPort/api/v1',
          tag: 'LocalApi');

      _server!.listen(
        _handleRequest,
        onError: (e) {
          AppLogger.e('Server error encountered', tag: 'LocalApi', error: e);
        },
        onDone: () {
          AppLogger.d('Server socket closed', tag: 'LocalApi');
        },
      );

      return true;
    } on SocketException catch (se) {
      _lastError =
          'Порт $targetPort вже використовується іншою програмою (${se.message})';
      AppLogger.w('Socket conflict on port $targetPort: $se', tag: 'LocalApi');
      _server = null;
      return false;
    } catch (e, stack) {
      _lastError = 'Не вдалося запустити сервер: $e';
      AppLogger.e('Failed to bind server',
          tag: 'LocalApi', error: e, stackTrace: stack);
      _server = null;
      return false;
    }
  }

  /// Stops the running HTTP server and cleans up SSE connections.
  Future<void> stop() async {
    _streamController?.dispose();
    _streamController = null;

    if (_server != null) {
      try {
        await _server!.close(force: true);
        AppLogger.i('Local REST API stopped', tag: 'LocalApi');
      } catch (e) {
        AppLogger.w('Error stopping server: $e', tag: 'LocalApi');
      } finally {
        _server = null;
        _startedAt = null;
      }
    }
  }

  /// Restarts the HTTP server, optionally on a new port.
  Future<bool> restart({int? port}) async {
    await stop();
    return await start(port: port);
  }

  /// Dispatches incoming HTTP requests to corresponding controllers.
  Future<void> _handleRequest(HttpRequest request) async {
    try {
      // 1. Handle CORS Pre-flight
      if (request.method == 'OPTIONS') {
        await _sendCorsPreflight(request);
        return;
      }

      // 2. Validate Host header to protect against DNS rebinding attacks
      final hostHeader = request.headers.value('host');
      if (hostHeader != null) {
        final rawHost = hostHeader.trim();
        String host;
        if (rawHost.startsWith('[')) {
          final closingBracket = rawHost.indexOf(']');
          host = closingBracket != -1
              ? rawHost.substring(1, closingBracket).toLowerCase()
              : rawHost.toLowerCase();
        } else {
          host = rawHost.split(':').first.toLowerCase();
        }

        if (host != 'localhost' && host != '127.0.0.1' && host != '::1') {
          final forbidden = ApiResponse.badRequest(
            'Недозволений заголовок Host: $hostHeader',
            code: 'INVALID_HOST',
          );
          await forbidden.sendTo(request);
          return;
        }
      }

      // 3. Normalize path: strip trailing slash for consistent routing
      var path = request.uri.path;
      if (path.length > 1 && path.endsWith('/')) {
        path = path.substring(0, path.length - 1);
      }

      // 4. Server-Sent Events (SSE) stream endpoint
      if (path == '/api/v1/stream') {
        if (request.method == 'GET') {
          _streamController ??= SseStreamController();
          await _streamController!.handleStream(request);
          return;
        } else {
          final err = ApiResponse.methodNotAllowed(
            'Ендпоінт /stream підтримує лише метод GET',
            allowedMethods: ['GET'],
          );
          await err.sendTo(request);
          return;
        }
      }

      // 5. Interactive Swagger UI Documentation endpoint
      if ((path == '/api/v1/docs' || path == '/docs') &&
          request.method == 'GET') {
        await _handleDocs(request);
        return;
      }

      // 6. Dispatch standard REST routes
      ApiResponse response;

      if (path == '/api/v1/status') {
        if (request.method == 'GET') {
          response = await _handleStatusSnapshot(request);
        } else {
          response = ApiResponse.methodNotAllowed(
            'Ендпоінт /status підтримує лише метод GET',
            allowedMethods: ['GET'],
          );
        }
      } else if (path == '/api/v1/health') {
        if (request.method == 'GET') {
          response = await _handleHealthCheck(request);
        } else {
          response = ApiResponse.methodNotAllowed(
            'Ендпоінт /health підтримує лише метод GET',
            allowedMethods: ['GET'],
          );
        }
      } else if (path == '/api/v1/openapi.json' || path == '/openapi.json') {
        if (request.method == 'GET') {
          response = ApiResponse.raw(OpenApiSpecs.generateSpec(port: port));
        } else {
          response = ApiResponse.methodNotAllowed(
            'Ендпоінт /openapi.json підтримує лише метод GET',
            allowedMethods: ['GET'],
          );
        }
      } else if (path.startsWith('/api/v1/power')) {
        response = await _routePower(request, path);
      } else if (path.startsWith('/api/v1/schedule')) {
        response = await _routeSchedule(request, path);
      } else if (path.startsWith('/api/v1/history')) {
        response = await _routeHistory(request, path);
      } else if (path.startsWith('/api/v1/analytics')) {
        response = await _routeAnalytics(request, path);
      } else {
        response = ApiResponse.notFound(
          'Маршрут $path не знайдено',
          code: 'ROUTE_NOT_FOUND',
        );
      }

      await response.sendTo(request);
    } catch (e, stack) {
      AppLogger.e('Unhandled API exception for ${request.uri.path}',
          tag: 'LocalApi', error: e, stackTrace: stack);
      try {
        final errResponse = ApiResponse.internalError(
          'Внутрішня помилка локального API сервера',
          exception: e,
        );
        await errResponse.sendTo(request);
      } catch (_) {}
    }
  }

  /// Serves the interactive Swagger UI HTML documentation.
  Future<void> _handleDocs(HttpRequest request) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.headers.contentType = ContentType.html;
    response.headers.set('Access-Control-Allow-Origin', '*');
    final html = _buildSwaggerHtml(port);
    final bytes = utf8.encode(html);
    response.headers.contentLength = bytes.length;
    try {
      response.add(bytes);
      await response.close();
    } catch (_) {}
  }

  String _buildSwaggerHtml(int currentPort) {
    return '''<!DOCTYPE html>
<html lang="uk">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Lumen Local API - Swagger Documentation</title>
  <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5.11.0/swagger-ui.css" />
  <style>
    body { margin: 0; background: #0f172a; color: #f8fafc; font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, sans-serif; }
    .topbar { display: none !important; }
    .swagger-ui .info .title { color: #38bdf8 !important; }
    .swagger-ui .info p, .swagger-ui .info li { color: #94a3b8 !important; }
    .swagger-ui .scheme-container { background: #1e293b !important; box-shadow: none !important; border-bottom: 1px solid #334155; }
    .swagger-ui .opblock .opblock-summary-path { color: #f1f5f9 !important; font-weight: 600; }
    .swagger-ui .opblock-description-wrapper p { color: #cbd5e1 !important; }
    .swagger-ui table thead tr td, .swagger-ui table thead tr th { color: #94a3b8 !important; }
    .swagger-ui .parameter__name { color: #e2e8f0 !important; }
    .swagger-ui .parameter__type { color: #38bdf8 !important; }
    .swagger-ui .response-col_status { color: #38bdf8 !important; }
  </style>
</head>
<body>
  <div id="swagger-ui">
    <div id="offline-fallback" style="display:none; padding: 2.5rem 1.5rem; max-width: 800px; margin: 0 auto;">
      <h2 style="color: #38bdf8; margin-top: 0;">Lumen Local REST API (Офлайн-режим)</h2>
      <p style="color: #94a3b8;">Інтерфейс Swagger UI завантажується із зовнішнього CDN. Якщо під час знеструмлення відсутнє інтернет-з'єднання, ви можете взаємодіяти з API напряму або завантажити машинночитну специфікацію:</p>
      <ul style="color: #cbd5e1; line-height: 2;">
        <li><a href="/api/v1/openapi.json" style="color: #38bdf8; font-weight: 600;" target="_blank">Специфікація OpenAPI (/api/v1/openapi.json)</a></li>
        <li><a href="/api/v1/status" style="color: #38bdf8;" target="_blank">Зведений статус системи (/api/v1/status)</a></li>
        <li><a href="/api/v1/power/current" style="color: #38bdf8;" target="_blank">Поточний стан світла (/api/v1/power/current)</a></li>
        <li><a href="/api/v1/schedule/today" style="color: #38bdf8;" target="_blank">Графік на сьогодні (/api/v1/schedule/today)</a></li>
        <li><a href="/api/v1/schedule/countdown" style="color: #38bdf8;" target="_blank">Таймер зворотного відліку (/api/v1/schedule/countdown)</a></li>
        <li><a href="/api/v1/stream" style="color: #38bdf8;" target="_blank">SSE потік подій у реальному часі (/api/v1/stream)</a></li>
      </ul>
    </div>
  </div>
  <script src="https://unpkg.com/swagger-ui-dist@5.11.0/swagger-ui-bundle.js" onerror="var f = document.getElementById('offline-fallback'); if (f) f.style.display='block';"></script>
  <script>
    window.onload = () => {
      if (typeof SwaggerUIBundle !== 'undefined') {
        window.ui = SwaggerUIBundle({
          url: '/api/v1/openapi.json',
          dom_id: '#swagger-ui',
          deepLinking: true,
          presets: [
            SwaggerUIBundle.presets.apis,
            SwaggerUIBundle.SwaggerUIStandalonePreset
          ],
          layout: "BaseLayout"
        });
      } else {
        var fallback = document.getElementById('offline-fallback');
        if (fallback) fallback.style.display = 'block';
      }
    };
  </script>
</body>
</html>''';
  }

  /// Combined dashboard status (Power + Schedule + Countdown in 1 call)
  /// Optimizes database access by preloading schedules once.
  Future<ApiResponse> _handleStatusSnapshot(HttpRequest request) async {
    final resolution = await ApiHelpers.resolveGroup(request);
    if (!resolution.isValid) {
      return ApiResponse.badRequest(resolution.error!, code: 'INVALID_GROUP');
    }

    final cachedSchedules = await HistoryService().getLastKnownSchedules();

    final powerResp = await _powerController.getCurrentStatus(request);
    final schedResp = await _scheduleController.getToday(
      request,
      preloadedSchedules: cachedSchedules,
    );
    final countResp = await _scheduleController.getCountdown(
      request,
      preloadedSchedules: cachedSchedules,
    );

    return ApiResponse.ok({
      'group': resolution.group,
      'power': powerResp.success
          ? powerResp.data
          : {'error': powerResp.error?.toMap()},
      'schedule_today': schedResp.success
          ? schedResp.data
          : {'error': schedResp.error?.toMap()},
      'countdown': countResp.success
          ? countResp.data
          : {'error': countResp.error?.toMap()},
    });
  }

  /// System health & diagnostics
  Future<ApiResponse> _handleHealthCheck(HttpRequest request) async {
    String version = 'unknown';
    try {
      version = await AppInfoService.getAppVersion();
    } catch (_) {}

    return ApiResponse.ok({
      'status': 'healthy',
      'uptime_seconds': uptime.inSeconds,
      'started_at': _startedAt?.toUtc().toIso8601String(),
      'app_version': version,
      'platform': Platform.operatingSystem,
      'port': port,
      'host': '127.0.0.1',
    });
  }

  Future<ApiResponse> _routePower(HttpRequest request, String path) async {
    const prefix = '/api/v1/power';
    final subPath =
        path.length > prefix.length ? path.substring(prefix.length + 1) : '';

    switch (subPath) {
      case 'current':
        if (request.method == 'GET') {
          return await _powerController.getCurrentStatus(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /power/current підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
      case 'events':
        if (request.method == 'GET') {
          return await _powerController.getEvents(request);
        }
        if (request.method == 'POST') {
          final resp = await _powerController.addManualEvent(request);
          // Broadcast manual event creation to SSE stream
          if (resp.success) {
            _streamController?.broadcast('manual_event_added', resp.data);
          }
          return resp;
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /power/events підтримує лише методи GET та POST',
          allowedMethods: ['GET', 'POST'],
        );
      case 'intervals':
        if (request.method == 'GET') {
          return await _powerController.getIntervals(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /power/intervals підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
      case 'refresh':
        if (request.method == 'POST') {
          return await _powerController.triggerRefresh(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /power/refresh підтримує лише метод POST',
          allowedMethods: ['POST'],
        );
    }
    return ApiResponse.notFound(
      'Ендпоінт /power/$subPath не знайдено',
      code: 'ROUTE_NOT_FOUND',
    );
  }

  Future<ApiResponse> _routeSchedule(HttpRequest request, String path) async {
    const prefix = '/api/v1/schedule';
    final subPath =
        path.length > prefix.length ? path.substring(prefix.length + 1) : '';

    if (subPath == 'today') {
      if (request.method == 'GET') {
        return await _scheduleController.getToday(request);
      }
      return ApiResponse.methodNotAllowed(
        'Ендпоінт /schedule/today підтримує лише метод GET',
        allowedMethods: ['GET'],
      );
    } else if (subPath == 'tomorrow') {
      if (request.method == 'GET') {
        return await _scheduleController.getTomorrow(request);
      }
      return ApiResponse.methodNotAllowed(
        'Ендпоінт /schedule/tomorrow підтримує лише метод GET',
        allowedMethods: ['GET'],
      );
    } else if (subPath == 'countdown') {
      if (request.method == 'GET') {
        return await _scheduleController.getCountdown(request);
      }
      return ApiResponse.methodNotAllowed(
        'Ендпоінт /schedule/countdown підтримує лише метод GET',
        allowedMethods: ['GET'],
      );
    } else if (subPath == 'groups') {
      if (request.method == 'GET') {
        return await _scheduleController.getAllGroups(request);
      }
      return ApiResponse.methodNotAllowed(
        'Ендпоінт /schedule/groups підтримує лише метод GET',
        allowedMethods: ['GET'],
      );
    } else if (subPath == 'sync') {
      if (request.method == 'POST') {
        // Sync completion will trigger _scheduleSubscription in StreamController automatically
        return await _scheduleController.triggerSync(request);
      }
      return ApiResponse.methodNotAllowed(
        'Ендпоінт /schedule/sync підтримує лише метод POST',
        allowedMethods: ['POST'],
      );
    } else if (subPath.startsWith('group/')) {
      if (request.method == 'GET') {
        final groupId = subPath.substring('group/'.length);
        return await _scheduleController.getGroupSchedule(request, groupId);
      }
      return ApiResponse.methodNotAllowed(
        'Ендпоінт /schedule/group/{id} підтримує лише метод GET',
        allowedMethods: ['GET'],
      );
    }

    return ApiResponse.notFound(
      'Ендпоінт /schedule/$subPath не знайдено',
      code: 'ROUTE_NOT_FOUND',
    );
  }

  Future<ApiResponse> _routeHistory(HttpRequest request, String path) async {
    const prefix = '/api/v1/history';
    final subPath =
        path.length > prefix.length ? path.substring(prefix.length + 1) : '';

    switch (subPath) {
      case 'versions':
        if (request.method == 'GET') {
          return await _historyController.getVersions(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /history/versions підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
      case 'dates':
        if (request.method == 'GET') {
          return await _historyController.getDates(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /history/dates підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
      case 'export':
        if (request.method == 'GET') {
          return await _historyController.exportHistory(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /history/export підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
      case 'logs':
        if (request.method == 'GET') {
          return await _historyController.getLogs(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /history/logs підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
    }
    return ApiResponse.notFound(
      'Ендпоінт /history/$subPath не знайдено',
      code: 'ROUTE_NOT_FOUND',
    );
  }

  Future<ApiResponse> _routeAnalytics(HttpRequest request, String path) async {
    const prefix = '/api/v1/analytics';
    final subPath =
        path.length > prefix.length ? path.substring(prefix.length + 1) : '';

    switch (subPath) {
      case 'stats':
        if (request.method == 'GET') {
          return await _analyticsController.getStats(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /analytics/stats підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
      case 'accuracy':
        if (request.method == 'GET') {
          return await _analyticsController.getAccuracy(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /analytics/accuracy підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
      case 'switch-lag':
        if (request.method == 'GET') {
          return await _analyticsController.getSwitchLag(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /analytics/switch-lag підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
      case 'records':
        if (request.method == 'GET') {
          return await _analyticsController.getRecords(request);
        }
        return ApiResponse.methodNotAllowed(
          'Ендпоінт /analytics/records підтримує лише метод GET',
          allowedMethods: ['GET'],
        );
    }
    return ApiResponse.notFound(
      'Ендпоінт /analytics/$subPath не знайдено',
      code: 'ROUTE_NOT_FOUND',
    );
  }

  Future<void> _sendCorsPreflight(HttpRequest request) async {
    final res = request.response;
    res.statusCode = HttpStatus.noContent;
    res.headers.set('Access-Control-Allow-Origin', '*');
    res.headers.set('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
    res.headers.set('Access-Control-Allow-Headers',
        'Origin, X-Requested-With, Content-Type, Accept, Authorization');
    res.headers.set('Access-Control-Allow-Private-Network', 'true');
    res.headers.set('Access-Control-Max-Age', '86400');
    try {
      await res.close();
    } catch (_) {}
  }
}
