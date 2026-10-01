import 'package:flutter/material.dart';

import '../../../models/interval_info.dart';

/// Віджет списку "Розклад інтервалами".
class ScheduleIntervalsList extends StatelessWidget {
  final List<IntervalInfo> intervals;
  final void Function(BuildContext context, dynamic interval)?
      onIntervalLongPress;

  const ScheduleIntervalsList({
    super.key,
    required this.intervals,
    this.onIntervalLongPress,
  });

  void _showIntervalMenu(BuildContext context, dynamic interval) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Меню не підтримується для цього режиму")),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (intervals.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 24, 16, 8),
          child: Text(
            "Розклад інтервалами:",
            style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 40),
          child: Card(
            child: Column(
              children: intervals.map((interval) {
                return GestureDetector(
                  onLongPress: () {
                    if (onIntervalLongPress != null) {
                      onIntervalLongPress!(context, interval);
                    } else {
                      _showIntervalMenu(context, interval);
                    }
                  },
                  child: Container(
                    decoration: const BoxDecoration(
                      border: Border(
                        bottom: BorderSide(color: Colors.white10),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 16,
                    ),
                    child: Row(
                      children: [
                        SizedBox(
                          width: 120,
                          child: Text(
                            interval.timeRange,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                              color: interval.statusText.contains("OFF")
                                  ? Colors.red
                                  : (Theme.of(context).brightness ==
                                          Brightness.dark
                                      ? Colors.white
                                      : Colors.black87),
                            ),
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: interval.color.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            interval.statusText,
                            style: TextStyle(
                              color: interval.color,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          "(${interval.duration})",
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),
      ],
    );
  }
}
