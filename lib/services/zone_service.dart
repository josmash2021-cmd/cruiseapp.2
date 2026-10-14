import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../models/lat_lng.dart';
import 'api_service.dart';
import 'local_cache.dart';
import 'socket_service.dart';
import 'state_outlines.dart';

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
/// Driver SECTOR map (2026-10-12 spec: big regions, "no de mini ciudad en
/// mini ciudad") — the ONLY zone dataset the app uses: drawing, tap-to-
/// select, demand heat AND the connect gate (2026-10-14 spec: sectors of
/// Florida AND Alabama, one dataset, the one the panel edits; the old
/// per-city file died with the gate's move to sectors).
///
/// Data comes from `${base}/static/fl_sectors.json` (the baked seed) and
/// the live `/zones/sectors` endpoint (the panel-edited map), mirrored into
/// LocalCache so the map works without network. Fail-open everywhere: no
/// data → `sectorsReady=false` → no gate and no drawing, never a lockout
/// over our own data file.
class ZoneService {
  ZoneService._();

  static const _sectorCacheKey = 'fl_sectors_json_v1';
  static const _sectorVersionCacheKey = 'fl_sectors_version_v1';

  /// The big SECTORS (2026-10-12 spec) and their raw features — one small
  /// GeoJSON source per sector on the map (the single all-cities source
  /// never materialized on iOS; per-sector sources are the size that draws).
  static final List<Sector> sectors = [];
  static final List<Map<String, dynamic>> sectorFeatures = [];
  static bool sectorsReady = false;
  static bool _sectorsLoading = false;

  /// Live boundary version (2026-10-13): the backend broadcasts
  /// `zones_updated` and `/zones/demand` carries `sectors_version`; when the
  /// version moves, the sectors re-download by REST and the driver map
  /// re-draws animated. Filled from the cache on bootstrap and from the
  /// server on every live refresh.
  static int sectorsVersion = 0;

  /// Fires (value++) when a live refresh actually changed the sector set —
  /// the driver map listens and runs the animated swap.
  static final ValueNotifier<int> sectorsChanged = ValueNotifier<int>(0);

  static bool _watching = false;

  /// Sector demand heat set by dispatch: sector_id → level/bonus. Polled
  /// every minute by the driver screen; missing = all gray.
  static final Map<String, SectorDemand> demand = {};
  static DateTime? _demandFetchedAt;

  /// Load the sector map: cached copy first (instant), live network refresh
  /// after. Awaited so callers' `.then` runs with sectors READY (the boot
  /// zone-restore raced the old fire-and-forget and could miss its id).
  static Future<void> load() async {
    watchZoneUpdates();
    await loadSectors();
  }

