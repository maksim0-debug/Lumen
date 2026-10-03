import 'package:flutter/material.dart';

import '../../../services/power_monitor_service.dart';

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

    final isDark = Theme.of(context).brightness == Brightness.dark;
    final isOnline = powerStatus == 'online';
    final isOffline = powerStatus == 'offline';

    final Color bgColor;
    final Color textColor;
    final String label;
    final IconData icon;
    final String tooltipMessage;

    final Color snackBarIconColor;

    if (isOnline) {
      bgColor = Colors.green.withValues(alpha: 0.15);
      textColor = isDark ? Colors.greenAccent.shade200 : Colors.green.shade800;
      snackBarIconColor = Colors.greenAccent.shade200;
      label = "ON";
      icon = Icons.power;
      tooltipMessage = "Електроенергія є (ON). Дані актуальні.";
    } else if (isOffline) {
      bgColor = Colors.red.withValues(alpha: 0.15);
      textColor = isDark ? Colors.redAccent.shade100 : Colors.red.shade700;
      snackBarIconColor = Colors.redAccent.shade100;
      label = "OFF";
      icon = Icons.power_off;
      tooltipMessage = "Електроенергії немає (OFF). Зафіксовано сенсором.";
    } else {
      bgColor = isDark ? Colors.white10 : Colors.black.withValues(alpha: 0.06);
      textColor = isDark ? Colors.grey.shade300 : Colors.grey.shade700;
      snackBarIconColor = Colors.grey.shade300;
      label = "N/A";
      icon = Icons.help_outline;

      final snapshot = PowerMonitorService().snapshot;
      final reasonMsg = snapshot.reason.userMessage;
      tooltipMessage = "Стан невідомий: $reasonMsg";
    }

    return Tooltip(
      message: tooltipMessage,
      child: Material(
        color: bgColor,
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Row(
                  children: [
                    Icon(icon, color: snackBarIconColor, size: 20),
                    const SizedBox(width: 8),
                    Expanded(child: Text(tooltipMessage)),
                  ],
                ),
                duration: const Duration(seconds: 3),
                behavior: SnackBarBehavior.floating,
              ),
            );
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
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
          ),
        ),
      ),
    );
  }
}
