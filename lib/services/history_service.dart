import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';

import '../models/schedule_status.dart';
import 'preferences_helper.dart';

class HistoryService {
  static final HistoryService _instance = HistoryService._internal();
  factory HistoryService() => _instance;
  HistoryService._internal();

  Database? _database;

  Future<Database> get database async {
    if (_database != null && _database!.isOpen) return _database!;
    _database = await _initDatabase();
    return _database!;
  }

  Future<String> get dbPath async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    return join(documentsDirectory.path, 'schedule_history.db');
  }

  Future<void> close() async {
    if (_database != null && _database!.isOpen) {
      await _database!.close();
      _database = null;
      print("[HistoryService] Database closed");
    }
  }

  Future<Database> _initDatabase() async {
    if (Platform.isWindows || Platform.isLinux) {
      sqfliteFfiInit();
      databaseFactory = databaseFactoryFfi;
    }

    final documentsDirectory = await getApplicationDocumentsDirectory();
    final path = join(documentsDirectory.path, 'schedule_history.db');

    return await openDatabase(
      path,
      version: 4,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE IF NOT EXISTS schedule_history (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            group_key TEXT,
            target_date TEXT,
            schedule_code TEXT,
            dtek_updated_at TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS app_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT,
            level TEXT,
            message TEXT
          )
        ''');
        await db.execute('''
          CREATE TABLE IF NOT EXISTS power_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            firebase_key TEXT UNIQUE,
            status TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            device TEXT,
            synced_at TEXT,
            is_manual INTEGER DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          await db.execute('''
          CREATE TABLE IF NOT EXISTS app_logs (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp TEXT,
            level TEXT,
            message TEXT
          )
        ''');
        }
        if (oldVersion < 3) {
          await db.execute('''
          CREATE TABLE IF NOT EXISTS power_events (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            firebase_key TEXT UNIQUE,
            status TEXT NOT NULL,
            timestamp TEXT NOT NULL,
            device TEXT,
            synced_at TEXT
          )
        ''');
        }
        if (oldVersion < 4) {
          // Check if column already exists to prevent crash
          final List<Map<String, dynamic>> columns =
              await db.rawQuery('PRAGMA table_info(power_events)');
          final hasIsManual =
              columns.any((column) => column['name'] == 'is_manual');
          if (!hasIsManual) {
            await db.execute(
                'ALTER TABLE power_events ADD COLUMN is_manual INTEGER DEFAULT 0');
          }
        }
      },
    );
  }

  Future<void> logAction(String message, {String level = 'INFO'}) async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final enabled = prefs.getBool('enable_logging') ?? true;
      if (!enabled && level != 'ERROR') return; // Always log errors

      final db = await database;
      await db.insert('app_logs', {
        'timestamp': DateTime.now().toIso8601String(),
        'level': level,
        'message': message,
      });
      print("[HistoryService LOG] $message");
    } catch (e) {
      print("[HistoryService] Failed to log: $e");
    }
  }

  Future<List<Map<String, dynamic>>> getLogs({int limit = 100}) async {
    final db = await database;
    return await db.query('app_logs', orderBy: 'id DESC', limit: limit);
  }

  Future<void> clearLogs() async {
    final db = await database;
    await db.delete('app_logs');
  }

  Future<void> persistVersion({
    required String groupKey,
    required String targetDate,
    required String scheduleCode,
    required String dtekUpdatedAt,
  }) async {
    final db = await database;

    final List<Map<String, dynamic>> maps = await db.query(
      'schedule_history',
      where: 'group_key = ? AND target_date = ? AND dtek_updated_at = ?',
      whereArgs: [groupKey, targetDate, dtekUpdatedAt],
    );

    if (maps.isEmpty) {
      await db.insert(
        'schedule_history',
        {
          'group_key': groupKey,
          'target_date': targetDate,
          'schedule_code': scheduleCode,
          'dtek_updated_at': dtekUpdatedAt,
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      print(
          "[HistoryService] Saved new version for $groupKey ($targetDate): $dtekUpdatedAt");
    }
  }

  Future<String?> getLatestUpdatedAt({
    required String groupKey,
    required String targetDate,
  }) async {
    final db = await database;

    final List<Map<String, dynamic>> maps = await db.query(
      'schedule_history',
      columns: ['dtek_updated_at'],
      where: 'group_key = ? AND target_date = ?',
      whereArgs: [groupKey, targetDate],
      orderBy: 'id DESC',
      limit: 1,
    );

    if (maps.isNotEmpty) {
      return maps.first['dtek_updated_at'] as String;
    }
    return null;
  }

  Future<List<ScheduleVersion>> getVersionsForDate(
      DateTime date, String groupKey) async {
    final db = await database;
    final dateStr =
        "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";

    // Always try to migrate first to ensure we have all data (including Today if mixed)
    await _tryMigrateFromPrefs(date, groupKey);

    final List<Map<String, dynamic>> maps = await db.query(
      'schedule_history',
      where: 'group_key = ? AND target_date = ?',
      whereArgs: [groupKey, dateStr],
      orderBy: 'id ASC',
    );

    List<ScheduleVersion> versions = [];
    for (var map in maps) {
      String timeStr = map['dtek_updated_at'] as String;
      DateTime savedAt;
      try {
        // Try to find full date-time first (DD.MM.YYYY HH:mm)
        // Matches: 27.01.2026 19:54 or 27.01.26 19:54
        final RegExp dateExp =
            RegExp(r'(\d{2})\.(\d{2})\.(\d{2,4})\s+(\d{1,2}):(\d{2})');
        final dateMatch = dateExp.firstMatch(timeStr);

        if (dateMatch != null) {
          int day = int.parse(dateMatch.group(1)!);
          int month = int.parse(dateMatch.group(2)!);
          int year = int.parse(dateMatch.group(3)!);
          if (year < 100) year += 2000;
          int h = int.parse(dateMatch.group(4)!);
          int m = int.parse(dateMatch.group(5)!);
          savedAt = DateTime(year, month, day, h, m);
        } else {
          // Fallback to just time (HH:mm)
          final RegExp exp = RegExp(r'(\d{1,2}):(\d{2})');
          final match = exp.firstMatch(timeStr);
          if (match != null) {
            int h = int.parse(match.group(1)!);
            int m = int.parse(match.group(2)!);
            savedAt = DateTime(date.year, date.month, date.day, h, m);
          } else {
            savedAt = DateTime.now();
          }
        }
      } catch (e) {
        savedAt = DateTime.now();
      }

      final schedule = DailySchedule.fromEncodedString(map['schedule_code']);

      versions.add(ScheduleVersion(
          hash: map['schedule_code'],
          savedAt: savedAt,
          outageMinutes: schedule.totalOutageMinutes));
    }

    return versions;
  }

  Future<void> importHistoryFromJson(String jsonStr) async {
    try {
      if (jsonStr.trim().isEmpty) throw Exception("Empty JSON string");

      final Map<String, dynamic> data = jsonDecode(jsonStr);
      int importedCount = 0;
      int skippedCount = 0;

      for (var entry in data.entries) {
        String key = entry.key;

        // Handle raw shared_preferences.json prefixes (e.g. "flutter.")
        if (key.startsWith("flutter.")) {
          key = key.substring(8);
        }

        // Only process history keys
        final isV2 = key.startsWith("history_v2_");
        final isV1 = !isV2 &&
            key.startsWith("history_"); // e.g. history_2026-01-19_GPV1.1

        if (!isV2 && !isV1) continue;

        final parts = key.split('_');
        // V2: history, v2, DATE, GROUP
        // V1: history, DATE, GROUP

        String dateStr;
        String groupKey;

        if (isV2) {
          if (parts.length < 4) continue;
          dateStr = parts[2];
          groupKey = parts[3];
        } else {
          if (parts.length < 3) continue;
          dateStr = parts[1];
          groupKey = parts[2];
        }

        var value = entry.value;

        // Handle double-encoded values (common in raw config files)
        if (value is String) {
          try {
            if (value.startsWith("[") || value.startsWith("{")) {
              value = jsonDecode(value);
            }
          } catch (e) {
            // If decode fails, it might be a simple V1 string "10101..."
          }
        }

        if (isV2) {
          if (value is! List) {
            skippedCount++;
            continue;
          }

          for (var item in value) {
            Map<String, dynamic>? versionMap;

            if (item is String) {
              try {
                versionMap = jsonDecode(item);
              } catch (e) {}
            } else if (item is Map) {
              // Already a map
              try {
                versionMap = Map<String, dynamic>.from(item);
              } catch (e) {}
            }

            if (versionMap != null) {
              try {
                final version = ScheduleVersion.fromJson(versionMap);

                await persistVersion(
                    groupKey: groupKey,
                    targetDate: dateStr,
                    scheduleCode: version.hash,
                    dtekUpdatedAt:
                        "${version.savedAt.hour}:${version.savedAt.minute.toString().padLeft(2, '0')}");
                importedCount++;
              } catch (e) {
                // print("Item import error: $e");
              }
            }
          }
        } else {
          // V1 - Value might be String or Number if pure digits
          String code = value.toString();
          if (code.length >= 24) {
            try {
              // V1 didn't track save time, so we assume 00:00
              await persistVersion(
                  groupKey: groupKey,
                  targetDate: dateStr,
                  scheduleCode: code,
                  dtekUpdatedAt: "00:00");
              importedCount++;
            } catch (e) {
              skippedCount++;
            }
          }
        }
      }

      final msg =
          "Import finished: $importedCount records imported, $skippedCount keys skipped.";
      await logAction(msg);
      print("[HistoryService] $msg");

      if (importedCount == 0 && data.isNotEmpty) {
        throw Exception(
            "No valid history records found. Checked ${data.length} keys.");
      }
    } catch (e) {
      print("Import error: $e");
      await logAction("Import error: $e", level: "ERROR");
      throw e;
    }
  }

  Future<void> clearPowerEvents() async {
    final db = await database;
    await db.delete('power_events');
    print("[HistoryService] Cleared power_events table.");
  }

  Future<String> exportHistoryToJson() async {
    final Map<String, dynamic> exportData = {};

    // 1. Export from Database (Primary Source)
    try {
      final db = await database;
      final List<Map<String, dynamic>> rows =
          await db.query('schedule_history');

      for (var row in rows) {
        try {
          String group = row['group_key'];
          String date = row['target_date']; // YYYY-MM-DD
          String code = row['schedule_code'];
          String time = row['dtek_updated_at']; // H:mm

          final key = "history_v2_${date}_$group";

          // Reconstruct DateTime
          final dParts = date.split('-');
          final tParts = time.split(':');
          final dt = DateTime(int.parse(dParts[0]), int.parse(dParts[1]),
              int.parse(dParts[2]), int.parse(tParts[0]), int.parse(tParts[1]));

          // Reconstruct ScheduleVersion
          final sch = DailySchedule.fromEncodedString(code);
          final ver = ScheduleVersion(
              hash: code, savedAt: dt, outageMinutes: sch.totalOutageMinutes);

          if (!exportData.containsKey(key)) {
            exportData[key] = <String>[];
          }
          (exportData[key] as List).add(jsonEncode(ver.toJson()));
        } catch (e) {
          // Skip malformed DB row
        }
      }
    } catch (e) {
      await logAction("Export DB Error: $e", level: "WARN");
    }

    // 2. Export from SharedPreferences (Legacy/Fallback)
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final keys = prefs.getKeys();

      for (String key in keys) {
        if (key.startsWith("history_v2_")) {
          // Verify format is List<String>
          try {
            final list = prefs.getStringList(key);
            if (list == null) continue;

            if (!exportData.containsKey(key)) {
              exportData[key] = list;
            } else {
              // Combine? For now, DB takes precedence so we skip if present.
              // Or we can append unique items? Too complex for now.
            }
          } catch (_) {}
        }
      }
    } catch (e) {
      await logAction("Export Prefs Error: $e", level: "WARN");
    }

    return jsonEncode(exportData);
  }

  Future<void> _tryMigrateFromPrefs(DateTime date, String groupKey) async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final dateStr =
          "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";
      final key = "history_v2_${dateStr}_$groupKey";

      // Mark as migrated to avoid re-reading prefs every time?
      // Or just rely on persistVersion skipping duplicates. Relying on persistVersion is safer.

      final List<String>? list = prefs.getStringList(key);
      if (list == null || list.isEmpty) return;

      int migratedCount = 0;
      for (String jsonStr in list) {
        try {
          final version = ScheduleVersion.fromJson(jsonDecode(jsonStr));

          // Persist to DB
          await persistVersion(
              groupKey: groupKey,
              targetDate: dateStr,
              scheduleCode: version.hash,
              dtekUpdatedAt:
                  "${version.savedAt.hour}:${version.savedAt.minute.toString().padLeft(2, '0')}");
          migratedCount++;
        } catch (e) {/* ignore corrupt data */}
      }
      if (migratedCount > 0) {
        await logAction(
            "CheckMigrate: processed $migratedCount records for $groupKey $dateStr");
      }
    } catch (e) {
      print("Migration error: $e");
    }
  }

  Future<Map<String, FullSchedule>> getLastKnownSchedules() async {
    final db = await database;
    final Map<String, FullSchedule> result = {};
    final now = DateTime.now();
    final tomorrow = now.add(const Duration(days: 1));

    final todayStr =
        "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";
    final tomorrowStr =
        "${tomorrow.year}-${tomorrow.month.toString().padLeft(2, '0')}-${tomorrow.day.toString().padLeft(2, '0')}";

    // Define all groups to iterate over
    const List<String> allGroups = [
      "GPV1.1",
      "GPV1.2",
      "GPV2.1",
      "GPV2.2",
      "GPV3.1",
      "GPV3.2",
      "GPV4.1",
      "GPV4.2",
      "GPV5.1",
      "GPV5.2",
      "GPV6.1",
      "GPV6.2",
    ];

    for (String group in allGroups) {
      // 1. Get Today's schedule
      final List<Map<String, dynamic>> todayMaps = await db.query(
        'schedule_history',
        where: 'group_key = ? AND target_date = ?',
        whereArgs: [group, todayStr],
        orderBy: 'id DESC', // Get the latest version
        limit: 1,
      );

      DailySchedule todaySchedule = DailySchedule.empty();
      // Using a local var for lastUpdated to avoid conflict if I used it elsewhere
      String lastUpdatedText = "Немає (Offline/Cache)";

      if (todayMaps.isNotEmpty) {
        final map = todayMaps.first;
        todaySchedule = DailySchedule.fromEncodedString(map['schedule_code']);
        lastUpdatedText = map['dtek_updated_at'] ?? "Невідомо";
      }

      // 2. Get Tomorrow's schedule
      final List<Map<String, dynamic>> tomorrowMaps = await db.query(
        'schedule_history',
        where: 'group_key = ? AND target_date = ?',
        whereArgs: [group, tomorrowStr],
        orderBy: 'id DESC', // Get the latest version
        limit: 1,
      );

      DailySchedule tomorrowSchedule = DailySchedule.empty();
      if (tomorrowMaps.isNotEmpty) {
        final map = tomorrowMaps.first;
        tomorrowSchedule =
            DailySchedule.fromEncodedString(map['schedule_code']);
      }

      // If we found at least something, add to result
      if (!todaySchedule.isEmpty || !tomorrowSchedule.isEmpty) {
        result[group] = FullSchedule(
          today: todaySchedule,
          tomorrow: tomorrowSchedule,
          lastUpdatedSource: lastUpdatedText, // This will be the "cache" time
        );
      }
    }

    return result;
  }
}
