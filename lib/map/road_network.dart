import 'dart:math' as math;

import '../models/lat_lng.dart';

/// The streets around the driver, read from the map's own vector tiles.
///
/// Owner report 2026-11-02 ("la flecha se sale de las vías y luego se pone
/// bien, y así… que gire siguiendo las vías"): searching has no route, and
/// the line the arrow rode was the map-matched trace of PAST fixes, refreshed
/// every 6 s — a moving car is always beyond its end. On a straight road the
/// line's straight continuation covered the gap; on a curve or after a turn
/// it could not, so the arrow showed the raw GPS, off the street, until the
/// next match pulled it back. Every 6 s, off and back.
///
/// The tiles already on screen hold the roads AHEAD of the car. Each fix
/// picks the street it is on (distance, the car's course, and the street it
/// was already on) and lays a line along it — [behindM] back, [aheadM]
/// forward, carried across the joins between features and tiles — that the
/// road lock rides exactly like a navigation route. No network call.
class RoadNetwork {
  RoadNetwork(Iterable<List<LatLng>> lines) : _lines = _dedupe(lines);

  final List<List<LatLng>> _lines;

  bool get isEmpty => _lines.isEmpty;
  int get lineCount => _lines.length;

  /// Mapbox Streets v8 `class` values a car drives on. Paths, pedestrian
  /// ways, tracks, rail and ferries never steer the arrow.
  static const Set<String> carClasses = {
    'motorway', 'motorway_link', 'trunk', 'trunk_link',
    'primary', 'primary_link', 'secondary', 'secondary_link',
    'tertiary', 'tertiary_link', 'street', 'street_limited', 'service',
  };

  /// How far the line reaches past the car: ~10 s at highway speed, and the
  /// line is rebuilt on every fix anyway.
  static const double aheadM = 300.0;
  static const double behindM = 40.0;

  /// A feature that ends within this of another one carries on along it —
  /// a way split at a crossing, or the same road cut at a tile edge.
  static const double joinM = 4.0;

  /// …but only when it keeps going roughly the same way. A sharper turn is a
  /// decision the car has not made yet: the next fix will show it.
  static const double maxJoinTurnDeg = 60.0;

  /// Lines of drivable roads from rendered-feature GeoJSON maps
  /// (`properties.class`, `geometry` LineString / MultiLineString in
  /// `[lng, lat]`). Anything malformed is skipped, never thrown.
  static List<List<LatLng>> parseFeatures(Iterable<Object?> features) {
    final out = <List<LatLng>>[];
    for (final feat in features) {
      if (feat is! Map) continue;
      final props = feat['properties'];
      if (props is! Map) continue;
      if (!carClasses.contains(props['class']?.toString() ?? '')) continue;
      final geom = feat['geometry'];
      if (geom is! Map) continue;
      final coords = geom['coordinates'];
      if (coords is! List) continue;
      switch (geom['type']) {
        case 'LineString':
          final line = _parseLine(coords);
          if (line != null) out.add(line);
        case 'MultiLineString':
          for (final part in coords) {
            if (part is! List) continue;
            final line = _parseLine(part);
            if (line != null) out.add(line);
          }
      }
    }
    return out;
  }

  static List<LatLng>? _parseLine(List coords) {
    final pts = <LatLng>[];
    for (final c in coords) {
      if (c is List && c.length >= 2 && c[0] is num && c[1] is num) {
        final lng = (c[0] as num).toDouble();
        final lat = (c[1] as num).toDouble();
        if (lat.isFinite && lng.isFinite) pts.add(LatLng(lat, lng));
      }
    }
    return pts.length >= 2 ? pts : null;
  }

  /// The same road comes back once per style layer that draws it (casing,
  /// fill, bridge…): keep one copy, or every join would stop on its twin.
  static List<List<LatLng>> _dedupe(Iterable<List<LatLng>> lines) {
    final seen = <String>{};
    final out = <List<LatLng>>[];
    String key(LatLng p) =>
        '${p.latitude.toStringAsFixed(6)},${p.longitude.toStringAsFixed(6)}';
    for (final l in lines) {
      if (l.length < 2) continue;
      final k = '${key(l.first)}|${key(l.last)}|${l.length}';
      final r = '${key(l.last)}|${key(l.first)}|${l.length}';
      if (seen.contains(k) || seen.contains(r)) continue;
      seen.add(k);
      out.add(List<LatLng>.unmodifiable(l));
    }
    return out;
  }

