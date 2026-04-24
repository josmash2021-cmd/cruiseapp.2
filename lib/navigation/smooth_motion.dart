import 'dart:math' as math;
import 'package:flutter/scheduler.dart';
import '../models/lat_lng.dart';

/// DEPRECATED — legacy exponential-decay smoother kept only for
/// [map_screen.dart] and [driver_nav_screen.dart] which still use the
/// old `onTick`-driven API. New code MUST use [SmoothMotion] from
/// `lib/utils/smooth_motion.dart` (constant-velocity, no decay). See
/// CLAUDE.md rule #13.
class LegacySmoothMotion {
  LegacySmoothMotion({
    required this.onTick,
    this.lerpFactor = 0.22,          // higher = snappier catch-up
    this.enablePrediction = true,
  });

  /// Called each frame with the interpolated position, bearing, and curve tilt.
  /// [curveTilt] ranges from -1.0 (hard left) to 1.0 (hard right).
  final void Function(LatLng pos, double bearing, double curveTilt) onTick;

  /// Base lerp speed (used as reference at 60 fps). Actual per-frame factor
  /// is adjusted by delta-time so the animation looks the same at any fps.
  final double lerpFactor;

  /// Whether to predict ahead slightly based on velocity.
  final bool enablePrediction;

  LatLng _current = const LatLng(0, 0);
  double _currentBearing = 0;
  LatLng _target = const LatLng(0, 0);
  double _targetBearing = 0;

  // -- Velocity prediction --
  /// Smoothed velocity in degrees/second, derived from successive pushTarget calls.
  LatLng _velocity = const LatLng(0, 0);
  DateTime? _lastPushTime;

  // -- Physics state for tilt --
  double _currentCurveTilt = 0;
  double _lastBearingVelocity = 0;

  Duration _lastElapsed = Duration.zero;

  /// Minimum movement in degrees (lat or lng) before we accept a new bearing.
  /// ~2e-5° ≈ 2.2 metres. Prevents bearing flips from GPS noise when stopped.
  static const double _minMoveDeg = 2e-5;

  /// How many seconds ahead to predict. 200 ms compensates typical GPS→render lag.
  static const double _predictionSec = 0.20;


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
    final now = DateTime.now();

    final dLat = (pos.latitude  - _target.latitude).abs();
    final dLng = (pos.longitude - _target.longitude).abs();

    // Compute smoothed velocity from successive pushTarget calls so the
    // prediction step can project slightly ahead of the GPS target.
    if (_lastPushTime != null) {
      final dtSec = now.difference(_lastPushTime!).inMicroseconds / 1e6;
      if (dtSec > 0 && dtSec < 2.0) {
        final rawVLat = (pos.latitude  - _target.latitude)  / dtSec;
        final rawVLng = (pos.longitude - _target.longitude) / dtSec;
        // Light smoothing (α=0.35) so noise doesn't corrupt prediction.
        _velocity = LatLng(
          _lerpD(_velocity.latitude,  rawVLat, 0.35),
          _lerpD(_velocity.longitude, rawVLng, 0.35),
        );
      }
    }
    _lastPushTime = now;

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

    // Predictive target: project velocity _predictionSec ahead to pre-compensate
    // the GPS→animation pipeline latency (~150-250 ms on device).
    final LatLng lerpTarget = enablePrediction
        ? LatLng(
            _target.latitude  + _velocity.latitude  * _predictionSec,
            _target.longitude + _velocity.longitude * _predictionSec,
          )
        : _target;

    // Lerp position
    _current = LatLng(
      _lerpD(_current.latitude,  lerpTarget.latitude,  posF),
      _lerpD(_current.longitude, lerpTarget.longitude, posF),
    );

    // Lerp bearing (shortest-arc)
    final prevBearing = _currentBearing;
    _currentBearing = _lerpAngle(_currentBearing, _targetBearing, brgF);

    // Compute angular velocity (degrees per second)
    double bDiff = (_currentBearing - prevBearing) % 360;
    if (bDiff > 180) bDiff -= 360;
    if (bDiff < -180) bDiff += 360;
    
    final bearingVel = bDiff / dt; // deg/sec
    // Smooth the velocity to prevent twitching
    _lastBearingVelocity = _lerpD(_lastBearingVelocity, bearingVel, 0.15);

    // Convert to a tilt factor (-1.0 to 1.0)
    // 45 degrees per second is considered a "hard turn"
    double targetTilt = (_lastBearingVelocity / 45.0).clamp(-1.0, 1.0);
    
    // Smooth the physical tilt
    _currentCurveTilt = _lerpD(_currentCurveTilt, targetTilt, 0.1);

    onTick(_current, _currentBearing, _currentCurveTilt);
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
