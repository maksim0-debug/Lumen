import 'dart:io';

import '../../app_logger.dart';
import '../../history_service.dart';
import '../api_helpers.dart';
import '../api_response.dart';

class HistoryController {
  final HistoryService _historyService;

  HistoryController({HistoryService? historyService})
      : _historyService = historyService ?? HistoryService();

  /// GET /api/v1/history/versions?date=YYYY-MM-DD&group=GPV2.1
  Future<ApiResponse> getVersions(HttpRequest request) async {
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

      final resolution = await ApiHelpers.resolveGroup(request);
      if (!resolution.isValid) {
        return ApiResponse.badRequest(resolution.error!, code: 'INVALID_GROUP');
      }
      final group = resolution.group!;

      final versions =
          await _historyService.getVersionsForDate(targetDate, group);

      final dateOnlyStr =
          "${targetDate.year}-${targetDate.month.toString().padLeft(2, '0')}-${targetDate.day.toString().padLeft(2, '0')}";

      final versionsData = <Map<String, dynamic>>[];
      for (int i = 0; i < versions.length; i++) {
        final v = versions[i];
        final schedule = v.toSchedule();
        final slots = schedule.toSlots();

        versionsData.add({
          'version_number': i + 1,
          'saved_at': v.savedAt.toUtc().toIso8601String(),
          'time_string': v.timeString,
          'outage_minutes': v.outageMinutes,
          'outage_formatted': v.outageString,
          'schedule_code': v.hash,
          'slots': slots.map((s) => s.name).toList(),
          'intervals': ApiHelpers.buildStructuredIntervals(schedule),
        });
      }

      final data = {
        'date': dateOnlyStr,
        'group': group,
        'versions_count': versionsData.length,
        'versions': versionsData,
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getVersions',
          tag: 'HistoryController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка завантаження версій графіка',
          exception: e);
    }
  }

  /// GET /api/v1/history/dates
  Future<ApiResponse> getDates(HttpRequest request) async {
    try {
      final dates = await _historyService.getAvailableDates();
      return ApiResponse.ok({
        'count': dates.length,
        'dates': dates,
      });
    } catch (e, stack) {
      AppLogger.e('Error in getDates',
          tag: 'HistoryController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка отримання списку дат',
          exception: e);
    }
  }

  /// GET /api/v1/history/export?from=YYYY-MM-DD&to=YYYY-MM-DD
  Future<ApiResponse> exportHistory(HttpRequest request) async {
    try {
      final queryParams = request.uri.queryParameters;
      final fromStr = queryParams['from'];
      final toStr = queryParams['to'];

      DateTime? fromDate;
      DateTime? toDate;

      final hasFrom = fromStr != null && fromStr.trim().isNotEmpty;
      final hasTo = toStr != null && toStr.trim().isNotEmpty;

      if (hasFrom != hasTo) {
        return ApiResponse.badRequest(
          'Неповний діапазон дат. Необхідно вказати обидва параметри: from=YYYY-MM-DD та to=YYYY-MM-DD, або жодного для повного експорту.',
          code: 'INCOMPLETE_DATE_RANGE',
        );
      }

      if (hasFrom && hasTo) {
        fromDate = DateTime.tryParse(fromStr.trim());
        toDate = DateTime.tryParse(toStr.trim());

        if (fromDate == null || toDate == null) {
          return ApiResponse.badRequest(
            'Некоректний формат дат. Очікується from=YYYY-MM-DD&to=YYYY-MM-DD',
            code: 'INVALID_DATE_RANGE',
          );
        }

        if (fromDate.isAfter(toDate)) {
          return ApiResponse.badRequest(
            'Дата from не може бути пізніше за дату to',
            code: 'INVALID_DATE_ORDER',
          );
        }
      }

      final exportMap = await _historyService.getExportDataMap(
        startDate: fromDate,
        endDate: toDate,
      );

      return ApiResponse.ok(exportMap);
    } catch (e, stack) {
      AppLogger.e('Error in exportHistory',
          tag: 'HistoryController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка експорту історії',
          exception: e);
    }
  }

  /// GET /api/v1/history/logs?limit=50
  Future<ApiResponse> getLogs(HttpRequest request) async {
    try {
      final limitStr = request.uri.queryParameters['limit'] ?? '50';
      final limit = (int.tryParse(limitStr) ?? 50).clamp(1, 500);

      final logs = await _historyService.getLogs(limit: limit);

      return ApiResponse.ok({
        'count': logs.length,
        'limit': limit,
        'logs': logs,
      });
    } catch (e, stack) {
      AppLogger.e('Error in getLogs',
          tag: 'HistoryController', error: e, stackTrace: stack);
      return ApiResponse.internalError(
          'Помилка завантаження системних журналів',
          exception: e);
    }
  }
}
