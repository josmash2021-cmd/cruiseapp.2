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
    this.extended = false,
  });

  final LatLng? point;
  final double? bearing;
  final bool trusted;
  final int segmentIndex;
  final double distanceM;

  /// True when [point] lies on the straight continuation PAST the end of a
  /// confidence line (see `extendPastEnd`), not on the line itself. Only the
  /// position is corrected there: [bearing] is the line's last direction,
  /// which says nothing about a turn the car starts beyond the line, so
  /// callers must not steer the arrow with it.
  final bool extended;
}

LatLng driverDisplayPosition(RoadLockFix result, LatLng rawGps) {
  if (result.trusted && result.point != null) return result.point!;
  return rawGps;
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
  bool _extensionTrusted = false;

  /// Lateral corridor around the continuation past a confidence line's end:
  /// engage within [extensionEngageM], release beyond [extensionReleaseM].
  /// Sized to GPS error (the 25 m-accuracy gate upstream), well under the
  /// width of a block, so a car that left the road is never pulled onto it.
  static const double extensionEngageM = 15.0;
  static const double extensionReleaseM = 20.0;

  /// The continuation is believed only while the car still drives along it:
  /// a course this far off the line's last direction is a turn or a curve.
  static const double extensionMaxHeadingDeg = 20.0;

  /// How far past the end the continuation reaches: the matched trace is
  /// refreshed every ~6 s, so this covers one refresh plus its latency at
  /// any speed, and no more.
  static double extensionMaxAlongM(double speedMps) =>
      math.max(120.0, 9.0 * (speedMps.isFinite ? speedMps : 0.0));

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
    _extensionTrusted = false;
    _revision++;
  }

  /// Projects [raw] onto [route].
  ///
  /// [extendPastEnd] (only meaningful with [requireConfidence]): past the
  /// last vertex of a confidence line — the map-matched trace of PAST fixes,
  /// which a moving car is always beyond — the road is taken to continue
  /// straight along the line's last direction, and [raw] is projected onto
  /// that continuation while it stays inside the lateral corridor, within
  /// reach of the end and (when [headingDeg] is given) along the car's own
  /// course. Owner report 2026-11-01 ("al hacer zoom la flecha queda fuera
  /// de las líneas"): without it a moving car was never snapped and the
  /// arrow showed the raw GPS error — metres, which at zoom 18 is a whole
  /// road width. The result is marked [RoadLockFix.extended]; it is never
  /// pinned to the end vertex (the 2026-10-29 "avanza y se detiene").
  RoadLockFix project(
    List<LatLng> route,
    LatLng raw, {
    bool requireConfidence = false,
    double speedMps = 0,
    bool extendPastEnd = false,
    double? headingDeg,
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
    // Past the END of a confidence line (owner report 2026-10-29: the arrow
    // "avanza, se detiene, vuelve a avanzar" on the online/offline map).
    // That line is the map-matched trace of PAST fixes, refreshed every ~6 s,
    // so a moving car is always beyond its last vertex — and the segment
    // projection clamps there. The marker sat pinned on that vertex for up to
    // 55 m, then jumped when the next match landed. Beyond the end the line
    // says nothing about the car: hand back untrusted so the display follows
    // the real motion — unless the caller asked for the straight
    // continuation (extendPastEnd), which projects instead of clamping and
    // is checked against the car itself. A live route (no
    // requireConfidence) still clamps.
    if (requireConfidence && _pastLineEnd(raw, closest.index)) {
      if (extendPastEnd) {
        final ext = _projectPastEnd(raw, speedMps, headingDeg);
        if (ext != null) return ext;
      }
      return RoadLockFix(
        point: _lastPoint,
        bearing: _lastBearing,
        trusted: false,
        segmentIndex: -1,
        distanceM: closest.distance,
      );
    }
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

  /// True when [raw] lies beyond the last vertex along the last segment's
  /// direction — the case where the projection is clamped to the end.
  bool _pastLineEnd(LatLng raw, int segment) {
    if (segment != _points.length - 2) return false;
    final a = _points[segment];
    final b = _points[segment + 1];
    final cosLat = math.cos(b.latitude * math.pi / 180);
    final sx = (b.longitude - a.longitude) * cosLat;
    final sy = b.latitude - a.latitude;
    if (sx * sx + sy * sy < 1e-14) return false;
    final rx = (raw.longitude - b.longitude) * cosLat;
    final ry = raw.latitude - b.latitude;
    return sx * rx + sy * ry > 0;
  }

  /// [raw] projected onto the straight continuation of the line past its
  /// last vertex, or null when the continuation cannot vouch for it (see
  /// `extendPastEnd` on [project]).
  RoadLockFix? _projectPastEnd(
      LatLng raw, double speedMps, double? headingDeg) {
    final n = _points.length;
    final end = _points[n - 1];
    // Direction from ~10 m back along the line, not the last segment alone:
    // matched geometry can end on a stub a metre long whose direction is
    // noise.
    var i = n - 2;
    while (i > 0 && RouteSplice.haversineM(_points[i], end) < 10.0) {
      i--;
    }
    final from = _points[i];
    if (RouteSplice.haversineM(from, end) < 3.0) {
      _extensionTrusted = false;
      return null;
    }
    final cosLat = math.cos(end.latitude * math.pi / 180);
    var ux = (end.longitude - from.longitude) * cosLat * 111320.0;
    var uy = (end.latitude - from.latitude) * 110540.0;
    final len = math.sqrt(ux * ux + uy * uy);
    ux /= len;
    uy /= len;
    final rx = (raw.longitude - end.longitude) * cosLat * 111320.0;
    final ry = (raw.latitude - end.latitude) * 110540.0;
    final along = rx * ux + ry * uy;
    final lateral = (rx * uy - ry * ux).abs();
    final rayBearing = (math.atan2(ux, uy) * 180 / math.pi + 360) % 360;
    final corridor =
        _extensionTrusted ? extensionReleaseM : extensionEngageM;
    final headingOk = headingDeg == null ||
        !headingDeg.isFinite ||
        _angleDelta(headingDeg % 360, rayBearing) <= extensionMaxHeadingDeg;
    if (along < 0 ||
        along > extensionMaxAlongM(speedMps) ||
        lateral > corridor ||
        !headingOk) {
      _extensionTrusted = false;
      return null;
    }
    _extensionTrusted = true;
    return RoadLockFix(
      point: LatLng(
        end.latitude + along * uy / 110540.0,
        end.longitude + along * ux / (111320.0 * cosLat),
      ),
      bearing: rayBearing,
      trusted: true,
      segmentIndex: n - 2,
      distanceM: lateral,
      extended: true,
    );
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
      // Lane continuity: keep the segment the car was on unless another is
      // clearly (8 m) closer — divided highways used to flip the marker
      // between carriageways. ONLY while the point still projects INSIDE
      // that segment (owner report 2026-11-01, "gira por pasos"): past its
      // end the projection clamps on the end vertex, and the 8 m slack held
      // the arrow there for ~8 m of driving before it jumped to the next
      // segment — on a curve, where vertices are 5–15 m apart, the arrow,
      // the camera centre and the heading all moved in steps, one per
      // vertex. Driving on into the next segment is the same road.
      final previous = _points[_segmentIndex];
      final next = _points[_segmentIndex + 1];
      if (_insideSegment(raw, previous, next)) {
        final point = RouteSplice.projectOnSegment(raw, previous, next);
        final distance = RouteSplice.haversineM(raw, point);
        if (distance <= best!.distance + 8) {
          best = (point: point, distance: distance, index: _segmentIndex);
        }
      }
    }
    return best!;
  }

  /// Whether [p]'s perpendicular foot on [a]→[b] falls within the segment
  /// (same equirectangular frame as [RouteSplice.projectOnSegment]).
  static bool _insideSegment(LatLng p, LatLng a, LatLng b) {
    final cosLat = math.cos((a.latitude + b.latitude) / 2 * math.pi / 180);
    final dy = b.latitude - a.latitude;
    final dx = (b.longitude - a.longitude) * cosLat;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return false;
    final t = ((p.longitude - a.longitude) * cosLat * dx +
            (p.latitude - a.latitude) * dy) /
        len2;
    return t >= 0 && t <= 1;
  }

  /// The arrow's heading at [point]: the CHORD from [point] to the spot
  /// [speedMps]·0.8 s (6–24 m) further along the line, so it rotates
  /// continuously as the car advances. Owner report 2026-11-01 ("la cámara
  /// gira por pasos"): this used to return the bearing of whichever SEGMENT
  /// the look-ahead landed on — constant along each segment, then a jump of
  /// the whole vertex angle each time the look-ahead crossed a vertex. The
  /// arrow turned in bursts, one per vertex, and the chase camera with it.
  /// A real corner (> 25°) inside the look-ahead still stops the aim AT the
  /// corner: the arrow never turns before the car gets there.
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
      if (distanceFrom >= remaining) {
        final f = distanceFrom > 1e-6 ? remaining / distanceFrom : 0.0;
        final aim = LatLng(
          from.latitude + (b.latitude - from.latitude) * f,
          from.longitude + (b.longitude - from.longitude) * f,
        );
        return _chord(point, aim) ?? currentBearing;
      }
      if (i + 2 < _points.length) {
        final nextBearing = _nextBearing(i + 1);
        if (nextBearing != null &&
            _angleDelta(currentBearing, nextBearing) > 25) {
          return _chord(point, b) ?? currentBearing;
        }
      }
      remaining -= distanceFrom;
      from = b;
      if (remaining <= 1e-3) return _chord(point, b) ?? currentBearing;
    }
    // The look-ahead ran past the line's end: aim at the end itself.
    for (var i = _points.length - 2; i >= 0; i--) {
      if (RouteSplice.haversineM(_points[i], _points[i + 1]) > 1e-3) {
        return _chord(point, _points.last) ??
            _bearing(_points[i], _points[i + 1]);
      }
    }
    return null;
  }

  /// Bearing of the first non-degenerate segment starting at vertex [start]
  /// (a repeated vertex used to read as a 0°/north segment — a phantom
  /// corner).
  double? _nextBearing(int start) {
    for (var j = start; j < _points.length - 1; j++) {
      if (RouteSplice.haversineM(_points[j], _points[j + 1]) > 1e-3) {
        return _bearing(_points[j], _points[j + 1]);
      }
    }
    return null;
  }

  /// [from]→[to] bearing, or null when the two are too close (< 0.5 m) for
  /// a direction to mean anything.
  static double? _chord(LatLng from, LatLng to) {
    if (RouteSplice.haversineM(from, to) < 0.5) return null;
    return _bearing(from, to);
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
