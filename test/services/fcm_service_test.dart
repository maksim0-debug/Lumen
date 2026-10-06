import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/services/fcm_service.dart';
import 'package:lumen/services/notification_service.dart';
import 'package:lumen/services/preferences_helper.dart';
import 'package:lumen/utils/app_formatters.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('FcmService Topic Mapping Tests', () {
    test(
        'groupToTopic converts dot notation to lowercase underscore topic format',
        () {
      expect(FcmService.groupToTopic('GPV1.1'), equals('group_gpv1_1'));
      expect(FcmService.groupToTopic('GPV1.2'), equals('group_gpv1_2'));
      expect(FcmService.groupToTopic('GPV2.1'), equals('group_gpv2_1'));
      expect(FcmService.groupToTopic('GPV2.2'), equals('group_gpv2_2'));
      expect(FcmService.groupToTopic('GPV3.1'), equals('group_gpv3_1'));
      expect(FcmService.groupToTopic('GPV3.2'), equals('group_gpv3_2'));
      expect(FcmService.groupToTopic('GPV4.1'), equals('group_gpv4_1'));
      expect(FcmService.groupToTopic('GPV4.2'), equals('group_gpv4_2'));
      expect(FcmService.groupToTopic('GPV5.1'), equals('group_gpv5_1'));
      expect(FcmService.groupToTopic('GPV5.2'), equals('group_gpv5_2'));
      expect(FcmService.groupToTopic('GPV6.1'), equals('group_gpv6_1'));
      expect(FcmService.groupToTopic('GPV6.2'), equals('group_gpv6_2'));
    });

    test('groupToTopic handles dashes and spaces gracefully', () {
      expect(FcmService.groupToTopic('GPV-1.1'), equals('group_gpv_1_1'));
      expect(FcmService.groupToTopic('custom.group-name'),
          equals('group_custom_group_name'));
    });

    test('groupToTopic supports dayType tomorrow by adding suffix _tomorrow',
        () {
      expect(FcmService.groupToTopic('GPV1.1', dayType: 'tomorrow'),
          equals('group_gpv1_1_tomorrow'));
      expect(FcmService.groupToTopic('GPV2.1', dayType: 'tomorrow'),
          equals('group_gpv2_1_tomorrow'));
      expect(FcmService.groupToTopic('GPV6.2', dayType: 'tomorrow'),
          equals('group_gpv6_2_tomorrow'));
    });

    test('FcmService maintains singleton instance', () {
      final instance1 = FcmService();
      final instance2 = FcmService();
      expect(identical(instance1, instance2), isTrue);
    });

    test('FcmService provides non-null broadcast stream for UI listeners', () {
      final stream = FcmService.onMessageStream;
      expect(stream.isBroadcast, isTrue);
    });

    test('FcmService checks platform support correctly', () {
      final service = FcmService();
      // On Windows test host, isSupportedPlatform must be false (only Android and iOS supported)
      expect(service.isSupportedPlatform, isFalse);
    });

    test(
        'groupToTopic matches FCM subscribed topics for background deduplication',
        () {
      final activeSubscribed = {
        'group_gpv1_1',
        'group_gpv2_1',
        'group_gpv4_1',
      };

      expect(
          activeSubscribed.contains(FcmService.groupToTopic('GPV2.1')), isTrue);
      expect(
          activeSubscribed.contains(FcmService.groupToTopic('GPV4.1')), isTrue);
      expect(activeSubscribed.contains(FcmService.groupToTopic('GPV3.1')),
          isFalse);
    });

    test('isFcmInitialized accurately reads boolean preference state',
        () async {
      SharedPreferences.setMockInitialValues({});
      expect(await FcmService.isFcmInitialized(), isFalse);

      SharedPreferences.setMockInitialValues({'fcm_initialized': false});
      expect(await FcmService.isFcmInitialized(), isFalse);

      SharedPreferences.setMockInitialValues({'fcm_initialized': true});
      expect(await FcmService.isFcmInitialized(), isTrue);
    });
  });

  group('PreferencesHelper Notification Groups Tests', () {
    test('returns notification_groups when explicitly saved', () async {
      SharedPreferences.setMockInitialValues({
        'notification_groups': ['GPV1.1', 'GPV4.2'],
      });
      final prefs = await SharedPreferences.getInstance();
      expect(PreferencesHelper.getActiveNotificationGroups(prefs),
          equals(['GPV1.1', 'GPV4.2']));
    });

    test('falls back to selected_group when notification_groups is empty',
        () async {
      SharedPreferences.setMockInitialValues({
        'notification_groups': <String>[],
        'selected_group': 'GPV3.1',
      });
      final prefs = await SharedPreferences.getInstance();
      expect(PreferencesHelper.getActiveNotificationGroups(prefs),
          equals(['GPV3.1']));
    });

    test('falls back to default GPV2.1 when both keys are missing', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      expect(PreferencesHelper.getActiveNotificationGroups(prefs),
          equals(['GPV2.1']));
    });
  });

  group('Notification ID Isolation Tests', () {
    test('getGroupIndex correctly maps all standard DTEK groups', () {
      expect(NotificationService.getGroupIndex('GPV1.1'), equals(0));
      expect(NotificationService.getGroupIndex('GPV1.2'), equals(1));
      expect(NotificationService.getGroupIndex('GPV2.1'), equals(2));
      expect(NotificationService.getGroupIndex('GPV6.2'), equals(11));
      expect(NotificationService.getGroupIndex('NON_EXISTENT'), equals(0));
    });

    test(
        'immediateGroupNotificationBaseId creates non-overlapping IDs from scheduled notifications',
        () {
      const baseId = NotificationService.immediateGroupNotificationBaseId;
      expect(baseId, equals(9000000));

      for (int i = 0; i < 12; i++) {
        final id = baseId + i;
        // Immediate ID is strictly in range 9000000..9000011
        expect(id >= 9000000 && id <= 9000011, isTrue);
        // Scheduled alarms max out around 1124999 (11 * 100000 + 24999), strictly below 9000000
        expect(id > 1200000, isTrue);
      }
    });
  });

  group('AppFormatters Schedule Change Message Tests', () {
    test('formats message correctly when outages decreased (more light)', () {
      final msg = AppFormatters.formatScheduleChangeMessage(
        oldMinutes: 240,
        newMinutes: 120,
      );
      expect(msg, equals("Світла стало БІЛЬШЕ на 2 год. 🎉"));
    });

    test(
        'formats fractional hours correctly when outages increased (less light)',
        () {
      final msg = AppFormatters.formatScheduleChangeMessage(
        oldMinutes: 60,
        newMinutes: 150,
      );
      expect(msg, equals("Світла стало МЕНШЕ на 1.5 год. 😔"));
    });

    test('formats message correctly when duration is unchanged', () {
      final msg = AppFormatters.formatScheduleChangeMessage(
        oldMinutes: 180,
        newMinutes: 180,
      );
      expect(msg, equals("Змінився час відключень на сьогодні ⚡"));
    });
  });
}
