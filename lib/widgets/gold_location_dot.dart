import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Animated gold location dot for Mapbox map screens.
///
/// Design: 3-layer pulsing glow — outer expanding ring, static inner halo,
/// solid core with subtle brightness pulse. Calm, elegant heartbeat of light.
/// 3 s per full cycle using a sin-based ease curve.
///
/// Position interpolation: call [setTarget] with each GPS update.
/// The dot lerps toward the target every tick for buttery-smooth movement
/// like water — no jumps, no steps.
class GoldLocationDot {
  static const Color _gold = Color(0xFFE8C547);
  // 90 frames × 33 ms ≈ 3 000 ms (3 s) per cycle — smooth 30 fps animation
  // Position lerp runs at 60fps (16ms) for buttery movement
  static const int _frameCount = 90;
  static const double _canvasSize = 160.0;

  // Core dot radius — all other layers are relative to this
  static const double _dotR = 18.0;

  List<Uint8List> _frames = [];
  int _frame = 0;
  Timer? _timer;       // 16ms position lerp (60fps)
  int _tickCount = 0;  // counts 16ms ticks to advance animation frame every 2nd tick

  // ── Position interpolation ──
  double? _currentLat;
  double? _currentLng;
  double? _targetLat;
  double? _targetLng;
  // Velocity tracking for prediction
  double _velLat = 0;
  double _velLng = 0;

  /// Interpolated position (lat, lng) — use this to place the annotation.
  double? get lat => _currentLat;
  double? get lng => _currentLng;

  bool get isReady => _frames.isNotEmpty;

  Uint8List? get currentBytes => _frames.isEmpty ? null : _frames[_frame];

  /// Set the GPS target position. The dot will smoothly lerp toward it.
  void setTarget(double lat, double lng) {
    // Track velocity for smooth prediction
    if (_targetLat != null) {
      _velLat = lat - _targetLat!;
      _velLng = lng - _targetLng!;
    }
    _targetLat = lat;
    _targetLng = lng;
    // First position — snap immediately, no lerp
    if (_currentLat == null) {
      _currentLat = lat;
      _currentLng = lng;
    }
  }

  /// Advance interpolated position toward target with velocity smoothing.
  void _lerpPosition() {
    if (_currentLat == null || _targetLat == null) return;
    // 0.14 at 16ms tick ≈ same responsiveness as 0.25 at 40ms, but 2.5× smoother
    const f = 0.14;
    final dLat = _targetLat! - _currentLat!;
    final dLng = _targetLng! - _currentLng!;

    // Velocity prediction — look 20% ahead for buttery-smooth anticipation
    final predLat = _targetLat! + _velLat * 0.20;
    final predLng = _targetLng! + _velLng * 0.20;

    _currentLat = _currentLat! + (predLat - _currentLat!) * f;
    _currentLng = _currentLng! + (predLng - _currentLng!) * f;

    // Slower decay at 60fps so prediction sustains between GPS updates
    _velLat *= 0.96;
    _velLng *= 0.96;

    // Snap when close enough to avoid perpetual micro-lerping
    if (dLat.abs() < 0.0000003 && dLng.abs() < 0.0000003) {
      _currentLat = _targetLat;
      _currentLng = _targetLng;
    }
  }

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

    // 16ms tick — 60fps position lerp, animation frame advances every 2nd tick (~33ms ≈ 30fps visual)
    _tickCount = 0;
    _timer = Timer.periodic(const Duration(milliseconds: 16), (_) {
      _lerpPosition();
      _tickCount++;
      if (_tickCount % 2 == 0) {
        _frame = (_frame + 1) % _frames.length;
      }
      onTick();
    });
  }

  void dispose() {
    _timer?.cancel();
  }
}
