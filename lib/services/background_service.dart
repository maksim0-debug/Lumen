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
import 'schedule_ingestion_service.dart';
import 'worker_schedule_service.dart';
import '../models/schedule_status.dart';

const String taskUpdateSchedule = 'taskUpdateSchedule';
const String taskApplySchedules = 'taskApplySchedules';

Future<void> enqueueLocalScheduleWork() => Workmanager().registerOneOffTask(
    'apply_received_schedules', taskApplySchedules,
    // The installed Android adapter maps append to APPEND_OR_REPLACE, so a
    // final drain cannot lose a new revision arriving while an older job exits.
    existingWorkPolicy: ExistingWorkPolicy.append);

Future<bool> applyPendingSchedules() => ScheduleIngestionService()
    .applyPending((schedules) => applyBackgroundSchedules(schedules));

/// FCM only queues recovery work; displaying a push never waits for DTEK/WAF.
Future<void> enqueueScheduleRefresh() =>
    Workmanager().registerOneOffTask('fcm_schedule_refresh', taskUpdateSchedule,
        inputData: {'diagnostic_source': 'fcm_recovery'},
        existingWorkPolicy: ExistingWorkPolicy.keep,
        constraints: Constraints(networkType: NetworkType.connected));

Future<Map<String, FullSchedule>> _fetchBackgroundSchedules() async {
  try {
    final schedules = await WorkerScheduleService().fetch();
    AndroidFetchDiagnostics.current?.event('worker_source', {
      'source': 'worker_schedule_service',
    });
    return schedules;
  } catch (error) {
    AppLogger.w('Worker unavailable; using direct schedule parser',
        tag: 'Background', error: error.runtimeType);
    AndroidFetchDiagnostics.current?.event('worker_source_fallback', {
      'reason': error.runtimeType.toString(),
    });
    return ParserService.background().fetchAllSchedules();
  }
}

/// A successful source refresh completes the network job. Failed local effects
/// leave persisted work intact for the next periodic poll or push; they
/// must not cause WorkManager to download the same source on every retry.
Future<bool> refreshBackgroundSchedules({
  Future<bool> Function()? applyPending,
  Future<Map<String, FullSchedule>> Function()? fetchSchedules,
  Future<void> Function(Map<String, FullSchedule>)? applySchedules,
}) async {
  var pendingComplete = false;
  try {
    pendingComplete = await (applyPending ?? applyPendingSchedules)();
  } catch (error, stack) {
    AndroidFetchDiagnostics.current?.event(
        'pending_local_work_error', AndroidFetchDiagnostics.errorFields(error),
        level: AppLogLevel.error);
    AppLogger.e('Pending local effects failed; continuing schedule recovery',
        tag: 'Background', error: error, stackTrace: stack);
  }
  final schedules = await (fetchSchedules ?? _fetchBackgroundSchedules)();
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
  var effectsComplete = false;
  try {
    await (applySchedules ?? applyBackgroundSchedules)(schedules);
    effectsComplete = true;
  } catch (error, stack) {
    AppLogger.e('New schedules recovered; local effects remain pending',
        tag: 'Background', error: error, stackTrace: stack);
    AndroidFetchDiagnostics.current?.event(
        'local_work_deferred', AndroidFetchDiagnostics.errorFields(error),
        level: AppLogLevel.error);
  }
  AndroidFetchDiagnostics.current?.event('worker_schedules_applied', {
    'groups': schedules.length,
    'pendingComplete': pendingComplete,
    'effectsComplete': effectsComplete,
  });
  if (!pendingComplete || !effectsComplete) {
    AndroidFetchDiagnostics.current?.event(
        'worker_result',
        {
          'result': 'success',
          'reason': 'local_work_deferred',
        },
        level: AppLogLevel.warning);
  }
  return true;
}

@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    return AndroidFetchDiagnostics.instance.run(
        source: inputData?['diagnostic_source'] as String? ??
            (task == taskApplySchedules
                ? 'apply_schedules'
                : 'workmanager_legacy'),
        execution: 'workmanager',
        fields: {'task': task},
        action: () async {
          if (task == taskApplySchedules) return await applyPendingSchedules();
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
            if (!await refreshBackgroundSchedules()) return false;
            await HistoryService().logAction('Бекграунд завдання завершено');
            AndroidFetchDiagnostics.current?.event('worker_result', {
              'result': 'success',
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
        });
  });
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
  await attempt('widget refresh',
      () => (widgets ?? WidgetService()).updateWidget(schedules));
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
              groupName: group,
              cancelExisting: cancelExisting,
              rethrowOnError: true));
    }
  });
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
      enqueueLocalScheduleWork().catchError((Object error) {
        AppLogger.e('Cannot enqueue pending local schedule work',
            tag: 'BackgroundManager', error: error);
      });
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
