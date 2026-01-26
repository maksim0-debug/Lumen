import 'dart:io';
import 'package:home_widget/home_widget.dart';
import '../models/schedule_status.dart';

class WidgetService {
  static final WidgetService _instance = WidgetService._internal();
  factory WidgetService() => _instance;
  WidgetService._internal();

  Future<void> updateWidget(Map<String, FullSchedule> allSchedules) async {
    if (!Platform.isAndroid) return;

    print("[WidgetService] Оновлення даних для віджетів...");

    try {
      for (var entry in allSchedules.entries) {
        String groupKey = entry.key; 
        FullSchedule schedule = entry.value;

        await HomeWidget.saveWidgetData<String>(
            'schedule_$groupKey', schedule.today.toEncodedString());
        await HomeWidget.saveWidgetData<String>(
            'schedule_tomorrow_$groupKey', schedule.tomorrow.toEncodedString());
      }

      if (allSchedules.isNotEmpty) {
        String lastUpdate = allSchedules.values.first.lastUpdatedSource;
        if (lastUpdate.contains(" ")) {
          lastUpdate = lastUpdate.split(" ").last;
        }
        await HomeWidget.saveWidgetData<String>('last_update_time', lastUpdate);

        final now = DateTime.now();
        final dateStr = "${now.year}-${now.month}-${now.day}";
        await HomeWidget.saveWidgetData<String>('last_update_date', dateStr);

        for (int i = 1; i <= 12; i++) {
          await HomeWidget.saveWidgetData<bool>('is_loading_$i', false);
        }
      }

      final providers = [
        'LightScheduleWidgetProvider',
        'LightScheduleWidgetProvider2',
        'LightScheduleWidgetProvider3',
        'LightScheduleWidgetProvider4',
        'LightScheduleWidgetProvider5',
        'LightScheduleWidgetProvider6',
        'LightScheduleWidgetProvider7',
        'LightScheduleWidgetProvider8',
        'LightScheduleWidgetProvider9',
        'LightScheduleWidgetProvider10',
        'LightScheduleWidgetProvider11',
        'LightScheduleWidgetProvider12',
      ];

      for (var provider in providers) {
        await HomeWidget.updateWidget(
          androidName: provider,
        );
      }

      print("[WidgetService] ✅ Дані всіх груп збережено для віджетів");
    } catch (e) {
      print("[WidgetService] ❌ Помилка: $e");
    }
  }

  Future<void> clearAllLoadingStates() async {
    if (!Platform.isAndroid) return;
    try {
      for (int i = 1; i <= 12; i++) {
        await HomeWidget.saveWidgetData<bool>('is_loading_$i', false);
      }

      final providers = [
        'LightScheduleWidgetProvider',
        'LightScheduleWidgetProvider2',
        'LightScheduleWidgetProvider3',
        'LightScheduleWidgetProvider4',
        'LightScheduleWidgetProvider5',
        'LightScheduleWidgetProvider6',
        'LightScheduleWidgetProvider7',
        'LightScheduleWidgetProvider8',
        'LightScheduleWidgetProvider9',
        'LightScheduleWidgetProvider10',
        'LightScheduleWidgetProvider11',
        'LightScheduleWidgetProvider12',
      ];

      for (var provider in providers) {
        await HomeWidget.updateWidget(
          androidName: provider,
        );
      }
      print("[WidgetService] 🔄 Стан завантаження скинуто");
    } catch (e) {
      print("[WidgetService] ❌ Помилка скидання завантаження: $e");
    }
  }

  String _encodeSchedule(DailySchedule schedule) {
    final buffer = StringBuffer();
    for (var status in schedule.hours) {
      switch (status) {
        case LightStatus.on:
          buffer.write('0');
          break;
        case LightStatus.off:
          buffer.write('1');
          break;
        case LightStatus.semiOn:
          buffer.write('2');
          break;
        case LightStatus.semiOff:
          buffer.write('3');
          break;
        case LightStatus.maybe:
          buffer.write('4');
          break; 
        default:
          buffer.write('9');
          break;
      }
    }
    return buffer.toString();
  }
}
