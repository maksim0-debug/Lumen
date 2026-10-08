import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'app_logger.dart';
import 'fcm_event_guard.dart';
import 'notification_service.dart';
import 'parser_service.dart';
import 'preferences_helper.dart';

/// Diagnostic pushes never enter schedule or emergency state processing.
class FcmTestNotificationService {
  final Future<SharedPreferences> Function() _preferences;
  final Future<void> Function(String title, String body) _show;
  final Future<bool> Function(String? eventId) _claim;

  FcmTestNotificationService({
    Future<SharedPreferences> Function()? preferences,
    Future<void> Function(String, String)? show,
    Future<bool> Function(String?)? claim,
  })  : _preferences = preferences ?? PreferencesHelper.getSafeInstance,
        _show = show ?? _showNotification,
        _claim = claim ?? FcmEventGuard.claim;

  static bool isTest(Map<String, dynamic> data) => data['type'] == 'test';

  static Future<void> _showNotification(String title, String body) =>
      NotificationService().showImmediate(
        title,
        body,
        notificationId: NotificationService.testNotificationId,
        rethrowOnError: true,
      );

  /// Returns true for every test, including malformed or disabled tests, so
  /// callers cannot fall through to operational processing on failure.
  Future<bool> handleIfTest(RemoteMessage message, {bool notify = true}) async {
    final data = message.data;
    if (!isTest(data)) return false;
    if (!notify) return true;

    try {
      final explicitAudience = data['testAudience'];
      // Older workers used a group envelope for the global emergency topic.
      final eventId = data['eventId'];
      final audience = explicitAudience ??
          (data['group'] == 'EMERGENCY' ||
                  (eventId is String &&
                      eventId.startsWith('emergency_alerts:test:'))
              ? 'emergency'
              : 'group');
      final prefs = await _preferences();
      await prefs.reload();
      final bool enabled;
      if (audience == 'emergency') {
        enabled = prefs.getBool('notify_emergency_outages') ?? true;
      } else if (audience == 'group') {
        final group = data['group'];
        final dayType = data['dayType'] ?? 'today';
        if (group is! String ||
            !ParserService.allGroups.contains(group) ||
            !['today', 'tomorrow'].contains(dayType)) {
          AppLogger.w('Ignoring invalid group test push', tag: 'FCM');
          return true;
        }
        enabled = PreferencesHelper.getActiveNotificationGroups(prefs)
                .contains(group) &&
            (prefs.getBool(dayType == 'tomorrow'
                    ? 'notify_tomorrow_schedule'
                    : 'notify_schedule_change') ??
                true);
      } else {
        AppLogger.w('Ignoring unknown test push audience', tag: 'FCM');
        return true;
      }
      if (!enabled) return true;
      if (eventId != null && eventId is! String) {
        AppLogger.w('Ignoring invalid test push identity', tag: 'FCM');
        return true;
      }
      final title = message.notification?.title ?? data['title'];
      final body = message.notification?.body ?? data['body'];
      if (title is! String || title.trim().isEmpty || body is! String) {
        AppLogger.w('Ignoring incomplete test push', tag: 'FCM');
        return true;
      }
      if (!await _claim(eventId as String?)) return true;
      await _show(title, body).timeout(const Duration(seconds: 10));
      AppLogger.i('Displayed diagnostic FCM push', tag: 'FCM');
    } catch (error, stack) {
      AppLogger.e('Cannot display diagnostic FCM push',
          tag: 'FCM', error: error, stackTrace: stack);
    }
    return true;
  }
}
