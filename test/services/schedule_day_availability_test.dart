import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/schedule_snapshot.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/models/schedule_view_mode.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/api/controllers/history_controller.dart';
import 'package:lumen/services/parser_service.dart';
import 'package:lumen/services/schedule_clock.dart';
import 'package:lumen/services/schedule_ingestion_service.dart';
import 'package:lumen/services/schedule_version_filter.dart';
import 'package:lumen/ui/state/home_notifier.dart';
import 'package:lumen/utils/app_formatters.dart';

class _HistoryRequest extends Fake implements HttpRequest {
  _HistoryRequest(this.uri);
  @override
  final Uri uri;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Database db;
  late HistoryService history;
  late ScheduleIngestionService ingestion;
  late DateTime day;
  const group = 'GPV2.1';
  final zero = '0' * 24;
  final unknown = '9' * 24;
  final a = '0' * 12 + '1' * 4 + '0' * 8;
  final b = '0' * 16 + '1' * 4 + '0' * 4;

  ScheduleSnapshot publication(int sequence, String? tomorrow,
      {DateTime? targetToday, String? today, String? update}) {
    final date = targetToday ?? day;
    final source = update ??
        '${date.day.toString().padLeft(2, '0')}.'
            '${date.month.toString().padLeft(2, '0')}.${date.year} '
            '00:${sequence.toString().padLeft(2, '0')}';
    return ScheduleSnapshot.parse({
      'v': 1,
      'journalId': 'audit',
      'sequence': sequence,
      'todayDate': AppFormatters.formatDateKey(date),
      'tomorrowDate': AppFormatters.formatDateKey(
          DateTime(date.year, date.month, date.day + 1)),
      'sourceVersion': ScheduleClock.parseVersion(source),
      'sourceUpdatedAt': source,
      'alerts': 0,
      'groups': {
        for (final g in ParserService.allGroups) g: [today ?? zero, tomorrow]
      },
    }, now: ScheduleClock.calendar(date.year, date.month, date.day, 23, 59));
  }

  Future<void> save(ScheduleSnapshot value) => history.persistSnapshot(
      schedules: value.schedules,
      todayDate: value.todayDate,
      tomorrowDate: value.tomorrowDate,
      dtekUpdatedAt: value.sourceUpdatedAt);

  Future<List<ScheduleVersion>> versions({DateTime? target}) =>
      history.getVersionsForDate(
          target ?? DateTime(day.year, day.month, day.day + 1), group);

  Future<void> archive(List<ScheduleSnapshot> values, {int previous = 0}) =>
      ingestion.archivePage(values,
          endpoint: 'audit',
          journalId: 'audit',
          previous: previous,
          next: values.last.sequence,
          expectedJournalId: previous == 0 ? null : 'audit');

