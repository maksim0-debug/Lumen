import 'package:flutter/material.dart';

import '../../../models/hour_segment.dart';
import '../../../models/schedule_status.dart';
import '../../../models/schedule_view_mode.dart';
import '../../../services/darkness_theme_service.dart';
import '../../../theme/darkness_stage_style.dart';
import '../theme_animated_cell.dart';
import 'predicted_mode_grid_cell.dart';

/// Ячейка Real Mode: пропорційна заливка кольорами (themed) + анімації + Future Styling.
class RealModeGridCell extends StatelessWidget {
  final int hour;
  final List<HourSegment> segments;
  final bool isCurrentHour;
  final ScheduleViewMode viewMode;
  final VoidCallback? onLongPress;

  const RealModeGridCell({
    super.key,
    required this.hour,
    required this.segments,
    this.isCurrentHour = false,
    this.viewMode = ScheduleViewMode.today,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final darknessService = DarknessThemeService();
    final stage =
        darknessService.isEnabled ? darknessService.currentStage : null;
    final now = DateTime.now();
    final bool showNowLine = isCurrentHour;
    final double nowFraction = showNowLine ? now.minute / 60.0 : 0;
    final stageStyle = DarknessStageStyle.of(stage);
    final textStyle = stageStyle.cellTextStyle;
    final nowLineColor = stageStyle.nowLineColor;

    // Build timeline segments
    Widget timeline = LayoutBuilder(builder: (context, constraints) {
      final totalWidth = constraints.maxWidth;
      List<Widget> children = [];

      for (final segment in segments) {
        // Handle split for current hour
        double start = segment.startFraction;
        double end = segment.endFraction;

        List<_RenderSegment> distinctParts = [];

        if (isCurrentHour) {
          // 1. Part before NOW (Past/Fact)
          if (start < nowFraction) {
            final effectiveEnd = end < nowFraction ? end : nowFraction;
            distinctParts.add(_RenderSegment(
                start, effectiveEnd, segment.color, false,
                status: segment.status));
          }
          // 2. Part after NOW (Future/Forecast)
          if (end > nowFraction) {
            final effectiveStart = start > nowFraction ? start : nowFraction;
            distinctParts.add(_RenderSegment(
                effectiveStart, end, segment.color, true,
                status: segment.status));
          }
        } else {
          bool isFuture = false;
          if (viewMode == ScheduleViewMode.today) {
            if (hour > now.hour) isFuture = true;
          } else if (viewMode == ScheduleViewMode.tomorrow) {
            isFuture = true;
          } else if (viewMode == ScheduleViewMode.yesterday ||
              viewMode == ScheduleViewMode.history) {
            isFuture = false;
          }

          distinctParts.add(_RenderSegment(start, end, segment.color, isFuture,
              status: segment.status));
        }

        for (final part in distinctParts) {
          final w = (part.end - part.start) * totalWidth;
          if (w < 0.5) continue;

          leftOffset() => part.start * totalWidth;

          final isSegmentOn = part.isOn;
          final themeColor = isSegmentOn
              ? stageStyle.onColor
              : (part.status == LightStatus.maybe
                  ? Colors.grey.shade500
                  : (part.status == LightStatus.unknown
                      ? Colors.grey.shade700
                      : stageStyle.offColor));

          final segResult = stageStyle.segmentDecoration(
            isFuture: part.isFuture,
            isSegmentOn: isSegmentOn,
            themeColor: themeColor,
            seed: hour * 100 + (part.start * 100).toInt(),
          );

          Widget segmentWidget = Container(
              decoration: segResult.decoration, child: segResult.overlay);

          // Overlays for Fact parts (Diesel stripes OFF etc)
          if (!part.isFuture) {
            List<Widget> extras = [segmentWidget];
            // Dieselpunk: diagonal stripes for OFF FACT
            if (stage == DarknessStage.dieselpunk && !isSegmentOn) {
              extras.add(Positioned.fill(
                child: ClipRect(
                  child: CustomPaint(
                    painter: DiagonalStripesPainter(
                      color: const Color(0xFFFF9800).withValues(alpha: 0.08),
                    ),
                  ),
                ),
              ));
            }
            // Stalker: scanlines for OFF FACT
            if (stage == DarknessStage.stalker && !isSegmentOn) {
              extras.add(Positioned.fill(
                child: ClipRect(
                  child: CustomPaint(
                    painter: ScanlinePainter(
                      color: const Color(0xFFFF1744).withValues(alpha: 0.06),
                    ),
                  ),
                ),
              ));
            }

            children.add(Positioned(
              left: leftOffset(),
              width: w,
              top: 0,
              bottom: 0,
              child: Stack(children: extras),
            ));
          } else {
            // Future widget already has overlay inside
            children.add(Positioned(
              left: leftOffset(),
              width: w,
              top: 0,
              bottom: 0,
              child: segmentWidget,
            ));
          }
        }
      }

      return Stack(
        children: [
          ...children, // Positioned widgets

          // Stalker: global scanline overlay (subtle) - ONLY FOR FACT PARTS?
          // Actually, let's keep it global for cohesion, or maybe restrict?
          // User said "Future... must be unique".
          // Let's keep global effects minimal on Future to not conflict.

          // "Now" vertical line
          if (showNowLine)
            Positioned(
              left: nowFraction * totalWidth - 1,
              top: 0,
              bottom: 0,
              child: Container(
                width: stage == DarknessStage.stalker ? 1.5 : 2,
                decoration: BoxDecoration(
                  color: nowLineColor,
                  boxShadow: stage == DarknessStage.cyberpunk
                      ? [
                          BoxShadow(
                            color: nowLineColor.withValues(alpha: 0.6),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ]
                      : null,
                ),
              ),
            ),

          // Timestamp
          Center(
            child: Text(
              "$hour:00",
              style: textStyle.copyWith(
                shadows: [
                  const Shadow(
                      blurRadius: 4,
                      color: Colors.black87,
                      offset: Offset(0, 0)),
                  const Shadow(
                      blurRadius: 8,
                      color: Colors.black54,
                      offset: Offset(0, 0)),
                  if (stage == DarknessStage.stalker)
                    const Shadow(
                        blurRadius: 4,
                        color: Color(0xFF39FF14),
                        offset: Offset(0, 0)),
                ],
              ),
            ),
          ),

          // Stalker: small radiation icon
          if (stage == DarknessStage.stalker)
            Positioned(
              right: 2,
              bottom: 1,
              child: Icon(
                Icons.radio_button_checked,
                size: 8,
                color: const Color(0xFF39FF14).withValues(alpha: 0.2),
              ),
            ),
        ],
      );
    });

    final BoxDecoration containerDecoration = stageStyle.emptyBoxDecoration();

    // Wrap with gesture detector and tooltip
    Widget cell = GestureDetector(
      onLongPress: onLongPress,
      child: Container(
        decoration: containerDecoration,
        clipBehavior: Clip.antiAlias, // Ensure segments don't overflow
        child: timeline,
      ),
    );

    // Wrap with animation
    final animated = ThemeAnimatedCell(
      stage: stage,
      child: cell,
    );

    if (isCurrentHour) {
      return themedCurrentHourWrap(animated, stage);
    }
    return animated;
  }
}

// --- HELPERS ---

class _RenderSegment {
  final double start;
  final double end;
  final Color color;
  final bool isFuture;
  final LightStatus status;

  _RenderSegment(this.start, this.end, this.color, this.isFuture,
      {this.status = LightStatus.unknown});

  bool get isOn => status == LightStatus.on;
}

typedef RenderSegment = _RenderSegment;
