import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../utils/mapbox_safe.dart';
import 'unified_map_service.dart';

/// ═══════════════════════════════════════════════════════════════════
///  MapLayerManager — Gestión de capas lógicas sobre el mapa único
/// ═══════════════════════════════════════════════════════════════════
///
/// Cada feature (navegación, pins, rutas, etc.) crea su propia
/// "sandbox" o capa. Una capa no puede borrar o interferir con
/// los elementos de otra.
///
/// Si un feature necesita el mapa limpio, puede solicitar una
/// capa exclusiva que oculta temporalmente todo lo demás.
class MapLayerManager {
  MapLayerManager._();
  static final MapLayerManager _instance = MapLayerManager._();
  static MapLayerManager get instance => _instance;

  final Map<String, MapLayer> _layers = {};

  void register(String id, MapLayer layer) => _layers[id] = layer;

  MapLayer? get(String id) => _layers[id];

  void show(String id) => _layers[id]?.show();
  void hide(String id) => _layers[id]?.hide();
  void clear(String id) => _layers[id]?.clear();

  void showAll(Iterable<String> ids) {
    for (final entry in _layers.entries) {
      entry.value.setVisible(ids.contains(entry.key));
    }
  }

  /// Modo exclusivo: muestra solo [id], oculta todo lo demás.
  void showExclusive(String id) {
    for (final entry in _layers.entries) {
      entry.value.setVisible(entry.key == id);
    }
  }

  /// Muestra múltiples capas, oculta el resto.
  void showOnly(Iterable<String> ids) {
    final set = ids.toSet();
    for (final entry in _layers.entries) {
      entry.value.setVisible(set.contains(entry.key));
    }
  }

  void clearAll() {
    for (final layer in _layers.values) {
      layer.clear();
    }
  }

  void hideAll() {
    for (final layer in _layers.values) {
      layer.hide();
    }
  }
}

/// Capa lógica abstracta sobre el mapa.
abstract class MapLayer {
  bool _visible = false;
  bool get isVisible => _visible;

  void show() => setVisible(true);
  void hide() => setVisible(false);

  void setVisible(bool visible) {
    if (_visible == visible) return;
    _visible = visible;
    onVisibilityChanged(visible);
  }

  /// Llamado cuando cambia la visibilidad. Override para animar opacity, etc.
  @protected
  void onVisibilityChanged(bool visible) {}

  /// Limpia el contenido de la capa (borra anotaciones).
  Future<void> clear();
}

/// Capa de pin (pickup o dropoff).
class PinLayer extends MapLayer {
  PinLayer({required this.isPickup});

  final bool isPickup;
  mapbox.PointAnnotation? _annotation;
  Uint8List? _iconBytes;

  set iconBytes(Uint8List? bytes) => _iconBytes = bytes;

  @override
  Future<void> clear() async {
    final annot = _annotation;
    final mgr = UnifiedMapService.instance.pointAnnotationManager;
    if (annot != null && mgr != null) {
      try {
        await mgr.delete(annot);
      } catch (_) {}
    }
    _annotation = null;
  }

  Future<void> setPosition(LatLng pos) async {
    if (_iconBytes == null) return;
    await clear();
    if (!isVisible) return;

    final mgr = UnifiedMapService.instance.pointAnnotationManager;
    if (mgr == null) return;

    _annotation = await safeCreatePoint(
      mgr,
      lng: pos.longitude,
      lat: pos.latitude,
      image: _iconBytes!,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    );
  }

  @override
  void onVisibilityChanged(bool visible) {
    if (!visible) {
      clear();
    }
  }
}

/// Capa de ruta (polyline).
class RouteLayer extends MapLayer {
  mapbox.PolylineAnnotation? _annotation;
  int _lineColor = 0xFFE8C547; // gold
  double _lineWidth = 5.0;

  set lineColor(int color) => _lineColor = color;
  set lineWidth(double width) => _lineWidth = width;

  @override
  Future<void> clear() async {
    final annot = _annotation;
    final mgr = UnifiedMapService.instance.polylineAnnotationManager;
    if (annot != null && mgr != null) {
      try {
        await mgr.delete(annot);
      } catch (_) {}
    }
    _annotation = null;
  }

  Future<void> setRoute(List<LatLng> points) async {
    await clear();
    if (!isVisible || points.length < 2) return;

    final mgr = UnifiedMapService.instance.polylineAnnotationManager;
    if (mgr == null) return;

    _annotation = await safeCreatePolyline(
      mgr,
      points: points,
      lineColor: _lineColor,
      lineWidth: _lineWidth,
      lineJoin: mapbox.LineJoin.ROUND,
    );
  }

