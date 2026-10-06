import 'dart:async';
import 'preferences_helper.dart';

/// Serializes foreground duplicate checks and bounds the persistent event cache.
class FcmEventGuard {
  static Future<void> _tail = Future.value();
  static const _key = 'fcm_received_event_ids';
  static Future<bool> claim(String? eventId) {
    if (eventId == null || eventId.isEmpty) {
      return Future.value(true); // Older workers.
    }
    if (eventId.length > 512) return Future.value(false);
    final result = _tail.then((_) async {
      final prefs = await PreferencesHelper.getSafeInstance();
      await prefs.reload();
      final events = prefs.getStringList(_key) ?? <String>[];
      if (events.contains(eventId)) return false;
      events.add(eventId);
      if (events.length > 200) events.removeRange(0, events.length - 200);
      if (!await prefs.setStringList(_key, events)) {
        throw StateError('Cannot persist FCM event identity');
      }
      return true;
    });
    _tail =
        result.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return result;
  }
}
