import 'dart:math' as math;

/// Google Maps-style constant-velocity motion smoother.
///
/// Usage: call [setTarget] on every GPS fix. Call [tick] every frame from a
/// Ticker/Timer (pass the elapsed seconds since last tick). Read [lat],
/// [lng], [bearing] to render the annotation / marker.
///
/// The smoother tracks velocity from position deltas between GPS fixes, then
/// advances the rendered position forward at that measured velocity on every
/// tick. A gentle proportional correction pulls toward the latest target so
/// GPS jitter and car turns are absorbed without overshoot.
///
/// This produces the steady gliding motion of Google Maps — no "catch up
/// then stall" feel of exponential decay.
class SmoothMotion {
  // Current rendered position (null = no GPS yet).
  double? _lat;
  double? _lng;
  double _bearing = 0;

  // Latest GPS target.
  double? _targetLat;
  double? _targetLng;
  double _targetBearing = 0;

  // Velocity in degrees/second (treated as locally linear — safe over the
  // short horizons involved in GPS smoothing).
  double _vLat = 0;
  double _vLng = 0;

  DateTime? _lastTargetAt;

  /// How much of the remaining angular gap to close per second when applying
  /// the low-pass filter on bearing. Higher = more responsive turns.
  static const double _bearingLerpPerSec = 2.5;

  /// How much of the residual lat/lng gap to close per second via
  /// proportional correction. Higher = more responsive, follows GPS closer.
  /// Lowered from 1.8 → 1.2 for silkier gliding — less visible snap to raw GPS.
  static const double _correctionPerSec = 1.2;

  /// Freeze velocity after this many seconds without a fresh GPS fix.
  /// 3.5 s allows the dot to keep gliding through brief urban GPS shadows
  /// (tunnels, buildings) without stalling, while still freezing if GPS
  /// is truly lost.
  static const double _maxExtrapolationSec = 3.5;

  double? get lat => _lat;
  double? get lng => _lng;
  double get bearing => _bearing;
  bool get hasPosition => _lat != null;

  /// Provide a new GPS target. Measures velocity from the delta to the
  /// previous target. [bearing] is optional (degrees, 0 = north).
  void setTarget(double lat, double lng, {double? bearing}) {
    if (bearing != null && !bearing.isNaN && !bearing.isInfinite) {
      _targetBearing = bearing;
    }

    final now = DateTime.now();
    if (_targetLat != null && _lastTargetAt != null) {
      final dtSec =
          now.difference(_lastTargetAt!).inMilliseconds / 1000.0;
      if (dtSec > 0.05 && dtSec < 10.0) {
        final newVLat = (lat - _targetLat!) / dtSec;
        final newVLng = (lng - _targetLng!) / dtSec;
        // Exponential average — absorbs GPS jitter without overfitting.
        _vLat = _vLat * 0.3 + newVLat * 0.7;
        _vLng = _vLng * 0.3 + newVLng * 0.7;
      }
    }
    _lastTargetAt = now;
    _targetLat = lat;
    _targetLng = lng;

    // First fix — snap immediately so the marker doesn't slide from (0,0).
    if (_lat == null) {
      _lat = lat;
      _lng = lng;
      _bearing = _targetBearing;
    }
  }

  /// Advance the rendered position by [dtSec] seconds. Returns true if the
  /// position or bearing changed noticeably — caller can skip redraws when
  /// false.
  bool tick(double dtSec) {
    if (_lat == null || _targetLat == null) return false;
    if (dtSec <= 0) return false;
    // Clamp huge frame gaps (e.g., app coming back from background) so we
    // never teleport the marker across several seconds in one step.
    if (dtSec > 0.2) dtSec = 0.2;

    // Freeze velocity if the last GPS fix is stale — avoids extrapolating
    // the marker off into nowhere when the driver phone silently drops GPS.
    double vLat = _vLat;
    double vLng = _vLng;
    if (_lastTargetAt != null) {
      final staleSec =
          DateTime.now().difference(_lastTargetAt!).inMilliseconds / 1000.0;
      if (staleSec > _maxExtrapolationSec) {
        vLat = 0;
        vLng = 0;
      }
    }

    // Constant-velocity advance.
    double stepLat = vLat * dtSec;
    double stepLng = vLng * dtSec;

    // Gentle proportional correction — handles measurement noise, sudden
    // turns, and GPS jumps without a visible snap.
    final residualLat = _targetLat! - _lat!;
    final residualLng = _targetLng! - _lng!;
    final corrFactor =
        1.0 - math.pow(1.0 - _correctionPerSec, dtSec).toDouble();
    stepLat += residualLat * corrFactor;
    stepLng += residualLng * corrFactor;

    // Never overshoot past the target on either axis.
    if (residualLat > 0) {
      if (stepLat > residualLat) stepLat = residualLat;
      if (stepLat < 0) stepLat = 0;
    } else if (residualLat < 0) {
      if (stepLat < residualLat) stepLat = residualLat;
      if (stepLat > 0) stepLat = 0;
    }
    if (residualLng > 0) {
      if (stepLng > residualLng) stepLng = residualLng;
      if (stepLng < 0) stepLng = 0;
    } else if (residualLng < 0) {
      if (stepLng < residualLng) stepLng = residualLng;
      if (stepLng > 0) stepLng = 0;
    }

    final newLat = _lat! + stepLat;
    final newLng = _lng! + stepLng;
    final movedPos =
        (newLat - _lat!).abs() > 1e-9 || (newLng - _lng!).abs() > 1e-9;
    _lat = newLat;
    _lng = newLng;

    // Bearing low-pass (shortest arc).
    double dBrg = _targetBearing - _bearing;
    while (dBrg > 180) {
      dBrg -= 360;
    }
    while (dBrg < -180) {
      dBrg += 360;
    }
    final brgFactor =
        1.0 - math.pow(1.0 - _bearingLerpPerSec, dtSec).toDouble();
    final newBearing = (_bearing + dBrg * brgFactor) % 360;
    final movedBrg = (newBearing - _bearing).abs() > 0.05;
    _bearing = newBearing < 0 ? newBearing + 360 : newBearing;

    return movedPos || movedBrg;
  }

  /// True when the smoother is close enough to the target that the caller
  /// can park its ticker to save CPU.
  bool get isAtTarget {
    if (_lat == null || _targetLat == null) return true;
    final latGap = (_targetLat! - _lat!).abs();
    final lngGap = (_targetLng! - _lng!).abs();
    // ~1 cm resolution.
    return latGap < 1e-7 && lngGap < 1e-7;
  }

  /// Force-set position (e.g., resuming from background, camera recenter).
  /// Velocity is zeroed so the next [tick] doesn't drift.
  void snapTo(double lat, double lng, {double? bearing}) {
    _lat = lat;
    _lng = lng;
    _targetLat = lat;
    _targetLng = lng;
    if (bearing != null) {
      _bearing = bearing;
      _targetBearing = bearing;
    }
    _vLat = 0;
    _vLng = 0;
    _lastTargetAt = DateTime.now();
  }

  /// Reset to an uninitialised state (driver went offline, trip cancelled).
  void reset() {
    _lat = null;
    _lng = null;
    _targetLat = null;
    _targetLng = null;
    _vLat = 0;
    _vLng = 0;
    _bearing = 0;
    _targetBearing = 0;
    _lastTargetAt = null;
  }
}
