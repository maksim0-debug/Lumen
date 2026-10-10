import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/models/schedule_change_event.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/schedule_change_notification_service.dart';
import 'package:lumen/services/schedule_change_notification_store.dart';
import 'package:lumen/services/schedule_clock.dart';

class _Paths extends PathProviderPlatform {
  final String directory;
  _Paths(this.directory);
  @override
  Future<String?> getApplicationDocumentsPath() async => directory;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
      'version 5 upgrade preserves history and pending work and bootstrap remains idempotent',
      () async {
    SharedPreferences.setMockInitialValues({
      'notification_groups': ['GPV1.2']
    });
    sqfliteFfiInit();
    final originalPaths = PathProviderPlatform.instance;
    final directory =
        await Directory.systemTemp.createTemp('lumen-policy-migration-');
    await HistoryService().close();
    PathProviderPlatform.instance = _Paths(directory.path);
    try {
      final legacy = await databaseFactoryFfi.openDatabase(
          '${directory.path}/schedule_history.db',
          options: OpenDatabaseOptions(version: 5));
      await legacy.execute('CREATE TABLE schedule_history ('
          'id INTEGER PRIMARY KEY AUTOINCREMENT, group_key TEXT, '
          'target_date TEXT, schedule_code TEXT, dtek_updated_at TEXT)');
      await ScheduleChangeNotificationStore.createSchema(legacy);
      await legacy.execute('DROP TABLE schedule_notification_policy');
      final now = ScheduleClock.calendar(2026, 10, 10, 10);
      const hash = '000000000000000111100000';
      await HistoryService.forTesting(legacy).persistSnapshot(
          schedules: {
            'GPV1.2': FullSchedule(
                today: DailySchedule.fromEncodedString(hash),
                tomorrow: DailySchedule.empty(),
                lastUpdatedSource: '10.10.2026 09:38')
          },
          todayDate: '2026-10-10',
          tomorrowDate: '2026-10-11',
          dtekUpdatedAt: '10.10.2026 09:38');
      await legacy.insert('schedule_notification_state', {
        'group_key': 'GPV1.2',
        'target_date': '2026-10-10',
        'source_version': ScheduleClock.parseVersion('10.10.2026 09:38'),
        'schedule_hash': hash,
        'event_key': 'pending-before-upgrade',
        'handled_hash': '0' * 24,
        'handled_version': 1,
        'previous_hash': '0' * 24,
        'pending_since': now.millisecondsSinceEpoch,
      });
      final beforeHistory = await legacy.query('schedule_history');
      final beforeState = await legacy.query('schedule_notification_state');
      final beforeSource = await legacy.query('dtek_snapshot_state');
      await legacy.close();
      final migrated = await HistoryService().database;
      expect(await migrated.getVersion(), 6);
      expect(await migrated.query('schedule_history'), beforeHistory);
      expect(await migrated.query('schedule_notification_state'), beforeState);
      expect(await migrated.query('dtek_snapshot_state'), beforeSource);
      expect(await migrated.query('schedule_notification_policy'), isEmpty);
      final claims = <ScheduleNotificationClaim>[];
      final service = ScheduleChangeNotificationService(
          store:
              ScheduleChangeNotificationStore(database: () async => migrated),
          now: () => now,
          show: (claim) async => claims.add(claim));
      final event = ScheduleChangeEvent(
          group: 'GPV1.2',
          targetDate: '2026-10-10',
          sourceVersion: ScheduleClock.parseVersion('10.10.2026 09:38'),
          hash: hash,
          dayType: 'today');
      final push = {
        'type': 'schedule_updated',
        'schemaVersion': '2',
        'group': event.group,
        'targetDate': event.targetDate,
        'sourceVersion': '${event.sourceVersion}',
        'scheduleHash': event.hash,
        'dayType': event.dayType,
        'eventId': event.id
      };
      await service.handlePush(push);
      await service.handlePush(push);
      expect(claims, hasLength(1));
      expect(claims.single.identity, 'pending-before-upgrade');
      expect(await migrated.query('schedule_history'), beforeHistory);
      expect(
          (await migrated.rawQuery('PRAGMA integrity_check'))
              .single
              .values
              .single,
          'ok');
    } finally {
      await HistoryService().close();
      PathProviderPlatform.instance = originalPaths;
      await directory.delete(recursive: true);
    }
  });
}
