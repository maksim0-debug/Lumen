import 'schedule_clock.dart';
import 'dart:io';
import 'dart:convert';
import 'package:lumen_schedule_widgets/lumen_schedule_widgets.dart';
import '../utils/app_formatters.dart';
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
      if (allSchedules.isEmpty) return;
      final now = ScheduleClock.now();
      var version = 0;
      final update = allSchedules.values.first.lastUpdatedSource;
      try {
        version = ScheduleClock.parseVersion(update);
        if (allSchedules.values.any((s) => s.lastUpdatedSource != update)) {
          // Mixed source/manual cache rows cannot represent one publication.
          version = 0;
        }
      } on FormatException {
        // Manual/legacy schedules remain displayable without changing DTEK watermarks.
      }
      await LumenScheduleWidgets.applySnapshot(jsonEncode({
        'todayDate': AppFormatters.formatDateKey(now),
        'tomorrowDate': AppFormatters.formatDateKey(ScheduleClock.day(now, 1)),
        'sourceVersion': version,
        'sourceUpdatedAt': update,
        'groups': {
          for (final e in allSchedules.entries)
            e.key: [e.value.today.scheduleHash, e.value.tomorrow.scheduleHash]
        },
      }));
      AppLogger.i('Дані графіків атомарно передано Android-віджетам',
          tag: 'WidgetService');
      AndroidFetchDiagnostics.current?.event('widgets_updated', {
        'groups': allSchedules.length,
      });
    } catch (error) {
      AndroidFetchDiagnostics.current?.event(
          'widgets_update_error', AndroidFetchDiagnostics.errorFields(error),
          level: AppLogLevel.error);
      AppLogger.e('Помилка оновлення віджетів',
          tag: 'WidgetService', error: error);
      rethrow;
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
