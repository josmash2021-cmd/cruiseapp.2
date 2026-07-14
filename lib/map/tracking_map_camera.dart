import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';

/// ═══════════════════════════════════════════════════════════════════
///  TrackingMapCamera — Control de cámara del mapa de tracking
/// ═══════════════════════════════════════════════════════════════════
class TrackingMapCamera {
  TrackingMapCamera(this._map);

  final mapbox.MapboxMap? _map;

  bool _cameraAnimating = false;
  DateTime? _cameraAnimEnd;
  DateTime _lastBoundsFit = DateTime(2000);

  /// Ajusta la cámara para mostrar todos los puntos con padding
  Future<void> fitBounds({
    required List<LatLng> points,
    required double topPadding,
    required double bottomPadding,
    double leftPadding = 44,
    double rightPadding = 44,
    int durationMs = 800,
    double minZoom = 11.0,
    double maxZoom = 16.0,
  }) async {
    if (_map == null || points.isEmpty) return;
    if (_cameraAnimating && DateTime.now().isBefore(_cameraAnimEnd!)) return;

    double minLat = points[0].latitude, maxLat = points[0].latitude;
    double minLng = points[0].longitude, maxLng = points[0].longitude;
    for (final p in points) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }

    final cam = await _map!.cameraForCoordinatesPadding(
      [
        mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
        mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
      ],
      mapbox.CameraOptions(bearing: 0, pitch: 0),
      mapbox.MbxEdgeInsets(
        top: topPadding,
        bottom: bottomPadding,
        left: leftPadding,
        right: rightPadding,
      ),
      null, null,
    );

    final zoom = (cam.zoom ?? 14.0).clamp(minZoom, maxZoom);
    final clampedCam = mapbox.CameraOptions(
      center: cam.center,
      zoom: zoom,
      bearing: cam.bearing,
      pitch: cam.pitch,
      padding: cam.padding,
      anchor: cam.anchor,
    );

    _cameraAnimating = true;
    _cameraAnimEnd = DateTime.now().add(Duration(milliseconds: durationMs - 50));
    await _map!.flyTo(clampedCam, mapbox.MapAnimationOptions(duration: durationMs));

