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

  // ── Chase intro: the camera swings in behind the car ──
  //
  // The chase used to take the camera over on its very first frame:
  // pitch and bearing were whatever this class last held (0 and 0 on a
  // fresh screen) and the centre jumped straight onto the car. Starting a
  // ride was a hard cut from a flat overview to a tilted close-up.
  //
  // The intro eases centre, zoom, pitch, bearing and anchor together,
  // from wherever the camera actually is to the chase frame, so the view
  // rotates around and settles behind the car. It replays whenever the
  // chase is handed back — after the rider pans, or on recenter.
  static const int _kChaseIntroMs = 1500;
  bool _introActive = false;
  bool _introSeeding = false;
  DateTime? _introStartedAt;
  LatLng? _introFromCenter;
  double _introFromZoom = 16.0;
  double _introFromPitch = 0.0;
  double _introFromBearing = 0.0;

  void startNavigationChase() {
    _navChaseActive = true;
    _lastNavFrameAt = null;
    // Leaving the approach phase — re-seed if we ever come back to it.
    _approachZoom = null;
    _lastApproachFrameAt = null;
    _beginChaseIntro();
  }

  /// Read the live camera so the intro starts from the real view rather
  /// than from this class's stale internal values.
  void _beginChaseIntro() {
    if (_map == null) return;
    _introActive = true;
    _introSeeding = true;
    _introStartedAt = null; // stamped on the first frame after seeding, so
    _introFromCenter = null; // the async read is not counted as animation
    _map!.getCameraState().then((state) {
      _introFromZoom = state.zoom;
      _introFromPitch = state.pitch;
      _introFromBearing = state.bearing;
      final c = state.center.coordinates;
      _introFromCenter = LatLng(c.lat.toDouble(), c.lng.toDouble());
      _introSeeding = false;
    }).catchError((Object e) {
      // Could not read the live camera. Drop the intro and let the chase
      // take over directly: a hard cut is worse than a swing, but a
      // camera stalled mid-ride waiting on a seed is worse than both.
      debugPrint('[TrackingMapCamera] chase intro seed failed: $e');
      _introSeeding = false;
      _introActive = false;
    });
  }

  static double _easeInOut(double t) => t < 0.5
      ? 4 * t * t * t
      : 1 - math.pow(-2 * t + 2, 3).toDouble() / 2;

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
    // Abandon any intro in flight. The rider has the camera now, and a
    // half-finished swing must never resume from a stale start point.
    _introActive = false;
    _introSeeding = false;
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
    //
    // Pulled back ~1.5 levels from the original 17.5/16.5/15.5/14.5. At
    // 17.5 a stopped car filled the screen with a single block — the
    // rider could see the car but not the street it was on, where it was
    // heading, or how far was left. They are a passenger watching, not a
    // driver navigating; legibility beats intimacy.
    final targetZoom = speedMps < 2.0
        ? 16.0
        : speedMps < 8.0
            ? 15.4
            : speedMps < 18.0
                ? 14.8
                : 14.0;

    // ── Intro: swing in and settle behind the car ──
    //
    // Absolute interpolation from the seeded start values, not the per-frame
    // low-pass the steady state uses: the low-pass approaches its target
    // asymptotically, which is right for chasing a moving car but would
    // leave the opening move drifting in for several seconds with no
    // defined end. The intro has a duration and an easing curve.
    if (_introActive) {
      if (_introSeeding || _introFromCenter == null) return; // seed in flight
      _introStartedAt ??= now;
      final t = (now.difference(_introStartedAt!).inMilliseconds /
              _kChaseIntroMs)
          .clamp(0.0, 1.0);
      final e = _easeInOut(t);

      // A stopped car has no meaningful heading — hold the starting bearing
      // instead of swinging the map to a stale one.
      final introTargetBearing = speedMps < 1.0 ? _introFromBearing : bearing;
      var introDb = introTargetBearing - _introFromBearing;
      while (introDb > 180) {
        introDb -= 360;
      }
      while (introDb < -180) {
        introDb += 360;
      }

      final from = _introFromCenter!;
      _navZoom = _introFromZoom + (targetZoom - _introFromZoom) * e;
      _navPitch = _introFromPitch +
          ((use3DPitch ? 35.0 : 0.0) - _introFromPitch) * e;
      _navBearing = (_introFromBearing + introDb * e) % 360;

      // The anchor eases too. A bounds-fit camera sits on the viewport
      // centre; the chase hangs the car 62% down the visible box. Snapping
      // that in one frame slides the car across the screen right as the
      // swing lands.
      final introVisibleH = screenSize.height - topPadding - bottomPadding;
      final anchorYFrom = screenSize.height / 2;
      final anchorYTo = topPadding + introVisibleH * 0.62;

      _writeChaseFrame(
        center: LatLng(
          from.latitude + (driverPos.latitude - from.latitude) * e,
          from.longitude + (driverPos.longitude - from.longitude) * e,
        ),
        anchorX: screenSize.width / 2,
        anchorY: anchorYFrom + (anchorYTo - anchorYFrom) * e,
      );

      if (t >= 1.0) _introActive = false;
      return;
    }

    // Bearing: freeze when nearly stopped so the map doesn't spin in traffic.
    var targetBearing = bearing;
    if (speedMps < 1.0) {
      targetBearing = _navBearing;
    }

    // Smooth bearing via shortest arc.
    var db = targetBearing - _navBearing;
    while (db > 180) {
      db -= 360;
    }
    while (db < -180) {
      db += 360;
    }
    _navBearing = (_navBearing + db * tf(0.25)) % 360;

    // Smooth pitch: animate into 3D once chase starts.
    //
    // 35°, not the 55° a driver's turn-by-turn view uses. At 55° the road
    // ahead compresses into a thin band at the top and the map stops
    // being readable — combined with the old close zoom, that is the view
    // the rider complained about. 35° keeps a sense of depth and motion
    // while the streets stay legible.
    final targetPitch = use3DPitch ? 35.0 : 0.0;
    _navPitch = _navPitch + (targetPitch - _navPitch) * tf(0.12);

    // Smooth zoom.
    _navZoom = _navZoom + (targetZoom - _navZoom) * tf(0.08);

    // Anchor the driver a bit above the lower third of the visible map area
    // (Uber-style): enough road ahead is visible while the car stays prominent.
    final visibleH = screenSize.height - topPadding - bottomPadding;
    final anchorX = screenSize.width / 2;
    final anchorY = topPadding + visibleH * 0.62;

    _writeChaseFrame(
      center: driverPos,
      anchorX: anchorX,
      anchorY: anchorY,
    );
  }

  /// Push one chase frame to the map.
  ///
  /// Instant setCamera, NOT an animated easeTo. Every value handed in is
  /// already smoothed — by tf() against real dt in the steady state, by the
  /// easing curve during the intro — so the smoothing lives in our own
  /// state. Layering a 150 ms easeTo on top, restarted before it ever
  /// finished on every single frame, smoothed an already-smooth signal and
  /// left the camera rubber-banding behind the car it was chasing. Feeding
  /// pre-smoothed values straight in is what makes the map glide with the
  /// marker instead of after it.
  void _writeChaseFrame({
    required LatLng center,
    required double anchorX,
    required double anchorY,
  }) {
    if (_map == null) return;
    if (_frameInFlight) return;
    _frameInFlight = true;
    try {
      _map!
          .setCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
            coordinates: mapbox.Position(center.longitude, center.latitude),
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
