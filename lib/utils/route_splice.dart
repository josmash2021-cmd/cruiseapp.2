import 'dart:math' as math;

import '../models/lat_lng.dart';

/// Geometry helpers for Uber-style partial re-routing.
///
/// When the driver leaves the planned route, only the affected stretch of
/// the polyline should be redrawn: the part already driven keeps its usual
/// treatment (erased behind the car), and the part of the old route past
/// the point where the new route rejoins it stays untouched. This class
/// finds those two cut points and splices the polyline pieces together.
///
/// Pure maths, no Flutter — unit-tested in test/route_splice_test.dart.
class RouteSplice {
  RouteSplice._();

  /// Haversine distance in meters.
  static double haversineM(LatLng a, LatLng b) {
    const r = 6371000.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(h));
  }

  /// Closest point to [p] on segment [a]→[b], equirectangular approximation
  /// (cosine-latitude corrected). Accurate to well under a meter at the
  /// distances a route polyline samples the road at.
  static LatLng projectOnSegment(LatLng p, LatLng a, LatLng b) {
    final cosLat = math.cos((a.latitude + b.latitude) / 2 * math.pi / 180);
    final dy = b.latitude - a.latitude;
    final dx = (b.longitude - a.longitude) * cosLat;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return a;
    final py = p.latitude - a.latitude;
    final px = (p.longitude - a.longitude) * cosLat;
    final t = ((px * dx + py * dy) / len2).clamp(0.0, 1.0);
    return LatLng(a.latitude + t * dy, a.longitude + t * (b.longitude - a.longitude));
  }

  /// Perpendicular distance from [p] to the closest point on [polyline],
  /// in meters. Segment-projection based — a vertex-only check overestimates
  /// the distance in the middle of long straight segments and would fire
  /// false off-route alerts there.
  static double distanceToPolylineM(List<LatLng> polyline, LatLng p) {
    if (polyline.isEmpty) return double.infinity;
    if (polyline.length == 1) return haversineM(p, polyline.first);
    var best = double.infinity;
    for (var i = 0; i + 1 < polyline.length; i++) {
      final d = haversineM(p, projectOnSegment(p, polyline[i], polyline[i + 1]));
      if (d < best) best = d;
    }
    return best;
  }

  /// Index i of the segment [i → i+1] of [polyline] whose projection is
  /// closest to [p]. This is the "deviation point": where the driver left
  /// the route.
  static int closestSegmentIndex(List<LatLng> polyline, LatLng p) {
    if (polyline.length < 2) return 0;
    var best = double.infinity;
    var bestIdx = 0;
    for (var i = 0; i + 1 < polyline.length; i++) {
      final d = haversineM(p, projectOnSegment(p, polyline[i], polyline[i + 1]));
      if (d < best) {
        best = d;
        bestIdx = i;
      }
    }
    return bestIdx;
  }

  /// Splice [newRoute] into [oldRoute] around the driver's deviation.
  ///
  /// The result is:
  ///   oldRoute[0 … deviation]          (already-driven head — the caller's
  ///                                    erase-behind-the-car keeps hiding it)
  /// + newRoute[0 … rejoin]             (the fresh path from the driver's
  ///                                    off-route position back to the plan)
  /// + oldRoute[rejoinSegment+1 … end]  (the untouched tail)
  ///
  /// The rejoin is the first point of [newRoute] that comes within
  /// [rejoinMeters] of the old route at or past the deviation segment. When
  /// no point qualifies — a genuinely different route — the new route
  /// replaces the old one wholesale, which is also the correct outcome.
  static List<LatLng> splice({
    required List<LatLng> oldRoute,
    required List<LatLng> newRoute,
    required LatLng driverPos,
    double rejoinMeters = 15.0,
  }) {
    if (newRoute.length < 2) return List.of(oldRoute);
    if (oldRoute.length < 2) return List.of(newRoute);

    final devIdx = closestSegmentIndex(oldRoute, driverPos);

    for (var j = 0; j < newRoute.length; j++) {
      final np = newRoute[j];
      for (var k = devIdx; k + 1 < oldRoute.length; k++) {
        final proj = projectOnSegment(np, oldRoute[k], oldRoute[k + 1]);
        if (haversineM(np, proj) <= rejoinMeters) {
          return <LatLng>[
            ...oldRoute.sublist(0, devIdx + 1),
            ...newRoute.sublist(0, j + 1),
            ...oldRoute.sublist(k + 1),
          ];
        }
      }
    }
    // No rejoin within tolerance — replace completely.
    return List.of(newRoute);
  }
}
