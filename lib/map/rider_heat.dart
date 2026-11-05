import 'dart:math' as math;

import '../models/lat_lng.dart';

/// Heat zones: riders building a trip, on the driver's map (owner
/// 2026-11-05). The server (backend/services/rider_heat.py) publishes the
/// riders as ~400 m grid cells with a weight — 0.55 a rider whose location
/// was detected, 0.8 a typed pickup, 1.0 a typed dropoff — summed per cell.
/// The driver never sees a rider, only where they add up.

/// One grid cell of heat.
class HeatCell {
  const HeatCell(this.lat, this.lng, this.w);

  final double lat;
  final double lng;
  final double w;

  /// Stable identity of the cell — the server snaps to a fixed grid.
  String get key => '${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}';

  /// `[{lat, lng, w}, …]` from the Firestore doc / REST fallback. Anything
  /// malformed drops out cell by cell.
  static List<HeatCell> listFrom(Object? raw) {
    if (raw is! List) return const [];
    final out = <HeatCell>[];
    for (final c in raw) {
      if (c is! Map) continue;
      double? n(Object? v) => v is num ? v.toDouble() : null;
      final lat = n(c['lat']);
      final lng = n(c['lng']);
      final w = n(c['w']);
      if (lat == null || lng == null || w == null) continue;
      if (!lat.isFinite || !lng.isFinite || !w.isFinite || w <= 0) continue;
      if (lat.abs() > 90 || lng.abs() > 180) continue;
      out.add(HeatCell(lat, lng, w));
    }
    return out;
  }
}

/// One cloud: neighbouring cells together, with its flame at the weighted
/// middle.
class HeatZone {
  const HeatZone(this.key, this.center, this.weight);

  /// Kept across updates while the cloud stays put, so its flame does not
  /// fade out and back in every time a rider joins.
  final int key;
  final LatLng center;
  final double weight;
}

/// Cells closer than this belong to the same cloud (three grid steps: the
/// ~0.4 mi glow of each one already runs into the next).
const double kHeatZoneLinkM = 1200;

/// A cloud that moved less than this is the same cloud.
const double kHeatZoneSameM = 1500;

double heatDistanceM(double aLat, double aLng, double bLat, double bLng) {
  const r = 6371000.0;
  final dLat = (bLat - aLat) * math.pi / 180;
  final dLng = (bLng - aLng) * math.pi / 180;
  final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
      math.cos(aLat * math.pi / 180) *
          math.cos(bLat * math.pi / 180) *
          math.sin(dLng / 2) *
          math.sin(dLng / 2);
  return 2 * r * math.asin(math.min(1, math.sqrt(h)));
}

/// Groups [cells] into clouds (single link at [kHeatZoneLinkM]) and keys
/// each one: a cloud within [kHeatZoneSameM] of one in [previous] keeps that
/// key; the rest get fresh keys from [nextKey].
List<HeatZone> heatZonesFrom(
  List<HeatCell> cells, {
  List<HeatZone> previous = const [],
  required int Function() nextKey,
}) {
  final n = cells.length;
  final group = List<int>.generate(n, (i) => i);
  int find(int i) {
    while (group[i] != i) {
      group[i] = group[group[i]];
      i = group[i];
    }
    return i;
  }

  for (var i = 0; i < n; i++) {
    for (var j = i + 1; j < n; j++) {
      if (heatDistanceM(cells[i].lat, cells[i].lng, cells[j].lat,
              cells[j].lng) <=
          kHeatZoneLinkM) {
        group[find(i)] = find(j);
      }
    }
  }
  final sums = <int, List<double>>{}; // root → [Σw·lat, Σw·lng, Σw]
  for (var i = 0; i < n; i++) {
    final c = cells[i];
    final s = sums.putIfAbsent(find(i), () => [0, 0, 0]);
    s[0] += c.w * c.lat;
    s[1] += c.w * c.lng;
    s[2] += c.w;
  }
  final raw = [
    for (final s in sums.values)
      if (s[2] > 0) (LatLng(s[0] / s[2], s[1] / s[2]), s[2]),
  ]..sort((a, b) => b.$2.compareTo(a.$2)); // heaviest claims its key first
  final free = [...previous];
  final out = <HeatZone>[];
  for (final (center, w) in raw) {
    HeatZone? best;
    var bestM = kHeatZoneSameM;
    for (final p in free) {
      final m = heatDistanceM(center.latitude, center.longitude,
          p.center.latitude, p.center.longitude);
      if (m <= bestM) {
        bestM = m;
        best = p;
      }
    }
    if (best != null) free.remove(best);
    out.add(HeatZone(best?.key ?? nextKey(), center, w));
  }
  return out;
}

