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
  double get _height => size * 1.12;

  // ── Gold palette ──
  static const _goldLight = Color(0xFFF5DC7A);
  static const _goldMid   = Color(0xFFD4A800);
  static const _goldDeep  = Color(0xFFB08800);

  void paint(Canvas canvas, Size canvasSize) {
    final w = _width;
    final cx = w / 2;

    // V2 crescent cup measurements
    final r = w * 0.30;
    final cupCY = w * 0.34;
    final thick = r * 0.28;
    final tipY = _height - w * 0.01;
    final iconCY = cupCY;

    const arcStart = 0.5654866776; // pi * 0.18
    const arcEnd   = 2.5761455262; // pi * 0.82
    const arcSweep = arcEnd - arcStart;

    // ── 1. White fade glow behind icon ──
    final glowR = r * 0.60;
    canvas.drawCircle(
      Offset(cx, iconCY),
      glowR,
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(cx, iconCY),
          glowR,
          [
            Colors.white.withValues(alpha: 0.50),
            Colors.white.withValues(alpha: 0.15),
            Colors.transparent,
          ],
          [0.0, 0.45, 1.0],
        ),
    );

    // ── 2. Gold crescent cup + sharp tail ──
    final outerPath = Path()
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, cupCY), radius: r),
        arcStart, arcSweep, true,
      );

    final endX = cx + r * math.cos(arcEnd);
    final endY = cupCY + r * math.sin(arcEnd);
    final startX = cx + r * math.cos(arcStart);
    final startY = cupCY + r * math.sin(arcStart);

    // Tail left → sharp pointy tip
    outerPath.quadraticBezierTo(
      endX + r * 0.06, tipY - (tipY - endY) * 0.25,
      cx, tipY,
    );
    // Tail right → back to arc start
    outerPath.quadraticBezierTo(
      startX - r * 0.06, tipY - (tipY - startY) * 0.25,
      startX, startY,
    );
    outerPath.close();

    // Crescent with inner cutout (even-odd)
    final crescent = Path()..addPath(outerPath, Offset.zero);
    final innerR = r - thick;
    final iArcStart = arcStart + 0.08;
    final iArcEnd = arcEnd - 0.08;
    crescent.moveTo(
      cx + innerR * math.cos(iArcStart),
      cupCY + innerR * math.sin(iArcStart),
    );
    crescent.arcTo(
      Rect.fromCircle(center: Offset(cx, cupCY), radius: innerR),
      iArcStart, iArcEnd - iArcStart, false,
    );
    final iStartX = cx + innerR * math.cos(iArcStart);
    final iStartY = cupCY + innerR * math.sin(iArcStart);
    final iEndY = cupCY + innerR * math.sin(iArcEnd);
    crescent.quadraticBezierTo(cx, iEndY + thick * 0.9, iStartX, iStartY);
    crescent.close();
    crescent.fillType = PathFillType.evenOdd;

    // Shadow glow (outer shape only)
    canvas.drawPath(
      outerPath,
      Paint()
        ..color = const Color(0x73D4A800)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Gold gradient fill
    canvas.drawPath(
      crescent,
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, cupCY - r),
          Offset(cx, tipY),
          [_goldLight, _goldMid, _goldDeep],
          [0.0, 0.45, 1.0],
        ),
    );

    // ── 3. Subtle highlight on upper rim ──
    final hlPath = Path()
      ..arcTo(
        Rect.fromCircle(center: Offset(cx, cupCY), radius: r - 1),
        arcStart + 0.1, arcSweep * 0.35, true,
      );
    canvas.drawPath(
      hlPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = r * 0.07
        ..color = Colors.white.withValues(alpha: 0.28),
    );

    // ── 4. White icon ──
    _drawIcon(canvas, icon, cx, iconCY, r);
  }

  void _drawIcon(Canvas canvas, IconData iconData, double cx, double cy, double r) {
    final iconSize = r * 1.35;
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



