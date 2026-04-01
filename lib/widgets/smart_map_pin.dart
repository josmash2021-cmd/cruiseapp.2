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
    final iconCY = headCY - r * 0.10;

    // ── 1. White fade glow behind icon ──
    canvas.drawCircle(
      Offset(cx, iconCY),
      r * 0.85,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(cx, iconCY),
          r * 0.85,
          [
            Colors.white.withValues(alpha: 0.30),
            Colors.white.withValues(alpha: 0.07),
            Colors.transparent,
          ],
          [0.0, 0.50, 1.0],
        ),
    );

    // ── 2. Golden crescent cup (open top, V-point bottom) ──
    final cupPath = _buildCrescent(cx, headCY, r, tipY);
    canvas.drawPath(
      cupPath,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, headCY + r * 0.15),
          Offset(cx, tipY),
          [_goldLight, _goldMid, _goldDeep],
          [0.0, 0.45, 1.0],
        ),
    );

    // ── 3. White icon ──
    _drawIcon(canvas, icon, cx, iconCY, r);
  }

  /// Crescent cup shape: open at top, golden V tapering to point at bottom.
  Path _buildCrescent(double cx, double headCY, double r, double tipY) {
    final openY = headCY + r * 0.15;
    final halfW = r * 0.88;
    return Path()
      ..moveTo(cx - halfW, openY)
      // Left outer curve → V tip
      ..cubicTo(
        cx - halfW * 1.12, openY + (tipY - openY) * 0.52,
        cx - r * 0.10, tipY - (tipY - openY) * 0.10,
        cx, tipY,
      )
      // V tip → right opening
      ..cubicTo(
        cx + r * 0.10, tipY - (tipY - openY) * 0.10,
        cx + halfW * 1.12, openY + (tipY - openY) * 0.52,
        cx + halfW, openY,
      )
      // Concave inner curve (bowl top) back to start
      ..quadraticBezierTo(
        cx, openY - r * 0.30,
        cx - halfW, openY,
      );
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
  final key = '${icon.codePoint}_${size}_${scale}_$isPickup';
  if (_goldenPinCache.containsKey(key)) return _goldenPinCache[key]!;

  final painter = GoldenPinPainter(icon: icon, size: size, isPickup: isPickup);
  final w = painter._width;
  final h = painter._height;

  final recorder = ui.PictureRecorder();
  // Canvas must match the scaled output size so the content fills every pixel.
  // Without scale(), toImage(w*scale, h*scale) creates a larger image but the
  // drawing stays at [0..w, 0..h] — pin tip (at y=h) lands at image center,
  // not the bottom, causing iconAnchor:BOTTOM to float above the coordinate.
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w * scale, h * scale));
  canvas.scale(scale, scale); // scale drawing coords → fill the output image
  painter.paint(canvas, Size(w, h));

  final picture = recorder.endRecording();
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



