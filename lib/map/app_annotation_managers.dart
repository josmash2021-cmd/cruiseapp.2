/// Annotation-manager abstraction over the two map backends.
///
/// The overlays speak to these interfaces using the pure-Dart data classes
/// from `mapbox_maps_flutter` (PointAnnotationOptions, PolylineAnnotation…),
/// which compile everywhere. On native, each wrapper delegates to the real
/// mapbox manager. On web, annotations become Mapbox GL JS markers /
/// GeoJSON layers via [WebMapController].
///
/// Only the operations the overlays actually use are exposed:
/// create / update / delete / deleteMulti / getAnnotations.
library;

import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import 'web_map_controller_base.dart';

// ════════════════════════════════════════════════════════════════════════════
// Interfaces
// ════════════════════════════════════════════════════════════════════════════

abstract class AppPointAnnotationManager {
  Future<mapbox.PointAnnotation?> create(mapbox.PointAnnotationOptions options);
  Future<void> update(mapbox.PointAnnotation annotation);
  Future<void> delete(mapbox.PointAnnotation annotation);
  Future<void> deleteMulti(List<mapbox.PointAnnotation> annotations);
  Future<List<mapbox.PointAnnotation>> getAnnotations();
}

abstract class AppPolylineAnnotationManager {
  Future<mapbox.PolylineAnnotation?> create(
      mapbox.PolylineAnnotationOptions options);
  Future<void> update(mapbox.PolylineAnnotation annotation);
  Future<void> delete(mapbox.PolylineAnnotation annotation);
  Future<void> deleteMulti(List<mapbox.PolylineAnnotation> annotations);
  Future<List<mapbox.PolylineAnnotation>> getAnnotations();
}

abstract class AppCircleAnnotationManager {
  Future<mapbox.CircleAnnotation?> create(
      mapbox.CircleAnnotationOptions options);
  Future<void> delete(mapbox.CircleAnnotation annotation);
  Future<void> deleteMulti(List<mapbox.CircleAnnotation> annotations);
  Future<List<mapbox.CircleAnnotation>> getAnnotations();
}

// ════════════════════════════════════════════════════════════════════════════
// Native wrappers — delegate to the real mapbox managers
// ════════════════════════════════════════════════════════════════════════════

class NativePointAnnotationManager extends AppPointAnnotationManager {
  NativePointAnnotationManager(this._inner);
  final mapbox.PointAnnotationManager _inner;

  @override
  Future<mapbox.PointAnnotation?> create(
          mapbox.PointAnnotationOptions options) =>
      _inner.create(options);

  @override
  Future<void> update(mapbox.PointAnnotation annotation) =>
      _inner.update(annotation);

  @override
  Future<void> delete(mapbox.PointAnnotation annotation) =>
      _inner.delete(annotation);

  @override
  Future<void> deleteMulti(List<mapbox.PointAnnotation> annotations) =>
      _inner.deleteMulti(annotations);

  @override
  Future<List<mapbox.PointAnnotation>> getAnnotations() async =>
      (await _inner.getAnnotations()).whereType<mapbox.PointAnnotation>().toList();
}

class NativePolylineAnnotationManager extends AppPolylineAnnotationManager {
  NativePolylineAnnotationManager(this._inner);
  final mapbox.PolylineAnnotationManager _inner;

  @override
  Future<mapbox.PolylineAnnotation?> create(
          mapbox.PolylineAnnotationOptions options) =>
      _inner.create(options);

  @override
  Future<void> update(mapbox.PolylineAnnotation annotation) =>
      _inner.update(annotation);

  @override
  Future<void> delete(mapbox.PolylineAnnotation annotation) =>
      _inner.delete(annotation);

  @override
  Future<void> deleteMulti(List<mapbox.PolylineAnnotation> annotations) =>
      _inner.deleteMulti(annotations);

  @override
  Future<List<mapbox.PolylineAnnotation>> getAnnotations() async =>
      (await _inner.getAnnotations())
          .whereType<mapbox.PolylineAnnotation>()
          .toList();
}

class NativeCircleAnnotationManager extends AppCircleAnnotationManager {
  NativeCircleAnnotationManager(this._inner);
  final mapbox.CircleAnnotationManager _inner;

  @override
  Future<mapbox.CircleAnnotation?> create(
          mapbox.CircleAnnotationOptions options) =>
      _inner.create(options);

  @override
  Future<void> delete(mapbox.CircleAnnotation annotation) =>
      _inner.delete(annotation);

  @override
  Future<void> deleteMulti(List<mapbox.CircleAnnotation> annotations) =>
      _inner.deleteMulti(annotations);

  @override
  Future<List<mapbox.CircleAnnotation>> getAnnotations() async =>
      (await _inner.getAnnotations())
          .whereType<mapbox.CircleAnnotation>()
          .toList();
}

// ════════════════════════════════════════════════════════════════════════════
// Web implementations — Mapbox GL JS via WebMapController
// ════════════════════════════════════════════════════════════════════════════

/// 0xAARRGGBB (mapbox int color) → '#RRGGBB' (GL JS).
String _hexColor(int? argb, {String fallback = '#D4AF37'}) {
  if (argb == null) return fallback;
  return '#${(argb & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}';
}

