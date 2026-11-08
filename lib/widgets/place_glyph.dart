import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../services/places_service.dart' show PlaceType;

/// The search results' marks: one thin-line family, drawn rather than taken
/// from the icon font (owner 2026-11-08: "hazlo más moderno" — picked the
/// outline pin with a dot, then "los negocios y aeropuertos también").
///
/// Every mark is drawn on a 24-unit grid with the same 1.8 px line at any
/// size, so the pin, the bag, the plane… read as one set beside the field
/// rail's rings.
class PlaceGlyph extends StatelessWidget {
  const PlaceGlyph(
    this.type, {
    super.key,
    this.color = const Color(0xFFE8C547),
    this.size = 20,
  });

  final PlaceType type;
  final Color color;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: PlaceGlyphPainter(type, color),
      );
}

class PlaceGlyphPainter extends CustomPainter {
  const PlaceGlyphPainter(this.type, this.color);

  final PlaceType type;
  final Color color;

  /// On-screen line width, whatever the size.
  static const double strokePx = 1.8;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = strokePx / k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final fill = Paint()..color = color;
    switch (type) {
      case PlaceType.home:
        _pin(canvas, line, fill);
      case PlaceType.commerce:
        _bag(canvas, line);
      case PlaceType.business:
        _store(canvas, line);
      case PlaceType.airport:
        _plane(canvas, line);
      case PlaceType.hotel:
        _bed(canvas, line);
      case PlaceType.hospital:
        _hospital(canvas, line);
      case PlaceType.education:
        _cap(canvas, line);
    }
    canvas.restore();
  }

  // An address: a drop with a dot in its head (the rail's ring + dot).
  void _pin(Canvas c, Paint line, Paint fill) {
    const r = 8.4, cx = 12.0, cy = 9.6;
    final side = r - line.strokeWidth / 2;
    final tip = 22.8 - line.strokeWidth / 2;
    c.drawPath(
      Path()
        ..moveTo(cx, tip)
        ..cubicTo(cx - r * 0.35, tip - r * 0.75, cx - side, cy + r * 0.55,
            cx - side, cy)
        ..arcToPoint(const Offset(cx, cy) + Offset(side, 0),
            radius: Radius.circular(side))
        ..cubicTo(cx + side, cy + r * 0.55, cx + r * 0.35, tip - r * 0.75, cx,
            tip)
        ..close(),
      line,
    );
    c.drawCircle(const Offset(cx, cy), r * 0.32, fill);
  }

  // A store: a shopping bag.
  void _bag(Canvas c, Paint line) {
    c.drawRRect(
      RRect.fromLTRBR(4.5, 8, 19.5, 21.5, const Radius.circular(2.5)),
      line,
    );
    c.drawPath(
      Path()
        ..moveTo(8.5, 11)
        ..lineTo(8.5, 6.5)
        ..arcToPoint(const Offset(15.5, 6.5),
            radius: const Radius.circular(3.5))
        ..lineTo(15.5, 11),
      line,
    );
  }

  // Any other named place: a shopfront with its awning and door.
  void _store(Canvas c, Paint line) {
    c.drawPath(
      Path()
        ..moveTo(3, 9.5)
        ..lineTo(4.8, 4)
        ..lineTo(19.2, 4)
        ..lineTo(21, 9.5)
        ..close(),
      line,
    );
    c.drawPath(
      Path()
        ..moveTo(5, 9.5)
        ..lineTo(5, 20.5)
        ..lineTo(19, 20.5)
        ..lineTo(19, 9.5)
        ..moveTo(10, 20.5)
        ..lineTo(10, 15)
        ..lineTo(14, 15)
        ..lineTo(14, 20.5),
      line,
    );
  }

  // An airport: a plane climbing to the right.
  void _plane(Canvas c, Paint line) {
    c.save();
    c.translate(12, 12);
    c.rotate(math.pi / 4);
    c.translate(-12, -12);
    c.drawPath(
      Path()
        ..moveTo(12, 2)
        ..cubicTo(13.1, 2, 14, 2.9, 14, 4)
        ..lineTo(14, 9)
        ..lineTo(21, 13.2)
        ..lineTo(21, 15.5)
        ..lineTo(14, 13.3)
        ..lineTo(14, 18)
        ..lineTo(16.2, 19.7)
        ..lineTo(16.2, 21.5)
        ..lineTo(12, 20.4)
        ..lineTo(7.8, 21.5)
        ..lineTo(7.8, 19.7)
        ..lineTo(10, 18)
        ..lineTo(10, 13.3)
        ..lineTo(3, 15.5)
        ..lineTo(3, 13.2)
        ..lineTo(10, 9)
        ..lineTo(10, 4)
        ..cubicTo(10, 2.9, 10.9, 2, 12, 2)
        ..close(),
      line,
    );
    c.restore();
  }

  // A hotel: a bed with its pillow.
  void _bed(Canvas c, Paint line) {
    c.drawPath(
      Path()
        ..moveTo(3, 5)
        ..lineTo(3, 19)
        ..moveTo(3, 15.5)
        ..lineTo(21, 15.5)
        ..moveTo(21, 19)
        ..lineTo(21, 12.5)
        ..arcToPoint(const Offset(18, 9.5),
            radius: const Radius.circular(3), clockwise: false)
        ..lineTo(10, 9.5)
        ..lineTo(10, 15.5),
      line,
    );
    c.drawCircle(const Offset(6.5, 12.3), 1.8, line);
  }

  // A hospital: a cross in a rounded square.
  void _hospital(Canvas c, Paint line) {
    c.drawRRect(
      RRect.fromLTRBR(3.5, 3.5, 20.5, 20.5, const Radius.circular(4)),
      line,
    );
    c.drawPath(
      Path()
        ..moveTo(12, 8)
        ..lineTo(12, 16)
        ..moveTo(8, 12)
        ..lineTo(16, 12),
      line,
    );
  }

  // A school or university: a graduation cap.
  void _cap(Canvas c, Paint line) {
    c.drawPath(
      Path()
        ..moveTo(2, 9.5)
        ..lineTo(12, 5)
        ..lineTo(22, 9.5)
        ..lineTo(12, 14)
        ..close(),
      line,
    );
    c.drawPath(
      Path()
        ..moveTo(6.5, 11.8)
        ..lineTo(6.5, 16)
        ..cubicTo(6.5, 17.6, 9, 19, 12, 19)
        ..cubicTo(15, 19, 17.5, 17.6, 17.5, 16)
        ..lineTo(17.5, 11.8)
        ..moveTo(22, 9.5)
        ..lineTo(22, 14),
      line,
    );
  }

  @override
  bool shouldRepaint(covariant PlaceGlyphPainter old) =>
      old.type != type || old.color != color;
}

