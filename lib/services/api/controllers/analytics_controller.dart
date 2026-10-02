import 'dart:io';

import '../../analytics_service.dart';
import '../../app_logger.dart';
import '../api_helpers.dart';
import '../api_response.dart';

class AnalyticsController {
  final AnalyticsService _analyticsService;

  AnalyticsController({AnalyticsService? analyticsService})
      : _analyticsService = analyticsService ?? AnalyticsService();

  /// GET /api/v1/analytics/stats?days=7&mode=real&group=GPV2.1
  Future<ApiResponse> getStats(HttpRequest request) async {
    try {
      final daysStr = request.uri.queryParameters['days'] ?? '7';
      final days = (int.tryParse(daysStr) ?? 7).clamp(1, 365);

      final resolution = await ApiHelpers.resolveGroup(request);
      if (!resolution.isValid) {
        return ApiResponse.badRequest(resolution.error!, code: 'INVALID_GROUP');
      }
      final group = resolution.group!;
      final mode = ApiHelpers.resolveMode(request);

      final stats = await _analyticsService.getOutageStatsForPeriod(
        days,
        mode: mode,
        groupKey: group,
      );

      final data = {
        'period_days': days,
        'group': group,
        'mode': mode.name,
        'total_outage_minutes': stats.totalMinutes,
        'total_outage_hours': (stats.totalMinutes / 60.0).toStringAsFixed(1),
        'formatted_total': stats.totalFormatted,
        'outage_percentage': stats.percentage.round(),
        'average_duration_minutes': stats.avgDurationMinutes,
        'formatted_average_duration': stats.avgFormatted,
        'outages_count': stats.count,
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getStats',
          tag: 'AnalyticsController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка розрахунку статистики',
          exception: e);
    }
  }

  /// GET /api/v1/analytics/accuracy?days=7&group=GPV2.1
  Future<ApiResponse> getAccuracy(HttpRequest request) async {
    try {
      final daysStr = request.uri.queryParameters['days'] ?? '7';
      final days = (int.tryParse(daysStr) ?? 7).clamp(1, 365);

      final resolution = await ApiHelpers.resolveGroup(request);
      if (!resolution.isValid) {
        return ApiResponse.badRequest(resolution.error!, code: 'INVALID_GROUP');
      }
      final group = resolution.group!;

      final score =
          await _analyticsService.getAccuracyScoreForPeriod(days, group);

      final hasValidScore = score >= 0;

      final data = {
        'period_days': days,
        'group': group,
        'has_data': hasValidScore,
        'accuracy_score': hasValidScore ? score : null,
        'accuracy_percentage': hasValidScore ? (score * 100).round() : null,
        'description':
            'Відсоток збігу запланованих ДТЕК відключень із реальними даними сенсора',
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getAccuracy',
          tag: 'AnalyticsController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка розрахунку точності графіків',
          exception: e);
    }
  }

  /// GET /api/v1/analytics/switch-lag?days=7&group=GPV2.1
  Future<ApiResponse> getSwitchLag(HttpRequest request) async {
    try {
      final daysStr = request.uri.queryParameters['days'] ?? '7';
      final days = (int.tryParse(daysStr) ?? 7).clamp(1, 365);

      final resolution = await ApiHelpers.resolveGroup(request);
      if (!resolution.isValid) {
        return ApiResponse.badRequest(resolution.error!, code: 'INVALID_GROUP');
      }
      final group = resolution.group!;

      final lag = await _analyticsService.getSwitchLag(
        0,
        days - 1,
        group,
      );

      final hasSamples = lag.sampleCount > 0;

      final data = {
        'period_days': days,
        'group': group,
        'sample_count': lag.sampleCount,
        'has_data': hasSamples,
        'avg_on_lag_minutes': hasSamples ? lag.avgOnLagMinutes : null,
        'avg_off_lag_minutes': hasSamples ? lag.avgOffLagMinutes : null,
        'interpretation': {
          'on_lag': !hasSamples
              ? 'Недостатньо даних для аналізу затримки включення'
              : (lag.avgOnLagMinutes > 0
                  ? 'Світло вмикають пізніше графіка в середньому на ${lag.avgOnLagMinutes.toStringAsFixed(1)} хв'
                  : (lag.avgOnLagMinutes < 0
                      ? 'Світло вмикають раніше графіка в середньому на ${(-lag.avgOnLagMinutes).toStringAsFixed(1)} хв'
                      : 'Світло вмикають точно за графіком')),
          'off_lag': !hasSamples
              ? 'Недостатньо даних для аналізу затримки виключення'
              : (lag.avgOffLagMinutes > 0
                  ? 'Світло вимикають пізніше графіка в середньому на ${lag.avgOffLagMinutes.toStringAsFixed(1)} хв'
                  : (lag.avgOffLagMinutes < 0
                      ? 'Світло вимикають раніше графіка в середньому на ${(-lag.avgOffLagMinutes).toStringAsFixed(1)} хв'
                      : 'Світло вимикають точно за графіком')),
        },
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getSwitchLag',
          tag: 'AnalyticsController', error: e, stackTrace: stack);
      return ApiResponse.internalError(
          'Помилка розрахунку затримки перемикання',
          exception: e);
    }
  }

  /// GET /api/v1/analytics/records?mode=real&group=GPV2.1
  Future<ApiResponse> getRecords(HttpRequest request) async {
    try {
      final resolution = await ApiHelpers.resolveGroup(request);
      if (!resolution.isValid) {
        return ApiResponse.badRequest(resolution.error!, code: 'INVALID_GROUP');
      }
      final group = resolution.group!;
      final mode = ApiHelpers.resolveMode(request);

      final records = await _analyticsService.getRecords(
        mode: mode,
        groupKey: group,
      );

      final data = {
        'group': group,
        'mode': mode.name,
        'longest_outage': records.longestOutage != null
            ? {
                'start': records.longestOutage!.start.toUtc().toIso8601String(),
                'end': records.longestOutage!.end.toUtc().toIso8601String(),
                'duration_minutes': records.longestOutage!.duration.inMinutes,
                'formatted': records.longestOutage!.durationFormatted,
                'date': records.longestOutage!.dateFormatted,
              }
            : null,
        'longest_uptime': records.longestUptime != null
            ? {
                'start': records.longestUptime!.start.toUtc().toIso8601String(),
                'end': records.longestUptime!.end.toUtc().toIso8601String(),
                'duration_minutes': records.longestUptime!.duration.inMinutes,
                'formatted': records.longestUptime!.durationFormatted,
                'date': records.longestUptime!.dateFormatted,
              }
            : null,
        'shortest_uptime': records.shortestUptime != null
            ? {
                'start':
                    records.shortestUptime!.start.toUtc().toIso8601String(),
                'end': records.shortestUptime!.end.toUtc().toIso8601String(),
                'duration_minutes': records.shortestUptime!.duration.inMinutes,
                'formatted': records.shortestUptime!.durationFormatted,
                'date': records.shortestUptime!.dateFormatted,
              }
            : null,
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getRecords',
          tag: 'AnalyticsController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка отримання рекордів',
          exception: e);
    }
  }
}
