import 'dart:io';
import 'dart:convert';
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

  Future<int> importHistoryJson() async {
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
      final Map<String, dynamic> data = jsonDecode(content);

      int count = 0;

      for (var entry in data.entries) {
        final key = entry.key; // e.g. history_v2_2025-12-06_GPV3.2
        final list = entry.value as List;

        if (list.isEmpty) continue;

        for (var item in list) {
          final hash = item['hash'];
          final savedAt = item['savedAt'];

          // Key format: history_v2_DATE_GROUP
          final parts = key.split('_');
          if (parts.length >= 4) {
            final date = parts[2];
            final group = parts[3];

            // --- LOGIC: Overwrite OLD data (< Jan 19), Preserve NEW data (>= Jan 19) ---
            DateTime? parsedDate;
            try {
              parsedDate = DateTime.parse(date);
            } catch (_) {}

            final db = await _historyService.database;

            // Cutoff date: Jan 19, 2026
            final cutoff = DateTime(2026, 1, 19);

            if (parsedDate != null && parsedDate.isBefore(cutoff)) {
              // OLD DATA: Force overwrite (delete existing first to remove "bad" data)
              await db.delete(
                'schedule_history',
                where: 'group_key = ? AND target_date = ?',
                whereArgs: [group, date],
              );
            } else {
              // NEW DATA (or parse error): Safety Check - Do NOT overwrite
              final List<Map<String, dynamic>> existing = await db.query(
                'schedule_history',
                columns: ['id'],
                where: 'group_key = ? AND target_date = ?',
                whereArgs: [group, date],
                limit: 1,
              );
              if (existing.isNotEmpty) {
                continue;
              }
            }

            await _historyService.persistVersion(
                groupKey: group,
                targetDate: date,
                scheduleCode: hash,
                dtekUpdatedAt: savedAt);
            count++;
          }
        }
      }
      return count;
    } catch (e) {
      print("JSON Import error: $e");
      rethrow;
    }
  }
}
