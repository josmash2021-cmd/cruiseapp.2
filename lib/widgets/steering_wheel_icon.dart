import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A steering wheel, drawn rather than imported.
///
/// Material Icons has no steering wheel — the closest it offers is
/// `two_wheeler`, which is a motorbike. So this is a painter: an outer
/// rim, a hub, and three spokes, which is the shape everyone reads as a
/// wheel and belongs to nobody.
///
/// Sized and coloured like an [Icon] so it can stand in for one.
class SteeringWheelIcon extends StatelessWidget {
  const SteeringWheelIcon({
    super.key,
    this.size = 24,
    this.color = Colors.white,
  });

  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(
        painter: _SteeringWheelPainter(color),
        // The glyph carries no text of its own, so it says what it is.
        isComplex: false,
      ),
    );
  }
}

class _SteeringWheelPainter extends CustomPainter {
  const _SteeringWheelPainter(this.color);

  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = math.min(size.width, size.height) / 2;

    // Stroke width scales with the glyph so it reads the same at 15pt as
    // at 40pt. A fixed width turns to mush small and to a doughnut large.
    final stroke = math.max(1.0, r * 0.16);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final rim = r - stroke / 2;
    canvas.drawCircle(c, rim, paint);

    final hub = r * 0.30;
    canvas.drawCircle(c, hub, paint);

    // Three spokes: one down, two up-and-out. Drawn from the hub's edge
    // to the rim's inner edge so they meet both without crossing either.
    const angles = <double>[math.pi / 2, math.pi + math.pi / 6, -math.pi / 6];
    for (final a in angles) {
      final from = c + Offset(math.cos(a), math.sin(a)) * (hub + stroke / 2);
      final to = c + Offset(math.cos(a), math.sin(a)) * (rim - stroke / 2);
      canvas.drawLine(from, to, paint);
    }
  }

  @override
  bool shouldRepaint(_SteeringWheelPainter old) => old.color != color;
}
