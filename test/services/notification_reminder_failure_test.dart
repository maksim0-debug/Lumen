import 'dart:io';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/notification_service.dart';

class _Plugin extends Fake implements FlutterLocalNotificationsPlugin {
  bool initialized = true;
  Object? scheduleFailure;
  Object? cancelFailure;
  final scheduledIds = <int>[];
  @override
  dynamic noSuchMethod(Invocation call) {
    if (call.memberName == #initialize) return Future<bool?>.value(initialized);
    if (call.memberName == #zonedSchedule) {
      scheduledIds.add(call.positionalArguments.first as int);
      return scheduleFailure == null
          ? Future<void>.value()
          : Future<void>.error(scheduleFailure!);
    }
    if (call.memberName == #cancelAll) {
      return cancelFailure == null
          ? Future<void>.value()
          : Future<void>.error(cancelFailure!);
    }
    return super.noSuchMethod(call);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final schedule = FullSchedule(
      today: DailySchedule.fromEncodedString('1' * 24),
      tomorrow: DailySchedule.fromEncodedString('11${'0' * 22}'));
  setUp(() => SharedPreferences.setMockInitialValues({
        'notification_groups': ['GPV2.1'],
        'notify_1h_before_off': false,
        'notify_30m_before_off': false,
        'notify_5m_before_off': false,
        'notify_1h_before_on': true,
        'notify_30m_before_on': true,
      }));
  // Exercise the real public service and its private error handling, mocking
  // only the external platform SDK. This runner uses the Windows adapter path.
  test('failed initialization cannot consume durable reminder work', () async {
    final plugin = _Plugin()..initialized = false;
    await expectLater(
        NotificationService.forTesting(plugin).scheduleNotificationsForToday(
            schedule,
            groupName: 'GPV2.1',
            rethrowOnError: true),
        throwsStateError);
    expect(plugin.scheduledIds, isEmpty);
  }, skip: !Platform.isWindows);
  test('SDK scheduling failure remains retryable and uses stable IDs',
      () async {
    final error = StateError('Native scheduler unavailable');
    final plugin = _Plugin()..scheduleFailure = error;
    final service = NotificationService.forTesting(plugin);
    await expectLater(
        service.scheduleNotificationsForToday(schedule,
            groupName: 'GPV2.1', rethrowOnError: true),
        throwsA(same(error)));
    expect(plugin.scheduledIds.length, 2);
    final originalIds = plugin.scheduledIds.toList();
    plugin.scheduleFailure = null;
    await service.scheduleNotificationsForToday(schedule,
        groupName: 'GPV2.1', rethrowOnError: true);
    expect(plugin.scheduledIds.skip(2), originalIds);
  }, skip: !Platform.isWindows);
  test('cancel failure is reported after independent reminders are attempted',
      () async {
    final error = StateError('Cancel failed');
    final plugin = _Plugin()..cancelFailure = error;
    await expectLater(
        NotificationService.forTesting(plugin).scheduleNotificationsForToday(
            schedule,
            groupName: 'GPV2.1',
            rethrowOnError: true),
        throwsA(same(error)));
    expect(plugin.scheduledIds.length, 2);
  }, skip: !Platform.isWindows);
  test('existing foreground callers retain nonthrowing SDK error handling',
      () async {
    final plugin = _Plugin()..scheduleFailure = StateError('Native failure');
    await NotificationService.forTesting(plugin)
        .scheduleNotificationsForToday(schedule, groupName: 'GPV2.1');
    expect(plugin.scheduledIds.length, 2);
  }, skip: !Platform.isWindows);
}
