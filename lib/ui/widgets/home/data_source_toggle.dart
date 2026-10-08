import 'package:flutter/material.dart';

import '../../../models/data_source_mode.dart';
import '../../helpers/horizontal_swipe_detector.dart';
import 'power_status_badge.dart';

/// Віджет перемикача "Прогноз / Реальне".
class DataSourceToggle extends StatelessWidget {
  /// Screen width breakpoint (dp) for phantom balancing without a notice.
  /// On screens >= 420dp (tablets, desktop, wide phones), phantom badge balancing
  /// guarantees that the central forecast/real chips remain mathematically centered
  /// without being displaced when badge size changes.
  /// On mobile screens (< 420dp), omit phantom balancer so elements fit cleanly
  /// on screen without creating empty left whitespace or pushing the badge off-screen.
  static const double wideScreenBreakpoint = 420.0;

  final bool powerMonitorEnabled;
  final DataSourceMode currentMode;
  final ValueChanged<DataSourceMode> onModeChanged;
  final String powerStatus;

  /// An informational notice that remains visible when monitoring is disabled.
  final Widget? leadingNotice;

  const DataSourceToggle({
    super.key,
    required this.powerMonitorEnabled,
    required this.currentMode,
    required this.onModeChanged,
    required this.powerStatus,
    this.leadingNotice,
  });

  @override
  Widget build(BuildContext context) {
    if (!powerMonitorEnabled) {
      return leadingNotice == null
          ? const SizedBox.shrink()
          : Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: Align(
                  heightFactor: 1,
                  alignment: AlignmentDirectional.centerStart,
                  child: leadingNotice),
            );
    }

    final badge = PowerStatusBadge(
      enabled: powerMonitorEnabled,
      powerStatus: powerStatus,
    );

    return LayoutBuilder(
      builder: (context, constraints) {
        final isWide = constraints.maxWidth >= wideScreenBreakpoint;
        final hPadding = isWide ? 12.0 : 8.0;
        const spacing = 8.0;

        final forecastChip = ChoiceChip(
          showCheckmark: true,
          label: const Text('📋 Прогноз'),
          selected: currentMode == DataSourceMode.predicted,
          selectedColor: Colors.orange.withValues(alpha: 0.3),
          onSelected: (selected) {
            if (selected) onModeChanged(DataSourceMode.predicted);
          },
        );
        final realChip = ChoiceChip(
          showCheckmark: true,
          label: const Text('⚡ Реальне'),
          selected: currentMode == DataSourceMode.real,
          selectedColor: Colors.amber.withValues(alpha: 0.3),
          onSelected: (selected) {
            if (selected) onModeChanged(DataSourceMode.real);
          },
        );

        if (leadingNotice != null) {
          // Reserve symmetrical side columns so the mode chips stay centered.
          // Enlarged text uses the stacked layout before the notice can collide
          // with the controls; Wrap keeps every control reachable on phones.
          final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final inline = constraints.hasBoundedWidth &&
              constraints.maxWidth >= 800 * (textScale < 1 ? 1 : textScale);
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: inline
                ? _withSwipeGestures(Row(children: [
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsetsDirectional.only(end: 16),
                        child: Align(
                            heightFactor: 1,
                            alignment: AlignmentDirectional.centerStart,
                            child: leadingNotice),
                      ),
                    ),
                    forecastChip,
                    const SizedBox(width: spacing),
                    realChip,
                    Expanded(
                      child: Padding(
                        padding:
                            const EdgeInsetsDirectional.only(start: spacing),
                        child: Align(
                            heightFactor: 1,
                            alignment: AlignmentDirectional.centerStart,
                            child: badge),
                      ),
                    ),
                  ]))
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Align(
                          heightFactor: 1,
                          alignment: AlignmentDirectional.centerStart,
                          child: leadingNotice),
                      const SizedBox(height: 4),
                      _withSwipeGestures(Wrap(
                        alignment: WrapAlignment.center,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: spacing,
                        children: [forecastChip, realChip, badge],
                      )),
                    ],
                  ),
          );
        }

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
          forecastChip,
          const SizedBox(width: spacing),
          realChip,
          const SizedBox(width: spacing),
          badge,
        ];

        final minInnerWidth =
            constraints.hasBoundedWidth && constraints.maxWidth > (hPadding * 2)
                ? constraints.maxWidth - (hPadding * 2)
                : 0.0;

        return _withSwipeGestures(Padding(
          padding: EdgeInsets.symmetric(horizontal: hPadding, vertical: 4.0),
          child: SingleChildScrollView(
            physics: const NeverScrollableScrollPhysics(),
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: minInnerWidth),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: children,
              ),
            ),
          ),
        ));
      },
    );
  }

  Widget _withSwipeGestures(Widget child) => HorizontalSwipeDetector(
        behavior: HitTestBehavior.opaque,
        onSwipeLeft: () {
          if (currentMode != DataSourceMode.real) {
            onModeChanged(DataSourceMode.real);
          }
        },
        onSwipeRight: () {
          if (currentMode != DataSourceMode.predicted) {
            onModeChanged(DataSourceMode.predicted);
          }
        },
        child: child,
      );
}
