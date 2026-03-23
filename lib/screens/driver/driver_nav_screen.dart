import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../navigation/nav_state_machine.dart';
import '../../navigation/route_service.dart';
import '../../navigation/route_snapper.dart';
import '../../navigation/smooth_motion.dart';
import '../../services/api_service.dart';
import '../../services/navigation_service.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  DRIVER NAV SCREEN  — DoorDash-style full navigation
//  Phases: toPickup → arrivedPickup → onTrip → arrivedDropoff → completed
// ═══════════════════════════════════════════════════════════════════════════

class DriverNavScreen extends StatefulWidget {
  const DriverNavScreen({
    super.key,
    required this.tripId,
    required this.riderName,
    this.riderPhotoUrl = '',
    this.riderRating = 4.8,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.fare,
    required this.vehicleType,
    required this.driverPos,
    this.routePoints,
    this.riderPhone = '',
    this.startWithOverview = false,
  });

  final int tripId;
  final String riderName;
  final String riderPhotoUrl;
  final double riderRating;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String pickupAddress;
  final String dropoffAddress;
  final double fare;
  final String vehicleType;
  final LatLng driverPos;
  final List<LatLng>? routePoints;
  final String riderPhone;
  final bool startWithOverview;

  @override
  State<DriverNavScreen> createState() => _DriverNavScreenState();
}

