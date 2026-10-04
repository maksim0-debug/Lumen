import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart' show join;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:lumen/models/schedule_status.dart';
import 'package:lumen/services/backup_service.dart';
import 'package:lumen/services/history_service.dart';
import 'package:lumen/services/power_monitor_service.dart';
import 'package:lumen/services/hour_segment_service.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String documentsPath;
  MockPathProviderPlatform(this.documentsPath);

  @override
  Future<String?> getApplicationDocumentsPath() async => documentsPath;

  @override
  Future<String?> getTemporaryPath() async => documentsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  late Directory tempDir;
  late String legacyViklDbPath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('lumen_legacy_db_test_');
    PathProviderPlatform.instance = MockPathProviderPlatform(tempDir.path);

    legacyViklDbPath = join(tempDir.path, 'vikl_backup_2026-09-20_12-00.db');

    // Create authentic legacy vikl SQLite database (schema version 3, lacking is_manual, space in timestamp)
    final db = await databaseFactoryFfi.openDatabase(legacyViklDbPath);
    await db.execute('''
      CREATE TABLE schedule_history (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        group_key TEXT,
        target_date TEXT,
        schedule_code TEXT,
        dtek_updated_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE power_events (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        firebase_key TEXT UNIQUE,
        status TEXT NOT NULL,
        timestamp TEXT NOT NULL,
        device TEXT,
        synced_at TEXT
      )
    ''');
    await db.execute('''
      CREATE TABLE app_logs (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        timestamp TEXT,
        level TEXT,
        message TEXT
      )
    ''');

    // Insert legacy vikl schedule data
    await db.insert('schedule_history', {
      'group_key': 'GPV1.1',
      'target_date': '2026-09-20',
      'schedule_code': '111100001111000011110000',
      'dtek_updated_at': '2026-09-20T07:30:00',
    });

    // Insert legacy power events with space-separated timestamps (pre-ISO migration)
    await db.insert('power_events', {
      'firebase_key': 'legacy_event_1',
      'status': 'offline',
      'timestamp': '2026-09-20 10:00:00',
      'device': 'esp32_sensor',
      'synced_at': '2026-09-20 10:01:00',
    });
    await db.insert('power_events', {
      'firebase_key': 'legacy_event_2',
      'status': 'online',
      'timestamp': '2026-09-20 14:30:00',
      'device': 'esp32_sensor',
      'synced_at': '2026-09-20 14:31:00',
    });

    await db.close();
  });

  tearDown(() async {
    await HistoryService().close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('Legacy Vikl Database Migration & Import Verification', () {
    test(
        'seamlessly imports vikl_backup_*.db, upgrades schema and feeds analytics',
        () async {
      final backupService = BackupService();

      // 1. Execute database import from legacy vikl backup file
      await backupService.importDatabase(legacyViklDbPath);

      // 2. Verify schedule history was imported correctly
      final historyService = HistoryService();
      final versions = await historyService.getVersionsForDate(
        DateTime(2026, 9, 20),
        'GPV1.1',
      );
      expect(versions, isNotEmpty,
          reason: 'Historical schedules must be present after import');
      expect(versions.first.hash, '111100001111000011110000');

      // 3. Verify power events were imported, migrated to ISO-8601 ('T') and column is_manual added
      final powerEvents =
          await PowerMonitorService().getEventsForDate(DateTime(2026, 9, 20));
      expect(powerEvents.length, 2,
          reason: 'All legacy power events must be restored');
      expect(powerEvents.first.timestamp.year, 2026);
      expect(powerEvents.first.timestamp.hour, 10);
      expect(powerEvents.first.isOffline, isTrue);
      expect(powerEvents.last.isOnline, isTrue);

      // 4. Verify HourSegmentService calculates accurate historical outage intervals from imported data
      final outageIntervals =
          await PowerMonitorService().getOutageIntervalsForDate(
        DateTime(2026, 9, 20),
      );
      expect(outageIntervals, isNotEmpty,
          reason:
              'Outage intervals must be computed from restored power events');

      final segments = HourSegmentService.computeHourSegments(
        outageIntervals,
        DateTime(2026, 9, 20),
        11, // Hour 11:00 - was completely off (10:00 to 14:30)
        forecast: versions.first.toSchedule(),
      );
      expect(segments.any((s) => s.status == LightStatus.off), isTrue,
          reason: 'Charts must reflect outages from imported vikl database');
    });
  });
}
