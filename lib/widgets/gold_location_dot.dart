import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Minimalist animated gold location dot for Mapbox map screens.
///
/// Design: flat 2D gold core + white ring + single expanding pulse ring
/// with a 3D fade shadow underneath. Clean, premium, one animation only.
class GoldLocationDot {
  static const Color _gold = Color(0xFFE8C547);
  // Single pulse: 20 frames at 70ms → ~1.4s cycle
  static const int _frameCount = 20;
  static const double _canvasSize = 160.0;

  // Core dimensions
  static const double _coreR    = 14.0; // gold filled circle
  static const double _ringR    = 20.0; // white outer ring radius

  // Pulse ring: expands from _ringR to _pulseMaxR, fades out
  static const double _pulseMaxR = 52.0;

  List<Uint8List> _frames = [];
  int _frame = 0;
  Timer? _timer;

  bool get isReady => _frames.isNotEmpty;

  Uint8List? get currentBytes => _frames.isEmpty ? null : _frames[_frame];

  Future<void> build(VoidCallback onTick) async {
    final frames = <Uint8List>[];

    for (int i = 0; i < _frameCount; i++) {
      final t = i / _frameCount; // 0 → 1

      // Single pulse ring: expand + fade
      final pulseR = _ringR + (_pulseMaxR - _ringR) * t;
      final pulseAlpha = (1.0 - t) * 0.50;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, _canvasSize, _canvasSize),
      );
      const center = Offset(_canvasSize / 2, _canvasSize / 2);

      // ── 3D fade shadow — soft ellipse below the pin ──
      canvas.drawOval(
        Rect.fromCenter(
          center: center.translate(0, _ringR + 6),
          width: _ringR * 2.6,
          height: _ringR * 0.7,
        ),
        Paint()
          ..color = const Color(0xCC000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );

      // ── Single expanding pulse ring ──
      canvas.drawCircle(
        center,
        pulseR,
        Paint()
          ..color = _gold.withValues(alpha: pulseAlpha * 0.18)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        pulseR,
        Paint()
          ..color = _gold.withValues(alpha: pulseAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.8,
      );

      // ── White outer ring (static) ──
      canvas.drawCircle(
        center,
        _ringR,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.fill,
      );

      // ── Flat 2D gold core ──
      canvas.drawCircle(
        center,
        _coreR,
        Paint()..color = _gold,
      );

      final img = await recorder
          .endRecording()
          .toImage(_canvasSize.toInt(), _canvasSize.toInt());
      final data = await img.toByteData(format: ui.ImageByteFormat.png);
      if (data == null) return;
      frames.add(data.buffer.asUint8List());
    }

    if (frames.length != _frameCount) return;
    _frames = frames;

    // 70ms per frame → ~1.4s per full pulse cycle
    _timer = Timer.periodic(const Duration(milliseconds: 70), (_) {
      _frame = (_frame + 1) % _frames.length;
      onTick();
    });
  }

  void dispose() {
    _timer?.cancel();
  }
}
