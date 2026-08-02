import 'dart:math' as math;

import 'package:flutter/material.dart';

/// A steering wheel, drawn rather than imported.
///
/// Material Icons has no steering wheel — the nearest it offers is
/// `two_wheeler`, which is a motorbike. So this is a painter.
///
/// Not the classic three-spoke circle: that shape reads as a bus wheel
/// from 1970. This is the contemporary one — a rim with a flat bottom,
/// a hub sitting slightly low, and two spokes falling away from it. The
/// geometry is a generic pictogram and belongs to nobody.
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
      child: CustomPaint(painter: _SteeringWheelPainter(color)),
    );
  }
}

class _SteeringWheelPainter extends CustomPainter {
  const _SteeringWheelPainter(this.color);

  final Color color;

  /// Where the bottom is cut, as a fraction of the radius. 1.0 would be a
  /// full circle; this is a hint of a D, not a half-moon.
  static const _flat = 0.88;

  /// How far below centre the hub sits, as a fraction of the radius.
  static const _drop = 0.12;

  static const _hubFraction = 0.24;

  /// How far the spokes fall away from horizontal.
  static const _tilt = 26 * math.pi / 180;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    // Inset so the stroke stays inside the box at every size.
    final r = math.min(size.width, size.height) / 2 * 0.92;

    // Stroke scales with the glyph: fixed width turns to mush small and
    // to a doughnut large.
    final w = math.max(1.0, r * 0.12);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = w
      ..strokeCap = StrokeCap.round
      ..isAntiAlias = true;

    final rim = r - w / 2;

    // ── Rim: an arc, open at the bottom, closed by a chord ──
    // Canvas angles run clockwise from 3 o'clock with y growing down, so
    // the two ends of the cut are where sin(theta) == _flat.
    final t = math.asin(_flat);
    canvas.drawArc(
      Rect.fromCircle(center: c, radius: rim),
      math.pi - t,
      2 * t + math.pi,
      false,
      paint,
    );

    final cutY = c.dy + rim * _flat;
    final cutX = rim * math.sqrt(math.max(0.0, 1 - _flat * _flat));
    canvas.drawLine(
      Offset(c.dx - cutX, cutY),
      Offset(c.dx + cutX, cutY),
      paint,
    );

    // ── Hub ──
    final hubC = Offset(c.dx, c.dy + rim * _drop);
    final hubR = rim * _hubFraction;
    canvas.drawCircle(hubC, hubR, paint);

    // ── Two spokes, falling outward ──
    for (final sign in const [-1.0, 1.0]) {
      final u = Offset(math.cos(_tilt) * sign, math.sin(_tilt));
      // Distance from the hub centre to the rim along u: solve
      // |d + k·u|² = rim², where d is the hub's offset from the centre.
      final d = hubC - c;
      final b = d.dx * u.dx + d.dy * u.dy;
      final disc = b * b - (d.distanceSquared - rim * rim);
      if (disc <= 0) continue;
      var k = -b + math.sqrt(disc);

      // Stop at the flat cut rather than crossing it.
      if (u.dy > 0) {
        final toCut = (cutY - hubC.dy) / u.dy;
        if (toCut > 0) k = math.min(k, toCut);
      }
      k -= w / 2;
      if (k <= hubR) continue;

      canvas.drawLine(hubC + u * hubR, hubC + u * k, paint);
    }
  }

  @override
  bool shouldRepaint(_SteeringWheelPainter old) => old.color != color;
}
