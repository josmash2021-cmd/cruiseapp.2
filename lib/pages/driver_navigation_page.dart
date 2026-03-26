import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import '../widgets/verified_avatar.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../config/mapbox_config.dart';
import '../config/map_theme.dart';
import '../models/lat_lng.dart';

import '../config/map_styles.dart';
import '../navigation/nav_state_machine.dart';
import '../navigation/car_icon_loader.dart';
import '../navigation/route_snapper.dart';
import '../navigation/route_service.dart';
import '../navigation/smooth_motion.dart';
import '../services/api_service.dart';
import '../services/navigation_service.dart';
import '../l10n/app_localizations.dart';
import '../widgets/driver_action_panel.dart';
import '../widgets/gold_pin_renderer.dart';

class DriverNavigationPage extends StatefulWidget {
  const DriverNavigationPage({
    super.key,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    this.tripId = '',
    this.initialDriverPos,
    this.routePoints,
    this.riderName = 'Rider',
    this.riderPhotoUrl = '',
    this.riderRating = 0,
    this.pickupLabel = '',
    this.dropoffLabel = '',
    this.vehiclePlate = '',
    this.speedLimitMph = 35,
  });

  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String tripId;
  final LatLng? initialDriverPos;
  final List<LatLng>? routePoints;
  final String riderName;
  final String riderPhotoUrl;
  final double riderRating;
  final String pickupLabel;
  final String dropoffLabel;
  final String vehiclePlate;
  final int speedLimitMph;

  @override
  State<DriverNavigationPage> createState() => _DriverNavigationPageState();
}

