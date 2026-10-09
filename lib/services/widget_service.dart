import 'schedule_clock.dart';
import 'dart:io';
import 'package:home_widget/home_widget.dart';
import '../models/schedule_status.dart';
import 'app_logger.dart';
import 'android_fetch_diagnostics.dart';

class WidgetService {
  static final WidgetService _instance = WidgetService._internal();
  factory WidgetService() => _instance;
  WidgetService._internal();

  Future<void> updateWidget(Map<String, FullSchedule> allSchedules) async {
    if (!Platform.isAndroid) return;

    AppLogger.d("Оновлення даних для віджетів...", tag: 'WidgetService');

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

        final now = ScheduleClock.now();
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
          qualifiedAndroidName: 'ua.maksim0.lumen.$provider',
        );
      }

      AppLogger.i("✅ Дані всіх груп збережено для віджетів",
          tag: 'WidgetService');
      AndroidFetchDiagnostics.current?.event('widgets_updated', {
        'groups': allSchedules.length,
        'providers': providers.length,
      });
    } catch (e) {
      AndroidFetchDiagnostics.current?.event(
          'widgets_update_error', AndroidFetchDiagnostics.errorFields(e),
          level: AppLogLevel.error);
      AppLogger.e("Помилка оновлення віджетів", tag: 'WidgetService', error: e);
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
          qualifiedAndroidName: 'ua.maksim0.lumen.$provider',
        );
      }
      AppLogger.d("🔄 Стан завантаження скинуто", tag: 'WidgetService');
    } catch (e) {
      AppLogger.e("Помилка скидання завантаження",
          tag: 'WidgetService', error: e);
    }
  }
}
