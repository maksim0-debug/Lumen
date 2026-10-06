import '../../../services/schedule_clock.dart';
import 'dart:async';
import 'package:flutter/material.dart';

import '../../../models/schedule_status.dart';
import '../../../services/countdown_service.dart';
import '../../../services/darkness_theme_service.dart';
import '../../../theme/darkness_stage_style.dart';

class CountdownCard extends StatefulWidget {
  final FullSchedule? fullSchedule;

  const CountdownCard({
    super.key,
    required this.fullSchedule,
  });

  @override
  State<CountdownCard> createState() => _CountdownCardState();
}

class _CountdownCardState extends State<CountdownCard> {
  Timer? _ticker;
  int _lastRenderedMinute = -1;

  @override
  void initState() {
    super.initState();
    _lastRenderedMinute = ScheduleClock.now().minute;
    _scheduleNextMinuteTick();
  }

  void _scheduleNextMinuteTick() {
    _ticker?.cancel();
    final now = ScheduleClock.now();
    final msToNextMinute = (60 - now.second) * 1000 - now.millisecond + 100;
    _ticker = Timer(Duration(milliseconds: msToNextMinute), () {
      if (mounted) {
        if (widget.fullSchedule != null) {
          final currentMinute = ScheduleClock.now().minute;
          if (currentMinute != _lastRenderedMinute) {
            _lastRenderedMinute = currentMinute;
            setState(() {});
          }
        }
        _scheduleNextMinuteTick();
      }
    });
  }

  @override
  void didUpdateWidget(covariant CountdownCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.fullSchedule != widget.fullSchedule) {
      _lastRenderedMinute = ScheduleClock.now().minute;
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (widget.fullSchedule == null) {
      return const SizedBox.shrink();
    }

    final countdown = CountdownService.calculateCountdown(
      today: widget.fullSchedule!.today,
      tomorrow: widget.fullSchedule!.tomorrow,
      now: ScheduleClock.now(),
    );

    if (countdown == null) return const SizedBox.shrink();

    final msg = countdown.message;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final darknessService = DarknessThemeService();
    final stage =
        darknessService.isEnabled ? darknessService.currentStage : null;

    final style = DarknessStageStyle.of(stage).countdownStyle(isDark);

    final baseTextStyle = TextStyle(
      fontSize: 18,
      fontWeight: FontWeight.bold,
      color: style.textColor,
    );
    final finalTextStyle = style.extraStyle != null
        ? baseTextStyle.merge(style.extraStyle)
        : baseTextStyle;

    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        decoration: BoxDecoration(
          color: style.containerColor,
          borderRadius: BorderRadius.circular(style.borderRadius),
          border: style.border,
          boxShadow: style.shadows,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.timer_outlined, color: style.iconColor, size: 24),
            const SizedBox(width: 8),
            Text(msg, style: finalTextStyle),
          ],
        ),
      ),
    );
  }
}
