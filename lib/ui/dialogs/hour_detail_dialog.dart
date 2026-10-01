import 'package:flutter/material.dart';

import '../../models/hour_segment.dart';
import '../../utils/app_formatters.dart';

/// Діалог деталей за обрану годину (AlertDialog з розбивкою сегментів).
class HourDetailDialog extends StatelessWidget {
  final int hour;
  final List<HourSegment> segments;

  const HourDetailDialog({
    super.key,
    required this.hour,
    required this.segments,
  });

  static Future<void> show({
    required BuildContext context,
    required int hour,
    required List<HourSegment> segments,
  }) {
    return showDialog(
      context: context,
      builder: (ctx) => HourDetailDialog(hour: hour, segments: segments),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text("Деталі за $hour:00"),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        children: segments.map((s) {
          final startM = (s.start * 60).toInt();
          final endM = (s.end * 60).toInt();
          return ListTile(
            leading: CircleAvatar(backgroundColor: s.color, radius: 8),
            title: Text(
                "${AppFormatters.fmtHM(hour, startM)} - ${AppFormatters.fmtHM(hour, endM)}"),
            subtitle: Text(s.isFuture ? "Прогноз" : "Фактичні дані"),
          );
        }).toList(),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text("Закрити"),
        ),
      ],
    );
  }
}
