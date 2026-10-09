import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/android_fetch_diagnostics.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/background_service.dart';
import 'package:lumen/services/notification_service.dart';
import 'package:lumen/services/schedule_change_notification_service.dart';
import 'package:lumen/services/widget_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Changes implements ScheduleChangeNotificationService {
  final Object? failure;
  _Changes(this.failure);
  @override
  Future<void> observeSchedules(Map<String, FullSchedule> schedules,
      {bool deliver = true}) async {
    if (failure != null) throw failure!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifications implements NotificationService {
  final Object? initFailure;
  final String? failingGroup;
  final attempts = <String>[];
  final cancellations = <bool>[];
  bool? permissionRequest;
  _Notifications({this.initFailure, this.failingGroup});

  @override
  Future<void> init({bool requestPermissions = true}) async {
    permissionRequest = requestPermissions;
    if (initFailure != null) throw initFailure!;
  }

  @override
  Future<void> scheduleNotificationsForToday(FullSchedule schedule,
      {String? groupName, bool cancelExisting = true}) async {
    attempts.add(groupName!);
    cancellations.add(cancelExisting);
    if (groupName == failingGroup) throw StateError('Reminder failed');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Widgets implements WidgetService {
  final Object? failure;
  Map<String, FullSchedule>? received;
  _Widgets({this.failure});
  @override
  Future<void> updateWidget(Map<String, FullSchedule> schedules) async {
    received = schedules;
    if (failure != null) throw failure!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final schedules = {
    for (final group in ['GPV2.1', 'GPV1.1'])
      group: FullSchedule(
          today: DailySchedule.fromEncodedString('111111${'0' * 18}'),
          tomorrow: DailySchedule.empty(),
          lastUpdatedSource: '09.10.2026 14:00'),
  };
  setUp(() => SharedPreferences.setMockInitialValues({
        'notification_groups': ['GPV2.1', 'GPV1.1'],
      }));

  test(
      'notification failure still refreshes reminders and widget, then fails for retry',
      () async {
    final failure = StateError('Display failed');
    final notifications = _Notifications();
    final widgets = _Widgets();
    await expectLater(
        applyBackgroundSchedules(schedules,
            changes: _Changes(failure),
            notifications: notifications,
            widgets: widgets),
        throwsA(same(failure)));
    expect(notifications.attempts, ['GPV2.1', 'GPV1.1']);
    expect(notifications.cancellations, [true, false]);
    expect(notifications.permissionRequest, false);
    expect(widgets.received, same(schedules));
  });

  test('Diagnostics retain the failed effect and original retry exception',
      () async {
    final records = <Map<String, dynamic>>[];
    final diagnostics = AndroidFetchDiagnostics(
        enabled: true,
        modeLoader: () async => AndroidDiagnosticMode.verbose,
        snapshot: (_) async => {},
        sink: (message, _) async => records.add(jsonDecode(message)));
    final failure = StateError('private display failure');
    final notifications = _Notifications();
    final widgets = _Widgets();
    await expectLater(
        diagnostics.run(
            source: 'periodic_poll',
            execution: 'workmanager',
            action: () => applyBackgroundSchedules(schedules,
                changes: _Changes(failure),
                notifications: notifications,
                widgets: widgets)),
        throwsA(same(failure)));
    expect(
        records.singleWhere(
            (r) => r['stage'] == 'background_effect_error')['effect'],
        'change notifications');
    expect(
        records
            .where((r) => r['stage'] == 'background_effect_returned')
            .map((r) => r['effect']),
        containsAll(['widget refresh', 'reminder initialization']));
    expect(records.map((r) => r['operationId']).toSet(), hasLength(1));
    expect(jsonEncode(records), isNot(contains('private display failure')));
    expect(widgets.received, same(schedules));
    expect(notifications.attempts, ['GPV2.1', 'GPV1.1']);
  });

  test('reminder initialization failure cannot block widget refresh', () async {
    final failure = StateError('Plugin initialization failed');
    final notifications = _Notifications(initFailure: failure);
    final widgets = _Widgets();
    await expectLater(
        applyBackgroundSchedules(schedules,
            changes: _Changes(null),
            notifications: notifications,
            widgets: widgets),
        throwsA(same(failure)));
    expect(widgets.received, same(schedules));
  });

  test(
      'failed reminder group cannot block another group or clear its alarms again',
      () async {
    final notifications = _Notifications(failingGroup: 'GPV2.1');
    final widgets = _Widgets();
    await expectLater(
        applyBackgroundSchedules(schedules,
            changes: _Changes(null),
            notifications: notifications,
            widgets: widgets),
        throwsStateError);
    expect(notifications.attempts, ['GPV2.1', 'GPV1.1']);
    expect(notifications.cancellations, [true, false]);
    expect(widgets.received, same(schedules));
  });

  test('widget failure is reported after reminders have been refreshed',
      () async {
    final failure = StateError('Widget failed');
    final notifications = _Notifications();
    await expectLater(
        applyBackgroundSchedules(schedules,
            changes: _Changes(null),
            notifications: notifications,
            widgets: _Widgets(failure: failure)),
        throwsA(same(failure)));
    expect(notifications.attempts, ['GPV2.1', 'GPV1.1']);
  });
}
