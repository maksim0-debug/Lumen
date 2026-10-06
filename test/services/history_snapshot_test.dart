import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/schedule_clock.dart';

void main() {
  late Database db;
  late HistoryService history;
  FullSchedule schedule(String code) => FullSchedule(
      today: DailySchedule.fromEncodedString(code),
      tomorrow: DailySchedule.empty(),
      lastUpdatedSource: 'test');
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
        'CREATE TABLE schedule_history (id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'group_key TEXT, target_date TEXT, schedule_code TEXT, dtek_updated_at TEXT)');
    history = HistoryService.forTesting(db);
  });
  tearDown(() async => db.close());
  Future<void> save(Map<String, FullSchedule> data, String update) =>
      history.persistSnapshot(
          schedules: data,
          todayDate: '2026-10-06',
          tomorrowDate: '2026-10-07',
          dtekUpdatedAt: update);
  test('identical snapshots do not create duplicate rows', () async {
    final data = {'GPV1.1': schedule('0' * 24), 'GPV1.2': schedule('1' * 24)};
    await save(data, '06.10.2026 10:00');
    await save(data, '06.10.2026 10:00');
    expect((await db.query('schedule_history')).length, 2);
  });
  test('later-group conflict rolls back all earlier writes in the batch',
      () async {
    await save({'GPV1.2': schedule('0' * 24)}, '06.10.2026 11:00');
    await expectLater(
        save({'GPV1.1': schedule('0' * 24), 'GPV1.2': schedule('1' * 24)},
            '06.10.2026 11:00'),
        throwsFormatException);
    final rows = await db.query('schedule_history');
    expect(rows.length, 1);
    expect(rows.first['group_key'], 'GPV1.2');
    expect(rows.first['schedule_code'], '0' * 24);
  });
  test('older source versions cannot overwrite latest history', () async {
    await save({'GPV1.1': schedule('0' * 24)}, '06.10.2026 11:00');
    await expectLater(save({'GPV1.1': schedule('1' * 24)}, '06.10.2026 10:00'),
        throwsFormatException);
    expect((await db.query('schedule_history')).length, 1);
  });
  test(
      'withdrawn tomorrow persists an empty latest version and older publication cannot revive it',
      () async {
    final both = FullSchedule(
        today: DailySchedule.fromEncodedString('0' * 24),
        tomorrow: DailySchedule.fromEncodedString('1' * 24));
    await save({'GPV1.1': both}, '06.10.2026 10:00');
    await save({'GPV1.1': schedule('0' * 24)}, '06.10.2026 12:00');
    final rows = await db.query('schedule_history',
        where: 'target_date = ?',
        whereArgs: ['2026-10-07'],
        orderBy: 'id DESC');
    expect(rows.first['schedule_code'], '9' * 24);
    await expectLater(
        save({'GPV1.1': both}, '06.10.2026 11:00'), throwsFormatException);
  });
  test('manual/imported rows cannot reset the source watermark', () async {
    await save({'GPV1.1': schedule('0' * 24)}, '06.10.2026 12:00');
    await history.persistVersion(
        groupKey: 'GPV1.1',
        targetDate: '2026-10-06',
        scheduleCode: '1' * 24,
        dtekUpdatedAt: '06.10.2026 12:30:00 (Manual)');
    await expectLater(save({'GPV1.1': schedule('1' * 24)}, '06.10.2026 11:00'),
        throwsFormatException);
  });
  test('late legacy import cannot resurrect a withdrawn current publication',
      () async {
    final both = FullSchedule(
        today: DailySchedule.fromEncodedString('0' * 24),
        tomorrow: DailySchedule.fromEncodedString('1' * 24));
    await save({'GPV1.1': both}, '06.10.2026 10:00');
    await save({'GPV1.1': schedule('0' * 24)}, '06.10.2026 12:00');
    await history.persistVersion(
        groupKey: 'GPV1.1',
        targetDate: '2026-10-07',
        scheduleCode: '1' * 24,
        dtekUpdatedAt: '10:00');
    final versions =
        await history.getVersionsForDate(DateTime(2026, 10, 7), 'GPV1.1');
    expect(versions.last.toSchedule().isEmpty, true);
    expect(
        await history.getLatestUpdatedAt(
            groupKey: 'GPV1.1', targetDate: '2026-10-07'),
        '06.10.2026 12:00');
  });
  test('explicit manual edit remains current without resetting DTEK watermark',
      () async {
    await save({'GPV1.1': schedule('0' * 24)}, '06.10.2026 12:00');
    await history.persistVersion(
        groupKey: 'GPV1.1',
        targetDate: '2026-10-06',
        scheduleCode: '1' * 24,
        dtekUpdatedAt: '06.10.2026 12:30:00 (Manual)');
    final versions =
        await history.getVersionsForDate(DateTime(2026, 10, 6), 'GPV1.1');
    expect(versions.last.hash, '1' * 24);
  });
  test('equal-version rollover conflicts with already published target date',
      () async {
    final both = FullSchedule(
        today: DailySchedule.fromEncodedString('0' * 24),
        tomorrow: DailySchedule.fromEncodedString('0' * 24));
    await save({'GPV1.1': both}, '06.10.2026 23:00');
    await expectLater(
        history.persistSnapshot(
            schedules: {'GPV1.1': schedule('1' * 24)},
            todayDate: '2026-10-07',
            tomorrowDate: '2026-10-08',
            dtekUpdatedAt: '06.10.2026 23:00'),
        throwsFormatException);
  });
  test('calendar rollback cannot replace a newer-day source baseline',
      () async {
    await history.persistSnapshot(
        schedules: {'GPV1.1': schedule('0' * 24)},
        todayDate: '2026-10-07',
        tomorrowDate: '2026-10-08',
        dtekUpdatedAt: '07.10.2026 00:00');
    await expectLater(save({'GPV1.1': schedule('1' * 24)}, '07.10.2026 00:00'),
        throwsFormatException);
    expect((await db.query('dtek_snapshot_state')).single['today_date'],
        '2026-10-07');
  });
  test(
      'midnight rollover accepts snapshot with publication time earlier than yesterday emergency update',
      () async {
    // Yesterday had an emergency update at 23:15
    await history.persistSnapshot(
      schedules: {'GPV1.1': schedule('0' * 24)},
      todayDate: '2026-10-06',
      tomorrowDate: '2026-10-07',
      dtekUpdatedAt: '06.10.2026 23:15',
    );

    // After midnight, calendar date moves to 2026-10-07, but DTEK site still displays the decree published at 19:00
    await history.persistSnapshot(
      schedules: {'GPV1.1': schedule('1' * 24)},
      todayDate: '2026-10-07',
      tomorrowDate: '2026-10-08',
      dtekUpdatedAt: '06.10.2026 19:00',
    );

    final state = (await db.query('dtek_snapshot_state')).single;
    expect(state['today_date'], '2026-10-07');
    expect(state['version'], ScheduleClock.parseVersion('06.10.2026 19:00'));
  });
}
