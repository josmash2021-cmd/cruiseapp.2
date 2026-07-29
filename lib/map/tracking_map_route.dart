import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../utils/mapbox_safe.dart';

/// ═══════════════════════════════════════════════════════════════════
///  TrackingMapRoute — Gestión de líneas de ruta en el mapa
/// ═══════════════════════════════════════════════════════════════════
class TrackingMapRoute {
  TrackingMapRoute({
    required this.map,
    required mapbox.PolylineAnnotationManager? polylineAnnotMgr,
  }) : _polylineAnnotMgr = polylineAnnotMgr;

  final mapbox.MapboxMap map;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;

  mapbox.PolylineAnnotation? _remainingRouteAnnot;
  mapbox.PolylineAnnotation? _dimmedRouteAnnot;
  mapbox.PolylineAnnotation? _approachAnnot;

  List<LatLng> _routePts = [];
  List<LatLng> _tripRoutePts = [];
  List<double> _segDist = [];

  double _traveledM = 0;
  double _tgtTraveledM = 0;

  Ticker? _routeDrawTicker;
  bool _routeDrawDone = false;

  DateTime _lastRouteErase = DateTime(2000);

  /// True while an erase update is still crossing the platform channel.
  ///
  /// The erase rate below is fast enough that a slow IPC round-trip could
  /// overlap the next call. Without this the writes queue up and Mapbox
  /// starts dropping them mid-flight (project rule 25), which shows up as
  /// the route line stuttering and snapping backwards. Skipping a frame is
  /// invisible; a dropped flush is not.
  bool _eraseBusy = false;

  /// How often the line behind the car is trimmed. 66 ms ≈ 15 fps.
  ///
  /// Was 500 ms — 2 fps — while the car itself moves at 30 fps. The line
  /// visibly lagged the car and then jumped to catch up. Matching them is
  /// the whole point: the rider should see the road being consumed under
  /// the car, not swallowed in chunks half a second later.
  static const int _eraseIntervalMs = 66;

  /// Actualiza el manager de anotaciones
  void setAnnotManager(mapbox.PolylineAnnotationManager? mgr) {
    _polylineAnnotMgr = mgr;
    _remainingRouteAnnot = null;
    _dimmedRouteAnnot = null;
    _approachAnnot = null;
  }

  /// Inicializa la ruta del viaje
  void initRoute({
    required List<LatLng> routePoints,
    required LatLng pickupLatLng,
    required LatLng dropoffLatLng,
  }) {
    _tripRoutePts = List.from(routePoints);
    _routePts = List.from(routePoints);

    // Snap endpoints to exact pickup/dropoff
    if (_routePts.length >= 2) {
      _routePts[0] = pickupLatLng;
      _routePts[_routePts.length - 1] = dropoffLatLng;
    }

    _buildSegDist();
    _traveledM = 0;
    _tgtTraveledM = 0;
    _routeDrawDone = false;
  }

  /// Point this component at a new active route.
  ///
  /// [initRoute] only ever ran once, at map creation, while the screen
  /// swaps its own route three times over a trip — approach route,
  /// reroute, then the pickup→dropoff leg. This component kept the first
  /// one forever, so:
  ///   - startAnimatedRouteDraw bailed on its own stale `_routeDrawDone`
  ///     and the trip route was never drawn at all;
  ///   - eraseRouteBehindCar trimmed against the wrong geometry.
  /// Every swap on the screen side must come through here.
  void setActiveRoute(List<LatLng> points, {bool resetDraw = true}) {
    if (points.length < 2) return;
    _routePts = List.of(points);
    _buildSegDist();
    if (resetDraw) {
      _routeDrawTicker?.stop();
      _routeDrawDone = false;
    }
  }

  /// Dibuja la ruta completa (dimmed) como fondo
  Future<void> drawDimmedRoute({double opacity = 0.20, double width = 5.0}) async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;

    final dimmedPts = _tripRoutePts.isNotEmpty ? _tripRoutePts : _routePts;
    if (dimmedPts.length < 2) return;

    final safeGeom = safeLineString(dimmedPts);
    if (safeGeom == null) return;

