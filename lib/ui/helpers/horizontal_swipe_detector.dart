import 'package:flutter/widgets.dart';

/// Reusable widget that detects horizontal swipes (both rapid flings and continuous drags)
/// with configurable thresholds and slop tolerances.
class HorizontalSwipeDetector extends StatefulWidget {
  final Widget child;
  final HitTestBehavior behavior;
  final VoidCallback? onSwipeLeft;
  final VoidCallback? onSwipeRight;
  final double minVelocity;
  final double minDistance;
  final double slopTolerance;
  final double maxOppositeVelocity;

  const HorizontalSwipeDetector({
    super.key,
    required this.child,
    this.behavior = HitTestBehavior.opaque,
    this.onSwipeLeft,
    this.onSwipeRight,
    this.minVelocity = 250.0,
    this.minDistance = 50.0,
    this.slopTolerance = 10.0,
    this.maxOppositeVelocity = 150.0,
  });

  @override
  State<HorizontalSwipeDetector> createState() =>
      _HorizontalSwipeDetectorState();
}

class _HorizontalSwipeDetectorState extends State<HorizontalSwipeDetector> {
  double _dragOffset = 0.0;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: widget.behavior,
      onHorizontalDragStart: (_) {
        _dragOffset = 0.0;
      },
      onHorizontalDragUpdate: (details) {
        _dragOffset += details.primaryDelta ?? 0.0;
      },
      onHorizontalDragCancel: () {
        _dragOffset = 0.0;
      },
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0.0;
        final offset = _dragOffset;
        _dragOffset = 0.0;

        final isFlingLeft =
            velocity < -widget.minVelocity && offset <= widget.slopTolerance;
        final isFlingRight =
            velocity > widget.minVelocity && offset >= -widget.slopTolerance;
        final isDragLeft = offset < -widget.minDistance &&
            velocity <= widget.maxOppositeVelocity;
        final isDragRight = offset > widget.minDistance &&
            velocity >= -widget.maxOppositeVelocity;

        if (isFlingLeft || isDragLeft) {
          widget.onSwipeLeft?.call();
        } else if (isFlingRight || isDragRight) {
          widget.onSwipeRight?.call();
        }
      },
      child: widget.child,
    );
  }
}
