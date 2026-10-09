import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_change_event.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/ui/widgets/home/displayed_schedule_acknowledgment.dart';

void main() {
  ScheduleChangeEvent publication(int hour) => ScheduleChangeEvent(
        group: 'GPV2.1',
        targetDate: '2026-10-09',
        dayType: 'today',
        sourceVersion:
            ScheduleClock.calendar(2026, 10, 9, hour).millisecondsSinceEpoch,
        hash: '${'1' * hour}${'0' * (24 - hour)}',
      );
  late ValueNotifier<ScheduleChangeEvent?> displayed;
  late List<ScheduleChangeEvent> acknowledged;
  late GlobalKey<NavigatorState> navigator;
  setUp(() {
    displayed = ValueNotifier(publication(1));
    acknowledged = [];
    navigator = GlobalKey<NavigatorState>();
  });
  tearDown(() => displayed.dispose());

  Widget app({Future<void> Function(ScheduleChangeEvent)? acknowledge}) =>
      MaterialApp(
        navigatorKey: navigator,
        home: ValueListenableBuilder<ScheduleChangeEvent?>(
          valueListenable: displayed,
          builder: (context, event, _) => DisplayedScheduleAcknowledgment(
            event: event,
            onAcknowledge: acknowledge ??
                (event) async {
                  acknowledged.add(event);
                },
            child: Scaffold(body: Text(event?.id ?? 'No current schedule')),
          ),
        ),
      );

  testWidgets(
      'acknowledges after rendering and ignores rebuilds of the same publication',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(app(acknowledge: (event) async {
      expect(find.text(event.id), findsOneWidget);
      acknowledged.add(event);
    }));
    expect(acknowledged.map((event) => event.id), [publication(1).id]);
    displayed.value = publication(1);
    await tester.pump();
    await tester.pump();
    expect(acknowledged, hasLength(1));
    displayed.value = publication(2);
    expect(acknowledged, hasLength(1));
    await tester.pump();
    expect(acknowledged.map((event) => event.id),
        [publication(1).id, publication(2).id]);
  });

  testWidgets('paused application acknowledges only after resume and a frame',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(app());
    expect(acknowledged, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(acknowledged, isEmpty);
    await tester.pump();
    expect(acknowledged.map((event) => event.id), [publication(1).id]);
  });

  testWidgets(
      'publication under another route is acknowledged only when it becomes visible',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(app());
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Settings'))));
    await tester.pumpAndSettle();
    displayed.value = publication(2);
    await tester.pump();
    expect(acknowledged, hasLength(1));
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(acknowledged.map((event) => event.id),
        [publication(1).id, publication(2).id]);
  });

  testWidgets('only the final publication rendered in a frame is acknowledged',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(app());
    displayed.value = publication(2);
    displayed.value = publication(3);
    await tester.pump();
    expect(acknowledged.map((event) => event.id),
        [publication(1).id, publication(3).id]);
    displayed.value = null;
    await tester.pump();
    expect(acknowledged, hasLength(2));
  });

  testWidgets('failed acknowledgment is retryable on a later rebuild',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var attempts = 0;
    await tester.pumpWidget(app(acknowledge: (event) async {
      attempts++;
      if (attempts == 1) throw StateError('Database unavailable');
      acknowledged.add(event);
    }));
    await tester.pump();
    expect(acknowledged, isEmpty);
    displayed.value = publication(1);
    await tester.pump();
    expect(attempts, 2);
    expect(acknowledged.single.id, publication(1).id);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'late failure of an older acknowledgment cannot clear the newer one',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final oldAttempt = Completer<void>();
    await tester.pumpWidget(app(acknowledge: (event) async {
      acknowledged.add(event);
      if (event.id == publication(1).id) await oldAttempt.future;
    }));
    displayed.value = publication(2);
    await tester.pump();
    oldAttempt.completeError(StateError('Late database failure'));
    await tester.pump();
    displayed.value = publication(2);
    await tester.pump();
    expect(acknowledged.map((event) => event.id),
        [publication(1).id, publication(2).id]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('disposed screen cannot acknowledge on a later app resume',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pumpWidget(app());
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(acknowledged, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
