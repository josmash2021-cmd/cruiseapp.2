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

  /// Pin proportions
  double get _width => size;
  double get _height => size * 1.25;
  double get _cx => _width / 2;
  double get _circleY => _height * 0.34;
  double get _radius => _width * 0.37;
  double get _tipY => _height * 0.90;

  void paint(Canvas canvas, Size canvasSize) {
    final cx = _cx;
    final circleY = _circleY;
    final r = _radius;
    final tipY = _tipY;

    // ── 0. GROUND SHADOW (dark ellipse below tip) ──
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx, tipY + 4),
        width: r * 0.9,
        height: 8,
      ),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // ── 1. BUILD TEARDROP PATH ──
    final pinPath = _teardropPath(cx, circleY, r, tipY);

    // ── 2. GOLDEN GRADIENT FILL ──
    final pinBounds = Rect.fromLTWH(cx - r, circleY - r, r * 2, tipY - circleY + r);
    final gradient = RadialGradient(
      center: const Alignment(-0.3, -0.3),
      radius: 0.8,
      colors: const [
        Color(0xFFf5d76e), // bright gold highlight
        Color(0xFFc8a951), // mid gold
        Color(0xFF8B6914), // deep gold shadow
      ],
      stops: const [0.0, 0.5, 1.0],
    );
    canvas.drawPath(
      pinPath,
      Paint()..shader = gradient.createShader(pinBounds),
    );

    // ── 3. THIN DARK-GOLD BORDER ──
    canvas.drawPath(
      pinPath,
      Paint()
        ..color = const Color(0xFF705A10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );

    // ── 4. GLOSSY 3D SHINE (white semi-transparent highlight) ──
    canvas.save();
    canvas.clipPath(pinPath);
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx - r * 0.22, circleY - r * 0.18),
        width: r * 0.75,
        height: r * 0.55,
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.32),
    );
    canvas.restore();

    // ── 5. WHITE ICON (centered in circle head) ──
    _drawMaterialIcon(canvas, icon, cx, circleY, r);
  }

  /// Builds the teardrop/drop path: arc for the circle head +
  /// smooth curves tapering to the tip.
  Path _teardropPath(double cx, double circleY, double r, double tipY) {
    // Angle from bottom-center of circle where taper begins (~35°)
    const double taper = 0.60;

    // Points on circle where taper starts
    final double rx = cx + r * math.sin(taper);
    final double ry = circleY + r * math.cos(taper);
    final double lx = cx - r * math.sin(taper);
    final double ly = ry; // symmetric

    final path = Path()
      ..moveTo(cx, tipY)
      // Right side: cubic bezier from tip up to right taper point
      ..cubicTo(
        cx + r * 0.12, tipY - (tipY - ry) * 0.42, // cp1
        rx + r * 0.06, ry + (tipY - ry) * 0.24,    // cp2
        rx, ry,                                      // end
      )
      // Arc from right taper clockwise through top to left taper
      ..arcToPoint(
        Offset(lx, ly),
        radius: Radius.circular(r),
        clockwise: false,
        largeArc: true,
      )
      // Left side: cubic bezier from left taper point down to tip
      ..cubicTo(
        lx - r * 0.06, ly + (tipY - ly) * 0.24, // cp1
        cx - r * 0.12, tipY - (tipY - ly) * 0.42, // cp2
        cx, tipY,                                    // end
      )
      ..close();

    return path;
  }

  /// Renders a Material icon via TextPainter onto the canvas.
  void _drawMaterialIcon(
    Canvas canvas,
    IconData iconData,
    double cx,
    double cy,
    double radius,
  ) {
    final iconSize = radius * 0.85;
    final textPainter = TextPainter(
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
    );
    textPainter.layout();
    textPainter.paint(
      canvas,
      Offset(cx - textPainter.width / 2, cy - textPainter.height / 2),
    );
  }
}

// ──────────────────────────────────────────────────────────────────
//  BUILD GOLDEN PIN → BitmapDescriptor  (for Google Maps)
// ──────────────────────────────────────────────────────────────────

/// Returns a golden teardrop pin rendered as PNG [Uint8List].
///
/// [icon]  — Material icon to embed in the pin head.
/// [size]  — logical width in pixels (height = size × 1.25).
/// [scale] — device-pixel-ratio multiplier (default 2.0 for retina).
///
/// Results are cached by (icon.codePoint, size) key.
final Map<String, Uint8List> _goldenPinCache = {};

Future<Uint8List> buildGoldenPinBytes({
  required IconData icon,
  double size = 80,
  double scale = 2.0,
}) async {
  final key = '${icon.codePoint}_$size';
  if (_goldenPinCache.containsKey(key)) return _goldenPinCache[key]!;

  final w = size;
  final h = size * 1.25;

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));
  final painter = GoldenPinPainter(icon: icon, size: size);
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
