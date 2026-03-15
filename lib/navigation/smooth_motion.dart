import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Smoothly interpolates between raw GPS positions so the driver marker
/// doesn't jump. Uses **time-based** exponential decay so the animation is
/// frame-rate independent and buttery smooth at any refresh rate.
class SmoothMotion {
  SmoothMotion({
    required this.onTick,
    this.lerpFactor = 0.15,
    this.enablePrediction = true,
  });

  /// Called each frame with the interpolated position and bearing.
  final void Function(LatLng pos, double bearing) onTick;

  /// Base lerp speed (used as reference at 60 fps). Actual per-frame factor
  /// is adjusted by delta-time so the animation looks the same at any fps.
  final double lerpFactor;

  /// Whether to predict ahead slightly based on velocity.
  final bool enablePrediction;

  LatLng _current = const LatLng(0, 0);
  double _currentBearing = 0;
  LatLng _target = const LatLng(0, 0);
  double _targetBearing = 0;
  Duration _lastElapsed = Duration.zero;

  Ticker? _ticker;

  /// Start the animation loop. Requires a [TickerProvider] (e.g. from a State
  /// that uses `TickerProviderStateMixin`).
  void start(TickerProvider vsync) {
    _ticker?.dispose();
    _lastElapsed = Duration.zero;
    _ticker = vsync.createTicker(_onFrame);
    _ticker!.start();
  }

  /// Immediately set position without interpolation.
  void teleport(LatLng pos, double bearing) {
    _current = pos;
    _target = pos;
    _currentBearing = bearing;
    _targetBearing = bearing;
  }

  /// Push a new target position + bearing from a raw GPS reading.
  void pushTarget(LatLng pos, double bearing) {
    _target = pos;
    _targetBearing = bearing;
  }

  void _onFrame(Duration elapsed) {
    // Compute delta-time in seconds (clamped to avoid huge jumps on resume)
    final dtMs = (elapsed - _lastElapsed).inMilliseconds.clamp(1, 100);
    _lastElapsed = elapsed;
    final dt = dtMs / 1000.0;

    // Time-based exponential decay: factor = 1 - (1 - base)^(dt * 60)
    // At 60 fps (dt≈0.0167) this gives exactly `lerpFactor` per frame.
    // At 30 fps (dt≈0.033) the factor is larger, keeping speed consistent.
    final posF = 1.0 - math.pow(1.0 - lerpFactor, dt * 60);
    // Bearing uses a higher factor for snappier turns
    final brgF = 1.0 - math.pow(1.0 - (lerpFactor * 2.0).clamp(0.0, 0.95), dt * 60);

    // Lerp position
    _current = LatLng(
      _lerpD(_current.latitude, _target.latitude, posF),
      _lerpD(_current.longitude, _target.longitude, posF),
    );

    // Lerp bearing (shortest-arc)
    _currentBearing = _lerpAngle(_currentBearing, _targetBearing, brgF);

    onTick(_current, _currentBearing);
  }

  void dispose() {
    _ticker?.stop();
    _ticker?.dispose();
    _ticker = null;
  }

  /// Compute initial bearing from [from] to [to] in degrees.
  static double computeBearing(LatLng from, LatLng to) {
    final dLng = _r(to.longitude - from.longitude);
    final y = math.sin(dLng) * math.cos(_r(to.latitude));
    final x = math.cos(_r(from.latitude)) * math.sin(_r(to.latitude)) -
        math.sin(_r(from.latitude)) * math.cos(_r(to.latitude)) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  // ── Helpers ──

  static double _lerpD(double a, double b, double t) => a + (b - a) * t;

  static double _lerpAngle(double a, double b, double t) {
    double diff = (b - a) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return (a + diff * t) % 360;
  }

  static double _r(double d) => d * math.pi / 180;
}
