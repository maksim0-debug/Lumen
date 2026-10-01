import 'package:flutter/material.dart';

/// Віджет індикатора реального часу (220В статус).
class PowerStatusBadge extends StatelessWidget {
  final bool enabled;
  final String powerStatus;

  const PowerStatusBadge({
    super.key,
    this.enabled = true,
    required this.powerStatus,
  });

  @override
  Widget build(BuildContext context) {
    if (!enabled) return const SizedBox.shrink();

    final isOnline = powerStatus == 'online';
    final isOffline = powerStatus == 'offline';

    final Color bgColor;
    final Color textColor;
    final String label;
    final IconData icon;

    if (isOnline) {
      bgColor = Colors.green.withValues(alpha: 0.15);
      textColor = Colors.green;
      label = "ON";
      icon = Icons.power;
    } else if (isOffline) {
      bgColor = Colors.red.withValues(alpha: 0.15);
      textColor = Colors.red;
      label = "OFF";
      icon = Icons.power_off;
    } else {
      bgColor = Colors.grey.withValues(alpha: 0.15);
      textColor = Colors.grey;
      label = "...";
      icon = Icons.pending;
    }

    return Container(
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: textColor.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: textColor, size: 16),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: textColor,
              fontSize: 12,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}
