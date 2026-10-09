import 'dart:math';
import 'package:flutter/material.dart';
import '../services/darkness_theme_service.dart';

/// Стиль для картки зворотного відліку відповідно до теми.
class CountdownCardStyle {
  final Color containerColor;
  final Color textColor;
  final Color iconColor;
  final double borderRadius;
  final Border? border;
  final List<BoxShadow>? shadows;
  final TextStyle? extraStyle;

  const CountdownCardStyle({
    required this.containerColor,
    required this.textColor,
    required this.iconColor,
    required this.borderRadius,
    this.border,
    this.shadows,
    this.extraStyle,
  });
}

/// Результат оформлення сегмента графіка.
class SegmentDecorationResult {
  final Decoration decoration;
  final Widget? overlay;

  const SegmentDecorationResult({
    required this.decoration,
    this.overlay,
  });
}

/// Стиль оформлення поточної години.
class CurrentHourWrapStyle {
  final Color borderColor;
  final double borderWidth;
  final double radius;
  final List<BoxShadow>? shadows;
  final IconData dotIcon;
  final Color dotColor;
  final double dotSize;

  const CurrentHourWrapStyle({
    required this.borderColor,
    required this.borderWidth,
    required this.radius,
    required this.dotIcon,
    required this.dotColor,
    required this.dotSize,
    this.shadows,
  });
}

/// Централізоване налаштування візуальних стилів для стадій темряви.
abstract class DarknessStageStyle {
  Color get onColor;
  Color get offColor;
  Color get nowLineColor;
  double get borderRadius;
  TextStyle get cellTextStyle;

  BoxDecoration colorBoxDecoration(bool isOn, Color fallbackColor);
  BoxDecoration gradientBoxDecoration(
      bool isSemiOn, List<Color> colors, Color onColor);
  BoxDecoration maybeBoxDecoration();
  BoxDecoration emptyBoxDecoration();
  CurrentHourWrapStyle currentHourStyle();
  CountdownCardStyle countdownStyle(bool isDark);
  SegmentDecorationResult segmentDecoration({
    required bool isFuture,
    required bool isSegmentOn,
    required Color themeColor,
    required int seed,
  });

  static DarknessStageStyle of(DarknessStage? stage) {
    switch (stage) {
      case DarknessStage.solarpunk:
        return const _SolarpunkStyle();
      case DarknessStage.dieselpunk:
        return const _DieselpunkStyle();
      case DarknessStage.cyberpunk:
        return const _CyberpunkStyle();
      case DarknessStage.stalker:
        return const _StalkerStyle();
      default:
        return const _DefaultStageStyle();
    }
  }
}

// -------------------------------------------------------------
// DEFAULT THEME STYLE
// -------------------------------------------------------------
class _DefaultStageStyle implements DarknessStageStyle {
  const _DefaultStageStyle();

  @override
  Color get onColor => Colors.green.shade400;

  @override
  Color get offColor => Colors.red.shade400;

  @override
  Color get nowLineColor => Colors.white.withValues(alpha: 0.9);

  @override
  double get borderRadius => 6.0;

