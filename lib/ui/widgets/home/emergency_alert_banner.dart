import 'package:flutter/material.dart';

class EmergencyAlertBanner extends StatelessWidget {
  final bool isActive;
  final bool isStale;

  const EmergencyAlertBanner(
      {super.key, required this.isActive, this.isStale = false});

  @override
  Widget build(BuildContext context) {
    if (!isActive) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final colors = theme.colorScheme;
    final accent = theme.brightness == Brightness.dark
        ? const Color(0xFFE4B84C)
        : const Color(0xFF8C690C);
    return Semantics(
      liveRegion: true,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 280),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: colors.onSurface.withValues(alpha: 0.035),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: accent.withValues(alpha: 0.35)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(Icons.warning_amber_rounded, color: accent, size: 18),
          const SizedBox(width: 8),
          Flexible(
              child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                  isStale
                      ? 'Останні дані: екстрені відключення'
                      : 'Зараз діють екстрені відключення',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      height: 1.3,
                      color: colors.onSurface)),
              Text(
                  isStale
                      ? 'Не вдалося отримати актуальні дані'
                      : 'Можливі відхилення від графіків',
                  style: TextStyle(
                      fontSize: 11,
                      height: 1.3,
                      color: colors.onSurfaceVariant)),
            ],
          )),
        ]),
      ),
    );
  }
}
