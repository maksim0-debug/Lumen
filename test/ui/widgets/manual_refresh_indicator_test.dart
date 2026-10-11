import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/ui/widgets/home/manual_refresh_indicator.dart';

void main() {
  Future<void> mount(WidgetTester tester,
          {Future<void>? operation,
          required Future<void> Function() onRefresh}) =>
      tester.pumpWidget(MaterialApp(
          home: Scaffold(
              body: ManualRefreshIndicator(
        operation: operation,
        onRefresh: onRefresh,
        child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            children: const [SizedBox(height: 1000, child: Text('Graph'))]),
      ))));

  for (final fail in [false, true]) {
    testWidgets(
        'external operation shows and dismisses spinner (failure=$fail)',
        (tester) async {
      final completion = Completer<void>();
      var requests = 0;
      await mount(tester, operation: completion.future, onRefresh: () async {
        requests++;
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.byType(RefreshProgressIndicator), findsOneWidget);
      expect(find.text('Graph'), findsOneWidget);
      expect(requests, 0);
      if (fail) {
        completion.completeError(TimeoutException('source timeout'));
      } else {
        completion.complete();
      }
      await tester.pumpAndSettle();
      expect(find.byType(RefreshProgressIndicator), findsNothing);
      expect(requests, 0);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
      'warm operation starts spinner and fast completion does not restart request',
      (tester) async {
    var requests = 0;
    final completion = Completer<void>();
    Future<void> refresh() async {
      requests++;
    }

    await mount(tester, onRefresh: refresh);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    await mount(tester, operation: completion.future, onRefresh: refresh);
    completion.complete();
    await mount(tester, onRefresh: refresh);
    await tester.pumpAndSettle();
    expect(requests, 0);
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('pull gesture calls refresh once and awaits completion',
      (tester) async {
    var requests = 0;
    final completion = Completer<void>();
    await mount(tester, onRefresh: () {
      requests++;
      return completion.future;
    });
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(requests, 1);
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    completion.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('replacement operation keeps spinner until both complete',
      (tester) async {
    final first = Completer<void>();
    final second = Completer<void>();
    await mount(tester, operation: first.future, onRefresh: () async {});
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await mount(tester, operation: second.future, onRefresh: () async {});
    first.complete();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    second.complete();
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
  });

  testWidgets('dispose during refresh tolerates later completion',
      (tester) async {
    final completion = Completer<void>();
    await mount(tester, operation: completion.future, onRefresh: () async {});
    await tester.pumpWidget(const SizedBox());
    completion.complete();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('failed pull callback also dismisses spinner', (tester) async {
    final completion = Completer<void>();
    await mount(tester, onRefresh: () => completion.future);
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(RefreshProgressIndicator), findsOneWidget);
    completion.completeError(TimeoutException('source timeout'));
    await tester.pumpAndSettle();
    expect(find.byType(RefreshProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
      'first pull after operation clears during entrance performs request',
      (tester) async {
    var requests = 0;
    final completion = Completer<void>();
    Future<void> refresh() async {
      requests++;
    }

    await mount(tester, operation: completion.future, onRefresh: refresh);
    completion.complete();
    await mount(tester, onRefresh: refresh);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(requests, 1);
  });

  testWidgets(
      'external operation during held gesture does not swallow next pull',
      (tester) async {
    var requests = 0;
    final completion = Completer<void>();
    Future<void> refresh() async {
      requests++;
    }

    await mount(tester, onRefresh: refresh);
    final gesture =
        await tester.startGesture(tester.getCenter(find.byType(ListView)));
    await gesture.moveBy(const Offset(0, 50));
    await tester.pump();
    await mount(tester, operation: completion.future, onRefresh: refresh);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    completion.complete();
    await mount(tester, onRefresh: refresh);
    await gesture.up();
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 400));
    await tester.pumpAndSettle();
    expect(requests, 1);
  });
}
