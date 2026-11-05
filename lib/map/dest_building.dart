import 'dart:math' as math;

import '../models/lat_lng.dart';

/// The building at the trip's address, outlined in gold on the navigation
/// map (owner 2026-11-04, Lyft's "la estructura de la dirección exacta").
/// The footprints come from the map's own `building` layer
/// (`queryRenderedFeatures` in a small box around the address) — no
/// network, no cost.
class DestBuilding {
  DestBuilding._();

  /// The footprint at [dest]: the one containing it, else the nearest
  /// whose edge is within [maxM] metres (an address point often sits at the
  /// front of the lot). A footprint cut by a tile edge comes back in
  /// pieces sharing one feature id — all of them are returned. Null when
  /// no building qualifies.
  static List<List<LatLng>>? pick(
    Iterable<Object?> features,
    LatLng dest, {
    double maxM = 25,
  }) {
    final rings = _parse(features);
    ({Object? id, List<LatLng> ring})? best;
    var bestD = double.infinity;
    for (final r in rings) {
      final d = contains(r.ring, dest) ? 0.0 : edgeDistanceM(r.ring, dest);
      if (d < bestD) {
        bestD = d;
        best = r;
      }
    }
    if (best == null || bestD > maxM) return null;
    final chosen = best;
    final pieces = chosen.id == null
        ? [chosen.ring]
        : [
            for (final r in rings)
              if (r.id == chosen.id) r.ring,
          ];
    // The same footprint can come back once per layer that draws it.
    final seen = <String>{};
    return [
      for (final p in pieces)
        if (seen.add('${p.length}:${p.first.latitude}:${p.first.longitude}')) p,
    ];
  }

  static List<({Object? id, List<LatLng> ring})> _parse(
      Iterable<Object?> features) {
    final rings = <({Object? id, List<LatLng> ring})>[];
    for (final feat in features) {
      if (feat is! Map) continue;
      final geom = feat['geometry'];
      if (geom is! Map) continue;
      final coords = geom['coordinates'];
      if (coords is! List) continue;
      final id = feat['id'];
      switch (geom['type']) {
        case 'Polygon':
          final r = _outer(coords);
          if (r != null) rings.add((id: id, ring: r));
        case 'MultiPolygon':
          for (final poly in coords) {
            if (poly is! List) continue;
            final r = _outer(poly);
            if (r != null) rings.add((id: id, ring: r));
          }
      }
    }
    return rings;
  }

  /// Every footprint's outer ring among queried building features.
  static List<List<LatLng>> footprints(Iterable<Object?> features) =>
      [for (final r in _parse(features)) r.ring];

  /// Where the drawn route must end (owner 2026-11-04: "la línea de la ruta
  /// no debe salirse de las calles… ni estar encima de la estructura
  /// marcada ni otra estructura… sino donde se debe parar"): [clearM]
  /// metres before the route first runs into a building within its last
  /// [tailM] metres — the driveway or service lane the router snapped the
  /// address to. Null when it never does.
  static double? tailCutS(
    List<LatLng> route,
    List<List<LatLng>> footprints, {
    double tailM = 200,
    double clearM = 3,
  }) {
    if (route.length < 2 || footprints.isEmpty) return null;
    final total = lengthM(route);
    final from = math.max(0.0, total - tailM);
    final ref = route.last;
    const mPerDeg = 111320.0;
    final kx = mPerDeg * math.cos(ref.latitude * math.pi / 180);
    ({double x, double y}) xy(LatLng q) => (
          x: (q.longitude - ref.longitude) * kx,
          y: (q.latitude - ref.latitude) * mPerDeg,
        );
    final polys = [
      for (final f in footprints) [for (final p in f) xy(p)],
    ];
    var s = 0.0;
    for (var i = 0; i + 1 < route.length; i++) {
      final seg = _distM(route[i], route[i + 1]);
      if (s + seg >= from && seg > 0) {
        final a = xy(route[i]);
        final b = xy(route[i + 1]);
        // Only the part of this segment inside the tail window.
        final t0 = s >= from ? 0.0 : (from - s) / seg;
        final ax = a.x + (b.x - a.x) * t0, ay = a.y + (b.y - a.y) * t0;
        var hit = double.infinity;
        for (var k = 0; k < polys.length; k++) {
          if (contains(footprints[k], _lerp(route[i], route[i + 1], t0))) {
            hit = 0;
            break;
          }
          final poly = polys[k];
          for (var e = 0; e + 1 < poly.length; e++) {
            final u = _segHit(ax, ay, b.x, b.y, poly[e].x, poly[e].y,
                poly[e + 1].x, poly[e + 1].y);
            if (u != null && u < hit) hit = u;
          }
        }
        if (hit.isFinite) {
          final t = t0 + (1 - t0) * hit;
          return math.max(0.0, s + seg * t - clearM);
        }
      }
      s += seg;
    }
    return null;
  }

