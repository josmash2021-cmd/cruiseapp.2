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
  // PICKUP — always person icon regardless of location type.
  if (isPickup) return Icons.person;

  final name = placeName.toLowerCase();
  final types = placeTypes.map((t) => t.toLowerCase()).toList();

  // AIRPORT
  if (types.contains('airport') ||
      types.contains('transit_station') ||
      name.contains('airport') ||
      name.contains('aeropuerto') ||
      name.contains('terminal') ||
      name.contains('intl') ||
      name.contains('international')) {
    return Icons.flight_takeoff;
  }

  // COMMERCIAL / BUSINESS
  if (types.any((t) => [
        'store', 'restaurant', 'cafe',
        'shopping_mall', 'lodging', 'hotel', 'bar',
        'establishment', 'food', 'point_of_interest',
        'grocery_or_supermarket', 'pharmacy',
        'gas_station', 'gym', 'bank', 'supermarket',
      ].contains(t)) ||
      name.contains('mall') ||
      name.contains('plaza') ||
      name.contains('hotel') ||
      name.contains('inn') ||
      name.contains('store') ||
      name.contains('market') ||
      name.contains('office') ||
      name.contains('center') ||
      name.contains('clinic') ||
      name.contains('hospital') ||
      name.contains('restaurant') ||
      name.contains('cafe') ||
      name.contains('suite')) {
    return Icons.storefront;
  }

  // RESIDENTIAL / HOME
  if (types.any((t) => [
        'premise', 'street_address',
        'subpremise', 'neighborhood',
        'residential', 'route',
      ].contains(t)) ||
      name.contains('apt') ||
      name.contains('house') ||
      name.contains('home') ||
      name.contains('residence') ||
      name.contains(' dr') ||
      name.contains(' st') ||
      name.contains(' ave') ||
      name.contains(' blvd') ||
      name.contains(' ln') ||
      name.contains(' ct') ||
      name.contains(' rd')) {
    return Icons.home;
  }

  // DROPOFF default
  return Icons.location_on;
}

// ──────────────────────────────────────────────────────────────────
//  GOLDEN PIN PAINTER  (renders to Canvas)
// ──────────────────────────────────────────────────────────────────

class GoldenPinPainter {
  GoldenPinPainter({required this.icon, required this.size, this.isPickup = true});

  final IconData icon;
  final double size;
  final bool isPickup;

  double get _width  => size;
  double get _height => size * 1.1;
  double get _cx     => _width / 2;
  double get _r      => _width * 0.29;
  double get _headCY => _r + _width * 0.06;
  // Keep tip at image bottom so IconAnchor.BOTTOM pins exactly at coordinates.
  double get _tipY   => _height - 1.0;
  double get _shadowY => _height - (_width * 0.07);

  // ── Gold palette (used for both pickup and dropoff) ──
  static const _goldLight  = Color(0xFFFFF5C4);
  static const _goldMid    = Color(0xFFE4BD4A);
  static const _goldDeep   = Color(0xFF9C6B12);
  static const _goldRing   = Color(0xB8FFE4A0);
  static const _goldBorder = Color(0x7AFFF1B8);

  void paint(Canvas canvas, Size canvasSize) {
    final cx      = _cx;
    final r       = _r;
    final headCY  = _headCY;
    final tipY    = _tipY;
    final shadowY = _shadowY;

    // No detached ground shadow: avoid any floating illusion.

    // ── 1. Teardrop path ──
    final pinPath = _buildTeardrop(cx, headCY, r, tipY);

    // Minimal body shadow for depth, without visual lift from the map.
    canvas.drawPath(
      pinPath.shift(const Offset(0, 1.2)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.13)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // ── 3. Premium metallic fill ──
    const colorLight  = _goldLight;
    const colorMid    = _goldMid;
    const colorDeep   = _goldDeep;
    const colorRing   = _goldRing;
    const colorBorder = _goldBorder;
    canvas.drawPath(
      pinPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx - r * 0.5, headCY - r),
          Offset(cx + r * 0.5, tipY),
          [colorLight, colorMid, colorDeep],
          [0.0, 0.42, 1.0],
        ),
    );

    // Center ring only (transparent fill) around the icon.
    canvas.drawCircle(
      Offset(cx, headCY),
      r * 0.61,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.35
        ..color = colorRing,
    );

    // Inner crisp highlight ring for the glossy/luxury look.
    canvas.drawCircle(
      Offset(cx, headCY),
      r * 0.50,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 0.9
        ..color = const Color(0x88FFFFFF),
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

    // ── 5. Thin bright border around full pin ──
    canvas.drawPath(
      pinPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.25
        ..color = colorBorder,
    );

    // ── 6. Transparent hole where icon would be ──
    canvas.drawCircle(
      Offset(cx, headCY),
      r * 0.52,
      Paint()..blendMode = BlendMode.clear,
    );
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
    final iconSize = r * 1.18;
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(iconData.codePoint),
        style: TextStyle(
          fontSize: iconSize,
          fontFamily: iconData.fontFamily,
          package: iconData.fontPackage,
          color: const Color(0xFFF8FBFF),
          shadows: const [Shadow(color: Color(0x66000000), blurRadius: 4)],
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
  bool isPickup = true,
}) async {
  final key = '${icon.codePoint}_${size}_$isPickup';
  if (_goldenPinCache.containsKey(key)) return _goldenPinCache[key]!;

  final painter = GoldenPinPainter(icon: icon, size: size, isPickup: isPickup);
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



