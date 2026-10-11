import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/emergency_status.dart';
import 'package:lumen/ui/widgets/home/displayed_emergency_acknowledgment.dart';
import 'package:lumen/ui/widgets/home/emergency_alert_banner.dart';

void main() {
  late ValueNotifier<EmergencyStatus> displayed;
  late List<int> acknowledged;
  late GlobalKey<NavigatorState> navigator;
  late int now;
  var windowVisible = true;

  EmergencyStatus status(int version,
          {bool active = true, bool stale = false}) =>
      EmergencyStatus(
        active: active,
        changedAt: now + version,
        observedAt: stale
            ? now - const Duration(hours: 1).inMilliseconds
            : now + version,
        seenAt: now + version,
      );

  setUp(() {
    now = DateTime.now().millisecondsSinceEpoch;
    displayed = ValueNotifier(status(1));
    acknowledged = [];
    navigator = GlobalKey<NavigatorState>();
    windowVisible = true;
  });
  tearDown(() => displayed.dispose());

  Widget app(
          {Future<bool> Function(EmergencyStatus)? acknowledge,
          Future<bool> Function()? visibility}) =>
      MaterialApp(
        navigatorKey: navigator,
        home: ValueListenableBuilder<EmergencyStatus>(
          valueListenable: displayed,
          builder: (context, status, _) => DisplayedEmergencyAcknowledgment(
            status: status,
            isWindowVisible: visibility ?? (() async => windowVisible),
            onAcknowledge: acknowledge ??
                (status) async {
                  acknowledged.add(status.changedAt);
                  return true;
                },
            child: Scaffold(body: Text('${status.changedAt}')),
          ),
        ),
      );

  testWidgets('visible stream update is acknowledged after its rendered frame',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(acknowledged, [status(1).changedAt]);
    displayed.value = status(2);
    expect(acknowledged, hasLength(1));
    await tester.pump();
    await tester.pump();
    expect(acknowledged, [status(1).changedAt, status(2).changedAt]);
    displayed.value = status(2);
    await tester.pump();
    expect(acknowledged, hasLength(2));
  });

  testWidgets('hidden lifecycle waits until resume and a visible frame',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.pumpWidget(app());
    await tester.pump();
    expect(acknowledged, isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(acknowledged, isEmpty);
    await tester.pump();
    await tester.pump();
    expect(acknowledged, [status(1).changedAt]);
  });

  testWidgets('native hidden window cannot acknowledge even while resumed',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    windowVisible = false;
    await tester.pumpWidget(app());
    await tester.pump();
    displayed.value = status(2);
    await tester.pump();
    expect(acknowledged, isEmpty);
    windowVisible = true;
    displayed.value = status(2);
    await tester.pump();
    await tester.pump();
    expect(acknowledged, [status(2).changedAt]);
  });

  testWidgets('covered route waits until the banner becomes visible',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(app());
    navigator.currentState!.push(MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Settings'))));
    await tester.pumpAndSettle();
    displayed.value = status(2);
    await tester.pump();
    expect(acknowledged, [status(1).changedAt]);
    navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(acknowledged, [status(1).changedAt, status(2).changedAt]);
  });

  testWidgets('stale and cancelled banners do not acknowledge a transition',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    displayed.value = status(1, stale: true);
    await tester.pumpWidget(app());
    await tester.pump();
    displayed.value = status(2, active: false);
    await tester.pump();
    expect(acknowledged, isEmpty);
  });

  testWidgets('rejected acknowledgment and write failure remain retryable',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var attempts = 0;
    await tester.pumpWidget(app(acknowledge: (status) async {
      attempts++;
      if (attempts == 1) return false;
      if (attempts == 2) throw StateError('Database unavailable');
      acknowledged.add(status.changedAt);
      return true;
    }));
    await tester.pump();
    displayed.value = status(1);
    await tester.pump();
    await tester.pump();
    expect(acknowledged, isEmpty);
    displayed.value = status(1);
    await tester.pump();
    await tester.pump();
    expect(attempts, 3);
    expect(acknowledged, [status(1).changedAt]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('visibility result for an obsolete frame cannot acknowledge it',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final check = Completer<bool>();
    var checks = 0;
    await tester.pumpWidget(app(visibility: () {
      if (++checks == 1) return check.future;
      return Future.value(true);
    }));
    displayed.value = status(2);
    await tester.pump();
    await tester.pump();
    check.complete(true);
    await tester.pump();
    expect(acknowledged, [status(2).changedAt]);
  });

  testWidgets('disposed banner cannot acknowledge after a visibility check',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final check = Completer<bool>();
    await tester.pumpWidget(app(visibility: () => check.future));
    await tester.pumpWidget(const SizedBox.shrink());
    check.complete(true);
    await tester.pump();
    expect(acknowledged, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'offscreen banner waits until scrolling renders it in the viewport',
      (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final scroll = ScrollController();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
          body: SingleChildScrollView(
        controller: scroll,
        child: Column(children: [
          const SizedBox(height: 1000),
          DisplayedEmergencyAcknowledgment(
            status: status(1),
            isWindowVisible: () async => true,
            onAcknowledge: (status) async {
              acknowledged.add(status.changedAt);
              return true;
            },
            child: const SizedBox(
                height: 60, width: 200, child: Text('Emergency banner')),
          ),
          const SizedBox(height: 1000),
        ]),
      )),
    ));
    await tester.pump();
    expect(acknowledged, isEmpty);
    scroll.jumpTo(950);
    await tester.pump();
    await tester.pump();
    expect(acknowledged, [status(1).changedAt]);
    await tester.pumpWidget(const SizedBox.shrink());
    scroll.dispose();
  });

  for (final scale in [1.3, 2.0]) {
    testWidgets('text scale $scale keeps a clipped banner unacknowledged',
        (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final scroll = ScrollController();
      final viewportHeight = ValueNotifier<double>(400);
      // Measure without writing a receipt, then clip two pixels of the banner.
      windowVisible = false;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: MediaQuery(
          data: MediaQueryData(textScaler: TextScaler.linear(scale)),
          child: ValueListenableBuilder<double>(
            valueListenable: viewportHeight,
            builder: (context, height, _) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                height: height,
                width: 250,
                child: SingleChildScrollView(
                  controller: scroll,
                  child: Column(children: [
                    const SizedBox(height: 10),
                    DisplayedEmergencyAcknowledgment(
                      status: status(1),
                      isWindowVisible: () async => windowVisible,
                      onAcknowledge: (status) async {
                        acknowledged.add(status.changedAt);
                        return true;
                      },
                      child: const EmergencyAlertBanner(
                          isActive: true,
                          noticeText: 'Введені екстрені відключення.'),
                    ),
                    const SizedBox(height: 100),
                  ]),
                ),
              ),
            ),
          ),
        )),
      ));
      await tester.pump();
      final bannerHeight =
          tester.getSize(find.byType(EmergencyAlertBanner)).height;
      viewportHeight.value = bannerHeight + 8;
      windowVisible = true;
      await tester.pump();
      await tester.pump();
      expect(acknowledged, isEmpty,
          reason: 'Partial visibility does not establish a complete display');
      expect(tester.takeException(), isNull);
      scroll.jumpTo(2);
      await tester.pump();
      await tester.pump();
      expect(acknowledged, [status(1).changedAt]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      scroll.dispose();
      viewportHeight.dispose();
    });
  }
}