  /// [pts] between arc-lengths [fromS] and [toS] (null = to the end), ends
  /// interpolated.
  static List<LatLng> slice(List<LatLng> pts, double fromS, double? toS) {
    final out = <LatLng>[];
    if (pts.length < 2) return out;
    final end = toS ?? double.infinity;
    if (end <= fromS) return out;
    var s = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      final a = pts[i];
      final b = pts[i + 1];
      final seg = _distM(a, b);
      final s1 = s + seg;
      if (s1 >= fromS && s <= end) {
        if (out.isEmpty) {
          out.add(seg <= 0 || fromS <= s
              ? a
              : _lerp(a, b, ((fromS - s) / seg).clamp(0.0, 1.0)));
        }
        if (end < s1) {
          out.add(_lerp(a, b, seg <= 0 ? 0.0 : (end - s) / seg));
          return out;
        }
        out.add(b);
      }
      s = s1;
    }
    return out;
  }

  /// The point [s] metres along [pts] (clamped to its ends).
  static LatLng? pointAt(List<LatLng> pts, double s) {
    if (pts.isEmpty) return null;
    var acc = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      final seg = _distM(pts[i], pts[i + 1]);
      if (acc + seg >= s) {
        return _lerp(pts[i], pts[i + 1],
            seg <= 0 ? 0.0 : ((s - acc) / seg).clamp(0.0, 1.0));
      }
      acc += seg;
    }
    return pts.last;
  }

  static double lengthM(List<LatLng> pts) {
    var m = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      m += _distM(pts[i], pts[i + 1]);
    }
    return m;
  }

  static LatLng _lerp(LatLng a, LatLng b, double t) => LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );

  static double _distM(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.pow(math.sin(dLat / 2), 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.pow(math.sin(dLng / 2), 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  /// Where along p0→p1 (0..1) it crosses q0→q1, or null.
  static double? _segHit(double p0x, double p0y, double p1x, double p1y,
      double q0x, double q0y, double q1x, double q1y) {
    final rx = p1x - p0x, ry = p1y - p0y;
    final sx = q1x - q0x, sy = q1y - q0y;
    final den = rx * sy - ry * sx;
    if (den.abs() < 1e-12) return null;
    final qpx = q0x - p0x, qpy = q0y - p0y;
    final t = (qpx * sy - qpy * sx) / den;
    final u = (qpx * ry - qpy * rx) / den;
    if (t < 0 || t > 1 || u < 0 || u > 1) return null;
    return t;
  }

  static List<LatLng>? _outer(List poly) {
    if (poly.isEmpty || poly.first is! List) return null;
    final pts = <LatLng>[];
    for (final c in poly.first as List) {
      if (c is List && c.length >= 2 && c[0] is num && c[1] is num) {
        final lng = (c[0] as num).toDouble();
        final lat = (c[1] as num).toDouble();
        if (lat.isFinite && lng.isFinite) pts.add(LatLng(lat, lng));
      }
    }
    if (pts.length < 3) return null;
    // Closed, as a polygon and its outline need.
    if (pts.first != pts.last) pts.add(pts.first);
    return pts.length >= 4 ? pts : null;
  }

  /// Ray casting in lng/lat — exact enough over one building.
  static bool contains(List<LatLng> ring, LatLng p) {
    var inside = false;
    for (var i = 0, j = ring.length - 1; i < ring.length; j = i++) {
      final a = ring[i];
      final b = ring[j];
      if ((a.latitude > p.latitude) != (b.latitude > p.latitude)) {
        final x = (b.longitude - a.longitude) *
                (p.latitude - a.latitude) /
                (b.latitude - a.latitude) +
            a.longitude;
        if (p.longitude < x) inside = !inside;
      }
    }
    return inside;
  }

  /// Metres from [p] to the ring's nearest edge (local flat projection).
  static double edgeDistanceM(List<LatLng> ring, LatLng p) {
    const mPerDeg = 111320.0;
    final kx = mPerDeg * math.cos(p.latitude * math.pi / 180);
    double x(LatLng q) => (q.longitude - p.longitude) * kx;
    double y(LatLng q) => (q.latitude - p.latitude) * mPerDeg;
    var best = double.infinity;
    for (var i = 0; i + 1 < ring.length; i++) {
      final ax = x(ring[i]), ay = y(ring[i]);
      final bx = x(ring[i + 1]), by = y(ring[i + 1]);
      final dx = bx - ax, dy = by - ay;
      final len2 = dx * dx + dy * dy;
      final t = len2 == 0
          ? 0.0
          : ((-ax * dx - ay * dy) / len2).clamp(0.0, 1.0);
      final cx = ax + dx * t, cy = ay + dy * t;
      best = math.min(best, math.sqrt(cx * cx + cy * cy));
    }
    return best;
  }
}