List<LngLatPoint> _lineCoords(mapbox.LineString? line) => [
      for (final p in line?.coordinates ?? const <mapbox.Position>[])
        (lng: p.lng.toDouble(), lat: p.lat.toDouble()),
    ];

class WebPointAnnotationManager extends AppPointAnnotationManager {
  WebPointAnnotationManager(this._map);

  final WebMapController _map;
  int _counter = 0;
  final _items = <String, mapbox.PointAnnotation>{};

  @override
  Future<mapbox.PointAnnotation?> create(
      mapbox.PointAnnotationOptions options) async {
    final g = options.geometry;
    if (g == null) return null;
    final id = 'web-pt-${_counter++}';
    _map.addMarker(
      id,
      g.coordinates.lng.toDouble(),
      g.coordinates.lat.toDouble(),
      iconBytes: options.image,
      rotation: options.iconRotate ?? 0,
    );
    final annotation = mapbox.PointAnnotation(
      id: id,
      geometry: g,
      image: options.image,
      iconAnchor: options.iconAnchor,
      iconOffset: options.iconOffset,
      iconRotate: options.iconRotate,
      iconSize: options.iconSize,
    );
    _items[id] = annotation;
    return annotation;
  }

  @override
  Future<void> update(mapbox.PointAnnotation annotation) async {
    final g = annotation.geometry;
    if (g == null || !_items.containsKey(annotation.id)) return;
    _map.updateMarkerPosition(
      annotation.id,
      g.coordinates.lng.toDouble(),
      g.coordinates.lat.toDouble(),
      rotation: annotation.iconRotate,
    );
  }

  @override
  Future<void> delete(mapbox.PointAnnotation annotation) async {
    _items.remove(annotation.id);
    _map.removeMarker(annotation.id);
  }

  @override
  Future<void> deleteMulti(List<mapbox.PointAnnotation> annotations) async {
    for (final a in annotations) {
      await delete(a);
    }
  }

  @override
  Future<List<mapbox.PointAnnotation>> getAnnotations() async =>
      _items.values.toList();
}

class WebPolylineAnnotationManager extends AppPolylineAnnotationManager {
  WebPolylineAnnotationManager(this._map);

  final WebMapController _map;
  int _counter = 0;
  final _items = <String, mapbox.PolylineAnnotation>{};

  @override
  Future<mapbox.PolylineAnnotation?> create(
      mapbox.PolylineAnnotationOptions options) async {
    final g = options.geometry;
    final coords = _lineCoords(g);
    if (g == null || coords.length < 2) return null;
    final id = 'web-line-${_counter++}';
    _map.setPolyline(
      id,
      coords,
      color: _hexColor(options.lineColor),
      width: options.lineWidth ?? 5,
    );
    final annotation = mapbox.PolylineAnnotation(
      id: id,
      geometry: g,
      lineColor: options.lineColor,
      lineWidth: options.lineWidth,
      lineJoin: options.lineJoin,
    );
    _items[id] = annotation;
    return annotation;
  }

  @override
  Future<void> update(mapbox.PolylineAnnotation annotation) async {
    final coords = _lineCoords(annotation.geometry);
    if (coords.length < 2 || !_items.containsKey(annotation.id)) return;
    _map.setPolyline(
      annotation.id,
      coords,
      color: _hexColor(annotation.lineColor),
      width: annotation.lineWidth ?? 5,
    );
  }

  @override
  Future<void> delete(mapbox.PolylineAnnotation annotation) async {
    _items.remove(annotation.id);
    _map.removePolyline(annotation.id);
  }

  @override
  Future<void> deleteMulti(List<mapbox.PolylineAnnotation> annotations) async {
    for (final a in annotations) {
      await delete(a);
    }
  }

  @override
  Future<List<mapbox.PolylineAnnotation>> getAnnotations() async =>
      _items.values.toList();
}

class WebCircleAnnotationManager extends AppCircleAnnotationManager {
  WebCircleAnnotationManager(this._map);

  final WebMapController _map;
  int _counter = 0;
  final _items = <String, mapbox.CircleAnnotation>{};

  @override
  Future<mapbox.CircleAnnotation?> create(
      mapbox.CircleAnnotationOptions options) async {
    final g = options.geometry;
    if (g == null) return null;
    final id = 'web-circle-${_counter++}';
    _map.setCircle(
      id,
      g.coordinates.lng.toDouble(),
      g.coordinates.lat.toDouble(),
      radiusPx: options.circleRadius ?? 60,
      color: _hexColor(options.circleColor),
      opacity: options.circleOpacity ?? 0.25,
    );
    final annotation = mapbox.CircleAnnotation(
      id: id,
      geometry: g,
      circleColor: options.circleColor,
      circleOpacity: options.circleOpacity,
      circleRadius: options.circleRadius,
    );
    _items[id] = annotation;
    return annotation;
  }

  @override
  Future<void> delete(mapbox.CircleAnnotation annotation) async {
    _items.remove(annotation.id);
    _map.removeCircle(annotation.id);
  }

  @override
  Future<void> deleteMulti(List<mapbox.CircleAnnotation> annotations) async {
    for (final a in annotations) {
      await delete(a);
    }
  }

  @override
  Future<List<mapbox.CircleAnnotation>> getAnnotations() async =>
      _items.values.toList();
}
