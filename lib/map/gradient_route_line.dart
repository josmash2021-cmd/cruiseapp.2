import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../models/lat_lng.dart';

/// The card rail's line on the map (owner 2026-11-04, "mismo diseño para la
/// línea de ruta… la línea de la página de navegación hazla igual"): gold
/// where the line starts, white where it ends. An annotation cannot carry a
/// gradient, so this is a style layer: one GeoJSON source with
/// `lineMetrics` (what makes `line-progress` exist) and one LineLayer under
/// the street names. Annotations (pins, rings, the car) stay above it.
///
/// Writes are coalesced — one in flight, the latest pending — so a burst
/// (the draw-on, the trim) never queues, and the LAST geometry always lands.
class GradientRouteLine {
  GradientRouteLine({
    required this.sourceId,
    required this.layerId,
    this.width = 6.5,
  });

  final String sourceId;
  final String layerId;
  final double width;

  bool _shown = false;
  bool _faded = false;
  bool _busy = false;
  List<LatLng>? _pending;
  mapbox.MapboxMap? _pendingMap;

  /// A line is on the map (its last write landed and it was not hidden).
  bool get isShown => _shown;

  /// The gradient: gold at progress 0, white at 1.
  static const List<Object> gradient = [
    'interpolate',
    ['linear'],
    ['line-progress'],
    0,
    'rgba(232, 197, 71, 1)',
    1,
    'rgba(255, 255, 255, 1)',
  ];

  /// The layers the line goes under, first one the style has.
  static const List<String> belowLayers = ['road-label-simple', 'road-label'];

  static String geoJson(List<LatLng> pts) => jsonEncode({
        'type': 'Feature',
        'properties': <String, Object>{},
        'geometry': {
          'type': 'LineString',
          'coordinates': [
            for (final p in pts)
              if (p.latitude.isFinite && p.longitude.isFinite)
                [p.longitude, p.latitude],
          ],
        },
      });

  /// Draws [pts] (creating the source and layer the first time). False
  /// when the style refused it — not loaded yet, or the surface is gone;
  /// the caller simply draws again later.
  Future<bool> set(mapbox.MapboxMap map, List<LatLng> pts) async {
    if (pts.length < 2) return false;
    if (_busy) {
      _pending = pts;
      _pendingMap = map;
      return true;
    }
    _busy = true;
    var ok = false;
    try {
      ok = await _write(map, pts);
      while (_pending != null) {
        final next = _pending!;
        final m = _pendingMap ?? map;
        _pending = null;
        _pendingMap = null;
        ok = await _write(m, next);
      }
    } finally {
      _busy = false;
    }
    return ok;
  }

  Future<bool> _write(mapbox.MapboxMap map, List<LatLng> pts) async {
    final style = map.style;
    try {
      final data = geoJson(pts);
      if (await style.styleSourceExists(sourceId)) {
        await style.setStyleSourceProperty(sourceId, 'data', data);
      } else {
        await style.addSource(mapbox.GeoJsonSource(
          id: sourceId,
          data: data,
          lineMetrics: true,
        ));
      }
      if (!await style.styleLayerExists(layerId)) {
        final layer = mapbox.LineLayer(
          id: layerId,
          sourceId: sourceId,
          lineCap: mapbox.LineCap.ROUND,
          lineJoin: mapbox.LineJoin.ROUND,
          lineWidth: width,
          lineGradientExpression: gradient,
        );
        var placed = false;
        for (final below in belowLayers) {
          if (!await style.styleLayerExists(below)) continue;
          try {
            await style.addLayerAt(layer, mapbox.LayerPosition(below: below));
            placed = true;
            break;
          } catch (_) {}
        }
        if (!placed) await style.addLayer(layer);
      } else if (!_shown) {
        await style.setStyleLayerProperty(layerId, 'visibility', 'visible');
      }
      _shown = true;
      return true;
    } catch (e) {
      debugPrint('[GradientRouteLine] $layerId write failed: $e');
      return false;
    }
  }

  /// Fades the drawn line (an offer leaving); the next [hide] puts it back
  /// to full strength for the next [set].
  Future<void> setOpacity(mapbox.MapboxMap map, double opacity) async {
    _faded = opacity < 1;
    try {
      if (await map.style.styleLayerExists(layerId)) {
        await map.style.setStyleLayerProperty(layerId, 'line-opacity', opacity);
      }
    } catch (_) {}
  }

  /// Takes the line off the map (kept, hidden, for the next [set]).
  Future<void> hide(mapbox.MapboxMap map) async {
    _pending = null;
    _shown = false;
    try {
      if (await map.style.styleLayerExists(layerId)) {
        await map.style.setStyleLayerProperty(layerId, 'visibility', 'none');
        if (_faded) {
          _faded = false;
          await map.style.setStyleLayerProperty(layerId, 'line-opacity', 1.0);
        }
      }
    } catch (_) {}
  }

  /// The surface (and its style) is gone: nothing is drawn any more.
  void forget() {
    _pending = null;
    _pendingMap = null;
    _shown = false;
    _faded = false;
  }
}