  /// The street [fix] is on, as a line pointing the way the car goes — or
  /// null when no drivable street is close enough to vouch for it (a parking
  /// lot, a road the tiles lack): the caller keeps its older source then.
  ///
  /// [headingDeg] orients the line and, while moving, rules out a street
  /// crossing the car's course (an overpass, the cross street at a corner).
  /// [previousPath] is the line the last fix chose: staying on it is
  /// preferred, so a parallel street or a carriageway never steals the
  /// arrow on GPS noise alone.
  List<LatLng>? pathFor(
    LatLng fix, {
    double? headingDeg,
    double speedMps = 0,
    double accuracyM = 10,
    List<LatLng> previousPath = const [],
  }) {
    if (_lines.isEmpty || !fix.latitude.isFinite || !fix.longitude.isFinite) {
      return null;
    }
    final f = _Frame(fix);
    final pts = [
      for (final l in _lines) [for (final p in l) f.xy(p)]
    ];
    final prev = [for (final p in previousPath) f.xy(p)];
    final heading =
        (headingDeg != null && headingDeg.isFinite) ? headingDeg % 360 : null;
    final moving = heading != null && speedMps >= 2.0;
    // The tiles draw a street's centre line: a car in an outer lane of a
    // wide road sits ~10 m off it before any GPS error.
    var radius = (accuracyM.isFinite && accuracyM > 0)
        ? (accuracyM * 2 + 8).clamp(15.0, 30.0).toDouble()
        : 20.0;
    // Crawling or parked: only a street the car is plainly ON. A car in a
    // lot beside the road must not be drawn on the road.
    if (speedMps < 2.0) radius = math.min(radius, 10.0);

    _Hit? best;
    var bestCost = double.infinity;
    for (var li = 0; li < pts.length; li++) {
      final line = pts[li];
      for (var si = 0; si < line.length - 1; si++) {
        final a = line[si], b = line[si + 1];
        final dx = b.x - a.x, dy = b.y - a.y;
        final len2 = dx * dx + dy * dy;
        if (len2 < 0.01) continue;
        // The fix is the frame's origin.
        final t = ((-a.x) * dx + (-a.y) * dy) / len2;
        final tc = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
        final px = a.x + dx * tc, py = a.y + dy * tc;
        final dist = math.sqrt(px * px + py * py);
        if (dist > radius) continue;
        final segBrg = _bearingXY(dx, dy);
        var up = true;
        var mismatch = 0.0;
        if (heading != null) {
          final d = _angleDelta(heading, segBrg);
          up = d <= 90;
          mismatch = up ? d : 180 - d;
        }
        if (moving && mismatch > 70) continue;
        var cost = dist + (moving ? 0.4 * math.max(0.0, mismatch - 10) : 0.0);
        if (prev.length >= 2 && _distToPolyline(px, py, prev) < 3.0) {
          cost -= 6.0;
        }
        if (cost < bestCost) {
          bestCost = cost;
          best = _Hit(li, si, _P(px, py), up);
        }
      }
    }
    final hit = best;
    if (hit == null) return null;

    final ahead = _walk(pts, hit, up: hit.up, budget: aheadM, hops: 12);
    final behind = _walk(pts, hit, up: !hit.up, budget: behindM, hops: 0);
    final path = <_P>[...behind.reversed, hit.point, ...ahead];
    final out = <LatLng>[];
    _P? last;
    for (final p in path) {
      if (last != null && (p.x - last.x).abs() < 0.05 && (p.y - last.y).abs() < 0.05) {
        continue;
      }
      out.add(f.ll(p));
      last = p;
    }
    return out.length >= 2 ? out : null;
  }

  /// Walks [budget] metres from [hit] along its line in the [up] (vertex
  /// order) or opposite direction; at a line's end, up to [hops] times,
  /// carries on along the feature that continues it (see [joinM]).
  List<_P> _walk(List<List<_P>> pts, _Hit hit,
      {required bool up, required double budget, required int hops}) {
    final out = <_P>[];
    var li = hit.line;
    var dirUp = up;
    var idx = dirUp ? hit.segment + 1 : hit.segment;
    var cur = hit.point;
    var remaining = budget;
    var hopsLeft = hops;
    double? lastBrg;
    final visited = <int>{li};
    while (true) {
      final line = pts[li];
      while (dirUp ? idx < line.length : idx >= 0) {
        final v = line[idx];
        final d = _dist(cur, v);
        if (d >= remaining) {
          final k = d > 1e-9 ? remaining / d : 0.0;
          out.add(_P(cur.x + (v.x - cur.x) * k, cur.y + (v.y - cur.y) * k));
          return out;
        }
        if (d > 1e-3) lastBrg = _bearingXY(v.x - cur.x, v.y - cur.y);
        remaining -= d;
        cur = v;
        out.add(v);
        idx += dirUp ? 1 : -1;
      }
      if (hopsLeft-- <= 0 || lastBrg == null) return out;
      final next = _continuation(pts, cur, lastBrg, visited);
      if (next == null) return out;
      li = next.line;
      dirUp = next.up;
      idx = dirUp ? next.segment + 1 : next.segment;
      final d = _dist(cur, next.point);
      if (d > 0.05) {
        out.add(next.point);
        remaining -= d;
        cur = next.point;
      }
      visited.add(li);
    }
  }

