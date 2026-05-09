import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../config/mapbox_config.dart';
import '../config/map_theme.dart';

/// ═══════════════════════════════════════════════════════════════════
///  UnifiedMapService — Singleton del mapa persistente (Uber-style)
/// ═══════════════════════════════════════════════════════════════════
///
/// Un único MapboxMap que vive durante toda la vida de la app.
/// Las pantallas no crean mapas — renderizan overlays encima y
/// manipulan capas lógicas a través de este servicio.
///
/// Usage:
///   // En MapShellScreen.onMapCreated:
///   await UnifiedMapService.instance.initialize(controller);
///
///   // Desde cualquier overlay:
///   final map = UnifiedMapService.instance;
///   map.setStyle(MapStyle.dark);
///   map.camera.fitToPoints([pickup, dropoff]);
class UnifiedMapService extends ChangeNotifier {
  UnifiedMapService._();
  static final UnifiedMapService _instance = UnifiedMapService._();
  static UnifiedMapService get instance => _instance;

  mapbox.MapboxMap? _controller;
  mapbox.MapboxMap? get controller => _controller;
  bool get isReady => _controller != null;

  // ── Annotation managers (creados una sola vez) ──
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  mapbox.CircleAnnotationManager? _circleAnnotMgr;

  mapbox.PointAnnotationManager? get pointAnnotationManager => _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? get polylineAnnotationManager => _polylineAnnotMgr;
  mapbox.CircleAnnotationManager? get circleAnnotationManager => _circleAnnotMgr;

  // ── Estado ──
  MapStyle _currentStyle = MapStyle.dark;
  MapStyle get currentStyle => _currentStyle;

  bool _isNavigating = false;
  bool get isNavigating => _isNavigating;

  // ── Callbacks ──
  final List<VoidCallback> _onReadyListeners = [];

