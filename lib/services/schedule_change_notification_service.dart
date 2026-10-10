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
  static Future<void> _settingsTail = Future.value();

  /// Persist every transition, including off/on between two source refreshes.
  /// Preference writes are idempotent; a failed SQL transaction is reconciled
  /// from durable preferences before any later notification can be claimed.
  Future<void> updatePreferences({
    List<String>? groups,
    String? selectedGroup,
    bool? notifyToday,
    bool? notifyTomorrow,
  }) {
    final savedGroups = groups == null ? null : List<String>.of(groups);
    final result = _settingsTail.then((_) async {
      // Commit the old policy first so a retry cannot mistake reactivation for
      // first-install bootstrap after an external preference write succeeded.
      await _store.withPreferences(
          _preferences, _now(), (txn, prefs, policy) async {});
      await _store.withPreferences(_preferences, _now(), (txn, prefs, _) async {
        Future<void> write(Future<bool> operation) async {
          if (!await operation) {
            throw StateError('Cannot persist schedule notification settings');
          }
        }

        try {
          if (selectedGroup != null) {
            final previous = prefs.getString('selected_group') ?? 'GPV2.1';
            final currentGroups =
                prefs.getStringList('notification_groups') ?? [];
            if (savedGroups == null &&
                (currentGroups.isEmpty ||
                    (currentGroups.length == 1 &&
                        currentGroups.contains(previous)))) {
              await write(
                  prefs.setStringList('notification_groups', [selectedGroup]));
            }
            await write(prefs.setString('selected_group', selectedGroup));
          }
          if (savedGroups != null) {
            await write(
                prefs.setStringList('notification_groups', savedGroups));
          }
          if (notifyToday != null) {
            await write(prefs.setBool('notify_schedule_change', notifyToday));
          }
          if (notifyTomorrow != null) {
            await write(
                prefs.setBool('notify_tomorrow_schedule', notifyTomorrow));
          }
        } catch (_) {
          // SharedPreferences may update its cache before a platform failure.
          await prefs.reload();
          rethrow;
        }
        await _store.synchronizePolicyIn(txn, prefs, _now());
      });
    });
    _settingsTail =
        result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }

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
    final policy = await _store.synchronizePolicyIn(txn, prefs, _now());
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
        final observation = await _store.observeConfiguredIn(txn, event, policy,
            nowMs: _now().millisecondsSinceEpoch,
            fromPush: fromPush &&
                (snapshot.alertsFor(group, dayType) || trigger?.id == event.id),
            handled: alreadyDisplayed && trigger?.id == event.id,
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
    final now = _now();
    final rejected = <(String, String, FormatException)>[];
    final observations = await _store.withPreferences(_preferences, now,
        (txn, prefs, policy) async {
      rejected.clear();
      AndroidFetchDiagnostics.current?.event('notification_settings', {
        'activeGroups': PreferencesHelper.getActiveNotificationGroups(prefs),
        'notifyToday': prefs.getBool('notify_schedule_change') ?? true,
        'notifyTomorrow': prefs.getBool('notify_tomorrow_schedule') ?? true,
        'deliver': deliver,
      });
      final results =
          <(ScheduleChangeEvent, bool, ScheduleNotificationObservation)>[];
      for (final group
          in PreferencesHelper.getActiveNotificationGroups(prefs)) {
        final schedule = schedules[group];
        if (schedule == null) continue;
        for (final dayType in ['today', 'tomorrow']) {
          try {
            final event =
                ScheduleChangeEvent.fromSchedule(group, schedule, dayType, now);
            final observation = await _store.observeConfiguredIn(
                txn, event, policy,
                nowMs: now.millisecondsSinceEpoch,
                legacyHash: _legacyHash(prefs, event));
            results.add((event, policy.allows(event), observation));
          } on FormatException catch (error) {
            // Validation occurs before state writes. A conflicting group/date
            // cannot block independent publications in the same source batch.
            rejected.add((group, dayType, error));
          }
        }
      }
      return results;
    });
    for (final (group, dayType, error) in rejected) {
      AndroidFetchDiagnostics.current?.event(
          'notification_snapshot_rejected',
          {
            'group': group,
            'dayType': dayType,
            ...AndroidFetchDiagnostics.errorFields(error),
          },
          level: AppLogLevel.warning);
      AppLogger.w(
          'Ignoring unverifiable notification snapshot for $group/$dayType',
          tag: 'ScheduleNotifications',
          error: error);
    }
    (Object, StackTrace)? failure;
    for (final (event, allowed, observation) in observations) {
      if (!deliver ||
          !allowed ||
          event.isWithdrawal ||
          observation != ScheduleNotificationObservation.pending) {
        AndroidFetchDiagnostics.current?.event('notification_skipped', {
          'group': event.group,
          'dayType': event.dayType,
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
            'Cannot display schedule notification for ${event.group}/${event.dayType}',
            tag: 'ScheduleNotifications',
            error: error,
            stackTrace: stack);
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
    final result = await _store.withPreferences(
        _preferences,
        now,
        (txn, prefs, policy) async => (
              policy.allows(event),
              await _store.observeConfiguredIn(txn, event, policy,
                  nowMs: now.millisecondsSinceEpoch,
                  fromPush: true,
                  handled: alreadyDisplayed,
                  legacyHash: _legacyHash(prefs, event)),
            ));
    final allowed = result.$1;
    final observation = result.$2;
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
      final allowed = await _store.withPreferences(_preferences, _now(),
          (txn, prefs, policy) async => policy.allows(event));
      if (!allowed ||
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
      if (!await _store.isCurrentClaim(claim)) {
        await _store.finish(claim, success: false);
        continue;
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
