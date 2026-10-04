import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/services/achievement_service.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/ui/dialogs/shortcut_help_dialog.dart';
import 'package:lumen/ui/shortcuts/app_intents.dart';
import 'package:lumen/ui/shortcuts/app_key_activator.dart';
import 'package:lumen/ui/shortcuts/keyboard_shortcut_wrapper.dart';
import 'package:lumen/ui/shortcuts/shortcut_registry.dart';
import 'package:lumen/ui/state/home_notifier.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async => '.';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PathProviderPlatform.instance = MockPathProviderPlatform();
    await AchievementService().loadAllStates();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({
      'selected_group': 'GPV6.1',
      'notification_groups': ['GPV6.1'],
      'power_monitor_enabled': true,
    });
  });

  group('Keyboard Shortcuts Registry & Mapping Tests (Tier C)', () {
    test(
        'homeShortcuts contains all primary and numpad keys for date navigation',
        () {
      final shortcuts = AppKeyboardShortcuts.homeShortcuts;

      // Day back: A, ArrowLeft, Numpad4
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyA,
            physicalKey: PhysicalKeyboardKey.keyA)],
        isA<NavigateDateIntent>().having((i) => i.offset, 'offset', -1),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.arrowLeft)],
        isA<NavigateDateIntent>().having((i) => i.offset, 'offset', -1),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.numpad4)],
        isA<NavigateDateIntent>().having((i) => i.offset, 'offset', -1),
      );

      // Day forward: D, ArrowRight, Numpad6
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyD,
            physicalKey: PhysicalKeyboardKey.keyD)],
        isA<NavigateDateIntent>().having((i) => i.offset, 'offset', 1),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.arrowRight)],
        isA<NavigateDateIntent>().having((i) => i.offset, 'offset', 1),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.numpad6)],
        isA<NavigateDateIntent>().having((i) => i.offset, 'offset', 1),
      );

      // Today: T, Home, Numpad5
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyT,
            physicalKey: PhysicalKeyboardKey.keyT)],
        isA<JumpToTodayIntent>(),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.home)],
        isA<JumpToTodayIntent>(),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.numpad5)],
        isA<JumpToTodayIntent>(),
      );

      // Refresh: R, F5, Ctrl+R
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyR,
            physicalKey: PhysicalKeyboardKey.keyR)],
        isA<RefreshDataIntent>(),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.f5)],
        isA<RefreshDataIntent>(),
      );
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyR,
            physicalKey: PhysicalKeyboardKey.keyR, control: true)],
        isA<RefreshDataIntent>(),
      );

      // Copy summary: Ctrl+C / Cmd+C
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyC,
            physicalKey: PhysicalKeyboardKey.keyC, control: true)],
        isA<CopyScheduleSummaryIntent>(),
      );

      // Group cycle: Upward increases group number (+1), downward decreases (-1)
      expect(
        shortcuts[
            const SingleActivator(LogicalKeyboardKey.arrowUp, control: true)],
        isA<CycleGroupIntent>().having((i) => i.direction, 'direction', 1),
      );
      expect(
        shortcuts[
            const SingleActivator(LogicalKeyboardKey.numpad8, control: true)],
        isA<CycleGroupIntent>().having((i) => i.direction, 'direction', 1),
      );
      expect(
        shortcuts[
            const SingleActivator(LogicalKeyboardKey.arrowDown, control: true)],
        isA<CycleGroupIntent>().having((i) => i.direction, 'direction', -1),
      );
      expect(
        shortcuts[
            const SingleActivator(LogicalKeyboardKey.numpad2, control: true)],
        isA<CycleGroupIntent>().having((i) => i.direction, 'direction', -1),
      );

      // Group brackets: ] (+1), [ (-1)
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.bracketRight,
            physicalKey: PhysicalKeyboardKey.bracketRight)],
        isA<CycleGroupIntent>().having((i) => i.direction, 'direction', 1),
      );
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.bracketLeft,
            physicalKey: PhysicalKeyboardKey.bracketLeft)],
        isA<CycleGroupIntent>().having((i) => i.direction, 'direction', -1),
      );

      // Mode: M, Num0, W (predicted), S (real)
      // Confirm arrowUp/arrowDown are NOT in shortcuts to allow vertical page scrolling!
      expect(
          shortcuts
              .containsKey(const SingleActivator(LogicalKeyboardKey.arrowUp)),
          isFalse);
      expect(
          shortcuts
              .containsKey(const SingleActivator(LogicalKeyboardKey.arrowDown)),
          isFalse);

      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyM,
            physicalKey: PhysicalKeyboardKey.keyM)],
        isA<ToggleDataSourceModeIntent>(),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.numpad0)],
        isA<ToggleDataSourceModeIntent>(),
      );
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyW,
            physicalKey: PhysicalKeyboardKey.keyW)],
        isA<SetDataSourceModeIntent>()
            .having((i) => i.mode, 'mode', DataSourceMode.predicted),
      );
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyS,
            physicalKey: PhysicalKeyboardKey.keyS)],
        isA<SetDataSourceModeIntent>()
            .having((i) => i.mode, 'mode', DataSourceMode.real),
      );

      // Theme toggle: F4, Ctrl+Shift+D
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.f4,
            includeRepeats: false)],
        isA<ToggleThemeIntent>(),
      );
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyD,
            physicalKey: PhysicalKeyboardKey.keyD,
            control: true,
            shift: true,
            includeRepeats: false)],
        isA<ToggleThemeIntent>(),
      );
    });

    test('analyticsShortcuts contains tab navigation and group cycling', () {
      final shortcuts = AppKeyboardShortcuts.analyticsShortcuts;

      // Tab prev: A, ArrowLeft, Numpad4
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyA,
            physicalKey: PhysicalKeyboardKey.keyA)],
        isA<AnalyticsPrevTabIntent>(),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.arrowLeft)],
        isA<AnalyticsPrevTabIntent>(),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.numpad4)],
        isA<AnalyticsPrevTabIntent>(),
      );

      // Tab next: D, ArrowRight, Numpad6
      expect(
        shortcuts[const AppShortcutActivator(LogicalKeyboardKey.keyD,
            physicalKey: PhysicalKeyboardKey.keyD)],
        isA<AnalyticsNextTabIntent>(),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.arrowRight)],
        isA<AnalyticsNextTabIntent>(),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.numpad6)],
        isA<AnalyticsNextTabIntent>(),
      );

      // Direct tab keys 1..5
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.digit1)],
        isA<AnalyticsSelectTabIntent>()
            .having((i) => i.tabIndex, 'tabIndex', 0),
      );
      expect(
        shortcuts[const SingleActivator(LogicalKeyboardKey.digit5)],
        isA<AnalyticsSelectTabIntent>()
            .having((i) => i.tabIndex, 'tabIndex', 4),
      );

      // Ctrl + ArrowUp / ArrowDown for groups in analytics
      expect(
        shortcuts[
            const SingleActivator(LogicalKeyboardKey.arrowUp, control: true)],
        isA<CycleGroupIntent>().having((i) => i.direction, 'direction', 1),
      );
      expect(
        shortcuts[
            const SingleActivator(LogicalKeyboardKey.arrowDown, control: true)],
        isA<CycleGroupIntent>().having((i) => i.direction, 'direction', -1),
      );
    });
  });

  group('HomeNotifier Group & Mode Shortcuts - BDD Scenarios (Tier A)', () {
    test(
        'GIVEN current group is 6.1 WHEN cycling group forward THEN group becomes 6.2',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);
      await notifier.changeGroup('GPV6.1');
      expect(
          container.read(homeNotifierProvider).currentGroup, equals('GPV6.1'));

      await notifier.cycleGroup(1);
      expect(
          container.read(homeNotifierProvider).currentGroup, equals('GPV6.2'));
    });

    test(
        'GIVEN current group is 6.2 WHEN cycling group forward THEN wraps around to 1.1',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);
      await notifier.changeGroup('GPV6.2');

      await notifier.cycleGroup(1);
      expect(
          container.read(homeNotifierProvider).currentGroup, equals('GPV1.1'));
    });

    test(
        'GIVEN current group is 1.1 WHEN cycling group backward THEN wraps around to 6.2',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);
      await notifier.changeGroup('GPV1.1');

      await notifier.cycleGroup(-1);
      expect(
          container.read(homeNotifierProvider).currentGroup, equals('GPV6.2'));
    });

    test(
        'GIVEN group selection by digit WHEN selecting 3 THEN switches to GPV3.1 and toggles to GPV3.2 on repeat',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);
      await notifier.changeGroup('GPV1.1');

      await notifier.selectGroupByIndex(3);
      expect(
          container.read(homeNotifierProvider).currentGroup, equals('GPV3.1'));

      await notifier.selectGroupByIndex(3);
      expect(
          container.read(homeNotifierProvider).currentGroup, equals('GPV3.2'));

      await notifier.selectGroupByIndex(3);
      expect(
          container.read(homeNotifierProvider).currentGroup, equals('GPV3.1'));
    });

    test(
        'GIVEN power monitor enabled WHEN toggling data source mode THEN alternates predicted and real',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final notifier = container.read(homeNotifierProvider.notifier);
      container.read(homeNotifierProvider.notifier).state =
          container.read(homeNotifierProvider).copyWith(
                powerMonitorEnabled: true,
                dataSourceMode: DataSourceMode.predicted,
              );

      await notifier.toggleDataSourceMode();
      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.real));

      await notifier.toggleDataSourceMode();
      expect(container.read(homeNotifierProvider).dataSourceMode,
          equals(DataSourceMode.predicted));
    });
  });

  group('Property-Based Group Invariants (Tier B)', () {
    test(
        'Inv-1: Cycling through all 12 groups forward exactly 12 times returns to starting group',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(homeNotifierProvider.notifier);

      for (final startGroup in ParserService.allGroups) {
        await notifier.changeGroup(startGroup);
        for (int i = 0; i < ParserService.allGroups.length; i++) {
          await notifier.cycleGroup(1);
        }
        expect(container.read(homeNotifierProvider).currentGroup,
            equals(startGroup));
      }
    });

    test('Inv-2: Cycling backward 12 times returns to starting group',
        () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(homeNotifierProvider.notifier);

      for (final startGroup in ParserService.allGroups) {
        await notifier.changeGroup(startGroup);
        for (int i = 0; i < ParserService.allGroups.length; i++) {
          await notifier.cycleGroup(-1);
        }
        expect(container.read(homeNotifierProvider).currentGroup,
            equals(startGroup));
      }
    });
  });

  group('KeyboardShortcutWrapper & Focus Protection Tests (Tier C & D)', () {
    testWidgets(
        'GIVEN an active text field WHEN user types hotkey letter THEN shortcut does not intercept text',
        (tester) async {
      bool actionTriggered = false;
      final textController = TextEditingController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardShortcutWrapper(
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.keyA):
                    NavigateDateIntent(-1),
              },
              actions: {
                NavigateDateIntent: CallbackAction<NavigateDateIntent>(
                  onInvoke: (intent) {
                    actionTriggered = true;
                    return null;
                  },
                ),
              },
              child: Center(
                child: TextField(
                  controller: textController,
                  autofocus: true,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      // Focus is inside the TextField
      expect(
          FocusManager.instance.primaryFocus?.context
                  ?.findAncestorStateOfType<EditableTextState>() !=
              null,
          isTrue);

      // Send 'A' key event
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();

      // Action should NOT have been invoked because user is typing in TextField!
      expect(actionTriggered, isFalse);
    });

    testWidgets(
        'ShortcutHelpDialog renders all cheat sheet categories and keycaps',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: ShortcutHelpDialog(),
          ),
        ),
      );

      await tester.pumpAndSettle();

      // Check header and initially visible categories
      expect(find.text('Гарячі клавіші керування'), findsOneWidget);
      expect(find.text('📅 Навігація по датах'), findsOneWidget);

      // Scroll and verify subsequent categories
      await tester.scrollUntilVisible(
          find.text('⚡ Режим даних (Графік ⟷ Факт)'), 100);
      expect(find.text('⚡ Режим даних (Графік ⟷ Факт)'), findsOneWidget);

      // Scroll and verify subsequent categories
      await tester.scrollUntilVisible(find.text('👥 Вибір групи (Черги)'), 100);
      expect(find.text('👥 Вибір групи (Черги)'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('🔄 Оновлення та версії'), 100);
      expect(find.text('🔄 Оновлення та версії'), findsOneWidget);

      await tester.scrollUntilVisible(
          find.text('🧭 Швидкі переходи по екранах'), 100);
      expect(find.text('🧭 Швидкі переходи по екранах'), findsOneWidget);

      await tester.scrollUntilVisible(
          find.text('📊 Навігація в Аналітиці'), 100);
      expect(find.text('📊 Навігація в Аналітиці'), findsOneWidget);
    });

    testWidgets(
        'GIVEN focused KeyboardShortcutWrapper WHEN user presses shortcut key THEN action is invoked successfully',
        (tester) async {
      bool actionTriggered = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardShortcutWrapper(
              autofocus: true,
              shortcuts: const {
                SingleActivator(LogicalKeyboardKey.keyA):
                    NavigateDateIntent(-1),
              },
              actions: {
                NavigateDateIntent: CallbackAction<NavigateDateIntent>(
                  onInvoke: (intent) {
                    actionTriggered = true;
                    return null;
                  },
                ),
              },
              child: const Text('Home Screen Content'),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.pumpAndSettle();

      expect(actionTriggered, isTrue);
    });

    testWidgets('ShortcutHelpDialog can be dismissed via Escape key',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () => ShortcutHelpDialog.show(context),
                child: const Text('Open Help'),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.text('Open Help'));
      await tester.pumpAndSettle();

      expect(find.byType(ShortcutHelpDialog), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.byType(ShortcutHelpDialog), findsNothing);
    });

    testWidgets(
        'ShortcutHelpDialog renders without overflow on narrow 360px mobile screen',
        (tester) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await tester.pumpWidget(
        MaterialApp(
          theme: ThemeData.dark(),
          home: const Scaffold(
            body: ShortcutHelpDialog(),
          ),
        ),
      );

      await tester.pumpAndSettle();
      expect(find.byType(ShortcutHelpDialog), findsOneWidget);
      // If RenderFlex had overflowed, pumpAndSettle would have thrown FlutterError
      expect(tester.takeException(), isNull);
    });
  });

  group('AppShortcutActivator Cross-Platform & Layout Independence Tests', () {
    test(
        'accepts key by physicalKey even when logicalKey is Cyrillic (Ukrainian layout)',
        () {
      const activator = AppShortcutActivator(
        LogicalKeyboardKey.keyD,
        physicalKey: PhysicalKeyboardKey.keyD,
      );

      // Simulate Ukrainian 'в' keydown event with physical key D
      const event = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyD,
        logicalKey: LogicalKeyboardKey(0x00000432), // Ukrainian 'в'
        timeStamp: Duration.zero,
      );

      expect(activator.accepts(event, HardwareKeyboard.instance), isTrue);
    });

    test('rejects trigger key when required control modifier is not pressed',
        () {
      const activator = AppShortcutActivator(
        LogicalKeyboardKey.keyC,
        physicalKey: PhysicalKeyboardKey.keyC,
        control: true,
      );

      const normalEvent = KeyDownEvent(
        physicalKey: PhysicalKeyboardKey.keyC,
        logicalKey: LogicalKeyboardKey.keyC,
        timeStamp: Duration.zero,
      );
      expect(
          activator.accepts(normalEvent, HardwareKeyboard.instance), isFalse);
    });
  });

  group('SaveEditorDataIntent & Focus Unfocus Tests', () {
    testWidgets(
        'GIVEN active text field WHEN user presses Ctrl+S THEN SaveEditorDataIntent is invoked',
        (tester) async {
      bool saveTriggered = false;
      final textController = TextEditingController(text: 'sample');

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardShortcutWrapper(
              shortcuts: AppKeyboardShortcuts.editorShortcuts,
              actions: {
                SaveEditorDataIntent: CallbackAction<SaveEditorDataIntent>(
                  onInvoke: (intent) {
                    saveTriggered = true;
                    return null;
                  },
                ),
              },
              child: Center(
                child: TextField(
                  controller: textController,
                  autofocus: true,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      // Press Ctrl+S
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pumpAndSettle();

      expect(saveTriggered, isTrue);
    });

    testWidgets(
        'GIVEN active text field WHEN user presses Escape THEN focus is removed from TextField',
        (tester) async {
      final textController = TextEditingController();

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: KeyboardShortcutWrapper(
              shortcuts: AppKeyboardShortcuts.editorShortcuts,
              actions: {
                CloseTopModalOrGoBackIntent:
                    CallbackAction<CloseTopModalOrGoBackIntent>(
                  onInvoke: (intent) => null,
                ),
              },
              child: Center(
                child: TextField(
                  controller: textController,
                  autofocus: true,
                ),
              ),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pumpAndSettle();

      // Ensure focused
      expect(
          FocusManager.instance.primaryFocus?.context
                  ?.findAncestorStateOfType<EditableTextState>() !=
              null,
          isTrue);

      // Press Escape
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      // Focus should be unfocused from TextField
      expect(
          FocusManager.instance.primaryFocus?.context
                  ?.findAncestorStateOfType<EditableTextState>() !=
              null,
          isFalse);
    });
  });

  group('ParserService.cycleGroup Unit & Boundary Tests', () {
    test('cycling forward from first group steps sequentially to last', () {
      String current = ParserService.allGroups.first;
      for (int i = 1; i < ParserService.allGroups.length; i++) {
        current = ParserService.cycleGroup(current, 1);
        expect(current, equals(ParserService.allGroups[i]));
      }
    });

    test('cycling forward from last group wraps around to first', () {
      final next = ParserService.cycleGroup('GPV6.2', 1);
      expect(next, equals('GPV1.1'));
    });

    test('cycling backward from first group wraps around to last', () {
      final prev = ParserService.cycleGroup('GPV1.1', -1);
      expect(prev, equals('GPV6.2'));
    });

    test('direction 0 leaves group unchanged', () {
      final same = ParserService.cycleGroup('GPV3.1', 0);
      expect(same, equals('GPV3.1'));
    });

    test('unknown group defaults to first index and steps', () {
      final next = ParserService.cycleGroup('UNKNOWN_GROUP', 1);
      expect(next, equals(ParserService.allGroups[1]));
    });
  });
}
