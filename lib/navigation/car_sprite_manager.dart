import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Pre-renders 36 car sprites (one per 10 degrees) at startup using Canvas.
/// Call [CarSpriteManager.init()] once before using [iconForBearing].
class CarSpriteManager {
  CarSpriteManager._();

  static const int _frames = 36;
  static const int _tileW = 44;
  static const int _tileH = 66;

  static final List<BitmapDescriptor> _icons = [];
  static bool _ready = false;

  static bool get isReady => _ready;

  /// Must be called once before any GPS updates (e.g., in initState).
  static Future<void> init() async {
    if (_ready) return;
    _icons.clear();
    for (int i = 0; i < _frames; i++) {
      final bearing = i * (360.0 / _frames); // 0, 10, 20 ... 350
      final icon = await _renderFrame(bearing);
      _icons.add(icon);
    }
    _ready = true;
  }

  /// Returns the sprite closest to [bearingDeg] (snapped to nearest 10 deg).
  static BitmapDescriptor iconForBearing(double bearingDeg) {
    if (!_ready || _icons.isEmpty) return BitmapDescriptor.defaultMarker;
    final idx = ((bearingDeg % 360) / (360.0 / _frames)).round() % _frames;
    return _icons[idx];
  }

  static Future<BitmapDescriptor> _renderFrame(double bearing) async {
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(
        recorder,
        Rect.fromLTWH(0, 0, _tileW.toDouble(), _tileH.toDouble()));

    _drawCar(canvas, bearing);

    final picture = recorder.endRecording();
    final img = await picture.toImage(_tileW, _tileH);
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    final list = Uint8List.view(bytes!.buffer);
    return BitmapDescriptor.fromBytes(list);
  }

  static void _drawCar(ui.Canvas canvas, double bearing) {
    final cx = _tileW / 2.0;
    final cy = _tileH / 2.0;

    canvas.save();
    canvas.translate(cx, cy);
    canvas.rotate(bearing * math.pi / 180);
    canvas.translate(-cx, -cy);

    // Shadow
    final shadowPaint = Paint()
      ..color = const Color(0x44000000)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 12, cy - 18, 24, 38), const Radius.circular(6)),
      shadowPaint,
    );

    // Body
    final bodyPaint = Paint()..color = const Color(0xFF1E3A5F);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 10, cy - 19, 20, 37), const Radius.circular(5)),
      bodyPaint,
    );

    // Roof / cabin
    final roofPaint = Paint()..color = const Color(0xFF2A5080);
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          Rect.fromLTWH(cx - 7, cy - 13, 14, 20), const Radius.circular(4)),
      roofPaint,
    );

    // Front windshield
    final glassPaint = Paint()..color = const Color(0x99C8E8FF);
    final frontPath = Path()
      ..moveTo(cx - 6, cy - 13)
      ..lineTo(cx + 6, cy - 13)
      ..lineTo(cx + 5, cy - 19)
      ..lineTo(cx - 5, cy - 19)
      ..close();
    canvas.drawPath(frontPath, glassPaint);

    // Rear windshield
    final rearPath = Path()
      ..moveTo(cx - 6, cy + 7)
      ..lineTo(cx + 6, cy + 7)
      ..lineTo(cx + 5, cy + 12)
      ..lineTo(cx - 5, cy + 12)
      ..close();
    canvas.drawPath(rearPath, Paint()..color = const Color(0x7070A8D0));

    // Headlights
    final hlPaint = Paint()..color = const Color(0xFFFFFF99);
    canvas.drawOval(
        Rect.fromCenter(center: Offset(cx - 6, cy - 18.5), width: 5, height: 3),
        hlPaint);
    canvas.drawOval(
        Rect.fromCenter(center: Offset(cx + 6, cy - 18.5), width: 5, height: 3),
        hlPaint);

    // Tail lights
    final tlPaint = Paint()..color = const Color(0xFFFF3322);
    canvas.drawOval(
        Rect.fromCenter(center: Offset(cx - 7, cy + 17), width: 5, height: 3),
        tlPaint);
    canvas.drawOval(
        Rect.fromCenter(center: Offset(cx + 7, cy + 17), width: 5, height: 3),
        tlPaint);

    // Wheels
    final wheelPaint = Paint()..color = const Color(0xFF111111);
    for (final pt in [
      Offset(cx - 11, cy - 10),
      Offset(cx + 11, cy - 10),
      Offset(cx - 11, cy + 8),
      Offset(cx + 11, cy + 8),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
            Rect.fromCenter(center: pt, width: 5, height: 9),
            const Radius.circular(2)),
        wheelPaint,
      );
    }

    canvas.restore();
  }
}
