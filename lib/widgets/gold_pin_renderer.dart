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
    const double h = 132;
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));

    const cx = w / 2;
    const bulbR = 42.0;
    const bulbCy = 50.0;
    const tipY = h - 6.0;

    // 1. Tail (teardrop)
    final tail = Path()
      ..moveTo(cx - 18, bulbCy + bulbR * 0.55)
      ..quadraticBezierTo(cx - 6, tipY - 10, cx, tipY)
      ..quadraticBezierTo(cx + 6, tipY - 10, cx + 18, bulbCy + bulbR * 0.55)
      ..close();
    canvas.drawPath(tail, Paint()..color = _gold);

    // 2. Main bulb (radial gradient)
    final bulbGrad = Paint()
      ..shader = ui.Gradient.radial(
        const Offset(cx - bulbR * 0.25, bulbCy - bulbR * 0.25),
        bulbR * 1.2,
        [const Color(0xFFFFF0A0), _gold, const Color(0xFFB8900A)],
        [0.0, 0.5, 1.0],
      );
    canvas.drawCircle(const Offset(cx, bulbCy), bulbR, bulbGrad);

    // 3. Outer border ring
    canvas.drawCircle(
      const Offset(cx, bulbCy),
      bulbR,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..color = Colors.white.withValues(alpha: 0.40),
    );

    // 7. Transparent hole in bulb center
    canvas.drawCircle(
      const Offset(cx, bulbCy),
      bulbR * 0.52,
      Paint()..blendMode = BlendMode.clear,
    );

    final pic = recorder.endRecording();
    final img = await pic.toImage(w.toInt(), h.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }
}
