import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:vikl/services/history_service.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'dart:io';

// Setup Mock for PathProvider (same as history_service_test.dart)
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

  group('Logs Feature Tests', () {
    test('Can write and read logs', () async {
      final service = HistoryService();
      await service.database; // Ensure Init

      await service.clearLogs();

      await service.logAction("Test Log 1");
      await service.logAction("Test Log 2", level: "ERROR");

      final logs = await service.getLogs();
      
      expect(logs.length, 2);
      expect(logs[0]['message'], "Test Log 2"); // Latest first
      expect(logs[0]['level'], "ERROR");
      expect(logs[1]['message'], "Test Log 1");
    });

    test('Log has timestamp', () async {
       final service = HistoryService();
       await service.logAction("Timestamp test");
       final logs = await service.getLogs(limit: 1);
       final item = logs.first;
       
       expect(item['timestamp'], isNotNull);
       // Should parse as date
       expect(DateTime.tryParse(item['timestamp']), isNotNull);
    });
  });
}
