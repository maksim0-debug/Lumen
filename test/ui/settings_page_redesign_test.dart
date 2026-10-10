import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/services/app_info_service.dart';
import 'package:lumen/services/power_monitor_service.dart';
import 'package:lumen/ui/settings_page.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'is_dark_mode': true,
      'notify_1h_before_off': true,
      'notify_30m_before_off': true,
      'notify_5m_before_off': true,
      'notify_1h_before_on': true,
      'notify_30m_before_on': true,
      'selected_group': '1.1',
      'notification_groups': ['1.1'],
    });
    AppInfoService.setMockPackageInfo(
      PackageInfo(
        appName: 'Lumen',
        packageName: 'lumen',
        version: '1.3.0',
        buildNumber: '8',
        buildSignature: '',
      ),
    );
  });

  tearDown(() {
    AppInfoService.setMockPackageInfo(null);
    PowerMonitorService().stopPolling();
  });

  testWidgets(
      'SettingsPage renders all modular cards and preserves all settings',
      (WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 3000);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      const ProviderScope(
        child: MaterialApp(
          home: SettingsPage(),
        ),
      ),
    );

    await tester.pump();
    await tester.pumpAndSettle();

    // Verify main card headers exist
    expect(find.text('Оформлення та інтерфейс'), findsOneWidget);
    expect(find.text('Сповіщення'), findsOneWidget);
    expect(find.text('Моніторинг 220 В'), findsOneWidget);
    expect(find.text('Підключення реального моніторингу електромережі'),
        findsOneWidget);
    expect(find.text('Резервне копіювання (Beta)'), findsOneWidget);
    expect(find.text('Журнал та діагностика'), findsOneWidget);

    // Verify "Оформлення та інтерфейс" contents (expanded by default)
    expect(find.text('Темна тема'), findsOneWidget);
    expect(find.text('Стиль оформлення'), findsOneWidget);
    expect(find.text('Анімації'), findsOneWidget);
    expect(find.text('Масштаб'), findsOneWidget);
    expect(find.text('Приховувати версії без змін'), findsOneWidget);

    // Verify "Оповіщення" contents with horizontal sub-cards
    expect(find.text('Групи для сповіщень'), findsOneWidget);
    expect(find.text('До відключення світла'), findsOneWidget);
    expect(find.text('До відновлення світла'), findsOneWidget);

    // Verify chips inside sub-cards
    expect(find.text('1 година'), findsNWidgets(2));
    expect(find.text('30 хвилин'), findsNWidgets(2));
    expect(find.text('5 хвилин'), findsOneWidget);

    // Toggle 5 хвилин chip
    await tester.tap(find.text('5 хвилин'));
    await tester.pumpAndSettle();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('notify_5m_before_off'), false);

    expect(find.text('Зміна графіка'), findsOneWidget);
    expect(find.text('Графік на завтра'), findsOneWidget);

    // "Моніторинг 220 В" is collapsed by default when disabled
    expect(find.text('Реальний моніторинг'), findsNothing);

    // Tap to expand "Моніторинг 220 В"
    await tester.tap(find.text('Моніторинг 220 В'));
    await tester.pumpAndSettle();

    expect(find.text('Реальний моніторинг'), findsOneWidget);
    // Guide MUST be visible even when power monitoring is disabled!
    expect(
        find.text('Як налаштувати свій сенсор? (Інструкція)'), findsOneWidget);

    // Toggle "Реальний моніторинг" on to verify configuration fields appear
    await tester.tap(find.text('Реальний моніторинг'));
    await tester.pumpAndSettle();

    expect(find.text('URL бази даних Firebase'), findsOneWidget);
    expect(find.text('Зберегти'), findsOneWidget);
    expect(
        find.text('Як налаштувати свій сенсор? (Інструкція)'), findsOneWidget);

    // Toggle "Реальний моніторинг" off to cancel timers
    await tester.tap(find.text('Реальний моніторинг'));
    await tester.pumpAndSettle();

    // Initially collapsed "Резервне копіювання"
    expect(find.text('Створити резервну копію'), findsNothing);

    // Tap to expand "Резервне копіювання (Beta)"
    await tester.tap(find.text('Резервне копіювання (Beta)'));
    await tester.pumpAndSettle();

    expect(find.text('Створити резервну копію'), findsOneWidget);
    expect(find.text('Відновити з файлу'), findsOneWidget);
    expect(find.text('Експорт історії за період (JSON)'), findsOneWidget);
    expect(find.text('Імпорт історії з JSON'), findsOneWidget);
    expect(find.text('Ручне редагування графіка'), findsOneWidget);

    // Tap to expand "Журнал та діагностика"
    await tester.tap(find.text('Журнал та діагностика'));
    await tester.pumpAndSettle();

    expect(find.text('Переглянути логи'), findsOneWidget);
    expect(find.text('Увімкнути логування'), findsOneWidget);

    // Verify footer
    expect(find.text('Lumen v1.3.0+8'), findsOneWidget);
    expect(find.text('Розробник: @maksim0-debug'), findsOneWidget);
  });
}
