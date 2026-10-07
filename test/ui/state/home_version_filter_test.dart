import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/services/schedule_version_filter.dart';
import 'package:lumen/ui/state/home_notifier.dart';
import 'package:lumen/ui/state/schedule_version_preferences.dart';
import 'package:lumen/utils/app_formatters.dart';

class DelayedHistory extends Fake implements HistoryService {
  final pending = <Completer<List<ScheduleVersion>>>[];

  @override
  Future<List<ScheduleVersion>> getVersionsForDate(
      DateTime date, String groupKey) {
    final result = Completer<List<ScheduleVersion>>();
    pending.add(result);
    return result.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late HistoryService history;
  late ProviderContainer container;
  late HomeNotifier home;
  late DateTime date;
  const a = '000000000000111100000000';
  const b = '000000000000000011110000';

  Future<void> save(String code, int minute,
          {String group = 'GPV2.1', DateTime? target, String? source}) =>
      history.persistVersion(
        groupKey: group,
        targetDate: AppFormatters.formatDateKey(target ?? date),
        scheduleCode: code,
        dtekUpdatedAt: source ?? '10:${minute.toString().padLeft(2, '0')}',
      );

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE schedule_history ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, group_key TEXT, '
        'target_date TEXT, schedule_code TEXT, dtek_updated_at TEXT)');
    history = HistoryService.forTesting(db);
    date = ScheduleClock.now();
    container = ProviderContainer(overrides: [
      homeNotifierProvider
          .overrideWith(() => HomeNotifier(historyService: history)),
    ]);
    home = container.read(homeNotifierProvider.notifier);
    await container
        .read(scheduleVersionPreferencesProvider.notifier)
        .ensureLoaded();
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  test('real database retains all publications while navigation skips repeats',
      () async {
    await save(a, 0);
    await save(a, 5);
    await save(b, 10);
    await save(b, 15);
    await save(a, 20);
    await home.refreshVersionsForCurrentMode();
    expect(home.state.historyVersions, hasLength(5));
    expect(home.state.versionProjection.visibleIndices, [1, 3, 4]);
    expect(await db.query('schedule_history'), hasLength(5));
    expect(home.state.selectedVersionIndex, 4);
    home.cycleVersion(-1);
    expect(home.state.selectedVersionIndex, 3);
    expect(home.state.currentDisplaySchedule!.scheduleHash, b);
    home.cycleVersion(-1);
    expect(home.state.selectedVersionIndex, 1);
    home.cycleVersion(-1);
    expect(home.state.selectedVersionIndex, 4);
    home.cycleVersion(1);
    expect(home.state.selectedVersionIndex, 1);
  });

  test(
      'toggle maps a hidden selection to the same run without changing its schedule',
      () async {
    await save(a, 0);
    await save(a, 5);
    await save(b, 10);
    await home.refreshVersionsForCurrentMode();
    final preferences =
        container.read(scheduleVersionPreferencesProvider.notifier);
    await preferences.setHideUnchanged(false);
    home.selectVersion(0);
    expect(home.state.selectedVersionIndex, 0);
    await preferences.setHideUnchanged(true);
    expect(home.state.selectedVersionIndex, 1);
    expect(home.state.currentDisplaySchedule!.scheduleHash, a);
    await preferences.setHideUnchanged(false);
    expect(home.state.selectedVersionIndex, 1);
    home.cycleVersion(-1);
    expect(home.state.selectedVersionIndex, 0);
    expect(home.state.historyVersions, hasLength(3));
  });

  test('all identical versions remain accessible and navigation is a no-op',
      () async {
    await save(a, 0);
    await save(a, 5);
    await home.refreshVersionsForCurrentMode();
    home.cycleVersion(-1);
    expect(home.state.selectedVersionIndex, 1);
    await container
        .read(scheduleVersionPreferencesProvider.notifier)
        .setHideUnchanged(false);
    home.cycleVersion(-1);
    expect(home.state.selectedVersionIndex, 0);
  });

  test('filter recalculates independently for each group and date', () async {
    await save(a, 0);
    await save(a, 5);
    await save(a, 0, group: 'GPV1.1');
    await save(b, 5, group: 'GPV1.1');
    await save(a, 10, target: date.add(const Duration(days: 1)));
    await home.refreshVersionsForCurrentMode();
    expect(home.state.versionProjection.visibleIndices, [1]);
    home.state = home.state.copyWith(currentGroup: 'GPV1.1');
    await home.refreshVersionsForCurrentMode();
    expect(home.state.versionProjection.visibleIndices, [0, 1]);
    home.state = home.state
        .copyWith(currentGroup: 'GPV2.1', viewMode: ScheduleViewMode.tomorrow);
    await home.refreshVersionsForCurrentMode();
    expect(home.state.historyVersions, hasLength(1));
    expect(home.state.hideUnchangedScheduleVersions, isTrue);
  });

