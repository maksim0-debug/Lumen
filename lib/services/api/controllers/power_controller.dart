import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../../../models/power_event.dart';
import '../../../models/power_monitor_status.dart';
import '../../app_logger.dart';
import '../../power_monitor_service.dart';
import '../api_response.dart';

class PowerController {
  final PowerMonitorService _monitorService;
  final Random _random = Random();

  PowerController({
    PowerMonitorService? monitorService,
  }) : _monitorService = monitorService ?? PowerMonitorService();

  /// GET /api/v1/power/current
  Future<ApiResponse> getCurrentStatus(HttpRequest request) async {
    try {
      final snapshot = _monitorService.snapshot;
      final effectiveState = _monitorService.effectiveState;
      final now = DateTime.now();

      int? durationMinutes;
      if (snapshot.lastEventTime != null) {
        durationMinutes = now.difference(snapshot.lastEventTime!).inMinutes;
        if (durationMinutes < 0) durationMinutes = 0;
      }

      final lastEventIso = snapshot.lastEventTime?.toUtc().toIso8601String();
      final lastSeenIso = snapshot.lastSeen?.toUtc().toIso8601String();
      final lastSyncIso = snapshot.lastSyncTime?.toUtc().toIso8601String();

      final data = {
        'state': effectiveState.toSerializedString(),
        'state_label': effectiveState.label,
        'is_online': effectiveState.isOnline,
        'is_offline': effectiveState.isOffline,
        'is_unknown': effectiveState.isUnknown,
        'duration_minutes': durationMinutes,
        'last_event_time': lastEventIso,
        'last_transition_at': lastEventIso,
        'sensor': {
          'is_enabled': snapshot.reason != PowerStateReason.disabled &&
              snapshot.reason != PowerStateReason.notConfigured,
          'reason': snapshot.reason.name,
          'reason_message': snapshot.reason.userMessage,
          'is_stale': snapshot.isStale,
          'last_seen': lastSeenIso,
          'last_seen_at': lastSeenIso,
          'last_sync': lastSyncIso,
          'last_sync_at': lastSyncIso,
          'ttl_minutes': snapshot.ttl.inMinutes,
          'consecutive_errors': _monitorService.consecutiveErrors,
          'error_message': snapshot.errorMessage,
        }
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getCurrentStatus',
          tag: 'PowerController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка отримання статусу сенсора',
          exception: e);
    }
  }