  /// Inicializa el mapa persistente. Llamar UNA VEZ desde MapShellScreen.
  Future<void> initialize(mapbox.MapboxMap ctrl) async {
    if (_controller != null) {
      debugPrint('[UnifiedMap] Already initialized, skipping');
      return;
    }
    _controller = ctrl;

    // Ocultar ornamentos nativos
    await ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    await ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    await ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
    await ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));

    // Desactivar puck nativo (usamos anotaciones custom)
    await ctrl.location.updateSettings(mapbox.LocationComponentSettings(enabled: false));

    // Crear annotation managers
    _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
      below: 'road-label',
    );
    _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
    _circleAnnotMgr = await ctrl.annotations.createCircleAnnotationManager();

    // Configurar capa de puntos
    await _configurePointLayer();

    // Aplicar tema
    await _applyTheme();

    debugPrint('[UnifiedMap] Initialized successfully');
    notifyListeners();

    // Notificar listeners pendientes
    for (final cb in _onReadyListeners) {
      cb();
    }
    _onReadyListeners.clear();
  }

  Future<void> _configurePointLayer() async {
    final mgr = _pointAnnotMgr;
    final ctrl = _controller;
    if (mgr == null || ctrl == null) return;
    try {
      final lid = mgr.id;
      await ctrl.style.setStyleLayerProperty(lid, 'icon-pitch-alignment', 'viewport');
      await ctrl.style.setStyleLayerProperty(lid, 'icon-rotation-alignment', 'viewport');
      await ctrl.style.setStyleLayerProperty(lid, 'icon-anchor', 'bottom');
      await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
      await ctrl.style.setStyleLayerProperty(lid, 'icon-ignore-placement', true);
    } catch (_) {}
  }

  Future<void> _applyTheme() async {
    final ctrl = _controller;
    if (ctrl == null) return;
    await MapTheme.applyNavyGold(ctrl);
    await _configurePointLayer();
  }

  /// Cambia el estilo del mapa (dark/light/navigation).
  Future<void> setStyle(MapStyle style) async {
    if (_currentStyle == style) return;
    _currentStyle = style;

    final ctrl = _controller;
    if (ctrl == null) return;

    final uri = switch (style) {
      MapStyle.dark => MapboxConfig.styleDark,
      MapStyle.light => MapboxConfig.styleLight,
      MapStyle.navigation => MapboxConfig.styleNavigation,
    };

    try {
      await ctrl.style.setStyleURI(uri);
      // El tema se re-aplica automáticamente vía onStyleLoaded en MapShellScreen
    } catch (e) {
      debugPrint('[UnifiedMap] setStyle error: $e');
    }
  }

  /// Ejecuta [action] cuando el mapa esté listo. Si ya está listo, ejecuta inmediatamente.
  void whenReady(VoidCallback action) {
    if (isReady) {
      action();
    } else {
      _onReadyListeners.add(action);
    }
  }

  /// Mueve la cámara a [target] con animación suave.
  Future<void> flyTo(
    mapbox.Point center, {
    double? zoom,
    double? bearing,
    double? pitch,
    int durationMs = 600,
  }) async {
    final ctrl = _controller;
    if (ctrl == null) return;
    await ctrl.flyTo(
      mapbox.CameraOptions(
        center: center,
        zoom: zoom,
        bearing: bearing,
        pitch: pitch,
      ),
      mapbox.MapAnimationOptions(duration: durationMs),
    );
  }

  /// Ajusta la cámara para mostrar todos los [points] con [padding].
  Future<void> fitToPoints(
    List<mapbox.Point> points, {
    double top = 40,
    double left = 40,
    double bottom = 40,
    double right = 40,
    double? bearing,
    double? pitch,
    int durationMs = 700,
  }) async {
    final ctrl = _controller;
    if (ctrl == null || points.isEmpty) return;
    final cam = await ctrl.cameraForCoordinatesPadding(
      points,
      mapbox.CameraOptions(
        bearing: bearing,
        pitch: pitch,
      ),
      mapbox.MbxEdgeInsets(top: top, left: left, bottom: bottom, right: right),
      null,
      null,
    );
    await ctrl.flyTo(cam, mapbox.MapAnimationOptions(duration: durationMs));
  }

  /// Centra la cámara en una posición.
  Future<void> centerOn(
    mapbox.Point center, {
    double zoom = 15.0,
    int durationMs = 600,
  }) async {
    await flyTo(center, zoom: zoom, durationMs: durationMs);
  }

  /// Activa/desactiva modo navegación (control exclusivo de cámara).
  void setNavigating(bool value) {
    _isNavigating = value;
    notifyListeners();
  }

  /// Obtiene el zoom actual.
  Future<double> getZoom() async {
    final ctrl = _controller;
    if (ctrl == null) return 15.0;
    try {
      final state = await ctrl.getCameraState();
      return state.zoom;
    } catch (_) {
      return 15.0;
    }
  }

  /// Convierte coordenadas a píxeles de pantalla.
  Future<mapbox.ScreenCoordinate?> pixelForCoordinate(mapbox.Point point) async {
    final ctrl = _controller;
    if (ctrl == null) return null;
    try {
      return await ctrl.pixelForCoordinate(point);
    } catch (_) {
      return null;
    }
  }

  /// Limpia TODAS las anotaciones (emergency reset).
  Future<void> clearAllAnnotations() async {
    try {
      final points = await _pointAnnotMgr?.getAnnotations();
      if (points != null && points.isNotEmpty) {
        await _pointAnnotMgr?.deleteMulti(points);
      }
    } catch (_) {}
    try {
      final lines = await _polylineAnnotMgr?.getAnnotations();
      if (lines != null && lines.isNotEmpty) {
        await _polylineAnnotMgr?.deleteMulti(lines);
      }
    } catch (_) {}
    try {
      final circles = await _circleAnnotMgr?.getAnnotations();
      if (circles != null && circles.isNotEmpty) {
        await _circleAnnotMgr?.deleteMulti(circles);
      }
    } catch (_) {}
  }

  /// Dispose permanente (ej: logout).
  void disposeService() {
    _controller = null;
    _pointAnnotMgr = null;
    _polylineAnnotMgr = null;
    _circleAnnotMgr = null;
    _onReadyListeners.clear();
    notifyListeners();
  }
}

/// Estilos de mapa soportados.
enum MapStyle {
  dark,
  light,
  navigation,
}
