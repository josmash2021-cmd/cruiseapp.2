import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Pin icon types for contextual display inside the gold pin.
enum GoldPinIcon { none, person, house, store, airplane, car }

/// Detects the appropriate contextual icon from an address label.
GoldPinIcon detectPinIcon(String label) {
  final l = label.toLowerCase();
  if (l.contains('airport') ||
      l.contains('terminal') ||
      RegExp(
        r'\b(mia|fll|jfk|lax|ord|atl|sfo|dfw|ewr|bos|iah|dca|phl|msp|dtw|sea|den|las|mco|clt)\b',
      ).hasMatch(l)) {
    return GoldPinIcon.airplane;
  }
  if (l.contains('store') ||
      l.contains('shop') ||
      l.contains('mall') ||
      l.contains('plaza') ||
      l.contains('market') ||
      l.contains('center') ||
      l.contains('restaurant') ||
      l.contains('hotel') ||
      l.contains('bar') ||
      l.contains('café') ||
      l.contains('cafe') ||
      l.contains('gym') ||
      l.contains('salon') ||
      l.contains('office') ||
      l.contains('hospital') ||
      l.contains('clinic') ||
      l.contains('bank') ||
      l.contains('pharmacy')) {
    return GoldPinIcon.store;
  }
  if (RegExp(r'^\d+\s').hasMatch(l) &&
      RegExp(
        r'\b(st|ave|rd|dr|ln|ct|blvd|way|pkwy|pl|cir|ter|loop)\b',
      ).hasMatch(l)) {
    return GoldPinIcon.house;
  }
  return GoldPinIcon.person;
}

/// Primary gold color used across all pin rendering.
const goldPinColor = Color(0xFFE8C547);

// ── Luxury pin palette ──
const _glassWhite = Color(0x66FFFFFF); // glass sheen

// ── Gold palette (shared by pickup and dropoff) ──
const _colorLight = Color(0xFFFFF8DC);
const _colorMid   = Color(0xFFE8C547);
const _colorDeep  = Color(0xFFB8860B);

/// Cache for rendered pin bytes.
final Map<String, Uint8List> _pinCache = {};

// ═══════════════════════════════════════════════════════════════════
//  SHARED DRAWING — draws the luxury glass-gold pin onto [canvas].
//
//  Layout (w=80, h=108):
//    ┌───────────────────┐
//    │   circle head     │  r=26, cy=32
//    │  (icon inside)    │
//    │       │           │
//    │     tail          │
//    │       ▼           │  tip at y=86
//    │                   │
//    │   ░░shadow░░      │  ellipse y=100 — SEPARATED from tip
//    └───────────────────┘
// ═══════════════════════════════════════════════════════════════════
void _drawLuxuryPin(
  Canvas canvas, {
  required double cx,
  required double headCY,
  required double r,
  required double tipY,
  required double shadowY,
  required GoldPinIcon icon,
  bool isPickup = true,
}) {
  final colorLight  = _colorLight;
  final colorMid    = _colorMid;
  final colorDeep   = _colorDeep;
  // ── 1. Ground shadow ring — SEPARATED (creates floating illusion) ──
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(cx, shadowY),
      width: r * 1.4,
      height: r * 0.32,
    ),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.22)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
  );

  // ── 2. Build teardrop path ──
  final path = Path()
    ..moveTo(cx, tipY)
    ..cubicTo(cx + r * 0.20, tipY - (tipY - headCY) * 0.35,
              cx + r * 0.95, headCY + r * 0.75,
              cx + r, headCY)
    ..arcTo(
      Rect.fromCircle(center: Offset(cx, headCY), radius: r),
      0, -math.pi * 2, false,
    )
    ..cubicTo(cx - r * 0.95, headCY + r * 0.75,
              cx - r * 0.20, tipY - (tipY - headCY) * 0.35,
              cx, tipY)
    ..close();

  // Alternate clean teardrop: arc + cubic taper
  final tearPath = _buildTeardrop(cx, headCY, r, tipY);

  // ── 3. Drop shadow behind pin ──
  canvas.drawPath(
    tearPath.shift(const Offset(0, 4)),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.28)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
  );

  // ── 4. Gradient fill ──
  final gradRect = Rect.fromLTWH(cx - r, headCY - r, r * 2, tipY - headCY + r);
  canvas.drawPath(
    tearPath,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - r * 0.5, headCY - r),
        Offset(cx + r * 0.5, tipY),
        [colorLight, colorMid, colorDeep],
        [0.0, 0.45, 1.0],
      ),
  );

  // ── 5. Glass sheen — white oval on upper-left of head ──
  canvas.save();
  canvas.clipPath(tearPath);
  canvas.drawOval(
    Rect.fromCenter(
      center: Offset(cx - r * 0.28, headCY - r * 0.25),
      width: r * 0.90,
      height: r * 0.60,
    ),
    Paint()
      ..color = _glassWhite
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
  );
  // Secondary micro-specular dot
  canvas.drawCircle(
    Offset(cx - r * 0.32, headCY - r * 0.32),
    r * 0.14,
    Paint()..color = Colors.white.withValues(alpha: 0.85),
  );
  canvas.restore();

  // ── 6. Thin bright-gold outer border ──
  canvas.drawPath(
    tearPath,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..color = Colors.white.withValues(alpha: 0.35),
  );

  // ── 7. Icon inside head ──
  _drawPinIcon(canvas, icon, cx, headCY, r);
}

