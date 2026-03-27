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
const _goldLight  = Color(0xFFFFF8DC); // ivory-gold highlight
const _goldMid    = Color(0xFFE8C547); // primary gold
const _goldDeep   = Color(0xFFB8860B); // dark gold shadow
const _glassWhite = Color(0x66FFFFFF); // glass sheen

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
}) {
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

  // ── 4. Gold gradient fill ──
  final gradRect = Rect.fromLTWH(cx - r, headCY - r, r * 2, tipY - headCY + r);
  canvas.drawPath(
    tearPath,
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx - r * 0.5, headCY - r),
        Offset(cx + r * 0.5, tipY),
        [_goldLight, _goldMid, _goldDeep],
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

  IconData? iconData;
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
    case GoldPinIcon.store:
      iconData = Icons.storefront_rounded;
    case GoldPinIcon.airplane:
      iconData = Icons.flight_takeoff_rounded;
    case GoldPinIcon.car:
      iconData = Icons.directions_car_rounded;
    case GoldPinIcon.none:
      // Simple white dot
      canvas.drawCircle(Offset(cx, cy), r * 0.30, paint);
      return;
  }

  if (iconData != null) {
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

/// Gold color used across all pin rendering.
const goldPinColor = Color(0xFFE8C547);

/// Cache for rendered pin bytes — avoids re-rendering the same pin repeatedly.
final Map<String, Uint8List> _pinCache = {};

/// Renders a gold teardrop map-pin as PNG bytes, matching the design from
/// the "Choose a ride" screen. The TIP of the pin is at the BOTTOM CENTER
/// of the image. Use `iconAnchor: BOTTOM` in Mapbox annotations.
///
/// [icon] — contextual icon rendered inside the pin head.
/// [isPickup] — affects the inner icon (person for pickup, square for dropoff)
///              only when [icon] is [GoldPinIcon.none].
///
/// Results are cached by (icon, isPickup) key.
Future<Uint8List> renderGoldPinBytes({
  GoldPinIcon icon = GoldPinIcon.none,
  bool isPickup = true,
}) async {
  final key = '${icon.name}_$isPickup';
  if (_pinCache.containsKey(key)) return _pinCache[key]!;

  const double w = 100;
  const double h = 105;
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
  const cx = w / 2;
  const r = 30.0;
  const headCY = r + 8;
  const tipY = h;

  // ── Teardrop path (head + tail, tip at exact bottom) ──
  final path = Path()
    ..moveTo(cx - r, headCY)
    ..arcTo(
      Rect.fromCircle(center: const Offset(cx, headCY), radius: r),
      math.pi, -math.pi, false,
    )
    ..cubicTo(cx + r, headCY + r, cx + r * 0.22, tipY - 4, cx, tipY)
    ..cubicTo(cx - r * 0.22, tipY - 4, cx - r, headCY + r, cx - r, headCY)
    ..close();

  // ── Drop shadow ──
  canvas.drawPath(
    path.shift(const Offset(0, 3)),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.32)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
  );

  // ── Gold fill ──
  canvas.drawPath(path, Paint()..color = goldPinColor);

  // ── White border ──
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.22),
  );

  // ── Specular highlight ──
  canvas.drawCircle(
    Offset(cx - r * 0.25, headCY - r * 0.25),
    r * 0.42,
    Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
  );

  // ── Fade blend at tip: vertical gradient transparent→route-blue ──
  final fadeTop = headCY + r * 0.8;
  canvas.drawRect(
    Rect.fromLTRB(cx - r, fadeTop, cx + r, tipY),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, fadeTop),
        Offset(cx, tipY),
        [Colors.transparent, const Color(0x885BA3F5)],
      )
      ..blendMode = BlendMode.srcATop,
  );

  // ── White icon inside head ──
  final iconPaint = Paint()
    ..color = Colors.white
    ..isAntiAlias = true;
  const s = r * 0.43;
  const iy = headCY;

  // Determine effective icon
  final effectiveIcon = icon == GoldPinIcon.none
      ? (isPickup ? GoldPinIcon.person : GoldPinIcon.person)
      : icon;

  switch (effectiveIcon) {
    case GoldPinIcon.house:
      final roofPath = Path()
        ..moveTo(cx, iy - s * 1.1)
        ..lineTo(cx - s * 1.0, iy - s * 0.15)
        ..lineTo(cx + s * 1.0, iy - s * 0.15)
        ..close();
      canvas.drawPath(roofPath, iconPaint);
      canvas.drawRect(
        Rect.fromLTRB(cx - s * 0.7, iy - s * 0.15, cx + s * 0.7, iy + s * 0.8),
        iconPaint,
      );
      canvas.drawRect(
        Rect.fromLTRB(cx - s * 0.2, iy + s * 0.2, cx + s * 0.2, iy + s * 0.8),
        Paint()..color = goldPinColor,
      );
      break;
    case GoldPinIcon.store:
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(cx - s * 0.9, iy - s * 0.9, cx + s * 0.9, iy - s * 0.2),
          Radius.circular(s * 0.3),
        ),
        iconPaint,
      );
      canvas.drawRect(
        Rect.fromLTRB(cx - s * 0.9, iy - s * 0.2, cx + s * 0.9, iy + s * 0.8),
        iconPaint,
      );
      canvas.drawRect(
        Rect.fromLTRB(cx - s * 0.5, iy, cx + s * 0.5, iy + s * 0.5),
        Paint()..color = goldPinColor,
      );
      break;
    case GoldPinIcon.airplane:
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.flight_takeoff_rounded.codePoint),
          style: TextStyle(
            fontSize: s * 2.8,
            fontFamily: Icons.flight_takeoff_rounded.fontFamily,
            package: Icons.flight_takeoff_rounded.fontPackage,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, iy - tp.height / 2));
      break;
    case GoldPinIcon.person:
      canvas.drawCircle(Offset(cx, iy - s * 0.5), s * 0.5, iconPaint);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(cx - s * 0.8, iy + s * 0.15, cx + s * 0.8, iy + s * 0.9),
          topLeft: Radius.circular(s * 0.8),
          topRight: Radius.circular(s * 0.8),
          bottomLeft: Radius.circular(s * 0.15),
          bottomRight: Radius.circular(s * 0.15),
        ),
        iconPaint,
      );
      break;
    case GoldPinIcon.car:
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.directions_car_rounded.codePoint),
          style: TextStyle(
            fontSize: s * 2.8,
            fontFamily: Icons.directions_car_rounded.fontFamily,
            package: Icons.directions_car_rounded.fontPackage,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, iy - tp.height / 2));
      break;
    case GoldPinIcon.none:
      // White circle in center
      canvas.drawCircle(const Offset(cx, iy), s * 0.7, iconPaint);
      break;
  }

  final picture = recorder.endRecording();
  final img = await picture.toImage(w.toInt(), h.toInt());
  final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
  final bytes = byteData!.buffer.asUint8List();
  _pinCache[key] = bytes;
  return bytes;
}

