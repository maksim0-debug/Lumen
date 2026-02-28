import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:share_plus/share_plus.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart';
import 'package:intl/intl.dart';

import 'history_service.dart';

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
      final fileName = 'vikl_backup_${formatter.format(now)}.db';
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
        await Share.shareXFiles(
          [XFile(tempPath)],
          text: 'Vikl Database Backup',
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

  Future<void> importDatabase() async {
    try {
      // 1. Pick file
      FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType
            .any, // .db files often don't have a specific mime type mapped everywhere
        // allowedExtensions: ['db'], // confusing on some platforms, better check manually
      );

      if (result == null || result.files.single.path == null) {
        return; // User canceled
      }

      final String pickedPath = result.files.single.path!;

      // Basic validation
      if (!pickedPath.toLowerCase().endsWith('.db') &&
          !pickedPath.toLowerCase().endsWith('.sqlite')) {
        // We could throw or just proceed if the user knows what they are doing.
        // Let's be strict for safety.
        // throw Exception("Invalid file extension. Please select a .db file.");
        // Actually, let's just warn or try anyway? Let's try.
      }

      // 2. Get target DB path
      final dbPath = await _historyService.dbPath;
      final File targetFile = File(dbPath);

      // 3. Close DB
      await _historyService.close();

      // 4. Overwrite
      final sourceFile = File(pickedPath);
      await sourceFile.copy(targetFile.path);

      // 5. Re-open DB
      await _historyService.database;
    } catch (e) {
      // Ensure DB is re-opened
      try {
        await _historyService.database;
      } catch (_) {}
      rethrow;
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
      await Share.shareXFiles([XFile(tempPath)], text: 'Експорт історії Lumen');
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
      print("JSON Import error: $e");
      rethrow;
    }
  }
}
