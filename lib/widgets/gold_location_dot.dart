import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Animated gold location dot for Mapbox map screens.
///
/// Design: 3-layer pulsing glow — outer expanding ring, static inner halo,
/// solid core with subtle brightness pulse. Calm, elegant heartbeat of light.
/// 2.5 s per full cycle using a sin-based ease curve.
class GoldLocationDot {
  static const Color _gold = Color(0xFFE8C547);
  // 25 frames × 100 ms = 2 500 ms (2.5 s) per cycle
  static const int _frameCount = 25;
  static const double _canvasSize = 160.0;

  // Core dot radius — all other layers are relative to this
  static const double _dotR = 18.0;

  List<Uint8List> _frames = [];
  int _frame = 0;
  Timer? _timer;

  bool get isReady => _frames.isNotEmpty;

  Uint8List? get currentBytes => _frames.isEmpty ? null : _frames[_frame];

  Future<void> build(VoidCallback onTick) async {
    final frames = <Uint8List>[];

    for (int i = 0; i < _frameCount; i++) {
      final t = i / _frameCount; // 0 → 1
      // Smooth sin curve: 0.0 → 1.0 → 0.0
      final pulse = (math.sin(t * 2 * math.pi) + 1) / 2;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, _canvasSize, _canvasSize),
      );
      const center = Offset(_canvasSize / 2, _canvasSize / 2);

      // ── Layer 1: Outer pulse ring (expanding + fading) ──
      final outerR = _dotR * (1.0 + 0.8 * pulse);
      final outerAlpha = 0.4 * (1.0 - pulse);
      canvas.drawCircle(
        center,
        outerR,
        Paint()
          ..color = Colors.white.withValues(alpha: outerAlpha)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );

      // ── Layer 2: Static inner glow ──
      canvas.drawCircle(
        center,
        _dotR * 1.3,
        Paint()
          ..color = Colors.white.withValues(alpha: 0.15)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
      );

      // ── Layer 3: White border ring ──
      canvas.drawCircle(
        center,
        _dotR,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );

      // ── Layer 4: Gold center fill (subtle brightness pulse) ──
      final dotAlpha = 0.85 + 0.15 * (1.0 - pulse);
      canvas.drawCircle(
        center,
        _dotR - 1.5,
        Paint()..color = _gold.withValues(alpha: dotAlpha),
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

    // 100 ms per frame → 2.5 s per full pulse cycle
    _timer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      _frame = (_frame + 1) % _frames.length;
      onTick();
    });
  }

  void dispose() {
    _timer?.cancel();
  }
}