  ProviderContainer homeContainer(HistoryService service) =>
      ProviderContainer(overrides: [
        homeNotifierProvider
            .overrideWith(() => HomeNotifier(historyService: service)),
      ]);

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db.execute('CREATE TABLE schedule_history ('
        'id INTEGER PRIMARY KEY AUTOINCREMENT, group_key TEXT, target_date TEXT, '
        'schedule_code TEXT, dtek_updated_at TEXT)');
    await db.execute('CREATE TABLE power_events ('
        'id INTEGER PRIMARY KEY, firebase_key TEXT UNIQUE, status TEXT, '
        'timestamp TEXT, device TEXT, synced_at TEXT, is_manual INTEGER)');
    history = HistoryService.forTesting(db);
    day = ScheduleClock.day(ScheduleClock.now());
    ingestion = ScheduleIngestionService(history: history);
  });
  tearDown(() async => db.close());

  test('null schedule code remains an explicit corrupt record without crashing',
      () async {
    final value = publication(1, zero);
    await db.insert('schedule_history', {
      'group_key': group,
      'target_date': value.todayDate,
      'schedule_code': null,
      'dtek_updated_at': value.sourceUpdatedAt,
    });
    final before = await db.query('schedule_history');
    final corrupt = (await versions(target: day)).single;
    expect(corrupt.isUnavailable, false);
    expect(corrupt.outageString, 'Пошкоджені дані графіка');
    final response = await HistoryController(historyService: history)
        .getVersions(_HistoryRequest(Uri.parse(
            '/api/v1/history/versions?date=${value.todayDate}&group=$group')));
    final entry = (response.data['versions'] as List).single;
    expect(entry['is_available'], false);
    expect(entry['entry_type'], 'invalid');
    final container = homeContainer(history);
    addTearDown(container.dispose);
    final home = container.read(homeNotifierProvider.notifier);
    await home.refreshVersionsForCurrentMode();
    home.selectVersion(0);
    await home.updateStatusDate();
    expect(home.state.statusMessage, startsWith('Пошкоджені дані графіка:'));
    expect(home.state.statusColor, Colors.grey);
    expect(await history.getLastKnownSchedules(), isEmpty);
    expect(await db.query('schedule_history'), before);
    await save(value);
    expect((await versions(target: day)).last.hash, zero);
    expect(await db.query('schedule_history'), hasLength(25));
  });

  test('malformed range records fail with FormatException and roll back',
      () async {
    final valid = {
      'group_key': group,
      'target_date': AppFormatters.formatDateKey(day),
      'schedule_code': zero,
      'dtek_updated_at': null,
    };
    for (final invalid in [
      null,
      42,
      <String, dynamic>{},
      {...valid, 'group_key': null},
      {...valid, 'target_date': 42},
      {...valid, 'schedule_code': null},
      {...valid, 'schedule_code': 123},
    ]) {
      await expectLater(
          history.importDataRangeFromJson(jsonEncode({
            'version': 1,
            'schedules': [valid, invalid],
          })),
          throwsFormatException);
      expect(await db.query('schedule_history'), isEmpty);
    }
  });

  test('new snapshots do not create the obsolete current pointer table',
      () async {
    await save(publication(1, zero));
    expect(
        await db.rawQuery("SELECT name FROM sqlite_master WHERE type='table' "
            "AND name='dtek_current_schedule'"),
        isEmpty);
  });

  test('malformed range containers fail with FormatException', () async {
    for (final payload in [
      <dynamic>[],
      {'version': 1, 'schedules': 42},
      {'version': 1, 'power_events': 'invalid'},
      {
        'version': 1,
        'power_events': [null]
      },
    ]) {
      await expectLater(history.importDataRangeFromJson(jsonEncode(payload)),
          throwsFormatException);
      expect(await db.query('schedule_history'), isEmpty);
      expect(await db.query('power_events'), isEmpty);
    }
  });

  test('invalid encoded legacy records stay visible without claiming absence',
      () async {
    for (final code in ['', '0' * 23, 'x' * 24]) {
      await history.persistVersion(
          groupKey: group,
          targetDate: AppFormatters.formatDateKey(day),
          scheduleCode: code,
          dtekUpdatedAt: '00:00');
    }
    final result = await versions(target: day);
    expect(result.map((v) => v.hash), ['', '0' * 23, 'x' * 24]);
    expect(result.every((v) => v.isCorrupt && !v.isUnavailable), true);
    expect(result.map((v) => v.outageString),
        everyElement('Пошкоджені дані графіка'));
    expect(
        ScheduleVersionFilter.project(result, hideUnchanged: true)
            .visibleIndices,
        [0, 1, 2]);
  });

  test('legacy current pointers remain authoritative until a new snapshot',
      () async {
    final value = publication(1, a);
    await history.persistVersion(
        groupKey: group,
        targetDate: value.todayDate,
        scheduleCode: a,
        dtekUpdatedAt: value.sourceUpdatedAt);
    final id = (await db.query('schedule_history')).single['id'];
    await db.execute('CREATE TABLE dtek_current_schedule ('
        'group_key TEXT, target_date TEXT, history_id INTEGER)');
    await db.insert('dtek_current_schedule', {
      'group_key': group,
      'target_date': value.todayDate,
      'history_id': id,
    });
    await history.persistVersion(
        groupKey: group,
        targetDate: value.todayDate,
        scheduleCode: b,
        dtekUpdatedAt: publication(2, b).sourceUpdatedAt);
    expect(
        (await history.getLastKnownSchedules())[group]!.today.scheduleHash, a);
    await save(publication(3, zero));
    expect((await history.getLastKnownSchedules())[group]!.today.scheduleHash,
        zero);
    expect((await db.query('dtek_current_schedule')).single['history_id'], id);
  });

  test('portable observation-only backup imports successfully', () async {
    await archive([publication(1, null)]);
    final backup = jsonDecode(await history.exportHistoryToJson()) as Map;
    backup.removeWhere((key, _) => key != 'source_observations');
    await db.delete('dtek_day_observations');
    await history.importHistoryFromJson(jsonEncode(backup));
    expect(await db.query('dtek_day_observations'), hasLength(24));
    expect(await versions(), isEmpty);
  });

  test('portable empty export is a valid no-op import', () async {
    final backup = await history.exportHistoryToJson();
    await history.importHistoryFromJson(backup);
    expect(await db.query('schedule_history'), isEmpty);
  });

  test('invalid portable observations roll back accompanying history',
      () async {
    final key = 'history_v2_${AppFormatters.formatDateKey(day)}_$group';
    final value = ScheduleVersion.fromSchedule(
        DailySchedule.fromEncodedString(a),
        at: day);
    await expectLater(
        history.importHistoryFromJson(jsonEncode({
          key: [value.toJson()],
          'source_observations': [
            {'group_key': group}
          ],
        })),
        throwsFormatException);
    expect(await db.query('schedule_history'), isEmpty);
  });

  test(
      'null legacy source timestamp remains readable and cannot block ingestion',
      () async {
    await db.insert('schedule_history', {
      'group_key': group,
      'target_date': AppFormatters.formatDateKey(day),
      'schedule_code': a,
      'dtek_updated_at': null,
    });
    final legacy = (await versions(target: day)).single;
    expect(legacy.hasReliableTimestamp, false);
    expect(legacy.isManual, false);
    expect(legacy.hash, a);
    expect(
        await history.getLatestUpdatedAt(
            groupKey: group, targetDate: AppFormatters.formatDateKey(day)),
        isNull);
    expect(
        (await history.getLastKnownSchedules())[group]!.today.scheduleHash, a);
    final backup = await history.exportDataRangeToJson(day, day);
    await db.delete('schedule_history');
    await history.importDataRangeFromJson(backup);
    expect(
        (await db.query('schedule_history')).single['dtek_updated_at'], isNull);
    expect((await versions(target: day)).single.hasReliableTimestamp, false);
    await save(publication(1, zero));
    expect((await versions(target: day)).map((v) => v.hash), [a, zero]);
  });

  for (final cached in [false, true]) {
    test('withdrawal status survives refresh with cached=$cached', () async {
      await save(publication(1, a));
      await save(publication(2, null));
      final container = homeContainer(history);
      addTearDown(container.dispose);
      final home = container.read(homeNotifierProvider.notifier);
      home.state = home.state.copyWith(viewMode: ScheduleViewMode.tomorrow);
      await home.refreshVersionsForCurrentMode();
      home.state = home.state.copyWith(isCachedData: cached);
      home.selectVersion(home.state.historyVersions.length - 1);
      final expected =
          'Графік відсутній: ${home.state.historyVersions.last.timeString}'
          '${cached ? " (З пам'яті)" : ""}';
      expect(home.state.statusMessage, expected);
      expect(home.state.statusColor, cached ? Colors.orange : Colors.grey);
      await home.updateStatusDate();
      expect(home.state.statusMessage, expected);
      expect(home.state.statusColor, cached ? Colors.orange : Colors.grey);
      await home.updateStatusDate();
      expect(home.state.statusMessage, expected);
    });
  }

  test('unsupported and malformed portable backups cannot report success',
      () async {
    for (final payload in [
      {'unrelated': true},
      {'source_observations': null},
      {'source_observations': 'invalid'},
      {
        'history_v2_${AppFormatters.formatDateKey(day)}_$group': ['invalid'],
        'source_observations': [],
      },
    ]) {
      await expectLater(history.importHistoryFromJson(jsonEncode(payload)),
          throwsFormatException);
      expect(await db.query('schedule_history'), isEmpty);
    }
  });

  test(
      'legacy V1 and double-encoded V2 imports remain compatible and idempotent',
      () async {
    final date = AppFormatters.formatDateKey(day);
    final value = ScheduleVersion.fromSchedule(
        DailySchedule.fromEncodedString(b),
        at: day);
    final payload = jsonEncode({
      'flutter.history_${date}_$group': a,
      'flutter.history_v2_${date}_$group':
          jsonEncode([jsonEncode(value.toJson()), 'malformed item']),
    });
    await history.importHistoryFromJson(payload);
    await history.importHistoryFromJson(payload);
    expect((await versions(target: day)).map((v) => v.hash), [a, b]);
    expect(await db.query('schedule_history'), hasLength(2));
  });

  test(
      'refresh preserves explicitly selected past withdrawal after republication',
      () async {
    await save(publication(1, a));
    await save(publication(2, null));
    await save(publication(3, zero));
    final container = homeContainer(history);
    addTearDown(container.dispose);
    final home = container.read(homeNotifierProvider.notifier);
    home.state = home.state.copyWith(viewMode: ScheduleViewMode.tomorrow);
    await home.refreshVersionsForCurrentMode();
    home.selectVersion(1);
    final message = home.state.statusMessage;
    await home.updateStatusDate();
    expect(home.state.statusMessage, message);
    expect(home.state.selectedVersionIndex, 1);
    expect(home.state.currentDisplaySchedule!.isEmpty, true);
    home.selectVersion(2);
    await home.updateStatusDate();
    expect(home.state.statusMessage,
        'Оновлено ДТЕК: ${home.state.historyVersions.last.timeString}');
    expect(home.state.currentDisplaySchedule!.scheduleHash, zero);
    expect(home.state.statusColor, Colors.green);
  });

  test(
      'absent and published zero have equal duration but distinct status and hash',
      () {
    final empty = DailySchedule.empty();
    final published = DailySchedule.fromEncodedString(zero);
    expect(empty.isEmpty, true);
    expect(published.isEmpty, false);
    expect(empty.totalOutageMinutes, 0);
    expect(published.totalOutageMinutes, 0);
    expect(empty.scheduleHash, unknown);
    expect(published.scheduleHash, zero);
  });

  test('unpublished tomorrow creates observations but no schedule publications',
      () async {
    await archive([for (var i = 1; i <= 3; i++) publication(i, null)]);
    final result = await versions();
    expect(result, isEmpty);
    expect(
        await db.query('dtek_day_observations',
            where: 'group_key=? AND schedule_code=?',
            whereArgs: [group, unknown]),
        hasLength(3));
    expect(
        ScheduleVersionFilter.project(result, hideUnchanged: true)
            .visibleIndices,
        isEmpty);
    expect(
        ScheduleVersionFilter.project(result, hideUnchanged: false)
            .visibleIndices,
        isEmpty);
  });

  test('direct initial absence alone creates no tomorrow history', () async {
    for (var i = 1; i <= 3; i++) {
      await save(publication(i, null));
    }
    expect(await versions(), isEmpty);
    expect(await db.query('schedule_history'), hasLength(36));
  });

  test('archived and live initial absence never manufacture a publication',
      () async {
    await archive([publication(1, null)]);
    await save(publication(2, null));
    expect(await versions(), isEmpty);
  });

  test(
      'repeated absence retains one withdrawal boundary and no empty history rows',
      () async {
    await save(publication(1, a));
    await save(publication(2, null));
    await save(publication(3, null));
    expect((await versions()).map((v) => v.hash), [a, unknown]);
    expect(
        (await history.getLastKnownSchedules())[group]!.tomorrow.isEmpty, true);
  });

  test('published zero and multiple tomorrow transitions survive both days',
      () async {
    final tomorrow = DateTime(day.year, day.month, day.day + 1);
    await archive([
      publication(1, a),
      publication(2, zero),
      publication(3, b),
      publication(4, zero)
    ]);
    await save(publication(5, null, targetToday: tomorrow, today: a));
    final result = await versions(target: tomorrow);
    expect(result.map((v) => v.hash), [a, zero, b, zero, a]);
    expect(result.map((v) => v.outageMinutes), [240, 0, 240, 0, 240]);
    expect(result.every((v) => !v.toSchedule().isEmpty), true);
    expect(
        ScheduleVersionFilter.project(result, hideUnchanged: true)
            .visibleIndices,
        [0, 1, 2, 3, 4]);
  });

  test(
      'equal-duration shifts and half-hour directions are distinct publications',
      () async {
    final first = '2${'0' * 23}';
    final second = '3${'0' * 23}';
    await archive([
      publication(1, a),
      publication(2, b),
      publication(3, first),
      publication(4, second)
    ]);
    final result = await versions();
    expect(result.map((v) => v.hash), [a, b, first, second]);
    expect(result.map((v) => v.outageMinutes), [240, 240, 30, 30]);
    expect(
        ScheduleVersionFilter.project(result, hideUnchanged: true)
            .visibleIndices,
        [0, 1, 2, 3]);
  });

  test('stale or equal-version conflicts do not erase a valid zero publication',
      () async {
    await save(publication(2, zero));
    await expectLater(save(publication(1, a)), throwsFormatException);
    await expectLater(save(publication(2, a)), throwsFormatException);
    expect((await versions()).single.hash, zero);
  });

  test('replaying an archive page is idempotent', () async {
    final values = [publication(1, a), publication(2, zero), publication(3, a)];
    await archive(values);
    await archive(values, previous: 3);
    expect(await db.query('schedule_history'), hasLength(72));
    expect((await versions()).map((v) => v.hash), [a, zero, a]);
  });

  test('partial backfill cannot revive tomorrow after a fresh initial absence',
      () async {
    await save(publication(2, null));
    expect(
        (await history.getLastKnownSchedules())[group]!.tomorrow.isEmpty, true);
    await archive([publication(1, a)]);
    expect(
        (await history.getLastKnownSchedules())[group]!.tomorrow.isEmpty, true);
    await archive([publication(2, null)], previous: 1);
    expect(
        (await history.getLastKnownSchedules())[group]!.tomorrow.isEmpty, true);
  });

  test('JSON export preserves all real rows and original source timestamps',
      () async {
    await save(publication(1, a));
    expect(await db.query('schedule_history'), hasLength(24));
    final portable = jsonDecode(await history.exportHistoryToJson()) as Map;
    expect(portable['source_observations'], hasLength(24));
    final histories = Map.of(portable)..remove('source_observations');
    expect(histories, hasLength(24));
    for (final entries in histories.values) {
      final version =
          ScheduleVersion.fromJson(jsonDecode((entries as List).single));
      expect(version.sourceUpdatedAt, publication(1, a).sourceUpdatedAt);
      expect(version.hasReliableTimestamp, true);
    }
  });

  test(
      'UI shows unavailable tomorrow without fictitious versions or green update',
      () async {
    await archive([publication(1, null), publication(2, null)]);
    final container = homeContainer(history);
    addTearDown(container.dispose);
    final home = container.read(homeNotifierProvider.notifier);
    home.state = home.state.copyWith(viewMode: ScheduleViewMode.tomorrow);
    await home.refreshVersionsForCurrentMode();
    await home.updateStatusDate();
    expect(home.state.historyVersions, isEmpty);
    expect(
        home.state.currentDisplaySchedule == null ||
            home.state.currentDisplaySchedule!.isEmpty,
        true);
    expect(home.state.hasDisplayData, false);
    expect(home.state.statusMessage, 'Графік на завтра відсутній');
    expect(home.state.statusColor, Colors.grey);
  });

  test(
      'yesterday missing tomorrow never becomes fictitious today history after rollover',
      () async {
    final yesterday = DateTime(day.year, day.month, day.day - 1);
    await archive([
      publication(1, null, targetToday: yesterday),
      publication(2, null, targetToday: yesterday)
    ]);
    await save(publication(3, null, today: a));
    final result = await versions(target: day);
    expect(result.map((v) => v.hash), [a]);
    expect(result.single.savedAt.day, day.day);
    final container = homeContainer(history);
    addTearDown(container.dispose);
    final home = container.read(homeNotifierProvider.notifier);
    await home.refreshVersionsForCurrentMode();
    expect(home.state.historyVersions, hasLength(1));
    expect(home.state.currentDisplaySchedule!.scheduleHash, a);
    expect(home.state.versionProjection.visibleIndices, [0]);
  });

  test('current absence survives removal of legacy empty history rows',
      () async {
    await save(publication(1, a));
    await save(publication(2, null));
    expect(
        (await history.getLastKnownSchedules())[group]!.tomorrow.isEmpty, true);
    // Only this isolated in-memory database is modified.
    await db.delete('schedule_history',
        where: 'schedule_code=?', whereArgs: [unknown]);
    expect(
        (await history.getLastKnownSchedules())[group]!.tomorrow.isEmpty, true);
  });

  test(
      'journal sequence across midnight preserves real graphs without phantom schedules',
      () async {
    // GPV2.1 transitions observed in the public journal on 10-11 October.
    // Other groups reuse this graph to exercise the complete snapshot contract.
    final records = <(int, String, String, String?)>[
      (10, '10.10.2026 10:37', '000000000000000111100000', null),
      (10, '10.10.2026 11:34', '000000000000000111100000', null),
      (10, '10.10.2026 18:52', '000000000000000011100000', null),
      (10, '10.10.2026 20:13', '000000000000000011100000', zero),
      (10, '10.10.2026 22:00', '000000000000000011100000', zero),
      (10, '10.10.2026 22:40', '000000000000000011100000', zero),
      (11, '10.10.2026 22:40', zero, null),
      (11, '11.10.2026 09:34', zero, null),
      (11, '11.10.2026 10:57', zero, null),
      (11, '11.10.2026 11:16', zero, null),
      (11, '11.10.2026 13:20', zero, null),
      (11, '11.10.2026 14:33', zero, null),
    ];
    final values = [
      for (var i = 0; i < records.length; i++)
        publication(i + 1, records[i].$4,
            targetToday: DateTime(2026, 10, records[i].$1),
            update: records[i].$2,
            today: records[i].$3),
    ];
    await ingestion.archivePage(values,
        endpoint: 'journal-regression',
        journalId: 'audit',
        previous: 0,
        next: values.last.sequence);
    final expectedAbsent =
        values.where((v) => v.schedules[group]!.tomorrow.isEmpty).length;
    final rows = await db.query('schedule_history',
        where: 'group_key=? AND schedule_code=?', whereArgs: [group, unknown]);
    expect(expectedAbsent, 9);
    expect(rows, isEmpty);
    final observations = await db.query('dtek_day_observations',
        where: 'group_key=? AND schedule_code=?', whereArgs: [group, unknown]);
    expect(observations, hasLength(expectedAbsent));
    final result =
        await history.getVersionsForDate(DateTime(2026, 10, 11), group);
    expect(result, isNotEmpty);
    expect(result.every((v) => !v.isUnavailable), true);
    expect(await history.getVersionsForDate(DateTime(2026, 10, 12), group),
        isEmpty);
  });

  test('initially unpublished tomorrow must not become a schedule version',
      () async {
    await archive([publication(1, null), publication(2, null)]);
    expect(await versions(), isEmpty,
        reason: 'An absent day is not a zero-outage published schedule');
  });

  test('initial legacy absence cannot create an available history date',
      () async {
    final target = publication(1, null).tomorrowDate;
    await history.persistVersion(
        groupKey: group,
        targetDate: target,
        scheduleCode: unknown,
        dtekUpdatedAt: publication(1, null).sourceUpdatedAt);
    expect(await history.getAvailableDates(), isEmpty);
    await history.persistVersion(
        groupKey: group,
        targetDate: target,
        scheduleCode: zero,
        dtekUpdatedAt: publication(2, zero).sourceUpdatedAt);
    expect(await history.getAvailableDates(), [target]);
  });

  test(
      'same legacy clock preserves different graphs and concurrent exact imports deduplicate',
      () async {
    final target = publication(1, null).tomorrowDate;
    Future<void> insert(String code) => history.persistVersion(
        groupKey: group,
        targetDate: target,
        scheduleCode: code,
        dtekUpdatedAt: '10:00');
    await Future.wait([insert(a), insert(a), insert(b), insert(b)]);
    expect((await versions()).map((v) => v.hash), [a, b]);
    expect(await db.query('schedule_history'), hasLength(2));
  });

  test('reimporting source backup is idempotent and cannot reset live absence',
      () async {
    await save(publication(1, a));
    final backup = await history.exportDataRangeToJson(
        day, DateTime(day.year, day.month, day.day + 1));
    await save(publication(2, null));
    final before = await db.query('schedule_history', orderBy: 'id');
    await history.importDataRangeFromJson(backup);
    await history.importDataRangeFromJson(backup);
    expect(await db.query('schedule_history', orderBy: 'id'), before);
    expect(
        (await history.getLastKnownSchedules())[group]!.tomorrow.isEmpty, true);
    expect((await versions()).map((v) => v.hash), [a, unknown]);
  });

  test('an absent version must not be labeled zero outage', () {
    expect(ScheduleVersion.fromSchedule(DailySchedule.empty()).outageString,
        isNot('0г'));
  });

  test(
      'withdrawal and republication of the same zero or outage graph stay visible',
      () async {
    for (final code in [a, zero]) {
      final offset = code == a ? 0 : 4;
      await save(publication(offset + 1, code));
      await save(publication(offset + 2, null));
      await save(publication(offset + 3, null));
      await save(publication(offset + 4, code));
    }
    final result = await versions();
    expect(result.map((v) => v.hash), [a, unknown, a, zero, unknown, zero]);
    for (final hide in [true, false]) {
      expect(
          ScheduleVersionFilter.project(result, hideUnchanged: hide)
              .visibleIndices,
          [0, 1, 2, 3, 4, 5]);
    }
    final rows = await db.query('schedule_history',
        where: 'group_key=? AND target_date=?',
        whereArgs: [group, publication(1, a).tomorrowDate]);
    expect(rows.map((r) => r['schedule_code']), [a, a, zero, zero]);
  });

  test(
      'legacy phantom rows are hidden without changing or deleting stored records',
      () async {
    for (var i = 1; i <= 3; i++) {
      final value = publication(i, null);
      await history.persistVersion(
          groupKey: group,
          targetDate: value.tomorrowDate,
          scheduleCode: unknown,
          dtekUpdatedAt: value.sourceUpdatedAt);
    }
    final before = await db.query('schedule_history', orderBy: 'id');
    expect(await versions(), isEmpty);
    expect(await db.query('schedule_history', orderBy: 'id'), before);
    await save(publication(4, zero));
    expect((await versions()).map((v) => v.hash), [zero]);
    expect(
        (await db.query('schedule_history',
            where: 'schedule_code=?', whereArgs: [unknown])),
        before);
  });

  test('legacy withdrawal retains the current empty state and every real graph',
      () async {
    for (final value in [
      publication(1, a),
      publication(2, null),
      publication(3, null)
    ]) {
      await history.persistVersion(
          groupKey: group,
          targetDate: value.tomorrowDate,
          scheduleCode: value.schedules[group]!.tomorrow.scheduleHash,
          dtekUpdatedAt: value.sourceUpdatedAt);
    }
    final before = await db.query('schedule_history', orderBy: 'id');
    expect((await versions()).map((v) => v.hash), [a, unknown]);
    final cached = await history.getLastKnownSchedules();
    // Only tomorrow data exists and is withdrawn, so there is no usable group.
    expect(cached[group], isNull);
    expect(await db.query('schedule_history', orderBy: 'id'), before);
  });

  test('old phantom watermark cannot reject a real graph after midnight',
      () async {
    final yesterday = DateTime(day.year, day.month, day.day - 1);
    final prefix = '${yesterday.day.toString().padLeft(2, '0')}.'
        '${yesterday.month.toString().padLeft(2, '0')}.${yesterday.year}';
    await history.persistVersion(
        groupKey: group,
        targetDate: AppFormatters.formatDateKey(day),
        scheduleCode: unknown,
        dtekUpdatedAt: '$prefix 23:15');
    await save(publication(1, null, today: a, update: '$prefix 19:00'));
    expect((await versions(target: day)).map((v) => v.hash), [a]);
    expect(
        (await history.getLastKnownSchedules())[group]!.today.scheduleHash, a);
  });

  test(
      'calendar observations prevent old absence from splitting new-day publications',
      () async {
    final yesterday = DateTime(day.year, day.month, day.day - 1);
    final prefix = '${yesterday.day.toString().padLeft(2, '0')}.'
        '${yesterday.month.toString().padLeft(2, '0')}.${yesterday.year}';
    await save(
        publication(1, null, targetToday: yesterday, update: '$prefix 23:15'));
    await save(publication(2, null, today: a, update: '$prefix 19:00'));
    await save(publication(3, null, today: zero, update: '$prefix 20:00'));
    await save(publication(4, null, today: b, update: '$prefix 21:00'));
    expect((await versions(target: day)).map((v) => v.hash), [a, zero, b]);
  });

  test(
      'identical source retries preserve a later manual edit of unavailable tomorrow',
      () async {
    final value = publication(1, null);
    await save(value);
    await history.persistVersion(
        groupKey: group,
        targetDate: value.tomorrowDate,
        scheduleCode: a,
        dtekUpdatedAt: '${value.sourceUpdatedAt}:30 (Manual)');
    await save(value);
    expect(
        (await history.getLastKnownSchedules())[group]!.tomorrow.scheduleHash,
        a);
    expect((await versions()).last.isManual, true);
    await save(publication(2, null));
    expect(
        (await history.getLastKnownSchedules())[group]!.tomorrow.isEmpty, true);
    expect((await versions()).last.isUnavailable, true);
  });

  test('history API distinguishes withdrawal from a published zero outage',
      () async {
    final first = publication(1, zero);
    final controller = HistoryController(historyService: history);
    final request = _HistoryRequest(Uri.parse(
        '/api/v1/history/versions?date=${first.tomorrowDate}&group=$group'));
    await save(publication(1, null));
    expect((await controller.getVersions(request)).data['versions'], isEmpty);
    await save(publication(2, zero));
    await save(publication(3, null));
    final response = await controller.getVersions(request);
    expect(response.statusCode, 200);
    final entries = response.data['versions'] as List;
    expect(entries.map((v) => v['is_available']), [true, false]);
    expect(entries.map((v) => v['entry_type']), ['publication', 'unavailable']);
    expect(
        entries.map((v) => v['outage_formatted']), ['0г', 'Графік відсутній']);
  });

  test('new calendar snapshot supersedes manual edits of a reused publication',
      () async {
    final previousDay = DateTime(day.year, day.month, day.day - 1);
    final first = publication(1, a, targetToday: previousDay);
    await save(first);
    await history.persistVersion(
        groupKey: group,
        targetDate: first.tomorrowDate,
        scheduleCode: b,
        dtekUpdatedAt: '${first.sourceUpdatedAt}:30 (Manual)');
    expect(
        (await history.getLastKnownSchedules())[group]!.today.scheduleHash, b);
    await save(publication(2, null, today: a, update: first.sourceUpdatedAt));
    expect(
        (await history.getLastKnownSchedules())[group]!.today.scheduleHash, a);
    expect((await versions(target: day)).last.hash, a);
  });

  test('concurrent live retries and journal replay create one publication',
      () async {
    final value = publication(1, zero);
    await Future.wait([
      save(value),
      save(value),
      archive([value]),
      archive([value])
    ]);
    expect(await db.query('schedule_history'), hasLength(24));
    expect(await db.query('dtek_day_observations'), hasLength(24));
    expect(await db.query('dtek_current_day_state'), hasLength(24));
    expect((await versions()).single.hash, zero);
  });

  test(
      'conflicting absent and published observations roll back page and cursor',
      () async {
    final first = publication(1, null);
    await archive([first]);
    final conflict = publication(1, a);
    await expectLater(archive([publication(2, b), conflict], previous: 1),
        throwsFormatException);
    expect(await db.query('schedule_history'), hasLength(12));
    expect(await db.query('dtek_day_observations'), hasLength(24));
    expect((await db.query('schedule_journal_cursor')).single['sequence'], 1);
    expect(await versions(), isEmpty);
  });

  test('published uncertainty is retained even when planned outages are zero',
      () async {
    await save(publication(1, '4' * 24));
    final result = (await versions()).single;
    expect(result.isUnavailable, false);
    expect(result.outageMinutes, 0);
    expect(result.hash, '4' * 24);
  });

  test('partial unknown schedules roll back the whole source snapshot',
      () async {
    await save(publication(1, a));
    final before = await db.query('schedule_history', orderBy: 'id');
    await expectLater(
        history.persistSnapshot(
            schedules: {
              'GPV1.1': FullSchedule(
                  today: DailySchedule.fromEncodedString(b),
                  tomorrow: DailySchedule.empty()),
              group: FullSchedule(
                  today: DailySchedule.fromEncodedString('9${'0' * 23}'),
                  tomorrow: DailySchedule.empty()),
            },
            todayDate: publication(2, null).todayDate,
            tomorrowDate: publication(2, null).tomorrowDate,
            dtekUpdatedAt: publication(2, null).sourceUpdatedAt),
        throwsFormatException);
    expect(await db.query('schedule_history', orderBy: 'id'), before);
    expect((await versions()).single.hash, a);
  });

  test(
      'range and legacy JSON restore withdrawals and original publication timestamps',
      () async {
    await save(publication(1, a));
    await save(publication(2, null));
    final expected = await db.query('schedule_history',
        columns: [
          'group_key',
          'target_date',
          'schedule_code',
          'dtek_updated_at'
        ],
        orderBy: 'id');
    final raw = await history.exportDataRangeToJson(
        day, DateTime(day.year, day.month, day.day + 1));
    final legacy = await history.exportHistoryToJson();
    for (final value in [raw, legacy]) {
      final directory =
          await Directory.systemTemp.createTemp('lumen-availability-restore-');
      final restoredDb =
          await databaseFactoryFfi.openDatabase('${directory.path}/history.db');
      try {
        await restoredDb.execute(
            'CREATE TABLE schedule_history (id INTEGER PRIMARY KEY AUTOINCREMENT, group_key TEXT, target_date TEXT, schedule_code TEXT, dtek_updated_at TEXT)');
        final restored = HistoryService.forTesting(restoredDb);
        if (value == raw) {
          await restored.importDataRangeFromJson(value);
        } else {
          await restored.importHistoryFromJson(value);
        }
        expect(
            await restoredDb.query('schedule_history',
                columns: [
                  'group_key',
                  'target_date',
                  'schedule_code',
                  'dtek_updated_at'
                ],
                orderBy: 'id'),
            unorderedEquals(expected));
        expect(
            (await restored.getLastKnownSchedules())[group]!.tomorrow.isEmpty,
            true);
        expect(
            (await restored.getVersionsForDate(
                    DateTime(day.year, day.month, day.day + 1), group))
                .map((v) => v.hash),
            [a, unknown]);
        expect(await restoredDb.query('dtek_current_day_state'), isEmpty);
      } finally {
        await restoredDb.close();
        await directory.delete(recursive: true);
      }
    }
  });

  test('invalid observation import rolls back every raw history insert',
      () async {
    final raw =
        jsonDecode(await history.exportDataRangeToJson(day, day)) as Map;
    raw['schedules'] = [
      {
        'group_key': group,
        'target_date': publication(1, a).todayDate,
        'schedule_code': a,
        'dtek_updated_at': publication(1, a).sourceUpdatedAt
      }
    ];
    raw['source_observations'] = [
      {
        'group_key': group,
        'target_date': '2026-02-30',
        'snapshot_date': '2026-02-29',
        'source_version': 1,
        'schedule_code': zero,
        'dtek_updated_at': 'bad'
      }
    ];
    await expectLater(history.importDataRangeFromJson(jsonEncode(raw)),
        throwsFormatException);
    expect(await db.query('schedule_history'), isEmpty);
  });

  test(
      'randomized observed histories preserve all publications and absence boundaries',
      () async {
    final random = Random(119);
    final choices = <String?>[null, zero, a, b, '2${'0' * 23}'];
    final expected = <String>[];
    final published = <String>[];
    for (var i = 1; i <= 40; i++) {
      final code = choices[random.nextInt(choices.length)];
      await save(publication(i, code));
      if (code != null) {
        published.add(code);
        expected.add(code);
      } else if (expected.isNotEmpty && expected.last != unknown) {
        expected.add(unknown);
      }
      final result = await versions();
      expect(result.map((v) => v.hash), expected);
      final rows = await db.query('schedule_history',
          where: 'group_key=? AND target_date=?',
          whereArgs: [group, publication(i, code).tomorrowDate],
          orderBy: 'id');
      expect(rows.map((r) => r['schedule_code']), published);
      final cache = (await history.getLastKnownSchedules())[group]!.tomorrow;
      expect(cache.scheduleHash, code ?? unknown);
    }
  });
}
