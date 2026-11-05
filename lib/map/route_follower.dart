import 'dart:math' as math;

import '../models/lat_lng.dart';

/// The rider's car ALONG the route (owner 2026-11-05: "que se vea mucho más
/// fluido el carrito avanzando al mismo tiempo que el conductor y cuando gire
/// gire igual como el conductor… que no se salga del carril").
///
/// The car lives in one dimension — metres along the route — so it can only
/// ever be on the street:
///  * each driver fix is projected onto the route and filtered together with
///    the speed the driver's phone measured (a small Kalman filter): a phone
///    position is off by metres, its Doppler speed by a fraction of a metre
///    per second, so the filter leans on the speed and the car is not tugged
///    back and forth by every fix;
///  * fixes are dated on the driver's own clock (the capture time), mapped to
///    ours by the smallest arrival-minus-capture seen lately — a fix that
///    came in late is known to be old, and the car is aimed where the driver
///    is NOW (the filtered position plus speed × age), not where they were;
///  * the drawn progress follows that aim on a critically damped spring: no
///    step on a new fix, no overshoot, never backwards, a stop when the
///    driver stops;
///  * the route's corners are rounded over a few metres (a car turns on a
///    curve, not on a point) and the car's nose is the street's direction
///    under it — it turns through the bend exactly as the road does.
///
/// Pure (no Flutter, no map): the rider tracking controller feeds it fixes
/// and ticks it every frame; it is tested on its own.
class RouteFollower {
  RouteFollower({DateTime Function()? clock}) : _now = clock ?? DateTime.now;

  final DateTime Function() _now;

  /// A fix farther than this from the route is the driver off it: the
  /// follower steps aside (the free glide takes the car).
  static const double maxLateralM = 35;

  /// How far before and after a corner the turn begins and ends.
  static const double cornerReachM = 8;

  /// A turn under this many degrees keeps its vertex (a slight bend).
  static const double minTurnDeg = 8;

  /// The filter: a phone position along the street (σ, m), the phone's own
  /// speed reading (σ, m/s) and how hard a car changes speed (σ, m/s²).
  static const double posSigmaM = 3.0;
  static const double speedSigma = 0.5;
  static const double accelSigma = 3.0;

  /// The drawn car follows the aim on a critically damped spring of this
  /// natural frequency (rad/s), fed the driver's speed: it keeps up with a
  /// moving aim and settles a correction without overshooting it.
  static const double springOmega = 4.0;

  /// Catching up runs at most this many times the driver's speed (+1.5 m/s).
  static const double maxCatchUp = 1.25;

  /// How far ahead of a fix the guess may reach, in seconds of driving (a
  /// longer silence holds the guess there instead of inventing a road).
  static const double maxLeadSec = 2.0;

  /// A new fix's correction to the guess is blended in over this time
  /// constant instead of all at once — the car never surges on a fix.
  static const double correctionEaseSec = 0.6;

  /// The nose follows the street's direction this quickly (time constant).
  static const double headingEaseSec = 0.10;

  /// Under this speed (walking pace) the driver counts as parked.
  static const double parkedMps = 0.8;

  /// Farther than this from the aim the car is placed there at once (the
  /// first fix, or a return after a long silence).
  static const double snapGapM = 80;

  /// The network's floor that the clock estimate cannot see (the smallest
  /// delay is folded into it).
  static const double netFloorSec = 0.15;

  // The rounded route, in local metres around its first point.
  double _refLat = 0, _refLng = 0, _kx = 1;
  final List<double> _x = [], _y = [], _s = [];
  int _hint = 0;

  // The filter: progress and speed at the last fix, and their covariance.
  bool _filtered = false;
  double _fs = 0, _fv = 0;
  double _p00 = 0, _p01 = 0, _p11 = 0;
  DateTime? _fixAt;
  double? _fixTsMs;
  final List<double> _offsetsMs = [];
  double _corr = 0;
  DateTime? _corrAt;

  // What is drawn.
  double? _shownS;
  double _u = 0;
  double _bearing = 0;
  bool _onRoute = false;

  /// On the route with a position to draw.
  bool get active => _onRoute && _shownS != null && _s.length >= 2;

  /// The drawn position, or null when not [active].
  LatLng? get position {
    final s = _shownS;
    if (!active || s == null) return null;
    final p = _pointAt(s);
    return _toLatLng(p.$1, p.$2);
  }

  /// Degrees clockwise from north: the street's direction under the car.
  double get bearing => _bearing;

  /// The estimated speed, m/s.
  double get speedMps => _fv;

