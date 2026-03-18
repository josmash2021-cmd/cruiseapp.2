import 'dart:math' as math;
import '../models/lat_lng.dart';

/// Result of snapping a raw GPS position to the nearest point on a route.
class SnapResult {
  /// The snapped position on the route polyline.
  final LatLng snapped;

  /// The segment index on the route where the snap occurred.
  final int segmentIndex;

  /// Bearing in degrees at the snapped point (direction of the segment).
  final double bearingDeg;

  /// Distance in meters from the raw position to the snapped point.
  final double offsetMeters;

  const SnapResult({
    required this.snapped,
    required this.segmentIndex,
    required this.bearingDeg,
    required this.offsetMeters,
  });
}

/// Snaps a raw GPS coordinate to the closest point on a polyline route.
class RouteSnapper {
  /// Snap [raw] to the nearest point on [route].
  ///
  /// [lastIndex] is a hint for the last known segment index to speed up search.
  /// Returns a [SnapResult] with the snapped position, segment index, and bearing.
  static SnapResult snap(
    LatLng raw,
    List<LatLng> route, {
    int lastIndex = 0,
  }) {
    if (route.isEmpty) {
      return SnapResult(
        snapped: raw,
        segmentIndex: 0,
        bearingDeg: 0,
        offsetMeters: 0,
      );
    }
    if (route.length == 1) {
      return SnapResult(
        snapped: route[0],
        segmentIndex: 0,
        bearingDeg: 0,
        offsetMeters: _haversineM(raw, route[0]),
      );
    }

    // Search window: start a few segments back from lastIndex.
    // Look ahead generously (80 segments) to handle tunnels/GPS jumps.
    final searchStart = (lastIndex - 5).clamp(0, route.length - 2);
    final searchEnd = math.min(searchStart + 80, route.length - 1);

    double bestDist = double.infinity;
    LatLng bestPoint = route[searchStart];
    int bestSeg = searchStart;

    for (int i = searchStart; i < searchEnd; i++) {
      final proj = _projectOnSegment(raw, route[i], route[i + 1]);
      final d = _haversineM(raw, proj);
      if (d < bestDist) {
        bestDist = d;
        bestPoint = proj;
        bestSeg = i;
      }
    }

    // Smooth heading: blend current segment bearing with look-ahead.
    // This prevents abrupt 90° bearing snaps at corners.
    final bearing = _smoothBearing(route, bestSeg);

    return SnapResult(
      snapped: bestPoint,
      segmentIndex: bestSeg,
      bearingDeg: bearing,
      offsetMeters: bestDist,
    );
  }

  /// Compute a smoothed heading by averaging the current segment bearing
  /// with the next segment bearing, weighted by segment length.
  static double _smoothBearing(List<LatLng> route, int segIdx) {
    final next = (segIdx + 1).clamp(0, route.length - 1);
    final b0 = _computeBearing(route[segIdx], route[next]);
    if (segIdx + 2 >= route.length) return b0;

    final b1 = _computeBearing(route[next], route[segIdx + 2]);
    // Only blend if the two bearings are within 45° — prevents blending
    // through a sharp turn and pointing diagonally.
    double diff = (b1 - b0).abs();
    if (diff > 180) diff = 360 - diff;
    if (diff > 45) return b0; // sharp turn: use current segment only

    // Weight current segment more (70/30 blend)
    final blended = b0 * 0.7 + b1 * 0.3;
    return blended % 360;
  }

  /// Project [p] onto segment [a]-[b], returning the closest point on
  /// the segment.
  ///
  /// Uses cosine-latitude correction so that 1° longitude and 1° latitude
  /// map to the same metric distance. Without this correction the projection
  /// is skewed on East-West roads, causing the vehicle to appear to drift
  /// sideways or snap to the wrong segment.
  static LatLng _projectOnSegment(LatLng p, LatLng a, LatLng b) {
    // Scale longitude by cos(midLat) to make the space isotropic
    final cosLat = math.cos(_r((a.latitude + b.latitude) / 2.0));

    final dLat = b.latitude - a.latitude;
    final dLng = (b.longitude - a.longitude) * cosLat;
    if (dLat.abs() < 1e-10 && dLng.abs() < 1e-10) return a;

    final pLat = p.latitude - a.latitude;
    final pLng = (p.longitude - a.longitude) * cosLat;

    final t = (pLat * dLat + pLng * dLng) / (dLat * dLat + dLng * dLng);
    final clamped = t.clamp(0.0, 1.0);

    return LatLng(
      a.latitude + clamped * (b.latitude - a.latitude),
      a.longitude + clamped * (b.longitude - a.longitude),
    );
  }

  static double _computeBearing(LatLng from, LatLng to) {
    final dLng = _r(to.longitude - from.longitude);
    final y = math.sin(dLng) * math.cos(_r(to.latitude));
    final x = math.cos(_r(from.latitude)) * math.sin(_r(to.latitude)) -
        math.sin(_r(from.latitude)) * math.cos(_r(to.latitude)) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  static double _haversineM(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = _r(b.latitude - a.latitude);
    final dLng = _r(b.longitude - a.longitude);
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_r(a.latitude)) *
            math.cos(_r(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  static double _r(double d) => d * math.pi / 180;
}
