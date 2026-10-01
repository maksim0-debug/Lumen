import 'package:flutter/material.dart';

import '../../../services/darkness_theme_service.dart';

/// Банер поточної стадії тьми (показується коли автотема ввімкнена).
class DarknessStageBanner extends StatelessWidget {
  final DarknessThemeService? darknessService;

  const DarknessStageBanner({
    super.key,
    this.darknessService,
  });

  @override
  Widget build(BuildContext context) {
    final service = darknessService ?? DarknessThemeService();
    if (!service.isEnabled) return const SizedBox.shrink();

    final stage = service.currentStage;
    final icon = DarknessThemeService.stageIcon(stage);
    final name = DarknessThemeService.stageName(stage);
    final subtitle = DarknessThemeService.stageSubtitle(stage);
    final accent = DarknessThemeService.stageAccentColor(stage);
    final secondary = DarknessThemeService.stageSecondaryColor(stage);
    final flutterIcon = DarknessThemeService.stageFlutterIcon(stage);

    // Stalker mode: более жёсткий и тревожный стиль
    final isStalker = stage == DarknessStage.stalker;
    final isCyberpunk = stage == DarknessStage.cyberpunk;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      padding: EdgeInsets.symmetric(
        horizontal: isStalker ? 8 : 12,
        vertical: isStalker ? 8 : 6,
      ),
      decoration: BoxDecoration(
        color: isStalker
            ? Colors.black
            : isCyberpunk
                ? const Color(0xFF08081A)
                : accent.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(isStalker ? 2 : 10),
        border: Border.all(
          color: isStalker
              ? accent.withValues(alpha: 0.6)
              : accent.withValues(alpha: 0.3),
          width: isStalker ? 1.5 : 1,
        ),
        boxShadow: isCyberpunk || isStalker
            ? [
                BoxShadow(
                  color: accent.withValues(alpha: isStalker ? 0.15 : 0.2),
                  blurRadius: isStalker ? 8 : 12,
                  spreadRadius: 0,
                ),
              ]
            : null,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            flutterIcon,
            color: isStalker ? secondary : accent,
            size: isStalker ? 18 : 16,
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  isStalker ? '[ $name ]' : '$icon $name',
                  style: TextStyle(
                    fontSize: isStalker ? 11 : 12,
                    color: accent,
                    fontWeight: FontWeight.bold,
                    fontFamily: isStalker ? 'monospace' : null,
                    letterSpacing: isStalker ? 2 : (isCyberpunk ? 1 : 0),
                  ),
                ),
                Text(
                  isStalker ? subtitle.toUpperCase() : subtitle,
                  style: TextStyle(
                    fontSize: 9,
                    color: accent.withValues(alpha: 0.6),
                    fontFamily: isStalker ? 'monospace' : null,
                    letterSpacing: isStalker ? 1.5 : 0,
                  ),
                ),
              ],
            ),
          ),
          if (isStalker) ...[
            const SizedBox(width: 8),
            Icon(
              Icons.warning_amber,
              color: secondary,
              size: 14,
            ),
          ],
        ],
      ),
    );
  }
}