  /// A new route: rounded once; everything about the old one is forgotten.
  void setRoute(List<LatLng> pts) {
    _x.clear();
    _y.clear();
    _s.clear();
    _hint = 0;
    leaveRoute();
    final clean = <LatLng>[
      for (final p in pts)
        if (p.latitude.isFinite && p.longitude.isFinite) p,
    ];
    if (clean.length < 2) return;
    _refLat = clean.first.latitude;
    _refLng = clean.first.longitude;
    _kx = 111320.0 * math.cos(_refLat * math.pi / 180);
    final xs = <double>[], ys = <double>[];
    for (final p in clean) {
      final x = (p.longitude - _refLng) * _kx;
      final y = (p.latitude - _refLat) * 110540.0;
      if (xs.isNotEmpty &&
          math.sqrt(math.pow(x - xs.last, 2) + math.pow(y - ys.last, 2)) <
              0.5) {
        continue;
      }
      xs.add(x);
      ys.add(y);
    }
    if (xs.length < 2) return;
    _x.add(xs.first);
    _y.add(ys.first);
    for (var i = 1; i + 1 < xs.length; i++) {
      final ax = xs[i] - xs[i - 1], ay = ys[i] - ys[i - 1];
      final bx = xs[i + 1] - xs[i], by = ys[i + 1] - ys[i];
      final la = math.sqrt(ax * ax + ay * ay);
      final lb = math.sqrt(bx * bx + by * by);
      final cos = ((ax * bx + ay * by) / (la * lb)).clamp(-1.0, 1.0);
      final turn = math.acos(cos) * 180 / math.pi;
      if (turn < minTurnDeg) {
        _x.add(xs[i]);
        _y.add(ys[i]);
        continue;
      }
      // A quadratic curve from `d` before the corner to `d` after it, the
      // corner its control point: inside the bend by at most ~0.35·d.
      final d = math.min(cornerReachM, math.min(la, lb) / 2);
      final p0x = xs[i] - ax / la * d, p0y = ys[i] - ay / la * d;
      final p2x = xs[i] + bx / lb * d, p2y = ys[i] + by / lb * d;
      const steps = 8;
      for (var k = 0; k <= steps; k++) {
        final t = k / steps, m = 1 - t;
        _x.add(m * m * p0x + 2 * m * t * xs[i] + t * t * p2x);
        _y.add(m * m * p0y + 2 * m * t * ys[i] + t * t * p2y);
      }
    }
    _x.add(xs.last);
    _y.add(ys.last);
    _s.add(0);
    for (var i = 1; i < _x.length; i++) {
      _s.add(_s.last +
          math.sqrt(math.pow(_x[i] - _x[i - 1], 2) +
              math.pow(_y[i] - _y[i - 1], 2)));
    }
  }

  /// The driver left the route (or the screen has none usable): the free
  /// glide takes the car until a fix lands on it again.
  void leaveRoute() {
    _onRoute = false;
    _shownS = null;
    _u = 0;
    _filtered = false;
    _fixAt = null;
    _fixTsMs = null;
    _corr = 0;
    _corrAt = null;
  }