/// Clean teardrop: full arc for head + smooth cubic taper to tip.
Path _buildTeardrop(double cx, double headCY, double r, double tipY) {
  const taper = 0.58; // radians from bottom of circle where taper starts
  final rx = cx + r * math.sin(taper);
  final ry = headCY + r * math.cos(taper);
  final lx = cx - r * math.sin(taper);

  return Path()
    ..moveTo(cx, tipY)
    ..cubicTo(cx + r * 0.14, tipY - (tipY - ry) * 0.38,
              rx + r * 0.08, ry + (tipY - ry) * 0.20,
              rx, ry)
    ..arcToPoint(Offset(lx, ry),
        radius: Radius.circular(r), clockwise: false, largeArc: true)
    ..cubicTo(lx - r * 0.08, ry + (tipY - ry) * 0.20,
              cx - r * 0.14, tipY - (tipY - ry) * 0.38,
              cx, tipY)
    ..close();
}

/// Draws the icon inside the pin head with generous size.
void _drawPinIcon(Canvas canvas, GoldPinIcon icon, double cx, double cy, double r) {
  final iconSize = r * 1.25; // large so icons are clearly visible
  final paint = Paint()..color = Colors.white..isAntiAlias = true;
  final shadowPaint = Paint()
    ..color = Colors.black.withValues(alpha: 0.20)
    ..isAntiAlias = true;

  IconData iconData = Icons.home_rounded;
  switch (icon) {
    case GoldPinIcon.person:
      // Person: head circle + body trapezoid
      final hr = r * 0.30;
      canvas.drawCircle(Offset(cx + 1, cy - hr - 1), hr, shadowPaint);
      canvas.drawCircle(Offset(cx, cy - hr), hr, paint);
      final body = RRect.fromRectAndCorners(
        Rect.fromLTRB(cx - r * 0.50 + 1, cy + 1, cx + r * 0.50 + 1, cy + r * 0.65 + 1),
        topLeft: Radius.circular(r * 0.50),
        topRight: Radius.circular(r * 0.50),
      );
      canvas.drawRRect(body, shadowPaint);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(cx - r * 0.50, cy, cx + r * 0.50, cy + r * 0.65),
          topLeft: Radius.circular(r * 0.50),
          topRight: Radius.circular(r * 0.50),
        ),
        paint,
      );
      return;
    case GoldPinIcon.house:
      iconData = Icons.home_rounded;
      break;
    case GoldPinIcon.store:
      iconData = Icons.storefront_rounded;
      break;
    case GoldPinIcon.airplane:
      iconData = Icons.flight_takeoff_rounded;
      break;
    case GoldPinIcon.car:
      iconData = Icons.directions_car_rounded;
      break;
    case GoldPinIcon.none:
      // Simple white dot
      canvas.drawCircle(Offset(cx, cy), r * 0.30, paint);
      return;
  }

  final resolvedIcon = iconData;
  final tp = TextPainter(
    text: TextSpan(
      text: String.fromCharCode(resolvedIcon.codePoint),
      style: TextStyle(
        fontSize: iconSize,
        fontFamily: resolvedIcon.fontFamily,
        package: resolvedIcon.fontPackage,
        color: Colors.white,
        shadows: const [Shadow(color: Color(0x44000000), blurRadius: 4)],
      ),
    ),
    textDirection: TextDirection.ltr,
  )..layout();
  tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
}

// ═══════════════════════════════════════════════════════════════════
//  PUBLIC API — renderGoldPinBytes (used by Mapbox annotations)
// ═══════════════════════════════════════════════════════════════════

/// Renders a luxury glass-gold teardrop map-pin as PNG bytes.
/// The TIP of the pin is at the BOTTOM CENTER. Use `iconAnchor: BOTTOM`.
Future<Uint8List> renderGoldPinBytes({
  GoldPinIcon icon = GoldPinIcon.none,
  bool isPickup = true,
}) async {
  final effectiveIcon = icon == GoldPinIcon.none
      ? (isPickup ? GoldPinIcon.person : GoldPinIcon.person)
      : icon;
  final key = '${effectiveIcon.name}_$isPickup';
  if (_pinCache.containsKey(key)) return _pinCache[key]!;

  const double w = 80;
  const double h = 110;
  const double cx = w / 2;
  const double r = 26.0;
  const double headCY = r + 8;
  const double tipY = 88.0;
  const double shadowY = 102.0; // SEPARATED from tip

  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

  _drawLuxuryPin(
    canvas,
    cx: cx,
    headCY: headCY,
    r: r,
    tipY: tipY,
    shadowY: shadowY,
    icon: effectiveIcon,
    isPickup: isPickup,
  );

  final picture = recorder.endRecording();
  final img = await picture.toImage(w.toInt(), h.toInt());
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  final bytes = byteData!.buffer.asUint8List();
  _pinCache[key] = bytes;
  return bytes;
}

// ═══════════════════════════════════════════════════════════════════
//  drawGoldPinAt — Canvas-based variant for composite renders
// ═══════════════════════════════════════════════════════════════════

/// Draws a luxury gold pin directly onto [canvas] at position (ox, oy).
/// The pin tip is at (ox + size/2, oy + size * 0.87).
void drawGoldPinAt(
  Canvas canvas,
  double ox,
  double oy,
  double size, {
  GoldPinIcon icon = GoldPinIcon.none,
}) {
  final cx = ox + size / 2;
  final r = size * 0.30;
  final headCY = oy + r + size * 0.06;
  final tipY = oy + size * 0.87;
  final shadowY = oy + size * 0.98;

  _drawLuxuryPin(
    canvas,
    cx: cx,
    headCY: headCY,
    r: r,
    tipY: tipY,
    shadowY: shadowY,
    icon: icon,
  );
}
