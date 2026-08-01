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

  /// The fraction of the remaining gap to close in [dtSec], for a filter that
  /// closes [ratePerSec] of it per second, at any frame rate.
  ///
  /// This used to be written `1 - pow(1 - ratePerSec, dtSec)`, which is only
  /// defined while the rate is below 1. Both rates above are over 1, so the
  /// base was negative — and Dart's `pow` returns NaN for a negative base
  /// raised to a fractional power, which every frame delta is. So the factor
  /// was NaN on every single tick.
  ///
  /// NaN does not announce itself. It multiplies into the step, adds into
  /// the position, and the overshoot clamps in [tick] wave it through because
  /// every comparison against NaN is false. Downstream, `safePoint` drops
  /// the annotation update and the overlay's `canvas.rotate(NaN)` draws
  /// nothing — which is the arrow that "disappears and comes back", and the
  /// dot that has to be nudged by watchdogs to move at all. The marker only
  /// ever looked alive because `snapTo` and first-fix seeding kept resetting
  /// it to a real number between ticks.
  ///
  /// `1 - exp(-rate * dt)` is the continuous form of the same idea and is
  /// defined for every positive rate. Clamped because a huge dt should mean
  /// "close all of it", never more.
  static double _lerpFactor(double ratePerSec, double dtSec) {
    final f = 1.0 - math.exp(-ratePerSec * dtSec);
    if (f.isNaN) return 0.0;
    return f < 0.0 ? 0.0 : (f > 1.0 ? 1.0 : f);
  }

  double? get lat => _lat;
  double? get lng => _lng;
  double get bearing => _bearing;
  bool get hasPosition => _lat != null;

  /// Provide a new GPS target. Measures velocity from the delta to the
  /// previous target. [bearing] is optional (degrees, 0 = north).
  void setTarget(double lat, double lng, {double? bearing}) {
    // The busiest entry point, and the one that was not checking.
    //
    // snapTo guards its input and setBearing guards its own, but this runs on
    // every GPS fix — and a fix with a NaN coordinate is not hypothetical:
    // iOS emits them while the location manager is warming up. One of those
    // set _targetLat to NaN, and on the first fix of a session that is copied
    // straight into the rendered position, from where it reaches the native
    // map. Dropping the fix costs one update out of the one per second the
    // platform sends.
    if (!lat.isFinite || !lng.isFinite) return;
    if (bearing != null) setBearing(bearing);

    final now = DateTime.now();
    if (_targetLat != null && _lastTargetAt != null) {
      final dtSec =
          now.difference(_lastTargetAt!).inMilliseconds / 1000.0;
      if (dtSec > 0.05 && dtSec < 10.0) {
        final dLat = lat - _targetLat!;
        final dLng = lng - _targetLng!;
        // Equirectangular meters — accurate enough at GPS-smoothing scales.
        final cosLat = math.cos(_targetLat! * math.pi / 180.0);
        final distM = math.sqrt(
          math.pow(dLng * 111320.0 * cosLat, 2) +
              math.pow(dLat * 110540.0, 2),
        );
        final impliedSpeed = distM / dtSec; // m/s

        // GPS teleport glitch (tunnel re-acquire, cell-tower hop): snap
        // directly instead of ingesting a 100+ m/s velocity estimate that
        // rockets the dot across the map.
        if (impliedSpeed > 60.0) {
          snapTo(lat, lng, bearing: bearing);
          return;
        }

        // Standstill jitter hold: while essentially parked, ignore small
        // position hops (typical GPS wander is 5–20 m). Without this the
        // velocity estimator ingests random jitter and the dot visibly
        // jumps around a stationary car.
        final curSpeedMps = math.sqrt(
          math.pow(_vLng * 111320.0 * cosLat, 2) +
              math.pow(_vLat * 110540.0, 2),
        );
        if (curSpeedMps < 1.2 && distM < 15.0) {
          // Bleed off residual velocity and refresh the timestamp so the
          // extrapolation freeze doesn't kick in — but keep the old target.
          _vLat *= 0.5;
          _vLng *= 0.5;
          _lastTargetAt = now;
          return;
        }

        final newVLat = dLat / dtSec;
        final newVLng = dLng / dtSec;
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

  /// Aim the marker at [bearing] without touching its position.
  ///
  /// The compass and the GPS run at different rates and answer different
  /// questions — where the phone is pointing versus where the car is going —
  /// so where the marker points is now fed separately from where it is. A
  /// parked driver turning the phone in their hand produces a stream of these
  /// and no position updates at all.
  ///
  /// [tick] still does the actual turning, at the same rate and through the
  /// same shortest-arc filter as a bearing that arrived with a fix.
  void setBearing(double bearing) {
    if (bearing.isNaN || bearing.isInfinite) return;
    _targetBearing = bearing % 360;
    if (_targetBearing < 0) _targetBearing += 360;
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
    final corrFactor = _lerpFactor(_correctionPerSec, dtSec);
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

    // Nothing non-finite leaves this class.
    //
    // Everything computed above reaches the native map — as annotation
    // geometry, as a camera centre, as a rotation. NaN there is not a Dart
    // exception anyone can catch: it is a Swift precondition that closes the
    // app on the spot ("latitude must not be NaN", MapboxMaps/Projection).
    //
    // The clamps above cannot be the guard, because every comparison against
    // NaN is false and so every one of them is skipped. So it is checked
    // here, once, at the only place the value is committed. Falling back to
    // the raw target keeps the marker where the GPS last said it was, which
    // is a lost frame of smoothing rather than a lost session.
    if (!newLat.isFinite || !newLng.isFinite) {
      _lat = _targetLat;
      _lng = _targetLng;
      _vLat = 0;
      _vLng = 0;
      return true;
    }

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
    final brgFactor = _lerpFactor(_bearingLerpPerSec, dtSec);
    final newBearing = (_bearing + dBrg * brgFactor) % 360;
    // Same reason as the position guard above: this goes out as iconRotate,
    // and as the camera bearing while navigating.
    if (!newBearing.isFinite) {
      _bearing = _targetBearing.isFinite ? _targetBearing : 0;
      return true;
    }
    final movedBrg = (newBearing - _bearing).abs() > 0.05;
    _bearing = newBearing < 0 ? newBearing + 360 : newBearing;

    return movedPos || movedBrg;
  }

  /// True when the smoother has nothing left to animate.
  ///
  /// Position *and* bearing. It used to be position alone, which was a fair
  /// description of the marker back when the only bearing it had came bundled
  /// with a fix — no new position meant no new heading either. The compass
  /// broke that: a driver standing still and turning the phone produces a
  /// steady stream of bearings and not one position update, so a caller that
  /// parked its ticker here would freeze the arrow mid-turn and leave it
  /// pointing at wherever the last frame caught it.
  bool get isAtTarget {
    if (_lat == null || _targetLat == null) return true;
    final latGap = (_targetLat! - _lat!).abs();
    final lngGap = (_targetLng! - _lng!).abs();
    // Same threshold tick() uses to call a turn visible, so the two agree on
    // what "settled" means.
    double brgGap = (_targetBearing - _bearing).abs();
    if (brgGap > 180) brgGap = 360 - brgGap;
    // ~1 cm of position, a twentieth of a degree of heading.
    return latGap < 1e-7 && lngGap < 1e-7 && brgGap < 0.05;
  }

  /// Force-set position (e.g., resuming from background, camera recenter).
  /// Velocity is zeroed so the next [tick] doesn't drift.
  void snapTo(double lat, double lng, {double? bearing}) {
    // The one entry point that wrote straight through to the rendered
    // position without checking. A single NaN fix from the platform — iOS
    // reports them briefly while the location manager is starting — put NaN
    // on the map with nothing in between.
    if (!lat.isFinite || !lng.isFinite) return;
    _lat = lat;
    _lng = lng;
    _targetLat = lat;
    _targetLng = lng;
    if (bearing != null && bearing.isFinite) {
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