  test(
      'live refresh preserves older selection but follows latest when already latest',
      () async {
    await save(a, 0);
    await save(b, 5);
    await home.refreshVersionsForCurrentMode();
    home.selectVersion(0);
    final selectedId = home.state.historyVersions.first.recordId;
    await save(a, 10);
    await home.refreshVersionsForCurrentMode();
    expect(home.state.historyVersions[home.state.selectedVersionIndex].recordId,
        selectedId);
    home.selectVersion(2);
    await save(b, 15);
    await home.refreshVersionsForCurrentMode();
    expect(home.state.selectedVersionIndex, 3);
    expect(home.state.currentDisplaySchedule!.scheduleHash, b);
  });

  test(
      'stale modal callback resolves identity after insertion, and rejects other contexts',
      () async {
    await save(a, 0);
    await save(b, 5);
    await home.refreshVersionsForCurrentMode();
    final selected = home.state.historyVersions.first;
    final extra = ScheduleVersion(
        hash: '1' * 24, savedAt: date, outageMinutes: 1440, recordId: 90);
    home.state = home.state
        .copyWith(historyVersions: [extra, ...home.state.historyVersions]);
    home.selectPublication(selected, group: 'GPV2.1', date: date);
    expect(home.state.selectedVersionIndex, 1);
    home.selectPublication(extra, group: 'GPV1.1', date: date);
    expect(home.state.selectedVersionIndex, 1);
    home.selectPublication(extra,
        group: 'GPV2.1', date: date.subtract(const Duration(days: 1)));
    expect(home.state.selectedVersionIndex, 1);
    home.selectPublication(
        ScheduleVersion(
            hash: b, savedAt: date, outageMinutes: 240, recordId: 999),
        group: 'GPV2.1',
        date: date);
    expect(home.state.selectedVersionIndex, 1);
  });

  test('database metadata preserves manual and ambiguous legacy publications',
      () async {
    await save(a, 0);
    await save(a, 5, source: '07.10.2026 10:05:10 (Manual)');
    await save(a, 10, source: 'unknown');
    await save(a, 15, source: '07.13.2026 99:99');
    final versions = await history.getVersionsForDate(date, 'GPV2.1');
    expect(versions.map((v) => v.recordId).toSet(), hasLength(4));
    expect(versions[1].isManual, isTrue);
    expect(versions[2].hasReliableTimestamp, isFalse);
    expect(versions[3].hasReliableTimestamp, isFalse);
    expect(
        ScheduleVersionFilter.project(versions, hideUnchanged: true)
            .visibleIndices,
        [0, 1, 2, 3]);
  });

  test(
      'late import cannot replace withdrawn tomorrow when filtering is enabled',
      () async {
    final target = date.add(const Duration(days: 1));
    await save(a, 0, target: target);
    await save('9' * 24, 10, target: target);
    final last =
        (await db.query('schedule_history', orderBy: 'id DESC')).first['id'];
    await db.execute('CREATE TABLE dtek_current_schedule ('
        'group_key TEXT, target_date TEXT, history_id INTEGER)');
    await db.insert('dtek_current_schedule', {
      'group_key': 'GPV2.1',
      'target_date': AppFormatters.formatDateKey(target),
      'history_id': last,
    });
    await save(a, 5, target: target);
    home.state = home.state.copyWith(viewMode: ScheduleViewMode.tomorrow);
    await home.refreshVersionsForCurrentMode();
    expect(home.state.historyVersions.last.hash, '9' * 24);
    expect(home.state.currentDisplaySchedule!.isEmpty, isTrue);
    expect(home.state.versionProjection.visibleIndices.last,
        home.state.historyVersions.length - 1);
  });

  test('out-of-order async completions cannot overwrite newer requests',
      () async {
    final delayed = DelayedHistory();
    final other = ProviderContainer(overrides: [
      homeNotifierProvider
          .overrideWith(() => HomeNotifier(historyService: delayed)),
    ]);
    addTearDown(other.dispose);
    final notifier = other.read(homeNotifierProvider.notifier);
    final first = notifier.refreshVersionsForCurrentMode();
    final second = notifier.refreshVersionsForCurrentMode();
    final latest = ScheduleVersion(
        hash: b, savedAt: date, outageMinutes: 240, recordId: 2);
    delayed.pending[1].complete([latest]);
    await second;
    delayed.pending[0].complete([
      ScheduleVersion(hash: a, savedAt: date, outageMinutes: 240, recordId: 1)
    ]);
    await first;
    expect(notifier.state.historyVersions.single.recordId, 2);
    final third = notifier.refreshVersionsForCurrentMode();
    notifier.state = notifier.state.copyWith(currentGroup: 'GPV1.1');
    delayed.pending[2].complete([latest]);
    await third;
    expect(notifier.state.currentGroup, 'GPV1.1');
    expect(notifier.state.historyVersions.single.recordId, 2);
  });
}