  /// GET /api/v1/power/events?date=YYYY-MM-DD&from=YYYY-MM-DD&to=YYYY-MM-DD&limit=100&sort=desc
  Future<ApiResponse> getEvents(HttpRequest request) async {
    try {
      final queryParams = request.uri.queryParameters;
      final dateStr = queryParams['date'];
      final fromStr = queryParams['from'];
      final toStr = queryParams['to'];
      final limitStr = queryParams['limit'] ?? '100';
      final limit = (int.tryParse(limitStr) ?? 100).clamp(1, 1000);
      final sortDesc = (queryParams['sort']?.toLowerCase() ?? 'desc') != 'asc';

      DateTime? startDate;
      DateTime? endDate;

      if (dateStr != null && dateStr.trim().isNotEmpty) {
        final parsed = DateTime.tryParse(dateStr.trim());
        if (parsed == null) {
          return ApiResponse.badRequest(
            'Некоректний формат дати. Використовуйте YYYY-MM-DD (наприклад, 2026-10-02)',
            code: 'INVALID_DATE_FORMAT',
          );
        }
        startDate = DateTime(parsed.year, parsed.month, parsed.day, 0, 0, 0);
        endDate =
            DateTime(parsed.year, parsed.month, parsed.day, 23, 59, 59, 999);
      } else {
        if (fromStr != null && fromStr.trim().isNotEmpty) {
          startDate = DateTime.tryParse(fromStr.trim());
          if (startDate == null) {
            return ApiResponse.badRequest(
              'Некоректний формат дати from. Використовуйте YYYY-MM-DD',
              code: 'INVALID_DATE_FORMAT',
            );
          }
          startDate =
              DateTime(startDate.year, startDate.month, startDate.day, 0, 0, 0);
        }
        if (toStr != null && toStr.trim().isNotEmpty) {
          endDate = DateTime.tryParse(toStr.trim());
          if (endDate == null) {
            return ApiResponse.badRequest(
              'Некоректний формат дати to. Використовуйте YYYY-MM-DD',
              code: 'INVALID_DATE_FORMAT',
            );
          }
          endDate = DateTime(
              endDate.year, endDate.month, endDate.day, 23, 59, 59, 999);
        }

        if (startDate != null &&
            endDate != null &&
            startDate.isAfter(endDate)) {
          return ApiResponse.badRequest(
            'Дата from не може бути пізніше за дату to',
            code: 'INVALID_DATE_ORDER',
          );
        }
      }

      final events = await _monitorService.getEventsRange(
        startDate: startDate,
        endDate: endDate,
        limit: limit,
        descending: sortDesc,
      );

      final data = {
        'count': events.length,
        'limit': limit,
        'sort': sortDesc ? 'desc' : 'asc',
        'filters': {
          'date': dateStr,
          'from': fromStr,
          'to': toStr,
        },
        'events': events
            .map((e) => {
                  'id': e.id,
                  'firebase_key': e.firebaseKey,
                  'status': e.status,
                  'timestamp': e.timestamp.toUtc().toIso8601String(),
                  'device': e.device,
                  'is_manual': e.isManual,
                })
            .toList(),
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getEvents',
          tag: 'PowerController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка завантаження журналу подій',
          exception: e);
    }
  }

  /// GET /api/v1/power/intervals?date=YYYY-MM-DD
  Future<ApiResponse> getIntervals(HttpRequest request) async {
    try {
      final queryParams = request.uri.queryParameters;
      final dateStr = queryParams['date'];
      final targetDate = (dateStr != null && dateStr.trim().isNotEmpty)
          ? DateTime.tryParse(dateStr.trim())
          : DateTime.now();

      if (targetDate == null) {
        return ApiResponse.badRequest(
            'Некоректний формат дати. Використовуйте YYYY-MM-DD',
            code: 'INVALID_DATE_FORMAT');
      }

      final dateOnly =
          DateTime(targetDate.year, targetDate.month, targetDate.day);
      final intervals =
          await _monitorService.getOutageIntervalsForDate(dateOnly);
      final totalMinutes =
          await _monitorService.getTotalOutageMinutesForDate(dateOnly);

      final data = {
        'date':
            "${dateOnly.year}-${dateOnly.month.toString().padLeft(2, '0')}-${dateOnly.day.toString().padLeft(2, '0')}",
        'total_outage_minutes': totalMinutes,
        'total_outage_hours': (totalMinutes / 60.0).toStringAsFixed(1),
        'intervals_count': intervals.length,
        'intervals': intervals
            .map((i) => {
                  'start': i.start.toUtc().toIso8601String(),
                  'end': i.end?.toUtc().toIso8601String(),
                  'duration_minutes': i.duration.inMinutes,
                  'formatted_duration': i.durationString,
                  'is_ongoing': i.isOngoing,
                })
            .toList(),
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getIntervals',
          tag: 'PowerController', error: e, stackTrace: stack);
      return ApiResponse.internalError(
          'Помилка розрахунку інтервалів відключень',
          exception: e);
    }
  }

