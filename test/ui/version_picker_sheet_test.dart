import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/ui/dialogs/version_picker_sheet.dart';
import 'package:lumen/ui/shortcuts/app_intents.dart';

void main() {
  final sampleVersions = [
    ScheduleVersion(
      hash: '0' * 24,
      savedAt: DateTime(2026, 10, 1, 0, 0),
      outageMinutes: 0,
    ),
    ScheduleVersion(
      hash: '1' * 24,
      savedAt: DateTime(2026, 10, 1, 6, 36),
      outageMinutes: 1440,
    ),
  ];

  Widget buildTestApp({
    required VoidCallback onOpen,
  }) {
    return MaterialApp(
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (context) {
              return ElevatedButton(
                onPressed: onOpen,
                child: const Text('Open Picker'),
              );
            },
          ),
        ),
      ),
    );
  }

  tearDown(() {
    VersionPickerSheet.resetOpenState();
  });

  group('VersionPickerSheet Keyboard Toggle and Close Tests', () {
    testWidgets('Pressing key V closes the version picker sheet',
        (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          onOpen: () {},
        ),
      );

      final BuildContext context = tester.element(find.byType(ElevatedButton));

      VersionPickerSheet.show(
        context: context,
        versions: sampleVersions,
        selectedVersionIndex: 0,
        onVersionSelected: (_) {},
      );

      await tester.pumpAndSettle();
      expect(find.text('Оберіть версію'), findsOneWidget);
      expect(VersionPickerSheet.isOpen, isTrue);

      // Press key V to close the picker
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.pumpAndSettle();

      expect(find.text('Оберіть версію'), findsNothing);
      expect(VersionPickerSheet.isOpen, isFalse);
    });

    testWidgets(
        'Pressing physical key V (Cyrillic layout) closes the version picker sheet',
        (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          onOpen: () {},
        ),
      );

      final BuildContext context = tester.element(find.byType(ElevatedButton));

      VersionPickerSheet.show(
        context: context,
        versions: sampleVersions,
        selectedVersionIndex: 0,
        onVersionSelected: (_) {},
      );

      await tester.pumpAndSettle();
      expect(find.text('Оберіть версію'), findsOneWidget);

      // Simulate physical key V with different logical key (e.g. keyM / Cyrillic layout)
      await tester.sendKeyEvent(
        LogicalKeyboardKey.keyM,
        physicalKey: PhysicalKeyboardKey.keyV,
      );
      await tester.pumpAndSettle();

      expect(find.text('Оберіть версію'), findsNothing);
      expect(VersionPickerSheet.isOpen, isFalse);
    });

    testWidgets('Pressing Escape closes the version picker sheet',
        (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          onOpen: () {},
        ),
      );

      final BuildContext context = tester.element(find.byType(ElevatedButton));

      VersionPickerSheet.show(
        context: context,
        versions: sampleVersions,
        selectedVersionIndex: 0,
        onVersionSelected: (_) {},
      );

      await tester.pumpAndSettle();
      expect(find.text('Оберіть версію'), findsOneWidget);
      expect(VersionPickerSheet.isOpen, isTrue);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();

      expect(find.text('Оберіть версію'), findsNothing);
      expect(VersionPickerSheet.isOpen, isFalse);
    });

    testWidgets('Calling show while already open does not open duplicate sheet',
        (tester) async {
      await tester.pumpWidget(
        buildTestApp(
          onOpen: () {},
        ),
      );

      final BuildContext context = tester.element(find.byType(ElevatedButton));

      VersionPickerSheet.show(
        context: context,
        versions: sampleVersions,
        selectedVersionIndex: 0,
        onVersionSelected: (_) {},
      );
      await tester.pumpAndSettle();
      expect(VersionPickerSheet.isOpen, isTrue);

      // Second call while open
      VersionPickerSheet.show(
        context: context,
        versions: sampleVersions,
        selectedVersionIndex: 0,
        onVersionSelected: (_) {},
      );
      await tester.pumpAndSettle();

      expect(find.text('Оберіть версію'), findsOneWidget);
    });

    testWidgets('Invoking OpenVersionPickerAction pops sheet when already open',
        (tester) async {
      late BuildContext actionContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Actions(
              actions: {
                OpenVersionPickerIntent:
                    CallbackAction<OpenVersionPickerIntent>(
                  onInvoke: (intent) {
                    if (VersionPickerSheet.isOpen) {
                      Navigator.of(actionContext).maybePop();
                      return null;
                    }
                    VersionPickerSheet.show(
                      context: actionContext,
                      versions: sampleVersions,
                      selectedVersionIndex: 0,
                      onVersionSelected: (_) {},
                    );
                    return null;
                  },
                ),
              },
              child: Builder(
                builder: (innerContext) {
                  actionContext = innerContext;
                  return ElevatedButton(
                    onPressed: () {
                      Actions.invoke(
                        innerContext,
                        const OpenVersionPickerIntent(),
                      );
                    },
                    child: const Text('Toggle Picker'),
                  );
                },
              ),
            ),
          ),
        ),
      );

      // Open picker
      await tester.tap(find.text('Toggle Picker'));
      await tester.pumpAndSettle();
      expect(find.text('Оберіть версію'), findsOneWidget);
      expect(VersionPickerSheet.isOpen, isTrue);

      // Trigger action again to toggle off
      Actions.invoke(actionContext, const OpenVersionPickerIntent());
      await tester.pumpAndSettle();

      expect(find.text('Оберіть версію'), findsNothing);
      expect(VersionPickerSheet.isOpen, isFalse);
    });
  });
}
