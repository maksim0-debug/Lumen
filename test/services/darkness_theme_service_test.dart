import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/services/darkness_theme_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('DarknessThemeService Arrow Icons', () {
    late DarknessThemeService service;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      service = DarknessThemeService();
      await service.init();
    });

    test('Solarpunk stage has symmetric arrow icons', () async {
      await service.setMode('solarpunk');
      expect(service.currentStage, DarknessStage.solarpunk);
      expect(service.getArrowIcon(forward: true),
          Icons.arrow_circle_right_outlined);
      expect(service.getArrowIcon(forward: false),
          Icons.arrow_circle_left_outlined);
    });

    test('Dieselpunk stage has symmetric arrow icons', () async {
      await service.setMode('dieselpunk');
      expect(service.currentStage, DarknessStage.dieselpunk);
      expect(service.getArrowIcon(forward: true), Icons.arrow_forward_ios);
      expect(service.getArrowIcon(forward: false), Icons.arrow_back_ios_new);
    });

    test('Cyberpunk stage has symmetric arrow icons', () async {
      await service.setMode('cyberpunk');
      expect(service.currentStage, DarknessStage.cyberpunk);
      expect(service.getArrowIcon(forward: true),
          Icons.keyboard_double_arrow_right);
      expect(service.getArrowIcon(forward: false),
          Icons.keyboard_double_arrow_left);
    });

    test(
        'Stalker stage returns Icons.forward for both directions and flips backward',
        () async {
      await service.setMode('stalker');
      expect(service.currentStage, DarknessStage.stalker);
      expect(service.getArrowIcon(forward: true), Icons.forward);
      expect(service.getArrowIcon(forward: false), Icons.forward);
    });

    testWidgets(
        'buildArrowIcon in Stalker stage returns flipped widget for backward navigation',
        (tester) async {
      await service.setMode('stalker');

      final forwardWidget =
          service.buildArrowIcon(forward: true, color: Colors.green);
      final backwardWidget =
          service.buildArrowIcon(forward: false, color: Colors.green);

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Column(
              children: [
                forwardWidget,
                backwardWidget,
              ],
            ),
          ),
        ),
      );

      // Verify that forward is a normal Icon(Icons.forward)
      expect(forwardWidget, isA<Icon>());
      expect((forwardWidget as Icon).icon, Icons.forward);

      // Verify that backward widget is a Transform.flip wrapping Icon(Icons.forward)
      expect(backwardWidget, isA<Transform>());
      final Transform transform = backwardWidget as Transform;
      expect(transform.transform.storage[0], -1.0);
      expect(transform.child, isA<Icon>());
      expect((transform.child as Icon).icon, Icons.forward);
    });
  });
}

