import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';

/// ═══════════════════════════════════════════════════════════════════
///  TrackingMapRoute — Gestión de líneas de ruta en el mapa
/// ═══════════════════════════════════════════════════════════════════
class TrackingMapRoute {
  TrackingMapRoute(this._polylineAnnotMgr);

  final mapbox.PolylineAnnotationManager? _polylineAnnotMgr;

  mapbox.PolylineAnnotation? _remainingRouteAnnot;
  mapbox.PolylineAnnotation? _dimmedRouteAnnot;
  mapbox.PolylineAnnotation? _approachAnnot;

  List<LatLng> _routePts = [];
  List<LatLng> _tripRoutePts = [];
  List<double> _segDist = [];

  double _traveledM = 0;
  double _tgtTraveledM = 0;

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
  }

  /// Dibuja la ruta completa (dimmed) como fondo
  Future<void> drawDimmedRoute() async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || _routePts.length < 2) return;

    // Eliminar ruta anterior si existe
    if (_dimmedRouteAnnot != null) {
      try { await mgr.delete(_dimmedRouteAnnot!); } catch (_) {}
    }

    final line = mapbox.LineString(
      coordinates: _routePts.map((p) =>
        mapbox.Position(p.longitude, p.latitude)
      ).toList(),
    );

    _dimmedRouteAnnot = await mgr.create(
      mapbox.PolylineAnnotationOptions(
        geometry: line,
        lineColor: const Color(0x40E8C547).toARGB32(),
        lineWidth: 4.0,
      ),
    );
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

    _remainingRouteAnnot = await mgr.create(
      mapbox.PolylineAnnotationOptions(
        geometry: line,
        lineColor: const Color(0xFFE8C547).toARGB32(),
        lineWidth: 5.0,
      ),
    );
  }

  /// Dibuja línea de approach (conductor → pickup)
  Future<void> drawApproach(LatLng driverPos, LatLng pickupPos) async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;

    if (_approachAnnot != null) {
      try { await mgr.delete(_approachAnnot!); } catch (_) {}
    }

    final line = mapbox.LineString(
      coordinates: [
        mapbox.Position(driverPos.longitude, driverPos.latitude),
        mapbox.Position(pickupPos.longitude, pickupPos.latitude),
      ],
    );

    _approachAnnot = await mgr.create(
      mapbox.PolylineAnnotationOptions(
        geometry: line,
        lineColor: const Color(0xFFE8C547).toARGB32(),
        lineWidth: 3.0,
        // Note: dasharray not supported in this version of Mapbox SDK
      ),
    );
  }

  /// Limpia todas las rutas
  Future<void> clear() async {
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
  }

  /// Obtiene los puntos restantes de la ruta desde una distancia dada
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

  /// Proyecta un punto sobre la ruta y devuelve la distancia acumulada
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

  /// Construye las distancias acumuladas por segmento
  void _buildSegDist() {
    _segDist = [0.0];
    double acc = 0;
    for (int i = 0; i + 1 < _routePts.length; i++) {
      acc += _haversine(_routePts[i], _routePts[i + 1]) * 1609.34;
      _segDist.add(acc);
    }
  }

  /// Distancia haversine en millas
  double _haversine(LatLng a, LatLng b) {
    const R = 3958.8; // Radio de la Tierra en millas
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
}
