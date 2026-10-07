import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/notification_service.dart';
import 'package:lumen/services/schedule_notification_coordinator.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/utils/app_formatters.dart';

class RecordingNotifications extends Fake implements NotificationService {
  final messages = <({String title, String body, String? group})>[];

  @override
  Future<void> showImmediate(String title, String body,
      {String? groupName, int? notificationId}) async {
    messages.add((title: title, body: body, group: groupName));
  }

  @override
  Future<void> scheduleNotificationsForToday(FullSchedule schedule,
      {String? groupName, bool cancelExisting = true}) async {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const a = '000000000000111100000000';
  const b = '000000000000000011110000';
  FullSchedule schedule(String code) => FullSchedule(
      today: DailySchedule.fromEncodedString(code),
      tomorrow: DailySchedule.empty());

  for (final hide in [true, false]) {
    test('time shifts and A-B-A notify independently of hideUnchanged=$hide',
        () async {
      SharedPreferences.setMockInitialValues({
        'hide_unchanged_schedule_versions': hide,
        'notify_schedule_change': true,
      });
      final notifications = RecordingNotifications();
      final coordinator =
          ScheduleNotificationCoordinator(notifier: notifications);
      Future<void> update(String code) => coordinator.handleScheduleUpdate(
          allSchedules: {'GPV2.1': schedule(code)}, currentGroup: 'GPV2.1');
      await update(a);
      expect(notifications.messages, isEmpty);
      await update(b);
      await update(a);
      await update(a);
      if (Platform.isWindows) {
        expect(notifications.messages, hasLength(2));
        expect(
            notifications.messages.map((m) => m.group), everyElement('GPV2.1'));
        expect(notifications.messages.map((m) => m.body),
            everyElement('Змінився час відключень на сьогодні ⚡'));
      } else {
        expect(notifications.messages, isEmpty);
      }
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('prev_hash_GPV2.1_today'), a);
    });
  }

  test('other-group changes do not notify unchanged selected group', () async {
    SharedPreferences.setMockInitialValues({'notify_schedule_change': true});
    final notifications = RecordingNotifications();
    final coordinator =
        ScheduleNotificationCoordinator(notifier: notifications);
    await coordinator.handleScheduleUpdate(
      allSchedules: {'GPV2.1': schedule(a), 'GPV1.1': schedule(a)},
      currentGroup: 'GPV2.1',
      notificationGroups: ['GPV1.1'],
    );
    await coordinator.handleScheduleUpdate(
      allSchedules: {'GPV2.1': schedule(a), 'GPV1.1': schedule(b)},
      currentGroup: 'GPV2.1',
      notificationGroups: ['GPV1.1'],
    );
    if (Platform.isWindows) {
      expect(notifications.messages, hasLength(1));
      expect(notifications.messages.single.group, 'GPV1.1');
    }
  });

  test(
      'notification setting remains authoritative when version filter is enabled',
      () async {
    SharedPreferences.setMockInitialValues({
      'hide_unchanged_schedule_versions': true,
      'notify_schedule_change': false,
      'prev_hash_GPV2.1_today': a,
      'prev_date_GPV2.1_today':
          AppFormatters.formatDateKey(ScheduleClock.now()),
    });
    final notifications = RecordingNotifications();
    await ScheduleNotificationCoordinator(notifier: notifications)
        .handleScheduleUpdate(
      allSchedules: {'GPV2.1': schedule(b)},
      currentGroup: 'GPV2.1',
    );
    expect(notifications.messages, isEmpty);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('prev_hash_GPV2.1_today'), b);
  });
}
