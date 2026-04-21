import 'dart:math' as math;

import 'package:flutter/material.dart';

/// Procedural twinkling gold star field — matches the Shopify widget's
/// .vipRide__testStar layer (25 small gold dots scattered across the
/// container, each with its own random opacity and scale pulse).
///
/// Drop it as the first child of a Stack (or with `Positioned.fill`)
/// and put your UI content on top. It's fully IgnorePointer so it
/// never blocks gestures.
class AmbientStarField extends StatefulWidget {
  final int starCount;
  final Color color;
  final double minSize;
  final double maxSize;
  final double minOpacity;
  final double maxOpacity;
  final double minScale;
  final double maxScale;
  final int minDurationMs;
  final int maxDurationMs;

  const AmbientStarField({
    super.key,
    this.starCount = 25,
    this.color = const Color(0xFFE8C547),
    this.minSize = 1.0,
    this.maxSize = 3.5,
    this.minOpacity = 0.08,
    this.maxOpacity = 0.65,
    this.minScale = 0.7,
    this.maxScale = 1.3,
    this.minDurationMs = 1600,
    this.maxDurationMs = 3800,
  });

  @override
  State<AmbientStarField> createState() => _AmbientStarFieldState();
}

class _AmbientStarFieldState extends State<AmbientStarField>
    with SingleTickerProviderStateMixin {
  late final AnimationController _master;
  late final List<_Star> _stars;
  final _rng = math.Random(42); // seeded so layouts stay stable

  @override
  void initState() {
    super.initState();
    // Single shared controller at 10s cadence — each star reads its
    // own phase / duration from the loop, so there's only ever one
    // ticker alive no matter how many stars we draw.
    _master = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 10),
    )..repeat();
    _stars = List.generate(widget.starCount, (_) => _spawnStar());
  }

  _Star _spawnStar() {
    final duration = widget.minDurationMs +
        _rng.nextInt(widget.maxDurationMs - widget.minDurationMs);
    return _Star(
      x: 0.02 + _rng.nextDouble() * 0.96,
      y: 0.02 + _rng.nextDouble() * 0.96,
      size: widget.minSize +
          _rng.nextDouble() * (widget.maxSize - widget.minSize),
      durationMs: duration,
      phase: _rng.nextDouble() * 3.0, // 0-3s random offset
    );
  }

  @override
  void dispose() {
    _master.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return IgnorePointer(
      child: LayoutBuilder(
        builder: (_, constraints) {
          return AnimatedBuilder(
            animation: _master,
            builder: (_, __) {
              final now = _master.value * 10.0; // 0-10s
              return CustomPaint(
                size: Size(constraints.maxWidth, constraints.maxHeight),
                painter: _StarFieldPainter(
                  stars: _stars,
                  now: now,
                  color: widget.color,
                  minOpacity: widget.minOpacity,
                  maxOpacity: widget.maxOpacity,
                  minScale: widget.minScale,
                  maxScale: widget.maxScale,
                ),
              );
            },
          );
        },
      ),
    );
  }
}

class _Star {
  final double x; // 0-1 (relative to box width)
  final double y; // 0-1 (relative to box height)
  final double size; // px at scale 1.0
  final int durationMs; // full twinkle cycle
  final double phase; // seconds of offset

  const _Star({
    required this.x,
    required this.y,
    required this.size,
    required this.durationMs,
    required this.phase,
  });
}

class _StarFieldPainter extends CustomPainter {
  final List<_Star> stars;
  final double now; // 0..10 seconds
  final Color color;
  final double minOpacity;
  final double maxOpacity;
  final double minScale;
  final double maxScale;

  _StarFieldPainter({
    required this.stars,
    required this.now,
    required this.color,
    required this.minOpacity,
    required this.maxOpacity,
    required this.minScale,
    required this.maxScale,
  });

  @override
  void paint(Canvas canvas, Size size) {
    for (final star in stars) {
      final durSec = star.durationMs / 1000.0;
      final t = ((now + star.phase) % durSec) / durSec; // 0-1 local phase
      // Tri-wave 0 → 1 → 0 (matches vipTestTwinkle 0%/50%/100% keyframes).
      final peak = 1 - (t - 0.5).abs() * 2;
      final opacity = minOpacity + (maxOpacity - minOpacity) * peak;
      final scale = minScale + (maxScale - minScale) * peak;

      final paint = Paint()
        ..color = color.withValues(alpha: opacity.clamp(0.0, 1.0))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 0.8);

      canvas.drawCircle(
        Offset(star.x * size.width, star.y * size.height),
        star.size * scale * 0.5,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _StarFieldPainter old) => old.now != now;
}
