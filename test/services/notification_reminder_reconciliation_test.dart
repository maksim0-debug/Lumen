import 'dart:async';
import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/notification_service.dart';
import 'package:lumen/services/schedule_clock.dart';

class _Plugin extends Fake implements FlutterLocalNotificationsPlugin {
  final pending = <int, PendingNotificationRequest>{};
  final scheduled = <int>[];
  final shown = <int>[];
  final shownChannels = <String?>[];
  final cancelled = <int>[];
  Object? enumerationFailure;
  int? failedCancel;
  int? failedSchedule;
  bool failedShow = false;
  Future<void>? enumerationGate;
  final enumerationStarted = Completer<void>();

  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName == #initialize) return Future<bool?>.value(true);
    if (call.memberName == #pendingNotificationRequests) {
      return () async {
        if (!enumerationStarted.isCompleted) enumerationStarted.complete();
        await enumerationGate;
        if (enumerationFailure != null) throw enumerationFailure!;
        return pending.values.toList();
      }();
    }
    if (call.memberName == #cancel) {
      final id = call.positionalArguments[0] as int;
      cancelled.add(id);
      if (id == failedCancel) {
        return Future<void>.error(StateError('Cancel failed'));
      }
      pending.remove(id);
      return Future<void>.value();
    }
    if (call.memberName == #zonedSchedule) {
      final id = call.positionalArguments[0] as int;
      scheduled.add(id);
      if (id == failedSchedule) {
        return Future<void>.error(StateError('Schedule failed'));
      }
      // Match Windows: pending requests provide IDs but no title/body/payload.
      pending[id] = PendingNotificationRequest(id, null, null, null);
      return Future<void>.value();
    }
    if (call.memberName == #show) {
      if (failedShow) return Future<void>.error(StateError('Show failed'));
      shown.add(call.positionalArguments[0] as int);
      shownChannels.add((call.positionalArguments[3] as NotificationDetails)
          .android
          ?.channelId);
      return Future<void>.value();
    }
    return super.noSuchMethod(call);
  }
}

class _FailingStore extends InMemorySharedPreferencesStore {
  bool failWrites = true;
  int stateWrites = 0;
  _FailingStore(Map<String, Object> data) : super.withData(data);

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.endsWith('scheduled_reminder_state_v1')) {
      stateWrites++;
      if (failWrites) return false;
    }
    return super.setValue(valueType, key, value);
  }
}

