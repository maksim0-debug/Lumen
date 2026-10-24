import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/windows_startup_service.dart';
import 'package:lumen/ui/widgets/windows_startup_settings.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Registration implements WindowsStartupRegistration {
  bool enabled = true;
  int mutations = 0;
  Object? error;
  Completer<void>? pending;

  @override
  Future<void> initialize() async {}

  @override
  Future<bool> isEnabled() async => enabled;

  @override
  Future<void> setEnabled(bool value) async {
    mutations++;
    await pending?.future;
    if (error != null) throw error!;
    enabled = value;
  }
}

class _FailingModeService extends WindowsStartupService {
  _FailingModeService({required super.registration});
  bool fail = true;

  @override
  Future<void> writeMode(WindowsStartupMode mode) async {
    if (fail) throw StateError('Storage unavailable');
    await super.writeMode(mode);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _Registration registration;

  setUp(() {
    SharedPreferences.setMockInitialValues({'enable_logging': false});
    registration = _Registration();
  });

  Future<void> mount(WidgetTester tester,
      {WindowsStartupService? service}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(
              child: WindowsStartupSettings(
        service: service ?? WindowsStartupService(registration: registration),
      ))),
    ));
    await tester.pumpAndSettle();
  }

  WindowsStartupMode? selected(WidgetTester tester) => tester
      .widget<RadioGroup<WindowsStartupMode>>(
          find.byType(RadioGroup<WindowsStartupMode>))
      .groupValue;

  testWidgets('tray is selected by default and modes remain mutually exclusive',
      (tester) async {
    await mount(tester);
    expect(selected(tester), WindowsStartupMode.tray);
    await tester.tap(find.text('Згорнуто на панелі завдань'));
    await tester.pumpAndSettle();
    expect(selected(tester), WindowsStartupMode.minimized);
    expect(
        (await SharedPreferences.getInstance())
            .getString(WindowsStartupService.modeKey),
        'minimized');
    await tester.tap(find.text('У треї'));
    await tester.pumpAndSettle();
    expect(selected(tester), WindowsStartupMode.tray);
    expect(
        (await SharedPreferences.getInstance())
            .getString(WindowsStartupService.modeKey),
        'tray');
  });

  testWidgets(
      'disabled startup disables mode selection and keeps the saved mode',
      (tester) async {
    SharedPreferences.setMockInitialValues(
        {WindowsStartupService.modeKey: 'minimized'});
    registration.enabled = false;
    await mount(tester);
    expect(selected(tester), WindowsStartupMode.minimized);
    expect(
        tester
            .widgetList<RadioListTile<WindowsStartupMode>>(
                find.byType(RadioListTile<WindowsStartupMode>))
            .every((tile) => tile.enabled == false),
        isTrue);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(registration.enabled, true);
    expect(selected(tester), WindowsStartupMode.minimized);
  });

  testWidgets(
      'pending system update disables controls and publishes after success',
      (tester) async {
    await mount(tester);
    registration.pending = Completer<void>();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    final pendingSwitch =
        tester.widget<SwitchListTile>(find.byType(SwitchListTile));
    expect(pendingSwitch.value, true);
    expect(pendingSwitch.onChanged, isNull);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(
        tester
            .widgetList<RadioListTile<WindowsStartupMode>>(
                find.byType(RadioListTile<WindowsStartupMode>))
            .every((tile) => tile.enabled == false),
        isTrue);
    registration.pending!.complete();
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false);
    expect(registration.mutations, 1);
  });

  testWidgets(
      'failed system update keeps verified state and explains the failure',
      (tester) async {
    registration.enabled = false;
    registration.error = PlatformException(code: 'startup_disabled_by_user');
    await mount(tester);
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value,
        false);
    expect(
        find.textContaining('Автозапуск вимкнено у Windows.'), findsOneWidget);
    registration.error = null;
    await tester.tap(find.byType(SwitchListTile));
    await tester.pumpAndSettle();
    expect(
        tester.widget<SwitchListTile>(find.byType(SwitchListTile)).value, true);
    expect(find.textContaining('Автозапуск вимкнено у Windows.'), findsNothing);
  });

  testWidgets('failed mode save retains previous mode and can be retried',
      (tester) async {
    final service = _FailingModeService(registration: registration);
    await mount(tester, service: service);
    await tester.tap(find.text('Згорнуто на панелі завдань'));
    await tester.pumpAndSettle();
    expect(selected(tester), WindowsStartupMode.tray);
    expect(find.textContaining('Не вдалося застосувати'), findsOneWidget);
    service.fail = false;
    await tester.tap(find.text('Згорнуто на панелі завдань'));
    await tester.pumpAndSettle();
    expect(selected(tester), WindowsStartupMode.minimized);
  });

  testWidgets('completing an update after leaving settings does not set state',
      (tester) async {
    await mount(tester);
    registration.pending = Completer<void>();
    await tester.tap(find.byType(SwitchListTile));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    registration.pending!.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(registration.enabled, false);
  });

  for (final brightness in Brightness.values) {
    testWidgets(
        'startup choices fit narrow ${brightness.name} layout with large text',
        (tester) async {
      tester.view.physicalSize = const Size(360, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(MaterialApp(
        theme: ThemeData(brightness: brightness),
        home: MediaQuery(
          data: const MediaQueryData(textScaler: TextScaler.linear(1.8)),
          child: Scaffold(
              body: SingleChildScrollView(
                  child: WindowsStartupSettings(
            service: WindowsStartupService(registration: registration),
          ))),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('У треї'), findsOneWidget);
      expect(find.text('Згорнуто на панелі завдань'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
