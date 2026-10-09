import 'package:flutter_test/flutter_test.dart';
import 'package:lumen/services/history_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  late Database db;
  late HistoryService history;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    sqfliteFfiInit();
    db = await databaseFactoryFfi.openDatabase(inMemoryDatabasePath);
    await db
        .execute('CREATE TABLE app_logs (id INTEGER PRIMARY KEY AUTOINCREMENT, '
            'timestamp TEXT, level TEXT, message TEXT)');
    history = HistoryService.forTesting(db);
  });
  tearDown(() async {
    if (db.isOpen) await db.close();
  });

  test('Batch logging preserves stage ordering and levels', () async {
    await history.insertRawLogs([
      (message: 'start', level: 'INFO'),
      (message: 'failure', level: 'ERROR'),
      (message: 'end', level: 'WARN'),
    ]);
    final rows = await db.query('app_logs', orderBy: 'id');
    expect(rows.map((row) => row['message']), ['start', 'failure', 'end']);
    expect(rows.map((row) => row['level']), ['INFO', 'ERROR', 'WARN']);
  });

  test('Disabled logging keeps errors while dropping routine batch entries',
      () async {
    await (await SharedPreferences.getInstance())
        .setBool('enable_logging', false);
    await history.insertRawLogs([
      (message: 'routine', level: 'INFO'),
      (message: 'failure', level: 'ERROR'),
    ]);
    expect((await db.query('app_logs')).single['message'], 'failure');
  });

  test('A batch rolls back all records when an insertion fails', () async {
    await db.execute(
        "CREATE TRIGGER fail_log BEFORE INSERT ON app_logs WHEN NEW.message = 'fail' "
        "BEGIN SELECT RAISE(ABORT, 'test failure'); END");
    await history.insertRawLogs([
      (message: 'first', level: 'INFO'),
      (message: 'fail', level: 'ERROR'),
    ]);
    expect(await db.query('app_logs'), isEmpty);
  });

  test('Storage failure does not throw into the calling operation', () async {
    await db.execute('DROP TABLE app_logs');
    await history.insertRawLogs([(message: 'failure', level: 'ERROR')]);
  });
}
