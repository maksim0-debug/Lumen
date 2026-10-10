import 'package:flutter/services.dart';

class LumenScheduleWidgets {
  static const _channel = MethodChannel('lumen/schedule_widgets');

  static Future<void> applySnapshot(String snapshot) =>
      _channel.invokeMethod<void>('applySnapshot', snapshot);
}