  /// The feature that carries on from [end] the way [incomingBrg] goes, or
  /// null at a dead end or a corner (see [maxJoinTurnDeg]).
  _Hit? _continuation(
      List<List<_P>> pts, _P end, double incomingBrg, Set<int> visited) {
    _Hit? best;
    var bestDev = double.infinity;
    for (var li = 0; li < pts.length; li++) {
      if (visited.contains(li)) continue;
      final line = pts[li];
      for (var si = 0; si < line.length - 1; si++) {
        final a = line[si], b = line[si + 1];
        final dx = b.x - a.x, dy = b.y - a.y;
        final len2 = dx * dx + dy * dy;
        if (len2 < 0.01) continue;
        final t = ((end.x - a.x) * dx + (end.y - a.y) * dy) / len2;
        final tc = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
        final q = _P(a.x + dx * tc, a.y + dy * tc);
        if (_dist(q, end) > joinM) continue;
        final segBrg = _bearingXY(dx, dy);
        for (final up in const [true, false]) {
          // Nothing left to drive that way from here: not a continuation.
          final left = up
              ? _dist(q, b) + _lengthFrom(line, si + 1, true)
              : _dist(q, a) + _lengthFrom(line, si, false);
          if (left < 0.5) continue;
          final dev = _angleDelta(incomingBrg, up ? segBrg : (segBrg + 180) % 360);
          if (dev <= maxJoinTurnDeg && dev < bestDev) {
            bestDev = dev;
            best = _Hit(li, si, q, up);
          }
        }
      }
    }
    return best;
  }

  static double _lengthFrom(List<_P> line, int vertex, bool up) {
    var sum = 0.0;
    if (up) {
      for (var i = vertex; i < line.length - 1; i++) {
        sum += _dist(line[i], line[i + 1]);
      }
    } else {
      for (var i = vertex; i > 0; i--) {
        sum += _dist(line[i], line[i - 1]);
      }
    }
    return sum;
  }

  static double _distToPolyline(double x, double y, List<_P> line) {
    var best = double.infinity;
    for (var i = 0; i < line.length - 1; i++) {
      final a = line[i], b = line[i + 1];
      final dx = b.x - a.x, dy = b.y - a.y;
      final len2 = dx * dx + dy * dy;
      final t = len2 < 1e-9 ? 0.0 : ((x - a.x) * dx + (y - a.y) * dy) / len2;
      final tc = t < 0 ? 0.0 : (t > 1 ? 1.0 : t);
      final ex = a.x + dx * tc - x, ey = a.y + dy * tc - y;
      best = math.min(best, math.sqrt(ex * ex + ey * ey));
    }
    return best;
  }

  static double _dist(_P a, _P b) {
    final dx = b.x - a.x, dy = b.y - a.y;
    return math.sqrt(dx * dx + dy * dy);
  }

  /// Compass bearing of a metric (east, north) step.
  static double _bearingXY(double dx, double dy) =>
      (math.atan2(dx, dy) * 180 / math.pi + 360) % 360;

  static double _angleDelta(double a, double b) {
    final diff = (a - b).abs() % 360;
    return diff > 180 ? 360 - diff : diff;
  }
}

class _P {
  const _P(this.x, this.y);
  final double x;
  final double y;
}

class _Hit {
  const _Hit(this.line, this.segment, this.point, this.up);
  final int line;
  final int segment;
  final _P point;
  final bool up;
}

/// Local metric frame (east, north metres) centred on one fix — exact enough
/// over the few hundred metres a path spans.
class _Frame {
  _Frame(LatLng origin)
      : _lat0 = origin.latitude,
        _lng0 = origin.longitude,
        _kx = math.cos(origin.latitude * math.pi / 180) * 111320.0;

  final double _lat0;
  final double _lng0;
  final double _kx;
  static const double _ky = 110540.0;

  _P xy(LatLng p) => _P((p.longitude - _lng0) * _kx, (p.latitude - _lat0) * _ky);

  LatLng ll(_P p) => LatLng(_lat0 + p.y / _ky, _lng0 + p.x / _kx);
}
