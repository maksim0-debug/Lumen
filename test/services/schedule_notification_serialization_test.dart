import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/notification_service.dart';
import 'package:lumen/services/schedule_notification_coordinator.dart';

class _Notifier extends Fake implements NotificationService {
  final started = Completer<void>();
  final release = Completer<void>();
  final calls = <String>[];
  String? applied;
  bool failFirst = false;

  @override
  Future<void> scheduleNotificationsForToday(FullSchedule schedule,
      {String? groupName,
      bool cancelExisting = true,
      bool rethrowOnError = false}) async {
    final code = schedule.today.scheduleHash;
    calls.add(code);
    if (calls.length == 1) {
      started.complete();
      await release.future;
      if (failFirst) throw StateError('First pass failed');
    }
    applied = code;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({
        'notification_groups': ['GPV1.1'],
        'notify_schedule_change': false,
      }));
  Map<String, FullSchedule> schedules(String code) => {
        'GPV1.1': FullSchedule(
            today: DailySchedule.fromEncodedString(code),
            tomorrow: DailySchedule.empty()),
      };

  for (final directFirst in [false, true]) {
    test(
        'direct and synchronized passes share the same queue: directFirst=$directFirst',
        () async {
      final notifier = _Notifier();
      final first = ScheduleNotificationCoordinator(
          notifier: notifier, isPlatformSupported: true);
      final second = ScheduleNotificationCoordinator(
          notifier: notifier, isPlatformSupported: true);
      final a = schedules('0' * 24);
      final b = schedules('1' * 24);
      final firstWork = directFirst
          ? first.updateNotificationsOnly(
              allSchedules: a, currentGroup: 'GPV1.1')
          : first.handleScheduleUpdate(allSchedules: a, currentGroup: 'GPV1.1');
      await notifier.started.future;
      final secondWork = directFirst
          ? second.handleScheduleUpdate(allSchedules: b, currentGroup: 'GPV1.1')
          : second.updateNotificationsOnly(
              allSchedules: b, currentGroup: 'GPV1.1');
      await Future<void>.delayed(Duration.zero);
      expect(notifier.calls, ['0' * 24]);
      notifier.release.complete();
      await Future.wait([firstWork, secondWork]);
      expect(notifier.calls, ['0' * 24, '1' * 24]);
      expect(notifier.applied, '1' * 24);
    }, skip: !Platform.isWindows);
  }

  test('one failed pass does not poison subsequent coordinator work', () async {
    final notifier = _Notifier()..failFirst = true;
    final coordinator = ScheduleNotificationCoordinator(
        notifier: notifier, isPlatformSupported: true);
    final first = coordinator.updateNotificationsOnly(
        allSchedules: schedules('0' * 24), currentGroup: 'GPV1.1');
    final failure = expectLater(first, throwsStateError);
    await notifier.started.future;
    final second = coordinator.updateNotificationsOnly(
        allSchedules: schedules('1' * 24), currentGroup: 'GPV1.1');
    notifier.release.complete();
    await failure;
    await second;
    expect(notifier.applied, '1' * 24);
  }, skip: !Platform.isWindows);
}
