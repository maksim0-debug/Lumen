import '../models/emergency_status.dart';
import 'app_logger.dart';
import 'emergency_status_service.dart';
import 'notification_service.dart';
import 'preferences_helper.dart';

class EmergencyNotificationService {
  final EmergencyStatusService statusService;
  final Future<void> Function(bool active) _show;
  final Future<bool> Function() _enabled;

  EmergencyNotificationService(
      {EmergencyStatusService? statusService,
      Future<void> Function(bool)? show,
      Future<bool> Function()? enabled})
      : statusService = statusService ?? EmergencyStatusService(),
        _show = show ?? _showNotification,
        _enabled = enabled ?? _notificationsEnabled;

  static Future<bool> _notificationsEnabled() async {
    final prefs = await PreferencesHelper.getSafeInstance();
    // The background isolate may have an older preferences cache.
    await prefs.reload();
    return prefs.getBool('notify_emergency_outages') ?? true;
  }

  static Future<void> _showNotification(bool active) =>
      NotificationService().showImmediate(
        active ? 'Екстрені відключення' : 'Екстрені відключення скасовано',
        active
            ? 'ДТЕК повідомляє про екстрені відключення. Можливі відхилення від графіків.'
            : 'ДТЕК повідомляє про скасування екстрених відключень.',
        notificationId: NotificationService.emergencyNotificationId,
        rethrowOnError: true,
      );

  Future<bool> handlePush(Map<String, dynamic> data,
      {bool notify = true}) async {
    final push =
        EmergencyPush.parse(data, DateTime.now().millisecondsSinceEpoch);
    if (push == null) {
      AppLogger.w('Ignoring expired or incomplete emergency push',
          tag: 'Emergency');
      return false;
    }
    final status = await statusService.observe(push.observation);
    if (notify &&
        status.active == push.observation.active &&
        status.seenAt == push.observation.observedAt) {
      await notifyStatus(status);
    }
    return true;
  }

  Future<void> notifyStatus(EmergencyStatus status) async {
    try {
      if (status.active == null ||
          !status.isFreshAt(DateTime.now().millisecondsSinceEpoch) ||
          !await _enabled()) {
        return;
      }
      await statusService.deliverNotification(
          status, () => _show(status.active!));
      final latest = await statusService.read();
      if (latest.changedAt > status.changedAt) await notifyStatus(latest);
    } catch (error, stack) {
      AppLogger.e('Cannot display emergency notification',
          tag: 'Emergency', error: error, stackTrace: stack);
    }
  }
}
