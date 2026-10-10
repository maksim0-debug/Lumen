import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:path/path.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:path_provider/path_provider.dart';

import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'preferences_helper.dart';
import 'schedule_clock.dart';
import 'schedule_change_notification_store.dart';
import 'android_fetch_coordinator.dart';

class HistoryService {
  static final HistoryService _instance = HistoryService._internal();
  factory HistoryService() => _instance;
  HistoryService._internal();
  HistoryService.forTesting(Database database) : _database = database;

  Database? _database;
  Future<Database>? _openingDatabase;

  /// Maximum number of log entries retained in SQLite database.
  static const int maxLogEntries = 1500;
  static const int _logPruneInterval = 50;
  int _logInsertCount = 0;
  bool _isPruning = false;

  Future<Database> get database async {
    if (_database != null && _database!.isOpen) return _database!;
    final opening = _openingDatabase ??= _initDatabase();
    try {
      return _database = await opening;
    } finally {
      if (identical(_openingDatabase, opening)) _openingDatabase = null;
    }
  }

  Future<String> get dbPath async {
    final documentsDirectory = await getApplicationDocumentsDirectory();
    return join(documentsDirectory.path, 'schedule_history.db');
  }

  Future<void> close() async {
    if (_database != null && _database!.isOpen) {
      await _database!.close();
      _database = null;
      AppLogger.d("Database closed", tag: 'HistoryService');
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
      version: 6,
      onCreate: (db, version) async {
        await ScheduleChangeNotificationStore.createSchema(db);
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
        if (oldVersion < 6) {
          await ScheduleChangeNotificationStore.createSchema(db);
        }
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
      onOpen: (db) async {
        await ScheduleChangeNotificationStore.createSchema(db);
        await AndroidFetchCoordinator.createSchema(db);
        // Ensure all required tables exist even if imported from legacy/partial backups
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

        // Verify and add is_manual column if missing in legacy power_events table
        final List<Map<String, dynamic>> columns =
            await db.rawQuery('PRAGMA table_info(power_events)');
        final hasIsManual =
            columns.any((column) => column['name'] == 'is_manual');
        if (!hasIsManual) {
          await db.execute(
              'ALTER TABLE power_events ADD COLUMN is_manual INTEGER DEFAULT 0');
        }

        // Seamless migration: normalize legacy timestamp strings with space to standard ISO-8601 ('T')
        await db.execute(
            "UPDATE power_events SET timestamp = replace(timestamp, ' ', 'T') WHERE timestamp LIKE '% %'");
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_power_events_timestamp ON power_events(timestamp)');
        await db.execute(
            'CREATE INDEX IF NOT EXISTS idx_schedule_history_group_date ON schedule_history(group_key, target_date)');

        // Enforce log retention policy on database open (caps logs at maxLogEntries)
        try {
          await _pruneLogs(db, maxLogEntries);
        } catch (_) {}
      },
    );
  }

  /// Direct, low-overhead database insertion for raw logs with automatic retention.
  Future<void> insertRawLog(String message, {String level = 'INFO'}) async {
    await insertRawLogs([(message: message, level: level)]);
  }

  /// One transaction per bounded diagnostic operation, rather than per stage.
  Future<void> insertRawLogs(
      Iterable<({String message, String level})> entries) async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final enabled = prefs.getBool('enable_logging') ?? true;
      final retained =
          entries.where((entry) => enabled || entry.level == 'ERROR').toList();
      if (retained.isEmpty) return;

      final db = await database;
      final timestamp = DateTime.now().toIso8601String();
      final batch = db.batch();
      for (final entry in retained) {
        batch.insert('app_logs', {
          'timestamp': timestamp,
          'level': entry.level,
          'message': entry.message,
        });
      }
      await batch.commit(noResult: true);

      _logInsertCount += retained.length;
      if (_logInsertCount >= _logPruneInterval) {
        _logInsertCount = 0;
        if (!_isPruning) {
          _isPruning = true;
          // Asynchronous background log pruning to prevent database bloat
          unawaited(
            pruneOldLogs(keep: maxLogEntries).whenComplete(() {
              _isPruning = false;
            }),
          );
        }
      }
    } catch (_) {
      // Ignored to avoid cascading errors during logging failure
    }
  }

  /// Trims old logs to prevent uncontrolled SQLite database growth.
  Future<int> pruneOldLogs({int keep = maxLogEntries}) async {
    try {
      final db = await database;
      return await _pruneLogs(db, keep);
    } catch (_) {
      return 0;
    }
  }

  /// Internal helper to execute log retention query on any open [DatabaseExecutor].
  static Future<int> _pruneLogs(DatabaseExecutor db, int keep) async {
    if (keep <= 0) {
      return await db.delete('app_logs');
    }
    return await db.rawDelete('''
      DELETE FROM app_logs 
      WHERE id NOT IN (
        SELECT id FROM app_logs ORDER BY id DESC LIMIT ?
      )
    ''', [keep]);
  }

  Future<void> logAction(String message, {String level = 'INFO'}) async {
    await insertRawLog(message, level: level);
    AppLogger.d(message, tag: 'HistoryService LOG');
  }

  Future<List<Map<String, dynamic>>> getLogs({int limit = 100}) async {
    final db = await database;
    return await db.query('app_logs', orderBy: 'id DESC', limit: limit);
  }

  Future<void> clearLogs() async {
    final db = await database;
    _logInsertCount = 0;
    await db.delete('app_logs');
  }

  /// A fetched snapshot is all-or-nothing; old responses cannot become latest history.
  Future<void> persistSnapshot({
    required Map<String, FullSchedule> schedules,
    required String todayDate,
    required String tomorrowDate,
    required String dtekUpdatedAt,
    Future<void> Function(Transaction)? afterPersist,
  }) async {
    final db = await database;
    final incoming = ScheduleClock.parseVersion(dtekUpdatedAt);
    final keys = schedules.keys.toList()..sort();
    final fingerprint = jsonEncode([
      todayDate,
      tomorrowDate,
      for (final key in keys)
        [
          key,
          schedules[key]!.today.toEncodedString(),
          schedules[key]!.tomorrow.toEncodedString()
        ]
    ]);
    await db.transaction((txn) async {
      // Kept separately from editable/imported history so those writers cannot reset the source watermark.
      await txn.execute('CREATE TABLE IF NOT EXISTS dtek_snapshot_state ('
          'id INTEGER PRIMARY KEY CHECK (id = 1), today_date TEXT NOT NULL, '
          'version INTEGER NOT NULL, fingerprint TEXT NOT NULL)');
      await txn.execute('CREATE TABLE IF NOT EXISTS dtek_current_schedule ('
          'group_key TEXT NOT NULL, target_date TEXT NOT NULL, history_id INTEGER NOT NULL, '
          'PRIMARY KEY (group_key, target_date))');
      final metadata = await txn.query('dtek_snapshot_state', where: 'id = 1');
      if (metadata.isNotEmpty) {
        final latest = metadata.single;
        final latestDate = latest['today_date'] as String;
        final latestVer = latest['version'] as int;
        if (todayDate.compareTo(latestDate) < 0 ||
            (todayDate == latestDate && incoming < latestVer)) {
          throw const FormatException('Older DTEK snapshot rejected');
        }
        if (incoming == latestVer &&
            todayDate == latestDate &&
            fingerprint != latest['fingerprint']) {
          throw const FormatException('Conflicting DTEK snapshot version');
        }
      }
      for (final entry in schedules.entries) {
        for (final day in [
          (todayDate, entry.value.today),
          (tomorrowDate, entry.value.tomorrow)
        ]) {
          final rows = await txn.query('schedule_history',
              where: 'group_key = ? AND target_date = ?',
              whereArgs: [entry.key, day.$1],
              orderBy: 'id DESC');
          // Bootstrap the watermark from source rows, excluding manual/time-only legacy records.
          if (metadata.isEmpty ||
              (metadata.single['today_date'] != todayDate &&
                  day.$1 == todayDate)) {
            for (final row in rows) {
              int version;
              try {
                version = ScheduleClock.parseVersion(
                    row['dtek_updated_at'] as String);
              } on FormatException {
                continue;
              }
              if (version > incoming) {
                throw const FormatException('Older DTEK snapshot rejected');
              }
              if (version == incoming &&
                  row['schedule_code'] != '9' * 24 &&
                  row['schedule_code'] != day.$2.toEncodedString()) {
                throw const FormatException(
                    'Conflicting DTEK snapshot version');
              }
            }
          }
          // An empty tomorrow is persisted as a tombstone; archived publications remain available.
          if (day.$2.isEmpty && rows.isEmpty) {
            continue;
          }
          Map<String, dynamic>? existing;
          for (final row in rows) {
            if (row['schedule_code'] != day.$2.toEncodedString()) continue;
            try {
              if (ScheduleClock.parseVersion(
                      row['dtek_updated_at'] as String) ==
                  incoming) {
                existing = row;
                break;
              }
            } on FormatException {
              // Manual/time-only rows are separate from source publications.
            }
          }
          if (existing != null) {
            await txn.insert(
                'dtek_current_schedule',
                {
                  'group_key': entry.key,
                  'target_date': day.$1,
                  'history_id': existing['id'],
                },
                conflictAlgorithm: ConflictAlgorithm.replace);
            continue;
          }
          final historyId = await txn.insert('schedule_history', {
            'group_key': entry.key,
            'target_date': day.$1,
            'schedule_code': day.$2.toEncodedString(),
            'dtek_updated_at': dtekUpdatedAt,
          });
          await txn.insert(
              'dtek_current_schedule',
              {
                'group_key': entry.key,
                'target_date': day.$1,
                'history_id': historyId,
              },
              conflictAlgorithm: ConflictAlgorithm.replace);
        }
      }
      await txn.insert(
          'dtek_snapshot_state',
          {
            'id': 1,
            'today_date': todayDate,
            'version': incoming,
            'fingerprint': fingerprint,
          },
          conflictAlgorithm: ConflictAlgorithm.replace);
      await afterPersist?.call(txn);
    });
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
      AppLogger.d(
          "Saved new version for $groupKey ($targetDate): $dtekUpdatedAt",
          tag: 'HistoryService');
    }
  }

  /// Imported archive rows must not override a fetched current snapshot. Explicit manual edits may.
  Future<Map<String, dynamic>?> _effectiveLatest(
      DatabaseExecutor db, String group, String date) async {
    final table = await db.rawQuery(
        "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'dtek_current_schedule'");
    if (table.isNotEmpty) {
      final pointer = await db.query('dtek_current_schedule',
          where: 'group_key = ? AND target_date = ?', whereArgs: [group, date]);
      if (pointer.isNotEmpty) {
        final sourceId = pointer.single['history_id'] as int;
        final current = await db.query('schedule_history',
            where:
                "group_key = ? AND target_date = ? AND (id = ? OR (id > ? AND dtek_updated_at LIKE '%(Manual)'))",
            whereArgs: [group, date, sourceId, sourceId],
            orderBy: 'id DESC',
            limit: 1);
        if (current.isNotEmpty) return current.single;
      }
    }
    final rows = await db.query('schedule_history',
        where: 'group_key = ? AND target_date = ?',
        whereArgs: [group, date],
        orderBy: 'id DESC');
    if (rows.isEmpty) return null;
    var latest = rows.first;
    int? version(Map<String, dynamic> row) {
      try {
        return ScheduleClock.parseVersion(row['dtek_updated_at'] as String);
      } on FormatException {
        return null;
      }
    }

    // Archive recovery inserts old publications after new ones. Without a
    // current pointer, use source chronology; retain legacy/manual ID ordering.
    final firstVersion = version(latest);
    if (firstVersion != null) {
      var best = firstVersion;
      for (final row in rows.skip(1)) {
        final candidate = version(row);
        if (candidate != null && candidate > best) {
          latest = row;
          best = candidate;
        }
      }
    }
    return latest;
  }

  Future<String?> getLatestUpdatedAt({
    required String groupKey,
    required String targetDate,
  }) async {
    final db = await database;

    final latest = await _effectiveLatest(db, groupKey, targetDate);
    if (latest != null) return latest['dtek_updated_at'] as String;
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

    final effectiveLatest = await _effectiveLatest(db, groupKey, dateStr);
    final orderedMaps = List<Map<String, dynamic>>.of(maps);
    // Recovery can insert older publications after a newer live push. Keep
    // source publications chronological while preserving legacy/manual slots.
    int? sourceVersion(Map<String, dynamic> row) {
      try {
        return ScheduleClock.parseVersion(row['dtek_updated_at'] as String);
      } on FormatException {
        return null;
      }
    }

    final sourceRows = orderedMaps
        .where((row) => sourceVersion(row) != null)
        .toList()
      ..sort((a, b) => sourceVersion(a)!.compareTo(sourceVersion(b)!));
    var sourceIndex = 0;
    for (var i = 0; i < orderedMaps.length; i++) {
      if (sourceVersion(orderedMaps[i]) != null) {
        orderedMaps[i] = sourceRows[sourceIndex++];
      }
    }
    if (effectiveLatest != null) {
      orderedMaps.removeWhere((row) => row['id'] == effectiveLatest['id']);
      orderedMaps.add(effectiveLatest);
    }

    List<ScheduleVersion> versions = [];
    for (var map in orderedMaps) {
      String timeStr = map['dtek_updated_at'] as String;
      DateTime savedAt;
      var hasReliableTimestamp = true;
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
          hasReliableTimestamp = savedAt.year == year &&
              savedAt.month == month &&
              savedAt.day == day &&
              savedAt.hour == h &&
              savedAt.minute == m;
        } else {
          // Fallback to just time (HH:mm)
          final RegExp exp = RegExp(r'(\d{1,2}):(\d{2})');
          final match = exp.firstMatch(timeStr);
          if (match != null) {
            int h = int.parse(match.group(1)!);
            int m = int.parse(match.group(2)!);
            savedAt = DateTime(date.year, date.month, date.day, h, m);
            hasReliableTimestamp = h >= 0 && h < 24 && m >= 0 && m < 60;
          } else {
            hasReliableTimestamp = false;
            savedAt = DateTime.now();
          }
        }
      } catch (e) {
        hasReliableTimestamp = false;
        savedAt = DateTime.now();
      }

      final schedule = DailySchedule.fromEncodedString(map['schedule_code']);

      versions.add(ScheduleVersion(
          recordId: map['id'] as int?,
          sourceUpdatedAt: timeStr,
          isManual: timeStr.endsWith('(Manual)'),
          hasReliableTimestamp: hasReliableTimestamp,
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
              } catch (e) {
                // Ignore invalid JSON item
              }
            } else if (item is Map) {
              // Already a map
              try {
                versionMap = Map<String, dynamic>.from(item);
              } catch (e) {
                // Ignore invalid map format
              }
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
                // Item import error ignored
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
      AppLogger.i(msg, tag: 'HistoryService');

      if (importedCount == 0 && data.isNotEmpty) {
        throw Exception(
            "No valid history records found. Checked ${data.length} keys.");
      }
    } catch (e) {
      AppLogger.e("Import error", tag: 'HistoryService', error: e);
      await logAction("Import error: $e", level: "ERROR");
      rethrow;
    }
  }

  Future<void> clearPowerEvents() async {
    final db = await database;
    await db.delete('power_events');
    AppLogger.d("Cleared power_events table.", tag: 'HistoryService');
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
      AppLogger.e("Migration error", tag: 'HistoryService', error: e);
    }
  }

  Future<String> exportDataRangeToJson(
      DateTime startDate, DateTime endDate) async {
    final db = await database;

    // Форматуємо дати для SQLite
    final startStr =
        "${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}";
    final endStr =
        "${endDate.year}-${endDate.month.toString().padLeft(2, '0')}-${endDate.day.toString().padLeft(2, '0')}";

    // 1. Отримуємо графіки
    final schedules = await db.query(
      'schedule_history',
      where: 'target_date >= ? AND target_date <= ?',
      whereArgs: [startStr, endStr],
    );

    // 2. Отримуємо реальні події сенсора
    final endNextDay = DateTime(endDate.year, endDate.month, endDate.day)
        .add(const Duration(days: 1));
    final endNextDayStr =
        "${endNextDay.year}-${endNextDay.month.toString().padLeft(2, '0')}-${endNextDay.day.toString().padLeft(2, '0')}";

    final events = await db.query(
      'power_events',
      where: 'timestamp >= ? AND timestamp < ?',
      whereArgs: ["${startStr}T00:00:00", "${endNextDayStr}T00:00:00"],
      orderBy: 'timestamp DESC',
    );

    // Пакуємо в єдиний JSON
    final Map<String, dynamic> exportData = {
      'version': 1,
      'export_date': DateTime.now().toIso8601String(),
      'schedules': schedules,
      'power_events': events,
    };

    return jsonEncode(exportData);
  }

  Future<int> importDataRangeFromJson(String jsonStr) async {
    final db = await database;
    final Map<String, dynamic> data = jsonDecode(jsonStr);

    if (data['version'] != 1) throw Exception("Непідтримуваний формат файлу");

    int importedCount = 0;
    final batch = db.batch();

    // 1. Імпорт графіків
    final schedules = data['schedules'] as List<dynamic>? ?? [];
    for (var s in schedules) {
      batch.insert(
        'schedule_history',
        {
          'group_key': s['group_key'],
          'target_date': s['target_date'],
          'schedule_code': s['schedule_code'],
          'dtek_updated_at': s['dtek_updated_at'],
        },
        conflictAlgorithm: ConflictAlgorithm.ignore,
      );
      importedCount++;
    }

    // 2. Імпорт подій сенсора з обов'язковою нормалізацією таймстампу до ISO-8601 ('T')
    final events = data['power_events'] as List<dynamic>? ?? [];
    for (var e in events) {
      final rawTimestamp = e['timestamp']?.toString() ?? '';
      final normalizedTimestamp = rawTimestamp.contains(' ')
          ? rawTimestamp.replaceFirst(' ', 'T')
          : rawTimestamp;

      batch.insert(
        'power_events',
        {
          'firebase_key': e['firebase_key'],
          'status': e['status'],
          'timestamp': normalizedTimestamp,
          'device': e['device'],
          'synced_at': e['synced_at'],
          'is_manual': e['is_manual'] ?? 0,
        },
        conflictAlgorithm:
            ConflictAlgorithm.ignore, // Ігноруємо дублікати по firebase_key
      );
      importedCount++;
    }

    await batch.commit(noResult: true);
    return importedCount;
  }

  Future<Map<String, FullSchedule>> getLastKnownSchedules() async {
    final db = await database;
    final Map<String, FullSchedule> result = {};
    final now = ScheduleClock.now();
    final tomorrow = ScheduleClock.day(now, 1);

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
      final todayRow = await _effectiveLatest(db, group, todayStr);
      DailySchedule todaySchedule = DailySchedule.empty();
      // Using a local var for lastUpdated to avoid conflict if I used it elsewhere
      String lastUpdatedText = "Немає (Offline/Cache)";

      if (todayRow != null) {
        final map = todayRow;
        todaySchedule = DailySchedule.fromEncodedString(map['schedule_code']);
        lastUpdatedText = map['dtek_updated_at'] ?? "Невідомо";
      }

      // 2. Get Tomorrow's schedule
      final tomorrowRow = await _effectiveLatest(db, group, tomorrowStr);
      DailySchedule tomorrowSchedule = DailySchedule.empty();
      if (tomorrowRow != null) {
        final map = tomorrowRow;
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

  /// Отримати список усіх унікальних дат, за які збережено дані (графіки або події)
  Future<List<String>> getAvailableDates() async {
    final db = await database;
    final List<Map<String, dynamic>> rows = await db.rawQuery('''
      SELECT DISTINCT target_date AS dt FROM schedule_history WHERE target_date IS NOT NULL
      UNION
      SELECT DISTINCT substr(timestamp, 1, 10) AS dt FROM power_events WHERE timestamp IS NOT NULL
      ORDER BY dt DESC
    ''');

    return rows
        .map((r) => r['dt'] as String?)
        .where((dt) => dt != null && dt.trim().isNotEmpty)
        .cast<String>()
        .toList();
  }

  /// Отримати дані експорту за період у вигляді Map (без зайвих JSON encode/decode циклів)
  Future<Map<String, dynamic>> getExportDataMap({
    DateTime? startDate,
    DateTime? endDate,
  }) async {
    final db = await database;

    String? schedWhere;
    List<dynamic>? schedArgs;
    String? eventWhere;
    List<dynamic>? eventArgs;

    if (startDate != null && endDate != null) {
      final startStr =
          "${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}";
      final endStr =
          "${endDate.year}-${endDate.month.toString().padLeft(2, '0')}-${endDate.day.toString().padLeft(2, '0')}";
      final endNextDay = DateTime(endDate.year, endDate.month, endDate.day)
          .add(const Duration(days: 1));
      final endNextDayStr =
          "${endNextDay.year}-${endNextDay.month.toString().padLeft(2, '0')}-${endNextDay.day.toString().padLeft(2, '0')}";

      schedWhere = 'target_date >= ? AND target_date <= ?';
      schedArgs = [startStr, endStr];
      eventWhere = 'timestamp >= ? AND timestamp < ?';
      eventArgs = ["${startStr}T00:00:00", "${endNextDayStr}T00:00:00"];
    }

    final schedules = await db.query(
      'schedule_history',
      where: schedWhere,
      whereArgs: schedArgs,
      orderBy: 'target_date DESC, id DESC',
    );

    final events = await db.query(
      'power_events',
      where: eventWhere,
      whereArgs: eventArgs,
      orderBy: 'timestamp DESC',
    );

    return {
      'version': 1,
      'export_date': DateTime.now().toUtc().toIso8601String(),
      'filters': {
        'from': startDate != null
            ? "${startDate.year}-${startDate.month.toString().padLeft(2, '0')}-${startDate.day.toString().padLeft(2, '0')}"
            : null,
        'to': endDate != null
            ? "${endDate.year}-${endDate.month.toString().padLeft(2, '0')}-${endDate.day.toString().padLeft(2, '0')}"
            : null,
      },
      'schedules_count': schedules.length,
      'events_count': events.length,
      'schedules': schedules,
      'power_events': events,
    };
  }
}