  /// One driver fix. [timestampMs] is the capture time on the driver's
  /// clock; [speedMps] the speed the driver's phone measured (~0 parked).
  /// [drawnNow] is where the car is on screen right now: when the follower
  /// takes over (first fix, a new route) the car starts there and glides to
  /// the aim, instead of jumping to it.
  void onFix(double lat, double lng,
      {double? speedMps, double? timestampMs, LatLng? drawnNow}) {
    if (_s.length < 2 || !lat.isFinite || !lng.isFinite) return;
    final now = _now();
    final x = (lng - _refLng) * _kx, y = (lat - _refLat) * 110540.0;
    final (s, lateral) = _project(x, y);
    if (lateral > maxLateralM) {
      leaveRoute();
      return;
    }
    final ts = (timestampMs != null && timestampMs.isFinite && timestampMs > 0)
        ? timestampMs
        : null;
    // Older than the last one (the relay and the database can cross).
    if (ts != null && _fixTsMs != null && ts <= _fixTsMs!) return;
    // When it was captured, on our clock: arrival minus capture is the two
    // clocks' gap plus the trip over the network; its smallest recent value
    // is the gap plus the fastest trip.
    var cap = now;
    if (ts != null) {
      _offsetsMs.add(now.millisecondsSinceEpoch - ts);
      if (_offsetsMs.length > 12) _offsetsMs.removeAt(0);
      final floor = _offsetsMs.reduce(math.min);
      final at = DateTime.fromMillisecondsSinceEpoch(
          (ts + floor - netFloorSec * 1000).round());
      cap = at.isAfter(now) ? now : at;
    }
    final reported = (speedMps != null && speedMps.isFinite && speedMps >= 0)
        ? speedMps
        : null;
    final before = _filtered && _fixAt != null ? _aim(now) : null;

    if (!_filtered) {
      _fs = s;
      _fv = reported ?? 0;
      _p00 = posSigmaM * posSigmaM;
      _p01 = 0;
      _p11 = reported != null ? speedSigma * speedSigma : 25;
      _filtered = true;
    } else {
      // Between the two captures, on the driver's clock when both have one.
      final prevAt = _fixAt, prevTs = _fixTsMs;
      final dt = ((ts != null && prevTs != null)
              ? (ts - prevTs) / 1000
              : (prevAt == null
                  ? 0.0
                  : cap.difference(prevAt).inMicroseconds / 1e6))
          .clamp(0.0, 5.0)
          .toDouble();
      // Predict: on at the same speed; the doubt grows with a car's ability
      // to change speed.
      const q = accelSigma * accelSigma;
      _fs += _fv * dt;
      _p00 += dt * (2 * _p01 + dt * _p11) + q * dt * dt * dt * dt / 4;
      _p01 += dt * _p11 + q * dt * dt * dt / 2;
      _p11 += q * dt * dt;
      // Parked: neither the GPS wander nor a stray speed reading may move
      // the car — it only ever steps forward, so either, folded in, would
      // ratchet it along the kerb (a speed reading moves the position too,
      // through their covariance). A real move (15 m+) still counts.
      final parked = reported != null && reported < parkedMps;
      if (parked && (s - _fs).abs() <= 15) {
        _fv = 0;
        _p01 = 0;
        _p11 = speedSigma * speedSigma;
      } else {
        // The position.
        _update(s - _fs, posSigmaM * posSigmaM, true);
        // The phone's own speed.
        if (reported != null) {
          _update(reported - _fv, speedSigma * speedSigma, false);
        }
      }
    }
    if (_fv < 0) _fv = 0;
    if (reported != null && reported < parkedMps) _fv = 0; // parked
    _fixAt = cap;
    _fixTsMs = ts;
    _onRoute = true;
    // Keep the guess where it was this instant and ease the difference out.
    _corr = 0;
    final after = _aim(now);
    _corr = (before == null || (before - after).abs() > snapGapM / 3)
        ? 0
        : before - after;
    _corrAt = now;
    if (_shownS == null) {
      var start = after;
      final d = drawnNow;
      if (d != null && d.latitude.isFinite && d.longitude.isFinite) {
        final (ds, dLat) = _project(
            (d.longitude - _refLng) * _kx, (d.latitude - _refLat) * 110540.0);
        if (dLat <= maxLateralM && (after - ds).abs() <= snapGapM) start = ds;
      }
      _shownS = start;
      _u = _fv;
      _bearing = _tangentAt(start);
    }
  }

  /// One Kalman measurement update: [innovation] against the position
  /// ([onPosition]) or the speed, with variance [r].
  void _update(double innovation, double r, bool onPosition) {
    final hp0 = onPosition ? _p00 : _p01; // P·Hᵀ, first row
    final hp1 = onPosition ? _p01 : _p11; // P·Hᵀ, second row
    final sVar = (onPosition ? _p00 : _p11) + r;
    final k0 = hp0 / sVar, k1 = hp1 / sVar;
    _fs += k0 * innovation;
    _fv += k1 * innovation;
    final p00 = _p00 - k0 * hp0;
    final p01 = _p01 - k0 * hp1;
    final p11 = _p11 - k1 * hp1;
    _p00 = p00;
    _p01 = p01;
    _p11 = p11;
  }

  /// One frame.
  void tick(double dt) {
    final shown = _shownS;
    if (!active || shown == null || !(dt > 0)) return;
    final now = _now();
    final aim = _aim(now);
    final gap = aim - shown;
    double next;
    if (gap.abs() > snapGapM) {
      next = aim;
      _u = _aimSpeed(now);
    } else {
      final aimV = _aimSpeed(now);
      // Sub-stepped: a long frame must not kick the spring.
      var s = shown, u = _u, left = dt;
      while (left > 0) {
        final h = math.min(left, 1 / 120);
        final acc = springOmega * springOmega * (aim - s) +
            2 * springOmega * (aimV - u);
        // Never backwards; and catching up never looks like a sprint.
        u = (u + acc * h).clamp(0.0, aimV * maxCatchUp + 1.5).toDouble();
        s += u * h;
        left -= h;
      }
      _u = u;
      next = s;
    }
    _shownS = next.clamp(0.0, _s.last).toDouble();
    if (_u > 0.2 || gap.abs() > snapGapM) {
      final t = _tangentAt(_shownS!);
      var d = (t - _bearing) % 360;
      if (d > 180) d -= 360;
      if (d < -180) d += 360;
      _bearing = (_bearing + d * (1 - math.exp(-dt / headingEaseSec))) % 360;
      if (_bearing < 0) _bearing += 360;
    }
  }

