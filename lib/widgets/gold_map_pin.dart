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
//    │   ░░shadow░░      │  ellipse at tip
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

  // ── 2. Golden crescent cup ──
  final cupPath = _buildCrescent(cx, headCY, r, tipY);
  canvas.drawPath(
    cupPath,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, headCY + r * 0.15),
        Offset(cx, tipY),
        [_colorLight, _colorMid, _colorDeep],
        [0.0, 0.45, 1.0],
      ),
  );
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
  const double h = 68;    // match tipY so pin tip is at exact canvas bottom
  const double cx = w / 2;
  const double r = 26.0;
  const double headCY = r + 6;
  const double tipY = 68.0;
  const double shadowY = 68.0;

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
