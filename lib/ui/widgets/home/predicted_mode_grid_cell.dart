import 'package:flutter/material.dart';

import '../../../models/schedule_status.dart';
import '../../../services/darkness_theme_service.dart';
import '../../../theme/darkness_stage_style.dart';
import '../theme_animated_cell.dart';

/// Predicted mode grid cell for classic LightStatus rendering.
class PredictedModeGridCell extends StatelessWidget {
  final int hour;
  final LightStatus status;
  final bool isCurrentHour;
  final DarknessStage? stage;

  const PredictedModeGridCell({
    super.key,
    required this.hour,
    required this.status,
    this.isCurrentHour = false,
    this.stage,
  });

  @override
  Widget build(BuildContext context) {
    final darknessService = DarknessThemeService();
    final effectiveStage = stage ??
        (darknessService.isEnabled ? darknessService.currentStage : null);
    final text = "$hour:00";
    Widget cellContent;

    switch (status) {
      case LightStatus.on:
        cellContent = themedColorBox(true, text, effectiveStage);
        break;
      case LightStatus.off:
        cellContent = themedColorBox(false, text, effectiveStage);
        break;
      case LightStatus.semiOn:
        cellContent = themedGradientBox(true, text, effectiveStage);
        break;
      case LightStatus.semiOff:
        cellContent = themedGradientBox(false, text, effectiveStage);
        break;
      case LightStatus.maybe:
      default:
        cellContent = themedMaybeBox(text, effectiveStage);
        break;
    }

    // Wrap with animation
    final animated = ThemeAnimatedCell(
      stage: effectiveStage,
      child: cellContent,
    );

    if (isCurrentHour) {
      return themedCurrentHourWrap(animated, effectiveStage);
    }
    return animated;
  }

  static Widget colorBox(bool isOn, String text, DarknessStage? stage) =>
      themedColorBox(isOn, text, stage);

  static Widget gradientBox(bool isSemiOn, String text, DarknessStage? stage) =>
      themedGradientBox(isSemiOn, text, stage);

  static Widget maybeBox(String text, DarknessStage? stage) =>
      themedMaybeBox(text, stage);

  static Widget currentHourWrap(Widget child, DarknessStage? stage) =>
      themedCurrentHourWrap(child, stage);
}

/// Themed ON/OFF cell.
Widget themedColorBox(bool isOn, String text, DarknessStage? stage) {
  final style = DarknessStageStyle.of(stage);
  final color = isOn ? style.onColor : style.offColor;
  final radius = style.borderRadius;
  final textStyle = style.cellTextStyle;
  final decoration = style.colorBoxDecoration(isOn, color);

  // Stalker: override text for OFF cells
  TextStyle displayStyle = textStyle;
  if (stage == DarknessStage.stalker && !isOn) {
    displayStyle = textStyle.copyWith(
      color: const Color(0xFFFF1744),
      shadows: [
        const Shadow(blurRadius: 4, color: Color(0xFFFF1744)),
      ],
    );
  }

  return Container(
    decoration: decoration,
    child: Stack(
      children: [
        // Stalker scanline overlay for OFF cells
        if (stage == DarknessStage.stalker && !isOn)
          Positioned.fill(
            child: CustomPaint(
              painter: ScanlinePainter(
                color: const Color(0xFFFF1744).withValues(alpha: 0.06),
              ),
            ),
          ),
        // Cyberpunk: subtle inner glow line at top
        if (stage == DarknessStage.cyberpunk)
          Positioned(
            top: 0,
            left: 4,
            right: 4,
            child: Container(
              height: 1,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    Colors.transparent,
                    (isOn ? const Color(0xFF00FFFF) : const Color(0xFFFF0080))
                        .withValues(alpha: 0.5),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
        // Dieselpunk: diagonal stripes for OFF
        if (stage == DarknessStage.dieselpunk && !isOn)
          Positioned.fill(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(radius),
              child: CustomPaint(
                painter: DiagonalStripesPainter(
                  color: const Color(0xFFFF9800).withValues(alpha: 0.08),
                ),
              ),
            ),
          ),
        // Main text
        Center(child: Text(text, style: displayStyle)),
      ],
    ),
  );
}

/// Themed gradient box for semi-on / semi-off status.
Widget themedGradientBox(bool isSemiOn, String text, DarknessStage? stage) {
  final style = DarknessStageStyle.of(stage);
  final onColor = style.onColor;
  final offColor = style.offColor;
  final radius = style.borderRadius;
  final textStyle = style.cellTextStyle;
  final colors = isSemiOn ? [offColor, onColor] : [onColor, offColor];

  final decoration = style.gradientBoxDecoration(isSemiOn, colors, onColor);

  return Container(
    decoration: decoration,
    child: Stack(
      children: [
        if (stage == DarknessStage.stalker)
          Positioned.fill(
            child: CustomPaint(
              painter: ScanlinePainter(
                color: const Color(0xFF39FF14).withValues(alpha: 0.04),
              ),
            ),
          ),
        // Dieselpunk: diagonal stripes for semiOff (right half is OFF)
        if (stage == DarknessStage.dieselpunk && !isSemiOn)
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(child: Container()), // Empty left half (ON)
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.only(
                        topRight: Radius.circular(radius),
                        bottomRight: Radius.circular(radius)),
                    child: CustomPaint(
                      painter: DiagonalStripesPainter(
                        color: const Color(0xFFFF9800).withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        // Dieselpunk: diagonal stripes for semiOn (left half is OFF)
        if (stage == DarknessStage.dieselpunk && isSemiOn)
          Positioned.fill(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.only(
                        topLeft: Radius.circular(radius),
                        bottomLeft: Radius.circular(radius)),
                    child: CustomPaint(
                      painter: DiagonalStripesPainter(
                        color: const Color(0xFFFF9800).withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                ),
                Expanded(child: Container()), // Empty right half (ON)
              ],
            ),
          ),

        Center(child: Text(text, style: textStyle)),
      ],
    ),
  );
}

/// Themed maybe/unknown cell.
Widget themedMaybeBox(String text, DarknessStage? stage) {
  final style = DarknessStageStyle.of(stage);
  final textStyle = style.cellTextStyle;
  final decoration = style.maybeBoxDecoration();

  return Container(
    decoration: decoration,
    child: Stack(
      children: [
        Center(
          child: Text(
            '$text ?',
            style: stage == DarknessStage.stalker
                ? textStyle.copyWith(
                    color: const Color(0xFF39FF14).withValues(alpha: 0.5),
                  )
                : (stage == DarknessStage.cyberpunk
                    ? textStyle.copyWith(
                        color: const Color(0xFF4A4A6A),
                      )
                    : textStyle.copyWith(color: Colors.white70)),
          ),
        ),
      ],
    ),
  );
}

/// Themed current-hour wrapper.
Widget themedCurrentHourWrap(Widget child, DarknessStage? stage) {
  final style = DarknessStageStyle.of(stage).currentHourStyle();
  return Stack(children: [
    Container(
      decoration: BoxDecoration(
        border: Border.all(color: style.borderColor, width: style.borderWidth),
        borderRadius: BorderRadius.circular(style.radius),
        boxShadow: style.shadows,
      ),
      child: child,
    ),
    Positioned(
      top: 3,
      right: 3,
      child: Icon(style.dotIcon, size: style.dotSize, color: style.dotColor),
    ),
  ]);
}
