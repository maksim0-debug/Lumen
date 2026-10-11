import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/notification_service.dart';
import 'package:lumen/services/schedule_notification_coordinator.dart';

class _TrackingNotificationService implements NotificationService {
  final List<(String, FullSchedule, bool)> scheduledCalls = [];
  int immediateCalls = 0;

  @override
  Future<void> scheduleNotificationsForToday(
    FullSchedule fullSchedule, {
    String? groupName,
    bool cancelExisting = true,
    bool rethrowOnError = false,
  }) async {
    scheduledCalls.add((groupName ?? '', fullSchedule, cancelExisting));
  }

  @override
  Future<void> showImmediate(
    String title,
    String body, {
    String? groupName,
    int? notificationId,
    String? notificationTag,
    String? payload,
    bool onlyAlertOnce = false,
    bool rethrowOnError = false,
  }) async {
    immediateCalls++;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('ScheduleNotificationCoordinator on Windows', () {
    late _TrackingNotificationService notifier;
    late ScheduleNotificationCoordinator coordinator;

    final dummySchedule = FullSchedule(
      today: DailySchedule.fromEncodedString('0' * 24),
      tomorrow: DailySchedule.empty(),
    );

    setUp(() {
      notifier = _TrackingNotificationService();
      coordinator = ScheduleNotificationCoordinator(
        notifier: notifier,
        isPlatformSupported: true,
      );
    });

    tearDown(() {
      NotificationService.resetForTesting();
    });

    test(
        'updateNotificationsOnly schedules notifications for active groups when supported',
        () async {
      SharedPreferences.setMockInitialValues({
        'notification_groups': ['GPV1.1', 'GPV2.1'],
      });

      final allSchedules = {
        'GPV1.1': dummySchedule,
        'GPV2.1': dummySchedule,
      };

      await coordinator.updateNotificationsOnly(
        allSchedules: allSchedules,
        currentGroup: 'GPV1.1',
      );

      expect(notifier.scheduledCalls.length, 2);
      expect(notifier.scheduledCalls[0].$1, 'GPV1.1');
      expect(notifier.scheduledCalls[0].$3, isTrue,
          reason: 'First group must cancel existing notifications');
      expect(notifier.scheduledCalls[1].$1, 'GPV2.1');
      expect(notifier.scheduledCalls[1].$3, isFalse,
          reason: 'Subsequent groups must not cancel earlier group schedules');
    });

    test(
        'updateNotificationsOnly skips scheduling when platform is not supported',
        () async {
      final disabledCoordinator = ScheduleNotificationCoordinator(
        notifier: notifier,
        isPlatformSupported: false,
      );

      SharedPreferences.setMockInitialValues({
        'notification_groups': ['GPV1.1'],
      });

      await disabledCoordinator.updateNotificationsOnly(
        allSchedules: {'GPV1.1': dummySchedule},
        currentGroup: 'GPV1.1',
      );

      expect(notifier.scheduledCalls, isEmpty);
    });

    test(
        'NotificationService createWindowsDetails attaches appLogoOverride image when iconPath is set',
        () {
      final service = NotificationService();
      service.windowsIconPath = 'C:\\test\\icon.png';

      final details = service.createWindowsDetails();
      expect(details.images.length, 1);
      expect(details.images.first.placement,
          WindowsImagePlacement.appLogoOverride);
      expect(details.images.first.altText, 'Lumen');
      expect(details.images.first.uri.toFilePath(windows: true),
          'C:\\test\\icon.png');
    });

    test(
        'NotificationService createWindowsDetails returns empty images when iconPath is null',
        () {
      final service = NotificationService();
      service.windowsIconPath = null;

      final details = service.createWindowsDetails();
      expect(details.images, isEmpty);
    });

    test(
        'NotificationService createWindowsDetails returns empty images when iconPath is empty',
        () {
      final service = NotificationService();
      service.windowsIconPath = '';

      final details = service.createWindowsDetails();
      expect(details.images, isEmpty);
    });

    test(
        'canScheduleForTesting enforces minimum lead time to prevent race conditions',
        () {
      tz.initializeTimeZones();
      final now = tz.TZDateTime.now(tz.local);
      final service = NotificationService();

      // Ahead by 10 seconds -> allowed
      final safeFutureTime = now.add(const Duration(seconds: 10));
      expect(service.canScheduleForTesting(safeFutureTime, now), isTrue);

      // Ahead by exactly 5 seconds (minSchedulingLeadTime) -> allowed
      final boundaryTime = now.add(NotificationService.minSchedulingLeadTime);
      expect(service.canScheduleForTesting(boundaryTime, now), isTrue);

      // Ahead by 4 seconds (< 5s) -> rejected to prevent FFI race condition
      final tooCloseTime = now.add(const Duration(seconds: 4));
      expect(service.canScheduleForTesting(tooCloseTime, now), isFalse);

      // In the past -> rejected
      final pastTime = now.subtract(const Duration(seconds: 10));
      expect(service.canScheduleForTesting(pastTime, now), isFalse);
    });

    test(
        'NotificationService resetForTesting clears configured windowsIconPath and resets singleton',
        () {
      final service = NotificationService();
      service.windowsIconPath = 'C:\\test\\icon.png';
      expect(service.windowsIconPath, 'C:\\test\\icon.png');

      NotificationService.resetForTesting();
      expect(service.windowsIconPath, isNull);

      final freshService = NotificationService();
      expect(freshService.windowsIconPath, isNull);
    });
  });
}