  @override
  TextStyle get cellTextStyle => const TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 13,
        color: Colors.white,
      );

  @override
  BoxDecoration colorBoxDecoration(bool isOn, Color fallbackColor) {
    return BoxDecoration(
      color: fallbackColor,
      borderRadius: BorderRadius.circular(borderRadius),
    );
  }

  @override
  BoxDecoration gradientBoxDecoration(
      bool isSemiOn, List<Color> colors, Color onColor) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      gradient: LinearGradient(colors: colors, stops: const [0.5, 0.5]),
    );
  }

  @override
  BoxDecoration maybeBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: Colors.grey.shade300,
    );
  }

  @override
  BoxDecoration emptyBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: Colors.grey.shade900,
    );
  }

  @override
  CurrentHourWrapStyle currentHourStyle() {
    return CurrentHourWrapStyle(
      borderColor: Colors.blueAccent,
      borderWidth: 2.5,
      radius: borderRadius,
      dotIcon: Icons.circle,
      dotColor: Colors.blueAccent,
      dotSize: 8,
      shadows: [
        BoxShadow(
          color: Colors.blueAccent.withValues(alpha: 0.3),
          blurRadius: 6,
          spreadRadius: 1,
        ),
      ],
    );
  }

  @override
  CountdownCardStyle countdownStyle(bool isDark) {
    return CountdownCardStyle(
      containerColor: isDark ? const Color(0xFF2C2C2C) : Colors.grey.shade300,
      textColor: isDark ? Colors.white : Colors.black87,
      iconColor: Colors.orange,
      borderRadius: 12,
    );
  }

  @override
  SegmentDecorationResult segmentDecoration({
    required bool isFuture,
    required bool isSegmentOn,
    required Color themeColor,
    required int seed,
  }) {
    if (isFuture) {
      return SegmentDecorationResult(
        decoration: BoxDecoration(color: themeColor.withValues(alpha: 0.4)),
      );
    }
    return SegmentDecorationResult(
      decoration: BoxDecoration(color: themeColor),
    );
  }
}

// -------------------------------------------------------------
// SOLARPUNK THEME STYLE
// -------------------------------------------------------------
class _SolarpunkStyle implements DarknessStageStyle {
  const _SolarpunkStyle();

  @override
  Color get onColor => const Color(0xFF4CAF50);

  @override
  Color get offColor => const Color(0xFFBF360C);

  @override
  Color get nowLineColor => const Color(0xFF2E7D32);

  @override
  double get borderRadius => 14.0;

  @override
  TextStyle get cellTextStyle => const TextStyle(
        fontWeight: FontWeight.w600,
        fontSize: 13,
        color: Colors.white,
        shadows: [Shadow(blurRadius: 2, color: Color(0x66000000))],
      );

  @override
  BoxDecoration colorBoxDecoration(bool isOn, Color fallbackColor) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      gradient: LinearGradient(
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
        colors: isOn
            ? [const Color(0xFF66BB6A), const Color(0xFF43A047)]
            : [const Color(0xFFE57373), const Color(0xFFBF360C)],
      ),
      boxShadow: [
        BoxShadow(
          color: fallbackColor.withValues(alpha: 0.25),
          blurRadius: 6,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  @override
  BoxDecoration gradientBoxDecoration(
      bool isSemiOn, List<Color> colors, Color onColor) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      gradient: LinearGradient(
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
        colors: colors,
        stops: const [0.45, 0.55],
      ),
      boxShadow: [
        BoxShadow(
          color: onColor.withValues(alpha: 0.2),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  @override
  BoxDecoration maybeBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: const Color(0xFFBDBDBD),
      boxShadow: [
        BoxShadow(
          color: Colors.grey.withValues(alpha: 0.2),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  @override
  BoxDecoration emptyBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: const Color(0xFF2E2E2E),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.2),
          blurRadius: 4,
          offset: const Offset(0, 2),
        ),
      ],
    );
  }

  @override
  CurrentHourWrapStyle currentHourStyle() {
    return CurrentHourWrapStyle(
      borderColor: const Color(0xFF2E7D32),
      borderWidth: 2.5,
      radius: borderRadius,
      dotIcon: Icons.access_time_filled,
      dotColor: const Color(0xFF2E7D32),
      dotSize: 10,
      shadows: [
        BoxShadow(
          color: const Color(0xFF2E7D32).withValues(alpha: 0.3),
          blurRadius: 8,
          spreadRadius: 1,
        ),
      ],
    );
  }

  @override
  CountdownCardStyle countdownStyle(bool isDark) {
    return CountdownCardStyle(
      containerColor: const Color(0xFF1B5E20).withValues(alpha: 0.85),
      textColor: const Color(0xFFE8F5E9),
      iconColor: const Color(0xFF66BB6A),
      borderRadius: 16,
      shadows: [
        BoxShadow(
          color: const Color(0xFF66BB6A).withValues(alpha: 0.2),
          blurRadius: 8,
          spreadRadius: 1,
        ),
      ],
    );
  }

  @override
  SegmentDecorationResult segmentDecoration({
    required bool isFuture,
    required bool isSegmentOn,
    required Color themeColor,
    required int seed,
  }) {
    if (isFuture) {
      return SegmentDecorationResult(
        decoration: BoxDecoration(
          color: themeColor.withValues(alpha: 0.35),
          border:
              Border.all(color: themeColor.withValues(alpha: 0.5), width: 0.5),
        ),
        overlay: CustomPaint(
          painter:
              GridOverlayPainter(color: themeColor.withValues(alpha: 0.15)),
        ),
      );
    }
    return SegmentDecorationResult(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: isSegmentOn
              ? [const Color(0xFF66BB6A), const Color(0xFF43A047)]
              : [const Color(0xFFE57373), const Color(0xFFBF360C)],
        ),
      ),
    );
  }
}

