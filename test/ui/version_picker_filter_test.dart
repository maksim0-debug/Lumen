import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/ui/dialogs/version_picker_sheet.dart';
import 'package:lumen/ui/state/home_notifier.dart';
import 'package:lumen/ui/state/schedule_version_preferences.dart';
import 'package:lumen/ui/widgets/schedule_version_filter_tile.dart';

void main() {
  late ProviderContainer container;
  late HomeNotifier home;
  var initialized = false;
  const a = '000000000000111100000000';
  const b = '000000000000000011110000';

  ScheduleVersion version(String code, int id) => ScheduleVersion(
      hash: code,
      recordId: id,
      savedAt: DateTime(2026, 10, 7, 10, id),
      outageMinutes: DailySchedule.fromEncodedString(code).totalOutageMinutes);

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    initialized = false;
  });

  void initialize({ScheduleVersionPreferences Function()? preferences}) {
    initialized = true;
    container = ProviderContainer(overrides: [
      if (preferences != null)
        scheduleVersionPreferencesProvider.overrideWith(preferences),
    ]);
    home = container.read(homeNotifierProvider.notifier);
  }

  tearDown(() {
    if (initialized) container.dispose();
    VersionPickerSheet.resetOpenState();
  });

  Future<void> open(WidgetTester tester, List<ScheduleVersion> versions,
      {int? selected, bool waitForPreferences = true}) async {
    if (!initialized) initialize();
    home.state = home.state.copyWith(
      historyVersions: versions,
      selectedVersionIndex: selected ?? versions.length - 1,
    );
    if (waitForPreferences) {
      await container
          .read(scheduleVersionPreferencesProvider.notifier)
          .ensureLoaded();
    }
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(home: Scaffold(body: Builder(builder: (context) {
        return Column(children: [
          const ScheduleVersionFilterTile(),
          ElevatedButton(
            child: const Text('Open'),
            onPressed: () => VersionPickerSheet.show(
              context: context,
              versions: versions,
              selectedVersionIndex: selected ?? versions.length - 1,
              onVersionSelected: (_) {},
              contentBuilder: (_) => Consumer(builder: (context, ref, child) {
                final state = ref.watch(homeNotifierProvider);
                final date = state.displayDate;
                return VersionPickerSheet(
                  key: ValueKey('${state.currentGroup}:$date'),
                  contextLabel: state.currentGroup,
                  versions: state.historyVersions,
                  selectedVersionIndex: state.selectedVersionIndex,
                  onVersionSelected: (index) => home.selectPublication(
                    state.historyVersions[index],
                    group: state.currentGroup,
                    date: date,
                  ),
                );
              }),
            ),
          ),
        ]);
      }))),
    ));
    await tester.tap(find.text('Open'));
    if (waitForPreferences) {
      await tester.pumpAndSettle();
    } else {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }
  }

  Finder getSheet() => find.byType(VersionPickerSheet);
  Finder switchInSheet() =>
      find.descendant(of: getSheet(), matching: find.byType(Switch));

  testWidgets(
      'default filter shows latest repeat and toggles full history in place',
      (tester) async {
    await open(tester, [version(a, 1), version(a, 2), version(b, 3)]);
    expect(find.text('Показано 2 із 3 публікацій'), findsOneWidget);
    expect(find.text('07.10 10:01'), findsNothing);
    expect(find.text('07.10 10:02'), findsOneWidget);
    await tester.tap(switchInSheet());
    await tester.pumpAndSettle();
    expect(find.text('Показано 3 із 3 публікацій'), findsOneWidget);
    expect(find.text('07.10 10:01'), findsOneWidget);
    expect(find.textContaining('Без змін для цієї групи'), findsOneWidget);
    expect(home.state.hideUnchangedScheduleVersions, isFalse);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getBool('hide_unchanged_schedule_versions'), isFalse);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
  });

  testWidgets('equal duration shifts and A-B-A all stay visible',
      (tester) async {
    await open(tester, [version(a, 1), version(b, 2), version(a, 3)]);
    expect(find.text('Показано 3 із 3 публікацій'), findsOneWidget);
    expect(find.text('(4г)'), findsNWidgets(3));
  });

  testWidgets('mouse selection returns original publication after filtering',
      (tester) async {
    await open(tester, [version(a, 1), version(a, 2), version(b, 3)]);
    await tester.tap(find.text('07.10 10:02'));
    await tester.pumpAndSettle();
    expect(getSheet(), findsNothing);
    expect(home.state.selectedVersionIndex, 1);
    expect(home.state.currentDisplaySchedule!.scheduleHash, a);
  });

  testWidgets('keyboard arrows and Enter navigate visible publications',
      (tester) async {
    await open(
        tester, [version(a, 1), version(a, 2), version(b, 3), version(b, 4)]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(getSheet(), findsNothing);
    expect(home.state.selectedVersionIndex, 1);
  });

  testWidgets(
      'enabling filter remaps selected repeat without changing the graph',
      (tester) async {
    initialize();
    await container
        .read(scheduleVersionPreferencesProvider.notifier)
        .setHideUnchanged(false);
    await open(tester, [version(a, 1), version(a, 2), version(b, 3)],
        selected: 0);
    home.selectVersion(0);
    await tester.tap(switchInSheet());
    await tester.pumpAndSettle();
    expect(home.state.selectedVersionIndex, 1);
    expect(home.state.currentDisplaySchedule!.scheduleHash, a);
    expect(find.text('07.10 10:01'), findsNothing);
    expect(find.byIcon(Icons.check), findsOneWidget);
  });

  testWidgets('one visible publication still allows showing all repeats',
      (tester) async {
    await open(tester, [version(a, 1), version(a, 2)]);
    expect(find.text('Показано 1 із 2 публікацій'), findsOneWidget);
    await tester.tap(switchInSheet());
    await tester.pumpAndSettle();
    expect(find.text('Показано 2 із 2 публікацій'), findsOneWidget);
  });

  testWidgets('stored false is awaited before any version rows are shown',
      (tester) async {
    final load = Completer<bool>();
    initialize(
        preferences: () => ScheduleVersionPreferences(read: () => load.future));
    await open(tester, [version(a, 1), version(a, 2)],
        waitForPreferences: false);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('07.10 10:01'), findsNothing);
    expect(tester.widget<Switch>(switchInSheet()).onChanged, isNull);
    load.complete(false);
    await tester.pumpAndSettle();
    expect(find.text('Показано 2 із 2 публікацій'), findsOneWidget);
    expect(find.text('07.10 10:01'), findsOneWidget);
  });

  testWidgets(
      'live insertion keeps focus on publication identity instead of old index',
      (tester) async {
    final first = version(a, 1);
    final second = version(b, 2);
    await open(tester, [first, second]);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    home.state = home.state.copyWith(
      historyVersions: [version('1' * 24, 9), first, second, version(a, 3)],
      selectedVersionIndex: 3,
    );
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(home.state.historyVersions[home.state.selectedVersionIndex].recordId,
        1);
  });

  testWidgets('open picker follows context changes and handles empty history',
      (tester) async {
    await open(tester, [version(a, 1), version(a, 2)]);
    home.state = home.state.copyWith(
      currentGroup: 'GPV1.1',
      historyVersions: [version(a, 3), version(b, 4)],
      selectedVersionIndex: 1,
    );
    await tester.pumpAndSettle();
    expect(find.text('GPV1.1'), findsOneWidget);
    expect(find.text('Показано 2 із 2 публікацій'), findsOneWidget);
    home.state =
        home.state.copyWith(historyVersions: [], selectedVersionIndex: -1);
    await tester.pumpAndSettle();
    expect(find.text('Немає збережених версій для цієї групи та дати'),
        findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(getSheet(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'Space on focused switch toggles preference without selecting or closing',
      (tester) async {
    await open(tester, [version(a, 1), version(a, 2)]);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pumpAndSettle();
    expect(getSheet(), findsOneWidget);
    expect(container.read(scheduleVersionPreferencesProvider).hideUnchanged,
        isFalse);
  });

  testWidgets('failed save shows an error and leaves rows and switch unchanged',
      (tester) async {
    initialize(
        preferences: () => ScheduleVersionPreferences(
              read: () async => true,
              write: (_) async => throw StateError('Write failed'),
            ));
    await open(tester, [version(a, 1), version(a, 2)]);
    await tester.tap(switchInSheet());
    await tester.pumpAndSettle();
    expect(tester.widget<Switch>(switchInSheet()).value, isTrue);
    expect(find.text('Показано 1 із 2 публікацій'), findsOneWidget);
    expect(find.text('Не вдалося зберегти налаштування. Спробуйте ще раз.'),
        findsOneWidget);
  });

  testWidgets('small mobile viewport fits filter, rows and keyboard hints',
      (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await open(tester, [version(a, 1), version(b, 2), version(a, 3)]);
    expect(switchInSheet(), findsOneWidget);
    expect(find.text('Показано 3 із 3 публікацій'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