  /// Same load discipline as the cities file.
  static Future<void> loadSectors() async {
    if (sectorsReady || _sectorsLoading) return;
    _sectorsLoading = true;
    try {
      final cached = LocalCache.get<String>(_sectorCacheKey);
      if (cached != null && cached.length > 100) {
        sectorsVersion = LocalCache.get<int>(_sectorVersionCacheKey) ?? 0;
        parseSectors(cached);
        if (sectorsReady) {
          // With a cache in hand the ONLY refresh is the versioned endpoint
          // (2026-10-13, "cierro la app y las zonas salen diferentes"): the
          // static-file refresh below clobbered the newer panel-edited
          // cache with the baked seed on every cold start.
          unawaited(refreshSectorsFromServer());
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

  /// Live refresh from the backend (2026-10-13): `GET /zones/sectors`
  /// answers {version, geojson} — a newer version (or the same version with
  /// a different body) re-parses, updates the cache and pings the map so the
  /// new boundaries draw animated without closing the app. Fail-open: an old
  /// backend (404) or a dead network logs and nothing throws.
  static Future<void> refreshSectorsFromServer() async {
    try {
      final res = await http
          .get(Uri.parse('${ApiService.currentBaseUrl}/zones/sectors'),
              headers: ApiService.jsonHeaders())
          .timeout(const Duration(seconds: 8));
      if (res.statusCode != 200) {
        debugPrint(
            '[Zones] live sector refresh skipped (HTTP ${res.statusCode})');
        return;
      }
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      final version = (data['version'] as num?)?.toInt() ?? 0;
      final geojson = data['geojson'];
      if (geojson is! Map<String, dynamic>) return;
      final body = jsonEncode(geojson);
      final changed = body != LocalCache.get<String>(_sectorCacheKey);
      if (version > sectorsVersion || (version == sectorsVersion && changed)) {
        sectorsVersion = version;
        parseSectors(body);
        if (sectorsReady) {
          unawaited(LocalCache.set(_sectorCacheKey, body));
          unawaited(LocalCache.set(_sectorVersionCacheKey, version));
          if (changed) sectorsChanged.value++;
        }
      }
    } catch (e) {
      debugPrint('[Zones] live sector refresh failed: $e');
    }
  }

  /// Subscribe once to the socket wake-up; the truth is always re-downloaded
  /// by REST (the event carries only a version number). The subscription
  /// lives for the process — the controller is never closed (same pattern
  /// as appUpdateGateStream).
  static void watchZoneUpdates() {
    if (_watching) return;
    _watching = true;
    SocketService.zonesUpdatedStream.listen((_) {
      unawaited(refreshSectorsFromServer());
    });
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

  // ── State grouping (2026-10-14, user spec: the app opens framing the
  // zones of the STATE the driver is in — Florida and Alabama for now) ──

  /// 'FL' | 'AL' | null — the state containing the point, from the embedded
  /// Census outlines (build-time data, no geocoder, works offline at boot).
  static String? stateOfPoint(LatLng p) {
    for (final ring in kStateOutlineFl) {
      if (_flatRingContains(p.longitude, p.latitude, ring)) return 'FL';
    }
    for (final ring in kStateOutlineAl) {
      if (_flatRingContains(p.longitude, p.latitude, ring)) return 'AL';
    }
    return null;
  }

  /// The state a sector belongs to: its center's state. Null = unknown
  /// (border-straddling hand-drawn geometry, a future state not yet
  /// outlined) — those sectors ride along in EVERY state fit (fail-open: a
  /// sector the panel saved must never vanish from the map view).
  static String? sectorState(Sector s) => stateOfPoint(s.center);

  /// The sectors the zone FIT frames for a driver in [state]: the state's
  /// own + the state-unknown ones. Null/unknown driver state → every
  /// sector (the union fit, the pre-2026-10-14 behaviour).
  static List<Sector> sectorsForState(String? state) {
    if (state == null) return List.unmodifiable(sectors);
    return [
      for (final s in sectors)
        if (sectorState(s) == null || sectorState(s) == state) s,
    ];
  }

  /// Whether the point falls inside the coverage region of the SECTOR map
  /// (union of sector bboxes). The connect gate applies inside it — with
  /// sectors drawn in both states (panel-edited), Florida AND Alabama
  /// drivers are gated by the same single dataset.
  static bool insideSectorCoverage(LatLng p) {
    if (!sectorsReady) return false;
    for (final s in sectors) {
      if (p.longitude >= s.bbox[0] &&
          p.longitude <= s.bbox[2] &&
          p.latitude >= s.bbox[1] &&
          p.latitude <= s.bbox[3]) {
        return true;
      }
    }
    return false;
  }

  /// Ray-casting on a flat [lng, lat, lng, lat, ...] ring (the generated
  /// state outlines) — same even-odd rule as [_ringContains].
  static bool _flatRingContains(double lng, double lat, List<double> ring) {
    var inside = false;
    var j = ring.length - 2;
    for (var i = 0; i < ring.length; i += 2) {
      final xi = ring[i], yi = ring[i + 1];
      final xj = ring[j], yj = ring[j + 1];
      if ((yi > lat) != (yj > lat)) {
        if (lng < (xj - xi) * (lat - yi) / (yj - yi) + xi) inside = !inside;
      }
      j = i;
    }
    return inside;
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
      // Polling fallback for a dead socket (2026-10-13): the demand answer
      // carries the live sectors version — a newer one re-downloads the
      // boundaries within this same ≤60 s cadence.
      final sv = (data['sectors_version'] as num?)?.toInt() ?? 0;
      if (sv > sectorsVersion) {
        unawaited(refreshSectorsFromServer());
      }
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
