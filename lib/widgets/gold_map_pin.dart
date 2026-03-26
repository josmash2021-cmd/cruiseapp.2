import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Pin icon types for contextual display inside the gold pin.
enum GoldPinIcon { none, person, house, store, airplane }

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
  const double h = 130;
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
/// The pin tip is at (ox + size/2, oy + size).
void drawGoldPinAt(
  Canvas canvas,
  double ox,
  double oy,
  double size, {
  GoldPinIcon icon = GoldPinIcon.none,
}) {
  final cx = ox + size / 2;
  final tipY = oy + size;
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
  }
}
