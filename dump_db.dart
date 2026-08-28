import 'dart:io';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path/path.dart';

void main() async {
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;

  final userProfile = Platform.environment['USERPROFILE'];
  final dbPath = join(userProfile!, 'Documents', 'schedule_history.db');

  stdout.writeln("Opening DB at $dbPath");

  try {
    final db = await databaseFactory.openDatabase(dbPath);

    final countResult = await db.rawQuery('SELECT COUNT(*) FROM power_events');
    final count = countResult.first.values.first as int;
    stdout.writeln("Total events: $count");

    final events = await db.query('power_events', orderBy: 'timestamp ASC');
    stdout.writeln("\n--- Power Events ---");
    for (var e in events) {
      stdout.writeln(
          "ID: ${e['id']} | Status: ${e['status']} | TS: ${e['timestamp']} | Manual: ${e['is_manual']} | Key: ${e['firebase_key']}");
    }

    await db.close();
  } catch (e) {
    stdout.writeln("Error: $e");
  }
}
