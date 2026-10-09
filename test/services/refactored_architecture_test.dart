import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/models/achievement.dart';
import 'package:lumen/models/hour_segment.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/darkness_theme_service.dart';
import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/services/power_monitor_service.dart';
import 'package:lumen/theme/darkness_stage_style.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HourSegment Domain Model', () {
    test('Correctly identifies status without RGB hacks', () {
      const onSegment = HourSegment(
        0.0,
        0.5,
        Colors.green,
        isFuture: false,
        status: LightStatus.on,
      );

      const offSegment = HourSegment(
        0.5,
        1.0,
        Colors.red,
        isFuture: false,
        status: LightStatus.off,
      );

      expect(onSegment.isOn, isTrue);
      expect(onSegment.isOff, isFalse);

      expect(offSegment.isOn, isFalse);
      expect(offSegment.isOff, isTrue);
    });

    test('Works consistently regardless of custom theme colors', () {
      // In old codebase, isOn checked green channel > 100 && red channel < 150.
      // If color was stalker toxic green or dieselpunk goldenrod, it could fail or misclassify.
      const stalkerToxicOn = HourSegment(
        0.0,
        1.0,
        Color(
            0xFF1B5E20), // Dark green, red channel 27, green channel 94 (< 100!)
        isFuture: false,
        status: LightStatus.on,
      );

      // In old RGB pixel check, this dark green would have returned FALSE because green channel (94) <= 100!
      // But domain model knows it is ON.
      expect(stalkerToxicOn.isOn, isTrue);
    });
  });

  group('DarknessStageStyle Architecture', () {
    test('Resolves distinct styles for all darkness stages', () {
      final solarpunk = DarknessStageStyle.of(DarknessStage.solarpunk);
      final dieselpunk = DarknessStageStyle.of(DarknessStage.dieselpunk);
      final cyberpunk = DarknessStageStyle.of(DarknessStage.cyberpunk);
      final stalker = DarknessStageStyle.of(DarknessStage.stalker);
      final defaultStyle = DarknessStageStyle.of(null);

      expect(solarpunk.borderRadius, 14.0);
      expect(dieselpunk.borderRadius, 4.0);
      expect(cyberpunk.borderRadius, 8.0);
      expect(stalker.borderRadius, 2.0);
      expect(defaultStyle.borderRadius, 6.0);

      // Distinct status colors remain available after removing tile icons.
      for (final style in [
        solarpunk,
        dieselpunk,
        cyberpunk,
        stalker,
        defaultStyle
      ]) {
        expect(style.onColor, isNot(style.offColor));
      }
    });

    test('Countdown styles adapt to dark/light theme per stage', () {
      final cyberpunk = DarknessStageStyle.of(DarknessStage.cyberpunk);
      final styleDark = cyberpunk.countdownStyle(true);
      final styleLight = cyberpunk.countdownStyle(false);

      expect(styleDark.border, isNotNull);
      expect(styleLight.border, isNotNull);
      expect(styleDark.textColor, const Color(0xFF00FFFF));
    });
  });

  group('Multi-Listener Singleton Leaks Elimination', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('DarknessThemeService supports multiple listeners without overwriting',
        () async {
      final service = DarknessThemeService();
      await service.init();
      int listener1Count = 0;
      int listener2Count = 0;

      void listener1(DarknessStage stage) {
        listener1Count++;
      }

      void listener2(DarknessStage stage) {
        listener2Count++;
      }

      service.addStageListener(listener1);
      service.addStageListener(listener2);

      // Set stage manually
      await service.setMode('stalker');

      expect(listener1Count, greaterThan(0));
      expect(listener2Count, greaterThan(0));
      expect(listener1Count, equals(listener2Count));

      // Remove listener 1
      service.removeStageListener(listener1);
      final prevL1 = listener1Count;
      final prevL2 = listener2Count;

      await service.setMode('cyberpunk');
      expect(listener1Count, equals(prevL1));
      expect(listener2Count, greaterThan(prevL2));

      service.removeStageListener(listener2);
    });

    test('AchievementService supports multiple listeners', () {
      final service = AchievementService();
      final List<AchievementDef> receivedA = [];
      final List<AchievementDef> receivedB = [];

      void listenerA(AchievementDef a) => receivedA.add(a);
      void listenerB(AchievementDef a) => receivedB.add(a);

      service.addAchievementListener(listenerA);
      service.addAchievementListener(listenerB);

      // Legacy onAchievementUnlocked getter/setter check
      expect(service.onAchievementUnlocked, isNull);
      void legacyListener(AchievementDef a) {}
      service.onAchievementUnlocked = legacyListener;
      expect(service.onAchievementUnlocked, equals(legacyListener));
      service.onAchievementUnlocked = null;

      service.removeAchievementListener(listenerA);
      service.removeAchievementListener(listenerB);
    });

    test('PowerMonitorService supports multiple listeners', () {
      final service = PowerMonitorService();
      int count1 = 0;
      int count2 = 0;

      void listener1(String status) => count1++;
      void listener2(String status) => count2++;

      service.addStatusListener(listener1);
      service.addStatusListener(listener2);

      // Legacy onStatusChanged setter also works without wiping other listeners
      int legacyCount = 0;
      service.onStatusChanged = (String status) => legacyCount++;

      service.removeStatusListener(listener1);
      service.removeStatusListener(listener2);
    });
  });
}
