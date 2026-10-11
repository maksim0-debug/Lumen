import 'dart:async';

import 'package:flutter/material.dart';
import '../../../services/app_logger.dart';

/// Displays the existing refresh animation for an externally started operation.
/// Its callback waits for that operation instead of issuing another request.
class ManualRefreshIndicator extends StatefulWidget {
  final Future<void>? operation;
  final RefreshCallback onRefresh;
  final Widget child;

  const ManualRefreshIndicator({
    super.key,
    required this.operation,
    required this.onRefresh,
    required this.child,
  });

  @override
  State<ManualRefreshIndicator> createState() => _ManualRefreshIndicatorState();
}

class _ManualRefreshIndicatorState extends State<ManualRefreshIndicator> {
  final _indicatorKey = GlobalKey<RefreshIndicatorState>();
  Future<void>? _displayedOperation;

  @override
  void initState() {
    super.initState();
    _showOperation();
  }

  @override
  void didUpdateWidget(ManualRefreshIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(widget.operation, oldWidget.operation)) _showOperation();
  }

  void _showOperation() {
    final operation = widget.operation;
    // Null may arrive while show() is still animating towards onRefresh.
    // Retain its future so that callback cannot issue a second network request.
    if (operation == null) return;
    // Keep the exact future even if it completes during the entrance animation.
    final displayed = _observe(operation);
    _displayedOperation = displayed;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && identical(_displayedOperation, displayed)) {
        unawaited(_indicatorKey.currentState?.show());
      }
    });
  }

  Future<void> _observe(Future<void> operation) =>
      operation.then<void>((_) {}, onError: (Object error, StackTrace stack) {
        AppLogger.w('Manual refresh indicator received a failed operation',
            tag: 'Home',
            error: error,
            stackTrace: stack,
            persistToHistory: false);
      });

  Future<void> _onRefresh() async {
    if (_displayedOperation == null) {
      await _observe(Future<void>.sync(widget.onRefresh));
    }
    while (_displayedOperation != null) {
      final operation = _displayedOperation;
      await operation;
      if (identical(_displayedOperation, operation)) _displayedOperation = null;
    }
  }

  @override
  Widget build(BuildContext context) => RefreshIndicator(
        key: _indicatorKey,
        color: Colors.orange,
        onRefresh: _onRefresh,
        child: widget.child,
      );
}
