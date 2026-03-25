import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';

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
    const double h = 140;
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
