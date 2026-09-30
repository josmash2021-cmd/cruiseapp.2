import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;

import '../config/mapbox_config.dart';
import '../models/lat_lng.dart';

/// Road-snap for the driver map while SEARCHING (no route to project onto).
///
/// User report (2026-09-27): zoomed all the way in, the arrow sits visibly
/// off the road lines — the raw fix wanders inside its ±5-25 m of GPS error
/// and there is no route polyline to snap to (the route snap only exists on
/// offer/enRoute/inTrip). Real driver apps map-match the puck; this is the
/// Cruise version of that.
///
/// Per-fix matching calls would burn rate/billing quota and still read as
/// steps, so this works like the real thing: it buffers the recent trace
/// (≤10 good fixes), asks for a matched polyline at most once every 6 s —
/// only while actually moving — and the controller projects each new fix
/// onto that line locally between refreshes. The arrow therefore glides
/// along real roads, not along the GPS noise. Mapbox Map Matching first
/// (same token as every other map call), the OSRM demo as the fallback
/// (same provider the directions fallback already uses), raw GPS when both
/// fail — the old line simply stays until the next success.
class RoadSnapService {
  static const _traceMax = 10;
  static const _minInterval = Duration(seconds: 6);

  /// The trace must span at least this much ground before a matching call
  /// is worth firing: a parked or crawling driver is owned by the
  /// stationary freeze, not by this service, and matching calls are not
  /// free.
  static const _minTraceSpanM = 12.0;

  /// Radius sent for a fix whose accuracy is unknown/absurd — matches the
  /// controller's own usability gate (fixes worse than 25 m never arrive).
  static const _defaultRadiusM = 25;

  final List<({double lat, double lng, double acc, int tsMs})> _trace = [];
  DateTime _lastCall = DateTime.fromMillisecondsSinceEpoch(0);
  bool _busy = false;
  int _seq = 0;

  /// The latest matched polyline, newest last. The controller replaces its
  /// projection line with whatever arrives here.
  void Function(List<LatLng> line)? onLine;

  /// Feed a usable fix (accuracy already gated by the caller). Cheap unless
  /// the scheduler fires.
  void onFix(Position pos) {
    if (_trace.length >= _traceMax) _trace.removeAt(0);
    _trace.add((
      lat: pos.latitude,
      lng: pos.longitude,
      acc: pos.accuracy,
      tsMs: pos.timestamp.millisecondsSinceEpoch,
    ));
    _maybeMatch();
  }

  /// Forget trace + invalidate in-flight responses (offline, a route
  /// appeared, screen covered). The projection line lives on the controller
  /// and is cleared by the same caller.
  void reset() {
    _trace.clear();
    _seq++; // in-flight responses die with the generation
  }

  void _maybeMatch() {
    if (_busy) return;
    final now = DateTime.now();
    if (now.difference(_lastCall) < _minInterval) return;
    if (_trace.length < 2) return;
    final a = _trace.first, b = _trace.last;
    if (_distM(a.lat, a.lng, b.lat, b.lng) < _minTraceSpanM) return;
    _busy = true;
    _lastCall = now;
    final seq = ++_seq;
    final trace = List.of(_trace);
    unawaited(_match(trace).then((line) {
      if (seq != _seq) return; // a newer call (or a reset) won
      if (line != null && line.length >= 2) onLine?.call(line);
    }).whenComplete(() => _busy = false));
  }

  Future<List<LatLng>?> _match(
      List<({double lat, double lng, double acc, int tsMs})> trace) async {
    final coords =
        trace.map((p) => '${p.lng},${p.lat}').join(';');
    final radiuses = trace
        .map((p) =>
            (p.acc.isFinite && p.acc > 0 && p.acc <= 200)
                ? p.acc.round()
                : _defaultRadiusM)
        .join(';');

    // 1) Mapbox Map Matching — same access token as every other map call.
    try {
      final token = MapboxConfig.accessToken;
      if (token.isNotEmpty) {
        final uri = Uri.parse(
            'https://api.mapbox.com/matching/v5/mapbox/driving/$coords'
            '?geometries=geojson&radiuses=$radiuses&tidy=true'
            '&access_token=$token');
        final res =
            await http.get(uri).timeout(const Duration(seconds: 6));
        if (res.statusCode == 200) {
          final line = _parseMatchGeometry(res.body);
          if (line != null) return line;
        } else {
          debugPrint('[RoadSnap] mapbox matching ${res.statusCode}');
        }
      }
    } catch (e) {
      debugPrint('[RoadSnap] mapbox matching failed: $e');
    }

    // 2) OSRM match on the same demo host the directions fallback uses.
    try {
      final uri = Uri.https(
        'router.project-osrm.org',
        '/match/v1/driving/$coords',
        {'geometries': 'geojson', 'radiuses': radiuses},
      );
      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final line = _parseMatchGeometry(res.body);
        if (line != null) return line;
      } else {
        debugPrint('[RoadSnap] osrm match ${res.statusCode}');
      }
    } catch (e) {
      debugPrint('[RoadSnap] osrm match failed: $e');
    }

    return null; // caller keeps the old line; fixes fall back to raw
  }

  /// Shared by both providers: `matchings[0].geometry.coordinates` as
  /// `[lng, lat]` pairs. Visible for the guard test — a bad parse here
  /// silently kills the whole feature (the fallback would mask it).
  @visibleForTesting
  static List<LatLng>? parseMatchGeometry(String body) =>
      _parseMatchGeometry(body);

  static List<LatLng>? _parseMatchGeometry(String body) {
    try {
      final json = jsonDecode(body) as Map<String, dynamic>;
      final matchings = json['matchings'] as List?;
      if (matchings == null || matchings.isEmpty) return null;
      final geom = matchings.first['geometry'] as Map<String, dynamic>?;
      final coords = geom?['coordinates'] as List?;
      if (coords == null || coords.length < 2) return null;
      final out = <LatLng>[];
      for (final c in coords) {
        if (c is! List || c.length < 2) continue;
        final lng = (c[0] as num?)?.toDouble();
        final lat = (c[1] as num?)?.toDouble();
        if (lat == null || lng == null) continue;
        if (!lat.isFinite || !lng.isFinite) continue;
        if (lat.abs() > 90 || lng.abs() > 180) continue;
        out.add(LatLng(lat, lng));
      }
      return out.length >= 2 ? out : null;
    } catch (e) {
      debugPrint('[RoadSnap] match geometry parse failed: $e');
      return null;
    }
  }

  static double _distM(double lat1, double lng1, double lat2, double lng2) {
    const r = 6371000.0;
    final dLat = (lat2 - lat1) * math.pi / 180;
    final dLng = (lng2 - lng1) * math.pi / 180;
    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1 * math.pi / 180) *
            math.cos(lat2 * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return 2 * r * math.asin(math.sqrt(h));
  }
}
