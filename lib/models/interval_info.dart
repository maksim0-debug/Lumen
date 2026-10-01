import 'package:flutter/material.dart';

class IntervalInfo {
  final String timeRange;
  final String statusText;
  final String duration;
  final Color color;
  final int? startEventId;
  final int? endEventId;

  IntervalInfo(this.timeRange, this.statusText, this.duration, this.color,
      {this.startEventId, this.endEventId});
}
