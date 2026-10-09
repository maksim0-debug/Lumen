import 'package:workmanager/workmanager.dart';
import 'package:flutter/foundation.dart';

import 'app_logger.dart';
import 'android_fetch_diagnostics.dart';
import 'parser_service.dart';
import 'widget_service.dart';
import 'notification_service.dart';
import 'history_service.dart';
import 'preferences_helper.dart';
import 'schedule_change_notification_service.dart';
import '../models/schedule_status.dart';

const String taskUpdateSchedule = 'taskUpdateSchedule';

/// FCM only queues recovery work; displaying a push never waits for DTEK/WAF.
Future<void> enqueueScheduleRefresh() =>
    Workmanager().registerOneOffTask('fcm_schedule_refresh', taskUpdateSchedule,
        inputData: {'diagnostic_source': 'fcm_recovery'},
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected));

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) =>
      AndroidFetchDiagnostics.instance.run(
          source: inputData?['diagnostic_source'] as String? ??
              'workmanager_legacy',
          execution: 'workmanager',
          fields: {'task': task},
          action: () async {
            try {
              await HistoryService()
                  .logAction('Бекграунд завдання запущено: $task');
              if (task != taskUpdateSchedule) {
                AndroidFetchDiagnostics.current?.event('worker_result', {
                  'result': 'success',
                  'reason': 'unrecognized_task',
                });
                return true;
              }
              final schedules =
                  await ParserService.background().fetchAllSchedules();
              if (schedules.isEmpty) {
                AndroidFetchDiagnostics.current?.event(
                    'worker_result',
                    {
                      'result': 'retry',
                      'reason': 'empty_schedule',
                    },
                    level: AppLogLevel.warning);
                AppLogger.w('Background schedule refresh returned no data',
                    tag: 'Background');
                return false;
              }
              await applyBackgroundSchedules(schedules);
              await HistoryService().logAction('Бекграунд завдання завершено');
              AndroidFetchDiagnostics.current?.event('worker_result', {
                'result': 'success',
                'groups': schedules.length,
              });
              return true;
            } catch (error, stack) {
              AndroidFetchDiagnostics.current?.event(
                  'worker_result',
                  {
                    'result': 'retry',
                    ...AndroidFetchDiagnostics.errorFields(error),
                  },
                  level: AppLogLevel.error);
              AppLogger.e('Background schedule refresh failed',
                  tag: 'Background', error: error, stackTrace: stack);
              return false;
            }
          }));
}

/// Shared by periodic polling and FCM recovery, with injectable side effects.
Future<void> applyBackgroundSchedules(
  Map<String, FullSchedule> schedules, {
  ScheduleChangeNotificationService? changes,
  NotificationService? notifications,
  WidgetService? widgets,
}) async {
  (Object, StackTrace)? failure;
  Future<void> attempt(String operation, Future<void> Function() action) async {
    final elapsed = Stopwatch()..start();
    AndroidFetchDiagnostics.current?.event('background_effect_start', {
      'effect': operation,
    });
    try {
      await action();
      AndroidFetchDiagnostics.current?.event('background_effect_returned', {
        'effect': operation,
        'durationMs': elapsed.elapsedMilliseconds,
      });
    } catch (error, stack) {
      AndroidFetchDiagnostics.current?.event(
          'background_effect_error',
          {
            'effect': operation,
            'durationMs': elapsed.elapsedMilliseconds,
            ...AndroidFetchDiagnostics.errorFields(error),
          },
          level: AppLogLevel.error);
      failure ??= (error, stack);
      AppLogger.e('Background $operation failed',
          tag: 'Background', error: error, stackTrace: stack);
    }
  }

  // Complete independent refreshes before reporting failure to Workmanager.
  await attempt(
      'change notifications',
      () => (changes ?? ScheduleChangeNotificationService())
          .observeSchedules(schedules));
  await attempt('reminder initialization', () async {
    final prefs = await PreferencesHelper.getSafeInstance();
    await prefs.reload();
    final notifier = notifications ?? NotificationService();
    await notifier.init(requestPermissions: false);
    var first = true;
    for (final group in PreferencesHelper.getActiveNotificationGroups(prefs)) {
      final schedule = schedules[group];
      if (schedule == null) continue;
      final cancelExisting = first;
      // A partially failed first group must not cause later groups to clear
      // reminders a second time in the same pass.
      first = false;
      await attempt(
          'reminders for $group',
          () => notifier.scheduleNotificationsForToday(schedule,
              groupName: group, cancelExisting: cancelExisting));
    }
  });
  await attempt('widget refresh',
      () => (widgets ?? WidgetService()).updateWidget(schedules));
  if (failure case final captured?) {
    Error.throwWithStackTrace(captured.$1, captured.$2);
  }
}

class BackgroundManager {
  static final BackgroundManager _instance = BackgroundManager._internal();
  factory BackgroundManager() => _instance;
  BackgroundManager._internal();

  Future<void> init() async {
    if (kIsWeb || (defaultTargetPlatform == TargetPlatform.windows)) return;

    try {
      await Workmanager().initialize(
        callbackDispatcher,
      );
      AppLogger.i("Ініціалізація успішна", tag: 'BackgroundManager');
    } catch (e) {
      AppLogger.e("Помилка ініціалізації", tag: 'BackgroundManager', error: e);
    }
  }

  void registerPeriodicTask() {
    if (kIsWeb || (defaultTargetPlatform == TargetPlatform.windows)) return;

    try {
      Workmanager().registerPeriodicTask(
        "periodic_update_task",
        taskUpdateSchedule,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(
          networkType: NetworkType.connected,
        ),
        existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
        initialDelay: const Duration(seconds: 10),
        inputData: {'diagnostic_source': 'periodic_poll'},
      );
      AppLogger.i("Періодичну задачу зареєстровано", tag: 'BackgroundManager');
    } catch (e) {
      AppLogger.e("Помилка реєстрації задачі",
          tag: 'BackgroundManager', error: e);
    }
  }
}
