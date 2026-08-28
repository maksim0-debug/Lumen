import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite/sqflite.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vikl/services/history_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';

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

      const group = "GPVTest";
      const date = "2026-01-29";
      const code = "000000000000000000000000"; // All ON
      const updated = "12:00";

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
       const group = "GPVTest2";
       final dateObj = DateTime(2026, 1, 30);
       const dateStr = "2026-01-30";
       const code = "111111111111111111111111"; // All OFF
       const updated = "10:00";

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
      const group = "GPVTest3";
      const date = "2026-01-29";
      const code = "0000001111000000";
      const updated = "13:00";

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