    try {
      _dimmedRouteAnnot ??= await mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: safeGeom,
        lineColor: const Color(0xFFFFD700).withValues(alpha: opacity).toARGB32(),
        lineWidth: width,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    } catch (e) {
      debugPrint('[TrackingMapRoute] Failed to create dimmed route: $e');
    }
  }

  /// Dibuja la ruta restante (brillante) desde la posición actual
  Future<void> drawRemainingRoute(LatLng driverPos) async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || _routePts.length < 2) return;

    // Proyectar posición del conductor sobre la ruta
    final projectedM = _projectOntoRoute(driverPos);
    _tgtTraveledM = projectedM;

    // Obtener puntos restantes
    final remainingPts = _getRemainingPoints(projectedM);
    if (remainingPts.length < 2) return;

    // Eliminar ruta anterior
    if (_remainingRouteAnnot != null) {
      try { await mgr.delete(_remainingRouteAnnot!); } catch (_) {}
    }

    final line = mapbox.LineString(
      coordinates: remainingPts.map((p) =>
        mapbox.Position(p.longitude, p.latitude)
      ).toList(),
    );

    try {
      _remainingRouteAnnot = await mgr.create(
        mapbox.PolylineAnnotationOptions(
          geometry: line,
          lineColor: const Color(0xFFFFD700).toARGB32(),
          lineWidth: 5.0,
          lineJoin: mapbox.LineJoin.ROUND,
        ),
      );
    } catch (e) {
      debugPrint('[TrackingMapRoute] Failed to create remaining route: $e');
    }
  }

  /// Dibuja línea de approach (conductor → pickup)
  Future<void> drawApproach(LatLng driverPos, LatLng pickupPos) async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;

    // Skip if driver hasn't reported position yet
    if (driverPos.latitude == 0 && driverPos.longitude == 0) return;

    final approachGeom = safeLineString([driverPos, pickupPos]);
    if (approachGeom == null) return;

    if (_approachAnnot == null) {
      try {
        _approachAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
          geometry: approachGeom,
          lineColor: const Color(0xFFFFD700).toARGB32(),
          lineWidth: 5.0,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
      } catch (e) {
        debugPrint('[TrackingMapRoute] Failed to create approach: $e');
      }
    } else {
      try {
        _approachAnnot!.geometry = approachGeom;
        await mgr.update(_approachAnnot!);
      } catch (_) {}
    }
  }

  /// Borra la ruta detrás del carro (muestra solo lo que queda por recorrer)
  Future<void> eraseRouteBehindCar(LatLng driverPos) async {
    if (_eraseBusy) return;
    final now = DateTime.now();
    if (now.difference(_lastRouteErase).inMilliseconds < _eraseIntervalMs) {
      return;
    }
    _lastRouteErase = now;

    final mgr = _polylineAnnotMgr;
    if (mgr == null || _segDist.isEmpty || _routePts.length < 2) return;
    if (_remainingRouteAnnot == null) return;

    final projectedM = _projectOntoRoute(driverPos);
    if (projectedM <= 0) return;

    // Binary search for the segment
    int lo = 0, hi = _segDist.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (_segDist[mid] <= projectedM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final segLen = _segDist[hi] - _segDist[lo];
    final t = segLen > 0.01 ? ((projectedM - _segDist[lo]) / segLen).clamp(0.0, 1.0) : 0.0;
    final a = _routePts[lo];
    final b = _routePts[hi];
    final curLat = a.latitude + (b.latitude - a.latitude) * t;
    final curLng = a.longitude + (b.longitude - a.longitude) * t;

    if (!isValidLatLng(curLat, curLng)) return;

    final ahead = hi < _routePts.length ? _routePts.length - hi : 0;
    final remaining = <mapbox.Position>[
      mapbox.Position(curLng, curLat),
      ...List.generate(
        ahead,
        (i) => mapbox.Position(_routePts[hi + i].longitude, _routePts[hi + i].latitude),
      ),
    ];

    final validRemaining = remaining.where(
      (p) => isValidLatLng(p.lat.toDouble(), p.lng.toDouble())
    ).toList();
    if (validRemaining.length < 2) return;

    final geom = mapbox.LineString(coordinates: validRemaining);
    _eraseBusy = true;
    try {
      _remainingRouteAnnot!.geometry = geom;
      await mgr.update(_remainingRouteAnnot!);
    } catch (_) {
    } finally {
      _eraseBusy = false;
    }
  }

  /// Animación de dibujo progresivo de la ruta
  void startAnimatedRouteDraw(TickerProvider tickerProvider, {VoidCallback? onComplete}) {
    if (_routeDrawDone || _routePts.length < 2) return;
    _routeDrawDone = true;

    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;

    final allCoords = _routePts.map((p) =>
      mapbox.Position(p.longitude, p.latitude)
    ).toList();
    final totalPts = allCoords.length;

    // Cumulative distances
    final cumDist = <double>[0.0];
    for (int i = 1; i < totalPts; i++) {
      final prev = allCoords[i - 1];
      final cur = allCoords[i];
      final dx = cur.lng.toDouble() - prev.lng.toDouble();
      final dy = cur.lat.toDouble() - prev.lat.toDouble();
      cumDist.add(cumDist.last + math.sqrt(dx * dx + dy * dy));
    }
    final totalDist = cumDist.last;
    if (totalDist < 0.00001) return;

    final drawDurationMs = (totalPts * 10).clamp(1800, 3500);

    // Pre-create with first 2 points
    final initGeom = mapbox.LineString(coordinates: allCoords.sublist(0, 2));
    _createRouteLayer(mgr, initGeom).then((_) {
      if (_remainingRouteAnnot == null) return;

      final stopwatch = Stopwatch()..start();
      bool updating = false;
      double lastFrac = 0.0;

      _routeDrawTicker?.stop();
      _routeDrawTicker?.dispose();
      _routeDrawTicker = tickerProvider.createTicker((_) {
        if (updating) return;
        final elapsed = stopwatch.elapsedMilliseconds;
        final t = (elapsed / drawDurationMs).clamp(0.0, 1.0);

        // Smooth S-curve
        final eased = t < 0.5
            ? 4 * t * t * t
            : 1 - math.pow(-2 * t + 2, 3) / 2;
        final targetDist = eased * totalDist;

        if ((eased - lastFrac).abs() < 0.003 && t < 1.0) return;
        lastFrac = eased;

        // Find interpolated position
        int seg = 0;
        for (int i = 1; i < totalPts; i++) {
          if (cumDist[i] >= targetDist) { seg = i - 1; break; }
          if (i == totalPts - 1) seg = i - 1;
        }

        final segLen = cumDist[seg + 1] - cumDist[seg];
        final frac = segLen > 0.00001 ? (targetDist - cumDist[seg]) / segLen : 1.0;

        final a = allCoords[seg];
        final b = allCoords[seg + 1];
        final tipLng = a.lng.toDouble() + (b.lng.toDouble() - a.lng.toDouble()) * frac;
        final tipLat = a.lat.toDouble() + (b.lat.toDouble() - a.lat.toDouble()) * frac;

        final coords = <mapbox.Position>[
          ...allCoords.sublist(0, seg + 1),
          mapbox.Position(tipLng, tipLat),
        ];

        if (coords.length < 2) return;
        final geom = mapbox.LineString(coordinates: coords);

        updating = true;
        try {
          _remainingRouteAnnot!.geometry = geom;
          mgr.update(_remainingRouteAnnot!).then((_) => updating = false).catchError((_) => updating = false);
        } catch (_) { updating = false; }

        if (t >= 1.0) {
          final fullGeom = mapbox.LineString(coordinates: allCoords);
          _remainingRouteAnnot!.geometry = fullGeom;
          mgr.update(_remainingRouteAnnot!).catchError((_) {});
          _routeDrawTicker?.stop();
          onComplete?.call();
        }
      })..start();
    });
  }

  Future<void> _createRouteLayer(mapbox.PolylineAnnotationManager mgr, mapbox.LineString geom) async {
    try {
      _remainingRouteAnnot ??= await mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: geom,
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    } catch (_) {}
  }

  /// Elimina la ruta dimmed
  Future<void> removeDimmedRoute() async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || _dimmedRouteAnnot == null) return;
    try {
      await mgr.delete(_dimmedRouteAnnot!);
      _dimmedRouteAnnot = null;
    } catch (_) {}
  }

  /// Elimina la línea de approach
  Future<void> removeApproach() async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || _approachAnnot == null) return;
    try {
      await mgr.delete(_approachAnnot!);
      _approachAnnot = null;
    } catch (_) {}
  }

  /// Limpia todas las rutas
  Future<void> clear() async {
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;

    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;

    if (_remainingRouteAnnot != null) {
      try { await mgr.delete(_remainingRouteAnnot!); } catch (_) {}
      _remainingRouteAnnot = null;
    }
    if (_dimmedRouteAnnot != null) {
      try { await mgr.delete(_dimmedRouteAnnot!); } catch (_) {}
      _dimmedRouteAnnot = null;
    }
    if (_approachAnnot != null) {
      try { await mgr.delete(_approachAnnot!); } catch (_) {}
      _approachAnnot = null;
    }
    _routeDrawDone = false;
  }

  /// Reset para recreación del mapa
  void reset() {
    _remainingRouteAnnot = null;
    _dimmedRouteAnnot = null;
    _approachAnnot = null;
    _routeDrawDone = false;
  }

  // ── Helpers privados ──

  List<LatLng> _getRemainingPoints(double fromMeters) {
    if (_routePts.isEmpty || _segDist.isEmpty) return [];

    final result = <LatLng>[];
    bool started = false;

    for (int i = 0; i < _routePts.length; i++) {
      if (_segDist[i] >= fromMeters || i == _routePts.length - 1) {
        started = true;
      }
      if (started) {
        result.add(_routePts[i]);
      }
    }

    return result;
  }

  double _projectOntoRoute(LatLng p) {
    if (_routePts.length < 2) return 0;

    double bestDist = double.infinity;
    double bestM = 0;

    for (int i = 0; i + 1 < _routePts.length; i++) {
      final a = _routePts[i];
      final b = _routePts[i + 1];
      final segStartM = _segDist[i];
      final segEndM = _segDist[i + 1];
      final segLenM = segEndM - segStartM;
      if (segLenM < 0.01) continue;

      final dy = (b.latitude - a.latitude) * 111320;
      final dx = (b.longitude - a.longitude) * 111320 * math.cos(a.latitude * math.pi / 180);
      final px = (p.longitude - a.longitude) * 111320 * math.cos(a.latitude * math.pi / 180);
      final py = (p.latitude - a.latitude) * 111320;

      var t = 0.0;
      if (dx != 0 || dy != 0) {
        final segLen2 = dx * dx + dy * dy;
        t = (px * dx + py * dy) / segLen2;
        t = t.clamp(0.0, 1.0);
      }

      final projLat = a.latitude + (b.latitude - a.latitude) * t;
      final projLng = a.longitude + (b.longitude - a.longitude) * t;
      final dist = _haversine(p, LatLng(projLat, projLng)) * 1609.34;

      if (dist < bestDist) {
        bestDist = dist;
        bestM = segStartM + segLenM * t;
      }
    }

    return bestM;
  }

  void _buildSegDist() {
    _segDist = [0.0];
    double acc = 0;
    for (int i = 0; i + 1 < _routePts.length; i++) {
      acc += _haversine(_routePts[i], _routePts[i + 1]) * 1609.34;
      _segDist.add(acc);
    }
  }

  double _haversine(LatLng a, LatLng b) {
    const R = 3958.8;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;

    final h = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) * math.sin(dLng / 2) * math.sin(dLng / 2);
    return 2 * R * math.asin(math.sqrt(h));
  }

  // Getters
  List<LatLng> get routePoints => _routePts;
  List<LatLng> get tripRoutePoints => _tripRoutePts;
  double get traveledMeters => _traveledM;
  bool get routeDrawDone => _routeDrawDone;
}
