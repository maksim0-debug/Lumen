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

    final badge = PowerStatusBadge(
      enabled: powerMonitorEnabled,
      powerStatus: powerStatus,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        // On wide screens (>= 420dp), use symmetrical phantom balancer on the left
        // to guarantee that the central forecast/real chips remain mathematically centered
        // without being displaced when badge size changes.
        // On mobile screens (< 420dp), omit phantom balancer so elements fit cleanly
        // on screen without creating empty left whitespace or pushing the badge off-screen.
        final isWide = constraints.maxWidth >= 420.0;
        final hPadding = isWide ? 12.0 : 8.0;
        const spacing = 8.0;

        final children = <Widget>[
          if (isWide) ...[
            IgnorePointer(
              child: Visibility(
                maintainSize: true,
                maintainAnimation: true,
                maintainState: true,
                maintainSemantics: false,
                visible: false,
                child: badge,
              ),
            ),
            const SizedBox(width: spacing),
          ],
          ChoiceChip(
            showCheckmark: true,
            label: const Text('📋 Прогноз'),
            selected: currentMode == DataSourceMode.predicted,
            selectedColor: Colors.orange.withValues(alpha: 0.3),
            onSelected: (selected) {
              if (selected) {
                onModeChanged(DataSourceMode.predicted);
              }
            },
          ),
          const SizedBox(width: spacing),
          ChoiceChip(
            showCheckmark: true,
            label: const Text('⚡ Реальне'),
            selected: currentMode == DataSourceMode.real,
            selectedColor: Colors.amber.withValues(alpha: 0.3),
            onSelected: (selected) {
              if (selected) {
                onModeChanged(DataSourceMode.real);
              }
            },
          ),
          const SizedBox(width: spacing),
          badge,
        ];

        final minInnerWidth =
            constraints.hasBoundedWidth && constraints.maxWidth > (hPadding * 2)
                ? constraints.maxWidth - (hPadding * 2)
                : 0.0;

        return Padding(
          padding: EdgeInsets.symmetric(horizontal: hPadding, vertical: 4.0),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: minInnerWidth),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: children,
              ),
            ),
          ),
        );
      },
    );
  }
}