/// "Choose on map": a folded map with the address pin standing on it, in
/// the same 1.8 px line as the place marks (owner 2026-11-08, "cámbialo
/// para uno más moderno"). [cutout] is the well behind it — the pin hides
/// the map's lines where it stands.
class MapPickGlyph extends StatelessWidget {
  const MapPickGlyph({
    super.key,
    this.color = const Color(0xFFE8C547),
    this.cutout = const Color(0xFF101014),
    this.size = 24,
  });

  final Color color;
  final Color cutout;
  final double size;

  @override
  Widget build(BuildContext context) => CustomPaint(
        size: Size.square(size),
        painter: _MapPickPainter(color, cutout),
      );
}

class _MapPickPainter extends CustomPainter {
  const _MapPickPainter(this.color, this.cutout);

  final Color color;
  final Color cutout;

  @override
  void paint(Canvas canvas, Size size) {
    final k = size.shortestSide / 24;
    canvas.save();
    canvas.translate((size.width - 24 * k) / 2, (size.height - 24 * k) / 2);
    canvas.scale(k);
    final line = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = PlaceGlyphPainter.strokePx / k
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    // The folded map: three panels.
    canvas.drawPath(
      Path()
        ..moveTo(2.5, 7)
        ..lineTo(8.5, 4.5)
        ..lineTo(15.5, 7)
        ..lineTo(21.5, 4.5)
        ..lineTo(21.5, 18)
        ..lineTo(15.5, 20.5)
        ..lineTo(8.5, 18)
        ..lineTo(2.5, 20.5)
        ..close()
        ..moveTo(8.5, 4.5)
        ..lineTo(8.5, 18)
        ..moveTo(15.5, 7)
        ..lineTo(15.5, 20.5),
      line,
    );
    // The pin on it, the address mark's shape.
    const cx = 12.0, cy = 8.2, r = 4.3, tip = 16.6;
    final pin = Path()
      ..moveTo(cx, tip)
      ..cubicTo(cx - r * 0.35, tip - r * 0.75, cx - r, cy + r * 0.55, cx - r, cy)
      ..arcToPoint(const Offset(cx + r, cy), radius: const Radius.circular(r))
      ..cubicTo(cx + r, cy + r * 0.55, cx + r * 0.35, tip - r * 0.75, cx, tip)
      ..close();
    canvas.drawPath(pin, Paint()..color = cutout);
    canvas.drawPath(pin, line);
    canvas.drawCircle(const Offset(cx, cy), r * 0.34, Paint()..color = color);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _MapPickPainter old) =>
      old.color != color || old.cutout != cutout;
}
