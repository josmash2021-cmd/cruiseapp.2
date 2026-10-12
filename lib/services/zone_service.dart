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

/// One demand-heat entry set by dispatch (2026-10-12 spec): level 1 = gold
/// semi-transparent, 2 = more solid + "Ocupado" pill, 3 = fully solid +
/// "Muy ocupado" pill. [bonus] rides the pill as "+$X.XX" (display only in
/// phase 1 — the charge/pay pipeline is phase 2).
class SectorDemand {
  final int level;
  final double bonus;
  const SectorDemand(this.level, this.bonus);
}

/// One large driver SECTOR (2026-10-12 spec: "no de mini ciudad en mini
/// ciudad si no por sectores") — the dissolve of several Census cities into
/// a big region, painted always in gray with its boundary; dispatch turns
/// it gold by demand level.
class Sector {
  final String id;
  final String name;
  final LatLng center;
  final List<double> bbox; // [west, south, east, north]

  /// [poly][ring][point] — same shape as [Zone.polys].
  final List<List<List<LatLng>>> polys;

  const Sector({
    required this.id,
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
  static const _sectorCacheKey = 'fl_sectors_json_v1';

  static final List<Zone> zones = [];

  /// Raw GeoJSON features, kept so the map can build its sources verbatim.
  static final List<Map<String, dynamic>> features = [];

  /// The big SECTORS (2026-10-12 spec) and their raw features — one small
  /// GeoJSON source per sector on the map (the single all-cities source
  /// never materialized on iOS; per-sector sources are the size that draws).
  static final List<Sector> sectors = [];
  static final List<Map<String, dynamic>> sectorFeatures = [];
  static bool sectorsReady = false;
  static bool _sectorsLoading = false;

  /// Sector demand heat set by dispatch: sector_id → level/bonus. Polled
  /// every minute by the driver screen; missing = all gray.
  static final Map<String, SectorDemand> demand = {};
  static DateTime? _demandFetchedAt;

  static bool ready = false;
  static bool _loading = false;

  /// Load zones + sectors: cached copies first (instant), network refresh
  /// after.
  static Future<void> load() async {
    unawaited(loadSectors());
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

  /// Same load discipline as the cities file.
  static Future<void> loadSectors() async {
    if (sectorsReady || _sectorsLoading) return;
    _sectorsLoading = true;
    try {
      final cached = LocalCache.get<String>(_sectorCacheKey);
      if (cached != null && cached.length > 100) {
        parseSectors(cached);
        if (sectorsReady) {
          unawaited(_refreshSectorsFromNetwork());
          return;
        }
      }
      await _refreshSectorsFromNetwork();
    } finally {
      _sectorsLoading = false;
    }
  }

  static Future<void> _refreshSectorsFromNetwork() async {
    try {
      final res = await http
          .get(Uri.parse(
              '${ApiService.currentBaseUrl}/static/fl_sectors.json'))
          .timeout(const Duration(seconds: 8));
      if (res.statusCode == 200 && res.body.length > 100) {
        parseSectors(res.body);
        if (sectorsReady) {
          unawaited(LocalCache.set(_sectorCacheKey, res.body));
        }
      }
    } catch (e) {
      debugPrint('[Zones] sector network load failed (cache applies): $e');
    }
  }

  /// Parse the sectors FeatureCollection. Public for the guard test.
  static void parseSectors(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final feats = (data['features'] as List?) ?? [];
      final parsed = <Sector>[];
      final rawFeats = <Map<String, dynamic>>[];
      for (final feat in feats) {
        final f = feat as Map<String, dynamic>;
        final props = (f['properties'] as Map?) ?? {};
        final geom = (f['geometry'] as Map?) ?? {};
        final gtype = geom['type'] as String?;
        final coords = geom['coordinates'] as List? ?? [];
        final rawPolys = gtype == 'MultiPolygon' ? coords : [coords];
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
        final id = (props['id'] ?? '').toString();
        if (polys.isEmpty || bbox.length < 4 || id.isEmpty) continue;
        parsed.add(Sector(
          id: id,
          name: (props['name'] ?? '').toString(),
          center: LatLng((center[1] as num).toDouble(),
              (center[0] as num).toDouble()),
          bbox: bbox,
          polys: polys,
        ));
        rawFeats.add(f);
      }
      sectors
        ..clear()
        ..addAll(parsed);
      sectorFeatures
        ..clear()
        ..addAll(rawFeats);
      sectorsReady = sectors.isNotEmpty;
    } catch (e) {
      debugPrint('[Zones] sector parse failed: $e');
    }
  }

  /// The sector containing the point, or null. Same ray-casting as the
  /// cities — tap-to-select works on sectors (2026-10-12).
  static Sector? sectorContaining(LatLng p) {
    if (!sectorsReady) return null;
    for (final s in sectors) {
      final w = s.bbox[0], so = s.bbox[1], e = s.bbox[2], n = s.bbox[3];
      if (p.longitude < w || p.longitude > e) continue;
      if (p.latitude < so || p.latitude > n) continue;
      for (final rings in s.polys) {
        if (!_ringContains(p.longitude, p.latitude, rings[0])) continue;
        final inHole = rings
            .skip(1)
            .any((hole) => _ringContains(p.longitude, p.latitude, hole));
        if (!inHole) return s;
      }
    }
    return null;
  }

  static Sector? sectorById(String id) {
    for (final s in sectors) {
      if (s.id == id) return s;
    }
    return null;
  }

  /// Pull the dispatch-set demand heat. 60 s cadence from the driver map.
  static Future<void> loadDemand({bool force = false}) async {
    final last = _demandFetchedAt;
    if (!force &&
        last != null &&
        DateTime.now().difference(last).inSeconds < 55) {
      return;
    }
    _demandFetchedAt = DateTime.now();
    try {
      final res = await http
          .get(Uri.parse('${ApiService.currentBaseUrl}/zones/demand'),
              headers: ApiService.jsonHeaders())
          .timeout(const Duration(seconds: 6));
      if (res.statusCode != 200) return;
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final raw = (data['sectors'] as Map?) ?? {};
      final parsed = <String, SectorDemand>{};
      for (final e in raw.entries) {
        final cfg = (e.value as Map?) ?? {};
        final level = (cfg['level'] as num?)?.toInt() ?? 0;
        final bonus = (cfg['bonus'] as num?)?.toDouble() ?? 0;
        if (level >= 1 && level <= 3) {
          parsed[e.key.toString()] = SectorDemand(level, bonus);
        }
      }
      demand
        ..clear()
        ..addAll(parsed);
    } catch (e) {
      debugPrint('[Zones] demand load failed (last values stay): $e');
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

  /// Whether the point falls inside the Florida coverage region (union of
  /// every zone bbox). The connect gate only applies INSIDE it — drivers in
  /// other states are never gated by a Florida file (Alabama's sectors come
  /// later, 2026-10-11 user decision).
  static bool insideCoverageArea(LatLng p) {
    if (!ready) return false;
    for (final z in zones) {
      if (p.longitude >= z.bbox[0] &&
          p.longitude <= z.bbox[2] &&
          p.latitude >= z.bbox[1] &&
          p.latitude <= z.bbox[3]) {
        return true;
      }
    }
    return false;
  }

  /// Zone by name (for the driver's SELECTION — they tap a zone on the map
  /// to declare where they work, 2026-10-11).
  static Zone? zoneByName(String name) {
    for (final z in zones) {
      if (z.name == name) return z;
    }
    return null;
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