// -------------------------------------------------------------
// DIESELPUNK THEME STYLE
// -------------------------------------------------------------
class _DieselpunkStyle implements DarknessStageStyle {
  const _DieselpunkStyle();

  @override
  Color get onColor => const Color(0xFFB8860B);

  @override
  Color get offColor => const Color(0xFF4E342E);

  @override
  Color get nowLineColor => const Color(0xFFFF9800);

  @override
  double get borderRadius => 4.0;

  @override
  TextStyle get cellTextStyle => const TextStyle(
        fontWeight: FontWeight.w900,
        fontSize: 12,
        color: Color(0xFFFFD54F),
        letterSpacing: 0.5,
        shadows: [
          Shadow(blurRadius: 3, color: Color(0x88000000)),
        ],
      );

  @override
  BoxDecoration colorBoxDecoration(bool isOn, Color fallbackColor) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: fallbackColor,
      border: Border.all(
        color: const Color(0xFFFF9800).withValues(alpha: 0.3),
        width: 1.5,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.5),
          blurRadius: 4,
          offset: const Offset(2, 2),
        ),
      ],
    );
  }

  @override
  BoxDecoration gradientBoxDecoration(
      bool isSemiOn, List<Color> colors, Color onColor) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      gradient: LinearGradient(colors: colors, stops: const [0.5, 0.5]),
      border: Border.all(
        color: const Color(0xFFFF9800).withValues(alpha: 0.3),
        width: 1.5,
      ),
      boxShadow: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.4),
          blurRadius: 3,
          offset: const Offset(1, 1),
        ),
      ],
    );
  }

  @override
  BoxDecoration maybeBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: const Color(0xFF3E2723),
      border: Border.all(
        color: const Color(0xFF795548).withValues(alpha: 0.4),
        width: 1,
      ),
    );
  }

  @override
  BoxDecoration emptyBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: const Color(0xFF1A1A1A),
      border: Border.all(
        color: const Color(0xFFFF9800).withValues(alpha: 0.2),
        width: 1,
      ),
    );
  }

  @override
  CurrentHourWrapStyle currentHourStyle() {
    return CurrentHourWrapStyle(
      borderColor: const Color(0xFFFF9800),
      borderWidth: 3,
      radius: borderRadius,
      dotIcon: Icons.circle,
      dotColor: const Color(0xFFFF9800),
      dotSize: 8,
      shadows: [
        BoxShadow(
          color: const Color(0xFFFF9800).withValues(alpha: 0.3),
          blurRadius: 6,
          spreadRadius: 1,
        ),
      ],
    );
  }

  @override
  CountdownCardStyle countdownStyle(bool isDark) {
    return CountdownCardStyle(
      containerColor: const Color(0xFF1A1A1A),
      textColor: const Color(0xFFFFD54F),
      iconColor: const Color(0xFFFF9800),
      borderRadius: 4,
      border: Border.all(
        color: const Color(0xFFFF9800).withValues(alpha: 0.35),
        width: 1.5,
      ),
      shadows: [
        BoxShadow(
          color: Colors.black.withValues(alpha: 0.6),
          blurRadius: 4,
          offset: const Offset(2, 2),
        ),
      ],
      extraStyle: const TextStyle(
        fontWeight: FontWeight.w900,
        letterSpacing: 0.5,
      ),
    );
  }

  @override
  SegmentDecorationResult segmentDecoration({
    required bool isFuture,
    required bool isSegmentOn,
    required Color themeColor,
    required int seed,
  }) {
    if (isFuture) {
      return SegmentDecorationResult(
        decoration: BoxDecoration(color: themeColor.withValues(alpha: 0.5)),
        overlay: ClipRect(
          child: CustomPaint(
            painter: DiagonalStripesPainter(
              color: Colors.black.withValues(alpha: 0.2),
              spacing: 4,
            ),
          ),
        ),
      );
    }
    return SegmentDecorationResult(
      decoration: BoxDecoration(color: themeColor),
    );
  }
}