class _DriverNavigationPageState extends State<DriverNavigationPage>
    with TickerProviderStateMixin {
  mapbox.MapboxMap? _map;
  bool _mapReady = false;
  late final NavStateMachine _sm;
  late final SmoothMotion _motion;
  final NavigationService _navService = NavigationService();

  LatLng _pos = const LatLng(0, 0);
  double _bearing = 0;
  int _snapIdx = 0;
  bool _cameraFollowing = true;
  Timer? _reFollowTimer;
  bool _hasResumedOnce = false;
  DateTime? _lastCameraUpdate;

  List<LatLng> _routePts = [];
  List<LatLng> _displayRoutePts = [];
  NavigationState? _navState;

  double _distRemainingMi = 0;
  int _etaMinutes = 0;

  StreamSubscription? _gpsSub;
  bool _muted = false;
  Uint8List? _arrowIconBytes;
  Uint8List? _destPinBytes;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  mapbox.PointAnnotation? _driverAnnot;
  mapbox.PointAnnotation? _destAnnot;
  mapbox.PolylineAnnotation? _routeAnnot;
  double _currentSpeedMph = 0;
  DateTime? _lastAnnotUpdate;
  bool _isRerouting = false;
  Timer? _etaRefreshTimer;

  // ── Cinematic route animation ─────────────────────────────────────────
  List<LatLng> _animatedRoute = [];
  bool _routeAnimating = false;
  bool _cinematicDone = false;
  Ticker? _routeDrawTicker;

  // ── Dynamic speed limit ───────────────────────────────────────────────
  int? _dynamicSpeedLimit;

  // ── Dest pin pop animation ────────────────────────────────────────────
  double _destPinScale = 0.0;
  Timer? _destPinAnimTimer;

  static const _navy = Color(0xFF0A2463);
  static const _red = Color(0xFFEF5350);
  static const _gold = Color(0xFFD4A24C);
  static const _cardBg = Color(0xFF1A1E2E);
  static const _cardBorder = Color(0xFF2A2F42);
  static const _textPrimary = Color(0xFFF0F0F5);
  static const _textSecondary = Color(0xFF8A8FA0);

  @override
  void initState() {
    super.initState();
    _pos = widget.initialDriverPos ?? widget.pickupLatLng;
    _sm = NavStateMachine(
      onPhaseChanged: (p) {
        if (mounted) setState(() {});
        _onPhaseChanged(p);
      },
    );
    _sm.startTrip(
      tripId: widget.tripId,
      pickup: widget.pickupLatLng,
      dropoff: widget.dropoffLatLng,
    );
    _motion = SmoothMotion(
      onTick: _onMotionTick,
      lerpFactor: 0.08,  // Más suave/fluido (antes 0.22)
      enablePrediction: true,
    );
    _motion.start(this);
    _motion.teleport(_pos, 0);
    _buildArrowIcon();
    _routePts =
        widget.routePoints ?? _makeStraightRoute(_pos, widget.pickupLatLng);
    _displayRoutePts = List.of(_routePts);
    _cameraFollowing = false; // wait for cinematic sequence
    _buildRouteOnInit();

    // Periodic ETA refresh every 30 seconds
    _etaRefreshTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshEtaRoute(),
    );
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _reFollowTimer?.cancel();
    _etaRefreshTimer?.cancel();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _destPinAnimTimer?.cancel();
    _motion.dispose();
    _sm.dispose();
    _map?.dispose();
    super.dispose();
  }

  Future<void> _buildRouteOnInit() async {
    if (widget.routePoints == null) {
      final dest = (_sm.phase == TripPhase.toPickup)
          ? widget.pickupLatLng
          : widget.dropoffLatLng;
      final route = await RouteService.fetchNavRoute(
        origin: _pos,
        destination: dest,
      );
      if (route != null && mounted) {
        _routePts = route.overviewPolyline;
        _displayRoutePts = List.of(_routePts);
        _navService.startNavigation(route);
        // Extract speed limit annotations if available
        _extractSpeedLimits(route);
      }
    }
    if (mounted) setState(() {});
    _startGPS();
  }

  void _startGPS() {
    _gpsSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 1,
          ),
        ).listen((pos) {
          if (!mounted) return;
          // speed is in m/s, convert to mph
          _currentSpeedMph = (pos.speed * 2.23694).clamp(0, 200);
          _onRawPosition(LatLng(pos.latitude, pos.longitude), pos.heading);
        });
  }

  void _onRawPosition(LatLng raw, double rawBearing) {
    final snap = RouteSnapper.snap(raw, _routePts, lastIndex: _snapIdx);
    _snapIdx = snap.segmentIndex;
    _motion.pushTarget(snap.snapped, snap.bearingDeg);
    if (_navService.isNavigating) {
      _navState = _navService.updatePosition(snap.snapped);
    }
    _sm.checkProximity(snap.snapped);
    _trimRouteBehind(snap.segmentIndex);
    _updateDynamicSpeedLimit();
    final dest = _sm.phase == TripPhase.onTrip
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    final dM = _haversineM(snap.snapped, dest);
    setState(() {
      _distRemainingMi = dM / 1609.34;
      _etaMinutes =
          _navState?.etaMinutes ?? (dM / 500 / 60).ceil().clamp(1, 99);
    });

    // Auto-reroute when off-route
    if (_navState != null && _navState!.isOffRoute && !_isRerouting) {
      _isRerouting = true;
      _reroute(dest).then((_) {
        if (mounted) _isRerouting = false;
      });
    }
  }

  void _trimRouteBehind(int segIdx) {
    if (segIdx < 2 || segIdx >= _routePts.length) return;
    _displayRoutePts = _routePts.sublist(segIdx);
  }

  void _onMotionTick(LatLng pos, double bearing, double curveTilt) {
    if (!mounted) return;
    _pos = pos;
    _bearing = bearing;
    setState(() {});

    final now = DateTime.now();

    // Update car annotation at ~30 fps (every 33 ms).
    // This is the imperative Mapbox annotation update — without this call
    // the car marker stays frozen at its initial position.
    if (_map != null &&
        _mapReady &&
        _arrowIconBytes != null &&
        (_lastAnnotUpdate == null ||
            now.difference(_lastAnnotUpdate!).inMilliseconds > 33)) {
      _lastAnnotUpdate = now;
      // You could pass curveTilt to _updateDriverAnnotation if you had multiple car sprites
      _updateDriverAnnotation();
    }

    // Throttle camera to ~60 Hz for super fluid real-time tracking
    if (_cameraFollowing &&
        _map != null &&
        _mapReady &&
        (_lastCameraUpdate == null ||
            now.difference(_lastCameraUpdate!).inMilliseconds > 16)) {
      _lastCameraUpdate = now;
      // Añadir inercia a la cámara: tilt dinámico basado en velocidad angular
      final dynamicTilt = (60.0 + (curveTilt.abs() * 12.0)).clamp(60.0, 75.0);
      _animateCameraNav(pos, bearing: bearing, tilt: dynamicTilt);
    }
  }

  void _onPhaseChanged(TripPhase phase) {
    if (phase == TripPhase.onTrip) {
      _hasResumedOnce = false;
      _cameraFollowing = false;
      _switchToDropoffRoute();
    }
  }

  Future<void> _switchToDropoffRoute() async {
    final route = await RouteService.fetchNavRoute(
      origin: _pos,
      destination: widget.dropoffLatLng,
    );
    if (route != null && mounted) {
      _routePts = route.overviewPolyline;
      _displayRoutePts = List.of(_routePts);
      _navService.startNavigation(route);
      _extractSpeedLimits(route);
      _snapIdx = 0;
      setState(() {});
      // Run full cinematic for the new route
      await _runCinematicSequence();
    } else if (mounted) {
      _routePts = _makeStraightRoute(_pos, widget.dropoffLatLng);
      _displayRoutePts = List.of(_routePts);
      _snapIdx = 0;
      _cameraFollowing = true;
      setState(() {});
    }
  }

  // =========================================================================
  //  CINEMATIC ROUTE FILL + CAMERA SEQUENCE
  // =========================================================================

  Future<void> _startCinematicEntry() async {
    if (_routePts.length < 2 || _cinematicDone) return;
    _cinematicDone = true;
    await _runCinematicSequence();
  }

  /// Phase A: top-down → route fill → Phase B: 45° → Phase C: 65° chase.
  Future<void> _runCinematicSequence() async {
    // Phase A — Zoom to top-down showing full route
    await _zoomToShowRoute();
    await Future.delayed(const Duration(milliseconds: 400));

    // Animated route draw (1.5s, easeInOut)
    await _drawRouteAnimated();

    // Phase B — Transition to 45° behind driver (1.5s)
    final midCenter = _lookaheadPoint(_pos, _bearing, 60);
    _map?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
            coordinates: mapbox.Position(midCenter.longitude, midCenter.latitude)),
        zoom: 16.0,
        bearing: _bearing,
        pitch: 45,
      ),
      mapbox.MapAnimationOptions(duration: 1500, startDelay: 0),
    );
    await Future.delayed(const Duration(milliseconds: 1600));

    // Pause 0.5s at 45°
    await Future.delayed(const Duration(milliseconds: 500));

    // Phase C — Settle to 65° chase-camera (1s)
    _map?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
            coordinates: mapbox.Position(
                _lookaheadPoint(_pos, _bearing, 50).longitude,
                _lookaheadPoint(_pos, _bearing, 50).latitude)),
        zoom: 17.0,
        bearing: _bearing,
        pitch: 65,
      ),
      mapbox.MapAnimationOptions(duration: 1000, startDelay: 0),
    );
    await Future.delayed(const Duration(milliseconds: 1100));

    // Enable continuous tracking
    if (mounted) {
      setState(() => _cameraFollowing = true);
    }
  }

  Future<void> _zoomToShowRoute() async {
    if (_routePts.isEmpty) return;
    final all = [..._routePts, _pos];
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in all) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final midLat = (minLat + maxLat) / 2;
    final midLng = (minLng + maxLng) / 2;
    final span = math.max(maxLat - minLat, maxLng - minLng);
    final zoom = span > 0
        ? (math.log(360 / span) / math.ln2).clamp(8.0, 14.5)
        : 13.0;
    _map?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: mapbox.Position(midLng, midLat)),
        zoom: zoom,
        bearing: 0,
        pitch: 0,
      ),
      mapbox.MapAnimationOptions(duration: 800, startDelay: 0),
    );
    await Future.delayed(const Duration(milliseconds: 900));
  }

  /// Draw route progressively at 60fps via Ticker (1.5s, easeInOut).
  Future<void> _drawRouteAnimated() async {
    if (_routePts.length < 2) return;
    _routeAnimating = true;
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    const totalMs = 1500;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final progress = (stopwatch.elapsedMilliseconds / totalMs).clamp(0.0, 1.0);
      final eased = Curves.easeInOut.transform(progress);
      final count = (eased * _routePts.length).round().clamp(1, _routePts.length);
      _animatedRoute = _routePts.sublist(0, count);
      _updateRouteAnnotationAnimated(_animatedRoute);

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        _routeAnimating = false;
        _animatedRoute = List.from(_routePts);
        _displayRoutePts = List.from(_routePts);
        _updateRouteAnnotation();
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  /// Animated variant: updates route polyline during progressive draw.
  Future<void> _updateRouteAnnotationAnimated(List<LatLng> pts) async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || pts.length < 2) return;
    final coords = pts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    final geo = mapbox.LineString(coordinates: coords);
    if (_routeAnnot != null) {
      _routeAnnot!.geometry = geo;
      try { await mgr.update(_routeAnnot!); } catch (_) {}
    } else {
      _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: geo,
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    }
  }

  // =========================================================================
  //  DYNAMIC SPEED LIMIT
  // =========================================================================

  List<int?> _segmentSpeedLimits = [];

  void _extractSpeedLimits(dynamic route) {
    // Try to extract maxspeed annotations from route data
    try {
      final annotations = route.speedLimitsMph as List<int?>?;
      if (annotations != null && annotations.isNotEmpty) {
        _segmentSpeedLimits = annotations;
        return;
      }
    } catch (_) {}
    // Fallback: infer from street names
    _segmentSpeedLimits = [];
  }

  void _updateDynamicSpeedLimit() {
    if (_segmentSpeedLimits.isNotEmpty && _snapIdx < _segmentSpeedLimits.length) {
      final limit = _segmentSpeedLimits[_snapIdx];
      if (limit != _dynamicSpeedLimit) {
        setState(() => _dynamicSpeedLimit = limit);
      }
      return;
    }
    // Infer from street name
    final street = (_navState?.currentStep?.streetName ?? '').toLowerCase();
    final maneuver = _navState?.currentManeuver ?? '';
    int? limit;
    if (street.contains('interstate') || street.contains('i-') ||
        street.contains('freeway') || street.contains('turnpike') ||
        street.contains('expressway') || street.contains('motorway')) {
      limit = 65;
    } else if (street.contains('highway') || street.contains('hwy') ||
               street.contains('parkway') || street.contains('pkwy') ||
               maneuver.contains('merge') || maneuver.contains('ramp')) {
      limit = 55;
    } else if (street.contains('boulevard') || street.contains('blvd') ||
               street.contains('avenue') || street.contains('ave') ||
               street.contains('road') || street.contains('rd') ||
               street.contains('drive') || street.contains('dr')) {
      limit = 35;
    } else if (street.isNotEmpty) {
      limit = 25;
    } else {
      limit = null; // hide when no data
    }
    if (limit != _dynamicSpeedLimit) {
      setState(() => _dynamicSpeedLimit = limit);
    }
  }

  // =========================================================================
  //  DEST PIN POP/BOUNCE ANIMATION
  // =========================================================================

  void _animateDestPinPop() {
    _destPinScale = 0.0;
    _destPinAnimTimer?.cancel();
    const totalMs = 450;
    final sw = Stopwatch()..start();
    _destPinAnimTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
      if (!mounted) { t.cancel(); return; }
      final p = (sw.elapsedMilliseconds / totalMs).clamp(0.0, 1.0);
      final eased = Curves.elasticOut.transform(p);
      _destPinScale = eased;
      // Update annotation iconSize
      final mgr = _pointAnnotMgr;
      final annot = _destAnnot;
      if (mgr != null && annot != null) {
        annot.iconSize = _destPinScale;
        try { mgr.update(annot); } catch (_) {}
      }
      if (p >= 1.0) t.cancel();
    });
  }

  /// Re-fetch route from current position when driver goes off-route.
  Future<void> _reroute(LatLng dest) async {
    final route = await RouteService.fetchNavRoute(origin: _pos, destination: dest);
    if (!mounted || route == null) return;
    setState(() {
      _routePts = route.overviewPolyline;
      _displayRoutePts = List.of(_routePts);
      _snapIdx = 0;
      _distRemainingMi = route.totalDistanceMiles;
      _etaMinutes = route.totalDurationMinutes;
    });
    _navService.startNavigation(route);
    _updateRouteAnnotation();
  }

  /// Periodic ETA refresh — re-fetch route every 30 seconds for fresh data.
  Future<void> _refreshEtaRoute() async {
    if (!mounted || _isRerouting) return;
    if (_sm.phase == TripPhase.arrivedPickup ||
        _sm.phase == TripPhase.arrivedDropoff ||
        _sm.phase == TripPhase.completed) {
      return;
    }
    final dest = _sm.phase == TripPhase.onTrip
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    final route = await RouteService.fetchNavRoute(origin: _pos, destination: dest);
    if (!mounted || route == null) return;
    setState(() {
      _routePts = route.overviewPolyline;
      _displayRoutePts = List.of(_routePts);
      _snapIdx = 0;
      _distRemainingMi = route.totalDistanceMiles;
      _etaMinutes = route.totalDurationMinutes;
    });
    _navService.startNavigation(route);
    _updateRouteAnnotation();
  }

  // =========================================================================
  //  NAVIGATION CAR ICON — compact Google-Maps style car
  // =========================================================================

  Future<void> _buildArrowIcon() async {
    final raw = await CarIconLoader.loadUberBytes();
    if (!mounted || raw == null) return;
    setState(() { _arrowIconBytes = raw; });
    _updateDriverAnnotation();
  }

  // ignore: unused_element
  Future<void> _buildArrowIconLegacy() async {
    const double w = 120;
    const double h = 220;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

    const double cx = w / 2;
    const double cy = h / 2 + 5;

    const bodyMain = Color(0xFF2E4A5E);
    const bodyLight = Color(0xFF4A6B82);
    const bodyDark = Color(0xFF1A2E3D);
    const bodyHi = Color(0xFF6B8FA3);
    const underBody = Color(0xFF0F1A22);
    const glass = Color(0xFF2A3A4A);
    const glassHi = Color(0xFF5A7A8A);
    const wheelColor = Color(0xFF0A0A0A);
    const rimColor = Color(0xFF4A4A4A);
    const headlightCol = Color(0xFFFFFFFF);
    const taillightCol = Color(0xFFFF2222);
    const outlineColor = Color(0xFF000000);
    const spoilerColor = Color(0xFF1A2E3D);

    const double bW = 28.0;
    const double bH = 52.0;
    const double depth = 5.0;

    // ── MODERN AERODYNAMIC BODY SHAPE ──
    Path modernCarBody(double ox, double oy, double hw, double hh) {
      return Path()
        // Front nose - sharp, aerodynamic
        ..moveTo(ox, oy - hh)
        ..cubicTo(
          ox + hw * 0.3, oy - hh,
          ox + hw * 0.7, oy - hh * 0.88,
          ox + hw, oy - hh * 0.65,
        )
        // Hood curve - sleek line
        ..lineTo(ox + hw * 0.98, oy - hh * 0.35)
        // Windshield base
        ..cubicTo(
          ox + hw * 0.95, oy - hh * 0.15,
          ox + hw * 0.85, oy + hh * 0.05,
          ox + hw * 0.75, oy + hh * 0.12,
        )
        // Roof line - fastback style
        ..lineTo(ox + hw * 0.4, oy + hh * 0.15)
        // Rear pillar curve
        ..cubicTo(
          ox + hw * 0.15, oy + hh * 0.18,
          ox + hw * 0.05, oy + hh * 0.55,
          ox, oy + hh * 0.95,
        )
        // Rear bumper - integrated
        ..cubicTo(
          ox - hw * 0.1, oy + hh,
          ox - hw * 0.3, oy + hh,
          ox - hw * 0.4, oy + hh * 0.92,
        )
        // Left side mirrors back
        ..lineTo(ox - hw * 0.75, oy + hh * 0.12)
        // Left windshield base
        ..cubicTo(
          ox - hw * 0.85, oy + hh * 0.05,
          ox - hw * 0.95, oy - hh * 0.15,
          ox - hw * 0.98, oy - hh * 0.35,
        )
        // Left hood
        ..lineTo(ox - hw, oy - hh * 0.65)
        // Left front curve
        ..cubicTo(
          ox - hw * 0.7, oy - hh * 0.88,
          ox - hw * 0.3, oy - hh,
          ox, oy - hh,
        )
        ..close();
    }

    // ── 1. Ground shadow ──
    canvas.drawPath(
      modernCarBody(cx, cy + 10, bW + 3, bH + 2),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.5)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12),
    );

    // ── 2. 3D undercarriage ──
    canvas.drawPath(
      modernCarBody(cx, cy + depth, bW, bH),
      Paint()..color = underBody,
    );

    // ── 3. MODERN ALLOY WHEELS ──
    for (final wp in [
      Offset(cx - bW * 0.75, cy - bH * 0.42), // front-left
      Offset(cx + bW * 0.75, cy - bH * 0.42), // front-right
      Offset(cx - bW * 0.70, cy + bH * 0.48), // rear-left
      Offset(cx + bW * 0.70, cy + bH * 0.48), // rear-right
    ]) {
      final wheelCenter = wp.translate(0, depth * 0.5);
      // Tire
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: wheelCenter, width: 9, height: 16),
          const Radius.circular(3),
        ),
        Paint()..color = wheelColor,
      );
      // Rim (silver)
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: wheelCenter, width: 5, height: 10),
          const Radius.circular(2),
        ),
        Paint()..color = rimColor,
      );
      // Rim spokes highlight
      canvas.drawLine(
        wheelCenter.translate(-2, -3),
        wheelCenter.translate(2, 3),
        Paint()..color = Colors.white.withValues(alpha: 0.3)..strokeWidth = 1,
      );
    }

    // ── 4. MAIN BODY (Modern metallic) ──
    final bodyPath = modernCarBody(cx, cy, bW, bH);
    final bodyRect = bodyPath.getBounds();

    // Base metallic fill
    canvas.drawPath(bodyPath, Paint()..color = bodyMain);

    // Metallic gradient (top to bottom)
    canvas.drawPath(
      bodyPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [bodyHi, bodyLight, bodyMain, bodyDark],
          stops: const [0.0, 0.3, 0.6, 1.0],
        ).createShader(bodyRect),
    );

    // Side highlight for 3D effect
    canvas.drawPath(
      bodyPath,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-0.8, -0.3),
          end: const Alignment(0.8, 0.3),
          colors: [
            Colors.white.withValues(alpha: 0.2),
            Colors.transparent,
            Colors.transparent,
            Colors.black.withValues(alpha: 0.15),
          ],
        ).createShader(bodyRect),
    );

    // Sharp outline
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = outlineColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    // ── 5. AERODYNAMIC HOOD LINES ──
    for (final side in [-1.0, 1.0]) {
      canvas.drawLine(
        Offset(cx + side * bW * 0.20, cy - bH * 0.82),
        Offset(cx + side * bW * 0.15, cy - bH * 0.45),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.25)
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round,
      );
    }
    // Center hood crease
    canvas.drawLine(
      Offset(cx, cy - bH * 0.85),
      Offset(cx, cy - bH * 0.40),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..strokeWidth = 0.8,
    );

    // ── 6. PANORAMIC WINDSHIELD ──
    final windshieldPath = Path()
      ..moveTo(cx - bW * 0.65, cy - bH * 0.32)
      ..lineTo(cx - bW * 0.55, cy - bH * 0.08)
      ..lineTo(cx + bW * 0.55, cy - bH * 0.08)
      ..lineTo(cx + bW * 0.65, cy - bH * 0.32)
      ..close();
    
    canvas.drawPath(windshieldPath, Paint()..color = glass);
    
    // Windshield reflection
    canvas.drawPath(
      windshieldPath,
      Paint()
        ..shader = LinearGradient(
          begin: const Alignment(-0.8, -0.8),
          end: const Alignment(0.5, 0.5),
          colors: [
            glassHi.withValues(alpha: 0.6),
            glass,
            glass.withValues(alpha: 0.8),
          ],
        ).createShader(windshieldPath.getBounds()),
    );

    // ── 7. PANORAMIC ROOF (glass roof) ──
    final roofPath = Path()
      ..moveTo(cx - bW * 0.52, cy - bH * 0.05)
      ..lineTo(cx - bW * 0.48, cy + bH * 0.18)
      ..lineTo(cx + bW * 0.48, cy + bH * 0.18)
      ..lineTo(cx + bW * 0.52, cy - bH * 0.05)
      ..close();
    
    canvas.drawPath(roofPath, Paint()..color = glass.withValues(alpha: 0.9));
    
    // Roof reflection
    canvas.drawPath(
      roofPath,
      Paint()
        ..shader = LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            Colors.white.withValues(alpha: 0.3),
            Colors.transparent,
          ],
        ).createShader(roofPath.getBounds()),
    );

    // ── 8. REAR WINDOW (fastback style) ──
    final rearWindowPath = Path()
      ..moveTo(cx - bW * 0.45, cy + bH * 0.22)
      ..lineTo(cx - bW * 0.35, cy + bH * 0.52)
      ..lineTo(cx + bW * 0.35, cy + bH * 0.52)
      ..lineTo(cx + bW * 0.45, cy + bH * 0.22)
      ..close();
    
    canvas.drawPath(rearWindowPath, Paint()..color = glass);

    // ── 9. SIDE WINDOWS (frameless) ──
    for (final side in [-1.0, 1.0]) {
      canvas.drawPath(
        Path()
          ..moveTo(cx + side * bW * 0.58, cy - bH * 0.28)
          ..lineTo(cx + side * bW * 0.78, cy - bH * 0.22)
          ..lineTo(cx + side * bW * 0.74, cy + bH * 0.15)
          ..lineTo(cx + side * bW * 0.54, cy + bH * 0.12)
          ..close(),
        Paint()..color = glass,
      );
      // Chrome window trim
      canvas.drawPath(
        Path()
          ..moveTo(cx + side * bW * 0.58, cy - bH * 0.28)
          ..lineTo(cx + side * bW * 0.78, cy - bH * 0.22)
          ..lineTo(cx + side * bW * 0.74, cy + bH * 0.15),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.4)
          ..strokeWidth = 1
          ..style = PaintingStyle.stroke,
      );
    }

    // ── 10. MODERN LED HEADLIGHTS (slim, aggressive) ──
    for (final side in [-1.0, 1.0]) {
      // Main LED strip
      canvas.drawPath(
        Path()
          ..moveTo(cx + side * bW * 0.35, cy - bH * 0.95)
          ..quadraticBezierTo(
            cx + side * bW * 0.70, cy - bH * 0.92,
            cx + side * bW * 0.85, cy - bH * 0.78,
          )
          ..lineTo(cx + side * bW * 0.75, cy - bH * 0.82)
          ..quadraticBezierTo(
            cx + side * bW * 0.60, cy - bH * 0.88,
            cx + side * bW * 0.45, cy - bH * 0.88,
          )
          ..close(),
        Paint()..color = headlightCol,
      );
      // LED glow effect
      canvas.drawPath(
        Path()
          ..moveTo(cx + side * bW * 0.35, cy - bH * 0.95)
          ..quadraticBezierTo(
            cx + side * bW * 0.70, cy - bH * 0.92,
            cx + side * bW * 0.85, cy - bH * 0.78,
          )
          ..lineTo(cx + side * bW * 0.75, cy - bH * 0.82)
          ..lineTo(cx + side * bW * 0.60, cy - bH * 0.88)
          ..close(),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.3)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
      );
    }

    // ── 11. LED TAILLIGHTS (continuous strip) ──
    // Center strip
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + bH * 0.92),
          width: bW * 0.8,
          height: 3,
        ),
        const Radius.circular(1.5),
      ),
      Paint()..color = taillightCol,
    );
    // Side extensions
    for (final side in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + side * bW * 0.55, cy + bH * 0.90),
            width: bW * 0.35,
            height: 4,
          ),
          const Radius.circular(2),
        ),
        Paint()..color = taillightCol,
      );
    }
    // LED glow
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + bH * 0.92),
          width: bW * 0.85,
          height: 5,
        ),
        const Radius.circular(2),
      ),
      Paint()
        ..color = Colors.red.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // ── 12. SPORTY SIDE MIRRORS (aerodynamic) ──
    for (final side in [-1.0, 1.0]) {
      // Mirror body
      canvas.drawPath(
        Path()
          ..moveTo(cx + side * (bW + 2), cy - bH * 0.25)
          ..lineTo(cx + side * (bW + 6), cy - bH * 0.28)
          ..lineTo(cx + side * (bW + 6), cy - bH * 0.18)
          ..lineTo(cx + side * (bW + 2), cy - bH * 0.20)
          ..close(),
        Paint()..color = bodyMain,
      );
      // Mirror highlight
      canvas.drawLine(
        Offset(cx + side * (bW + 3), cy - bH * 0.24),
        Offset(cx + side * (bW + 5), cy - bH * 0.26),
        Paint()
          ..color = Colors.white.withValues(alpha: 0.3)
          ..strokeWidth = 1,
      );
    }

    // ── 13. REAR SPOILER (sporty ducktail) ──
    final spoilerPath = Path()
      ..moveTo(cx - bW * 0.35, cy + bH * 0.88)
      ..lineTo(cx - bW * 0.30, cy + bH * 0.78)
      ..lineTo(cx + bW * 0.30, cy + bH * 0.78)
      ..lineTo(cx + bW * 0.35, cy + bH * 0.88)
      ..close();
    
    canvas.drawPath(spoilerPath, Paint()..color = spoilerColor);
    // Spoiler highlight
    canvas.drawLine(
      Offset(cx - bW * 0.25, cy + bH * 0.80),
      Offset(cx + bW * 0.25, cy + bH * 0.80),
      Paint()
        ..color = Colors.white.withValues(alpha: 0.2)
        ..strokeWidth = 1,
    );

    // ── 14. FRONT GRILL (modern black panel) ──
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy - bH * 0.88),
          width: bW * 0.5,
          height: 6,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = Colors.black,
    );

    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted) return;
    final raw = bytes!.buffer.asUint8List();
    if (!mounted) return;
    setState(() {
      _arrowIconBytes = raw;
    });
    _updateDriverAnnotation();
  }

  void _onCameraMoveStarted() {
    if (!_cameraFollowing) return;
    setState(() => _cameraFollowing = false);
    _reFollowTimer?.cancel();
    _reFollowTimer = Timer(const Duration(seconds: 7), _recenter);
  }

  void _recenter() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    setState(() {
      _cameraFollowing = true;
      _hasResumedOnce = true;
    });
    // Smooth flyTo back to 65° tilt chase-camera (1s)
    final ahead = _lookaheadPoint(_pos, _bearing, 50);
    _map?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
            coordinates: mapbox.Position(ahead.longitude, ahead.latitude)),
        zoom: 17.0,
        bearing: _bearing,
        pitch: 65,
      ),
      mapbox.MapAnimationOptions(duration: 1000, startDelay: 0),
    );
  }

  Future<void> _updateDriverAnnotation() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    final bytes = _arrowIconBytes;
    if (bytes == null) return;
    if (_driverAnnot == null) {
      _driverAnnot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(_pos.longitude, _pos.latitude)),
        image: bytes,
        iconRotate: _bearing,
        iconSize: 1.2,
      ));
      // Car rotates relative to map (not viewport/camera) so it always points forward
      try {
        await _map?.style.setStyleLayerProperty(
          mgr.id, 'icon-rotation-alignment', 'map');
      } catch (_) {}
    } else {
      _driverAnnot!.geometry = mapbox.Point(coordinates: mapbox.Position(_pos.longitude, _pos.latitude));
      _driverAnnot!.iconRotate = _bearing;
      await mgr.update(_driverAnnot!);
    }
  }

  Future<void> _updateDestAnnotation() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    final dest = _sm.phase == TripPhase.onTrip || _sm.phase == TripPhase.arrivedDropoff
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    _destPinBytes ??= await GoldPinRenderer.render(isPickup: _sm.phase == TripPhase.toPickup);
    if (_destAnnot == null) {
      _destAnnot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(dest.longitude, dest.latitude)),
        image: _destPinBytes,
        iconSize: 0.0, // start at 0 for pop animation
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
      _animateDestPinPop();
    } else {
      _destAnnot!.geometry = mapbox.Point(coordinates: mapbox.Position(dest.longitude, dest.latitude));
      await mgr.update(_destAnnot!);
    }
  }

  Future<void> _updateRouteAnnotation() async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || _displayRoutePts.length < 2) return;
    final coords = _displayRoutePts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    final geo = mapbox.LineString(coordinates: coords);
    // Delete old layer
    if (_routeAnnot != null) {
      try { await mgr.delete(_routeAnnot!); } catch (_) {}
    }
    _routeAnnot = null;
    // Single 5px gold line
    _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geo,
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 5.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
  }

  void _animateCameraNav(
    LatLng pos, {
    double? zoom,
    double bearing = 0,
    double tilt = 60,
  }) {
    // Dynamic zoom: parked=17.5 (closer), highway=15.0 (wider view)
    final speedZoom = 17.5 - (_currentSpeedMph / 80.0).clamp(0.0, 1.0) * 2.5;
    final effectiveZoom = zoom ?? speedZoom;
    // Lookahead: shift camera center forward so more road is visible ahead
    final lookaheadM = (20.0 + _currentSpeedMph * 0.7).clamp(20.0, 80.0);
    final ahead = _lookaheadPoint(pos, bearing, lookaheadM);
    _map?.setCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(ahead.longitude, ahead.latitude)),
      zoom: effectiveZoom,
      bearing: bearing,
      pitch: tilt,
    ));
  }

  LatLng _lookaheadPoint(LatLng origin, double bearingDeg, double distM) {
    const r = 6371000.0;
    final lat1 = origin.latitude * math.pi / 180;
    final lng1 = origin.longitude * math.pi / 180;
    final b = bearingDeg * math.pi / 180;
    final lat2 = math.asin(
      math.sin(lat1) * math.cos(distM / r) +
      math.cos(lat1) * math.sin(distM / r) * math.cos(b),
    );
    final lng2 = lng1 + math.atan2(
      math.sin(b) * math.sin(distM / r) * math.cos(lat1),
      math.cos(distM / r) - math.sin(lat1) * math.sin(lat2),
    );
    return LatLng(lat2 * 180 / math.pi, lng2 * 180 / math.pi);
  }

  // =========================================================================
  //  BUILD
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final top = mq.padding.top;
    final bot = mq.padding.bottom;

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF080c16),
      body: Stack(
        children: [
          // ── FULLSCREEN MAP ────────────────────────────────────────────────
          Positioned.fill(
            child: RepaintBoundary(
              child: mapbox.MapWidget(
              styleUri: MapboxConfig.styleNavigation,
              cameraOptions: mapbox.CameraOptions(
                center: mapbox.Point(coordinates: mapbox.Position(_pos.longitude, _pos.latitude)),
                zoom: 17.5,
                pitch: 60,
                bearing: _bearing,
              ),
              onMapCreated: (ctrl) async {
                _map = ctrl;
                _mapReady = true;
                // Route polyline below road labels; points always on top
                _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
                  below: "road-label",
                );
                _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
                // Don't draw route yet — cinematic will do it
                _updateDestAnnotation();
                _updateDriverAnnotation();
                // Trigger cinematic sequence after short delay
                Future.delayed(const Duration(milliseconds: 500), () {
                  if (mounted) _startCinematicEntry();
                });
              },
              onStyleLoadedListener: (_) async {
                if (_map != null) await MapTheme.applyNavyGold(_map!);
              },
              onScrollListener: (_) => _onCameraMoveStarted(),
            ),
            ),
          ),

          // ── TOP NAV BANNER ────────────────────────────────────────────────
          Positioned(top: top + 8, left: 12, right: 12, child: _navBanner()),

          // ── DRIVER ACTION PANEL (solo mostrar cuando no es idle/completed) ──
          if (_sm.phase != TripPhase.idle && _sm.phase != TripPhase.completed)
            Positioned(
              top: top + 140,
              left: 12,
              right: 12,
              child: DriverActionPanel(
                phase: _sm.phase,
                onArrivedAtPickup: () => _sm.arriveAtPickup(),
                onStartTrip: () => _sm.beginTrip(),
                onArrivedAtDropoff: () => _sm.arriveAtDropoff(),
                onFinishTrip: () async {
                  _sm.completeTrip();
                  final tid = int.tryParse(widget.tripId);
                  if (tid != null) {
                    try {
                      await ApiService.updateTripStatus(tripId: tid, status: 'completed');
                    } catch (_) {}
                  }
                  if (context.mounted) Navigator.of(context).pop();
                },
                distanceToDestination: _distRemainingMi,
                etaMinutes: _etaMinutes,
              ),
            ),

          // ── SPEED LIMIT SIGN (bottom-left above ETA bar) ──────────────────
          Positioned(bottom: 172 + bot, left: 14, child: _speedLimitSign()),

          // ── RIGHT FLOATING BUTTON STACK ───────────────────────────────────
          Positioned(right: 14, bottom: 192 + bot, child: _rightFabStack()),

          // ── RECENTER BUTTON ───────────────────────────────────────────────
          if (!_cameraFollowing)
            Positioned(
              bottom: 290 + bot,
              left: _hasResumedOnce ? 80 : 0,
              right: _hasResumedOnce ? null : 0,
              child: _hasResumedOnce
                  ? _recenterButton()
                  : Center(child: _resumePill()),
            ),

          // ── BOTTOM PANEL: Rider info + ETA + Action ────────────────────────
          Positioned(bottom: 0, left: 0, right: 0, child: _bottomPanel(bot)),
        ],
      ),
    );
  }

  // =========================================================================
  //  TOP NAV BANNER
  // =========================================================================

  Widget _navBanner() {
    final maneuver = _navState?.currentManeuver ?? 'straight';
    final mInfo = NavigationService.getManeuverIcon(maneuver);
    final distText = _navState?.distanceToTurnText ?? '';
    final instruction = _navState?.currentInstruction ?? _phaseInstruction;
    final streetName = _navState?.currentStep?.streetName ?? '';
    final isOffRoute = _navState?.isOffRoute ?? false;
    final nextStep = _navState?.nextStep;
    final nextMInfo = nextStep != null
        ? NavigationService.getManeuverIcon(nextStep.maneuver)
        : null;

    // Banner color: green for pickup, blue for trip, red if off-route
    final bannerColor = isOffRoute
        ? const Color(0xFFD32F2F)
        : (_sm.phase == TripPhase.toPickup
              ? const Color(0xFF2E7D32)
              : const Color(0xFF1A73E8));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── PRIMARY TURN CARD (Google Maps style) ──
        Container(
          decoration: BoxDecoration(
            color: bannerColor,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Main turn row
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Large maneuver icon
                    Icon(mInfo.icon, color: Colors.white, size: 44),
                    const SizedBox(width: 12),
                    // Distance + road info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              if (distText.isNotEmpty)
                                Text(
                                  distText,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w900,
                                    height: 1.0,
                                    fontFeatures: [FontFeature.tabularFigures()],
                                  ),
                                ),
                              if (streetName.isNotEmpty) ...[
                                const SizedBox(width: 10),
                                // Road badge (like Google Maps highway shields)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    streetName,
                                    style: TextStyle(
                                      color: bannerColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            instruction,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (isOffRoute)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'OFF\nROUTE',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                            height: 1.2,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // ── Lane guidance arrows row ──
              _laneGuidanceRow(maneuver, bannerColor),
              // ── Next step preview ──
              if (nextStep != null && nextMInfo != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: bannerColor.withValues(alpha: 0.85),
                  child: Row(
                    children: [
                      Text(
                        'Then',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(nextMInfo.icon, color: Colors.white.withValues(alpha: 0.8), size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          nextStep.streetName.isNotEmpty
                              ? nextStep.streetName
                              : nextStep.distanceText,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Lane guidance arrows (Google Maps style green/white arrows)
  Widget _laneGuidanceRow(String maneuver, Color bannerColor) {
    // Determine lane arrows based on current maneuver
    final isLeft = maneuver.contains('left');
    final isRight = maneuver.contains('right');
    final isStraight = maneuver == 'straight' || maneuver.isEmpty;
    final isRamp = maneuver.contains('ramp') || maneuver.contains('fork');
    final laneCount = isRamp ? 4 : 5;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      color: bannerColor.withValues(alpha: 0.7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(laneCount, (i) {
          final isHighlighted = isStraight
              ? true
              : isLeft
                  ? (i == 0)
                  : isRight
                      ? (i == laneCount - 1)
                      : (i == laneCount ~/ 2);
          final arrowIcon = isStraight
              ? Icons.straight
              : (i == 0 && isLeft)
                  ? Icons.turn_left
                  : (i == laneCount - 1 && isRight)
                      ? Icons.turn_right
                      : Icons.straight;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(
              arrowIcon,
              size: 18,
              color: isHighlighted
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.3),
            ),
          );
        }),
      ),
    );
  }

  String get _phaseInstruction {
    final s = S.of(context);
    switch (_sm.phase) {
      case TripPhase.toPickup:
        return s.headToPickup;
      case TripPhase.arrivedPickup:
        return s.arrivedAtPickup;
      case TripPhase.onTrip:
        return s.headToDropOff;
      case TripPhase.arrivedDropoff:
        return s.arrivedAtDest;
      case TripPhase.completed:
        return s.tripComplete;
      default:
        return s.readyLabel;
    }
  }

  // =========================================================================
  //  SPEED + SPEED LIMIT — Google Maps style (current speed + limit badge)
  // =========================================================================

  Widget _speedLimitSign() {
    final speed = _currentSpeedMph.round();
    final limit = _dynamicSpeedLimit;

    // Hide when no speed limit data available
    if (limit == null) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 60), // placeholder spacing
          // Current speed only
          Container(
            width: 54,
            height: 54,
            decoration: BoxDecoration(
              color: _cardBg,
              shape: BoxShape.circle,
              border: Border.all(color: _cardBorder, width: 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 10,
                  offset: const Offset(0, 3),
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  '$speed',
                  style: const TextStyle(
                    color: _textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                    height: 1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const Text(
                  'mph',
                  style: TextStyle(
                    color: _textSecondary,
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    height: 1,
                  ),
                ),
              ],
            ),
          ),
        ],
      );
    }

    final overLimit = speed > limit + 5;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Speed limit badge (MUTCD style)
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 300),
          child: Container(
            key: ValueKey(limit),
            width: 44,
            padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: overLimit ? Colors.red : Colors.black87, width: overLimit ? 3 : 2),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.4),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'SPEED\nLIMIT',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 6,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                  ),
                ),
                Text(
                  '$limit',
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                    height: 1.1,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 6),
        // Current speed (large, like Google Maps)
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: overLimit ? _red : _cardBg,
            shape: BoxShape.circle,
            border: Border.all(
              color: overLimit ? _red : _cardBorder,
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$speed',
                style: TextStyle(
                  color: overLimit ? Colors.white : _textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                'mph',
                style: TextStyle(
                  color: overLimit
                      ? Colors.white.withValues(alpha: 0.8)
                      : _textSecondary,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // =========================================================================
  //  RIGHT FLOATING ACTION BUTTONS
  // =========================================================================

  Widget _rightFabStack() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _circleFab(
          icon: Icons.zoom_out_map_rounded,
          tooltip: S.of(context).goHomeLabel,
          iconColor: _textSecondary,
          onTap: () {
            // Toggle overview
            final dest = _sm.phase == TripPhase.onTrip
                ? widget.dropoffLatLng
                : widget.pickupLatLng;
            final midLat = (_pos.latitude + dest.latitude) / 2;
            final midLng = (_pos.longitude + dest.longitude) / 2;
            final span = math.max(
              (_pos.latitude - dest.latitude).abs(),
              (_pos.longitude - dest.longitude).abs(),
            );
            final zoom = span > 0
                ? (math.log(360 / span) / math.ln2).clamp(8.0, 14.5)
                : 13.0;
            setState(() => _cameraFollowing = false);
            _map?.flyTo(
              mapbox.CameraOptions(
                center: mapbox.Point(
                    coordinates: mapbox.Position(midLng, midLat)),
                zoom: zoom,
                bearing: 0,
                pitch: 0,
              ),
              mapbox.MapAnimationOptions(duration: 800, startDelay: 0),
            );
          },
        ),
        const SizedBox(height: 10),
        _circleFab(
          icon: Icons.music_note_rounded,
          tooltip: 'Music',
          iconColor: _textSecondary,
          onTap: () {
            HapticFeedback.lightImpact();
            _showMusicSheet();
          },
        ),
        const SizedBox(height: 10),
        _circleFab(
          icon: _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          tooltip: _muted ? S.of(context).unmuteLabel : S.of(context).muteLabel,
          iconColor: _muted ? _gold : _textSecondary,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _muted = !_muted);
          },
        ),
        const SizedBox(height: 10),
        _circleFab(
          icon: Icons.report_problem_rounded,
          tooltip: S.of(context).reportIncident,
          iconColor: _textSecondary,
          onTap: () {
            HapticFeedback.mediumImpact();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(S.of(context).incidentReported),
                duration: const Duration(seconds: 1),
              ),
            );
          },
        ),
      ],
    );
  }

  void _showMusicSheet() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111318),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.24),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const Text('Music Controls',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                )),
              const SizedBox(height: 16),
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded, color: _gold),
                title: const Text('Open Spotify',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                onTap: () => Navigator.pop(ctx),
              ),
              ListTile(
                leading: const Icon(Icons.skip_next_rounded, color: _gold),
                title: const Text('Next Track',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                onTap: () => Navigator.pop(ctx),
              ),
              ListTile(
                leading: Icon(_muted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: _gold),
                title: Text(_muted ? 'Unmute Navigation' : 'Mute Navigation',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                onTap: () {
                  setState(() => _muted = !_muted);
                  Navigator.pop(ctx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _circleFab({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? iconColor,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _cardBg,
            shape: BoxShape.circle,
            border: Border.all(color: _cardBorder, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            icon,
            color: iconColor ?? (active ? _gold : _textSecondary),
            size: 22,
          ),
        ),
      ),
    );
  }

  // =========================================================================
  //  RECENTER BUTTON
  // =========================================================================

  Widget _recenterButton() {
    return GestureDetector(
      onTap: _recenter,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: _cardBg,
          shape: BoxShape.circle,
          border: Border.all(color: _cardBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.navigation_rounded, color: _gold, size: 24),
      ),
    );
  }

  Widget _resumePill() {
    return GestureDetector(
      onTap: _recenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _cardBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.navigation_rounded, color: _gold, size: 20),
            const SizedBox(width: 8),
            Text(
              S.of(context).resumeNav,
              style: TextStyle(
                color: _gold,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  //  BOTTOM PANEL — Uber-style: rider info + ETA + phase action button
  // =========================================================================

  Widget _bottomPanel(double botPad) {
    final arrival = DateTime.now().add(Duration(minutes: _etaMinutes));
    final h12 = arrival.hour % 12 == 0 ? 12 : arrival.hour % 12;
    final min = arrival.minute.toString().padLeft(2, '0');
    final ampm = arrival.hour < 12 ? 'AM' : 'PM';
    final arrivalStr = '$h12:$min $ampm';
    final distStr = _distRemainingMi < 0.1
        ? '${(_distRemainingMi * 5280).round()} ft'
        : '${_distRemainingMi.toStringAsFixed(1)} mi';

    return Container(
      decoration: const BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(color: Color(0x55000000), blurRadius: 16, offset: Offset(0, -4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Centered ETA row ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                // Centered ETA / distance / arrival
                Expanded(
                  child: Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$_etaMinutes min',
                          style: const TextStyle(
                            color: Color(0xFF34A853),
                            fontSize: 24,
                            fontWeight: FontWeight.w900,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$distStr · $arrivalStr',
                          style: const TextStyle(
                            color: _textSecondary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                // Exit button — no confirmation dialog, just pop
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
                    decoration: BoxDecoration(
                      color: const Color(0xFF232840),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: _cardBorder, width: 1),
                    ),
                    child: const Text(
                      'Exit',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: _cardBorder),
          // ── Rider info row ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(
              children: [
                VerifiedAvatar(
                  photoUrl: widget.riderPhotoUrl.isNotEmpty ? widget.riderPhotoUrl : null,
                  radius: 20,
                  fallbackName: widget.riderName,
                  isVerified: true,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.riderName,
                        style: const TextStyle(
                          color: _textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.riderRating > 0)
                        Row(
                          children: [
                            const Icon(Icons.star_rounded, color: _gold, size: 13),
                            const SizedBox(width: 2),
                            Text(
                              widget.riderRating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: _textSecondary, fontSize: 11, fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                _currentAddressPill(),
                _miniBtn(Icons.message_rounded, () => HapticFeedback.lightImpact()),
                const SizedBox(width: 6),
                _miniBtn(Icons.phone_rounded, () => HapticFeedback.lightImpact()),
              ],
            ),
          ),
          // ── Phase action button ──
          Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, botPad + 12),
            child: _actionButton(),
          ),
        ],
      ),
    );
  }

  Widget _currentAddressPill() {
    final isPickupPhase = _sm.phase == TripPhase.toPickup || _sm.phase == TripPhase.arrivedPickup;
    final label = isPickupPhase ? widget.pickupLabel : widget.dropoffLabel;
    if (label.isEmpty) return const SizedBox.shrink();
    final icon = isPickupPhase ? Icons.radio_button_checked : Icons.location_on_rounded;
    final color = isPickupPhase ? const Color(0xFF4CAF50) : _red;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 12),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(color: _textSecondary, fontSize: 11, fontWeight: FontWeight.w500),
            maxLines: 1, overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _miniBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF232840),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _cardBorder, width: 1),
        ),
        child: Icon(icon, color: _textSecondary, size: 16),
      ),
    );
  }

  // =========================================================================
  //  ACTION BUTTON — context-aware (Uber-style slide-to-act feel)
  // =========================================================================

  Widget _actionButton() {
    String label;
    Color bg;
    IconData icon;
    VoidCallback onTap;
    final s = S.of(context);

    switch (_sm.phase) {
      case TripPhase.toPickup:
        label = s.arrivedAtPickup;
        bg = const Color(0xFF2E7D32);
        icon = Icons.check_circle_outline_rounded;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.arriveAtPickup();
        };
      case TripPhase.arrivedPickup:
        label = s.startTrip;
        bg = _gold;
        icon = Icons.play_arrow_rounded;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.beginTrip();
        };
      case TripPhase.onTrip:
        label = s.endTrip;
        bg = _red;
        icon = Icons.stop_rounded;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.arriveAtDropoff();
        };
      case TripPhase.arrivedDropoff:
        label = s.finishRide;
        bg = _gold;
        icon = Icons.flag_rounded;
        onTap = () async {
          HapticFeedback.heavyImpact();
          _sm.completeTrip();
          final nav = Navigator.of(context);
          final tid = int.tryParse(widget.tripId);
          if (tid != null) {
            try {
              await ApiService.updateTripStatus(tripId: tid, status: 'completed');
            } catch (_) {}
          }
          if (mounted) nav.pop();
        };
      default:
        return const SizedBox.shrink();
    }

    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 22),
        label: Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          elevation: 6,
          shadowColor: bg.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  // =========================================================================
  //  UTILS
  // =========================================================================

  List<LatLng> _makeStraightRoute(LatLng from, LatLng to) {
    const n = 60;
    return List.generate(n + 1, (i) {
      final t = i / n;
      return LatLng(
        from.latitude + (to.latitude - from.latitude) * t,
        from.longitude + (to.longitude - from.longitude) * t,
      );
    });
  }

  double _haversineM(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = _r(b.latitude - a.latitude);
    final dLng = _r(b.longitude - a.longitude);
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_r(a.latitude)) *
            math.cos(_r(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  double _r(double d) => d * math.pi / 180;
}
