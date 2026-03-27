import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

/// Luxury glass-gold teardrop map pin renderer.
///
/// Use with Mapbox PointAnnotationOptions:
/// ```dart
/// final bytes = await GoldPinRenderer.render(isPickup: true);
/// mgr.create(PointAnnotationOptions(image: bytes, iconAnchor: BOTTOM));
/// ```
///
/// The tip of the pin is at the bottom center of the image.
class GoldPinRenderer {
  GoldPinRenderer._();

  static const _goldLight = Color(0xFFFFF8DC);
  static const _goldMid   = Color(0xFFE8C547);
  static const _goldDeep  = Color(0xFFB8860B);

  static Future<Uint8List> render({
    bool isPickup = true,
    bool withHouse = false,
  }) async {
    final recorder = ui.PictureRecorder();
    const double w = 80;
    const double h = 110;
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

    const cx     = w / 2;
    const r      = 26.0;
    const headCY = r + 8.0;
    const tipY   = 88.0;
    const shadowY = 102.0;

    // ── Ground shadow ring (SEPARATED — floating illusion) ──
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(cx, shadowY), width: r * 1.4, height: r * 0.32),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // ── Teardrop path ──
    final tearPath = _buildTeardrop(cx, headCY, r, tipY);

    // ── Drop shadow behind pin ──
    canvas.drawPath(
      tearPath.shift(const Offset(0, 4)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.26)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );

    // ── Gold gradient fill ──
    canvas.drawPath(
      tearPath,
      Paint()
        ..shader = ui.Gradient.linear(
          const Offset(cx - r * 0.5, headCY - r),
          const Offset(cx + r * 0.5, tipY),
          [_goldLight, _goldMid, _goldDeep],
          [0.0, 0.45, 1.0],
        ),
    );

