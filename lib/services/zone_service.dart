import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/lat_lng.dart';
import 'api_service.dart';
import 'local_cache.dart';

/// One municipal zone from the baked Census boundaries (2026-10-11).
class Zone {
  final String name;
  final LatLng center;
  final List<double> bbox; // [west, south, east, north]

  /// [poly][ring][point] — ring 0 of each poly is the outer boundary, the
  /// rest are holes. Same shape the backend's zone_polygons.py consumes.
  final List<List<List<LatLng>>> polys;

  const Zone({
    required this.name,
    required this.center,
    required this.bbox,
    required this.polys,
  });
}

/// Municipal zone polygons (2026-10-11, user spec: the driver map divided by
/// city like the photo, and connecting only inside a zone).
///
/// Data comes from `${base}/static/fl_zones.json` (real Census TIGER
/// boundaries), fetched once per process and mirrored into LocalCache so the
/// map works without network. Fail-open everywhere: no data → `ready=false`
/// → no gate and no drawing, never a lockout over our own data file.
class ZoneService {
  ZoneService._();

  static const _cacheKey = 'fl_zones_json_v1';

  static final List<Zone> zones = [];

  /// Raw GeoJSON features, kept so the map can build its sources verbatim.
  static final List<Map<String, dynamic>> features = [];

  static bool ready = false;
  static bool _loading = false;

  /// Load zones: cached copy first (instant), network refresh after.
  static Future<void> load() async {
    if (ready || _loading) return;
    _loading = true;
    try {
      final cached = LocalCache.get<String>(_cacheKey);
      if (cached != null && cached.length > 100) {
        parse(cached);
        if (ready) {
          unawaited(_refreshFromNetwork());
          return;
        }
      }
      await _refreshFromNetwork();
    } finally {
      _loading = false;
    }
  }

  static Future<void> _refreshFromNetwork() async {
    try {
      final res = await http
          .get(Uri.parse(
              '${ApiService.currentBaseUrl}/static/fl_zones.json'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200 && res.body.length > 100) {
        parse(res.body);
        if (ready) unawaited(LocalCache.set(_cacheKey, res.body));
      }
    } catch (e) {
      debugPrint('[Zones] network load failed (cache still applies): $e');
    }
  }

  /// Parse the FeatureCollection. Public for the guard test.
  static void parse(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final feats = (data['features'] as List?) ?? [];
      final parsed = <Zone>[];
      final rawFeats = <Map<String, dynamic>>[];
      for (final feat in feats) {
        final f = feat as Map<String, dynamic>;
        final props = (f['properties'] as Map?) ?? {};
        final geom = (f['geometry'] as Map?) ?? {};
        final gtype = geom['type'] as String?;
        final coords = geom['coordinates'] as List? ?? [];
        final rawPolys =
            gtype == 'MultiPolygon' ? coords : [coords];
        final polys = <List<List<LatLng>>>[];
        for (final poly in rawPolys) {
          final rings = <List<LatLng>>[
            for (final ring in (poly as List))
              [
                for (final pt in (ring as List))
                  LatLng((pt[1] as num).toDouble(), (pt[0] as num).toDouble())
              ]
          ];
          if (rings.isNotEmpty && rings.first.length >= 4) polys.add(rings);
        }
        final bbox = ((props['bbox'] as List?) ?? [])
            .map((v) => (v as num).toDouble())
            .toList();
        final center = (props['center'] as List?) ?? [0, 0];
        if (polys.isEmpty || bbox.length < 4) continue;
        parsed.add(Zone(
          name: (props['name'] ?? '').toString(),
          center: LatLng((center[1] as num).toDouble(),
              (center[0] as num).toDouble()),
          bbox: bbox,
          polys: polys,
        ));
        rawFeats.add(f);
      }
      zones
        ..clear()
        ..addAll(parsed);
      features
        ..clear()
        ..addAll(rawFeats);
      ready = zones.isNotEmpty;
    } catch (e) {
      debugPrint('[Zones] parse failed: $e');
    }
  }

  /// The zone containing the point, or null. Ray-casting, even-odd rule —
  /// the same math the backend gate uses, so app and server always agree.
  static Zone? zoneContaining(LatLng p) {
    if (!ready) return null;
    for (final zone in zones) {
      final w = zone.bbox[0], s = zone.bbox[1];
      final e = zone.bbox[2], n = zone.bbox[3];
      if (p.longitude < w || p.longitude > e) continue;
      if (p.latitude < s || p.latitude > n) continue;
      for (final rings in zone.polys) {
        if (!_ringContains(p.longitude, p.latitude, rings[0])) continue;
        final inHole = rings
            .skip(1)
            .any((hole) => _ringContains(p.longitude, p.latitude, hole));
        if (!inHole) return zone;
      }
    }
    return null;
  }

  static bool _ringContains(double lng, double lat, List<LatLng> ring) {
    var inside = false;
    var j = ring.length - 1;
    for (var i = 0; i < ring.length; i++) {
      final xi = ring[i].longitude, yi = ring[i].latitude;
      final xj = ring[j].longitude, yj = ring[j].latitude;
      if ((yi > lat) != (yj > lat)) {
        if (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
      }
      j = i;
    }
    return inside;
  }
}
