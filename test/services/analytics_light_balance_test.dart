import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/models/analytics_models.dart';
import 'package:lumen/models/power_event.dart';
import 'package:lumen/models/power_monitor_status.dart';
import 'package:lumen/services/analytics_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/power_monitor_service.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class RecordedPowerSource implements PowerMonitorService {
  final List<PowerEvent> events;
  DateTime? through;
  DateTime? seen;
  int reads = 0;
  bool fail = false;
  void Function()? beforeRead;
  RecordedPowerSource(this.events, this.through);
  @override
  Future<List<PowerEvent>> getLocalEvents() async {
    reads++;
    beforeRead?.call();
    if (fail) throw StateError('Sensor history unavailable');
    return events;
  }

  @override
  DateTime? get lastSuccessfulSync => through;
  @override
  PowerMonitorSnapshot get snapshot =>
      PowerMonitorSnapshot.unknown(lastSeen: seen);
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late HistoryService history;
  late RecordedPowerSource power;
  late AnalyticsService analytics;
  final now = ScheduleClock.calendar(2026, 10, 7, 12);
  final day = ScheduleClock.day(now, -1);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute(
        'CREATE TABLE schedule_history (id INTEGER PRIMARY KEY AUTOINCREMENT, '
        'group_key TEXT, target_date TEXT, schedule_code TEXT, dtek_updated_at TEXT)');
    history = HistoryService.forTesting(db);
    power = RecordedPowerSource([
      PowerEvent(
          firebaseKey: 'baseline',
          status: 'online',
          timestamp: ScheduleClock.day(now, -40)),
    ], now);
    analytics = AnalyticsService(
        powerMonitor: power, historyService: history, now: () => now);
  });
  tearDown(() async => db.close());

  Future<void> save(String group, String code,
          {String update = '06.10.2026 09:00'}) =>
      history.persistVersion(
          groupKey: group,
          targetDate: '2026-10-06',
          scheduleCode: code,
          dtekUpdatedAt: update);

  test('real persisted latest version is selected for the requested group',
      () async {
    await save('GPV2.1', '1' * 24);
    await save('GPV2.1', '0' * 12 + '1' * 12, update: '06.10.2026 12:00');
    await save('GPV3.1', '0' * 24);
    final data = await analytics.getScheduleDeviation(
        ScheduleDeviationPeriod.yesterday, 'GPV2.1');
    expect(data.balance.start, day);
    expect(data.balance.plannedOnSeconds, 12 * 3600);
    expect(data.balance.actualOnSeconds, 24 * 3600);
    expect(data.balance.relativePercentage, 100);
    expect(power.reads, 1);
    final other = await analytics.getScheduleDeviation(
        ScheduleDeviationPeriod.yesterday, 'GPV3.1');
    expect(other.balance.deltaSeconds, 0);
  });

  test('a withdrawn latest schedule never falls back to an older forecast',
      () async {
    await save('GPV2.1', '0' * 24);
    await save('GPV2.1', '9' * 24, update: '06.10.2026 12:00');
    final data = await analytics.getScheduleDeviation(
        ScheduleDeviationPeriod.yesterday, 'GPV2.1');
    expect(data.balance.hasData, isFalse);
    expect(data.balance.exclusions[LightBalanceExclusion.missingSchedule], 1);
  });

  test('one event-history read serves the entire monthly calculation',
      () async {
    await save('GPV2.1', '0' * 24);
    final data = await analytics.getScheduleDeviation(
        ScheduleDeviationPeriod.month, 'GPV2.1');
    expect(power.reads, 1);
    expect(data.balance.validDays, 1);
    expect(data.balance.excludedDays, 29);
  });

  test('heartbeat evidence can extend coverage beyond the last successful sync',
      () async {
    await save('GPV2.1', '0' * 24);
    power.through = day.add(const Duration(hours: 12));
    var data = await analytics.getScheduleDeviation(
        ScheduleDeviationPeriod.yesterday, 'GPV2.1');
    expect(data.balance.hasData, isFalse);
    power.seen = now;
    data = await analytics.getScheduleDeviation(
        ScheduleDeviationPeriod.yesterday, 'GPV2.1');
    expect(data.balance.hasData, isTrue);
  });

  test(
      'concurrent synchronization cannot advance a calculation past its captured evidence',
      () async {
    await history.persistVersion(
        groupKey: 'GPV2.1',
        targetDate: '2026-10-07',
        scheduleCode: '0' * 24,
        dtekUpdatedAt: '07.10.2026 09:00');
    final captured = now.subtract(const Duration(minutes: 1));
    power.through = captured;
    power.beforeRead = () => power.through = now;
    final data = await analytics.getScheduleDeviation(
        ScheduleDeviationPeriod.today, 'GPV2.1');
    expect(data.balance.hasData, isTrue);
    expect(data.balance.end, captured);
  });

  test('source errors propagate so the section can offer a retry', () async {
    power.fail = true;
    await expectLater(
        analytics.getScheduleDeviation(ScheduleDeviationPeriod.week, 'GPV2.1'),
        throwsStateError);
  });
}
