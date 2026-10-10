import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import '../models/schedule_snapshot.dart';

import '../models/schedule_change_event.dart';
import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'android_fetch_diagnostics.dart';
import 'dtek_snapshot.dart';
import 'notification_service.dart';
import 'preferences_helper.dart';
import 'schedule_change_notification_store.dart';
import 'schedule_clock.dart';

/// All schedule sources share the same delivery decisions and persisted state.
class ScheduleChangeNotificationService {
  final ScheduleChangeNotificationStore _store;
  final Future<SharedPreferences> Function() _preferences;
  final Future<void> Function(ScheduleNotificationClaim) _show;
  final DateTime Function() _now;
  static const clientTopicSuffix = '_v2';

  static String topicFor(String group,
      {String dayType = 'today', bool versioned = true}) {
    final clean = group.replaceAll('.', '_').replaceAll('-', '_').toLowerCase();
    return 'group_$clean${versioned ? clientTopicSuffix : ''}${dayType == 'tomorrow' ? '_tomorrow' : ''}';
  }

  Future<void> acknowledge(ScheduleChangeEvent event) => _store
      .observe(event, nowMs: _now().millisecondsSinceEpoch, handled: true)
      .then((_) {});

  ScheduleChangeNotificationService({
    ScheduleChangeNotificationStore? store,
    Future<SharedPreferences> Function()? preferences,
    Future<void> Function(ScheduleNotificationClaim)? show,
    DateTime Function()? now,
  })  : _store = store ?? ScheduleChangeNotificationStore(),
        _preferences = preferences ?? PreferencesHelper.getSafeInstance,
        _show = show ?? _showNotification,
        _now = now ?? ScheduleClock.now;

  static Future<void> _showNotification(ScheduleNotificationClaim claim) {
    final event = claim.event;
    return NotificationService().showImmediate(
      event.title(
          published:
              claim.previousHash == null || claim.previousHash == '9' * 24),
      event.body(claim.previousHash),
      groupName: event.group,
      notificationId: NotificationService.immediateGroupNotificationBaseId +
          NotificationService.getGroupIndex(event.group) +
          (event.dayType == 'tomorrow' ? 100 : 0),
      notificationTag: claim.identity,
      onlyAlertOnce: true,
      payload: '${event.group}:${event.targetDate}',
      rethrowOnError: true,
    );
  }

  static bool _allowed(SharedPreferences prefs, ScheduleChangeEvent event) =>
      PreferencesHelper.getActiveNotificationGroups(prefs)
          .contains(event.group) &&
      (prefs.getBool(event.dayType == 'tomorrow'
              ? 'notify_tomorrow_schedule'
              : 'notify_schedule_change') ??
          true);

  static String? _legacyHash(
          SharedPreferences prefs, ScheduleChangeEvent event) =>
      prefs.getString('prev_date_${event.group}_${event.dayType}') ==
              event.targetDate
          ? prefs.getString('prev_hash_${event.group}_${event.dayType}')
          : null;

  /// Stage delivery decisions in the same transaction as the source snapshot.
  Future<void> stageSnapshot(DatabaseExecutor txn, ScheduleSnapshot snapshot,
      {bool fromPush = false,
      ScheduleChangeEvent? trigger,
      bool alreadyDisplayed = false}) async {
    final prefs = await _preferences();
    await prefs.reload();
    await ScheduleChangeNotificationStore.createSchema(txn);
    for (final group in PreferencesHelper.getActiveNotificationGroups(prefs)) {
      final value = snapshot.schedules[group];
      if (value == null) continue;
      for (final dayType in ['today', 'tomorrow']) {
        final event = ScheduleChangeEvent(
            group: group,
            targetDate:
                dayType == 'today' ? snapshot.todayDate : snapshot.tomorrowDate,
            sourceVersion: snapshot.sourceVersion,
            dayType: dayType,
            hash: (dayType == 'today' ? value.today : value.tomorrow)
                .scheduleHash,
            allowWithdrawal: true);
        final observation = await _store.observeIn(txn, event,
            nowMs: _now().millisecondsSinceEpoch,
            fromPush: fromPush &&
                (snapshot.alertsFor(group, dayType) || trigger?.id == event.id),
            handled: !_allowed(prefs, event) ||
                (alreadyDisplayed && trigger?.id == event.id),
            legacyHash: _legacyHash(prefs, event));
        if (observation == ScheduleNotificationObservation.rejected) {
          throw const FormatException(
              'Snapshot precedes known notification publication');
        }
      }
    }
  }

