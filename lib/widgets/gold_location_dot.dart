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
  // Velocity tracking — degrees per second (not displacement)
  DateTime? _lastTargetTime;
  double _velLatSec = 0;
  double _velLngSec = 0;

  /// Interpolated position (lat, lng) — use this to place the annotation.
  double? get lat => _currentLat;
  double? get lng => _currentLng;

  bool get isReady => _frames.isNotEmpty;

  Uint8List? get currentBytes => _frames.isEmpty ? null : _frames[_frame];

  /// Set the GPS target position. The dot will smoothly glide toward it
  /// at constant velocity — no jumps, no stalls.
  void setTarget(double lat, double lng) {
    final now = DateTime.now();
    if (_targetLat != null && _lastTargetTime != null) {
      final dtSec = now.difference(_lastTargetTime!).inMilliseconds / 1000.0;
      if (dtSec > 0.05 && dtSec < 10.0) {
        final newVLat = (lat - _targetLat!) / dtSec;
        final newVLng = (lng - _targetLng!) / dtSec;
        // Smooth exponential average to avoid velocity spikes
        _velLatSec = _velLatSec * 0.3 + newVLat * 0.7;
        _velLngSec = _velLngSec * 0.3 + newVLng * 0.7;
      }
    }
    _lastTargetTime = now;
    _targetLat = lat;
    _targetLng = lng;
    // First position — snap immediately, no lerp
    if (_currentLat == null) {
      _currentLat = lat;
      _currentLng = lng;
    }
  }

  /// Advance position at CONSTANT VELOCITY toward target.
  /// No proportional lerp (which catches up in 200ms then stalls).
  /// The dot moves at measured speed every 16ms tick → glass-smooth.
  void _lerpPosition() {
    if (_currentLat == null || _targetLat == null) return;
    const dt = 0.016; // 16ms tick

    final dLat = _targetLat! - _currentLat!;
    final dLng = _targetLng! - _currentLng!;

    // Primary: constant-velocity advance (deg/sec × dt)
    final vStepLat = _velLatSec * dt;
    final vStepLng = _velLngSec * dt;

    // Fallback: ultra-gentle proportional correction (1.5% per tick)
    // so the dot glides at constant velocity and almost never
    // "catches up" visibly — just like Google Maps blue dot.
    final cStepLat = dLat * 0.015;
    final cStepLng = dLng * 0.015;

    // Move in correct direction — pick larger of velocity vs correction.
    // Clamp so we never overshoot past the target.
    double stepLat = 0, stepLng = 0;
    if (dLat.abs() > 0.0000003) {
      stepLat = dLat > 0
          ? math.max(vStepLat, cStepLat).clamp(0.0, dLat)
          : math.min(vStepLat, cStepLat).clamp(dLat, 0.0);
    }
    if (dLng.abs() > 0.0000003) {
      stepLng = dLng > 0
          ? math.max(vStepLng, cStepLng).clamp(0.0, dLng)
          : math.min(vStepLng, cStepLng).clamp(dLng, 0.0);
    }

    _currentLat = _currentLat! + stepLat;
    _currentLng = _currentLng! + stepLng;

    // Velocity decay: retain ~99.5% per second — sustains glide much
    // longer between GPS fixes so the dot never visibly stalls.
    final decay = math.pow(0.995, dt * 60);
    _velLatSec *= decay;
    _velLngSec *= decay;

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
