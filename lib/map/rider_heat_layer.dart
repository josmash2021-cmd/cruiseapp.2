import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import 'rider_heat.dart';

/// The heat clouds as a native Mapbox heatmap layer ON THE MAP FLOOR —
/// under the roads, the buildings' outlines and every label (owner
/// 2026-11-05: "la zona de calor esté en el piso del mapa, no por encima de
/// las líneas"). A Flutter overlay could not sit under the streets.
///
/// Writes coalesce: while one is on the wire only the newest frame waits.
class RiderHeatLayer {
  static const String sourceId = 'rider-heat-src';
  static const String layerId = 'rider-heat';

  bool _busy = false;
  List<HeatCell>? _pending;
  mapbox.MapboxMap? _pendingMap;
  bool _created = false;

  /// Draws [cells], creating the source and layer the first time, right
  /// under [belowLayerId] (the style's lowest road layer; null = on top).
  Future<void> set(mapbox.MapboxMap map, List<HeatCell> cells,
      {String? belowLayerId, required double latDeg}) async {
    if (_busy) {
      _pending = cells;
      _pendingMap = map;
      return;
    }
    _busy = true;
    try {
      await _write(map, cells, belowLayerId, latDeg);
      while (_pending != null) {
        final next = _pending!;
        final m = _pendingMap ?? map;
        _pending = null;
        _pendingMap = null;
        await _write(m, next, belowLayerId, latDeg);
      }
    } finally {
      _busy = false;
    }
  }

  Future<void> _write(mapbox.MapboxMap map, List<HeatCell> cells,
      String? belowLayerId, double latDeg) async {
    final style = map.style;
    try {
      final data = heatGeoJson(cells);
      if (_created && await style.styleSourceExists(sourceId)) {
        await style.setStyleSourceProperty(sourceId, 'data', data);
        return;
      }
      if (!await style.styleSourceExists(sourceId)) {
        await style.addSource(mapbox.GeoJsonSource(id: sourceId, data: data));
      } else {
        await style.setStyleSourceProperty(sourceId, 'data', data);
      }
      if (!await style.styleLayerExists(layerId)) {
        final layer = mapbox.HeatmapLayer(
          id: layerId,
          sourceId: sourceId,
          heatmapWeightExpression: kHeatWeightExpression,
          heatmapIntensity: 1.0,
          heatmapRadiusExpression: heatRadiusExpression(latDeg),
          heatmapColorExpression: kHeatColorExpression,
          heatmapOpacityExpression: kHeatOpacityExpression,
        );
        if (belowLayerId != null &&
            await style.styleLayerExists(belowLayerId)) {
          await style.addLayerAt(
              layer, mapbox.LayerPosition(below: belowLayerId));
        } else {
          await style.addLayer(layer);
        }
      }
      _created = true;
    } catch (e) {
      debugPrint('[RiderHeat] layer write failed: $e');
    }
  }

  /// The surface (and its style) is gone: the next [set] builds again.
  void forget() {
    _pending = null;
    _pendingMap = null;
    _created = false;
  }
}
