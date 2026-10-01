import 'package:flutter/material.dart';

import '../../../models/data_source_mode.dart';
import 'power_status_badge.dart';

/// Віджет перемикача "Прогноз / Реальне".
class DataSourceToggle extends StatelessWidget {
  final bool powerMonitorEnabled;
  final DataSourceMode currentMode;
  final ValueChanged<DataSourceMode> onModeChanged;
  final String powerStatus;

  const DataSourceToggle({
    super.key,
    required this.powerMonitorEnabled,
    required this.currentMode,
    required this.onModeChanged,
    required this.powerStatus,
  });

  @override
  Widget build(BuildContext context) {
    if (!powerMonitorEnabled) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12.0, vertical: 4.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          ChoiceChip(
            label: const Text('📋 Прогноз'),
            selected: currentMode == DataSourceMode.predicted,
            selectedColor: Colors.orange.withValues(alpha: 0.3),
            onSelected: (selected) {
              if (selected) {
                onModeChanged(DataSourceMode.predicted);
              }
            },
          ),
          const SizedBox(width: 8),
          ChoiceChip(
            label: const Text('⚡ Реальне'),
            selected: currentMode == DataSourceMode.real,
            selectedColor: Colors.amber.withValues(alpha: 0.3),
            onSelected: (selected) {
              if (selected) {
                onModeChanged(DataSourceMode.real);
              }
            },
          ),
          const SizedBox(width: 4),
          PowerStatusBadge(
            enabled: powerMonitorEnabled,
            powerStatus: powerStatus,
          ),
        ],
      ),
    );
  }
}
