import 'dart:async';
import 'dart:math';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../services/darkness_theme_service.dart';

/// Wraps a grid cell widget and applies a per-theme animation.
///
/// When [stage] is null (themes disabled), returns [child] as-is.
class ThemeAnimatedCell extends StatefulWidget {
  final DarknessStage? stage;
  final Widget child;

  const ThemeAnimatedCell({
    super.key,
    required this.stage,
    required this.child,
  });

  @override
  State<ThemeAnimatedCell> createState() => _ThemeAnimatedCellState();
}

class _ThemeAnimatedCellState extends State<ThemeAnimatedCell>
    with TickerProviderStateMixin {
  // ── Solarpunk: breathing ──
  AnimationController? _breathController;

  // ── Dieselpunk: flicker ──
  AnimationController? _flickerController;
  Timer? _flickerTimer;
  double _flickerOpacity = 1.0;
  final _rng = Random();

  // ── Cyberpunk: glitch ──
  Timer? _glitchTimer;
  bool _glitching = false;
  double _glitchOffsetX = 0;
  double _glitchOffsetY = 0;

  // ── Stalker: noise / interference ──
  Timer? _noiseTimer;
  Timer? _interferenceTimer;
  int _noiseSeed = 0;
  double _interferenceY = -1; // -1 = no bar visible
  AnimationController? _interferenceController;

  bool _animationsWasEnabled = true;

  @override
  void initState() {
    super.initState();
    _animationsWasEnabled = DarknessThemeService().areAnimationsEnabled;
    if (_animationsWasEnabled) {
      _initAnimation();
    }
  }

  @override
  void didUpdateWidget(covariant ThemeAnimatedCell old) {
    super.didUpdateWidget(old);
    final isEnabled = DarknessThemeService().areAnimationsEnabled;
    
    if (old.stage != widget.stage || _animationsWasEnabled != isEnabled) {
      _disposeAnimations();
      _animationsWasEnabled = isEnabled;
      if (isEnabled) {
        _initAnimation();
      }
    }
  }

  @override
  void dispose() {
    _disposeAnimations();
    super.dispose();
  }

  // ────────────────────────────────────────
  // Initialization
  // ────────────────────────────────────────

  void _initAnimation() {
    switch (widget.stage) {
      case DarknessStage.solarpunk:
        _initBreathing();
        break;
      case DarknessStage.dieselpunk:
        _initFlicker();
        break;
      case DarknessStage.cyberpunk:
        _initGlitch();
        break;
      case DarknessStage.stalker:
        _initNoise();
        break;
      default:
        break;
    }
  }

  void _disposeAnimations() {
    _breathController?.dispose();
    _breathController = null;

    _flickerController?.dispose();
    _flickerController = null;
    _flickerTimer?.cancel();
    _flickerTimer = null;

    _glitchTimer?.cancel();
    _glitchTimer = null;

    _noiseTimer?.cancel();
    _noiseTimer = null;
    _interferenceTimer?.cancel();
    _interferenceTimer = null;
    _interferenceController?.dispose();
    _interferenceController = null;
  }

  // ────────────────────────────────────────
  // 🌿 Solarpunk — breathing shadow
  // ────────────────────────────────────────

  void _initBreathing() {
    _breathController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat(); // no reverse — sin(t*π) already gives smooth 0→1→0 per cycle
  }

  // ────────────────────────────────────────
  // ⚙️ Dieselpunk — flicker
  // ────────────────────────────────────────

  void _initFlicker() {
    _scheduleNextFlicker();
  }

  void _scheduleNextFlicker() {
    // Variable interval 60–180ms for organic diesel-generator feel
    final delayMs = 60 + _rng.nextInt(120);
    _flickerTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      setState(() {
        _flickerOpacity = 0.9 + _rng.nextDouble() * 0.1; // 0.9 – 1.0
      });
      _scheduleNextFlicker();
    });
  }

  // ────────────────────────────────────────
  // 🌃 Cyberpunk — glitch
  // ────────────────────────────────────────

  void _initGlitch() {
    _scheduleNextGlitch();
  }

  void _scheduleNextGlitch() {
    final delayMs = 60000 + _rng.nextInt(120000); // 1-3 min
    _glitchTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      _triggerGlitch();
    });
  }

  void _triggerGlitch() {
    setState(() {
      _glitching = true;
      _glitchOffsetX = (_rng.nextDouble() - 0.5) * 4; // ±2 px
      _glitchOffsetY = (_rng.nextDouble() - 0.5) * 2; // ±1 px
    });

    // Hold glitch for 150–250ms, then reset
    Future.delayed(Duration(milliseconds: 150 + _rng.nextInt(100)), () {
      if (!mounted) return;
      setState(() {
        _glitching = false;
        _glitchOffsetX = 0;
        _glitchOffsetY = 0;
      });
      _scheduleNextGlitch();
    });
  }

  // ────────────────────────────────────────
  // ☢️ Stalker — noise + interference
  // ────────────────────────────────────────

  void _initNoise() {
    // Repaint noise grain every ~120ms
    _noiseTimer = Timer.periodic(const Duration(milliseconds: 120), (_) {
      if (!mounted) return;
      setState(() {
        _noiseSeed = _rng.nextInt(999999);
      });
    });

    _interferenceController = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 850));
    _interferenceController!.addListener(() {
      setState(() {
        _interferenceY = _interferenceController!.value;
      });
    });
    _interferenceController!.addStatusListener((status) {
      if (status == AnimationStatus.completed) {
        setState(() {
          _interferenceY = -1;
        });
        _scheduleInterference();
      }
    });

    // Initial random delay 2-10s
    _scheduleInterference(initial: true);
  }

  void _scheduleInterference({bool initial = false}) {
    // If initial, randomize shortly (2-10s).
    // If recurring, randomize rarely (40-100s).
    final minDelay = initial ? 2000 : 40000;
    final range = initial ? 8000 : 60000;
    
    final delayMs = minDelay + _rng.nextInt(range);
    _interferenceTimer = Timer(Duration(milliseconds: delayMs), () {
      if (!mounted) return;
      _triggerInterference();
    });
  }

  void _triggerInterference() {
    // Animate a horizontal bar sweeping from top to bottom
    if (!mounted) return;
    _interferenceController?.forward(from: 0);
  }

  // ────────────────────────────────────────
  // Build
  // ────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (widget.stage == null || !DarknessThemeService().areAnimationsEnabled) {
      return widget.child;
    }

    switch (widget.stage!) {
      case DarknessStage.solarpunk:
        return _buildSolarpunk();
      case DarknessStage.dieselpunk:
        return _buildDieselpunk();
      case DarknessStage.cyberpunk:
        return _buildCyberpunk();
      case DarknessStage.stalker:
        return _buildStalker();
    }
  }

  // ── Solarpunk ──
  Widget _buildSolarpunk() {
    return AnimatedBuilder(
      animation: _breathController!,
      builder: (context, child) {
        // sin(t*π): t goes 0→1 linearly, sin gives smooth 0→1→0 per 4s cycle
        final t = _breathController!.value;
        final pulse = sin(t * pi); // smooth 0 → 1 → 0
        final shadowBlur = 4.0 + pulse * 12.0; // 4 → 16 → 4
        final shadowOpacity = 0.08 + pulse * 0.22; // 0.08 → 0.30
        final cellOpacity = 0.92 + pulse * 0.08; // subtle 0.92 → 1.0

        return Opacity(
          opacity: cellOpacity,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF66BB6A).withOpacity(shadowOpacity),
                  blurRadius: shadowBlur,
                  spreadRadius: pulse * 3,
                ),
              ],
            ),
            child: child,
          ),
        );
      },
      child: widget.child,
    );
  }

  // ── Dieselpunk ──
  Widget _buildDieselpunk() {
    return Opacity(
      opacity: _flickerOpacity,
      child: widget.child,
    );
  }

  // ── Cyberpunk ──
  Widget _buildCyberpunk() {
    if (!_glitching) return widget.child;

    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Main shifted cell
        Transform.translate(
          offset: Offset(_glitchOffsetX, _glitchOffsetY),
          child: widget.child,
        ),
        // Red channel ghost (offset left)
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(_glitchOffsetX - 2, 0),
            child: Opacity(
              opacity: 0.3,
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Color(0xFFFF0000),
                  BlendMode.modulate,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
        // Cyan channel ghost (offset right)
        Positioned.fill(
          child: Transform.translate(
            offset: Offset(_glitchOffsetX + 2, 0),
            child: Opacity(
              opacity: 0.3,
              child: ColorFiltered(
                colorFilter: const ColorFilter.mode(
                  Color(0xFF00FFFF),
                  BlendMode.modulate,
                ),
                child: widget.child,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Stalker ──
  Widget _buildStalker() {
    return Stack(
      children: [
        widget.child,
        // Noise grain overlay
        Positioned.fill(
          child: IgnorePointer(
            child: CustomPaint(
              painter: _NoisePainter(seed: _noiseSeed),
            ),
          ),
        ),
        // Interference bar
        if (_interferenceY >= 0 && _interferenceY <= 1)
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            bottom: 0,
            child: IgnorePointer(
              child: CustomPaint(
                painter: _InterferencePainter(yFraction: _interferenceY),
              ),
            ),
          ),
      ],
    );
  }
}

// ════════════════════════════════════════
// Custom Painters
// ════════════════════════════════════════

/// Draws pseudo-random noise grain dots.
class _NoisePainter extends CustomPainter {
  final int seed;

  _NoisePainter({required this.seed});

  @override
  void paint(Canvas canvas, Size size) {
    final rng = Random(seed);
    final paint = Paint()..style = PaintingStyle.fill;

    final dotCount = (size.width * size.height / 60).round().clamp(20, 120);
    for (int i = 0; i < dotCount; i++) {
      final x = rng.nextDouble() * size.width;
      final y = rng.nextDouble() * size.height;
      final brightness = rng.nextDouble();
      paint.color = Color.fromRGBO(
        (brightness * 57).toInt().clamp(0, 255), // greenish tint
        (brightness * 255).toInt().clamp(0, 255),
        (brightness * 20).toInt().clamp(0, 255),
        0.06 + rng.nextDouble() * 0.08,
      );
      canvas.drawCircle(Offset(x, y), 0.5 + rng.nextDouble() * 0.5, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _NoisePainter old) => old.seed != seed;
}

/// Draws a horizontal interference bar at a given vertical fraction.
class _InterferencePainter extends CustomPainter {
  final double yFraction;

  _InterferencePainter({required this.yFraction});

  @override
  void paint(Canvas canvas, Size size) {
    final barHeight = size.height * 0.15;
    final y = yFraction * size.height;

    final paint = Paint()
      ..color = const Color(0xFF39FF14).withOpacity(0.12)
      ..style = PaintingStyle.fill;

    canvas.drawRect(
      Rect.fromLTWH(0, y, size.width, barHeight),
      paint,
    );

    // Thin bright line at bar top
    final linePaint = Paint()
      ..color = const Color(0xFF39FF14).withOpacity(0.25)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;

    canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
  }

  @override
  bool shouldRepaint(covariant _InterferencePainter old) =>
      old.yFraction != yFraction;
}
