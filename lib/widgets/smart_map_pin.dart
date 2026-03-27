import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

// ════════════════════════════════════════════════════════════════════
//  SMART GOLDEN MAP PIN
//  Classic teardrop/drop shape with golden gradient, 3D glossy
//  shine, ground shadow, and smart white icon inside.
// ════════════════════════════════════════════════════════════════════

/// Icon detection based on place types and name.
IconData getIconForPlace({
  required List<String> placeTypes,
  required String placeName,
  required bool isPickup,
}) {
  final name = placeName.toLowerCase();
  final types = placeTypes.map((t) => t.toLowerCase()).toList();

  // AIRPORT
  if (types.contains('airport') ||
      name.contains('airport') ||
      name.contains('aeropuerto') ||
      name.contains('terminal') ||
      types.contains('transit_station')) {
    return Icons.flight_takeoff;
  }

  // COMMERCIAL / BUSINESS
  if (types.any((t) => [
        'store', 'restaurant', 'cafe',
        'shopping_mall', 'lodging', 'hotel', 'bar',
        'establishment', 'food', 'point_of_interest',
        'grocery_or_supermarket', 'pharmacy',
        'gas_station', 'gym',
      ].contains(t)) ||
      name.contains('mall') ||
      name.contains('plaza') ||
      name.contains('hotel') ||
      name.contains('inn') ||
      name.contains('store') ||
      name.contains('market') ||
      name.contains('office') ||
      name.contains('suite')) {
    return Icons.storefront;
  }

  // RESIDENTIAL / HOME
  if (types.any((t) => [
        'premise', 'street_address',
        'subpremise', 'neighborhood',
        'residential',
      ].contains(t)) ||
      name.contains('apt') ||
      name.contains('house') ||
      name.contains('home') ||
      name.contains('residence') ||
      name.contains('dr ') ||
      name.contains('st ') ||
      name.contains('ave ') ||
      name.contains('blvd')) {
    return Icons.home;
  }

  // PICKUP default
  if (isPickup) return Icons.person;

  // DROPOFF default
  return Icons.location_on;
}

// ──────────────────────────────────────────────────────────────────
//  GOLDEN PIN PAINTER  (renders to Canvas)
// ──────────────────────────────────────────────────────────────────

class GoldenPinPainter {
  GoldenPinPainter({required this.icon, required this.size});

  final IconData icon;
  final double size;

  double get _width  => size;
  double get _height => size * 1.375;
  double get _cx     => _width / 2;
  double get _r      => _width * 0.32;
  double get _headCY => _r + _width * 0.06;
  double get _tipY   => _height * 0.82;
  double get _shadowY => _height * 0.97; // SEPARATED from tip

  static const _goldLight = Color(0xFFFFF8DC);
  static const _goldMid   = Color(0xFFE8C547);
  static const _goldDeep  = Color(0xFFB8860B);

  void paint(Canvas canvas, Size canvasSize) {
    final cx      = _cx;
    final r       = _r;
    final headCY  = _headCY;
    final tipY    = _tipY;
    final shadowY = _shadowY;

    // ── 0. Ground shadow ring — SEPARATED (floating illusion) ──
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, shadowY),
        width: r * 1.35,
        height: r * 0.30,
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.20)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // ── 1. Teardrop path ──
    final pinPath = _buildTeardrop(cx, headCY, r, tipY);

    // ── 2. Drop shadow behind pin ──
    canvas.drawPath(
      pinPath.shift(const Offset(0, 4)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // ── 3. Gold gradient fill (linear, light top-left → deep bottom-right) ──
    canvas.drawPath(
      pinPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - r * 0.5, headCY - r),
          Offset(cx + r * 0.5, tipY),
          [_goldLight, _goldMid, _goldDeep],
          [0.0, 0.45, 1.0],
        ),
    );

    // ── 4. Glass sheen — white oval highlight top-left ──
    canvas.save();
    canvas.clipPath(pinPath);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - r * 0.28, headCY - r * 0.25),
        width: r * 0.90,
        height: r * 0.60,
      ),
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    // Micro-specular dot
    canvas.drawCircle(
      Offset(cx - r * 0.32, headCY - r * 0.32),
      r * 0.14,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
    canvas.restore();

    // ── 5. Thin bright border ──
    canvas.drawPath(
      pinPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.35),
    );

    // ── 6. Icon (large and visible) ──
    _drawIcon(canvas, icon, cx, headCY, r);
  }

  Path _buildTeardrop(double cx, double headCY, double r, double tipY) {
    const taper = 0.58;
    final rx = cx + r * math.sin(taper);
    final ry = headCY + r * math.cos(taper);
    final lx = cx - r * math.sin(taper);
    return Path()
      ..moveTo(cx, tipY)
      ..cubicTo(cx + r * 0.14, tipY - (tipY - ry) * 0.38,
                rx + r * 0.08, ry + (tipY - ry) * 0.20, rx, ry)
      ..arcToPoint(Offset(lx, ry),
          radius: Radius.circular(r), clockwise: false, largeArc: true)
      ..cubicTo(lx - r * 0.08, ry + (tipY - ry) * 0.20,
                cx - r * 0.14, tipY - (tipY - ry) * 0.38, cx, tipY)
      ..close();
  }

  void _drawIcon(Canvas canvas, IconData iconData, double cx, double cy, double r) {
    final iconSize = r * 1.25;
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(iconData.codePoint),
        style: TextStyle(
          fontSize: iconSize,
          fontFamily: iconData.fontFamily,
          package: iconData.fontPackage,
          color: Colors.white,
          shadows: const [Shadow(color: Color(0x44000000), blurRadius: 4)],
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
  }
}

// ──────────────────────────────────────────────────────────────────
//  buildGoldenPinBytes — renders pin as PNG Uint8List
// ──────────────────────────────────────────────────────────────────

final Map<String, Uint8List> _goldenPinCache = {};

Future<Uint8List> buildGoldenPinBytes({
  required IconData icon,
  double size = 80,
  double scale = 2.0,
}) async {
  final key = '${icon.codePoint}_$size';
  if (_goldenPinCache.containsKey(key)) return _goldenPinCache[key]!;

  final painter = GoldenPinPainter(icon: icon, size: size);
  final w = painter._width;
  final h = painter._height;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
  painter.paint(canvas, Size(w, h));

  final picture = recorder.endRecording();
  final img = await picture.toImage(
    (w * scale).toInt(),
    (h * scale).toInt(),
  );
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) return Uint8List(0);

  final bytes = data.buffer.asUint8List();
  _goldenPinCache[key] = bytes;
  return bytes;
}