/// Draws a gold pin directly onto a canvas at position (ox, oy) with given
/// [size]. This is the Canvas-based variant used in screens that render
/// markers as part of a larger composite image (e.g. ride_request_screen).
///
/// The pin tip is at (ox + size/2, oy + size * 0.85).
void drawGoldPinAt(
  Canvas canvas,
  double ox,
  double oy,
  double size, {
  GoldPinIcon icon = GoldPinIcon.none,
}) {
  final cx = ox + size / 2;
  final tipY = oy + size * 0.85;
  final r = size * 0.32;
  final headCY = oy + r + size * 0.04;

  // ── Build teardrop path ──
  final path = Path();
  path.moveTo(cx - r, headCY);
  path.arcTo(
    Rect.fromCircle(center: Offset(cx, headCY), radius: r),
    math.pi, -math.pi, false,
  );
  path.cubicTo(
    cx + r, headCY + r * 1.0,
    cx + r * 0.22, tipY - size * 0.04,
    cx, tipY,
  );
  path.cubicTo(
    cx - r * 0.22, tipY - size * 0.04,
    cx - r, headCY + r * 1.0,
    cx - r, headCY,
  );
  path.close();

  // ── Drop shadow ──
  canvas.drawPath(
    path.shift(const Offset(0, 3)),
    Paint()
      ..color = Colors.black.withValues(alpha: 0.32)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
  );

  // ── Fill teardrop with gold ──
  canvas.drawPath(path, Paint()..color = goldPinColor);

  // ── White inner stroke ──
  canvas.drawPath(
    path,
    Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..color = Colors.white.withValues(alpha: 0.22),
  );

  // ── Subtle highlight on top-left ──
  canvas.drawCircle(
    Offset(cx - r * 0.25, headCY - r * 0.25),
    r * 0.42,
    Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
  );

  // ── Fade blend at tip ──
  final fadeTop = headCY + r * 0.8;
  canvas.drawRect(
    Rect.fromLTRB(cx - r, fadeTop, cx + r, tipY),
    Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx, fadeTop),
        Offset(cx, tipY),
        [Colors.transparent, const Color(0x885BA3F5)],
      )
      ..blendMode = BlendMode.srcATop,
  );

  // ── White icon inside head ──
  final iconPaint = Paint()
    ..color = Colors.white
    ..isAntiAlias = true;
  final s = size * 0.12;
  final cy = headCY;

  switch (icon) {
    case GoldPinIcon.person:
      canvas.drawCircle(Offset(cx, cy - s * 0.65), s * 0.52, iconPaint);
      final body = RRect.fromRectAndCorners(
        Rect.fromLTRB(
          cx - s * 0.9, cy + s * 0.15,
          cx + s * 0.9, cy + s * 1.05,
        ),
        topLeft: Radius.circular(s * 0.9),
        topRight: Radius.circular(s * 0.9),
        bottomLeft: Radius.circular(s * 0.2),
        bottomRight: Radius.circular(s * 0.2),
      );
      canvas.drawRRect(body, iconPaint);
      break;
    case GoldPinIcon.house:
      final roof = Path()
        ..moveTo(cx, cy - s * 1.25)
        ..lineTo(cx - s * 1.15, cy - s * 0.1)
        ..lineTo(cx + s * 1.15, cy - s * 0.1)
        ..close();
      canvas.drawPath(roof, iconPaint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(cx - s * 0.8, cy - s * 0.1, cx + s * 0.8, cy + s * 0.9),
          Radius.circular(s * 0.08),
        ),
        iconPaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(cx - s * 0.22, cy + s * 0.3, cx + s * 0.22, cy + s * 0.9),
          Radius.circular(s * 0.15),
        ),
        Paint()..color = goldPinColor,
      );
      break;
    case GoldPinIcon.store:
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(cx - s * 1.1, cy - s * 1.0, cx + s * 1.1, cy - s * 0.3),
          topLeft: Radius.circular(s * 0.2),
          topRight: Radius.circular(s * 0.2),
        ),
        iconPaint,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(cx - s * 1.0, cy - s * 0.3, cx + s * 1.0, cy + s * 1.0),
          Radius.circular(s * 0.1),
        ),
        iconPaint,
      );
      break;
    case GoldPinIcon.airplane:
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.flight_takeoff_rounded.codePoint),
          style: TextStyle(
            fontSize: s * 2.8,
            fontFamily: Icons.flight_takeoff_rounded.fontFamily,
            package: Icons.flight_takeoff_rounded.fontPackage,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
      break;
    case GoldPinIcon.none:
      canvas.drawCircle(Offset(cx, cy), s * 0.7, iconPaint);
      break;
    case GoldPinIcon.car:
      final tp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.directions_car_rounded.codePoint),
          style: TextStyle(
            fontSize: s * 2.8,
            fontFamily: Icons.directions_car_rounded.fontFamily,
            package: Icons.directions_car_rounded.fontPackage,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx - tp.width / 2, cy - tp.height / 2));
      break;
  }
}
