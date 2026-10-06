import '../../schedule_clock.dart';
import 'dart:io';

import '../../../models/schedule_status.dart';
import '../../app_logger.dart';
import '../../countdown_service.dart';
import '../../parser_service.dart';
import '../../schedule_sync_service.dart';
import '../api_helpers.dart';
import '../api_response.dart';

class ScheduleController {
  final ScheduleSyncService _syncService;

  ScheduleController({
    ScheduleSyncService? syncService,
  }) : _syncService = syncService ?? ScheduleSyncService();

  Future<Map<String, FullSchedule>> _getSchedules() async {
    return await _syncService.loadCachedData();
  }

  /// GET /api/v1/schedule/today?group=GPV2.1
  Future<ApiResponse> getToday(HttpRequest request,
      {Map<String, FullSchedule>? preloadedSchedules}) async {
    try {
      final resolution = await ApiHelpers.resolveGroup(request);
      if (!resolution.isValid) {
        return ApiResponse.badRequest(resolution.error!, code: 'INVALID_GROUP');
      }
      final group = resolution.group!;

      final schedules = preloadedSchedules ?? await _getSchedules();
      final fullSchedule = schedules[group];

      final now = ScheduleClock.now();
      final todayStr =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

      if (fullSchedule == null || fullSchedule.today.isEmpty) {
        return ApiResponse.ok({
          'date': todayStr,
          'group': group,
          'is_available': false,
          'status': 'no_data',
          'message': 'Графік на сьогодні відсутній у локальному кеші',
          'last_updated_source': fullSchedule?.lastUpdatedSource ?? 'Невідомо',
          'schedule': null,
        });
      }

      final today = fullSchedule.today;
      final outageMinutes = today.totalOutageMinutes;
      final slots = today.toSlots();
      final intervals = ApiHelpers.buildStructuredIntervals(today);

      final data = {
        'date': todayStr,
        'group': group,
        'is_available': true,
        'status': 'available',
        'total_outage_minutes': outageMinutes,
        'total_outage_hours': (outageMinutes / 60.0).toStringAsFixed(1),
        'outage_percentage': ((outageMinutes / 1440.0) * 100).round(),
        'last_updated_source': fullSchedule.lastUpdatedSource,
        'intervals': intervals,
        'slots': slots.map((s) => s.name).toList(),
        'hours_code': today.toEncodedString(),
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getToday',
          tag: 'ScheduleController', error: e, stackTrace: stack);
      return ApiResponse.internalError(
          'Помилка завантаження графіка на сьогодні',
          exception: e);
    }
  }

  /// GET /api/v1/schedule/tomorrow?group=GPV2.1
  Future<ApiResponse> getTomorrow(HttpRequest request,
      {Map<String, FullSchedule>? preloadedSchedules}) async {
    try {
      final resolution = await ApiHelpers.resolveGroup(request);
      if (!resolution.isValid) {
        return ApiResponse.badRequest(resolution.error!, code: 'INVALID_GROUP');
      }
      final group = resolution.group!;

      final schedules = preloadedSchedules ?? await _getSchedules();
      final fullSchedule = schedules[group];

      final tomorrow = ScheduleClock.day(ScheduleClock.now(), 1);
      final tomorrowStr =
          "${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}";

      if (fullSchedule == null || fullSchedule.tomorrow.isEmpty) {
        return ApiResponse.ok({
          'date': tomorrowStr,
          'group': group,
          'is_available': false,
          'status': 'not_published',
          'message': 'Графік на завтра ще не оприлюднено на сайті ДТЕК',
          'last_checked_source': fullSchedule?.lastUpdatedSource ?? 'Невідомо',
          'schedule': null,
        });
      }

      final sched = fullSchedule.tomorrow;
      final outageMinutes = sched.totalOutageMinutes;
      final slots = sched.toSlots();
      final intervals = ApiHelpers.buildStructuredIntervals(sched);

      final data = {
        'date': tomorrowStr,
        'group': group,
        'is_available': true,
        'status': 'published',
        'total_outage_minutes': outageMinutes,
        'total_outage_hours': (outageMinutes / 60.0).toStringAsFixed(1),
        'outage_percentage': ((outageMinutes / 1440.0) * 100).round(),
        'last_updated_source': fullSchedule.lastUpdatedSource,
        'intervals': intervals,
        'slots': slots.map((s) => s.name).toList(),
        'hours_code': sched.toEncodedString(),
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getTomorrow',
          tag: 'ScheduleController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка завантаження графіка на завтра',
          exception: e);
    }
  }

