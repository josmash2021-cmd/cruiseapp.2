import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import '../models/lat_lng.dart';

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

  /// Minimum movement in degrees (lat or lng) before we accept a new bearing.
  /// ~2e-5° ≈ 2.2 metres. Prevents bearing flips from GPS noise when stopped.
  static const double _minMoveDeg = 2e-5;


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

  /// Push a new target position + bearing from a route-snapped GPS reading.
  ///
  /// Bearing is only accepted when the vehicle has moved at least [_minMoveDeg]
  /// degrees (≈ 2 m). Below that threshold the vehicle is considered at rest
  /// and we keep the last known heading to prevent jitter flips.
  ///
  /// Because [bearing] always comes from the route polyline segment (not raw
  /// GPS heading), it is always trusted — no large-jump clamping is needed.
  void pushTarget(LatLng pos, double bearing) {
    final dLat = (pos.latitude - _target.latitude).abs();
    final dLng = (pos.longitude - _target.longitude).abs();
    _target = pos;
    if (dLat > _minMoveDeg || dLng > _minMoveDeg) {
      _targetBearing = bearing;
    }
    // Below threshold: position updated but bearing held → car keeps its
    // last direction while creeping / stopped at a light.
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