class _DriverNavScreenState extends State<DriverNavScreen>
    with SingleTickerProviderStateMixin {
  // ── Colours ──────────────────────────────────────────────────────────────
  static const _navBg      = Color(0xFF15232C); // DoorDash dark teal header
  static const _navBgSub   = Color(0xFF0F1A20);
  static const _routeBlue  = Color(0xFF4A90E2);
  static const _gold        = Color(0xFFD4A843);
  static const _bottomBg   = Color(0xFF111318);
  static const _pillBlue   = Color(0xFF1A6EBB);

  // ── Navigation engine ────────────────────────────────────────────────────
  late final NavStateMachine _sm;
  late final NavigationService _navService;
  late final SmoothMotion _motion;

  // ── Map ─────────────────────────────────────────────────────────────────────
  final _mapKey = GlobalKey();
  mapbox.MapboxMap? _map;
  bool _mapReady = false;
  mapbox.PolylineAnnotationManager? _polyMgr;
  mapbox.PointAnnotationManager? _pointMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.PolylineAnnotation? _routeCasingAnnot;
  mapbox.PointAnnotation? _driverAnnot;
  mapbox.PointAnnotation? _destAnnot;

  // ── Position & bearing ────────────────────────────────────────────────────
  LatLng _pos     = const LatLng(0, 0);
  double _bearing = 0;
  int    _lastSegIdx = 0;
  double _currentSpeedMph = 0;

  // ── Route ─────────────────────────────────────────────────────────────────
  List<LatLng> _routePts = [];

  // ── Nav state ─────────────────────────────────────────────────────────────
  NavigationState? _navState;
  double _distRemainingMi = 0;
  int    _etaMinutes      = 0;
  String _currentStreet   = '';

  // ── Camera ────────────────────────────────────────────────────────────────
  bool   _cameraFollowing  = true;
  bool   _isOverview       = false;
  bool   _hasResumedOnce   = false;
  Timer? _reFollowTimer;

  // ── UI state ──────────────────────────────────────────────────────────────
  bool   _isMuted          = false;
  bool   _nearPickup        = false;
  bool   _completing       = false;
  double _slideVal         = 0;
  bool   _slid             = false;

  // ── Car icon ──────────────────────────────────────────────────────────────
  Uint8List? _arrowBytes;

  // ── GPS ───────────────────────────────────────────────────────────────────
  StreamSubscription<Position>? _gpsSub;

  // ── Phase ─────────────────────────────────────────────────────────────────
  TripPhase get _phase => _sm.phase;

  // =========================================================================
  //  LIFECYCLE
  // =========================================================================

  @override
  void initState() {
    super.initState();
    _pos = widget.driverPos;

    // Navigation engine
    _navService = NavigationService();
    _sm = NavStateMachine(onPhaseChanged: _onPhaseChanged);
    _motion = SmoothMotion(onTick: _onMotionTick);
    _motion.start(this);
    _motion.teleport(_pos, _bearing);

    // Load car icon
    _buildArrowIcon().then((b) {
      if (mounted) setState(() => _arrowBytes = b);
    });

    // Start the trip state machine
    _sm.startTrip(
      tripId:  widget.tripId.toString(),
      pickup:  widget.pickupLatLng,
      dropoff: widget.dropoffLatLng,
    );

    // If caller already pre-fetched a route, use it; else fetch now
    if (widget.routePoints != null && widget.routePoints!.length > 1) {
      _routePts = List.of(widget.routePoints!);
    }

    // Overview mode: don't follow camera yet
    if (widget.startWithOverview) {
      _cameraFollowing = false;
      _isOverview = true;
    }

    // Fetch proper nav route (step-by-step) regardless
    _fetchRoute(widget.pickupLatLng);

    // Start GPS
    _startGps();
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _reFollowTimer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  // =========================================================================
  //  GPS
  // =========================================================================

  Future<void> _startGps() async {
    try {
      final svc  = await Geolocator.isLocationServiceEnabled();
      final perm = await Geolocator.checkPermission();
      if (!svc || perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) return;

      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 2,
        ),
      ).listen(_onGps);
    } catch (_) {}
  }

  void _onGps(Position p) {
    if (!mounted) return;
    final raw  = LatLng(p.latitude, p.longitude);
    _currentSpeedMph = p.speed * 2.23694;

    LatLng snapped = raw;
    double bearing = _bearing;

    if (_routePts.length > 1) {
      final snap = RouteSnapper.snap(raw, _routePts, lastIndex: _lastSegIdx);
      _lastSegIdx = snap.segmentIndex;
      snapped     = snap.snapped;
      bearing     = snap.bearingDeg;
    }

    _motion.pushTarget(snapped, bearing);

    // Update turn-by-turn
    final nav = _navService.updatePosition(snapped);
    if (nav != null && mounted) {
      setState(() {
        _navState        = nav;
        _distRemainingMi = nav.distanceRemainingMiles;
        _etaMinutes      = nav.etaMinutes;
        _currentStreet   = nav.currentStep?.streetName ?? _currentStreet;
      });
    }

    // Auto-proximity check for phase transitions
    _sm.checkProximity(raw);

    // Show "Arrived at Pickup" button when within 300 m
    if (_phase == TripPhase.toPickup && !_nearPickup) {
      if (_hav(raw, widget.pickupLatLng) < 0.3 && mounted) {
        setState(() => _nearPickup = true);
      }
    }
  }

  // =========================================================================
  //  SMOOTH MOTION TICK
  // =========================================================================

  void _onMotionTick(LatLng pos, double bearing, double curveTilt) {
    if (!mounted) return;
    setState(() {
      _pos     = pos;
      _bearing = bearing;
    });
    _updateCarAnnotation(pos, bearing);
    if (_cameraFollowing && !_isOverview) {
      _animateCamera(pos, bearing: bearing);
    }
  }

  // =========================================================================
  //  PHASE CHANGED
  // =========================================================================

  void _onPhaseChanged(TripPhase phase) {
    if (!mounted) return;
    HapticFeedback.mediumImpact();
    setState(() {
      _slideVal = 0;
      _slid     = false;
    });

    if (phase == TripPhase.onTrip) {
      // Driver started the trip — fetch route to dropoff
      _fetchRoute(widget.dropoffLatLng);
      _updateDestPin(widget.dropoffLatLng);
      _updateTripStatus('in_trip');
    } else if (phase == TripPhase.arrivedPickup) {
      _updateTripStatus('arrived');
    } else if (phase == TripPhase.arrivedDropoff) {
      setState(() {
        _cameraFollowing = false;
        _isOverview = true;
      });
      _animateCameraOverview(_pos, widget.dropoffLatLng);
    }
  }

  // =========================================================================
  //  ROUTE
  // =========================================================================

  Future<void> _fetchRoute(LatLng dest) async {
    final route = await RouteService.fetchNavRoute(origin: _pos, destination: dest);
    if (!mounted) return;
    if (route != null) {
      setState(() {
        _routePts        = List.of(route.overviewPolyline);
        _lastSegIdx      = 0;
        _distRemainingMi = route.totalDistanceMiles;
        _etaMinutes      = route.totalDurationMinutes;
      });
      _navService.startNavigation(route);
      _updateRouteAnnotation();
      if (widget.startWithOverview && _phase == TripPhase.toPickup) {
        await Future.delayed(const Duration(milliseconds: 200));
        _animateCameraOverview(_pos, dest);
      }
    } else if (_routePts.length > 1) {
      // Fallback: use pre-loaded overview polyline
      _updateRouteAnnotation();
    }
  }

  // =========================================================================
  //  API
  // =========================================================================

  Future<void> _updateTripStatus(String status) async {
    try {
      await ApiService.updateTripStatus(tripId: widget.tripId, status: status);
    } catch (_) {}
  }

  // =========================================================================
  //  MAP ANNOTATIONS
  // =========================================================================

  Future<void> _updateRouteAnnotation() async {
    final mgr = _polyMgr;
    if (mgr == null || _routePts.length < 2) return;
    final coords = _routePts
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();
    final geom = mapbox.LineString(coordinates: coords);

    if (_routeCasingAnnot != null) {
      try { await mgr.delete(_routeCasingAnnot!); } catch (_) {}
      _routeCasingAnnot = null;
    }
    if (_routeAnnot != null) {
      try { await mgr.delete(_routeAnnot!); } catch (_) {}
      _routeAnnot = null;
    }
    // Dark casing (border) – drawn first so it sits under the line
    _routeCasingAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFF0D2840).toARGB32(),
      lineWidth: 18.0,
    ));
    // Bright blue route line on top
    _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFF4D9FFF).toARGB32(),
      lineWidth: 13.0,
    ));
  }

  Future<void> _updateCarAnnotation(LatLng pos, double bearing) async {
    final mgr   = _pointMgr;
    final bytes = _arrowBytes;
    if (mgr == null || bytes == null) return;
    final geom = mapbox.Point(
        coordinates: mapbox.Position(pos.longitude, pos.latitude));
    if (_driverAnnot == null) {
      _driverAnnot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: geom,
        image: bytes,
        iconSize: 1.2,
        iconRotate: bearing,
      ));
      try {
        await _map?.style.setStyleLayerProperty(mgr.id, 'icon-rotation-alignment', 'map');
      } catch (_) {}
    } else {
      _driverAnnot!.geometry   = geom;
      _driverAnnot!.iconRotate = bearing;
      try { await mgr.update(_driverAnnot!); } catch (_) {}
    }
  }

  Future<void> _updateDestPin(LatLng dest) async {
    final mgr = _pointMgr;
    if (mgr == null) return;
    final geom = mapbox.Point(
        coordinates: mapbox.Position(dest.longitude, dest.latitude));
    if (_destAnnot != null) {
      try { await mgr.delete(_destAnnot!); } catch (_) {}
      _destAnnot = null;
    }
    final pinBytes = await _buildDestPin();
    if (pinBytes == null || !mounted) return;
    _destAnnot = await mgr.create(mapbox.PointAnnotationOptions(
      geometry: geom,
      image: pinBytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
      iconOffset: [0, 0],
    ));
  }

  // =========================================================================
  //  CAMERA
  // =========================================================================

  void _animateCamera(LatLng pos, {double? zoom, double bearing = 0, double tilt = 55}) {
    final speedZoom = 17.5 - (_currentSpeedMph / 80.0).clamp(0.0, 1.0) * 2.5;
    final z = zoom ?? speedZoom;
    // Lookahead offset
    final ahead = _lookaheadPoint(pos, bearing, 30.0);
    _map?.setCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(ahead.longitude, ahead.latitude)),
      zoom: z,
      bearing: bearing,
      pitch: tilt,
    ));
  }

  void _animateCameraOverview(LatLng a, LatLng b) {
    final midLat = (a.latitude  + b.latitude)  / 2;
    final midLng = (a.longitude + b.longitude) / 2;
    final latDiff = (a.latitude  - b.latitude).abs();
    final lngDiff = (a.longitude - b.longitude).abs();
    final span = math.max(latDiff, lngDiff);
    final zoom = span > 0 ? (math.log(360 / span) / math.ln2).clamp(8.0, 14.5) : 13.0;
    _map?.setCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(midLng, midLat)),
      zoom: zoom,
      bearing: 0,
      pitch: 0,
    ));
  }

  void _onCameraMoveStarted() {
    if (!_cameraFollowing) return;
    setState(() => _cameraFollowing = false);
    _reFollowTimer?.cancel();
    _reFollowTimer = Timer(const Duration(seconds: 8), _recenter);
  }

  void _recenter() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    setState(() {
      _cameraFollowing = true;
      _isOverview      = false;
      _hasResumedOnce  = true;
    });
    _animateCamera(_pos, bearing: _bearing, tilt: 55);
  }

  LatLng _lookaheadPoint(LatLng o, double bearingDeg, double distM) {
    const r    = 6371000.0;
    final lat1 = o.latitude  * math.pi / 180;
    final lng1 = o.longitude * math.pi / 180;
    final b    = bearingDeg  * math.pi / 180;
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
  //  ACTIONS
  // =========================================================================

  void _arrivedAtPickup() {
    HapticFeedback.mediumImpact();
    _sm.arriveAtPickup();
    setState(() {
      _cameraFollowing = false;
      _isOverview = true;
    });
    _animateCameraOverview(_pos, widget.pickupLatLng);
  }

  double _hav(LatLng a, LatLng b) {
    const r    = 6371.0;
    final dLat = (b.latitude  - a.latitude)  * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final s    = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude  * math.pi / 180) *
        math.cos(b.latitude  * math.pi / 180) *
        math.sin(dLng / 2) * math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(s), math.sqrt(1 - s));
  }

  void _startRide() {
    HapticFeedback.heavyImpact();
    _sm.beginTrip();
    setState(() {
      _cameraFollowing = true;
      _isOverview      = false;
    });
  }

  Future<void> _completeTrip() async {
    if (_completing) return;
    setState(() => _completing = true);
    HapticFeedback.heavyImpact();
    _sm.arriveAtDropoff();
    _sm.completeTrip();
    await _updateTripStatus('completed');
    if (mounted) Navigator.of(context).pop('completed');
  }

  void _exitNav() {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop('cancelled');
  }

  // =========================================================================
  //  CAR ICON (3D arrow with shadow)
  // =========================================================================

  Future<Uint8List?> _buildArrowIcon() async {
    const double w = 80, h = 80;
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx  = w / 2;
    final cy  = h / 2;

    // 3D fade shadow – large soft ellipse beneath the circle
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 7), width: 66, height: 22),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.38)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 3), width: 48, height: 13),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );

    // White circle body
    c.drawCircle(Offset(cx, cy), 22, Paint()..color = Colors.white);

    // Gold ring border
    c.drawCircle(
      Offset(cx, cy), 22,
      Paint()
        ..color = const Color(0xFFD4A843).withValues(alpha: 0.45)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0,
    );

    // Gold directional chevron (points UP – rotated with iconRotate)
    final chevron = Path()
      ..moveTo(cx,      cy - 13)
      ..lineTo(cx + 8,  cy + 5)
      ..lineTo(cx,      cy + 1)
      ..lineTo(cx - 8,  cy + 5)
      ..close();
    c.drawPath(chevron, Paint()..color = const Color(0xFFD4A843));

    final img   = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  Future<Uint8List?> _buildDestPin() async {
    const double w = 60;
    const double h = 80;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, const Rect.fromLTWH(0, 0, w, h));
    const cx = w / 2;
    const r = 18.0;
    const headCY = r + 6;
    const tipY = h;

    // ── Teardrop path (tip at exact bottom) ──
    final path = Path()
      ..moveTo(cx - r, headCY)
      ..arcTo(
        Rect.fromCircle(center: const Offset(cx, headCY), radius: r),
        math.pi, -math.pi, false,
      )
      ..cubicTo(cx + r, headCY + r, cx + r * 0.22, tipY - 3, cx, tipY)
      ..cubicTo(cx - r * 0.22, tipY - 3, cx - r, headCY + r, cx - r, headCY)
      ..close();

    // Shadow
    c.drawPath(
      path.shift(const Offset(0, 2)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    // Gold teardrop fill
    c.drawPath(path, Paint()..color = _gold);
    // White head circle
    c.drawCircle(const Offset(cx, headCY), r, Paint()..color = Colors.white);
    // Gold inner
    c.drawCircle(const Offset(cx, headCY), r - 5, Paint()..color = _gold);

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  // =========================================================================
  //  BUILD
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    final mq  = MediaQuery.of(context);
    final top = mq.padding.top;
    final bot = mq.padding.bottom;

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor:          Colors.transparent,
      statusBarIconBrightness: Brightness.light,
    ));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) { if (!did) _exitNav(); },
      child: Scaffold(
        backgroundColor: const Color(0xFF080C16),
        body: Stack(
          children: [
            // ── FULL MAP ─────────────────────────────────────────────────
            Positioned.fill(child: _buildMap()),

            // ── TOP HEADER ───────────────────────────────────────────────
            Positioned(top: 0, left: 0, right: 0, child: _buildNavHeader(top)),

            // ── RIGHT FAB COLUMN ─────────────────────────────────────────
            Positioned(
              right: 12,
              bottom: 90 + bot + 10,
              child: _buildRightFabs(),
            ),

            // ── BOTTOM BAR ────────────────────────────────────────────────
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: _buildBottomBar(bot),
            ),

            // ── PHASE OVERLAY (arrived / slide) ───────────────────────
            if (_nearPickup && _phase == TripPhase.toPickup)
              Positioned(
                bottom: 90 + bot + 10,
                right: 12,
                child: _buildArrivedBtn(),
              ),
            if (_phase == TripPhase.arrivedPickup)
              Positioned(
                bottom: 90 + bot,
                left: 12,
                right: 12,
                child: _buildArrivedAtPickupCard(),
              ),
            if (_phase == TripPhase.arrivedDropoff)
              Positioned(
                bottom: 90 + bot,
                left: 12,
                right: 12,
                child: _buildSlideToComplete(),
              ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  //  MAP WIDGET
  // =========================================================================

  Widget _buildMap() {
    return mapbox.MapWidget(
      key: _mapKey,
      styleUri: MapboxConfig.styleNavigation,
      cameraOptions: mapbox.CameraOptions(
        center: mapbox.Point(
            coordinates: mapbox.Position(_pos.longitude, _pos.latitude)),
        zoom: 17.0,
        pitch: 60.0,
        bearing: 0,
      ),
      onMapCreated: (ctrl) async {
        _map      = ctrl;
        _mapReady = true;
        _polyMgr  = await ctrl.annotations.createPolylineAnnotationManager();
        _pointMgr = await ctrl.annotations.createPointAnnotationManager();
        _updateRouteAnnotation();
        _updateDestPin(widget.pickupLatLng);
      },
      onStyleLoadedListener: (_) async {
        if (_map != null) await MapTheme.applyNavyGold(_map!);
      },
      onScrollListener: (_) => _onCameraMoveStarted(),
    );
  }

  // =========================================================================
  //  TOP NAV HEADER (DoorDash dark band)
  // =========================================================================

  Widget _buildNavHeader(double topPad) {
    final maneuver   = _navState?.currentManeuver ?? 'straight';
    final mInfo      = NavigationService.getManeuverIcon(maneuver);
    final distText   = _navState?.distanceToTurnText ?? '';
    final instruction = _navState?.currentInstruction ?? _phaseInstruction;
    final isOffRoute  = _navState?.isOffRoute ?? false;
    final nextStep    = _navState?.nextStep;

    final bg = isOffRoute ? const Color(0xFFB71C1C) : _navBg;
    final bgSub = isOffRoute ? const Color(0xFF8B0000) : _navBgSub;

    return Material(
      color: Colors.transparent,
      child: Container(
        color: bg,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(height: topPad),
            // Main row
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Turn icon
                  Icon(mInfo.icon, color: Colors.white, size: 42),
                  const SizedBox(width: 12),
                  // Distance + instruction
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (distText.isNotEmpty)
                          Text(distText,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 28,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                              fontFeatures: [FontFeature.tabularFigures()],
                            )),
                        const SizedBox(height: 2),
                        Text(isOffRoute ? 'Rerouting…' : instruction,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.88),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            height: 1.2,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                  // Phase pill
                  _phasePill(),
                ],
              ),
            ),
            // "Then" next step sub-row
            if (nextStep != null && !isOffRoute)
              Container(
                color: bgSub,
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: Row(
                  children: [
                    Text('Then',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      )),
                    const SizedBox(width: 8),
                    Icon(
                      NavigationService.getManeuverIcon(nextStep.maneuver).icon,
                      color: Colors.white.withValues(alpha: 0.75),
                      size: 16,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        nextStep.streetName.isNotEmpty
                            ? nextStep.streetName
                            : nextStep.distanceText,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.82),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '$_etaMinutes min  ·  ${_distRemainingMi.toStringAsFixed(1)} mi',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _phasePill() {
    String label;
    Color  bg;
    switch (_phase) {
      case TripPhase.toPickup:
        label = 'TO PICKUP';
        bg    = Colors.white.withValues(alpha: 0.15);
        break;
      case TripPhase.arrivedPickup:
        label = 'ARRIVED';
        bg    = const Color(0xFF2E7D32).withValues(alpha: 0.8);
        break;
      case TripPhase.onTrip:
        label = 'ON TRIP';
        bg    = _pillBlue.withValues(alpha: 0.8);
        break;
      case TripPhase.arrivedDropoff:
        label = 'DROPOFF';
        bg    = _gold.withValues(alpha: 0.8);
        break;
      default:
        return const SizedBox.shrink();
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(color: bg, borderRadius: BorderRadius.circular(8)),
      child: Text(label,
        style: const TextStyle(
          color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800,
          letterSpacing: 0.8)),
    );
  }

  String get _phaseInstruction {
    switch (_phase) {
      case TripPhase.toPickup:      return 'Head to pickup · ${widget.pickupAddress}';
      case TripPhase.arrivedPickup: return 'Arrived at pickup';
      case TripPhase.onTrip:        return 'Head to dropoff · ${widget.dropoffAddress}';
      case TripPhase.arrivedDropoff:return 'Arrived at destination';
      default:                       return 'Ready';
    }
  }

  // =========================================================================
  //  RIGHT FAB COLUMN
  // =========================================================================

  Widget _buildRightFabs() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. Route overview toggle
        _mapFab(
          icon: Icons.layers_rounded,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() {
              _isOverview      = !_isOverview;
              _cameraFollowing = !_isOverview;
            });
            if (_isOverview) {
              final dest = _phase == TripPhase.onTrip
                  ? widget.dropoffLatLng
                  : widget.pickupLatLng;
              _animateCameraOverview(_pos, dest);
            } else {
              _recenter();
            }
          },
          active: _isOverview,
        ),
        const SizedBox(height: 10),
        // 2. Re-center / compass — resumes 3D follow mode
        _mapFab(
          icon: Icons.navigation_rounded,
          onTap: () {
            HapticFeedback.mediumImpact();
            _recenter();
          },
          active: _cameraFollowing && !_isOverview,
        ),
        const SizedBox(height: 10),
        // 3. Safety shield
        _mapFab(
          icon: Icons.shield_rounded,
          onTap: () {},
        ),
      ],
    );
  }

  Widget _mapFab({
    required IconData icon,
    required VoidCallback onTap,
    bool active = false,
  }) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: active
                ? _pillBlue
                : const Color(0xFF1A1E28).withValues(alpha: 0.92),
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.45),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(icon,
              color: active ? Colors.white : Colors.white.withValues(alpha: 0.8),
              size: 20),
        ),
      );


  // =========================================================================
  //  BOTTOM BAR (DoorDash style)
  // =========================================================================

  Widget _buildBottomBar(double botPad) {
    final eta  = _etaMinutes;
    final dist = _distRemainingMi;
    final now  = DateTime.now();
    final arr  = now.add(Duration(minutes: eta));
    int   h    = arr.hour % 12; if (h == 0) h = 12;
    final m    = arr.minute.toString().padLeft(2, '0');
    final ap   = arr.hour >= 12 ? 'PM' : 'AM';
    final arrStr = '$h:$m $ap';
    final distStr = '${dist.toStringAsFixed(2)} mi';
    final etaLabel = eta <= 2 ? 'Arriving soon' : '$eta min';

    final maneuver = _navState?.currentManeuver ?? 'straight';
    final mInfo    = NavigationService.getManeuverIcon(maneuver);

    return Container(
      color: _bottomBg,
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // '^' overview toggle
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() {
                    _isOverview      = !_isOverview;
                    _cameraFollowing = !_isOverview;
                  });
                  if (_isOverview) {
                    final dest = _phase == TripPhase.onTrip
                        ? widget.dropoffLatLng : widget.pickupLatLng;
                    _animateCameraOverview(_pos, dest);
                  } else {
                    _recenter();
                  }
                },
                child: SizedBox(
                  width: 54,
                  child: Icon(
                    _isOverview ? Icons.zoom_in_map_rounded : Icons.keyboard_arrow_up_rounded,
                    color: Colors.white.withValues(alpha: 0.75), size: 26),
                ),
              ),
              // Turn arrow
              SizedBox(
                width: 34,
                child: Icon(mInfo.icon,
                    color: Colors.white.withValues(alpha: 0.65), size: 22),
              ),
              // ETA block (big number + sub-line)
              Expanded(
                child: eta <= 2
                    ? Text('Arriving soon',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ))
                    : Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text('$eta min',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                            )),
                          const SizedBox(height: 2),
                          Text('$distStr · $arrStr',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.6),
                              fontSize: 12,
                              fontWeight: FontWeight.w500,
                            )),
                        ],
                      ),
              ),
              // Exit button
              GestureDetector(
                onTap: _exitNav,
                child: Container(
                  height: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                  decoration: BoxDecoration(
                    border: Border(
                        left: BorderSide(
                            color: Colors.white.withValues(alpha: 0.08))),
                  ),
                  child: Center(
                    child: Text('Exit',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.8),
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // =========================================================================
  //  ARRIVED AT PICKUP CARD
  // =========================================================================

  Widget _buildArrivedAtPickupCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 24, offset: const Offset(0, -4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Rider info row
          Row(
            children: [
              // Avatar
              _riderAvatar(size: 46),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.riderName,
                      style: const TextStyle(
                        color: Colors.white, fontSize: 15,
                        fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, color: _gold, size: 13),
                        const SizedBox(width: 3),
                        Text(widget.riderRating.toStringAsFixed(1),
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 12, fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ],
                ),
              ),
              // Call + message
              _compactBtn(Icons.phone_rounded, () {}),
              const SizedBox(width: 8),
              _compactBtn(Icons.message_rounded, () {}),
            ],
          ),
          const SizedBox(height: 14),
          Text('Waiting for your rider',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13)),
          const SizedBox(height: 14),
          // Start Ride button
          SizedBox(
            width: double.infinity,
            height: 50,
            child: ElevatedButton(
              onPressed: _startRide,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2E7D32),
                foregroundColor: Colors.white,
                elevation: 0,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
              ),
              child: const Text('Start Ride',
                style: TextStyle(
                  fontSize: 16, fontWeight: FontWeight.w800,
                  color: Colors.white)),
            ),
          ),
        ],
      ),
    );
  }

  // =========================================================================
  //  SLIDE TO COMPLETE
  // =========================================================================

  Widget _buildSlideToComplete() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 24, offset: const Offset(0, -4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Slide to complete ride',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 13, fontWeight: FontWeight.w500)),
          const SizedBox(height: 12),
          _slideRail(),
        ],
      ),
    );
  }

  Widget _slideRail() {
    const height = 58.0;
    const thumbW = 52.0;
    return LayoutBuilder(
      builder: (ctx, constraints) {
        final trackW = constraints.maxWidth;
        final maxDrag = trackW - thumbW - 4;

        return SizedBox(
          height: height,
          child: Stack(
            children: [
              // Track background
              Positioned.fill(
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(height / 2),
                    border: Border.all(
                        color: Colors.white.withValues(alpha: 0.10)),
                  ),
                ),
              ),
              // Fill
              Positioned(
                left: 0, top: 0, bottom: 0,
                width: (_slideVal * maxDrag + thumbW).clamp(thumbW, trackW),
                child: Container(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        _gold.withValues(alpha: 0.4),
                        _gold.withValues(alpha: 0.15),
                      ],
                    ),
                    borderRadius: BorderRadius.circular(height / 2),
                  ),
                ),
              ),
              // Label
              Center(
                child: AnimatedOpacity(
                  opacity: 1.0 - _slideVal,
                  duration: const Duration(milliseconds: 100),
                  child: Text('Complete Trip  →',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 14, fontWeight: FontWeight.w600)),
                ),
              ),
              // Thumb
              Positioned(
                left: 2 + _slideVal * maxDrag,
                top: 3, bottom: 3,
                child: GestureDetector(
                  onHorizontalDragUpdate: (d) {
                    if (_slid) return;
                    setState(() {
                      _slideVal = (_slideVal + d.delta.dx / maxDrag)
                          .clamp(0.0, 1.0);
                    });
                    if (_slideVal >= 0.88) {
                      setState(() => _slid = true);
                      _completeTrip();
                    }
                  },
                  onHorizontalDragEnd: (_) {
                    if (!_slid) {
                      setState(() => _slideVal = 0);
                    }
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 80),
                    width: thumbW - 4,
                    decoration: BoxDecoration(
                      color: _slid ? const Color(0xFF2E7D32) : _gold,
                      borderRadius: BorderRadius.circular((height - 6) / 2),
                      boxShadow: [
                        BoxShadow(
                          color: (_slid
                                  ? const Color(0xFF2E7D32)
                                  : _gold)
                              .withValues(alpha: 0.5),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                    ),
                    child: Icon(
                      _slid ? Icons.check_rounded : Icons.chevron_right_rounded,
                      color: Colors.black,
                      size: 28,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  // =========================================================================
  //  HELPERS
  // =========================================================================

  Widget _riderAvatar({double size = 46}) {
    final init = widget.riderName.isNotEmpty
        ? widget.riderName[0].toUpperCase() : '?';
    if (widget.riderPhotoUrl.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          widget.riderPhotoUrl,
          width: size, height: size, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _initCircle(init, size),
        ),
      );
    }
    return _initCircle(init, size);
  }

  Widget _initCircle(String init, double size) => Container(
    width: size, height: size,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        colors: [Color(0xFFD4A843), Color(0xFFF5D990)],
        begin: Alignment.topLeft, end: Alignment.bottomRight),
    ),
    child: Center(
      child: Text(init,
        style: TextStyle(
          color: Colors.black,
          fontSize: size * 0.38,
          fontWeight: FontWeight.w900)),
    ),
  );

  Widget _compactBtn(IconData icon, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white, size: 17),
        ),
      );

  // ── "Arrived at Pickup" floating button (shown during toPickup phase) ─────
  Widget _buildArrivedBtn() => GestureDetector(
    onTap: _arrivedAtPickup,
    child: Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF2E7D32),
        borderRadius: BorderRadius.circular(28),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF2E7D32).withValues(alpha: 0.5),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.location_on_rounded, color: Colors.white, size: 18),
          SizedBox(width: 7),
          Text('Arrived at Pickup',
            style: TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            )),
        ],
      ),
    ),
  );
}