FullSchedule _schedule(int start, int end) {
  final hours = List.filled(24, LightStatus.on);
  for (var i = start; i < end; i++) {
    hours[i] = LightStatus.off;
  }
  return FullSchedule(
      today: DailySchedule(hours), tomorrow: DailySchedule.empty());
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Plugin plugin;
  late NotificationService service;
  late tz.TZDateTime now;
  setUp(() {
    SharedPreferences.setMockInitialValues({
      'notification_groups': ['GPV1.1'],
      'notify_1h_before_off': false,
      'notify_30m_before_off': false,
      'notify_5m_before_off': true,
      'notify_1h_before_on': false,
      'notify_30m_before_on': false,
    });
    now = ScheduleClock.calendar(2026, 10, 11, 17, 50);
    plugin = _Plugin();
    service = NotificationService.forTesting(plugin, now: () => now);
  });
  Future<void> update(FullSchedule schedule,
          {String group = 'GPV1.1', bool cancelExisting = true}) =>
      service.scheduleNotificationsForToday(schedule,
          groupName: group,
          cancelExisting: cancelExisting,
          rethrowOnError: true);

  group('real service reconciliation', () {
    test(
        'identical pending reminder survives refresh three seconds before delivery',
        () async {
      await update(_schedule(18, 20));
      now = ScheduleClock.calendar(2026, 10, 11, 17, 54)
          .add(const Duration(seconds: 57));
      await update(_schedule(18, 20));
      expect(plugin.scheduled, [18002]);
      expect(plugin.cancelled, isEmpty);
      expect(plugin.shown, isEmpty);
      expect(plugin.pending.keys, [18002]);
    });

    test(
        'retention survives a fresh service instance with Windows ID-only requests',
        () async {
      await update(_schedule(18, 20));
      service = NotificationService.forTesting(plugin, now: () => now);
      now = ScheduleClock.calendar(2026, 10, 11, 17, 54)
          .add(const Duration(seconds: 59));
      await update(_schedule(18, 20));
      expect(plugin.scheduled, [18002]);
      expect(plugin.cancelled, isEmpty);
    });

    test('new imminent reminder is shown once even across service restart',
        () async {
      now = ScheduleClock.calendar(2026, 10, 11, 17, 54)
          .add(const Duration(seconds: 57));
      await update(_schedule(18, 20));
      service = NotificationService.forTesting(plugin, now: () => now);
      await update(_schedule(18, 20));
      expect(plugin.shown, [18002]);
      expect(plugin.shownChannels, ['schedule_channel']);
      expect(plugin.scheduled, isEmpty);
    });

    test('changed imminent body replaces the obsolete pending reminder once',
        () async {
      await update(_schedule(18, 20));
      now = ScheduleClock.calendar(2026, 10, 11, 17, 54)
          .add(const Duration(seconds: 57));
      await update(_schedule(18, 21));
      await update(_schedule(18, 21));
      expect(plugin.cancelled, [18002]);
      expect(plugin.shown, [18002]);
    });

    test(
        'removed outage cancels the imminent reminder without showing stale content',
        () async {
      await update(_schedule(18, 20));
      now = ScheduleClock.calendar(2026, 10, 11, 17, 54)
          .add(const Duration(seconds: 57));
      await update(_schedule(0, 0));
      expect(plugin.pending, isEmpty);
      expect(plugin.cancelled, [18002]);
      expect(plugin.shown, isEmpty);
    });

    test('disabling a reminder removes it immediately on reconciliation',
        () async {
      await update(_schedule(18, 20));
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notify_5m_before_off', false);
      await update(_schedule(18, 20));
      expect(plugin.pending, isEmpty);
    });

    test(
        'all selected groups retain close reminders while obsolete groups are removed',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('notification_groups', ['GPV1.1', 'GPV2.1']);
      await update(_schedule(18, 20));
      await update(_schedule(18, 20), group: 'GPV2.1', cancelExisting: false);
      now = ScheduleClock.calendar(2026, 10, 11, 17, 54)
          .add(const Duration(seconds: 57));
      await update(_schedule(18, 20));
      await update(_schedule(18, 20), group: 'GPV2.1', cancelExisting: false);
      expect(plugin.cancelled, isEmpty);
      expect(plugin.scheduled, [18002, 218002]);
      await prefs.setStringList('notification_groups', ['GPV2.1']);
      await update(_schedule(18, 20), group: 'GPV2.1');
      // Switching to a single group also removes the multi-group title prefix.
      expect(plugin.cancelled, [18002, 218002]);
      expect(plugin.shown, [218002]);
      expect(plugin.pending, isEmpty);
    });

    test(
        'unrelated test notifications are preserved during schedule reconciliation',
        () async {
      plugin.pending[99991] =
          const PendingNotificationRequest(99991, null, null, null);
      plugin.pending[99993] =
          const PendingNotificationRequest(99993, null, null, null);
      await update(_schedule(18, 20));
      expect(plugin.pending.keys, containsAll([99991, 99993, 18002]));
      await service.cancelAllScheduled();
      expect(plugin.pending, isEmpty);
    });

    test(
        'calendar date is part of identity so daily IDs cannot retain yesterday',
        () async {
      await update(_schedule(18, 20));
      now = ScheduleClock.calendar(2026, 10, 12, 17, 50);
      await update(_schedule(18, 20));
      expect(plugin.cancelled, [18002]);
      expect(plugin.scheduled, [18002, 18002]);
    });

    test('enumeration failure preserves pending work and permits a later retry',
        () async {
      await update(_schedule(18, 20));
      plugin.enumerationFailure = StateError('No system access');
      await expectLater(update(_schedule(19, 20)), throwsStateError);
      expect(plugin.scheduled, [18002]);
      expect(plugin.pending.keys, [18002]);
      plugin.enumerationFailure = null;
      await update(_schedule(19, 20));
      expect(plugin.pending.keys, [19002]);
    });

    test(
        'failed cancellation does not create another pending copy of the same ID',
        () async {
      await update(_schedule(18, 20));
      plugin.failedCancel = 18002;
      await expectLater(update(_schedule(18, 21)), throwsStateError);
      expect(plugin.scheduled, [18002]);
      plugin.failedCancel = null;
      await update(_schedule(18, 21));
      expect(plugin.scheduled, [18002, 18002]);
    });

    test('failed immediate delivery stays retryable and is not marked as shown',
        () async {
      now = ScheduleClock.calendar(2026, 10, 11, 17, 54)
          .add(const Duration(seconds: 57));
      plugin.failedShow = true;
      await expectLater(update(_schedule(18, 20)), throwsStateError);
      plugin.failedShow = false;
      await update(_schedule(18, 20));
      expect(plugin.shown, [18002]);
    });

    test(
        'failed storage write retries despite SharedPreferences updating its cache',
        () async {
      final original = SharedPreferencesStorePlatform.instance;
      final store = _FailingStore(await original.getAll());
      SharedPreferencesStorePlatform.instance = store;
      addTearDown(() => SharedPreferencesStorePlatform.instance = original);
      now = ScheduleClock.calendar(2026, 10, 11, 17, 54)
          .add(const Duration(seconds: 57));
      await expectLater(update(_schedule(18, 20)), throwsStateError);
      expect(store.stateWrites, 1);
      expect(plugin.shown, [18002]);
      store.failWrites = false;
      await update(_schedule(18, 20));
      expect(store.stateWrites, 2);
      expect(plugin.shown, [18002],
          reason: 'Retry persists without another alert');
      expect((await store.getAll())['flutter.scheduled_reminder_state_v1'],
          contains('shown:'));
    });

    test(
        'one SDK failure does not block independent reminders or duplicate successful ones',
        () async {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('notify_1h_before_on', true);
      plugin.failedSchedule = 18002;
      await expectLater(update(_schedule(18, 20)), throwsStateError);
      expect(plugin.pending.keys, [20003]);
      plugin.failedSchedule = null;
      await update(_schedule(18, 20));
      expect(plugin.scheduled, [18002, 20003, 18002]);
      expect(plugin.pending.keys, containsAll([18002, 20003]));
    });

    test(
        'past reminders are never replayed when absent from the native schedule',
        () async {
      now = ScheduleClock.calendar(2026, 10, 11, 18);
      await update(_schedule(18, 20));
      expect(plugin.scheduled, isEmpty);
      expect(plugin.shown, isEmpty);
    });

    test(
        'overlapping service passes finish in order and leave only the newest plan',
        () async {
      final gate = Completer<void>();
      plugin.enumerationGate = gate.future;
      final first = update(_schedule(18, 20));
      await plugin.enumerationStarted.future;
      final second = update(_schedule(19, 21));
      gate.complete();
      await Future.wait([first, second]);
      expect(plugin.pending.keys, [19002]);
      expect(plugin.cancelled, [18002]);
    });
  }, skip: !Platform.isWindows);
}
