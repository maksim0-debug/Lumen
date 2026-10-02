import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../../app_logger.dart';
import '../../../models/schedule_status.dart';
import '../../power_monitor_service.dart';
import '../../schedule_sync_service.dart';

/// Server-Sent Events (SSE) controller for real-time state streaming over HTTP.
/// Endpoint: GET /api/v1/stream
class SseStreamController {
  final PowerMonitorService _powerMonitor;
  final Set<HttpResponse> _clients = {};
  Timer? _heartbeatTimer;
  void Function(String status)? _listener;
  StreamSubscription<Map<String, FullSchedule>>? _scheduleSubscription;

  SseStreamController({PowerMonitorService? powerMonitor})
      : _powerMonitor = powerMonitor ?? PowerMonitorService() {
    _initListener();
    _startHeartbeat();
  }

  void _initListener() {
    _listener = (status) {
      final snapshot = _powerMonitor.snapshot;
      broadcast('power_status', {
        'state': status,
        'reason': snapshot.reason.name,
        'reason_message': snapshot.reason.userMessage,
        'is_stale': snapshot.isStale,
        'timestamp': DateTime.now().toUtc().toIso8601String(),
      });
    };
    _powerMonitor.addStatusListener(_listener!);

    _scheduleSubscription =
        ScheduleSyncService.onSyncCompleted.listen((schedules) {
      broadcast('schedule_updated', {
        'timestamp': DateTime.now().toUtc().toIso8601String(),
        'groups_count': schedules.length,
        'source': 'dtek_sync',
      });
    });
  }

  void _startHeartbeat() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = Timer.periodic(const Duration(seconds: 25), (_) {
      _sendHeartbeat();
    });
  }

  void _sendHeartbeat() {
    if (_clients.isEmpty) return;

    final deadClients = <HttpResponse>[];
    for (final client in _clients) {
      try {
        client.write(': ping\n\n');
      } catch (_) {
        deadClients.add(client);
      }
    }

    for (final dead in deadClients) {
      _clients.remove(dead);
      try {
        dead.close();
      } catch (_) {}
    }
  }

  /// Handles incoming SSE subscription request.
  Future<void> handleStream(HttpRequest request) async {
    final response = request.response;
    response.statusCode = HttpStatus.ok;
    response.bufferOutput = false;

    response.headers.contentType =
        ContentType('text', 'event-stream', charset: 'utf-8');
    response.headers.set('Cache-Control', 'no-cache, no-transform');
    response.headers.set('Connection', 'keep-alive');
    response.headers.set('X-Accel-Buffering', 'no');
    response.headers.set('Access-Control-Allow-Origin', '*');
    response.headers.set('Access-Control-Allow-Methods', 'GET, OPTIONS');
    response.headers.set('Access-Control-Allow-Headers',
        'Origin, X-Requested-With, Content-Type, Accept, Authorization');

    _clients.add(response);
    AppLogger.d('SSE client connected. Active clients: ${_clients.length}',
        tag: 'SseStreamController');

    // Clean up when client disconnects
    response.done.then((_) {
      _clients.remove(response);
      AppLogger.d('SSE client disconnected. Active clients: ${_clients.length}',
          tag: 'SseStreamController');
    }).catchError((_) {
      _clients.remove(response);
    });

    // 1. Initial connection acknowledgement
    final initialPayload = {
      'status': 'connected',
      'timestamp': DateTime.now().toUtc().toIso8601String(),
      'active_clients': _clients.length,
    };
    response.write('event: connected\ndata: ${jsonEncode(initialPayload)}\n\n');

    // 2. Immediate current power status dispatch
    final snapshot = _powerMonitor.snapshot;
    final currentPayload = {
      'state': _powerMonitor.effectiveState.toSerializedString(),
      'reason': snapshot.reason.name,
      'reason_message': snapshot.reason.userMessage,
      'is_stale': snapshot.isStale,
      'timestamp': DateTime.now().toUtc().toIso8601String(),
    };
    response
        .write('event: power_status\ndata: ${jsonEncode(currentPayload)}\n\n');

    try {
      await response.flush();
    } catch (_) {
      _clients.remove(response);
      return;
    }
  }

  /// Broadcasts an event to all connected SSE clients.
  void broadcast(String event, Map<String, dynamic> data) {
    if (_clients.isEmpty) return;

    final message = 'event: $event\ndata: ${jsonEncode(data)}\n\n';
    final deadClients = <HttpResponse>[];

    for (final client in _clients) {
      try {
        client.write(message);
      } catch (_) {
        deadClients.add(client);
      }
    }

    for (final dead in deadClients) {
      _clients.remove(dead);
      try {
        dead.close();
      } catch (_) {}
    }
  }

  /// Closes all active client connections and disposes resources.
  void dispose() {
    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;
    if (_listener != null) {
      _powerMonitor.removeStatusListener(_listener!);
      _listener = null;
    }
    _scheduleSubscription?.cancel();
    _scheduleSubscription = null;

    for (final client in _clients) {
      try {
        client.close();
      } catch (_) {}
    }
    _clients.clear();
  }
}