  /// GET /api/v1/schedule/group/{id} (Today + Tomorrow for specific GPV group)
  Future<ApiResponse> getGroupSchedule(
      HttpRequest request, String rawGroupId) async {
    try {
      final normalized = rawGroupId.trim().toUpperCase();
      if (!ParserService.allGroups.contains(normalized)) {
        return ApiResponse.badRequest(
          'Невідома група "$rawGroupId". Доступні групи: ${ParserService.allGroups.join(", ")}',
          code: 'INVALID_GROUP',
        );
      }

      final schedules = await _getSchedules();
      final fullSchedule = schedules[normalized];

      final now = ScheduleClock.now();
      final tomorrow = ScheduleClock.day(now, 1);
      final todayStr =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
      final tomorrowStr =
          "${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}";

      final hasToday = fullSchedule != null && !fullSchedule.today.isEmpty;
      final hasTomorrow =
          fullSchedule != null && !fullSchedule.tomorrow.isEmpty;

      final data = {
        'group': normalized,
        'last_updated_source': fullSchedule?.lastUpdatedSource ?? 'Невідомо',
        'today': hasToday
            ? {
                'date': todayStr,
                'is_available': true,
                'total_outage_minutes': fullSchedule.today.totalOutageMinutes,
                'total_outage_hours':
                    (fullSchedule.today.totalOutageMinutes / 60.0)
                        .toStringAsFixed(1),
                'intervals':
                    ApiHelpers.buildStructuredIntervals(fullSchedule.today),
                'slots':
                    fullSchedule.today.toSlots().map((s) => s.name).toList(),
                'hours_code': fullSchedule.today.toEncodedString(),
              }
            : {
                'date': todayStr,
                'is_available': false,
                'status': 'no_data',
              },
        'tomorrow': hasTomorrow
            ? {
                'date': tomorrowStr,
                'is_available': true,
                'total_outage_minutes':
                    fullSchedule.tomorrow.totalOutageMinutes,
                'total_outage_hours':
                    (fullSchedule.tomorrow.totalOutageMinutes / 60.0)
                        .toStringAsFixed(1),
                'intervals':
                    ApiHelpers.buildStructuredIntervals(fullSchedule.tomorrow),
                'slots':
                    fullSchedule.tomorrow.toSlots().map((s) => s.name).toList(),
                'hours_code': fullSchedule.tomorrow.toEncodedString(),
              }
            : {
                'date': tomorrowStr,
                'is_available': false,
                'status': 'not_published',
              },
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getGroupSchedule',
          tag: 'ScheduleController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка завантаження графіка для групи',
          exception: e);
    }
  }

