import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vikl/services/history_service.dart';
import 'package:vikl/models/schedule_status.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'dart:io';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  @override
  Future<String?> getApplicationDocumentsPath() async {
    return '.';
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PathProviderPlatform.instance = MockPathProviderPlatform();
  });

  group('HistoryService Tests', () {
    test('persistVersion saves data correctly', () async {
      final service = HistoryService();
      // Ensure DB is initialized
      await service.database;

      final group = "GPVTest";
      final date = "2026-01-29";
      final code = "000000000000000000000000"; // All ON
      final updated = "12:00";

      await service.persistVersion(
        groupKey: group,
        targetDate: date,
        scheduleCode: code,
        dtekUpdatedAt: updated,
      );

      final fetchedUpdated = await service.getLatestUpdatedAt(
        groupKey: group,
        targetDate: date,
      );

      expect(fetchedUpdated, updated);
    });

    test('getVersionsForDate retrieves versions', () async {
       final service = HistoryService();
       final group = "GPVTest2";
       final dateObj = DateTime(2026, 1, 30);
       final dateStr = "2026-01-30";
       final code = "111111111111111111111111"; // All OFF
       final updated = "10:00";

       await service.persistVersion(
        groupKey: group,
        targetDate: dateStr,
        scheduleCode: code,
        dtekUpdatedAt: updated,
       );

       final versions = await service.getVersionsForDate(dateObj, group);
       expect(versions, isNotEmpty);
       expect(versions.first.hash, code);
       // Time check: 10:00 -> DateTime
       expect(versions.first.savedAt.hour, 10);
       expect(versions.first.savedAt.minute, 0);
    });
    
    test('Duplicate version is ignored', () async {
      final service = HistoryService();
      final group = "GPVTest3";
      final date = "2026-01-29";
      final code = "0000001111000000";
      final updated = "13:00";

      await service.persistVersion(
        groupKey: group,
        targetDate: date,
        scheduleCode: code,
        dtekUpdatedAt: updated,
      );

      // Save same again
      await service.persistVersion(
        groupKey: group,
        targetDate: date,
        scheduleCode: code,
        dtekUpdatedAt: updated,
      );

      final db = await service.database;
      final count = Sqflite.firstIntValue(await db.rawQuery(
        'SELECT COUNT(*) FROM schedule_history WHERE group_key = ? AND target_date = ? AND dtek_updated_at = ?',
        [group, date, updated]
      ));

      expect(count, 1);
    });
  });
}