    // ── Glass sheen ──
    canvas.save();
    canvas.clipPath(tearPath);
    canvas.drawOval(
      Rect.fromCenter(
        center: const Offset(cx - r * 0.28, headCY - r * 0.25),
        width: r * 0.90, height: r * 0.60,
      ),
      Paint()
        ..color = const Color(0x66FFFFFF)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(
      const Offset(cx - r * 0.32, headCY - r * 0.32),
      r * 0.14,
      Paint()..color = Colors.white.withValues(alpha: 0.85),
    );
    canvas.restore();

    // ── Thin border ──
    canvas.drawPath(
      tearPath,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5
        ..color = Colors.white.withValues(alpha: 0.35),
    );

    // ── Icon ──
    _drawIcon(canvas, cx, headCY, r, isPickup: isPickup, withHouse: withHouse);

    final pic = recorder.endRecording();
    final img = await pic.toImage(w.toInt(), h.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  static Path _buildTeardrop(double cx, double headCY, double r, double tipY) {
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

  static void _drawIcon(
    Canvas canvas,
    double cx,
    double cy,
    double r, {
    required bool isPickup,
    required bool withHouse,
  }) {
    final paint = Paint()..color = Colors.white..isAntiAlias = true;
    final iconSize = r * 1.25;

    if (withHouse) {
      _drawMaterialIcon(canvas, Icons.home_rounded, cx, cy, iconSize);
    } else if (!isPickup) {
      _drawMaterialIcon(canvas, Icons.location_on, cx, cy, iconSize);
    } else {
      // Person: head + body
      final hr = r * 0.30;
      canvas.drawCircle(Offset(cx, cy - hr), hr, paint);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(cx - r * 0.50, cy, cx + r * 0.50, cy + r * 0.65),
          topLeft: Radius.circular(r * 0.50),
          topRight: Radius.circular(r * 0.50),
        ),
        paint,
      );
    }
  }

  static void _drawMaterialIcon(
    Canvas canvas, IconData iconData, double cx, double cy, double size,
  ) {
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(iconData.codePoint),
        style: TextStyle(
          fontSize: size,
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


/// Renders a 3D gold teardrop map pin as raw PNG bytes (Uint8List).
///
/// Use with Mapbox PointAnnotationOptions:
/// ```dart
/// final bytes = await GoldPinRenderer.render(isPickup: true);
/// mgr.create(PointAnnotationOptions(image: bytes, iconAnchor: BOTTOM));
/// ```
///
/// The tip of the pin is at the bottom center of the image.
/// Use `iconAnchor: IconAnchor.BOTTOM` so the tip aligns with the coordinate.
class GoldPinRenderer {
  GoldPinRenderer._();

  static const _gold = Color(0xFFE8C547);

  /// Renders a gold teardrop pin as PNG bytes.
  /// [isPickup] true → person icon; false → square destination icon.
  /// [withHouse] true → house icon (overrides isPickup).
  static Future<Uint8List> render({
    bool isPickup = true,
    bool withHouse = false,
  }) async {
    final recorder = ui.PictureRecorder();
    const double w = 120;
    const double h = 125;
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

    const cx = w / 2;
    const bulbR = 42.0;
    const bulbCy = 50.0;
    const tipY = h - 6.0;

    // 1. Drop shadow
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(cx, tipY + 2), width: 28, height: 8),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // 2. Tail (teardrop)
    final tail = Path()
      ..moveTo(cx - 18, bulbCy + bulbR * 0.55)
      ..quadraticBezierTo(cx - 6, tipY - 10, cx, tipY)
      ..quadraticBezierTo(cx + 6, tipY - 10, cx + 18, bulbCy + bulbR * 0.55)
      ..close();
    canvas.drawPath(tail, Paint()..color = _gold);

    // 3. Outer glow ring
    canvas.drawCircle(
      const Offset(cx, bulbCy),
      bulbR + 4,
      Paint()
        ..color = _gold.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // 4. Main bulb (radial gradient)
    final bulbGrad = Paint()
      ..shader = ui.Gradient.radial(
        const Offset(cx - bulbR * 0.25, bulbCy - bulbR * 0.25),
        bulbR * 1.2,
        [const Color(0xFFFFF0A0), _gold, const Color(0xFFB8900A)],
        [0.0, 0.5, 1.0],
      );
    canvas.drawCircle(const Offset(cx, bulbCy), bulbR, bulbGrad);

    // 5. 3D highlight
    canvas.drawCircle(
      Offset(cx - bulbR * 0.28, bulbCy - bulbR * 0.28),
      bulbR * 0.38,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    canvas.drawCircle(
      Offset(cx - bulbR * 0.22, bulbCy - bulbR * 0.22),
      bulbR * 0.12,
      Paint()..color = Colors.white.withValues(alpha: 0.75),
    );

    // 6. Outer border ring
    canvas.drawCircle(
      const Offset(cx, bulbCy),
      bulbR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white.withValues(alpha: 0.40),
    );

    // 7. White icon inside bulb
    final iconPaint = Paint()
      ..color = Colors.white
      ..isAntiAlias = true;
    final iconShadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.18)
      ..isAntiAlias = true;

    if (withHouse) {
      final hs = bulbR * 0.40;
      final iconCy = bulbCy + hs * 0.15;
      final roofS = Path()
        ..moveTo(cx + 1, iconCy - hs * 1.05 + 1)
        ..lineTo(cx - hs + 1, iconCy - hs * 0.05 + 1)
        ..lineTo(cx + hs + 1, iconCy - hs * 0.05 + 1)
        ..close();
      canvas.drawPath(roofS, iconShadowPaint);
      final roof = Path()
        ..moveTo(cx, iconCy - hs * 1.05)
        ..lineTo(cx - hs, iconCy - hs * 0.05)
        ..lineTo(cx + hs, iconCy - hs * 0.05)
        ..close();
      canvas.drawPath(roof, iconPaint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(cx - hs * 0.65, iconCy - hs * 0.05, cx + hs * 0.65, iconCy + hs * 0.85),
          Radius.circular(hs * 0.1),
        ),
        iconPaint,
      );
    } else if (!isPickup) {
      final s = bulbR * 0.35;
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx, bulbCy), width: s * 2, height: s * 2),
          Radius.circular(s * 0.25),
        ),
        iconShadowPaint..color = Colors.black.withValues(alpha: 0.18),
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx - 1, bulbCy - 1), width: s * 2, height: s * 2),
          Radius.circular(s * 0.25),
        ),
        iconPaint,
      );
    } else {
      final s = bulbR * 0.38;
      canvas.drawCircle(Offset(cx, bulbCy - s * 0.52), s * 0.42, iconPaint);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(cx - s * 0.75, bulbCy + s * 0.02, cx + s * 0.75, bulbCy + s * 0.85),
          topLeft: Radius.circular(s * 0.75),
          topRight: Radius.circular(s * 0.75),
          bottomLeft: Radius.circular(s * 0.12),
          bottomRight: Radius.circular(s * 0.12),
        ),
        iconPaint,
      );
    }

    final pic = recorder.endRecording();
    final img = await pic.toImage(w.toInt(), h.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }
}
