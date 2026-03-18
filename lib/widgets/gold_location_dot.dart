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
  static const double _canvasSize = 140.0;

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
      final t = i / _frameCount;
      final pulseRadius = 40.0 + 20.0 * t;
      final pulseAlpha = (0.35 * (1.0 - t)).clamp(0.0, 1.0);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, _canvasSize, _canvasSize),
      );
      const center = Offset(_canvasSize / 2, _canvasSize / 2);

      // 3D shadow beneath dot
      canvas.drawCircle(
        center.translate(0, 4),
        22,
        Paint()
          ..color = const Color(0x50000000)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
      );

      // Outer pulse ring (fading gold)
      canvas.drawCircle(
        center,
        pulseRadius,
        Paint()
          ..color = _gold.withValues(alpha: pulseAlpha * 0.4)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        pulseRadius,
        Paint()
          ..color = _gold.withValues(alpha: pulseAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5,
      );

      // Gold outer ring (3D gradient)
      canvas.drawCircle(
        center,
        18,
        Paint()
          ..shader = ui.Gradient.radial(
            center.translate(-4, -4),
            22,
            [const Color(0xFFF5E27A), _gold, const Color(0xFFB8941E)],
            [0.0, 0.5, 1.0],
          ),
      );

      // White inner dot
      canvas.drawCircle(center, 9, Paint()..color = Colors.white);

      // Specular highlight for 3D look
      canvas.drawCircle(
        center.translate(-3, -3),
        5,
        Paint()..color = const Color(0x40FFFFFF),
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

    _timer = Timer.periodic(const Duration(milliseconds: 65), (_) {
      _frame = (_frame + 1) % _frames.length;
      onTick();
    });
  }

  void dispose() {
    _timer?.cancel();
  }
}