/// Smooth in, smooth out (owner 2026-11-05: "fade in smooth"): every cell's
/// weight eases to its new value over [kHeatFadeMs] — a new cloud grows from
/// nothing, a rider leaving fades, nothing jumps.
const int kHeatFadeMs = 1200;

double heatSmootherstep(double t) {
  if (t <= 0) return 0;
  if (t >= 1) return 1;
  return t * t * t * (t * (t * 6 - 15) + 10);
}

class _Fade {
  _Fade(this.lat, this.lng, this.from, this.to, this.t0);
  final double lat;
  final double lng;
  double from;
  double to;
  int t0;

  double at(int nowMs) =>
      from + (to - from) * heatSmootherstep((nowMs - t0) / kHeatFadeMs);
}

class HeatFader {
  final Map<String, _Fade> _cells = {};

  /// New targets; cells missing from [cells] fade to zero and go.
  void setTarget(List<HeatCell> cells, int nowMs) {
    final seen = <String>{};
    for (final c in cells) {
      seen.add(c.key);
      final f = _cells[c.key];
      if (f == null) {
        _cells[c.key] = _Fade(c.lat, c.lng, 0, c.w, nowMs);
      } else if (f.to != c.w) {
        f.from = f.at(nowMs);
        f.to = c.w;
        f.t0 = nowMs;
      }
    }
    for (final e in _cells.entries) {
      if (seen.contains(e.key) || e.value.to == 0) continue;
      e.value.from = e.value.at(nowMs);
      e.value.to = 0;
      e.value.t0 = nowMs;
    }
  }

  /// The cells as they look at [nowMs]; finished fade-outs are dropped.
  List<HeatCell> at(int nowMs) {
    _cells.removeWhere(
        (_, f) => f.to == 0 && nowMs - f.t0 >= kHeatFadeMs);
    return [
      for (final f in _cells.values)
        if (f.at(nowMs) > 0.001) HeatCell(f.lat, f.lng, f.at(nowMs)),
    ];
  }

  /// Still easing somewhere.
  bool animating(int nowMs) =>
      _cells.values.any((f) => nowMs - f.t0 < kHeatFadeMs);

  bool get isEmpty => _cells.isEmpty;

  void clear() => _cells.clear();
}

// ── The look: Mapbox heatmap paint (same ramp as the approved demo) ──

/// Each rider's glow reaches ~1.26 mi (a gaussian of σ ≈ 0.42 mi; Mapbox
/// uses σ = radius / 3).
const double kHeatKernelRadiusM = 2030;

/// heatmap-radius by zoom, in screen points, exact at [latDeg]: the glow
/// keeps its size on the ground as the driver zooms.
List<Object> heatRadiusExpression(double latDeg) {
  final metresPerPxZ0 =
      40075016.686 * math.cos(latDeg * math.pi / 180) / 512;
  double at(double z) => kHeatKernelRadiusM * math.pow(2, z) / metresPerPxZ0;
  return [
    'interpolate',
    ['exponential', 2],
    ['zoom'],
    8, at(8),
    16, at(16),
  ];
}

/// heatmap-density (Σ 0.4 · weight) → gold, see-through at the rim.
const List<Object> kHeatColorExpression = [
  'interpolate',
  ['linear'],
  ['heatmap-density'],
  0, 'rgba(232, 197, 71, 0)',
  0.05, 'rgba(233, 199, 74, 0.05)',
  0.1, 'rgba(234, 200, 78, 0.10)',
  0.2, 'rgba(236, 203, 85, 0.20)',
  0.3, 'rgba(238, 206, 91, 0.28)',
  0.5, 'rgba(241, 212, 105, 0.44)',
  0.8, 'rgba(246, 220, 122, 0.66)',
  1, 'rgba(246, 220, 122, 0.68)',
];

/// Lighter close in, so the streets inside the cloud still read (the
/// glow is fixed on the ground, so up close it covers the whole screen).
const List<Object> kHeatOpacityExpression = [
  'interpolate',
  ['linear'],
  ['zoom'],
  10, 1.0,
  13, 0.72,
  16, 0.55,
];

const List<Object> kHeatWeightExpression = ['get', 'w'];

String heatGeoJson(List<HeatCell> cells) {
  final b = StringBuffer('{"type":"FeatureCollection","features":[');
  var first = true;
  for (final c in cells) {
    if (!first) b.write(',');
    first = false;
    b.write('{"type":"Feature","properties":{"w":');
    b.write(c.w.toStringAsFixed(3));
    b.write('},"geometry":{"type":"Point","coordinates":[');
    b.write(c.lng.toStringAsFixed(6));
    b.write(',');
    b.write(c.lat.toStringAsFixed(6));
    b.write(']}}');
  }
  b.write(']}');
  return b.toString();
}
