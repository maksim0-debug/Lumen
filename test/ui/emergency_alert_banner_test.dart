import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/ui/widgets/home/emergency_alert_banner.dart';

void main() {
  for (final brightness in Brightness.values) {
    for (final size in [
      const Size(320, 640),
      const Size(640, 320),
      const Size(800, 1000)
    ]) {
      for (final possible in [true, false]) {
        testWidgets(
            'opens complete DTEK text at $size, $brightness, possible=$possible',
            (tester) async {
          tester.view.physicalSize = size;
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final notice =
              'Шановні клієнти!\n\n${'Повний текст ДТЕК про аварійні відключення у Бучанському районі.\n\n' * 12}Дякуємо за ваше розуміння!';
          await tester.pumpWidget(MaterialApp(
            theme: ThemeData(brightness: brightness),
            builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!),
            home: Scaffold(
                body: Center(
                    child: EmergencyAlertBanner(
                        isActive: true,
                        isPossible: possible,
                        noticeText: notice))),
          ));
          expect(
              find.text(possible
                  ? 'Можливі екстрені відключення'
                  : 'Зараз діють екстрені відключення'),
              findsOneWidget);
          expect(find.text('Не вдалося отримати актуальні дані'), findsNothing);
          expect(tester.takeException(), null);
          await tester.tap(find.byType(EmergencyAlertBanner));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsOneWidget);
          expect(
              tester.widget<SelectableText>(find.byType(SelectableText)).data,
              notice);
          expect(tester.takeException(), null);
          final scrollable = find
              .descendant(
                  of: find.byType(AlertDialog),
                  matching: find.byType(SingleChildScrollView))
              .first;
          await tester.drag(scrollable, const Offset(0, -2000));
          await tester.pumpAndSettle();
          expect(tester.takeException(), null);
          await tester.tap(find.text('Закрити'));
          await tester.pumpAndSettle();
          expect(find.byType(AlertDialog), findsNothing);
        });
      }
    }
  }

  testWidgets('stale state does not claim a verified current emergency',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
            body: EmergencyAlertBanner(isActive: true, isStale: true))));
    expect(find.text('Останні дані: екстрені відключення'), findsOneWidget);
    expect(find.text('Не вдалося отримати актуальні дані'), findsOneWidget);
    expect(find.text('Зараз діють екстрені відключення'), findsNothing);
  });

  testWidgets(
      'narrow layout and enlarged text remain readable without overflow',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
        home: MediaQuery(
            data: MediaQueryData(textScaler: TextScaler.linear(2)),
            child: Scaffold(
                body: Center(
                    child: SizedBox(
                        width: 280,
                        child: EmergencyAlertBanner(isActive: true)))))));
    expect(tester.takeException(), null);
    expect(find.text('Можливі відхилення від графіків'), findsOneWidget);
    final container = tester.widget<Container>(find
        .descendant(
            of: find.byType(EmergencyAlertBanner),
            matching: find.byType(Container))
        .first);
    final decoration = container.decoration! as BoxDecoration;
    expect(decoration.boxShadow, null);
    expect(decoration.color!.a, lessThan(0.1));
  });

  group('EmergencyAlertBanner Widget Tests', () {
    testWidgets('renders SizedBox.shrink when isActive is false',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmergencyAlertBanner(isActive: false),
          ),
        ),
      );

      expect(find.text('Зараз діють екстрені відключення'), findsNothing);
      expect(find.byIcon(Icons.warning_amber_rounded), findsNothing);
      expect(find.byType(SizedBox), findsOneWidget);
    });

    testWidgets('renders compact banner and text when isActive is true',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: EmergencyAlertBanner(isActive: true),
          ),
        ),
      );

      expect(find.text('Зараз діють екстрені відключення'), findsOneWidget);
      expect(find.text('Можливі відхилення від графіків'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      final size = tester.getSize(find.byType(EmergencyAlertBanner));
      expect(size.width, lessThanOrEqualTo(280));
    });

    testWidgets('adapts cleanly to dark theme', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: EmergencyAlertBanner(isActive: true),
          ),
        ),
      );

      expect(find.text('Зараз діють екстрені відключення'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
    });

    for (final brightness in Brightness.values) {
      testWidgets('uses a neutral surface and amber accent in $brightness',
          (tester) async {
        final theme = ThemeData(brightness: brightness);
        await tester.pumpWidget(MaterialApp(
          theme: theme,
          home: const Scaffold(body: EmergencyAlertBanner(isActive: true)),
        ));

        final container = tester.widget<Container>(find.descendant(
            of: find.byType(EmergencyAlertBanner),
            matching: find.byType(Container)));
        final decoration = container.decoration! as BoxDecoration;
        final border = decoration.border! as Border;
        final icon =
            tester.widget<Icon>(find.byIcon(Icons.warning_amber_rounded));
        expect(decoration.color,
            theme.colorScheme.onSurface.withValues(alpha: 0.035));
        expect(border.top.width, 1);
        expect(border.top.color, icon.color!.withValues(alpha: 0.35));
        expect(icon.color!.g, greaterThan(icon.color!.b));
        expect(decoration.boxShadow, null);
      });
    }
  });
}
