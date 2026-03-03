import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'bearing_utils.dart';

/// Forward-only route snapper.
/// Never produces a segmentIndex less than lastIndex.
/// bearingDeg is always derived from route tangent via look-ahead.
class RouteSnapper {
  RouteSnapper._();

  static SnapResult snap(
    LatLng raw,
    List<LatLng> route, {
    int lastIndex = 0,
    double maxSnapMeters = 60,
    double lookaheadMeters = 400,
    double bearingAheadMeters = 25,
  }) {
    if (route.length < 2) {
      return SnapResult(snapped: raw, segmentIndex: 0,
          distanceMeters: 0, isOnRoute: false, bearingDeg: 0,
          distanceAlongRouteMeters: 0);
    }

    final int startIdx = lastIndex.clamp(0, route.length - 2);

    // Build forward window up to lookaheadMeters ahead
    double walked = 0;
    int windowEnd = startIdx;
    for (int i = startIdx; i < route.length - 1; i++) {
      walked += _haversineM(route[i], route[i + 1]);
      windowEnd = i;
      if (walked >= lookaheadMeters) break;
    }

    double bestDist = double.infinity;
    LatLng bestPt = raw;
    int bestIdx = startIdx;

    // Search only forward window
    for (int i = startIdx; i <= windowEnd; i++) {
      final proj = _closestPointOnSegment(raw, route[i], route[i + 1]);
      final d = _haversineM(raw, proj);
      if (d < bestDist) { bestDist = d; bestPt = proj; bestIdx = i; }
    }

    // Off-route recovery: extend search further forward only
    if (bestDist > maxSnapMeters) {
      for (int i = windowEnd + 1; i < route.length - 1; i++) {
        final proj = _closestPointOnSegment(raw, route[i], route[i + 1]);
        final d = _haversineM(raw, proj);
        if (d < bestDist) { bestDist = d; bestPt = proj; bestIdx = i; }
      }
    }

    final snapped = bestDist <= maxSnapMeters ? bestPt : raw;
    final onRoute = bestDist <= maxSnapMeters;

    // Route-tangent bearing via look-ahead (never raw GPS delta)
    final bearing = BearingUtils.lookAheadBearing(
      snapped, bestIdx, route, aheadMeters: bearingAheadMeters);

    double along = 0;
    for (int i = 0; i < bestIdx; i++) {
      along += _haversineM(route[i], route[i + 1]);
    }
    along += _haversineM(route[bestIdx], snapped);

    return SnapResult(snapped: snapped, segmentIndex: bestIdx,
        distanceMeters: bestDist, isOnRoute: onRoute,
        bearingDeg: bearing, distanceAlongRouteMeters: along);
  }

  static double totalRouteMeters(List<LatLng> route) {
    double t = 0;
    for (int i = 0; i < route.length - 1; i++) t += _haversineM(route[i], route[i + 1]);
    return t;
  }

  static double remainingMeters(LatLng snapped, int segIdx, List<LatLng> route) {
    if (route.length < 2) return 0;
    final idx = segIdx.clamp(0, route.length - 2);
    double rem = _haversineM(snapped, route[idx + 1]);
    for (int i = idx + 1; i < route.length - 1; i++) rem += _haversineM(route[i], route[i + 1]);
    return rem;
  }

  static LatLng _closestPointOnSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.latitude - a.latitude;
    final dy = b.longitude - a.longitude;
    if (dx == 0 && dy == 0) return a;
    final t = ((p.latitude - a.latitude) * dx + (p.longitude - a.longitude) * dy) / (dx * dx + dy * dy);
    return LatLng(a.latitude + dx * t.clamp(0.0, 1.0), a.longitude + dy * t.clamp(0.0, 1.0));
  }

  static double _haversineM(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = _r(b.latitude - a.latitude);
    final dLng = _r(b.longitude - a.longitude);
    final x = math.sin(dLat/2)*math.sin(dLat/2) +
        math.cos(_r(a.latitude))*math.cos(_r(b.latitude))*math.sin(dLng/2)*math.sin(dLng/2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1-x));
  }

  static double _r(double d) => d * math.pi / 180;
}

class SnapResult {
  const SnapResult({
    required this.snapped, required this.segmentIndex,
    required this.distanceMeters, required this.isOnRoute,
    this.bearingDeg = 0, this.distanceAlongRouteMeters = 0,
  });
  final LatLng snapped;
  final int segmentIndex;
  final double distanceMeters;
  final bool isOnRoute;
  final double bearingDeg;
  final double distanceAlongRouteMeters;
}
