import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/analytics_models.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/ui/widgets/schedule_deviation_section.dart';
import 'package:shared_preferences/shared_preferences.dart';

ScheduleDeviationStats result(
  ScheduleDeviationPeriod period, {
  double deltaMinutes = 40,
  int plannedMinutes = 720,
  int validDays = 1,
  Map<LightBalanceExclusion, int> exclusions = const {},
  SwitchLag lag = const SwitchLag(
      avgOnLagMinutes: -18,
      avgOffLagMinutes: 22,
      sampleCount: 2,
      onSampleCount: 1,
      offSampleCount: 1),
}) =>
    ScheduleDeviationStats(
        balance: LightBalanceStats(
            period: period,
            start: ScheduleClock.calendar(2026, 10, 6),
            end: ScheduleClock.calendar(2026, 10, 7, 14, 20),
            plannedOnSeconds: plannedMinutes * 60,
            actualOnSeconds: ((plannedMinutes + deltaMinutes) * 60).round(),
            validDays: validDays,
            exclusions: exclusions),
        lag: lag);

void main() {
  setUp(
      () => SharedPreferences.setMockInitialValues({'enable_logging': false}));

  Widget app(ScheduleDeviationLoader load,
          {String group = 'GPV2.1',
          int revision = 0,
          double scale = 1,
          ScheduleDeviationPeriod initialPeriod =
              ScheduleDeviationPeriod.yesterday,
          ValueChanged<ScheduleDeviationPeriod>? onPeriodChanged,
          Brightness brightness = Brightness.dark}) =>
      MaterialApp(
          theme: ThemeData(brightness: brightness),
          home: MediaQuery(
              data: MediaQueryData(textScaler: TextScaler.linear(scale)),
              child: Scaffold(
                  body: SingleChildScrollView(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: ScheduleDeviationSection(
                              groupKey: group,
                              revision: revision,
                              initialPeriod: initialPeriod,
                              onPeriodChanged: onPeriodChanged,
                              load: load))))));

  Future<void> details(WidgetTester tester) async {
    await tester.ensureVisible(find.text('Деталі розрахунку'));
    await tester.tap(find.text('Деталі розрахунку'));
    await tester.pumpAndSettle();
  }

  testWidgets(
      'selection can be restored after the containing analytics tab remounts',
      (tester) async {
    var selected = ScheduleDeviationPeriod.yesterday;
    final calls = <ScheduleDeviationPeriod>[];
    Future<ScheduleDeviationStats> load(
        ScheduleDeviationPeriod period, String group) async {
      calls.add(period);
      return result(period);
    }

    await tester
        .pumpWidget(app(load, onPeriodChanged: (period) => selected = period));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тиждень'));
    await tester.pumpAndSettle();
    expect(selected, ScheduleDeviationPeriod.week);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(app(load, initialPeriod: selected));
    await tester.pumpAndSettle();
    expect(calls, [
      ScheduleDeviationPeriod.yesterday,
      ScheduleDeviationPeriod.week,
      ScheduleDeviationPeriod.week
    ]);
  });

  testWidgets(
      'subminute differences and percentages never round to an exact zero',
      (tester) async {
    await tester.pumpWidget(
        app((period, group) async => result(period, deltaMinutes: 0.5)));
    await tester.pumpAndSettle();
    expect(find.text('+менш ніж 1 хв'), findsOneWidget);
    expect(find.text('+<0,1%'), findsOneWidget);
    expect(find.text('Різниця становить менше хвилини.'), findsOneWidget);
    await tester.tap(find.text('Тиждень'));
    await tester.pumpAndSettle();
    expect(find.text('Середня різниця становить менше хвилини на день.'),
        findsOneWidget);
  });

  testWidgets(
      'small actual duration and observed zero lag have distinct labels',
      (tester) async {
    await tester.pumpWidget(app((period, group) async => result(period,
        deltaMinutes: 0.5,
        plannedMinutes: 0,
        lag: const SwitchLag(
            avgOnLagMinutes: 0,
            avgOffLagMinutes: 0,
            sampleCount: 2,
            onSampleCount: 1,
            offSampleCount: 1))));
    await tester.pumpAndSettle();
    expect(find.text('У середньому за графіком'), findsNWidgets(2));
    await details(tester);
    expect(find.text('Менше 1 хв'), findsOneWidget);
  });

  testWidgets(
      'defaults to yesterday and shows balance, percent and separate lags',
      (tester) async {
    final calls = <ScheduleDeviationPeriod>[];
    await tester.pumpWidget(app((period, group) async {
      calls.add(period);
      return result(period);
    }));
    await tester.pumpAndSettle();
    expect(calls, [ScheduleDeviationPeriod.yesterday]);
    expect(find.text('+40 хв'), findsOneWidget);
    expect(find.text('+5,6%'), findsOneWidget);
    expect(find.text('На 18 хв раніше'), findsOneWidget);
    expect(find.text('На 22 хв пізніше'), findsOneWidget);
    await details(tester);
    expect(find.text('Світла за графіком'), findsOneWidget);
    expect(find.textContaining('Записи датчика ↔ Група 2.1'), findsOneWidget);
  });

  testWidgets('week uses eligible-day average and exposes excluded-day reasons',
      (tester) async {
    await tester.pumpWidget(app((period, group) async => result(period,
        deltaMinutes: 200,
        validDays: 5,
        plannedMinutes: 3600,
        exclusions: {LightBalanceExclusion.missingSchedule: 2})));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Тиждень'));
    await tester.pumpAndSettle();
    expect(find.text('+40 хв / день'), findsOneWidget);
    expect(find.textContaining('5 із 7 завершених днів'), findsOneWidget);
    expect(find.text('Виключено днів: 2'), findsOneWidget);
    await details(tester);
    expect(find.text('Днів без графіка'), findsOneWidget);
    expect(find.text('+200 хв'), findsOneWidget);
  });

  testWidgets('negative balance is described as less light', (tester) async {
    await tester.pumpWidget(
        app((period, group) async => result(period, deltaMinutes: -40)));
    await tester.pumpAndSettle();
    expect(find.text('−40 хв'), findsOneWidget);
    expect(find.text('−5,6%'), findsOneWidget);
    expect(find.text('Світла менше за графік'), findsOneWidget);
  });

  testWidgets('zero balance does not claim that switching times matched',
      (tester) async {
    await tester.pumpWidget(
        app((period, group) async => result(period, deltaMinutes: 0)));
    await tester.pumpAndSettle();
    expect(find.text('0 хв'), findsOneWidget);
    expect(find.text('Сумарний час зі світлом збігся з графіком.'),
        findsOneWidget);
    expect(find.text('На 18 хв раніше'), findsOneWidget);
  });

  testWidgets('missing percentage and lag samples do not hide valid balance',
      (tester) async {
    await tester.pumpWidget(app((period, group) async => result(period,
        plannedMinutes: 0,
        lag: const SwitchLag(
            avgOnLagMinutes: 0, avgOffLagMinutes: 0, sampleCount: 0))));
    await tester.pumpAndSettle();
    expect(find.text('+40 хв'), findsOneWidget);
    expect(find.byKey(const ValueKey('light-balance-percent')), findsNothing);
    expect(find.text('Немає спостережень'), findsNWidgets(2));
    await details(tester);
    expect(find.textContaining('Відсоток не визначено'), findsOneWidget);
  });

  testWidgets(
      'one-sided lag samples never imply an observed zero on the missing side',
      (tester) async {
    await tester.pumpWidget(app((period, group) async => result(period,
        lag: const SwitchLag(
            avgOnLagMinutes: 0,
            avgOffLagMinutes: -10,
            sampleCount: 1,
            offSampleCount: 1))));
    await tester.pumpAndSettle();
    expect(find.text('Немає спостережень'), findsOneWidget);
    expect(find.text('На 10 хв раніше'), findsOneWidget);
    expect(find.text('У середньому за графіком'), findsNothing);
  });

  testWidgets('missing balance does not hide independently available lag',
      (tester) async {
    await tester.pumpWidget(app((period, group) async => result(period,
        validDays: 0,
        exclusions: {LightBalanceExclusion.incompleteActual: 1})));
    await tester.pumpAndSettle();
    expect(find.text('Недостатньо даних для порівняння'), findsOneWidget);
    expect(find.text('На 18 хв раніше'), findsOneWidget);
    expect(find.byKey(const ValueKey('light-balance-value')), findsNothing);
  });

  testWidgets('today explicitly labels the observed cutoff', (tester) async {
    await tester.pumpWidget(app((period, group) async => result(period)));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Сьогодні'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Від 00:00 до 14:20'), findsOneWidget);
    expect(find.textContaining('Сьогодні світло було'), findsOneWidget);
  });

  testWidgets(
      'out-of-order period responses cannot overwrite the current selection',
      (tester) async {
    final requests =
        <ScheduleDeviationPeriod, Completer<ScheduleDeviationStats>>{};
    await tester.pumpWidget(
        app((period, group) => (requests[period] = Completer()).future));
    await tester.tap(find.text('Тиждень'));
    await tester.pump();
    requests[ScheduleDeviationPeriod.week]!.complete(
        result(ScheduleDeviationPeriod.week, deltaMinutes: 700, validDays: 7));
    await tester.pumpAndSettle();
    expect(find.text('+100 хв / день'), findsOneWidget);
    requests[ScheduleDeviationPeriod.yesterday]!
        .complete(result(ScheduleDeviationPeriod.yesterday));
    await tester.pumpAndSettle();
    expect(find.text('+100 хв / день'), findsOneWidget);
    expect(find.text('+40 хв'), findsNothing);
  });

  testWidgets(
      'group changes and refreshes reload while preserving the selected period',
      (tester) async {
    final calls = <String>[];
    final pending = Completer<ScheduleDeviationStats>();
    Future<ScheduleDeviationStats> load(
        ScheduleDeviationPeriod period, String group) {
      calls.add('$group:${period.name}');
      if (calls.length == 1) return pending.future;
      return Future.value(result(period, deltaMinutes: -20));
    }

    await tester.pumpWidget(app(load));
    await tester.pumpWidget(app(load, group: 'GPV3.1'));
    await tester.pumpAndSettle();
    pending.complete(result(ScheduleDeviationPeriod.yesterday));
    await tester.pumpAndSettle();
    expect(find.text('−20 хв'), findsOneWidget);
    await tester.tap(find.text('Місяць'));
    await tester.pumpAndSettle();
    await tester.pumpWidget(app(load, group: 'GPV3.1', revision: 1));
    await tester.pumpAndSettle();
    expect(calls, [
      'GPV2.1:yesterday',
      'GPV3.1:yesterday',
      'GPV3.1:month',
      'GPV3.1:month'
    ]);
  });

  testWidgets(
      'failures offer a working retry and a disposed section ignores completion',
      (tester) async {
    int attempts = 0;
    await tester.pumpWidget(app((period, group) async {
      if (++attempts == 1) throw StateError('Read failed');
      return result(period);
    }));
    await tester.pumpAndSettle();
    expect(find.text('Не вдалося завантажити порівняння.'), findsOneWidget);
    await tester.tap(find.text('Повторити'));
    await tester.pumpAndSettle();
    expect(find.text('+40 хв'), findsOneWidget);
    final pending = Completer<ScheduleDeviationStats>();
    await tester
        .pumpWidget(app((period, group) => pending.future, revision: 2));
    await tester.pumpWidget(const SizedBox.shrink());
    pending.complete(result(ScheduleDeviationPeriod.yesterday));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  for (final width in [320.0, 375.0, 886.0]) {
    for (final brightness in Brightness.values) {
      testWidgets(
          'fits $width px in ${brightness.name} mode with enlarged text',
          (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(app((period, group) async => result(period),
            scale: 1.5, brightness: brightness));
        await tester.pumpAndSettle();
        await details(tester);
        expect(tester.takeException(), isNull);
        expect(
            tester
                .getRect(find.byKey(const ValueKey('light-balance-value')))
                .right,
            lessThanOrEqualTo(width));
      });
    }
  }

  for (final brightness in Brightness.values) {
    testWidgets(
        'fits a narrow screen with double-size accessible text in ${brightness.name}',
        (tester) async {
      tester.view.physicalSize = const Size(320, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(app((period, group) async => result(period),
          scale: 2, brightness: brightness));
      await tester.pumpAndSettle();
      await details(tester);
      expect(tester.takeException(), isNull);
    });
  }
}
