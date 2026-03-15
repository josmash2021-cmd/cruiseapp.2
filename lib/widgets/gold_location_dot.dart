import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Shared animated gold location dot that replaces the default blue dot
/// on all map screens (rider + driver).
///
/// Usage:
///   1. Create an instance in your State's initState:
///        _goldDot = GoldLocationDot();
///        _goldDot.build(() { if (mounted) setState(() {}); });
///   2. Dispose in dispose():
///        _goldDot.dispose();
///   3. Add marker in GoogleMap markers set:
///        if (_goldDot.marker(position) != null) _goldDot.marker(position)!
///   4. Set myLocationEnabled: false on GoogleMap.
class GoldLocationDot {
  static const Color _gold = Color(0xFFE8C547);
  static const int _frameCount = 12;
  static const double _canvasSize = 140.0;

  List<BitmapDescriptor> _frames = [];
  int _frame = 0;
  Timer? _timer;

  bool get isReady => _frames.isNotEmpty;

  /// Pre-render all animation frames then start the pulse timer.
  Future<void> build(VoidCallback onTick) async {
    final frames = <BitmapDescriptor>[];

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
      // ignore: deprecated_member_use
      frames.add(BitmapDescriptor.fromBytes(data.buffer.asUint8List()));
    }

    if (frames.length != _frameCount) return;
    _frames = frames;

    _timer = Timer.periodic(const Duration(milliseconds: 130), (_) {
      _frame = (_frame + 1) % _frames.length;
      onTick();
    });
  }

  /// Returns a Marker for the gold dot at [position], or null if not ready.
  Marker? marker(LatLng position) {
    if (_frames.isEmpty) return null;
    return Marker(
      markerId: const MarkerId('my_location_gold'),
      position: position,
      icon: _frames[_frame],
      anchor: const Offset(0.5, 0.5),
      flat: true,
      zIndexInt: 1,
    );
  }

  void dispose() {
    _timer?.cancel();
  }
}
