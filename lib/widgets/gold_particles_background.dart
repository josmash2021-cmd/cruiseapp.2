import 'dart:math' as math;
import 'package:flutter/material.dart';

/// Premium gold-particle background — same look used on the
/// "Matching with your driver" / SearchingDriverScreen so every dark
/// surface in the app shares one cohesive visual language.
///
/// Spec mirrored from searching_driver_screen.dart:
///   - 20 dots, size 2-4 px
///   - alpha 0.1 → 0.4 (twinkles via 4 shared 800-1700ms controllers)
///   - drift upward, speed 0.02-0.06 of height per particle loop
///   - MaskFilter.blur radius = size * 0.4 → soft gold halo
///
/// Performance:
///   - 1 drift Ticker + 4 twinkle Tickers (shared across 20 particles)
///     instead of 20 individual tickers — visually identical, 5x cheaper.
///   - RepaintBoundary + IgnorePointer wrap so the field never absorbs
///     hits and the painter only redraws when its own animations tick.
///
/// Usage:
/// ```dart
/// GoldParticlesBackground(
///   child: ...your normal screen content...,
/// )
/// ```
///
/// Optional: pass particleCount to scale down for small surfaces
/// (sheets / cards). Default 20 matches the Searching screen.
class GoldParticlesBackground extends StatefulWidget {
  final Widget child;
  final int particleCount;

  const GoldParticlesBackground({
    super.key,
    required this.child,
    this.particleCount = 20,
  });

  @override
  State<GoldParticlesBackground> createState() =>
      _GoldParticlesBackgroundState();
}

class _GoldParticlesBackgroundState extends State<GoldParticlesBackground>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late final AnimationController _driftCtrl;
  late final List<AnimationController> _twinkleCtrls;
  late final List<_Particle> _particles;

  @override
  void initState() {
    super.initState();

    final rng = math.Random(7); // seeded — stable field per launch
    _particles = List.generate(
      widget.particleCount,
      (_) => _Particle(
        x: rng.nextDouble(),
        y: rng.nextDouble(),
        size: 2.0 + rng.nextDouble() * 2.0,         // 2..4 px
        driftSpeed: 0.02 + rng.nextDouble() * 0.04, // 0.02..0.06
        phase: rng.nextDouble(),
      ),
    );

    // Single 4-second drift controller — every particle shares it.
    _driftCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 4000),
    )..repeat();

    // 4 staggered twinkle controllers (800/1100/1400/1700ms). Each
    // particle picks one via index % 4 — visually indistinguishable
    // from 20 individual controllers, 5x fewer tickers.
    _twinkleCtrls = List.generate(4, (i) {
      final ms = 800 + (i * 300);
      return AnimationController(
        vsync: this,
        duration: Duration(milliseconds: ms),
      )..repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _driftCtrl.dispose();
    for (final c in _twinkleCtrls) {
      c.dispose();
    }
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
                animation: Listenable.merge([_driftCtrl, ..._twinkleCtrls]),
                builder: (_, __) => CustomPaint(
                  painter: _ParticlePainter(
                    particles: _particles,
                    drift: _driftCtrl.value,
                    twinkleValues: List.generate(
                      _particles.length,
                      (i) => _twinkleCtrls[i % 4].value,
                    ),
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
  final double x;          // 0..1 horizontal position
  final double y;          // 0..1 initial vertical position
  final double size;       // px
  final double driftSpeed; // 0..1 of height per controller loop
  final double phase;      // 0..1 vertical offset
  const _Particle({
    required this.x,
    required this.y,
    required this.size,
    required this.driftSpeed,
    required this.phase,
  });
}

class _ParticlePainter extends CustomPainter {
  final List<_Particle> particles;
  final double drift;
  final List<double> twinkleValues;
  final Color color;

  _ParticlePainter({
    required this.particles,
    required this.drift,
    required this.twinkleValues,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    for (int i = 0; i < particles.length; i++) {
      final p = particles[i];
      final tw = twinkleValues[i];
      final alpha = 0.1 + tw * 0.3; // 0.1 → 0.4
      final dx = p.x * size.width;
      final dy = ((p.y - drift * p.driftSpeed + p.phase) % 1.0) * size.height;
      canvas.drawCircle(
        Offset(dx, dy),
        p.size,
        Paint()
          ..color = color.withValues(alpha: alpha)
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, p.size * 0.4),
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlePainter old) => true;
}
