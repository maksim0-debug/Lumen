import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/dtek_snapshot.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/services/schedule_clock.dart';

void main() {
  final now = DateTime.utc(2026, 10, 6, 12);
  Map<String, dynamic> fixture() {
    final stamp = DateTime.utc(2026, 10, 5, 21).millisecondsSinceEpoch ~/ 1000;
    return {
      'today': stamp,
      'update': '06.10.2026 10:00',
      'data': <String, dynamic>{
        '$stamp': {
          for (final g in ParserService.allGroups)
            g: {for (var h = 1; h <= 24; h++) '$h': 'yes'}
        }
      }
    };
  }

  DtekSnapshot parse(Map<String, dynamic> f, {DateTime? at}) =>
      DtekSnapshot.parse(jsonEncode(f), ParserService.allGroups,
          now: at ?? now);
  test('complete snapshot accepted; unpublished tomorrow is empty', () {
    final result = parse(fixture());
    expect(result.schedules.length, 12);
    expect(result.todayDate, '2026-10-06');
    expect(result.tomorrowDate, '2026-10-07');
    expect(result.schedules['GPV1.1']!.tomorrow.isEmpty, true);
  });
  test('any incomplete group or unknown hour rejects the entire snapshot', () {
    for (final corrupt in [
      (Map f) => (f['data']['${f['today']}'] as Map).remove('GPV6.2'),
      (Map f) => (f['data']['${f['today']}']['GPV6.2'] as Map).remove('24'),
      (Map f) => f['data']['${f['today']}']['GPV6.2']['24'] = 'invalid',
      (Map f) => f['update'] = '31.02.2026 10:00',
      (Map f) => f['update'] = '06.10.2026 23:00',
      (Map f) => f['today'] -= 86400,
    ]) {
      final f = fixture();
      corrupt(f);
      expect(() => parse(f), throwsFormatException);
    }
  });
  test('tomorrow empty placeholders allowed; partial publication rejected', () {
    final f = fixture();
    final key = '${(f['today'] as int) + 86400}';
    f['data'][key] = {for (final g in ParserService.allGroups) g: {}};
    expect(parse(f).schedules['GPV1.1']!.tomorrow.isEmpty, true);
    f['data'][key]['GPV1.1'] = f['data']['${f['today']}']['GPV1.1'];
    expect(() => parse(f), throwsFormatException);
  });
  test(
      'autumn DST uses 25-hour calendar day or fallback key; spring gap rejected',
      () {
    final f = fixture();
    final data = f['data']['${f['today']}'];
    final today = DateTime.utc(2026, 10, 24, 21).millisecondsSinceEpoch ~/ 1000;
    final next = DateTime.utc(2026, 10, 25, 22).millisecondsSinceEpoch ~/ 1000;
    f['today'] = today;
    f['update'] = '25.10.2026 10:00';
    f['data'] = {'$today': data, '$next': data};
    expect(
        parse(f, at: DateTime.utc(2026, 10, 25, 12))
            .schedules['GPV1.1']!
            .tomorrow
            .isEmpty,
        false);
    // Autumn repeated local time gracefully resolves without throwing.
    f['update'] = '25.10.2026 03:30';
    expect(
        parse(f, at: DateTime.utc(2026, 10, 25, 12))
            .schedules['GPV1.1']!
            .tomorrow
            .isEmpty,
        false);
    // Flexible format with Ukrainian 'о' is accepted
    f['update'] = '25.10.2026 о 10:00';
    expect(
        parse(f, at: DateTime.utc(2026, 10, 25, 12))
            .schedules['GPV1.1']!
            .tomorrow
            .isEmpty,
        false);
    f['update'] = '25.10.2026 10:00';
    // Fallback key (today + 86400) is also accepted if DTEK server doesn't adjust for DST
    f['data'] = {'$today': data, '${today + 86400}': data};
    expect(
        parse(f, at: DateTime.utc(2026, 10, 25, 12))
            .schedules['GPV1.1']!
            .tomorrow
            .isEmpty,
        false);
    // Non-existent spring local hour gap is rejected
    final fSpring = fixture();
    final springToday =
        DateTime.utc(2026, 3, 28, 22).millisecondsSinceEpoch ~/ 1000;
    fSpring['today'] = springToday;
    fSpring['data'] = {'$springToday': data};
    fSpring['update'] = '29.03.2026 03:30';
    expect(() => parse(fSpring, at: DateTime.utc(2026, 3, 29, 12)),
        throwsFormatException);
  });
  test(
      'extractor skips null, balances quoted braces and accepts double encoded JSON',
      () {
    final f = fixture()..['extra'] = 'a brace } and an escaped quote "';
    final literal = jsonEncode(f);
    expect(
        DtekSnapshot.extractJson(
            'DisconSchedule.fact=null; DisconSchedule.fact=$literal; other();'),
        literal);
    expect(
        DtekSnapshot.parse(
                DtekSnapshot.extractJson(
                    'DisconSchedule.fact=${jsonEncode(literal)};'),
                ParserService.allGroups,
                now: now)
            .schedules
            .length,
        12);
  });
  test(
      'Kyiv calendar does not depend on the device zone and advances across DST',
      () {
    final instant = DateTime.utc(2026, 10, 24, 22);
    expect(DtekSnapshot.notificationDate('today', now: instant), '2026-10-25');
    expect(
        DtekSnapshot.notificationDate('tomorrow', now: instant), '2026-10-26');
    final day = ScheduleClock.day(instant);
    expect(ScheduleClock.day(instant, 1).difference(day).inHours, 25);
  });
  test(
      'misdated and ambiguous tomorrow keys fail instead of silently losing a day',
      () {
    final f = fixture();
    final stamp = f['today'] as int;
    f['data']['${stamp + 90000}'] = f['data']['$stamp'];
    expect(() => parse(f), throwsFormatException);
    f['data']['${stamp + 86400}'] = f['data']['$stamp'];
    expect(() => parse(f), throwsFormatException);
  });
}