  /// Seconds of driving the guess may add to the last fix: its age, eased
  /// to a stop at [maxLeadSec].
  double _lead(DateTime now) {
    final at = _fixAt;
    if (at == null) return 0;
    final age = math.max(0.0, now.difference(at).inMicroseconds / 1e6);
    const knee = maxLeadSec * 0.6;
    if (age <= knee) return age;
    return knee +
        (maxLeadSec - knee) * (1 - math.exp(-(age - knee) / (maxLeadSec - knee)));
  }

  /// How fast [_aim] moves now (the driver's speed); 0 once the guess has
  /// stopped growing. The correction's easing is left to the spring: fed
  /// forward, its rate stepped on every fix and the car surged.
  double _aimSpeed(DateTime now) {
    final at = _fixAt;
    if (at == null) return 0;
    final age = math.max(0.0, now.difference(at).inMicroseconds / 1e6);
    const knee = maxLeadSec * 0.6;
    final grow =
        age <= knee ? 1.0 : math.exp(-(age - knee) / (maxLeadSec - knee));
    return _fv * grow;
  }

  /// Where the driver is now: the filtered fix plus what they drove since,
  /// plus the part of the last correction not yet eased out.
  double _aim(DateTime now) {
    if (!_filtered || _fixAt == null) return _shownS ?? 0;
    var aim = _fs + _fv * _lead(now);
    final at = _corrAt;
    if (at != null && _corr != 0) {
      final since = math.max(0.0, now.difference(at).inMicroseconds / 1e6);
      aim += _corr * math.exp(-since / correctionEaseSec);
    }
    return aim.clamp(0.0, _s.last).toDouble();
  }

  /// Nearest point of the route to (x, y): (metres along it, metres off it).
  /// Windowed around the last answer; the whole route when that is far.
  (double, double) _project(double x, double y) {
    final win = _projectIn(x, y, _hint - 6, _hint + 80);
    if (win.$3 <= maxLateralM) {
      _hint = win.$1;
      return (win.$2, win.$3);
    }
    final all = _projectIn(x, y, 0, _x.length - 1);
    _hint = all.$1;
    return (all.$2, all.$3);
  }

  (int, double, double) _projectIn(double x, double y, int from, int to) {
    final n = _x.length;
    from = from.clamp(0, n - 2);
    to = to.clamp(from + 1, n - 1);
    var best = double.infinity, bestS = _s[from];
    var bestI = from;
    for (var i = from; i < to; i++) {
      final dx = _x[i + 1] - _x[i], dy = _y[i + 1] - _y[i];
      final l2 = dx * dx + dy * dy;
      final t = l2 == 0
          ? 0.0
          : (((x - _x[i]) * dx + (y - _y[i]) * dy) / l2).clamp(0.0, 1.0);
      final px = _x[i] + dx * t, py = _y[i] + dy * t;
      final d = math.sqrt((x - px) * (x - px) + (y - py) * (y - py));
      if (d < best) {
        best = d;
        bestI = i;
        bestS = _s[i] + (_s[i + 1] - _s[i]) * t;
      }
    }
    return (bestI, bestS, best);
  }

  (double, double) _pointAt(double s) {
    if (s <= 0) return (_x.first, _y.first);
    if (s >= _s.last) return (_x.last, _y.last);
    var lo = 0, hi = _s.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (_s[mid] <= s) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final seg = _s[hi] - _s[lo];
    final t = seg > 0 ? (s - _s[lo]) / seg : 0.0;
    return (_x[lo] + (_x[hi] - _x[lo]) * t, _y[lo] + (_y[hi] - _y[lo]) * t);
  }

  /// The street's direction at [s]: the chord over ±3 m (continuous through
  /// the rounded corners).
  double _tangentAt(double s) {
    final a = _pointAt(math.max(0.0, s - 3));
    final b = _pointAt(math.min(_s.last, s + 3));
    final dx = b.$1 - a.$1, dy = b.$2 - a.$2;
    if (dx == 0 && dy == 0) return _bearing;
    return (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;
  }

  LatLng _toLatLng(double x, double y) =>
      LatLng(_refLat + y / 110540.0, _refLng + x / _kx);
}