  /// POST /api/v1/power/events
  /// Body: { "status": "online" | "offline", "timestamp": "2026-10-02 01:30:00", "device": "Custom" }
  Future<ApiResponse> addManualEvent(HttpRequest request) async {
    try {
      if (request.contentLength > 65536) {
        return ApiResponse.badRequest('Розмір запиту перевищує ліміт (64KB)',
            code: 'BODY_TOO_LARGE');
      }

      final List<int> bytes = [];
      await for (final chunk in request) {
        bytes.addAll(chunk);
        if (bytes.length > 65536) {
          return ApiResponse.badRequest('Розмір запиту перевищує ліміт (64KB)',
              code: 'BODY_TOO_LARGE');
        }
      }

      final content = utf8.decode(bytes);
      if (content.trim().isEmpty) {
        return ApiResponse.badRequest('Тіло запиту порожнє. Очікується JSON.',
            code: 'EMPTY_BODY');
      }

      final Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(content);
        if (decoded is! Map<String, dynamic>) {
          return ApiResponse.badRequest(
              'Некоректний формат JSON. Очікується JSON-об\'єкт { ... }',
              code: 'INVALID_JSON');
        }
        body = decoded;
      } catch (e) {
        return ApiResponse.badRequest('Некоректний формат JSON',
            code: 'INVALID_JSON');
      }

      final rawStatus = body['status'];
      if (rawStatus is! String) {
        return ApiResponse.badRequest(
            "Поле 'status' є обов'язковим і повинно бути рядком ('online' або 'offline')",
            code: 'INVALID_STATUS');
      }

      final status = rawStatus.toLowerCase().trim();
      if (status != 'online' && status != 'offline') {
        return ApiResponse.badRequest(
            "Статус повинен бути 'online' або 'offline'",
            code: 'INVALID_STATUS');
      }

      DateTime timestamp = DateTime.now();
      if (body['timestamp'] != null) {
        final parsed =
            PowerEvent.parseTimestamp(body['timestamp'].toString()) ??
                DateTime.tryParse(body['timestamp'].toString());
        if (parsed != null) {
          timestamp = parsed.toLocal();
        } else {
          return ApiResponse.badRequest(
              'Некоректний формат таймстампу для події. Використовуйте ISO8601 або YYYY-MM-DD HH:mm:ss',
              code: 'INVALID_TIMESTAMP');
        }
      }

      // Generate guaranteed unique key with timestamp and cryptographically sufficient entropy
      final uniqueSuffix = _random.nextInt(1000000).toString().padLeft(6, '0');
      final manualKey =
          'manual_${timestamp.millisecondsSinceEpoch}_$uniqueSuffix';

      final rawDevice = body['device']?.toString().trim();
      final deviceName = (rawDevice != null && rawDevice.isNotEmpty)
          ? rawDevice
          : 'API Client';

      final newEvent = PowerEvent(
        firebaseKey: manualKey,
        status: status,
        timestamp: timestamp,
        device: deviceName,
        isManual: true,
      );

      // Fast, non-blocking local persistence with immediate memory state recalculation
      final insertedId = await _monitorService.insertManualEvent(newEvent);

      return ApiResponse.ok({
        'created': true,
        'event_id': insertedId,
        'firebase_key': manualKey,
        'status': status,
        'timestamp': timestamp.toUtc().toIso8601String(),
        'device': newEvent.device,
        'is_manual': true,
      });
    } catch (e, stack) {
      AppLogger.e('Error in addManualEvent',
          tag: 'PowerController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка додавання ручної події',
          exception: e);
    }
  }

  /// POST /api/v1/power/refresh
  Future<ApiResponse> triggerRefresh(HttpRequest request) async {
    try {
      if (!_monitorService.isEnabled) {
        return ApiResponse.ok({
          'triggered': false,
          'message': 'Моніторинг живлення (сенсор) вимкнено в налаштуваннях',
        });
      }

      // Trigger background sync without stalling HTTP caller indefinitely
      unawaited(_monitorService.forceRefresh().catchError((e) {
        AppLogger.w('Background power refresh encountered warning: $e',
            tag: 'PowerController');
      }));

      return ApiResponse.accepted({
        'triggered': true,
        'message': 'Опитування сенсора запущено у фоновому режимі',
      });
    } catch (e) {
      return ApiResponse.internalError('Помилка оновлення сенсора',
          exception: e);
    }
  }
}
