import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import 'unified_map_service.dart';

/// ═══════════════════════════════════════════════════════════════════
///  CameraDirector — Control centralizado de la cámara del mapa
/// ═══════════════════════════════════════════════════════════════════
///
/// Regula quién controla la cámara. En lugar de que cada feature
/// mueva la cámara libremente (lo que hace que el mapa "salte"),
/// el director calcula una vista óptima que las incluya a todas.
///
/// Si un feature necesita control total (navegación), puede pedir
/// control exclusivo temporal.
class CameraDirector extends ChangeNotifier {
  bool _hasExclusiveControl = false;
  String? _exclusiveHolder;

  bool get hasExclusiveControl => _hasExclusiveControl;
  String? get exclusiveHolder => _exclusiveHolder;

  /// Último padding aplicado.
  mapbox.MbxEdgeInsets _padding = mapbox.MbxEdgeInsets(
    top: 40, left: 40, bottom: 40, right: 40,
  );

  /// Solicita control exclusivo de la cámara.
  /// Devuelve un lock que debe liberarse cuando termine.
  ExclusiveCameraLock? requestExclusive(String holder) {
    if (_hasExclusiveControl && _exclusiveHolder != holder) {
      debugPrint('[CameraDirector] Exclusive denied — held by $_exclusiveHolder');
      return null;
    }
    _hasExclusiveControl = true;
    _exclusiveHolder = holder;
    notifyListeners();
    return ExclusiveCameraLock._(() => _releaseExclusive(holder));
  }

  /// Verifica si hay un control exclusivo activo (sin importar quién).
  bool get isExclusiveLocked => _hasExclusiveControl;

  void _releaseExclusive(String holder) {
    if (_exclusiveHolder != holder) return;
    _hasExclusiveControl = false;
    _exclusiveHolder = null;
    notifyListeners();
  }

  /// Verifica si [holder] tiene control exclusivo.
  bool isHeldBy(String holder) => _hasExclusiveControl && _exclusiveHolder == holder;

  /// Actualiza el padding usado para fitToBounds.
  void setPadding(mapbox.MbxEdgeInsets padding) {
    _padding = padding;
  }

  // ── Movimientos de cámara de alto nivel ──

  /// Centra en un punto con zoom.
  Future<void> centerOn(
    LatLng target, {
    double zoom = 15.0,
    int durationMs = 600,
  }) async {
    if (_hasExclusiveControl) return;
    final point = _toPoint(target);
    if (point == null) return;
    await UnifiedMapService.instance.flyTo(
      point,
      zoom: zoom,
      durationMs: durationMs,
    );
  }

  /// Ajusta para mostrar múltiples puntos.
  Future<void> fitToPoints(
    List<LatLng> points, {
    double top = 40,
    double left = 40,
    double bottom = 40,
    double right = 40,
    double? bearing,
    double? pitch,
    int durationMs = 700,
  }) async {
    if (_hasExclusiveControl) return;
    if (points.isEmpty) return;

    final mapPoints = points.map(_toPoint).whereType<mapbox.Point>().toList();
    if (mapPoints.isEmpty) return;

    await UnifiedMapService.instance.fitToPoints(
      mapPoints,
      top: top,
      left: left,
      bottom: bottom,
      right: right,
      bearing: bearing,
      pitch: pitch,
      durationMs: durationMs,
    );
  }

  /// Ajusta para mostrar pickup y dropoff.
  Future<void> fitToRoute(
    LatLng pickup,
    LatLng dropoff, {
    double top = 90,
    double left = 60,
    double bottom = 220,
    double right = 60,
    int durationMs = 700,
  }) async {
    await fitToPoints(
      [pickup, dropoff],
      top: top,
      left: left,
      bottom: bottom,
      right: right,
      durationMs: durationMs,
    );
  }

  /// Ajusta para mostrar conductor y pickup (tracking mode).
  Future<void> fitToDriverAndPickup(
    LatLng driver,
    LatLng pickup, {
    double top = 100,
    double left = 40,
    double bottom = 280,
    double right = 40,
    int durationMs = 800,
  }) async {
    await fitToPoints(
      [driver, pickup],
      top: top,
      left: left,
      bottom: bottom,
      right: right,
      durationMs: durationMs,
    );
  }

  /// Ajusta para mostrar conductor y dropoff (on-trip mode).
  Future<void> fitToDriverAndDropoff(
    LatLng driver,
    LatLng dropoff, {
    double top = 100,
    double left = 40,
    double bottom = 200,
    double right = 40,
    int durationMs = 800,
  }) async {
    await fitToPoints(
      [driver, dropoff],
      top: top,
      left: left,
      bottom: bottom,
      right: right,
      durationMs: durationMs,
    );
  }

  /// Sigue la posición del conductor (navegación exclusiva).
  Future<void> followDriver(
    LatLng driver,
    double bearing, {
    double zoom = 17.5,
    double pitch = 55,
    int durationMs = 350,
  }) async {
    // Solo funciona si se tiene control exclusivo
    if (!_hasExclusiveControl) return;
    final point = _toPoint(driver);
    if (point == null) return;
    await UnifiedMapService.instance.flyTo(
      point,
      zoom: zoom,
      bearing: bearing,
      pitch: pitch,
      durationMs: durationMs,
    );
  }

  /// Zoom out para vista general.
  Future<void> zoomOut({double zoom = 10.5, int durationMs = 800}) async {
    if (_hasExclusiveControl) return;
    final ctrl = UnifiedMapService.instance.controller;
    if (ctrl == null) return;
    try {
      final state = await ctrl.getCameraState();
      await UnifiedMapService.instance.flyTo(
        mapbox.Point(coordinates: state.center.coordinates),
        zoom: zoom,
        durationMs: durationMs,
      );
    } catch (_) {}
  }

  /// Zoom in a nivel calle.
  Future<void> zoomIn(LatLng target, {double zoom = 17.5, int durationMs = 600}) async {
    if (_hasExclusiveControl) return;
    await centerOn(target, zoom: zoom, durationMs: durationMs);
  }

  mapbox.Point? _toPoint(LatLng ll) {
    if (ll.latitude.isNaN || ll.longitude.isNaN) return null;
    return mapbox.Point(
      coordinates: mapbox.Position(ll.longitude, ll.latitude),
    );
  }
}

/// Lock de control exclusivo de cámara. Liberar con [release()].
class ExclusiveCameraLock {
  ExclusiveCameraLock._(this._release);
  final VoidCallback _release;
  bool _released = false;

  void release() {
    if (_released) return;
    _released = true;
    _release();
  }
}
