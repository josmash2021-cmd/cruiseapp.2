import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Subtle premium gold-particle background.
///
/// Renders ~30 gold dots that drift slowly upward (bubble-like) with a
/// gentle horizontal sway. Each particle has its own size, speed, alpha
/// and phase so the field never looks tiled. When a particle reaches
/// the top it wraps back to the bottom with a fresh random x.
///
/// Usage:
/// ```dart
/// Scaffold(
///   backgroundColor: Colors.black,
///   body: GoldParticlesBackground(
///     child: ...your normal screen content...,
///   ),
/// )
/// ```
///
/// Performance:
/// - 30 painted circles per frame, no shadows / blur layers, no stroke.
/// - One Ticker (vsync) per screen instance — disposed when the widget
///   leaves the tree.
/// - The painter itself only redraws when `t` (animation value) changes.
///
/// Notes:
/// - Designed for screens WITHOUT a heavy GPU widget below it (no Mapbox,
///   no video). Stack it INSIDE the Scaffold body, NOT inside a screen
///   that already runs a 60fps map render.
class GoldParticlesBackground extends StatefulWidget {
  final Widget child;
  final int particleCount;

  const GoldParticlesBackground({
    super.key,
    required this.child,
    this.particleCount = 30,
  });

  @override
  State<GoldParticlesBackground> createState() =>
      _GoldParticlesBackgroundState();
}

class _GoldParticlesBackgroundState extends State<GoldParticlesBackground>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late final AnimationController _ctl;
  late final List<_Particle> _particles;
  final _rand = math.Random(42); // seeded so the field is stable per launch

  @override
  void initState() {
    super.initState();
    _particles = List.generate(
      widget.particleCount,
      (i) => _Particle.random(_rand),
    );
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 30),
    )..repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Positioned.fill(
          child: IgnorePointer(
            child: RepaintBoundary(
              child: AnimatedBuilder(
                animation: _ctl,
                builder: (_, __) => CustomPaint(
                  painter: _GoldParticlesPainter(
                    particles: _particles,
                    t: _ctl.value,
                    color: _gold,
                  ),
                ),
              ),
            ),
          ),
        ),
        widget.child,
      ],
    );
  }
}

class _Particle {
  // Normalized 0..1 coordinates so the field scales to any screen.
  final double xSeed;        // base horizontal position (0..1)
  final double ySeed;        // initial vertical phase (0..1)
  final double radius;       // px
  final double speed;        // 0.05..0.20 of screen height per loop
  final double alpha;        // 0.04..0.18
  final double swayAmp;      // 0..0.04 horizontal sway amplitude (0..1)
  final double swayPhase;    // 0..2π

  _Particle({
    required this.xSeed,
    required this.ySeed,
    required this.radius,
    required this.speed,
    required this.alpha,
    required this.swayAmp,
    required this.swayPhase,
  });

  factory _Particle.random(math.Random r) {
    return _Particle(
      xSeed: r.nextDouble(),
      ySeed: r.nextDouble(),
      radius: 0.7 + r.nextDouble() * 1.6,         // 0.7..2.3 px
      speed: 0.05 + r.nextDouble() * 0.15,        // 0.05..0.20
      alpha: 0.04 + r.nextDouble() * 0.14,        // 0.04..0.18
      swayAmp: r.nextDouble() * 0.04,             // 0..0.04
      swayPhase: r.nextDouble() * math.pi * 2,
    );
  }
}

class _GoldParticlesPainter extends CustomPainter {
  final List<_Particle> particles;
  final double t; // 0..1, loops
  final Color color;

  _GoldParticlesPainter({
    required this.particles,
    required this.t,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final w = size.width;
    final h = size.height;

    for (final p in particles) {
      // Vertical: each particle moves upward at its own pace, wraps top→bottom.
      final yProgress = ((p.ySeed - t * p.speed) % 1.0 + 1.0) % 1.0;
      final y = yProgress * h;

      // Horizontal: base position + gentle sine sway.
      final sway = math.sin(t * 2 * math.pi + p.swayPhase) * p.swayAmp;
      final x = ((p.xSeed + sway) % 1.0 + 1.0) % 1.0 * w;

      // Fade in at the bottom and out near the top so wrap is invisible.
      double edgeFade = 1.0;
      if (yProgress < 0.08) edgeFade = yProgress / 0.08;
      if (yProgress > 0.92) edgeFade = (1.0 - yProgress) / 0.08;

      final paint = Paint()
        ..color = color.withValues(alpha: p.alpha * edgeFade)
        ..style = PaintingStyle.fill;
      canvas.drawCircle(Offset(x, y), p.radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _GoldParticlesPainter old) =>
      old.t != t || old.particles != particles || old.color != color;
}
