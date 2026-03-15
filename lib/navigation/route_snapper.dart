import 'dart:math' as math;
import 'package:google_maps_flutter/google_maps_flutter.dart';

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

    // Search window: start a few segments back from lastIndex
    // If last offset was large, search all segments to find the true closest
    final searchStart = (lastIndex - 5).clamp(0, route.length - 2);

    double bestDist = double.infinity;
    LatLng bestPoint = route[searchStart];
    int bestSeg = searchStart;

    for (int i = searchStart; i < route.length - 1; i++) {
      final proj = _projectOnSegment(raw, route[i], route[i + 1]);
      final d = _haversineM(raw, proj);
      if (d < bestDist) {
        bestDist = d;
        bestPoint = proj;
        bestSeg = i;
      }
      // If we're past lastIndex by a lot and distance is increasing, stop early
      if (i > lastIndex + 30 && d > bestDist * 3) break;
    }

    final bearing = _computeBearing(
      route[bestSeg],
      route[(bestSeg + 1).clamp(0, route.length - 1)],
    );

    return SnapResult(
      snapped: bestPoint,
      segmentIndex: bestSeg,
      bearingDeg: bearing,
      offsetMeters: bestDist,
    );
  }

  /// Project point [p] onto the line segment [a]-[b], returning the closest
  /// point on the segment.
  static LatLng _projectOnSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.latitude - a.latitude;
    final dy = b.longitude - a.longitude;
    if (dx == 0 && dy == 0) return a;

    final t = ((p.latitude - a.latitude) * dx + (p.longitude - a.longitude) * dy) /
        (dx * dx + dy * dy);
    final clamped = t.clamp(0.0, 1.0);

    return LatLng(
      a.latitude + clamped * dx,
      a.longitude + clamped * dy,
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
