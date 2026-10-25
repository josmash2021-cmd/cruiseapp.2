import 'dart:math' as math;

import 'package:geolocator/geolocator.dart';

import '../models/lat_lng.dart';
import '../utils/route_splice.dart';

class RoadLockFix {
  const RoadLockFix({
    required this.point,
    required this.bearing,
    required this.trusted,
    required this.segmentIndex,
    required this.distanceM,
  });

  final LatLng? point;
  final double? bearing;
  final bool trusted;
  final int segmentIndex;
  final double distanceM;
}

class DriverRoadLock {
  List<LatLng> _routeRef = const [];
  List<LatLng> _points = const [];
  LatLng? _firstSnapshot;
  LatLng? _lastSnapshot;
  int _segmentIndex = -1;
  int _revision = 0;
  bool _trustedLine = false;
  LatLng? _lastPoint;
  double? _lastBearing;

  int get revision => _revision;
  LatLng? get lastPoint => _lastPoint;

  void reset() {
    _routeRef = const [];
    _points = const [];
    _firstSnapshot = null;
    _lastSnapshot = null;
    _segmentIndex = -1;
    _trustedLine = false;
    _lastPoint = null;
    _lastBearing = null;
    _revision++;
  }

  RoadLockFix project(
    List<LatLng> route,
    LatLng raw, {
    bool requireConfidence = false,
    double speedMps = 0,
  }) {
    _ensureRoute(route);
    if (_points.length < 2 ||
        !raw.latitude.isFinite ||
        !raw.longitude.isFinite) {
      return RoadLockFix(
        point: _lastPoint,
        bearing: _lastBearing,
        trusted: false,
        segmentIndex: -1,
        distanceM: double.infinity,
      );
    }

    final closest = _closest(raw);
    final threshold = _trustedLine ? 55.0 : 35.0;
    final trusted = !requireConfidence || closest.distance <= threshold;
    _trustedLine = trusted;
    if (!trusted) {
      return RoadLockFix(
        point: _lastPoint,
        bearing: _lastBearing,
        trusted: false,
        segmentIndex: -1,
        distanceM: closest.distance,
      );
    }

    _segmentIndex = closest.index;
    _lastPoint = closest.point;
    _lastBearing = _headingAt(closest.point, closest.index, speedMps);
    return RoadLockFix(
      point: closest.point,
      bearing: _lastBearing,
      trusted: true,
      segmentIndex: closest.index,
      distanceM: closest.distance,
    );
  }

  void _ensureRoute(List<LatLng> route) {
    final sameEndpoints = route.isEmpty ||
        (_same(route.first, _firstSnapshot) &&
            _same(route.last, _lastSnapshot));
    if (identical(route, _routeRef) &&
        route.length == _points.length &&
        sameEndpoints) {
      return;
    }
    _routeRef = route;
    _points = List<LatLng>.unmodifiable(route);
    _firstSnapshot = route.isEmpty ? null : route.first;
    _lastSnapshot = route.isEmpty ? null : route.last;
    _segmentIndex = -1;
    _trustedLine = false;
    _revision++;
  }

  static bool _same(LatLng? a, LatLng? b) => a == null || b == null
      ? a == b
      : a.latitude == b.latitude && a.longitude == b.longitude;

  ({LatLng point, double distance, int index}) _closest(LatLng raw) {
    ({LatLng point, double distance, int index})? best;
    void scan(int from, int to) {
      for (var i = from; i <= to; i++) {
        final point =
            RouteSplice.projectOnSegment(raw, _points[i], _points[i + 1]);
        final distance = RouteSplice.haversineM(raw, point);
        if (best == null || distance < best!.distance) {
          best = (point: point, distance: distance, index: i);
        }
      }
    }

    if (_segmentIndex < 0 || _segmentIndex >= _points.length - 1) {
      scan(0, _points.length - 2);
    } else {
      final from = math.max(0, _segmentIndex - 5);
      final to = math.min(_points.length - 2, _segmentIndex + 5);
      scan(from, to);
      if (best!.distance > 40) scan(0, _points.length - 2);
      final previous = _points[_segmentIndex];
      final next = _points[_segmentIndex + 1];
      final point = RouteSplice.projectOnSegment(raw, previous, next);
      final distance = RouteSplice.haversineM(raw, point);
      if (distance <= best!.distance + 8) {
        best = (point: point, distance: distance, index: _segmentIndex);
      }
    }
    return best!;
  }

  double? _headingAt(LatLng point, int segment, double speedMps) {
    var remaining = (speedMps * 0.8).clamp(6.0, 24.0).toDouble();
    var from = point;
    for (var i = segment; i < _points.length - 1; i++) {
      final a = _points[i];
      final b = _points[i + 1];
      final segmentLength = RouteSplice.haversineM(a, b);
      if (segmentLength < 1e-3) continue;
      final currentBearing = _bearing(a, b);
      final distanceFrom = RouteSplice.haversineM(from, b);
      if (i + 2 < _points.length) {
        final nextBearing = _bearing(b, _points[i + 2]);
        if (_angleDelta(currentBearing, nextBearing) > 25 &&
            distanceFrom < remaining) {
          return currentBearing;
        }
      }
      if (distanceFrom >= remaining) {
        return _bearing(from, b);
      }
      remaining -= distanceFrom;
      from = b;
      if (remaining <= 1e-3) return currentBearing;
    }
    for (var i = _points.length - 2; i >= 0; i--) {
      if (RouteSplice.haversineM(_points[i], _points[i + 1]) > 1e-3) {
        return _bearing(_points[i], _points[i + 1]);
      }
    }
    return null;
  }

  static double _bearing(LatLng a, LatLng b) {
    final bearing = Geolocator.bearingBetween(
        a.latitude, a.longitude, b.latitude, b.longitude);
    return (bearing + 360) % 360;
  }

  static double _angleDelta(double a, double b) {
    final diff = (a - b).abs() % 360;
    return diff > 180 ? 360 - diff : diff;
  }
}
