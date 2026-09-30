import 'package:flutter/material.dart';
import 'schedule_status.dart';

/// Внутрішній діапазон відключення всередині години.
class HourOffRange {
  final double start;
  final double end;

  const HourOffRange(this.start, this.end);
}

/// Сегмент всередині однієї години для пропорційної візуалізації напруги.
class HourSegment {
  final double startFraction; // 0.0–1.0 (0 хв – 60 хв)
  final double endFraction; // 0.0–1.0
  final Color color;
  final LightStatus status;
  final bool isFuture;

  const HourSegment(
    this.startFraction,
    this.endFraction,
    this.color, {
    this.status = LightStatus.unknown,
    this.isFuture = false,
  });

  double get width => endFraction - startFraction;
  double get start => startFraction;
  double get end => endFraction;

  bool get isOn => status == LightStatus.on;
  bool get isOff => status == LightStatus.off;
}
