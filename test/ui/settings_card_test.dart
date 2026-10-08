import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/ui/widgets/settings_card.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('SettingsCard Widget Tests', () {
    testWidgets('renders title, subtitle and icon properly',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsCard(
              title: 'Тестова картка',
              subtitle: 'Опис картки',
              icon: Icons.settings,
              initiallyExpanded: true,
              children: [
                Text('Вміст картки 1'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Тестова картка'), findsOneWidget);
      expect(find.text('Опис картки'), findsOneWidget);
      expect(find.byIcon(Icons.settings), findsOneWidget);
      expect(find.text('Вміст картки 1'), findsOneWidget);
    });

    testWidgets('renders properly without subtitle and with trailing widget',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsCard(
              title: 'Картка без субтитра',
              icon: Icons.info_outline,
              initiallyExpanded: true,
              trailing: Chip(label: Text('Beta')),
              children: [
                Text('Контент без субтитра'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Картка без субтитра'), findsOneWidget);
      expect(find.text('Beta'), findsOneWidget);
      expect(find.text('Контент без субтитра'), findsOneWidget);
    });

    testWidgets('toggles expanded state on header tap',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsCard(
              title: 'Секція налаштувань',
              icon: Icons.palette,
              initiallyExpanded: false,
              children: [
                Text('Прихований контент'),
              ],
            ),
          ),
        ),
      );

      // Initially collapsed, content should not be visible
      expect(find.text('Прихований контент'), findsNothing);

      // Tap header to expand
      await tester.tap(find.text('Секція налаштувань'));
      await tester.pumpAndSettle();

      expect(find.text('Прихований контент'), findsOneWidget);

      // Tap header to collapse
      await tester.tap(find.text('Секція налаштувань'));
      await tester.pumpAndSettle();

      expect(find.text('Прихований контент'), findsNothing);
    });

    testWidgets('handles rapid double-tapping safely without crashing',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsCard(
              title: 'Швидкий тап',
              icon: Icons.touch_app,
              initiallyExpanded: true,
              children: [
                Text('Динамічний контент'),
              ],
            ),
          ),
        ),
      );

      await tester.tap(find.text('Швидкий тап'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Швидкий тап'));
      await tester.pumpAndSettle();

      expect(find.text('Швидкий тап'), findsOneWidget);
      expect(find.text('Динамічний контент'), findsOneWidget);
    });

    testWidgets('saves and restores expanded state with persistenceKey',
        (WidgetTester tester) async {
      SharedPreferences.setMockInitialValues({
        'test_card_key': false,
      });

      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsCard(
              title: 'Персистентна картка',
              icon: Icons.cloud,
              persistenceKey: 'test_card_key',
              initiallyExpanded: true, // Should be overridden by prefs (false)
              children: [
                Text('Збережений елемент'),
              ],
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Since prefs had false, it should be collapsed
      expect(find.text('Збережений елемент'), findsNothing);

      // Tap to expand
      await tester.tap(find.text('Персистентна картка'));
      await tester.pumpAndSettle();

      expect(find.text('Збережений елемент'), findsOneWidget);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('test_card_key'), true);
    });

    testWidgets(
        'respects collapsible: false by staying expanded and omitting arrow',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsCard(
              title: 'Нерозбірна картка',
              icon: Icons.lock,
              collapsible: false,
              children: [
                Text('Завжди видимий вміст'),
              ],
            ),
          ),
        ),
      );

      expect(find.text('Нерозбірна картка'), findsOneWidget);
      expect(find.text('Завжди видимий вміст'), findsOneWidget);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsNothing);

      // Tap header should NOT collapse
      await tester.tap(find.text('Нерозбірна картка'));
      await tester.pumpAndSettle();

      expect(find.text('Завжди видимий вміст'), findsOneWidget);
    });

    testWidgets('exposes proper accessibility Semantics with expanded state',
        (WidgetTester tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SettingsCard(
              title: 'Доступна картка',
              icon: Icons.accessibility,
              initiallyExpanded: true,
              children: [
                Text('Текст для скрінрідера'),
              ],
            ),
          ),
        ),
      );

      final semanticsFinder = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.expanded == true &&
            widget.properties.button == true,
      );
      expect(semanticsFinder, findsOneWidget);

      // Tap to collapse
      await tester.tap(find.text('Доступна картка'));
      await tester.pumpAndSettle();

      final collapsedSemanticsFinder = find.byWidgetPredicate(
        (widget) =>
            widget is Semantics &&
            widget.properties.expanded == false &&
            widget.properties.button == true,
      );
      expect(collapsedSemanticsFinder, findsOneWidget);
    });

    testWidgets(
        'inherits cardTheme.color from custom theme (e.g. STALKER / Cyberpunk)',
        (WidgetTester tester) async {
      const customCardColor = Color(0xFF030303);

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark().copyWith(
            cardTheme: const CardThemeData(color: customCardColor),
          ),
          home: const Scaffold(
            body: SettingsCard(
              title: 'Тематична картка',
              icon: Icons.brush,
              children: [
                Text('Тестовий колір'),
              ],
            ),
          ),
        ),
      );

      final materialFinder = find.descendant(
        of: find.byType(SettingsCard),
        matching: find.byWidgetPredicate(
          (w) => w is Material && w.color == customCardColor,
        ),
      );
      expect(materialFinder, findsOneWidget);
    });
  });
}
