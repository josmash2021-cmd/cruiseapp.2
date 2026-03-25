import 'dart:math';
import 'package:flutter/material.dart';

/// Draws 3 staggered gold shimmer rings expanding radially from center.
/// [progress] drives the animation from 0.0 → 1.0 (looped externally).
class RadialShimmerPainter extends CustomPainter {
  final double progress;
  const RadialShimmerPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius =
        sqrt(pow(size.width / 2, 2) + pow(size.height / 2, 2));

    for (int i = 0; i < 3; i++) {
      final ringProgress = (progress + i / 3.0) % 1.0;
      final radius = ringProgress * maxRadius;
      final opacity = (1.0 - ringProgress) * 0.45;
      final strokeWidth = (1.0 - ringProgress) * 6.0 + 1.0;

      final paint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = strokeWidth
        ..shader = SweepGradient(
          colors: [
            const Color(0xFFFFE566).withValues(alpha: opacity),
            const Color(0xFFFFD700).withValues(alpha: opacity * 0.8),
            const Color(0xFFFFC200).withValues(alpha: opacity * 0.6),
            const Color(0xFFFFE566).withValues(alpha: opacity),
          ],
          stops: const [0.0, 0.33, 0.66, 1.0],
          transform: GradientRotation(ringProgress * 2 * pi),
        ).createShader(
          Rect.fromCircle(center: center, radius: radius),
        );

      canvas.drawCircle(center, radius, paint);
    }
  }

  @override
  bool shouldRepaint(RadialShimmerPainter old) => old.progress != progress;
}
