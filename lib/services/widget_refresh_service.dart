import 'package:flutter/services.dart';

import 'app_logger.dart';

/// Native requests remain pending until the home screen has loaded preferences.
/// Repeated taps during one refresh are consumed without starting another fetch.
class WidgetRefreshService {
  static const channel = MethodChannel('lumen/widget_refresh');
  final Future<void> Function() onRefresh;
  bool _disposed = false;
  bool _refreshing = false;

  WidgetRefreshService({required this.onRefresh});

  Future<bool> start() async {
    if (_disposed) return false;
    channel.setMethodCallHandler((call) async {
      if (call.method == 'refreshRequested') await _consume();
    });
    return _consume();
  }

  Future<bool> _consume() async {
    if (_disposed) return false;
    try {
      final pending = await channel.invokeMethod<bool>('consumePendingRefresh');
      if (_disposed || pending != true) return false;
      if (_refreshing) return true;
      _refreshing = true;
      try {
        await onRefresh();
      } catch (error, stack) {
        AppLogger.e('Widget refresh failed',
            tag: 'WidgetRefresh', error: error, stackTrace: stack);
      } finally {
        _refreshing = false;
      }
      return true;
    } catch (error, stack) {
      AppLogger.e('Cannot handle widget refresh request',
          tag: 'WidgetRefresh', error: error, stackTrace: stack);
      return false;
    }
  }

  void dispose() {
    _disposed = true;
    channel.setMethodCallHandler(null);
  }
}