// -------------------------------------------------------------
// CYBERPUNK THEME STYLE
// -------------------------------------------------------------
class _CyberpunkStyle implements DarknessStageStyle {
  const _CyberpunkStyle();

  @override
  Color get onColor => const Color(0xFF00BFA5);

  @override
  Color get offColor => const Color(0xFFAD1457);

  @override
  Color get nowLineColor => const Color(0xFFFF0080);

  @override
  double get borderRadius => 8.0;

  @override
  TextStyle get cellTextStyle => const TextStyle(
        fontFamily: 'Courier',
        fontWeight: FontWeight.bold,
        fontSize: 13,
        color: Color(0xFF00FFFF),
        shadows: [Shadow(blurRadius: 4, color: Color(0xFF00FFFF))],
      );

  @override
  BoxDecoration colorBoxDecoration(bool isOn, Color fallbackColor) {
    final neonColor = isOn ? const Color(0xFF00FFFF) : const Color(0xFFFF0080);
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: fallbackColor,
      border: Border.all(color: neonColor.withValues(alpha: 0.5), width: 1),
      boxShadow: [
        BoxShadow(
          color: neonColor.withValues(alpha: 0.2),
          blurRadius: 10,
          spreadRadius: 1,
        ),
      ],
    );
  }

  @override
  BoxDecoration gradientBoxDecoration(
      bool isSemiOn, List<Color> colors, Color onColor) {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      gradient: LinearGradient(colors: colors, stops: const [0.5, 0.5]),
      border: Border.all(
        color: const Color(0xFFBB86FC).withValues(alpha: 0.4),
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFFBB86FC).withValues(alpha: 0.15),
          blurRadius: 8,
          spreadRadius: 1,
        ),
      ],
    );
  }

  @override
  BoxDecoration maybeBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: const Color(0xFF12122A),
      border: Border.all(
        color: const Color(0xFF2A2A4A),
        width: 1,
      ),
    );
  }

  @override
  BoxDecoration emptyBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: const Color(0xFF0A0E21),
      border: Border.all(
        color: const Color(0xFF2A2A4A),
        width: 1,
      ),
      boxShadow: [
        BoxShadow(
          color: const Color(0xFF00FFFF).withValues(alpha: 0.08),
          blurRadius: 6,
        ),
      ],
    );
  }

  @override
  CurrentHourWrapStyle currentHourStyle() {
    return CurrentHourWrapStyle(
      borderColor: const Color(0xFF00FFFF),
      borderWidth: 2,
      radius: borderRadius,
      dotIcon: Icons.bolt,
      dotColor: const Color(0xFF00FFFF),
      dotSize: 12,
      shadows: [
        BoxShadow(
          color: const Color(0xFF00FFFF).withValues(alpha: 0.4),
          blurRadius: 10,
          spreadRadius: 1,
        ),
        BoxShadow(
          color: const Color(0xFFFF0080).withValues(alpha: 0.2),
          blurRadius: 20,
          spreadRadius: 2,
        ),
      ],
    );
  }

  @override
  CountdownCardStyle countdownStyle(bool isDark) {
    return CountdownCardStyle(
      containerColor: const Color(0xFF0A0E21),
      textColor: const Color(0xFF00FFFF),
      iconColor: const Color(0xFFFF0080),
      borderRadius: 8,
      border: Border.all(
        color: const Color(0xFF00FFFF).withValues(alpha: 0.4),
        width: 1,
      ),
      shadows: [
        BoxShadow(
          color: const Color(0xFF00FFFF).withValues(alpha: 0.2),
          blurRadius: 12,
          spreadRadius: 1,
        ),
      ],
      extraStyle: const TextStyle(
        fontWeight: FontWeight.w700,
        letterSpacing: 0.8,
      ),
    );
  }

  @override
  SegmentDecorationResult segmentDecoration({
    required bool isFuture,
    required bool isSegmentOn,
    required Color themeColor,
    required int seed,
  }) {
    if (isFuture) {
      return SegmentDecorationResult(
        decoration: BoxDecoration(
          color: themeColor.withValues(alpha: 0.2),
          border: Border.all(color: themeColor, width: 1),
        ),
        overlay: Column(
          children: List.generate(
            10,
            (index) => Expanded(
              child: Container(
                margin: const EdgeInsets.only(bottom: 1),
                color: themeColor.withValues(alpha: 0.1),
              ),
            ),
          ),
        ),
      );
    }
    return SegmentDecorationResult(
      decoration: BoxDecoration(
        color: themeColor,
        border: Border(
          top: BorderSide(
            color: (isSegmentOn
                    ? const Color(0xFF00FFFF)
                    : const Color(0xFFFF0080))
                .withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
    );
  }
}

// -------------------------------------------------------------
// STALKER THEME STYLE
// -------------------------------------------------------------
class _StalkerStyle implements DarknessStageStyle {
  const _StalkerStyle();

  @override
  Color get onColor => const Color(0xFF1B5E20);

  @override
  Color get offColor => const Color(0xFF8B0000);

  @override
  Color get nowLineColor => const Color(0xFFFF1744);

  @override
  double get borderRadius => 2.0;

  @override
  TextStyle get cellTextStyle => const TextStyle(
        fontFamily: 'RobotoMono',
        fontWeight: FontWeight.bold,
        fontSize: 12,
        color: Color(0xFF39FF14),
        shadows: [
          Shadow(blurRadius: 2, color: Color(0xFF39FF00)),
          Shadow(blurRadius: 8, color: Colors.black),
        ],
      );

  @override
  BoxDecoration colorBoxDecoration(bool isOn, Color fallbackColor) {
    final borderColor = isOn
        ? const Color(0xFF39FF14).withValues(alpha: 0.4)
        : const Color(0xFFFF1744).withValues(alpha: 0.5);
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: isOn ? const Color(0xFF0A1F0A) : const Color(0xFF1A0000),
      border: Border.all(color: borderColor, width: 1),
    );
  }

  @override
  BoxDecoration gradientBoxDecoration(
      bool isSemiOn, List<Color> colors, Color onColor) {
    const cOn = Color(0xFF0A1F0A);
    const cOff = Color(0xFF1A0000);
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      gradient: LinearGradient(
        colors: isSemiOn ? [cOff, cOn] : [cOn, cOff],
        stops: const [0.5, 0.5],
      ),
      border: Border.all(
        color: const Color(0xFF39FF14).withValues(alpha: 0.4),
        width: 1,
      ),
    );
  }

  @override
  BoxDecoration maybeBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: const Color(0xFF0A0A0A),
      border: Border.all(
        color: const Color(0xFF39FF14).withValues(alpha: 0.15),
        width: 1,
      ),
    );
  }

  @override
  BoxDecoration emptyBoxDecoration() {
    return BoxDecoration(
      borderRadius: BorderRadius.circular(borderRadius),
      color: const Color(0xFF050505),
      border: Border.all(
        color: const Color(0xFF39FF14).withValues(alpha: 0.2),
        width: 1,
      ),
    );
  }

  @override
  CurrentHourWrapStyle currentHourStyle() {
    return CurrentHourWrapStyle(
      borderColor: const Color(0xFFFF1744),
      borderWidth: 2,
      radius: borderRadius,
      dotIcon: Icons.warning_amber_rounded,
      dotColor: const Color(0xFFFF1744),
      dotSize: 10,
      shadows: [
        BoxShadow(
          color: const Color(0xFFFF1744).withValues(alpha: 0.4),
          blurRadius: 6,
          spreadRadius: 1,
        ),
      ],
    );
  }

  @override
  CountdownCardStyle countdownStyle(bool isDark) {
    return CountdownCardStyle(
      containerColor: const Color(0xFF050505),
      textColor: const Color(0xFF39FF14),
      iconColor: const Color(0xFF39FF14),
      borderRadius: 2,
      border: Border.all(
        color: const Color(0xFF39FF14).withValues(alpha: 0.3),
        width: 1,
      ),
      extraStyle: const TextStyle(
        fontWeight: FontWeight.bold,
        fontFamily: 'monospace',
        letterSpacing: 2,
        shadows: [
          Shadow(blurRadius: 4, color: Color(0xFF39FF14)),
        ],
      ),
    );
  }

  @override
  SegmentDecorationResult segmentDecoration({
    required bool isFuture,
    required bool isSegmentOn,
    required Color themeColor,
    required int seed,
  }) {
    if (isFuture) {
      return SegmentDecorationResult(
        decoration: BoxDecoration(
          color:
              Color.lerp(themeColor, Colors.grey, 0.7)!.withValues(alpha: 0.4),
        ),
        overlay: CustomPaint(painter: NoisePainter(seed: seed)),
      );
    }
    return SegmentDecorationResult(
      decoration: BoxDecoration(color: themeColor),
    );
  }
}

