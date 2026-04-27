import 'dart:math';

import 'package:flutter/material.dart';

/// Animated golden particles background for vehicle cards.
/// Creates a subtle floating dust of golden sparkles that drift
/// slowly upward, giving a premium magical feel.
class GoldParticlesBackground extends StatefulWidget {
  final Widget child;
  final int particleCount;
  final Color particleColor;

  const GoldParticlesBackground({
    super.key,
    required this.child,
    this.particleCount = 25,
    this.particleColor = const Color(0xFFE8C547),
  });

  @override
  State<GoldParticlesBackground> createState() => _GoldParticlesBackgroundState();
}

class _GoldParticlesBackgroundState extends State<GoldParticlesBackground>
    with TickerProviderStateMixin {
  late final List<Particle> _particles;
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    final random = Random();
    _particles = List.generate(widget.particleCount, (i) {
      return Particle(
        x: random.nextDouble(),
        y: random.nextDouble(),
        size: 1.5 + random.nextDouble() * 2.5,
        speed: 0.15 + random.nextDouble() * 0.25,
        opacity: 0.15 + random.nextDouble() * 0.35,
        phase: random.nextDouble() * pi * 2,
      );
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, child) {
          return CustomPaint(
            painter: _ParticlesPainter(
              particles: _particles,
              progress: _controller.value,
              color: widget.particleColor,
            ),
            child: child,
          );
        },
        child: widget.child,
      ),
    );
  }
}

class Particle {
  final double x;      // 0-1 horizontal position
  final double y;      // 0-1 vertical position (start)
  final double size;   // particle radius
  final double speed;  // drift speed
  final double opacity;// base opacity
  final double phase;  // animation phase offset

  Particle({
    required this.x,
    required this.y,
    required this.size,
    required this.speed,
    required this.opacity,
    required this.phase,
  });
}

class _ParticlesPainter extends CustomPainter {
  final List<Particle> particles;
  final double progress;
  final Color color;

  _ParticlesPainter({
    required this.particles,
    required this.progress,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final p in particles) {
      // Drift upward slowly, wrapping around
      final driftedY = (p.y - p.speed * progress) % 1.0;
      // Subtle horizontal sway
      final sway = sin(progress * pi * 2 + p.phase) * 8;

      final cx = p.x * size.width + sway;
      final cy = driftedY * size.height;

      // Twinkle: opacity oscillates
      final twinkle = 0.5 + 0.5 * sin(progress * pi * 4 + p.phase);
      final alpha = (p.opacity * twinkle).clamp(0.0, 1.0);

      // Draw glow
      final glowPaint = Paint()
        ..color = color.withValues(alpha: alpha * 0.6)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3);
      canvas.drawCircle(Offset(cx, cy), p.size * 1.5, glowPaint);

      // Draw core
      final corePaint = Paint()
        ..color = color.withValues(alpha: alpha);
      canvas.drawCircle(Offset(cx, cy), p.size * 0.5, corePaint);
    }
  }

  @override
  bool shouldRepaint(covariant _ParticlesPainter old) => true;
}
