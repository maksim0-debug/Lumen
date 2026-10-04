import 'dart:io';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/schedule_status.dart';
import '../services/app_logger.dart';
import '../services/notification_service.dart';
import '../services/preferences_helper.dart';
import '../services/widget_service.dart';
import '../utils/app_formatters.dart';

class ScheduleNotificationCoordinator {
  final NotificationService _notifier;
  final WidgetService _widgetService;

  ScheduleNotificationCoordinator({
    NotificationService? notifier,
    WidgetService? widgetService,
  })  : _notifier = notifier ?? NotificationService(),
        _widgetService = widgetService ?? WidgetService();

  NotificationService get notifier => _notifier;
  WidgetService get widgetService => _widgetService;

  String _formatDateKey(DateTime dt) => AppFormatters.formatDateKey(dt);

  Future<void> handleScheduleUpdate({
    required Map<String, FullSchedule> allSchedules,
    required String currentGroup,
    Iterable<String>? notificationGroups,
  }) async {
    try {
      final prefs = await PreferencesHelper.getSafeInstance();
      final notifyChange = prefs.getBool('notify_schedule_change') ?? true;
      final now = DateTime.now();

      final groupsToCheck = <String>{
        ...?notificationGroups,
        currentGroup,
      };

      for (final group in groupsToCheck) {
        if (!allSchedules.containsKey(group)) continue;

        final schedule = allSchedules[group]!;
        final keyHash = "prev_hash_${group}_today";
        final keyDate = "prev_date_${group}_today";
        final todayStr = _formatDateKey(now);

        final oldHash = prefs.getString(keyHash);
        final savedDate = prefs.getString(keyDate);
        final newHash = schedule.today.scheduleHash;

        if (notifyChange &&
            savedDate == todayStr &&
            oldHash != null &&
            oldHash != newHash) {
          if (Platform.isWindows) {
            final newMinutes = schedule.today.totalOutageMinutes;
            final oldMinutes =
                DailySchedule.fromEncodedString(oldHash).totalOutageMinutes;

            final diff = newMinutes - oldMinutes;
            final String msg;
            if (diff != 0) {
              final diffHours = (diff.abs() / 60);
              final diffStr = diffHours == diffHours.toInt()
                  ? diffHours.toInt().toString()
                  : diffHours.toStringAsFixed(1);
              msg = diff > 0
                  ? "Світла стало МЕНШЕ на $diffStr год. 😔"
                  : "Світла стало БІЛЬШЕ на $diffStr год. 🎉";
            } else {
              msg = "Змінився час відключень на сьогодні ⚡";
            }

            _notifier.showImmediate("Графік змінено!", msg, groupName: group);
          }
        }

        await prefs.setString(keyHash, newHash);
        await prefs.setString(keyDate, todayStr);
      }
    } catch (e) {
      AppLogger.e("Error syncing hash", tag: 'Main', error: e);
    }

    await updateNotificationsOnly(
      allSchedules: allSchedules,
      currentGroup: currentGroup,
    );
    if (Platform.isAndroid) await _widgetService.updateWidget(allSchedules);
  }

  Future<void> updateNotificationsOnly({
    required Map<String, FullSchedule> allSchedules,
    required String currentGroup,
  }) async {
    if (!Platform.isAndroid) return;

    SharedPreferences? prefs;
    try {
      prefs = await PreferencesHelper.getSafeInstance();
    } catch (e) {
      AppLogger.w(
          "Error loading SharedPreferences in _updateNotificationsOnly: $e",
          tag: 'Main');
      return;
    }

    List<String> notificationGroups =
        prefs.getStringList('notification_groups') ?? [];

    if (notificationGroups.isEmpty) {
      notificationGroups = [currentGroup];
    }

    bool first = true;
    for (String group in notificationGroups) {
      final schedule = allSchedules[group];
      if (schedule != null) {
        await _notifier.scheduleNotificationsForToday(schedule,
            groupName: group, cancelExisting: first);
        first = false;
      }
    }
  }
}
