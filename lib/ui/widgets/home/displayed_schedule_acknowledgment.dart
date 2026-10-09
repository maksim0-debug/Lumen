import 'dart:async';

import 'package:flutter/material.dart';

import '../../../models/schedule_change_event.dart';
import '../../../services/app_logger.dart';

/// Acknowledges the publication passed by the rendered UI, never fetched state.
class DisplayedScheduleAcknowledgment extends StatefulWidget {
  final ScheduleChangeEvent? event;
  final Future<void> Function(ScheduleChangeEvent) onAcknowledge;
  final Widget child;

  const DisplayedScheduleAcknowledgment({
    super.key,
    required this.event,
    required this.onAcknowledge,
    required this.child,
  });

  @override
  State<DisplayedScheduleAcknowledgment> createState() =>
      _DisplayedScheduleAcknowledgmentState();
}

class _DisplayedScheduleAcknowledgmentState
    extends State<DisplayedScheduleAcknowledgment> with WidgetsBindingObserver {
  String? _acknowledged;
  bool _frameScheduled = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scheduleAcknowledgment();
  }

  @override
  void didUpdateWidget(DisplayedScheduleAcknowledgment oldWidget) {
    super.didUpdateWidget(oldWidget);
    _scheduleAcknowledgment();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Subscribe to route visibility, including returning from another screen.
    ModalRoute.of(context);
    _scheduleAcknowledgment();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _scheduleAcknowledgment();
  }

  void _scheduleAcknowledgment() {
    if (_frameScheduled ||
        widget.event == null ||
        _acknowledged == widget.event!.id) {
      return;
    }
    _frameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameScheduled = false;
      if (!mounted ||
          ModalRoute.of(context)?.isCurrent != true ||
          WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
        return;
      }
      // didUpdateWidget captures the publication actually rendered this frame.
      final event = widget.event;
      if (event == null || _acknowledged == event.id) return;
      _acknowledged = event.id;
      unawaited(_acknowledge(event));
    });
  }

  Future<void> _acknowledge(ScheduleChangeEvent event) async {
    try {
      await widget.onAcknowledge(event);
    } catch (error, stack) {
      if (_acknowledged == event.id) _acknowledged = null;
      AppLogger.w('Cannot acknowledge displayed schedule',
          tag: 'Home', error: error, stackTrace: stack);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
