import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/fcm_service.dart';

void main() {
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
  });
}
