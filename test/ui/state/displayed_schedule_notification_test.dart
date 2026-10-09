import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/data_source_mode.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/ui/state/home_notifier.dart';

void main() {
  final now = ScheduleClock.calendar(2026, 10, 9, 23, 59);
  final today = DailySchedule.fromEncodedString('111111000000000000000000');
  final tomorrow = DailySchedule.fromEncodedString('111111110000000000000000');
  HomeState displayed({String source = '09.10.2026 01:22'}) => HomeState(
        isLoading: false,
        currentGroup: 'GPV2.1',
        allSchedules: {
          'GPV2.1': FullSchedule(
              today: today, tomorrow: tomorrow, lastUpdatedSource: source),
        },
        currentDisplaySchedule: today,
      );

  test('captures the rendered publication before state changes or midnight',
      () {
    final rendered = displayed();
    final event = HomeNotifier.scheduleEventForDisplayedState(rendered, now)!;
    final newer = displayed(source: '09.10.2026 23:59');
    expect(HomeNotifier.scheduleEventForDisplayedState(newer, now)!.id,
        isNot(event.id));
    expect(event.targetDate, '2026-10-09');
    expect(event.hash, today.scheduleHash);
    expect(event.sourceVersion,
        ScheduleClock.calendar(2026, 10, 9, 1, 22).millisecondsSinceEpoch);
  });

  test('only the displayed tomorrow group and date are acknowledged', () {
    final state = displayed().copyWith(
        viewMode: ScheduleViewMode.tomorrow, currentDisplaySchedule: tomorrow);
    final event = HomeNotifier.scheduleEventForDisplayedState(state, now)!;
    expect(event.group, 'GPV2.1');
    expect(event.dayType, 'tomorrow');
    expect(event.targetDate, '2026-10-10');
    expect(event.hash, tomorrow.scheduleHash);
  });

  test(
      'cache, loading, real mode, history and unrendered hashes do not acknowledge',
      () {
    final state = displayed();
    for (final hidden in [
      state.copyWith(isCachedData: true),
      state.copyWith(isLoading: true),
      state.copyWith(dataSourceMode: DataSourceMode.real),
      state.copyWith(viewMode: ScheduleViewMode.history),
      state.copyWith(viewMode: ScheduleViewMode.yesterday),
      state.copyWith(currentDisplaySchedule: tomorrow),
      state.copyWith(currentGroup: 'GPV1.1'),
      state.copyWith(viewMode: ScheduleViewMode.tomorrow),
    ]) {
      expect(HomeNotifier.scheduleEventForDisplayedState(hidden, now), isNull);
    }
  });

  test(
      'manual publication and empty schedules never advance the DTEK watermark',
      () {
    expect(
        HomeNotifier.scheduleEventForDisplayedState(
            displayed(source: 'manual'), now),
        isNull);
    expect(
        HomeNotifier.scheduleEventForDisplayedState(
            const HomeState(isLoading: false), now),
        isNull);
  });
}
