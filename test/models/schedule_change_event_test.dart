import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/schedule_change_event.dart';
import 'package:lumen/services/schedule_clock.dart';

void main() {
  ScheduleChangeEvent event(String hash, String dayType) => ScheduleChangeEvent(
        group: 'GPV2.1',
        targetDate: dayType == 'today' ? '2026-10-09' : '2026-10-10',
        sourceVersion:
            ScheduleClock.calendar(2026, 10, 9, 12).millisecondsSinceEpoch,
        hash: hash,
        dayType: dayType,
      );

  const durations = <int, String>{
    0: 'Відключень не заплановано 🎉',
    30: 'Заплановано відключень: 0.5 год. ⚡',
    60: 'Заплановано відключень: 1 год. ⚡',
    90: 'Заплановано відключень: 1.5 год. ⚡',
    180: 'Заплановано відключень: 3 год. ⚡',
    240: 'Заплановано відключень: 4 год. ⚡',
    1440: 'Заплановано відключень: 24 год. ⚡',
  };

  for (final dayType in ['today', 'tomorrow']) {
    for (final previousHash in <String?>[null, '9' * 24]) {
      for (final duration in durations.entries) {
        test(
            '$dayType initial publication of ${duration.key} minutes with ${previousHash == null ? 'no baseline' : 'withdrawn baseline'} formats outage hours',
            () {
          final hours = duration.key ~/ 60;
          final halfHour = duration.key % 60 == 0 ? '' : '2';
          final hash = ('1' * hours + halfHour).padRight(24, '0');
          final publication = event(hash, dayType);
          expect(publication.schedule.totalOutageMinutes, duration.key);
          expect(publication.body(previousHash), duration.value);
        });
      }
    }
  }

  test('half-hour in the second part of an hour has the same duration text',
      () {
    expect(event('3${'0' * 23}', 'today').body(null), durations[30]);
  });

  test('known schedules preserve delta and time-shift messages', () {
    final six = '111111${'0' * 18}';
    final eight = '11111111${'0' * 16}';
    final shiftedSix = '0111111${'0' * 17}';
    expect(event(eight, 'today').body(six), 'Світла стало МЕНШЕ на 2 год. 😔');
    expect(event(six, 'today').body(eight), 'Світла стало БІЛЬШЕ на 2 год. 🎉');
    expect(event(shiftedSix, 'today').body(six),
        'Змінився час відключень на сьогодні ⚡');
    expect(event(shiftedSix, 'tomorrow').body(six),
        'Змінився час відключень на завтра ⚡');
  });
}
