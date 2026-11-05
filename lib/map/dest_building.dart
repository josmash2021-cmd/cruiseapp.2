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
