import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/visible_schedule_ticker.dart';

void main() {
  testWidgets('Android minute work stops when hidden and restarts after resume',
      (tester) async {
    var now = DateTime(2026, 10, 9, 19, 14, 59);
    final ticks = <DateTime>[];
    var resumes = 0;
    final ticker = VisibleScheduleTicker(
        foregroundOnly: true,
        now: () => now,
        onMinute: ticks.add,
        onResume: () => resumes++);
    ticker.lifecycleChanged(AppLifecycleState.paused);
    now = DateTime(2026, 10, 9, 19, 15);
    await tester.pump(const Duration(minutes: 30));
    expect(ticks, isEmpty);
    ticker.lifecycleChanged(AppLifecycleState.resumed);
    expect(resumes, 1);
    now = DateTime(2026, 10, 9, 19, 16);
    await tester.pump(const Duration(seconds: 61));
    expect(ticks, [now]);
    ticker.dispose();
    await tester.pump(const Duration(hours: 1));
    expect(ticks, hasLength(1));
  });

  testWidgets('Permission dialog pauses ticks without forcing a data refresh',
      (tester) async {
    var resumes = 0;
    final ticker = VisibleScheduleTicker(
        foregroundOnly: true,
        now: () => DateTime(2026, 10, 9, 19, 15),
        onMinute: (_) => fail('inactive UI tick'),
        onResume: () => resumes++);
    ticker.lifecycleChanged(AppLifecycleState.inactive);
    await tester.pump(const Duration(minutes: 2));
    ticker.lifecycleChanged(AppLifecycleState.resumed);
    expect(resumes, 0);
    ticker.dispose();
  });

  testWidgets('Desktop minute work continues when the window is hidden',
      (tester) async {
    var count = 0;
    final ticker = VisibleScheduleTicker(
        foregroundOnly: false,
        now: () => DateTime(2026, 10, 9, 19, 15),
        onMinute: (_) => count++,
        onResume: () => fail('Android resume on desktop'));
    ticker.lifecycleChanged(AppLifecycleState.hidden);
    await tester.pump(const Duration(seconds: 61));
    expect(count, 1);
    ticker.dispose();
  });

  testWidgets('An initially hidden Android screen creates no minute timer',
      (tester) async {
    final ticker = VisibleScheduleTicker(
        foregroundOnly: true,
        initialState: AppLifecycleState.paused,
        now: () => DateTime(2026, 10, 9),
        onMinute: (_) => fail('hidden UI tick'),
        onResume: () {});
    await tester.pump(const Duration(hours: 1));
    ticker.dispose();
  });
}
