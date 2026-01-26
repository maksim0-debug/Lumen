import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/schedule_status.dart';

class HistoryService {
  static final HistoryService _instance = HistoryService._internal();
  factory HistoryService() => _instance;
  HistoryService._internal();

  
  static const int _maxVersionsPerDay = 50;

  
  
  Future<void> saveHistory(Map<String, FullSchedule> allSchedules) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final now = DateTime.now();
      final dateKey =
          "${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}";

      for (var entry in allSchedules.entries) {
        final group = entry.key;
        final schedule = entry.value;

        
        final key = "history_v2_${dateKey}_$group";

        
        List<ScheduleVersion> versions = await _loadVersions(prefs, key);

        
        final newVersion =
            ScheduleVersion.fromSchedule(schedule.today, at: now);

        
        if (versions.isEmpty || versions.last.hash != newVersion.hash) {
          versions.add(newVersion);

          
          if (versions.length > _maxVersionsPerDay) {
            versions = versions.sublist(versions.length - _maxVersionsPerDay);
          }

          
          await _saveVersions(prefs, key, versions);
          print(
              "[HistoryService] Нова версія збережена: $group (всього: ${versions.length})");
        } else {
          print("[HistoryService] Хеш не змінився для $group, пропускаємо");
        }
      }
    } catch (e) {
      print("[HistoryService] Error saving history: $e");
    }
  }

  
  Future<List<ScheduleVersion>> getVersionsForDate(
      DateTime date, String group) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final dateKey =
          "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";

      
      final keyV2 = "history_v2_${dateKey}_$group";
      List<ScheduleVersion> versions = await _loadVersions(prefs, keyV2);

      if (versions.isNotEmpty) {
        return versions;
      }

      
      final keyOld = "history_${dateKey}_$group";
      if (prefs.containsKey(keyOld)) {
        final encoded = prefs.getString(keyOld);
        if (encoded != null && encoded.length == 24) {
          
          final schedule = DailySchedule.fromEncodedString(encoded);
          final version = ScheduleVersion(
            hash: encoded,
            savedAt:
                DateTime(date.year, date.month, date.day, 0, 0), 
            outageMinutes: schedule.totalOutageMinutes,
          );
          return [version];
        }
      }

      return [];
    } catch (e) {
      print("[HistoryService] Error loading versions: $e");
      return [];
    }
  }

  
  
  Future<DailySchedule?> getHistoryForDate(DateTime date, String group) async {
    final versions = await getVersionsForDate(date, group);
    if (versions.isEmpty) return null;
    return versions.last.toSchedule();
  }

  
  Future<DailySchedule?> getVersionByIndex(
      DateTime date, String group, int index) async {
    final versions = await getVersionsForDate(date, group);
    if (index < 0 || index >= versions.length) return null;
    return versions[index].toSchedule();
  }

  

  Future<List<ScheduleVersion>> _loadVersions(
      SharedPreferences prefs, String key) async {
    try {
      if (!prefs.containsKey(key)) return [];

      await prefs.reload(); 
      final jsonStr = prefs.getString(key);
      if (jsonStr == null || jsonStr.isEmpty) return [];

      final List<dynamic> jsonList = jsonDecode(jsonStr);
      return jsonList
          .map((j) => ScheduleVersion.fromJson(j as Map<String, dynamic>))
          .toList();
    } catch (e) {
      print("[HistoryService] Error parsing versions: $e");
      return [];
    }
  }

  Future<void> _saveVersions(SharedPreferences prefs, String key,
      List<ScheduleVersion> versions) async {
    final jsonList = versions.map((v) => v.toJson()).toList();
    await prefs.setString(key, jsonEncode(jsonList));
  }

  
  Future<List<DateTime>> getAvailableDates(String group,
      {int daysBack = 30}) async {
    final prefs = await SharedPreferences.getInstance();
    final available = <DateTime>[];
    final now = DateTime.now();

    for (int i = 0; i < daysBack; i++) {
      final date = now.subtract(Duration(days: i));
      final dateKey =
          "${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}";

      final keyV2 = "history_v2_${dateKey}_$group";
      final keyOld = "history_${dateKey}_$group";

      if (prefs.containsKey(keyV2) || prefs.containsKey(keyOld)) {
        available.add(DateTime(date.year, date.month, date.day));
      }
    }

    return available;
  }
}