  @override
  void onVisibilityChanged(bool visible) {
    if (!visible) clear();
  }
}

/// Capa de coche del conductor (animada).
class DriverCarLayer extends MapLayer {
  mapbox.PointAnnotation? _annotation;
  Uint8List? _carIconBytes;
  LatLng? _currentPosition;
  double _currentBearing = 0;

  set carIconBytes(Uint8List? bytes) => _carIconBytes = bytes;

  @override
  Future<void> clear() async {
    final annot = _annotation;
    final mgr = UnifiedMapService.instance.pointAnnotationManager;
    if (annot != null && mgr != null) {
      try {
        await mgr.delete(annot);
      } catch (_) {}
    }
    _annotation = null;
  }

  Future<void> updatePosition(LatLng pos, double bearing) async {
    _currentPosition = pos;
    _currentBearing = bearing;

    if (!isVisible) return;

    final mgr = UnifiedMapService.instance.pointAnnotationManager;
    if (mgr == null || _carIconBytes == null) return;

    if (_annotation != null) {
      // Update existing
      safeUpdatePointGeometry(_annotation!, pos.longitude, pos.latitude);
      _annotation!.iconRotate = bearing;
      try {
        await mgr.update(_annotation!);
      } catch (_) {}
    } else {
      // Create new
      _annotation = await safeCreatePoint(
        mgr,
        lng: pos.longitude,
        lat: pos.latitude,
        image: _carIconBytes!,
        iconSize: 1.0,
        iconAnchor: mapbox.IconAnchor.CENTER,
        iconRotate: bearing,
      );
    }
  }

  @override
  void onVisibilityChanged(bool visible) {
    if (!visible) {
      clear();
    } else if (_currentPosition != null) {
      updatePosition(_currentPosition!, _currentBearing);
    }
  }
}

/// Capa de dot de ubicación actual (gold dot).
class LocationDotLayer extends MapLayer {
  mapbox.PointAnnotation? _annotation;
  Uint8List? _dotIconBytes;
  LatLng? _currentPosition;

  set dotIconBytes(Uint8List? bytes) => _dotIconBytes = bytes;

  @override
  Future<void> clear() async {
    final annot = _annotation;
    final mgr = UnifiedMapService.instance.pointAnnotationManager;
    if (annot != null && mgr != null) {
      try {
        await mgr.delete(annot);
      } catch (_) {}
    }
    _annotation = null;
  }

  Future<void> updatePosition(LatLng pos) async {
    _currentPosition = pos;
    if (!isVisible) return;

    final mgr = UnifiedMapService.instance.pointAnnotationManager;
    if (mgr == null || _dotIconBytes == null) return;

    if (_annotation != null) {
      safeUpdatePointGeometry(_annotation!, pos.longitude, pos.latitude);
      try {
        await mgr.update(_annotation!);
      } catch (_) {}
    } else {
      _annotation = await safeCreatePoint(
        mgr,
        lng: pos.longitude,
        lat: pos.latitude,
        image: _dotIconBytes!,
        iconSize: 1.0,
        iconAnchor: mapbox.IconAnchor.CENTER,
      );
    }
  }

  @override
  void onVisibilityChanged(bool visible) {
    if (!visible) {
      clear();
    } else if (_currentPosition != null) {
      updatePosition(_currentPosition!);
    }
  }
}

/// Capa de coches cercanos (múltiples pins).
class NearbyCarsLayer extends MapLayer {
  final List<mapbox.PointAnnotation> _annotations = [];
  Uint8List? _carIconBytes;

  set carIconBytes(Uint8List? bytes) => _carIconBytes = bytes;

  @override
  Future<void> clear() async {
    final mgr = UnifiedMapService.instance.pointAnnotationManager;
    if (mgr != null && _annotations.isNotEmpty) {
      try {
        await mgr.deleteMulti(_annotations.toList());
      } catch (_) {}
    }
    _annotations.clear();
  }

  Future<void> setCars(List<LatLng> positions) async {
    await clear();
    if (!isVisible || _carIconBytes == null) return;

    final mgr = UnifiedMapService.instance.pointAnnotationManager;
    if (mgr == null) return;

    for (final pos in positions) {
      final annot = await safeCreatePoint(
        mgr,
        lng: pos.longitude,
        lat: pos.latitude,
        image: _carIconBytes!,
        iconSize: 0.8,
        iconAnchor: mapbox.IconAnchor.CENTER,
      );
      if (annot != null) _annotations.add(annot);
    }
  }

  @override
  void onVisibilityChanged(bool visible) {
    if (!visible) clear();
  }
}
