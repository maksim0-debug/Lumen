import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'package:intl/intl.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'app_logger.dart';
import 'history_service.dart';
import 'power_monitor_service.dart';

class BackupService {
  final HistoryService _historyService = HistoryService();

  Future<String?> exportDatabase() async {
    try {
      // 1. Get current DB path
      final dbPath = await _historyService.dbPath;
      final File dbFile = File(dbPath);

      if (!await dbFile.exists()) {
        throw Exception("Database file not found at $dbPath");
      }

      // 2. Close DB connection to ensure data integrity
      await _historyService.close();

      // 3. Create a temporary copy with a user-friendly name
      final tempDir = await getTemporaryDirectory();
      final now = DateTime.now();
      final formatter = DateFormat('yyyy-MM-dd_HH-mm');
      final fileName = 'lumen_backup_${formatter.format(now)}.db';
      final tempPath = join(tempDir.path, fileName);

      await dbFile.copy(tempPath);

      if (Platform.isWindows) {
        // Windows: Save to Downloads
        final downloadsDir = await getDownloadsDirectory();
        if (downloadsDir == null) {
          throw Exception("Downloads directory not found");
        }
        final finalPath = join(downloadsDir.path, fileName);
        await File(tempPath).copy(finalPath);

        // Re-open DB
        await _historyService.database;

        return finalPath;
      } else {
        // Mobile: Share the file
        await SharePlus.instance.share(
          ShareParams(
            text: 'Lumen Database Backup',
            files: [XFile(tempPath)],
          ),
        );

        // Re-open DB
        await _historyService.database;
        return null;
      }
    } catch (e) {
      // Ensure DB is re-opened even if export fails
      try {
        await _historyService.database;
      } catch (_) {}
      rethrow;
    }
  }

  Future<void> importDatabase([String? explicitPath]) async {
    bool pollingWasPaused = false;
    File? bakFile;
    File? targetFile;

    try {
      String? pickedPath = explicitPath;
      if (pickedPath == null) {
        // Pick file
        FilePickerResult? result = await FilePicker.platform.pickFiles(
          type: FileType.any,
        );

        if (result == null || result.files.single.path == null) {
          return; // User canceled
        }
        pickedPath = result.files.single.path!;
      }

      final sourceFile = File(pickedPath);
      if (!await sourceFile.exists()) {
        throw Exception(
            "Файл резервної копії не знайдено за шляхом $pickedPath");
      }

      // Pre-flight validation: check that the file is a valid SQLite DB with relevant tables
      bool isValidSqlite = false;
      try {
        if (Platform.isWindows || Platform.isLinux) {
          sqfliteFfiInit();
          databaseFactory = databaseFactoryFfi;
        }
        final testDb = await openReadOnlyDatabase(pickedPath);
        final tables = await testDb.rawQuery(
          "SELECT name FROM sqlite_master WHERE type='table' AND name IN ('schedule_history', 'power_events', 'app_logs')",
        );
        isValidSqlite = tables.isNotEmpty;
        await testDb.close();
      } catch (err) {
        AppLogger.w("Pre-flight SQLite check warning: $err",
            tag: 'BackupService');
      }

      if (!isValidSqlite) {
        throw Exception(
            "Обраний файл не є дійсною базою даних або не містить збережених даних розкладу/відключень.");
      }

      // 1. Pause background power monitoring to avoid file lock collisions on Windows
      PowerMonitorService().stopPolling();
      pollingWasPaused = true;

      // 2. Target DB path
      final dbPath = await _historyService.dbPath;
      targetFile = File(dbPath);

      // 3. Close current DB
      await _historyService.close();

      // 4. Transactional safety: create backup of the existing target DB before overwrite
      if (await targetFile.exists()) {
        bakFile = File('${targetFile.path}.bak');
        await targetFile.copy(bakFile.path);
      }

      // 5. Clean up any stale WAL/SHM journaling artifacts before overwriting
      final walFile = File('${targetFile.path}-wal');
      if (await walFile.exists()) {
        await walFile.delete();
      }
      final shmFile = File('${targetFile.path}-shm');
      if (await shmFile.exists()) {
        await shmFile.delete();
      }

      // 6. Overwrite target with imported DB
      await sourceFile.copy(targetFile.path);

      // 7. Re-open DB (triggers onOpen resilient migrations and timestamp normalizations)
      await _historyService.database;

      // 8. Import succeeded! Delete the safety backup
      if (bakFile != null && await bakFile.exists()) {
        await bakFile.delete();
      }

      // 9. Refresh memory cache and power monitor snapshot from newly imported local DB
      try {
        await PowerMonitorService().reloadStatusFromLocal();
      } catch (e) {
        AppLogger.w(
            "Could not reload power monitor status immediately after DB restore: $e",
            tag: 'BackupService');
      }
    } catch (e) {
      AppLogger.e("Database import failed, initiating rollback: $e",
          tag: 'BackupService', error: e);

      // ROLLBACK: Restore from .bak if target replacement failed
      if (bakFile != null && await bakFile.exists() && targetFile != null) {
        try {
          await bakFile.copy(targetFile.path);
          await bakFile.delete();
          AppLogger.i("Database rollback successfully restored previous state",
              tag: 'BackupService');
        } catch (rbErr) {
          AppLogger.e("Failed to restore from .bak during rollback: $rbErr",
              tag: 'BackupService', error: rbErr);
        }
      }

      // Ensure DB is re-opened in any case
      try {
        await _historyService.database;
      } catch (_) {}

      rethrow;
    } finally {
      // Re-enable polling if monitor is enabled and polling was paused
      if (pollingWasPaused && PowerMonitorService().isEnabled) {
        PowerMonitorService().startPolling();
      }
    }
  }

  Future<String?> exportPartialHistory(DateTime start, DateTime end) async {
    final jsonStr = await _historyService.exportDataRangeToJson(start, end);

    final tempDir = await getTemporaryDirectory();
    final fileName = 'lumen_history_${end.year}-${end.month}-${end.day}.json';
    final tempPath = join(tempDir.path, fileName);

    final file = File(tempPath);
    await file.writeAsString(jsonStr);

    if (Platform.isWindows) {
      final downloadsDir = await getDownloadsDirectory();
      if (downloadsDir == null) {
        throw Exception("Downloads directory not found");
      }
      final finalPath = join(downloadsDir.path, fileName);
      await file.copy(finalPath);
      return finalPath;
    } else {
      await SharePlus.instance.share(
        ShareParams(
          text: 'Експорт історії Lumen',
          files: [XFile(tempPath)],
        ),
      );
      return null;
    }
  }

  Future<int> importPartialHistory() async {
    try {
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['json'],
      );

      if (result == null || result.files.single.path == null) {
        return 0;
      }

      final file = File(result.files.single.path!);
      final content = await file.readAsString();

      return await _historyService.importDataRangeFromJson(content);
    } catch (e) {
      AppLogger.e("JSON Import error", tag: 'BackupService', error: e);
      rethrow;
    }
  }
}