  /// GET /api/v1/schedule/countdown?group=GPV2.1
  Future<ApiResponse> getCountdown(HttpRequest request,
      {Map<String, FullSchedule>? preloadedSchedules}) async {
    try {
      final resolution = await ApiHelpers.resolveGroup(request);
      if (!resolution.isValid) {
        return ApiResponse.badRequest(resolution.error!, code: 'INVALID_GROUP');
      }
      final group = resolution.group!;

      final schedules = preloadedSchedules ?? await _getSchedules();
      final fullSchedule = schedules[group];

      final now = ScheduleClock.now();
      final countdown = CountdownService.calculateCountdown(
        today: fullSchedule?.today,
        tomorrow: fullSchedule?.tomorrow,
        now: now,
      );

      if (countdown == null) {
        return ApiResponse.ok({
          'group': group,
          'has_countdown': false,
          'message': 'Немає запланованих змін статусу або графік відсутній',
          'current_status': 'unknown',
          'target_status': null,
          'minutes_remaining': null,
          'formatted_remaining': null,
        });
      }

      final targetMinuteOfDay =
          (now.hour * 60 + now.minute) + countdown.minutesRemaining;
      final targetTime = ScheduleClock.day(now)
          .add(Duration(minutes: targetMinuteOfDay));

      final data = {
        'group': group,
        'has_countdown': true,
        'current_status': countdown.currentStatus.name,
        'target_status': countdown.targetStatus.name,
        'minutes_remaining': countdown.minutesRemaining,
        'target_time': targetTime.toUtc().toIso8601String(),
        'formatted_remaining': countdown.formattedRemaining,
        'message': countdown.message,
        'is_tomorrow_schedule_missing':
            fullSchedule?.tomorrow == null || fullSchedule!.tomorrow.isEmpty,
      };

      return ApiResponse.ok(data);
    } catch (e, stack) {
      AppLogger.e('Error in getCountdown',
          tag: 'ScheduleController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка розрахунку зворотного відліку',
          exception: e);
    }
  }

  /// GET /api/v1/schedule/groups
  Future<ApiResponse> getAllGroups(HttpRequest request) async {
    try {
      final schedules = await _getSchedules();
      final now = ScheduleClock.now();
      final currentSlotIndex = (now.hour * 60 + now.minute) ~/ 30;

      final groupsData = <String, dynamic>{};
      for (final group in ParserService.allGroups) {
        final sched = schedules[group];
        final today = sched?.today ?? DailySchedule.empty();
        final tomorrow = sched?.tomorrow ?? DailySchedule.empty();
        final todaySlots = today.toSlots();

        String currentStatus = 'unknown';
        if (currentSlotIndex >= 0 && currentSlotIndex < todaySlots.length) {
          currentStatus = todaySlots[currentSlotIndex].name;
        }

        groupsData[group] = {
          'has_today': !today.isEmpty,
          'has_tomorrow': !tomorrow.isEmpty,
          'today_outage_minutes': today.totalOutageMinutes,
          'tomorrow_outage_minutes': tomorrow.totalOutageMinutes,
          'current_status': currentStatus,
          'source_updated': sched?.lastUpdatedSource ?? 'Немає',
        };
      }

      return ApiResponse.ok({
        'total_groups': ParserService.allGroups.length,
        'groups': groupsData,
      });
    } catch (e, stack) {
      AppLogger.e('Error in getAllGroups',
          tag: 'ScheduleController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Помилка завантаження списку груп',
          exception: e);
    }
  }

  /// POST /api/v1/schedule/sync
  Future<ApiResponse> triggerSync(HttpRequest request) async {
    try {
      final force = request.uri.queryParameters['force'] == 'true';
      final result = await _syncService.syncSchedules(
        force: force,
        hasExistingData: true,
      );

      if (result.isCooldownActive) {
        return ApiResponse.ok({
          'status': 'cooldown_active',
          'message': 'Дані нещодавно оновлені. Кулдаун 30 секунд активний.',
          'cooldown_seconds': _syncService.fetchCooldown.inSeconds,
        });
      }

      if (result.isAlreadyFetching) {
        return ApiResponse.ok({
          'status': 'already_fetching',
          'message': 'Синхронізація вже триває у фоні.',
        });
      }

      if (result.isSuccess) {
        return ApiResponse.ok({
          'status': 'success',
          'message': 'Графіки успішно оновлено з сайту ДТЕК',
          'groups_updated': result.schedules?.keys.length ?? 0,
        });
      }

      return ApiResponse.internalError(
        'Помилка під час синхронізації з ДТЕК',
        exception: result.error,
      );
    } catch (e, stack) {
      AppLogger.e('Error in triggerSync',
          tag: 'ScheduleController', error: e, stackTrace: stack);
      return ApiResponse.internalError('Непередбачена помилка синхронізації',
          exception: e);
    }
  }
}