    Future.delayed(Duration(milliseconds: durationMs), () {
      _cameraAnimating = false;
    });
  }

  /// Cámara de persecución estilo navegación (driver + dropoff)
  Future<void> chaseCamera({
    required LatLng driverPos,
    required LatLng dropoffPos,
    required double topPadding,
    required double bottomPadding,
    double minZoom = 12.0,
    double maxZoom = 16.0,
    int durationMs = 800,
  }) async {
    if (_map == null) return;
    if (driverPos.latitude == 0 && driverPos.longitude == 0) return;
    if (_cameraAnimating && DateTime.now().isBefore(_cameraAnimEnd!)) return;

    final pts = <mapbox.Point>[
      mapbox.Point(coordinates: mapbox.Position(driverPos.longitude, driverPos.latitude)),
      mapbox.Point(coordinates: mapbox.Position(dropoffPos.longitude, dropoffPos.latitude)),
    ];

    _cameraAnimating = true;
    _cameraAnimEnd = DateTime.now().add(Duration(milliseconds: durationMs - 50));

    final camera = await _map!.cameraForCoordinatesPadding(
      pts,
      mapbox.CameraOptions(bearing: 0, pitch: 0),
      mapbox.MbxEdgeInsets(
        top: topPadding,
        bottom: bottomPadding,
        left: 28,
        right: 28,
      ),
      null, null,
    );

    final computedZoom = camera.zoom ?? 15.0;
    final zoom = math.max(minZoom, math.min(maxZoom, computedZoom));

    await _map!.flyTo(
      mapbox.CameraOptions(
        center: camera.center,
        zoom: zoom,
        bearing: 0,
        pitch: 0,
        padding: camera.padding,
      ),
      mapbox.MapAnimationOptions(duration: durationMs),
    );

    Future.delayed(Duration(milliseconds: durationMs), () {
      _cameraAnimating = false;
    });
  }

  /// Ajusta cámara para mostrar pickup + dropoff (fase arrived)
  Future<void> fitArrivedBounds({
    required LatLng pickupPos,
    required LatLng dropoffPos,
    required List<LatLng> routePoints,
    required double topPadding,
    required double bottomPadding,
    int durationMs = 1300,
  }) async {
    if (_map == null) return;

    final pts = <LatLng>[pickupPos, dropoffPos];
    if (routePoints.isNotEmpty) {
      pts.addAll(routePoints);
    }

    double minLat = pts[0].latitude, maxLat = pts[0].latitude;
    double minLng = pts[0].longitude, maxLng = pts[0].longitude;
    for (final p in pts) {
      minLat = math.min(minLat, p.latitude);
      maxLat = math.max(maxLat, p.latitude);
      minLng = math.min(minLng, p.longitude);
      maxLng = math.max(maxLng, p.longitude);
    }

    final cam = await _map!.cameraForCoordinatesPadding(
      [
        mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
        mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
      ],
      mapbox.CameraOptions(bearing: 0, pitch: 0),
      mapbox.MbxEdgeInsets(
        top: topPadding,
        bottom: bottomPadding,
        left: 44,
        right: 44,
      ),
      null, null,
    );

    final zoom = (cam.zoom ?? 14.0).clamp(13.0, 16.0);
    final clampedCam = mapbox.CameraOptions(
      center: cam.center,
      zoom: zoom,
      bearing: cam.bearing,
      pitch: cam.pitch,
      padding: cam.padding,
      anchor: cam.anchor,
    );

    await _map!.flyTo(clampedCam, mapbox.MapAnimationOptions(duration: durationMs));
  }

  /// Centra la cámara en el conductor con zoom cercano
  Future<void> centerOnDriver({
    required LatLng driverPos,
    required double topPadding,
    required double bottomPadding,
    double zoom = 16.4,
    int durationMs = 1100,
  }) async {
    if (_map == null) return;

    final point = mapbox.Point(
      coordinates: mapbox.Position(driverPos.longitude, driverPos.latitude),
    );

    try {
      final cam = await _map!.cameraForCoordinatesPadding(
        [point],
        mapbox.CameraOptions(zoom: zoom, bearing: 0, pitch: 0),
        mapbox.MbxEdgeInsets(
          top: topPadding,
          bottom: bottomPadding,
          left: 28,
          right: 28,
        ),
        null, null,
      );
      await _map!.flyTo(cam, mapbox.MapAnimationOptions(duration: durationMs));
    } catch (_) {
      await _map!.flyTo(
        mapbox.CameraOptions(center: point, zoom: zoom, bearing: 0, pitch: 0),
        mapbox.MapAnimationOptions(duration: durationMs),
      );
    }
  }

  /// Vuela hacia el conductor al inicio del viaje (zoom 16.5)
  Future<void> flyToDriverStart({
    required LatLng driverPos,
    required double topPadding,
    required double bottomPadding,
    int durationMs = 1500,
  }) async {
    if (_map == null) return;

    await _map!.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(driverPos.longitude, driverPos.latitude),
        ),
        zoom: 16.5,
        bearing: 0,
        pitch: 0,
        padding: mapbox.MbxEdgeInsets(
          top: topPadding,
          bottom: bottomPadding,
          left: 40,
          right: 40,
        ),
      ),
      mapbox.MapAnimationOptions(duration: durationMs),
    );
  }

  /// Centra la cámara en una posición genérica
  Future<void> centerOn(LatLng pos, {double zoom = 15.0, int durationMs = 600}) async {
    if (_map == null) return;
    await _map!.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: mapbox.Position(pos.longitude, pos.latitude)),
        zoom: zoom,
      ),
      mapbox.MapAnimationOptions(duration: durationMs),
    );
  }

  /// Throttle para evitar llamadas excesivas a fitBounds
  bool shouldThrottleBoundsFit({int minIntervalMs = 1500}) {
    final now = DateTime.now();
    if (now.difference(_lastBoundsFit).inMilliseconds < minIntervalMs) return true;
    _lastBoundsFit = now;
    return false;
  }

  /// Verifica si hay una animación de cámara en curso
  bool get isAnimating => _cameraAnimating;

  // ═══════════════════════════════════════════════════════════════════
  //  NAVIGATION CHASE CAMERA — estilo Uber/Waze
  // ═══════════════════════════════════════════════════════════════════
  bool _navChaseActive = false;
  double _navBearing = 0;
  double _navPitch = 0;
  double _navZoom = 16.0;
  DateTime? _lastNavFrameAt;

  bool get isNavChaseActive => _navChaseActive;

  void startNavigationChase() {
    _navChaseActive = true;
    _lastNavFrameAt = null;
  }

  void stopNavigationChase() {
    _navChaseActive = false;
  }

  /// Update the chase camera frame. Call from a ~20-30 fps ticker.
  ///
  /// [driverPos]   Smoothed car position (e.g. _animPos).
  /// [bearing]     Smoothed car bearing (e.g. _animBearing).
  /// [speedMps]    Driver speed in m/s for adaptive zoom.
  /// [screenSize]  Full screen size.
  /// [topPadding] / [bottomPadding]  Visible map insets (cards + safe area).
  /// [use3DPitch]  When true, pitch is 55° like Uber; false = 2D north-up.
  void updateChaseFrame({
    required LatLng driverPos,
    required double bearing,
    required double speedMps,
    required Size screenSize,
    required double topPadding,
    required double bottomPadding,
    bool use3DPitch = true,
  }) {
    if (_map == null) return;
    if (driverPos.latitude == 0 && driverPos.longitude == 0) return;

    final now = DateTime.now();
    final dtSec = _lastNavFrameAt == null
        ? 0.0
        : now.difference(_lastNavFrameAt!).inMilliseconds / 1000.0;
    _lastNavFrameAt = now;

    // Time-based interpolation factor; works at any refresh rate.
    double tf(double base) =>
        1.0 - math.pow(1.0 - base, (dtSec.clamp(0.0, 0.1) * 60)).toDouble();

    // Zoom by speed: closer when stopped, wider as the car goes faster.
    final targetZoom = speedMps < 2.0
        ? 17.5
        : speedMps < 8.0
            ? 16.5
            : speedMps < 18.0
                ? 15.5
                : 14.5;

    // Bearing: freeze when nearly stopped so the map doesn't spin in traffic.
    var targetBearing = bearing;
    if (speedMps < 1.0) {
      targetBearing = _navBearing;
    }

    // Smooth bearing via shortest arc.
    var db = targetBearing - _navBearing;
    while (db > 180) db -= 360;
    while (db < -180) db += 360;
    _navBearing = (_navBearing + db * tf(0.25)) % 360;

    // Smooth pitch: animate into 3D once chase starts.
    final targetPitch = use3DPitch ? 55.0 : 0.0;
    _navPitch = _navPitch + (targetPitch - _navPitch) * tf(0.12);

    // Smooth zoom.
    _navZoom = _navZoom + (targetZoom - _navZoom) * tf(0.08);

    // Anchor the driver a bit above the lower third of the visible map area
    // (Uber-style): enough road ahead is visible while the car stays prominent.
    final visibleH = screenSize.height - topPadding - bottomPadding;
    final anchorX = screenSize.width / 2;
    final anchorY = topPadding + visibleH * 0.62;

    // Fire-and-forget easeTo: short duration gives a continuous glide
    // without serializing the ticker behind the platform channel.
    try {
      _map!.easeTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(driverPos.longitude, driverPos.latitude),
          ),
          zoom: _navZoom,
          bearing: _navBearing,
          pitch: _navPitch,
          anchor: mapbox.ScreenCoordinate(x: anchorX, y: anchorY),
        ),
        mapbox.MapAnimationOptions(duration: 150),
      ).catchError((e) {
        debugPrint('[TrackingMapCamera] easeTo failed: $e');
      });
    } catch (e) {
      debugPrint('[TrackingMapCamera] easeTo error: $e');
    }
  }
}