// -------------------------------------------------------------
// CUSTOM PAINTERS FOR STYLES
// -------------------------------------------------------------
class GridOverlayPainter extends CustomPainter {
  final Color color;
  const GridOverlayPainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    const step = 6.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant GridOverlayPainter oldDelegate) =>
      oldDelegate.color != color;
}

class DiagonalStripesPainter extends CustomPainter {
  final Color color;
  final double spacing;
  const DiagonalStripesPainter({required this.color, this.spacing = 10.0});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 4
      ..style = PaintingStyle.stroke;

    for (double i = -size.height; i < size.width + size.height; i += spacing) {
      canvas.drawLine(
          Offset(i, 0), Offset(i + size.height, size.height), paint);
    }
  }

  @override
  bool shouldRepaint(covariant DiagonalStripesPainter old) =>
      old.color != color || old.spacing != spacing;
}

class NoisePainter extends CustomPainter {
  final int seed;
  const NoisePainter({required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final random = Random(seed);
    final paint = Paint()..strokeWidth = 1;

    for (int i = 0; i < 100; i++) {
      paint.color = Colors.white.withValues(alpha: random.nextDouble() * 0.1);
      final x = random.nextDouble() * size.width;
      final y = random.nextDouble() * size.height;
      canvas.drawRect(Rect.fromLTWH(x, y, 1, 1), paint);
    }
  }

  @override
  bool shouldRepaint(covariant NoisePainter old) => old.seed != seed;
}

class ScanlinePainter extends CustomPainter {
  final Color color;
  const ScanlinePainter({required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = 1;
    for (double y = 0; y < size.height; y += 3) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant ScanlinePainter old) => old.color != color;
}
