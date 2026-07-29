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

  /// True while a camera write is crossing the platform channel. Same
  /// latest-wins discipline as the car marker: frames produced during a
  /// write are dropped, never queued, so the camera can never lag behind
  /// the animation it is chasing.
  bool _frameInFlight = false;

  // ── Approach framing (driver on the way to the pickup) ──
  // Null until the first frame seeds it from the real span, so the view
  // opens already correct instead of gliding in from a default zoom.
  double? _approachZoom;
  DateTime? _lastApproachFrameAt;

  bool get isNavChaseActive => _navChaseActive;

  /// True once [updateApproachFrame] owns the camera. Callers use this to
  /// stand down their one-shot bounds fits, exactly as they already do for
  /// the navigation chase — a flyTo landing on top of a per-frame
  /// setCamera is a visible fight.
  bool get isApproachFramingActive => _approachZoom != null;

  void startNavigationChase() {
    _navChaseActive = true;
    _lastNavFrameAt = null;
    // Leaving the approach phase — re-seed if we ever come back to it.
    _approachZoom = null;
    _lastApproachFrameAt = null;
  }

  /// Frame the driver on their way to the pickup.
  ///
  /// Keeps the car and the pickup pin both in view while continuously
  /// tightening as the gap closes: wide while they are minutes away, close
  /// enough to see which street they are turning onto once they are near.
  ///
  /// Deliberately NOT a periodic re-fit. That existed before and was
  /// removed for jumping the camera every few seconds. This moves a
  /// fraction of the way toward the target zoom on every frame, so the
  /// tightening is continuous and never reads as a jump.
  void updateApproachFrame({
    required LatLng driverPos,
    required LatLng pickupPos,
    required Size screenSize,
    required double topPadding,
    required double bottomPadding,
  }) {
    if (_map == null) return;
    if (driverPos.latitude == 0 && driverPos.longitude == 0) return;

    final now = DateTime.now();
    final dtSec = _lastApproachFrameAt == null
        ? 0.0
        : now.difference(_lastApproachFrameAt!).inMilliseconds / 1000.0;
    _lastApproachFrameAt = now;
    double tf(double base) =>
        1.0 - math.pow(1.0 - base, (dtSec.clamp(0.0, 0.1) * 60)).toDouble();

    // Midpoint: both the car and the pin stay framed the whole way in.
    final centerLat = (driverPos.latitude + pickupPos.latitude) / 2;
    final centerLng = (driverPos.longitude + pickupPos.longitude) / 2;

    final targetZoom = _zoomToFitSpan(
      driverPos,
      pickupPos,
      screenSize,
      topPadding,
      bottomPadding,
    );
    // First frame snaps; every frame after glides 6% of the remaining gap.
    _approachZoom = _approachZoom == null
        ? targetZoom
        : _approachZoom! + (targetZoom - _approachZoom!) * tf(0.06);

    if (_frameInFlight) return;
    _frameInFlight = true;
    try {
      _map!
          .setCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(centerLng, centerLat),
          ),
          zoom: _approachZoom,
          // Flat and north-up while waiting: a tilted, rotating map is
          // disorienting when you are standing still reading it.
          bearing: 0,
          pitch: 0,
        ),
      )
          .then((_) {
        _frameInFlight = false;
      }).catchError((e) {
        debugPrint('[TrackingMapCamera] approach setCamera failed: $e');
        _frameInFlight = false;
      });
    } catch (e) {
      debugPrint('[TrackingMapCamera] approach setCamera error: $e');
      _frameInFlight = false;
    }
  }

  double _zoomToFitSpan(
    LatLng a,
    LatLng b,
    Size screen,
    double topPadding,
    double bottomPadding,
  ) =>
      zoomToFitSpan(a, b, screen, topPadding, bottomPadding);

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

    // Instant setCamera, NOT an animated easeTo.
    //
    // Every value above is already low-passed by tf() against real dt, so
    // the smoothing lives here, in our own state. Layering a 150 ms easeTo
    // on top — restarted before it ever finished, every single frame —
    // smoothed an already-smooth signal and left the camera rubber-banding
    // behind the car it was chasing. Feeding pre-smoothed values straight
    // in is what makes the map glide with the marker instead of after it.
    if (_frameInFlight) return;
    _frameInFlight = true;
    try {
      _map!
          .setCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(driverPos.longitude, driverPos.latitude),
          ),
          zoom: _navZoom,
          bearing: _navBearing,
          pitch: _navPitch,
          anchor: mapbox.ScreenCoordinate(x: anchorX, y: anchorY),
        ),
      )
          .then((_) {
        _frameInFlight = false;
      }).catchError((e) {
        debugPrint('[TrackingMapCamera] setCamera failed: $e');
        _frameInFlight = false;
      });
    } catch (e) {
      debugPrint('[TrackingMapCamera] setCamera error: $e');
      _frameInFlight = false;
    }
  }
}

/// Zoom level that fits the span between two points inside the visible map
/// area (the screen minus the cards at the top and bottom).
///
/// Top-level and public so it can be unit-tested: it is pure arithmetic
/// derived from Mapbox's own metres-per-pixel relation
/// (`156543.03392 * cos(lat) / 2^zoom`), and a sign or unit slip in here
/// would silently frame the whole approach wrong.
double zoomToFitSpan(
  LatLng a,
  LatLng b,
  Size screen,
  double topPadding,
  double bottomPadding, {
  double minZoom = 11.0,
  double maxZoom = 17.0,
}) {
  final midLat = (a.latitude + b.latitude) / 2;
  final cosLat = math.cos(midLat * math.pi / 180).abs().clamp(0.01, 1.0);

  // 32 px breathing room on each side; never let the usable box hit zero
  // (a card taller than the screen would otherwise divide by ~0).
  final visibleW = math.max(screen.width - 64.0, 80.0);
  final visibleH = math.max(screen.height - topPadding - bottomPadding, 80.0);

  // Floor the span so the zoom stops tightening once the two points sit on
  // top of each other — without it the camera races to maximum zoom at the
  // exact moment the driver pulls up.
  final spanX =
      math.max((b.longitude - a.longitude).abs() * 111320.0 * cosLat, 80.0);
  final spanY = math.max((b.latitude - a.latitude).abs() * 111320.0, 80.0);

  double zoomFor(double spanM, double px) =>
      math.log(156543.03392 * cosLat * px / spanM) / math.ln2;

  final z = math.min(zoomFor(spanX, visibleW), zoomFor(spanY, visibleH));
  if (z.isNaN || z.isInfinite) return 15.0;
  return z.clamp(minZoom, maxZoom);
}
