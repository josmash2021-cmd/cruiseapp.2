import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Shared animated gold location dot for Mapbox map screens.
///
/// Usage:
///   1. Create and build in initState:
///        _goldDot = GoldLocationDot();
///        _goldDot.build(() { if (mounted) setState(() {}); });
///   2. Dispose in dispose():
///        _goldDot.dispose();
///   3. Use currentBytes to get the current animation frame PNG bytes
///      and update a PointAnnotation on the Mapbox map.
class GoldLocationDot {
  static const Color _gold = Color(0xFFE8C547);
  static const int _frameCount = 24;
  static const double _canvasSize = 200.0;

  List<Uint8List> _frames = [];
  int _frame = 0;
  Timer? _timer;

  bool get isReady => _frames.isNotEmpty;

  /// Current animation frame as PNG bytes, or null if not ready.
  Uint8List? get currentBytes => _frames.isEmpty ? null : _frames[_frame];

  /// Pre-render all animation frames then start the pulse timer.
  Future<void> build(VoidCallback onTick) async {
    final frames = <Uint8List>[];

    for (int i = 0; i < _frameCount; i++) {
      // t goes 0→1 over one full cycle
      final t = i / _frameCount;
      // Two rings offset by half a cycle for continuous wave effect
      final t2 = (t + 0.5) % 1.0;

      // Ring 1: starts small, grows to edge, fades out
      final ring1Radius = 28.0 + 60.0 * t;
      final ring1Alpha  = (1.0 - t) * 0.55;

      // Ring 2: same but phase-shifted
      final ring2Radius = 28.0 + 60.0 * t2;
      final ring2Alpha  = (1.0 - t2) * 0.55;

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, _canvasSize, _canvasSize),
      );
      const center = Offset(_canvasSize / 2, _canvasSize / 2);

      // ── Drop shadow (3D) ──
      canvas.drawCircle(
        center.translate(0, 6),
        34,
        Paint()
          ..color = const Color(0x80000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
      );
      // ── Secondary shadow (depth) ──
      canvas.drawCircle(
        center.translate(0, 3),
        30,
        Paint()
          ..color = const Color(0x40000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
      );

      // ── Pulse ring 1 (white, expanding) ──
      canvas.drawCircle(
        center,
        ring1Radius,
        Paint()
          ..color = Colors.white.withValues(alpha: ring1Alpha * 0.25)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        ring1Radius,
        Paint()
          ..color = Colors.white.withValues(alpha: ring1Alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );

      // ── Pulse ring 2 (white, offset phase) ──
      canvas.drawCircle(
        center,
        ring2Radius,
        Paint()
          ..color = Colors.white.withValues(alpha: ring2Alpha * 0.20)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        ring2Radius,
        Paint()
          ..color = Colors.white.withValues(alpha: ring2Alpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.5,
      );

      // ── White outer ring (static halo around gold core) ──
      canvas.drawCircle(
        center,
        28,
        Paint()..color = Colors.white,
      );

      // ── Gold core circle ──
      canvas.drawCircle(
        center,
        20,
        Paint()
          ..shader = ui.Gradient.radial(
            center.translate(-4, -4),
            24,
            [const Color(0xFFF5E27A), _gold, const Color(0xFFB8941E)],
            [0.0, 0.55, 1.0],
          ),
      );

      // ── Specular highlight (3D feel) ──
      canvas.drawCircle(
        center.translate(-5, -5),
        8,
        Paint()..color = const Color(0x66FFFFFF),
      );
      // ── Secondary specular (lower) ──
      canvas.drawCircle(
        center.translate(-2, -2),
        4,
        Paint()..color = const Color(0x33FFFFFF),
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

    // ~60ms per frame → ~1.4s per full pulse cycle, smooth and fluid
    _timer = Timer.periodic(const Duration(milliseconds: 58), (_) {
      _frame = (_frame + 1) % _frames.length;
      onTick();
    });
  }

  void dispose() {
    _timer?.cancel();
  }
}
