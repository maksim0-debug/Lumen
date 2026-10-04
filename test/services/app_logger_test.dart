import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:lumen/services/app_logger.dart';
import 'package:lumen/services/history_service.dart';

class MockPathProviderPlatform extends Fake
    with MockPlatformInterfaceMixin
    implements PathProviderPlatform {
  final String _tempDir =
      Directory.systemTemp.createTempSync('app_logger_test_').path;

  @override
  Future<String?> getApplicationDocumentsPath() async {
    return _tempDir;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    SharedPreferences.setMockInitialValues({'enable_logging': true});
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
    PathProviderPlatform.instance = MockPathProviderPlatform();
  });

  tearDown(() {
    AppLogger.onLog = null;
  });

  group('AppLogger Tests', () {
    test('Logs through onLog listener with correct level and tag', () {
      final logs = <Map<String, dynamic>>[];
      AppLogger.onLog = (level, message, tag, error, stackTrace) {
        logs.add({
          'level': level,
          'message': message,
          'tag': tag,
          'error': error,
        });
      };

      AppLogger.d('Debug msg', tag: 'TestTag');
      AppLogger.i('Info msg', tag: 'TestTag');
      AppLogger.w('Warning msg', tag: 'TestTag');
      AppLogger.e('Error msg', tag: 'TestTag', error: Exception('boom'));

      expect(logs.length, 4);
      expect(logs[0]['level'], AppLogLevel.debug);
      expect(logs[0]['message'], 'Debug msg');
      expect(logs[0]['tag'], 'TestTag');

      expect(logs[1]['level'], AppLogLevel.info);
      expect(logs[1]['message'], 'Info msg');

      expect(logs[2]['level'], AppLogLevel.warning);
      expect(logs[2]['message'], 'Warning msg');

      expect(logs[3]['level'], AppLogLevel.error);
      expect(logs[3]['message'], 'Error msg');
      expect(logs[3]['error'].toString(), contains('boom'));
    });

    test('AppLogger.e persists error into HistoryService database', () async {
      final history = HistoryService();
      await history.database;
      await history.clearLogs();

      AppLogger.e('Fatal parsing failure',
          tag: 'ParserTest', error: 'NullPointer');

      // Allow microtask/future unawaited to execute
      await Future.delayed(const Duration(milliseconds: 100));

      final persistedLogs = await history.getLogs();
      expect(persistedLogs.isNotEmpty, isTrue);
      expect(persistedLogs.first['level'], 'ERROR');
      expect(persistedLogs.first['message'], contains('ParserTest'));
      expect(persistedLogs.first['message'], contains('Fatal parsing failure'));
      expect(persistedLogs.first['message'], contains('NullPointer'));
    });

    test('AppLogger handles null parameters gracefully', () {
      expect(() => AppLogger.d('Simple message'), returnsNormally);
      expect(() => AppLogger.i('Simple info'), returnsNormally);
      expect(() => AppLogger.w('Simple warn'), returnsNormally);
      expect(() => AppLogger.e('Simple error'), returnsNormally);
    });
  });
}
