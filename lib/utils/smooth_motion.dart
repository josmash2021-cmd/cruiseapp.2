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
///
/// The correction aims at the EXTRAPOLATED target (target + velocity × fix
/// age), not at the raw fix. A fix is already stale when it lands: at 1 fix/s
/// the car has moved on by a second's worth of travel. Aiming at the raw fix
/// made the marker sprint to a point the car had already left, slam into the
/// overshoot clamp, and park there until the next fix — the
/// glide-stop-glide cadence that read as "it steps once a second" (measured
/// in simulation: the marker spent 33–73% of frames at a standstill at a
/// steady 8 m/s). Aiming at the extrapolated point keeps the glide alive
/// between fixes: 0% stalled frames, rendered speed 8.02 ± 0.13 m/s.
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

  /// Capture timestamp (epoch millis) of the last accepted fix, when the
  /// feed carries one. Arrival time paces a feed that doesn't.
  double? _lastTargetTsMs;

  /// How much of the remaining angular gap to close per second when applying
  /// the low-pass filter on bearing. Higher = more responsive turns.
  /// 2.5 → 3.5: the arrow visibly trailed the car's turns by ~half a second.
  static const double _bearingLerpPerSec = 3.5;

  /// How much of the residual lat/lng gap to close per second via
  /// proportional correction. Higher = more responsive, follows GPS closer.
  /// 1.8 → 1.2 made it silky but put the marker ~0.8 s behind the car —
  /// "fluid, but late". 2.4 halves that constant (~0.4 s) while the
  /// constant-velocity leg keeps the glide, so it reads as real-time
  /// without the snap of raw GPS.
  static const double _correctionPerSec = 2.4;

  /// Freeze velocity after this many seconds without a fresh GPS fix.
  /// 5 s covers the real gaps seen on cellular (tower handoffs, burst
  /// delivery) and the rider's relayed feed; the old 3.5 s froze the marker
  /// mid-gap and the next fix then arrived to a stopped marker with metres
  /// of backlog — the freeze-then-jump cycle.
  static const double _maxExtrapolationSec = 5.0;

  /// How far ahead of the latest fix the extrapolated aim point may lead, in
  /// seconds of travel. Caps the guess when the feed goes quiet: with a dead
  /// feed the marker glides at most this far past the last fix and holds,
  /// instead of running on for the full [_maxExtrapolationSec]. 2 s covers
  /// the 1 Hz iOS cadence with jitter headroom; a live feed never reaches it.
  static const double _maxLeadSec = 2.0;

  /// Maximum acceleration the velocity estimate may gain per second of fix
  /// spacing (m/s²). The first delta after a stop reads the whole gap's
  /// distance over one fix interval — a parked car whose fix hops 8 m in
  /// 0.2 s "measures" 40 m/s, and without a cap the marker rockets past the
  /// target on the extrapolated lead. A city car accelerates at 2–4 m/s²;
  /// 8 is generous headroom that still absorbs the bogus spike.
  static const double _maxAccelMps2 = 8.0;

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

  /// Current measured glide speed in m/s — diagnostics: when the marker
  /// "steps once per fix", this reading near zero while the car moves means
  /// the velocity measurement is dying on the feed, not the renderer.
  double get speedMps {
    if (_lat == null || _targetLat == null) return 0;
    final cosLat = math.cos((_targetLat ?? _lat!) * math.pi / 180.0);
    return math.sqrt(
      math.pow(_vLng * 111320.0 * cosLat, 2) + math.pow(_vLat * 110540.0, 2),
    );
  }

  /// How many fixes in a row the standstill hold has swallowed.
  int _consecutiveHolds = 0;

  /// After this many, the next fix is taken whatever it says. Five fixes
  /// held a car pulling away from a stop for over a second — the "start"
  /// lag. Three still stacked into a visible freeze-jump-freeze cycle in
  /// slow traffic (hold the fix, stall, then close metres of backlog in
  /// one correction). Two absorbs a wander burst and lets a real move
  /// through before the stall is felt.
  static const int _maxConsecutiveHolds = 2;

  /// Provide a new GPS target. Measures velocity from the delta to the
  /// previous target.
  ///
  /// [bearing] is optional (degrees, 0 = north). [accuracyM] is the fix's
  /// own reported radius of uncertainty — `Position.accuracy` — and sizes
  /// the standstill hold below. Without it the hold falls back to the old
  /// flat 15 m, which is wider than a road.
  ///
  /// [timestampMs] is when the fix was CAPTURED (epoch millis), not when it
  /// arrived. Relayered feeds (the rider watching the driver over
  /// socket/RTDB) deliver fixes in bursts; measuring speed between arrival
  /// times reads a 3-fix burst as a sprint followed by a standstill, which
  /// is the accelerate-brake pulsing the old feed showed. When both the
  /// last and current fix carry a sane timestamp, the delta between them
  /// is what paces the glide.
  void setTarget(
    double lat,
    double lng, {
    double? bearing,
    double? accuracyM,
    double? timestampMs,
  }) {
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

    final now = DateTime.now();
    // Wall-clock sanity for the capture timestamp: future or prehistoric
    // timestamps are ignored and the arrival time paces that fix instead.
    final nowMs = now.millisecondsSinceEpoch.toDouble();
    final double? fixTsMs =
        (timestampMs != null && timestampMs.isFinite && timestampMs > 0)
            ? timestampMs
            : null;
    if (_targetLat != null && _lastTargetAt != null) {
      var dtSec =
          now.difference(_lastTargetAt!).inMilliseconds / 1000.0;
      // Prefer capture-to-capture spacing over arrival-to-arrival when the
      // feed carries real timestamps (see the docstring).
      if (fixTsMs != null && _lastTargetTsMs != null) {
        final tsDt = (fixTsMs - _lastTargetTsMs!) / 1000.0;
        if (tsDt > 0.05 && tsDt < 10.0) dtSec = tsDt;
      }
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
          if (fixTsMs != null) _lastTargetTsMs = fixTsMs;
          return;
        }

        // A stopped or crawling car's GPS heading is noise — it swings
        // 30-90° between fixes at a traffic light, and applying it made the
        // arrow tremble while parked. Only a fix that shows real movement
        // is allowed to aim the marker; compass-fed setBearing keeps
        // turning it meanwhile.
        if (bearing != null && impliedSpeed >= 1.0) setBearing(bearing);

        // After a long gap the average speed over the gap says nothing
        // about how fast the car is moving NOW — it crept through traffic
        // for 6 s and the delta reads as one slow slide. Left uncapped,
        // the blended velocity keeps the marker gliding far past the fix.
        // 12 m/s ≈ 43 km/h: a city car between fixes, never a flight.
        final speedScale = dtSec > 5.0 && impliedSpeed > 12.0
            ? 12.0 / impliedSpeed
            : 1.0;

        // Standstill jitter hold: while essentially parked, ignore position
        // hops small enough to be GPS wander rather than movement.
        //
        // The radius was a flat 15 m, and that is wider than a road. A
        // driver standing in the street was drawn on the pavement and stayed
        // there, because every fix that would have corrected it landed
        // inside the ring and was thrown away — and the ring is measured
        // from the stale target, so it never caught up. Fifteen metres of
        // permanent error, on the screen whose whole job is to say where
        // the driver is.
        //
        // Sized to the fix instead. The platform reports how far off it
        // might be; a reading good to 3 m that has moved 8 m has moved, and
        // one good to 40 m that has moved 8 m has not necessarily. Floored
        // at 2.5 m because no fix is better than that in a street, and
        // capped at the old 15 so a wild accuracy figure cannot widen it.
        // (The freeze-then-jump in slow traffic was NOT this radius — it
        // was the per-hold velocity halving stacked with 3 consecutive
        // holds; both are softened below.)
        final holdRadiusM = (accuracyM == null ||
                !accuracyM.isFinite ||
                accuracyM <= 0)
            ? 15.0
            : accuracyM.clamp(2.5, 15.0);

        final curSpeedMps = math.sqrt(
          math.pow(_vLng * 111320.0 * cosLat, 2) +
              math.pow(_vLat * 110540.0, 2),
        );
        // And never more than a couple in a row.
        //
        // Whatever the radius, a run of fixes that all agree on a new place
        // is not noise. Without this a marker could be held indefinitely by
        // readings that each sit just inside the ring, which is the same
        // permanent error in a slower form.
        if (curSpeedMps < 1.2 &&
            distM < holdRadiusM &&
            _consecutiveHolds < _maxConsecutiveHolds) {
          _consecutiveHolds++;
          // Bleed off a little residual velocity and refresh the timestamp
          // so the extrapolation freeze doesn't kick in — but keep the old
          // target. Halving it per held fix (the old 0.5) killed the glide
          // after two holds: a car creeping through traffic stalled dead
          // and then jumped to catch up. 0.85 settles a truly parked car
          // while letting a creeping one keep rolling.
          _vLat *= 0.85;
          _vLng *= 0.85;
          _lastTargetAt = now;
          if (fixTsMs != null) _lastTargetTsMs = fixTsMs;
          return;
        }
        _consecutiveHolds = 0;

        final newVLat = dLat / dtSec * speedScale;
        final newVLng = dLng / dtSec * speedScale;
        // Acceleration cap — see _maxAccelMps2. Applied to the fresh
        // measurement before the blend, so a single bogus delta cannot put
        // a highway speed into the extrapolation lead.
        final dvLat = newVLat - _vLat;
        final dvLng = newVLng - _vLng;
        final dvMps = math.sqrt(
          math.pow(dvLng * 111320.0 * cosLat, 2) +
              math.pow(dvLat * 110540.0, 2),
        );
        final maxDv = _maxAccelMps2 * dtSec;
        if (dvMps > maxDv && dvMps > 0) {
          final k = maxDv / dvMps;
          final cappedVLat = _vLat + dvLat * k;
          final cappedVLng = _vLng + dvLng * k;
          // Exponential average — absorbs GPS jitter without overfitting.
          // 0.3/0.7 → 0.2/0.8: the fresher the speed estimate, the less the
          // extrapolated glide runs behind (or ahead of) the car.
          _vLat = _vLat * 0.2 + cappedVLat * 0.8;
          _vLng = _vLng * 0.2 + cappedVLng * 0.8;
        } else {
          _vLat = _vLat * 0.2 + newVLat * 0.8;
          _vLng = _vLng * 0.2 + newVLng * 0.8;
        }
      } else if (bearing != null) {
        // No usable spacing (duplicate ts, huge gap): no speed to judge by,
        // keep the old behaviour and take the bearing as sent.
        setBearing(bearing);
      }
    } else if (bearing != null) {
      // First fix of the session — nothing to measure against yet.
      setBearing(bearing);
    }
    _lastTargetAt = now;
    _lastTargetTsMs = fixTsMs ?? _lastTargetTsMs;
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

  /// Where the correction is aiming right now.
  ///
  /// Normally the latest fix pushed forward by its age (capped at
  /// [_maxLeadSec] of travel): the car kept moving after the fix was taken,
  /// so the raw point is where it WAS. Aiming at the raw fix made the marker
  /// sprint to a stale point, hit the overshoot clamp, and park until the
  /// next fix — the once-a-second step.
  ///
  /// When the feed is stale the aim is the marker's own position — "hold
  /// where you are". Aiming back at the raw fix instead would visibly drag
  /// the marker BACKWARDS over the lead it had legitimately built up.
  (double, double) _aimPoint() {
    if (_lat == null || _targetLat == null) return (0, 0);
    var ageSec = 0.0;
    if (_lastTargetAt != null) {
      ageSec =
          DateTime.now().difference(_lastTargetAt!).inMilliseconds / 1000.0;
    }
    if (ageSec > _maxExtrapolationSec) return (_lat!, _lng!);
    final leadSec = ageSec > _maxLeadSec ? _maxLeadSec : ageSec;
    return (_targetLat! + _vLat * leadSec, _targetLng! + _vLng * leadSec);
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
    // turns, and GPS jumps without a visible snap. The aim point is the
    // extrapolated target (see _aimPoint) — aiming at the raw fix is what
    // produced the sprint-and-park cadence.
    final aim = _aimPoint();
    final residualLat = aim.$1 - _lat!;
    final residualLng = aim.$2 - _lng!;
    final corrFactor = _lerpFactor(_correctionPerSec, dtSec);
    stepLat += residualLat * corrFactor;
    stepLng += residualLng * corrFactor;

    // Never overshoot past the aim point on either axis. The aim point is
    // moving (see above), so this clamps the marker onto the extrapolated
    // lead — not onto the stale fix — and the glide survives.
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
    // Against the AIM point, not the raw fix: a gliding marker that has
    // caught its extrapolated lead has nothing left to animate, and a held
    // marker with a stale feed is exactly where it was told to hold.
    final aim = _aimPoint();
    final latGap = (aim.$1 - _lat!).abs();
    final lngGap = (aim.$2 - _lng!).abs();
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
    _consecutiveHolds = 0;
    _lastTargetAt = DateTime.now();
    _lastTargetTsMs = null;
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
    _consecutiveHolds = 0;
    _lastTargetAt = null;
    _lastTargetTsMs = null;
  }
}
