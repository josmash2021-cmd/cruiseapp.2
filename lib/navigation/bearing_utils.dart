import 'dart:math' as math;

import 'package:google_maps_flutter/google_maps_flutter.dart';

/// Pure bearing / angle utilities for route-following navigation.
abstract final class BearingUtils {
  BearingUtils._();

  // ─── Core bearing ──────────────────────────────────────────────────

  /// Compass bearing in degrees [0, 360) from [a] to [b].
  /// 0 = north, 90 = east, 180 = south, 270 = west.
  static double bearingBetween(LatLng a, LatLng b) {
    final lat1 = _r(a.latitude);
    final lat2 = _r(b.latitude);
    final dLng = _r(b.longitude - a.longitude);
    final y = math.sin(dLng) * math.cos(lat2);
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * _deg + 360) % 360;
  }

  // ─── Look-ahead bearing ────────────────────────────────────────────

  /// Computes the bearing from [snapPt] looking ahead [aheadMeters] along
  /// [route] starting at [segIdx].  Returns the current segment bearing if
  /// the route is too short.
  static double lookAheadBearing(
    LatLng snapPt,
    int segIdx,
    List<LatLng> route, {
    double aheadMeters = 25.0,
  }) {
    if (route.length < 2) return 0;
    final clampedIdx = segIdx.clamp(0, route.length - 2);

    // Walk forward along the polyline until we've covered aheadMeters
    double walked = _haversineM(snapPt, route[clampedIdx + 1]);
    LatLng lookPt = route[clampedIdx + 1];
    int i = clampedIdx + 1;

    while (walked < aheadMeters && i < route.length - 1) {
      final seg = _haversineM(route[i], route[i + 1]);
      if (walked + seg >= aheadMeters) {
        final need = aheadMeters - walked;
        final frac = need / seg;
        lookPt = LatLng(
          route[i].latitude +
              (route[i + 1].latitude - route[i].latitude) * frac,
          route[i].longitude +
              (route[i + 1].longitude - route[i].longitude) * frac,
        );
        walked = aheadMeters;
        break;
      } else {
        walked += seg;
        lookPt = route[i + 1];
      }
      i++;
    }

    // If look-ahead <= 1m, fall back to raw segment bearing
    if (_haversineM(snapPt, lookPt) < 1.0) {
      return bearingBetween(route[clampedIdx], route[clampedIdx + 1]);
    }
    return bearingBetween(snapPt, lookPt);
  }

  // ─── Smooth bearing ────────────────────────────────────────────────

  /// Interpolate [current] toward [target] using shortest-arc path.
  ///
  /// [dt] is the frame delta in seconds.
  /// [maxDegPerSec] clamps maximum rotation speed (default 180°/s).
  static double smoothBearing(
    double current,
    double target,
    double dt, {
    double maxDegPerSec = 180,
  }) {
    double diff = _shortestArc(current, target);
    final maxStep = maxDegPerSec * dt;
    if (diff.abs() > maxStep) {
      diff = diff.sign * maxStep;
    }
    return (current + diff + 360) % 360;
  }

  /// Returns the shortest signed angle delta from [from] to [to] (range -180..180).
  static double _shortestArc(double from, double to) {
    double d = (to - from) % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return d;
  }

  /// Lerp between bearings on the shortest arc. [t] in 0..1.
  static double lerpBearing(double from, double to, double t) {
    return (from + _shortestArc(from, to) * t + 360) % 360;
  }

  // ─── Helpers ───────────────────────────────────────────────────────

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

  static const double _deg = 180 / math.pi;
  static double _r(double d) => d * math.pi / 180;
}