  Future<void> observeSchedules(Map<String, FullSchedule> schedules,
      {bool deliver = true}) async {
    final prefs = await _preferences();
    await prefs.reload();
    final now = _now();
    AndroidFetchDiagnostics.current?.event('notification_settings', {
      'activeGroups': PreferencesHelper.getActiveNotificationGroups(prefs),
      'notifyToday': prefs.getBool('notify_schedule_change') ?? true,
      'notifyTomorrow': prefs.getBool('notify_tomorrow_schedule') ?? true,
      'deliver': deliver,
    });
    (Object, StackTrace)? failure;
    for (final group in PreferencesHelper.getActiveNotificationGroups(prefs)) {
      final schedule = schedules[group];
      if (schedule == null) continue;
      for (final dayType in ['today', 'tomorrow']) {
        final ScheduleChangeEvent event;
        final bool allowed;
        final ScheduleNotificationObservation observation;
        try {
          event =
              ScheduleChangeEvent.fromSchedule(group, schedule, dayType, now);
          allowed = _allowed(prefs, event);
          observation = await _store.observe(event,
              nowMs: now.millisecondsSinceEpoch,
              handled: !allowed,
              legacyHash: _legacyHash(prefs, event));
        } on FormatException catch (error) {
          AndroidFetchDiagnostics.current?.event(
              'notification_snapshot_rejected',
              {
                'group': group,
                'dayType': dayType,
                ...AndroidFetchDiagnostics.errorFields(error),
              },
              level: AppLogLevel.warning);
          // Conflicting source publications cannot advance the watermark or
          // block independent groups/dates, widgets and reminders.
          AppLogger.w(
              'Ignoring unverifiable notification snapshot for $group/$dayType',
              tag: 'ScheduleNotifications',
              error: error);
          continue;
        } catch (error, stack) {
          failure ??= (error, stack);
          AppLogger.e(
              'Cannot process schedule notification for $group/$dayType',
              tag: 'ScheduleNotifications',
              error: error,
              stackTrace: stack);
          continue;
        }
        if (!deliver ||
            !allowed ||
            event.isWithdrawal ||
            observation != ScheduleNotificationObservation.pending) {
          AndroidFetchDiagnostics.current?.event('notification_skipped', {
            'group': group,
            'dayType': dayType,
            'allowed': allowed,
            'observation': observation.name,
            'withdrawal': event.isWithdrawal,
            'deliver': deliver,
          });
          continue;
        }
        try {
          await _deliver(event);
        } catch (error, stack) {
          failure ??= (error, stack);
          AppLogger.e(
              'Cannot display schedule notification for $group/$dayType',
              tag: 'ScheduleNotifications',
              error: error,
              stackTrace: stack);
        }
      }
    }
    if (failure case final captured?) {
      Error.throwWithStackTrace(captured.$1, captured.$2);
    }
  }

  /// A push is processed before any network refresh; legacy background payloads
  /// have already been displayed by Android and must only acknowledge state.
  Future<bool> handlePush(Map<String, dynamic> data,
      {bool alreadyDisplayed = false}) async {
    final now = _now();
    final event = ScheduleChangeEvent.fromPush(data, now);
    final prefs = await _preferences();
    await prefs.reload();
    final allowed = _allowed(prefs, event);
    final observation = await _store.observe(event,
        nowMs: now.millisecondsSinceEpoch,
        fromPush: true,
        handled: alreadyDisplayed || !allowed,
        legacyHash: _legacyHash(prefs, event));
    if (observation == ScheduleNotificationObservation.pending &&
        allowed &&
        !alreadyDisplayed) {
      await _deliver(event);
    }
    return observation != ScheduleNotificationObservation.rejected;
  }

  Future<void> _deliver(ScheduleChangeEvent event) async {
    // If a newer observation arrives while showing, release the lease and
    // deliver the current pending state instead of acknowledging the wrong hash.
    for (var i = 0; i < 4; i++) {
      final prefs = await _preferences();
      await prefs.reload();
      if (!_allowed(prefs, event) ||
          event.targetDate !=
              DtekSnapshot.notificationDate(event.dayType, now: _now())) {
        return;
      }
      final claim =
          await _store.claim(event, nowMs: _now().millisecondsSinceEpoch);
      if (claim == null) {
        AndroidFetchDiagnostics.current?.event('notification_not_claimed', {
          'group': event.group,
          'dayType': event.dayType,
        });
        return;
      }
      try {
        AndroidFetchDiagnostics.current?.event('notification_show_start', {
          'group': event.group,
          'dayType': event.dayType,
        });
        await _show(claim).timeout(const Duration(seconds: 10));
      } catch (error) {
        AndroidFetchDiagnostics.current?.event(
            'notification_show_error',
            {
              'group': event.group,
              'dayType': event.dayType,
              ...AndroidFetchDiagnostics.errorFields(error),
            },
            level: AppLogLevel.error);
        await _store.finish(claim, success: false);
        rethrow;
      }
      await _store.finish(claim, success: true);
      AndroidFetchDiagnostics.current?.event('notification_show_returned', {
        'group': event.group,
        'dayType': event.dayType,
      });
      AppLogger.i('Displayed schedule change ${claim.identity}',
          tag: 'ScheduleNotifications', persistToHistory: true);
    }
  }
}
