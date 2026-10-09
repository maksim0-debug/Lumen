import 'dart:async';

import 'package:flutter/widgets.dart';

/// UI work stops while Android is hidden; WorkManager owns background polling.
class VisibleScheduleTicker {
  final bool foregroundOnly;
  final DateTime Function() now;
  final void Function(DateTime) onMinute;
  final void Function() onResume;
  Timer? _timer;
  bool _disposed = false;
  bool _backgrounded = false;
  AppLifecycleState? _state;

  VisibleScheduleTicker({
    required this.foregroundOnly,
    required this.now,
    required this.onMinute,
    required this.onResume,
    AppLifecycleState? initialState,
  }) : _state = initialState {
    _schedule();
  }

  bool get _allowed =>
      !foregroundOnly || _state == null || _state == AppLifecycleState.resumed;

  void lifecycleChanged(AppLifecycleState state) {
    if (_disposed) return;
    _state = state;
    if (foregroundOnly && !_allowed) {
      if (state == AppLifecycleState.paused ||
          state == AppLifecycleState.hidden) {
        _backgrounded = true;
      }
      _timer?.cancel();
      _timer = null;
    } else {
      _schedule();
      if (foregroundOnly && _backgrounded) {
        _backgrounded = false;
        onResume();
      }
    }
  }

  void _schedule() {
    _timer?.cancel();
    if (_disposed || !_allowed) return;
    final current = now();
    _timer = Timer(
        Duration(
            milliseconds:
                (60 - current.second) * 1000 - current.millisecond + 100), () {
      if (_disposed || !_allowed) return;
      onMinute(now());
      _schedule();
    });
  }

  void dispose() {
    _disposed = true;
    _timer?.cancel();
    _timer = null;
  }
}
