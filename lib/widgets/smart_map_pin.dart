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
  double get _height => size * 1.30;
  double get _cx     => _width / 2;
  double get _r      => _width * 0.42;
  double get _headCY => _r + _width * 0.08;
  double get _tipY   => _height;

  // ── Gold palette ──
  static const _goldLight = Color(0xFFFFE88A);
  static const _goldMid   = Color(0xFFD4A520);
  static const _goldDeep  = Color(0xFF8B6914);

  void paint(Canvas canvas, Size canvasSize) {
    final cx     = _cx;
    final r      = _r;
    final headCY = _headCY;
    final tipY   = _tipY;

    // ── 1. Golden tail (cone shape) ──
    final tailPath = _buildTail(cx, headCY, r, tipY);

    // Gold gradient fill
    canvas.drawPath(
      tailPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, headCY + r * 0.2),
          Offset(cx, tipY),
          [_goldLight, _goldMid, _goldDeep],
          [0.0, 0.50, 1.0],
        ),
    );

    // ── 2. Full golden ring around circle ──
    final arcRect = Rect.fromCircle(center: Offset(cx, headCY), radius: r);
    canvas.drawArc(
      arcRect,
      0,
      math.pi * 2,     // full 360°
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeCap = StrokeCap.round
        ..shader = ui.Gradient.sweep(
          Offset(cx, headCY),
          [
            const Color(0xAAFFE4A0),
            const Color(0xFFD4AF37),
            const Color(0xFFA07810),
            const Color(0xFFD4AF37),
            const Color(0xAAFFE4A0),
          ],
          [0.0, 0.25, 0.5, 0.75, 1.0],
        ),
    );

    // ── 3. White icon ──
    _drawIcon(canvas, icon, cx, headCY, r);
  }

  /// Tail shape: needle-like sharp teardrop from circle bottom.
  Path _buildTail(double cx, double headCY, double r, double tipY) {
    const spread = 0.55;
    final rx = cx + r * math.sin(spread);
    final ry = headCY + r * math.cos(spread);
    final lx = cx - r * math.sin(spread);
    final ly = ry;
    // Keep control points very tight near the apex for a clearly pointed tip.
    final tipW = r * 0.02;
    return Path()
      ..moveTo(cx, tipY)
      // Right side: sharp apex to right edge of circle.
      ..cubicTo(
        cx + tipW, tipY - (tipY - ry) * 0.02,
        rx - r * 0.01, ry + (tipY - ry) * 0.18,
        rx, ry,
      )
      // Short arc across bottom of circle (connects right to left)
      ..arcToPoint(
        Offset(lx, ly),
        radius: Radius.circular(r),
        clockwise: false,
        largeArc: false,
      )
      // Left side: left edge of circle returns to a sharp apex.
      ..cubicTo(
        lx + r * 0.01, ly + (tipY - ly) * 0.18,
        cx - tipW, tipY - (tipY - ly) * 0.02,
        cx, tipY,
      )
      ..close();
  }

  void _drawIcon(Canvas canvas, IconData iconData, double cx, double cy, double r) {
    final iconSize = r * 1.15;
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(iconData.codePoint),
        style: TextStyle(
          fontSize: iconSize,
          fontFamily: iconData.fontFamily,
          package: iconData.fontPackage,
          color: Colors.white,
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
  // Use ceil to ensure the pin tip (at bottom) is fully included in the image
  final img = await picture.toImage(
    (w * scale).ceil(),
    (h * scale).ceil(),
  );
  final data = await img.toByteData(format: ui.ImageByteFormat.png);
  if (data == null) return Uint8List(0);

  final bytes = data.buffer.asUint8List();
  _goldenPinCache[key] = bytes;
  return bytes;
}



