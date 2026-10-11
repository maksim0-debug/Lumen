import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../../../models/emergency_status.dart';
import '../../../services/app_logger.dart';

/// Only a fresh active banner rendered on the visible route is acknowledged.
/// Reading cached state or hiding a cancelled banner is not a display receipt.
class DisplayedEmergencyAcknowledgment extends StatefulWidget {
  final EmergencyStatus status;
  final Future<bool> Function(EmergencyStatus) onAcknowledge;
  final Future<bool> Function()? isWindowVisible;
  final Widget child;

  const DisplayedEmergencyAcknowledgment({
    super.key,
    required this.status,
    required this.onAcknowledge,
    required this.child,
    this.isWindowVisible,
  });

  @override
  State<DisplayedEmergencyAcknowledgment> createState() =>
      _DisplayedEmergencyAcknowledgmentState();
}

class _DisplayedEmergencyAcknowledgmentState
    extends State<DisplayedEmergencyAcknowledgment>
    with WidgetsBindingObserver, WindowListener {
  int? _acknowledged;
  int? _pending;
  bool _frameScheduled = false;
  late final bool _listenToWindow;
  ScrollPosition? _scrollPosition;
  List<Animation<double>> _routeAnimations = [];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenToWindow = !kIsWeb &&
        defaultTargetPlatform == TargetPlatform.windows &&
        widget.isWindowVisible == null;
    if (_listenToWindow) windowManager.addListener(this);
    _schedule();
  }

  @override
  void didUpdateWidget(DisplayedEmergencyAcknowledgment oldWidget) {
    super.didUpdateWidget(oldWidget);
    _schedule();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    for (final animation in _routeAnimations) {
      animation.removeStatusListener(_onRouteTransition);
    }
    _routeAnimations = [
      if (route?.animation != null) route!.animation!,
      if (route?.secondaryAnimation != null) route!.secondaryAnimation!,
    ];
    for (final animation in _routeAnimations) {
      animation.addStatusListener(_onRouteTransition);
    }
    final position = Scrollable.maybeOf(context)?.position;
    if (!identical(position, _scrollPosition)) {
      _scrollPosition?.removeListener(_schedule);
      _scrollPosition = position;
      _scrollPosition?.addListener(_schedule);
    }
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _schedule();
  }

  @override
  void onWindowFocus() => _schedule();

  @override
  void onWindowRestore() => _schedule();

  // Returning from a route can make isCurrent true before its transition
  // finishes. Recheck after animation so clipping never loses the receipt.
  void _onRouteTransition(AnimationStatus status) => _schedule();

  bool get _visible =>
      mounted &&
      ModalRoute.of(context)?.isCurrent == true &&
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;

  bool get _paintedVisible {
    final box = context.findRenderObject();
    if (box is! RenderBox ||
        !box.attached ||
        !box.hasSize ||
        box.size.isEmpty) {
      return false;
    }
    final bounds = MatrixUtils.transformRect(
        box.getTransformTo(null), Offset.zero & box.size);
    final view = View.of(context);
    var visible = bounds
        .intersect(Offset.zero & (view.physicalSize / view.devicePixelRatio));
    RenderObject child = box;
    for (var parent = child.parent; parent != null; parent = child.parent) {
      final clip = parent.describeApproximatePaintClip(child);
      if (clip != null) {
        visible = visible.intersect(
            MatrixUtils.transformRect(parent.getTransformTo(null), clip));
      }
      child = parent;
    }
    // A mounted banner outside (or mostly clipped by) a scroll viewport has
    // not been displayed. Allow subpixel rounding at the viewport boundary.
    return !visible.isEmpty &&
        visible.width >= bounds.width - 0.5 &&
        visible.height >= bounds.height - 0.5;
  }

  bool _eligible(EmergencyStatus status) =>
      status.active == true &&
      status.isFreshAt(DateTime.now().millisecondsSinceEpoch) &&
      status.changedAt > 0;

  void _schedule() {
    final status = widget.status;
    if (_frameScheduled ||
        !_eligible(status) ||
        _acknowledged == status.changedAt ||
        _pending == status.changedAt) {
      return;
    }
    _frameScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _frameScheduled = false;
      if (!_visible || !_paintedVisible || !_eligible(widget.status)) return;
      unawaited(_acknowledge(widget.status));
    });
    WidgetsBinding.instance.ensureVisualUpdate();
  }

  Future<void> _acknowledge(EmergencyStatus status) async {
    if (_pending == status.changedAt || _acknowledged == status.changedAt) {
      return;
    }
    _pending = status.changedAt;
    try {
      final visible = widget.isWindowVisible != null
          ? await widget.isWindowVisible!()
          : !_listenToWindow ||
              (await windowManager.isVisible() &&
                  !await windowManager.isMinimized());
      // Native visibility checks are asynchronous: recheck the rendered
      // publication and route before writing a receipt for this frame.
      if (!visible ||
          !_visible ||
          !_paintedVisible ||
          widget.status.changedAt != status.changedAt ||
          !_eligible(widget.status)) {
        return;
      }
      if (await widget.onAcknowledge(status) &&
          mounted &&
          widget.status.changedAt == status.changedAt) {
        _acknowledged = status.changedAt;
      }
    } catch (error, stack) {
      AppLogger.w('Cannot acknowledge displayed emergency status',
          tag: 'Home', error: error, stackTrace: stack);
    } finally {
      if (_pending == status.changedAt) _pending = null;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scrollPosition?.removeListener(_schedule);
    for (final animation in _routeAnimations) {
      animation.removeStatusListener(_onRouteTransition);
    }
    if (_listenToWindow) windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
