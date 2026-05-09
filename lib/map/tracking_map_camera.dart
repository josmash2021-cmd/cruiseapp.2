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
    int durationMs = 1200,
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

  /// Cámara de persecución estilo navegación
  Future<void> chaseCamera({
    required LatLng driverPos,
    required LatLng dropoffPos,
    required double topPadding,
    required double bottomPadding,
    double minZoom = 12.0,
    double maxZoom = 16.0,
    int durationMs = 1200,
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

  /// Throttle para evitar llamadas excesivas a fitBounds
  bool shouldThrottleBoundsFit({int minIntervalMs = 1500}) {
    final now = DateTime.now();
    if (now.difference(_lastBoundsFit).inMilliseconds < minIntervalMs) return true;
    _lastBoundsFit = now;
    return false;
  }

  /// Centra la cámara en una posición
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

  /// Verifica si hay una animación de cámara en curso
  bool get isAnimating => _cameraAnimating;
}
