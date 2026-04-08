import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import '../../widgets/verified_avatar.dart';
import '../../widgets/map/circular_pin_renderer.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../navigation/nav_state_machine.dart';
import '../../navigation/route_service.dart';
import '../../navigation/route_snapper.dart';
import '../../navigation/smooth_motion.dart';
import '../../config/page_transitions.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import '../home_screen.dart';
import '../../services/analytics_service.dart';
import '../../services/gps_service.dart';
import '../../services/navigation_service.dart';
import '../../services/trip_firestore_service.dart';
import 'driver_safety_screen.dart';
import 'driver_trip_accept_screen.dart';
import 'driver_rate_rider_screen.dart';
import '../../utils/responsive.dart';
import '../../utils/name_helper.dart' as nh;

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
    this.riderId,
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
    this.startInTripMode = false,
  });

  final int tripId;
  final String riderName;
  final String riderPhotoUrl;
  final double riderRating;
  final int? riderId;
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
  final bool startInTripMode;

  @override
  State<DriverNavScreen> createState() => _DriverNavScreenState();
}

class _DriverNavScreenState extends State<DriverNavScreen>
    with TickerProviderStateMixin {
  // ── Colours ──────────────────────────────────────────────────────────────
  static const _navBg      = Color(0xFF1A1E2E); // Dark navy header
  static const _navBgSub   = Color(0xFF0F1A20);
  static const _routeBlue  = Color(0xFF4A90E2);
  static const _gold        = Color(0xFFD4A843);
  static const _bottomBg   = Color(0xFF0A0A0A);
  static const _pillBlue   = Color(0xFF1A6EBB);
  static const _etaGreen   = Color(0xFF27AE60);
  static const _speedRed   = Color(0xFFE74C3C);

  // ── Navigation engine ────────────────────────────────────────────────────
  late final NavStateMachine _sm;
  late final NavigationService _navService;
  late final SmoothMotion _motion;

  // ── Map ─────────────────────────────────────────────────────────────────────
  final _mapKey = GlobalKey();
  mapbox.MapboxMap? _map;
  bool _mapReady = false;
  mapbox.PolylineAnnotationManager? _polyMgr;
  mapbox.PointAnnotationManager? _pointMgr;   // pickup/dropoff pins
  mapbox.PointAnnotationManager? _arrowMgr;   // driver arrow only
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.PointAnnotation? _driverAnnot;
  mapbox.PointAnnotation? _destAnnot;

  // ── Position & bearing ────────────────────────────────────────────────────
  LatLng _pos     = const LatLng(0, 0);
  double _bearing = 0;
  int    _lastSegIdx = 0;
  double _currentSpeedMph = 0;

  // ── Route ─────────────────────────────────────────────────────────────────
  List<LatLng> _routePts = [];
  /// Immutable pickup → dropoff route passed back when exiting navigation.
  List<LatLng> _pickupDropoffRoute = [];

  // ── Cinematic route animation ─────────────────────────────────────────────
  List<LatLng> _animatedRoute  = [];
  bool _routeAnimating         = false;
  bool _cinematicDone          = false;
  bool _startRideSwitching     = false;
  double _routeOpacity         = 1.0;
  Ticker? _routeDrawTicker;

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

  // ── Motion tick throttles ─────────────────────────────────────────────────
  DateTime? _lastAnnotUpdate;
  DateTime? _lastUIUpdate;

  // ── UI state ──────────────────────────────────────────────────────────────
  bool   _isMuted          = false;
  bool   _nearPickup        = false;
  bool   _notified5MinAway  = false;
  bool   _completing       = false;
  double _slideVal         = 0;
  bool   _slid             = false;
  final bool _waitingForStart  = false;

  // ── Dropoff finalize & completion ─────────────────────────────────────────
  bool   _showFinalizeButton   = false;
  bool   _showCompletionOverlay = false;
  Timer? _completionTimer;

  // ── Car icon ──────────────────────────────────────────────────────────────
  Uint8List? _arrowBytes;

  // ── Pulse animation (arrived-at-pickup button glow) ───────────────────────
  AnimationController? _pulseCtrl;
  late Animation<double> _pulseAnim;

  // ── Wait time tracking ────────────────────────────────────────────────────
  DateTime? _waitStartedAt;
  Timer? _waitTimer;
  int _waitSeconds = 0;
  static const int _freeWaitMinutes = 2;  // 2 minutes free
  static const double _waitRatePerMinute = 0.50;  // $0.50/min after free period

  // ── GPS ───────────────────────────────────────────────────────────────────
  StreamSubscription<Position>? _gpsSub;
  final _gpsService = GpsService();
  int? _driverId;

  // ── Periodic ETA refresh ──────────────────────────────────────────────────
  Timer? _etaRefreshTimer;
  bool   _isRerouting = false;

  // ── Pickup pin (visible throughout trip) ──────────────────────────────────
  mapbox.PointAnnotation? _pickupAnnot;
  Uint8List? _pickupPinBytes;
  AnimationController? _pickupPopCtrl;
  Animation<double>? _pickupPopScale;
  Animation<double>? _pickupPopFade;
  Offset? _pickupPopOffset;

  // ── Driver icon pulse ─────────────────────────────────────────────────────
  Timer? _iconPulseTimer;
  double _iconPulseScale = 1.6;
  bool   _iconPulseUp    = true;

  // ── Dest pin pop animation ────────────────────────────────────────────────
  Timer? _destPinAnimTimer;
  double _destPinScale = 0.0;

  // ── Phase ─────────────────────────────────────────────────────────────────
  TripPhase get _phase => _sm.phase;

  // =========================================================================
  //  LIFECYCLE
  // =========================================================================

  void _enforceDriverRole() {
    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          fadeThroughRoute(const HomeScreen()),
          (_) => false,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _enforceDriverRole();
    _pos = widget.driverPos;

    // Navigation engine
    _navService = NavigationService();
    _sm = NavStateMachine(onPhaseChanged: _onPhaseChanged);
    _motion = SmoothMotion(onTick: _onMotionTick);
    _motion.start(this);
    _motion.teleport(_pos, _bearing);

    // Pulse animation for arrived-at-pickup button
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnim = CurvedAnimation(parent: _pulseCtrl!, curve: Curves.easeInOut);

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

    // If returning from detail page after Start Ride, advance phase to onTrip.
    if (widget.startInTripMode) {
      _startRideSwitching = true;
      _sm.arriveAtPickup();
      _sm.beginTrip();
      _startRideSwitching = false;
    }

    // If caller already pre-fetched a route, use it; else fetch now
    if (widget.routePoints != null && widget.routePoints!.length > 1) {
      _routePts = List.of(widget.routePoints!);
      // Cap route endpoints to exact pin coordinates so polyline meets the pins
      final dest = widget.startInTripMode ? widget.dropoffLatLng : widget.pickupLatLng;
      _routePts[_routePts.length - 1] = dest;
    }

    // Compute initial bearing from route so arrow points along route immediately
    if (_routePts.length >= 2) {
      _bearing = _bearingBetween(_routePts.first, _routePts[1]);
      _motion.teleport(_pos, _bearing);
    }

    // Fetch the immutable pickup→dropoff route for later when exiting nav
    _fetchPickupDropoffRoute();

    // Overview mode for toPickup (always start with top-down overview)
    if (!widget.startInTripMode) {
      _cameraFollowing = false;
      _isOverview = true;
    }

    // Fetch proper nav route (step-by-step) regardless
    _fetchRoute(widget.startInTripMode ? widget.dropoffLatLng : widget.pickupLatLng);

    // Start GPS
    _startGps();

    // Start GpsService for real-time position sync to Firebase (rider tracking)
    _initGpsService();

    // Periodic ETA refresh every 45 seconds
    _etaRefreshTimer = Timer.periodic(
      const Duration(seconds: 45),
      (_) => _refreshEtaRoute(),
    );

    // Driver icon pulse glow (oscillate size) – 200 ms keeps visually smooth
    // while reducing Mapbox annotation updates from 12.5/s → 5/s.
    _iconPulseTimer = Timer.periodic(
      const Duration(milliseconds: 200),
      (_) => _tickIconPulse(),
    );
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _gpsService.stopTracking();
    _reFollowTimer?.cancel();
    _etaRefreshTimer?.cancel();
    _iconPulseTimer?.cancel();
    _destPinAnimTimer?.cancel();
    _waitTimer?.cancel();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _pulseCtrl?.dispose();
    _pickupPopCtrl?.dispose();
    _completionTimer?.cancel();
    _motion.dispose();
    super.dispose();
  }

  // =========================================================================
  //  GPS SERVICE (real-time position sync to Firebase)
  // =========================================================================

  Future<void> _initGpsService() async {
    final userId = await ApiService.getCurrentUserId();
    if (userId != null) {
      _driverId = userId;
      _gpsService.startTracking(userId.toString());
      _gpsService.setActiveTrip(widget.tripId.toString());
    }
  }

  // =========================================================================
  //  GPS
  // =========================================================================

  Future<void> _startGps() async {
    try {
      final svc  = await Geolocator.isLocationServiceEnabled();
      final perm = await Geolocator.checkPermission();
      if (!svc || perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        return;
      }

      _gpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 5, // 5 meters – smooth rider tracking
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

    // Trim passed route segments
    _trimRouteToPosition();

    // Off-route auto-rerouting
    if (nav != null && nav.isOffRoute && !_isRerouting) {
      _isRerouting = true;
      final dest = _phase == TripPhase.onTrip
          ? widget.dropoffLatLng
          : widget.pickupLatLng;
      _fetchRoute(dest).then((_) {
        if (mounted) _isRerouting = false;
      });
    }

    // Auto-proximity check for phase transitions
    _sm.checkProximity(raw);

    // Notify rider when driver is ~5 min away (once per trip)
    if (_phase == TripPhase.toPickup && !_notified5MinAway && _etaMinutes <= 5 && _etaMinutes > 0) {
      _notified5MinAway = true;
      ApiService.updateTripStatus(tripId: widget.tripId, status: 'driver_arriving')
          .catchError((_) => <String, dynamic>{});
    }

    // Show slide "Arrived" when ≤ 1 min ETA or within ~100 m of pickup
    if (_phase == TripPhase.toPickup && !_nearPickup && !_waitingForStart) {
      if ((_etaMinutes <= 1 || _hav(raw, widget.pickupLatLng) < 0.10) && mounted) {
        setState(() => _nearPickup = true);
      }
    }

    // Show slide "Finish Trip" when ≤ 1 min ETA or within ~100 m of dropoff
    if (_phase == TripPhase.onTrip && !_showFinalizeButton) {
      if ((_etaMinutes <= 1 || _hav(raw, widget.dropoffLatLng) < 0.10) && mounted) {
        setState(() => _showFinalizeButton = true);
      }
    }

    // Sync position to Firebase (GpsService → RTDB, TripFirestoreService → Firestore)
    _gpsService.updatePosition(raw, p.heading, p.speed);
    TripFirestoreService.syncDriverLocation(
      widget.tripId.toString(),
      raw.latitude,
      raw.longitude,
      bearing,
    );
  }

  // =========================================================================
  //  SMOOTH MOTION TICK
  // =========================================================================

  void _onMotionTick(LatLng pos, double bearing, double curveTilt) {
    if (!mounted) return;

    // Always update position/bearing (cheap, no rebuild).
    _pos     = pos;
    _bearing = bearing;

    // Update annotation every vsync frame — must stay in sync with setCamera
    // below (also per-frame) so the pin never lags behind the moving camera.
    _updateCarAnnotation(pos, bearing);

    final now = DateTime.now();
    // Throttle UI rebuild to ~4 Hz (every 250 ms) — speed, ETA, instructions.
    if (_lastUIUpdate == null ||
        now.difference(_lastUIUpdate!).inMilliseconds > 250) {
      _lastUIUpdate = now;
      setState(() {});
    }

    // Camera: use setCamera (instant) since SmoothMotion already interpolates.
    if (_cameraFollowing && !_isOverview) {
      final ahead = _lookaheadPoint(pos, bearing, 120);
      _map?.setCamera(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(ahead.longitude, ahead.latitude)),
          zoom: _navZoom,
          bearing: bearing,
          pitch: _navTilt,
        ),
      );
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
      // When _startRide() is driving the transition, it handles route fetch,
      // pin updates, status sync, and toast itself — skip duplicates here.
      if (!_startRideSwitching) {
        _fetchRoute(widget.dropoffLatLng);
        _updateDestPin(widget.dropoffLatLng);
        _deletePickupPin();
        _updateTripStatus('rider_onboard',
            extra: {'tripStartedAt': FieldValue.serverTimestamp()});
        _showToast('Trip started — navigate to dropoff');
      }
    } else if (phase == TripPhase.arrivedPickup) {
      if (!widget.startInTripMode) {
        _updateTripStatus('arrived_pickup',
            extra: {'driverArrivedAt': FieldValue.serverTimestamp()});
        _showToast('Rider notified — waiting for boarding');
      }
    } else if (phase == TripPhase.arrivedDropoff) {
      setState(() {
        _cameraFollowing = false;
        _isOverview = true;
        _showFinalizeButton = true;
      });
      _animateCameraOverview(_pos, widget.dropoffLatLng);
    }
  }

  // =========================================================================
  //  ROUTE
  // =========================================================================

  /// Fetch the pickup→dropoff route once and store it.
  /// This route is passed back when exiting navigation (never mutated).
  Future<void> _fetchPickupDropoffRoute() async {
    final route = await RouteService.fetchNavRoute(
      origin: widget.pickupLatLng,
      destination: widget.dropoffLatLng,
    );
    if (!mounted) return;
    if (route != null) {
      _pickupDropoffRoute = List.of(route.overviewPolyline);
    }
  }

  Future<void> _fetchRoute(LatLng dest) async {
    final route = await RouteService.fetchNavRoute(origin: _pos, destination: dest);
    if (!mounted) return;
    if (route != null) {
      final pts = List.of(route.overviewPolyline);
      // Cap endpoints: start at driver pos, end at exact destination pin
      if (pts.length >= 2) {
        pts[0] = _pos;
        pts[pts.length - 1] = dest;
      }
      setState(() {
        _routePts        = pts;
        _lastSegIdx      = 0;
        _distRemainingMi = route.totalDistanceMiles;
        _etaMinutes      = route.totalDurationMinutes;
      });
      _navService.startNavigation(route);
      _updateRouteAnnotation();

      // Compute initial bearing from route so arrow points along route
      if (_routePts.length >= 2) {
        _bearing = _bearingBetween(_routePts.first, _routePts[1]);
        _motion.teleport(_pos, _bearing);
      }

      // Show overview camera for toPickup (cinematic will take over)
      if (!widget.startInTripMode && _phase == TripPhase.toPickup && !_cinematicDone) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _animateCameraOverview(_pos, dest);
        });
      }
      // If map is ready but cinematic hasn't fired yet (route loaded after map),
      // trigger it now so it always plays exactly once.
      if (_mapReady && !_cinematicDone && !widget.startInTripMode) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          _startCinematicEntry();
        });
      } else if (_mapReady && !_cinematicDone && widget.startInTripMode) {
        _cinematicDone = true;
        _jumpToNavPosition();
      }
    } else if (_routePts.length > 1) {
      // Fallback: use pre-loaded overview polyline
      _updateRouteAnnotation();
    }
  }

  // =========================================================================
  //  API + FIRESTORE SYNC
  // =========================================================================

  Future<void> _updateTripStatus(String status, {Map<String, dynamic>? extra}) async {
    try {
      await ApiService.updateTripStatus(tripId: widget.tripId, status: status);
    } catch (_) {}
    try {
      final data = <String, dynamic>{'status': _normalizedFirestoreStatus(status)};
      if (extra != null) data.addAll(extra);
      await FirebaseFirestore.instance
          .collection('trips')
          .doc('sql_${widget.tripId}')
          .update(data);
    } catch (_) {}
  }

  String _normalizedFirestoreStatus(String status) {
    switch (status) {
      case 'arrived_pickup':
        return 'driver_arrived';
      case 'rider_onboard':
        return 'in_progress';
      default:
        return status;
    }
  }

  // =========================================================================
  //  ROUTE TRIMMING
  // =========================================================================

  /// Trim route polyline to remove segments the driver has already passed.
  void _trimRouteToPosition() {
    if (_routePts.length < 3 || _lastSegIdx < 1) return;
    // Keep a small buffer behind for visual smoothness
    final trimTo = (_lastSegIdx - 1).clamp(0, _routePts.length - 2);
    if (trimTo < 1) return;
    _routePts = _routePts.sublist(trimTo);
    _lastSegIdx = 1; // reset segment index relative to new list
    // Skip annotation update while the draw animation owns the annotation;
    // the animation's final frame will write the correct trimmed geometry.
    if (!_routeAnimating) _updateRouteSource();
  }

  /// Update just the polyline geometry without recreating annotations.
  Future<void> _updateRouteSource() async {
    final mgr = _polyMgr;
    if (mgr == null || _routePts.length < 2) return;
    final coords = _routePts
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();
    final geom = mapbox.LineString(coordinates: coords);

    if (_routeAnnot != null) {
      _routeAnnot!.geometry = geom;
      try { await mgr.update(_routeAnnot!); } catch (_) {}
    }
  }

  // =========================================================================
  //  PERIODIC ETA REFRESH
  // =========================================================================

  Future<void> _refreshEtaRoute() async {
    if (!mounted || _isRerouting || _routeAnimating) { return; }
    if (_phase == TripPhase.arrivedPickup ||
        _phase == TripPhase.arrivedDropoff ||
        _phase == TripPhase.completed) {
      return;
    }
    final dest = _phase == TripPhase.onTrip
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    final route = await RouteService.fetchNavRoute(origin: _pos, destination: dest);
    if (!mounted || route == null) return;
    setState(() {
      _routePts        = List.of(route.overviewPolyline);
      _lastSegIdx      = 0;
      _distRemainingMi = route.totalDistanceMiles;
      _etaMinutes      = route.totalDurationMinutes;
    });
    _navService.startNavigation(route);
    _updateRouteAnnotation();
  }

  // =========================================================================
  //  CINEMATIC ROUTE ANIMATION
  // =========================================================================

  /// Full cinematic entry: plays once per trip on first screen entry.
  /// Shows top-down overview and waits for driver to tap "Start Trip".
  Future<void> _startCinematicEntry() async {
    if (_routePts.length < 2 || _cinematicDone) return;
    _cinematicDone = true;

    // Compute initial bearing from route so arrow points correctly from start.
    if (_routePts.length >= 2) {
      _bearing = _bearingBetween(_routePts[0], _routePts[1]);
      _motion.teleport(_pos, _bearing);
    }

    // Phase 1: Top-down overview — show full route for 5 seconds.
    setState(() { _cameraFollowing = false; _isOverview = true; });
    _updateRouteAnnotation();
    await _zoomToShowRoute();
    if (!mounted) return;

    // Brief overview before entering nav mode.
    await Future.delayed(const Duration(seconds: 2));
    if (!mounted) return;

    // Phase 2: Transition — flyTo 45° nav view centred on driver.
    final dest = _phase == TripPhase.onTrip
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    final routeBearing = _bearingBetween(_pos, dest);
    _bearing = routeBearing;
    final ahead = _lookaheadPoint(_pos, routeBearing, 120);

    // Delete static route before redrawing animated.
    await _deleteRouteAnnotations();
    if (!mounted) return;

    _map?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
            coordinates: mapbox.Position(ahead.longitude, ahead.latitude)),
        zoom: _navZoom,
        bearing: routeBearing,
        pitch: _navTilt,
      ),
      mapbox.MapAnimationOptions(duration: 2000, startDelay: 0),
    );
    // Wait for flyTo to finish.
    await Future.delayed(const Duration(milliseconds: 2200));
    if (!mounted) return;

    // Phase 3: Draw route progressively.
    await _drawRouteAnimated();
    if (!mounted) return;

    // Lock camera to driver.
    setState(() {
      _cameraFollowing = true;
      _isOverview = false;
    });

    // Open native maps with pickup address for turn-by-turn
    if (_phase == TripPhase.toPickup) {
      _openNativeMaps(widget.pickupLatLng, widget.pickupAddress);
    }
  }

  /// Jump directly to locked nav position (no animation). Used on re-entry.
  void _jumpToNavPosition() {
    final ahead = _lookaheadPoint(_pos, _bearing, 120);
    _map?.setCamera(mapbox.CameraOptions(
      center: mapbox.Point(
          coordinates: mapbox.Position(ahead.longitude, ahead.latitude)),
      zoom: _navZoom,
      bearing: _bearing,
      pitch: _navTilt,
    ));
    setState(() {
      _cameraFollowing = true;
      _isOverview = false;
    });
  }

  Future<void> _zoomToShowRoute() async {
    if (_routePts.isEmpty) return;
    // Update route annotation so it's visible in the overview
    _updateRouteAnnotation();
    final all = [..._routePts, _pos];
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in all) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    // Use coordinateBounds for proper fit with generalized padding
    try {
      final cam = await _map?.cameraForCoordinateBounds(
        mapbox.CoordinateBounds(
          southwest: mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
          northeast: mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
          infiniteBounds: false,
        ),
        mapbox.MbxEdgeInsets(top: 140, left: 50, bottom: 120, right: 50),
        0, // bearing
        0, // pitch
        null,
        null,
      );
      if (cam != null) {
        _map?.setCamera(cam);
        return;
      }
    } catch (_) {}
    // Fallback: manual zoom calculation
    final midLat = (minLat + maxLat) / 2;
    final midLng = (minLng + maxLng) / 2;
    final span = math.max(maxLat - minLat, maxLng - minLng);
    final zoom = span > 0 ? (math.log(360 / span) / math.ln2).clamp(8.0, 14.5) : 13.0;
    _map?.setCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(midLng, midLat)),
      zoom: zoom,
      bearing: 0,
      pitch: 0,
    ));
  }

  /// Calculate bearing between two points (degrees).
  double _bearingBetween(LatLng a, LatLng b) {
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Draw route progressively at 60fps using a Ticker.
  Future<void> _drawRouteAnimated() async {
    if (_routePts.length < 2) return;
    _routeAnimating = true;

    // Pre-create annotation before ticker to avoid async-in-ticker issues
    final mgr = _polyMgr;
    if (mgr == null) { _routeAnimating = false; return; }
    if (_routeAnnot != null) { try { await mgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }
    final initCoords = _routePts.sublist(0, 2).map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    await _createRouteAnnotations(mgr, mapbox.LineString(coordinates: initCoords));
    if (!mounted || _routeAnnot == null) { _routeAnimating = false; return; }

    final totalMs = (_routePts.length * 10).clamp(1800, 3500);
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    bool updating = false;
    int lastCount = 2;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (updating) return;
      final progress = (stopwatch.elapsedMilliseconds / totalMs).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(progress);
      final count = (eased * _routePts.length).round().clamp(2, _routePts.length);

      if (count != lastCount) {
        lastCount = count;
        _animatedRoute = _routePts.sublist(0, count);
        final coords = _animatedRoute.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        _routeAnnot!.geometry = mapbox.LineString(coordinates: coords);
        updating = true;
        mgr.update(_routeAnnot!).then((_) => updating = false).catchError((_) => updating = false);
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        _routeAnimating = false;
        _animatedRoute = List.from(_routePts);
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  /// Fade out current route before switching segments.
  Future<void> _fadeOutRoute() async {
    final mgr = _polyMgr;
    if (mgr != null) {
      if (_routeAnnot != null) { try { await mgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }
    }
    _routeOpacity = 1.0;
    _animatedRoute = [];
  }

  /// Update route polyline opacity during fade transitions.
  void _updateRouteOpacity() {
    final mgr = _polyMgr;
    if (mgr == null) return;
    if (_routeAnnot != null) {
      _routeAnnot!.lineOpacity = _routeOpacity;
      try { mgr.update(_routeAnnot!); } catch (_) {}
    }
  }

  // =========================================================================
  //  DRIVER ICON PULSE
  // =========================================================================

  void _tickIconPulse() {
    if (!mounted) return;
    final step = 0.02; // Larger step compensates for slower 200 ms interval
    if (_iconPulseUp) {
      _iconPulseScale += step;
      if (_iconPulseScale >= 1.75) _iconPulseUp = false;
    } else {
      _iconPulseScale -= step;
      if (_iconPulseScale <= 1.55) _iconPulseUp = true;
    }
    final mgr = _arrowMgr;
    final annot = _driverAnnot;
    if (mgr == null || annot == null) return;
    annot.iconSize = _iconPulseScale;
    try { mgr.update(annot); } catch (_) {}
  }

  // =========================================================================
  //  MAP ANNOTATIONS
  // =========================================================================

  /// Full 4-layer gold gloss route annotation (used for static updates).
  Future<void> _updateRouteAnnotation() async {
    final mgr = _polyMgr;
    if (mgr == null || _routePts.length < 2) return;
    final coords = _routePts
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();
    final geom = mapbox.LineString(coordinates: coords);
    await _deleteRouteAnnotations();
    await _createRouteAnnotations(mgr, geom);
  }

  /// Animated variant: updates route geometry during progressive draw.
  Future<void> _updateRouteAnnotationAnimated(List<LatLng> pts) async {
    final mgr = _polyMgr;
    if (mgr == null || pts.length < 2) return;
    final coords = pts
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();
    final geom = mapbox.LineString(coordinates: coords);

    if (_routeAnnot != null) {
      _routeAnnot!.geometry = geom;
      try { await mgr.update(_routeAnnot!); } catch (_) {}
    } else {
      await _createRouteAnnotations(mgr, geom);
    }
  }

  Future<void> _deleteRouteAnnotations() async {
    final mgr = _polyMgr;
    if (mgr == null) return;
    if (_routeAnnot != null) { try { await mgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }
  }

  /// Create single 5px gold line on Mapbox.
  Future<void> _createRouteAnnotations(mapbox.PolylineAnnotationManager mgr, mapbox.LineString geom) async {
    _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 5.0,
    ));
  }

  Future<void> _updateCarAnnotation(LatLng pos, double bearing) async {
    final mgr   = _arrowMgr;
    final bytes = _arrowBytes;
    if (mgr == null || bytes == null) return;
    final geom = mapbox.Point(
        coordinates: mapbox.Position(pos.longitude, pos.latitude));
    if (_driverAnnot == null) {
      _driverAnnot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: geom,
        image: bytes,
        iconSize: 1.6,
        iconRotate: bearing,
        iconAnchor: mapbox.IconAnchor.CENTER,
        iconOffset: [0, 0],
      ));
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

    // If annotation already exists, just move it — no delete/recreate flash.
    if (_destAnnot != null) {
      _destAnnot!.geometry = geom;
      _destAnnot!.iconSize = 1.0; // keep stable size
      try { await mgr.update(_destAnnot!); } catch (_) {}
      return;
    }

    final pinBytes = await _buildDestPin();
    if (pinBytes == null || !mounted) return;
    _destPinScale = 0.0;
    _destAnnot = await mgr.create(mapbox.PointAnnotationOptions(
      geometry: geom,
      image: pinBytes,
      iconSize: 0.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
      iconOffset: [0, 0],
    ));
    _animateDestPinPop();
  }

  /// Pop/bounce animation for destination pin (elasticOut curve, 450ms).
  void _animateDestPinPop() {
    _destPinAnimTimer?.cancel();
    _destPinScale = 1.0;
    final annot = _destAnnot;
    final mgr = _pointMgr;
    if (annot != null && mgr != null) {
      annot.iconSize = 1.0;
      mgr.update(annot).catchError((_) {});
    }
  }

  /// Show a persistent pickup pin (gold teardrop) at pickup location.
  Future<void> _updatePickupPin(LatLng pickup) async {
    final mgr = _pointMgr;
    if (mgr == null) return;
    _pickupPinBytes ??= await _buildPickupPin();
    final pinBytes = _pickupPinBytes;
    if (pinBytes == null || !mounted) return;
    final geometry = mapbox.Point(
        coordinates: mapbox.Position(pickup.longitude, pickup.latitude));

    if (_pickupAnnot == null) {
      _pickupAnnot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: geometry,
        image: pinBytes,
        iconSize: 1.0,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
      return;
    }

    _pickupAnnot!
      ..geometry = geometry
      ..image = pinBytes
      ..iconSize = 1.0
      ..iconOpacity = 1.0;
    try { await mgr.update(_pickupAnnot!); } catch (_) {}
  }

  Future<void> _deletePickupPin() async {
    final mgr = _pointMgr;
    final annot = _pickupAnnot;
    if (mgr == null || annot == null) return;
    try { await mgr.delete(annot); } catch (_) {}
    _pickupAnnot = null;
  }

  Future<void> _startPickupPinPopout() async {
    await _deletePickupPin();
  }

  // =========================================================================
  //  CAMERA
  // =========================================================================

  // Navigation camera: 45° tilt, zoom 17.5, centered on driver
  static const double _navZoom = 17.5;
  static const double _navTilt = 45.0;
  static const double _pinOffsetRatio = 0.35;

  // _animateCamera is no longer used — camera follow is handled directly
  // in _onMotionTick via flyTo for smooth 1s transitions.

  /// Calculate offset LatLng so pin appears higher on screen.
  /// Shifts the camera center southward (behind the driver) so the
  /// driver icon renders in the upper portion of the viewport.
  LatLng _offsetLatLng(LatLng center, double bearing, double zoom, double ratio) {
    final metersPerPixel = 156543.03392 *
        math.cos(center.latitude * math.pi / 180) /
        math.pow(2, zoom);
    final screenHeight = MediaQuery.of(context).size.height;
    final offsetMeters = screenHeight * ratio * metersPerPixel;
    final bearingRad = bearing * math.pi / 180;
    final latOffset = offsetMeters * math.cos(bearingRad) / 111320;
    final lngOffset = offsetMeters * math.sin(bearingRad) /
        (111320 * math.cos(center.latitude * math.pi / 180));
    return LatLng(
      center.latitude - latOffset,
      center.longitude - lngOffset,
    );
  }

  void _animateCameraOverview(LatLng a, LatLng b) {
    final midLat = (a.latitude  + b.latitude)  / 2;
    final midLng = (a.longitude + b.longitude) / 2;
    final latDiff = (a.latitude  - b.latitude).abs();
    final lngDiff = (a.longitude - b.longitude).abs();
    final span = math.max(latDiff, lngDiff);
    final zoom = span > 0 ? (math.log(360 / span) / math.ln2).clamp(8.0, 14.5) : 13.0;
    _map?.setCamera(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: mapbox.Position(midLng, midLat)),
        zoom: zoom,
        bearing: 0,
        pitch: 0,
      ),
    );
  }

  void _onCameraMoveStarted() {
    if (!_cameraFollowing) return;
    setState(() => _cameraFollowing = false);
    _reFollowTimer?.cancel();
    // Auto-recenter after 15 seconds
    _reFollowTimer = Timer(const Duration(seconds: 15), () {
      if (mounted && !_cameraFollowing && !_isOverview) _recenter();
    });
  }

  void _recenter() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    // Keep _cameraFollowing FALSE during flyTo so _onMotionTick's setCamera
    // doesn't fight the animation. Enable tracking only after flyTo finishes.
    setState(() {
      _cameraFollowing = false;
      _isOverview      = false;
      _hasResumedOnce  = true;
    });
    final ahead = _lookaheadPoint(_pos, _bearing, 120);
    _map?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(
            coordinates: mapbox.Position(ahead.longitude, ahead.latitude)),
        zoom: _navZoom,
        bearing: _bearing,
        pitch: _navTilt,
      ),
      mapbox.MapAnimationOptions(duration: 800, startDelay: 0),
    );
    // Re-enable chase camera after flyTo completes
    Future.delayed(const Duration(milliseconds: 850), () {
      if (mounted) setState(() => _cameraFollowing = true);
    });
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
    _startWaitTimer();
  }

  /// Tapped "Arrived" in bottom bar → update status & go back to trip detail.
  void _arrivedAndGoBack() {
    HapticFeedback.mediumImpact();
    _sm.arriveAtPickup();
    _updateTripStatus('arrived_pickup',
        extra: {'driverArrivedAt': FieldValue.serverTimestamp()});

    // Cancel timers / subscriptions before leaving
    _gpsSub?.cancel();
    _etaRefreshTimer?.cancel();
    _iconPulseTimer?.cancel();
    _destPinAnimTimer?.cancel();
    _waitTimer?.cancel();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => DriverTripAcceptScreen(
          tripId:          widget.tripId,
          riderName:       widget.riderName,
          riderPhotoUrl:   widget.riderPhotoUrl,
          riderRating:     widget.riderRating,
          riderId:         widget.riderId,
          pickupLatLng:    widget.pickupLatLng,
          dropoffLatLng:   widget.dropoffLatLng,
          pickupAddress:   widget.pickupAddress,
          dropoffAddress:  widget.dropoffAddress,
          fare:            widget.fare,
          vehicleType:     widget.vehicleType,
          driverPos:       _pos,
          distToPickupKm:  _distRemainingMi * 1.60934,
          etaMinutes:      _etaMinutes,
          routePoints:     _pickupDropoffRoute,
          riderPhone:      widget.riderPhone,
          arrivedAtPickup: true,
        ),
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
          child: child,
        ),
        transitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  void _startWaitTimer() {
    _waitStartedAt = DateTime.now();
    _waitSeconds = 0;
    // Call backend to record wait time start
    ApiService.startWaitTime(widget.tripId).catchError((_) => <String, dynamic>{});
    AnalyticsService.instance.logEvent('wait_time_started');
    _waitTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _waitSeconds = DateTime.now().difference(_waitStartedAt!).inSeconds;
      });
      // Haptic feedback at 90s (30s before free ends) and 120s (free ends)
      if (_waitSeconds == 90) {
        HapticFeedback.mediumImpact();
      } else if (_waitSeconds == _freeWaitMinutes * 60) {
        HapticFeedback.heavyImpact();
        AnalyticsService.instance.logEvent('wait_time_free_expired');
      }
    });
  }

  void _stopWaitTimer() {
    _waitTimer?.cancel();
    _waitTimer = null;
    if (_waitStartedAt != null) {
      final waitMinutes = _waitSeconds ~/ 60;
      final chargedMinutes = (waitMinutes > _freeWaitMinutes) ? waitMinutes - _freeWaitMinutes : 0;
      final charge = chargedMinutes * _waitRatePerMinute;
      if (charge > 0) {
        AnalyticsService.instance.logEvent('wait_time_charged', parameters: {'amount': charge});
      }
      // Call backend to finalize wait time
      ApiService.endWaitTime(widget.tripId).catchError((_) => <String, dynamic>{});
    }
  }

  String _formatWaitTime(int totalSeconds) {
    final mins = totalSeconds ~/ 60;
    final secs = totalSeconds % 60;
    return '${mins.toString().padLeft(2, '0')}:${secs.toString().padLeft(2, '0')}';
  }

  double _calculateWaitCharge() {
    final waitMinutes = _waitSeconds ~/ 60;
    if (waitMinutes <= _freeWaitMinutes) return 0.0;
    return (waitMinutes - _freeWaitMinutes) * _waitRatePerMinute;
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

  Future<void> _startRide() async {
    HapticFeedback.heavyImpact();

    // ── Check if rider confirmed pickup ──
    bool riderConfirmed = false;
    try {
      final doc = await FirebaseFirestore.instance
          .collection('trips')
          .doc('sql_${widget.tripId}')
          .get();
      riderConfirmed = doc.data()?['rider_confirmed_pickup'] == true;
    } catch (_) {}

    if (!riderConfirmed) {
      _showToast('El rider no ha confirmado, comenzando viaje...');
    }

    _stopWaitTimer(); // End wait time when ride starts
    _startRideSwitching = true;
    unawaited(_startPickupPinPopout());
    _sm.beginTrip(); // triggers _onPhaseChanged(TripPhase.onTrip)

    // Fetch dropoff route
    final route = await RouteService.fetchNavRoute(
      origin: _pos, destination: widget.dropoffLatLng);
    if (!mounted) return;

    if (route != null) {
      setState(() {
        _routePts        = List.of(route.overviewPolyline);
        _lastSegIdx      = 0;
        _distRemainingMi = route.totalDistanceMiles;
        _etaMinutes      = route.totalDurationMinutes;
      });
      _navService.startNavigation(route);

      // ── Set up dropoff route with overview + animated transition ──
      _updateDestPin(widget.dropoffLatLng);
      await _deleteRouteAnnotations();

      // Brief overview of dropoff route.
      _updateRouteAnnotation();
      setState(() { _cameraFollowing = false; _isOverview = true; });
      _animateCameraOverview(_pos, widget.dropoffLatLng);
      await Future.delayed(const Duration(milliseconds: 1500));
      if (!mounted) return;

      // Transition to nav view.
      await _deleteRouteAnnotations();
      final routeBearing = _bearingBetween(_pos, widget.dropoffLatLng);
      _bearing = routeBearing;
      final ahead = _lookaheadPoint(_pos, routeBearing, 120);
      _map?.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(ahead.longitude, ahead.latitude)),
          zoom: _navZoom,
          bearing: routeBearing,
          pitch: _navTilt,
        ),
        mapbox.MapAnimationOptions(duration: 2000, startDelay: 0),
      );
      await Future.delayed(const Duration(milliseconds: 2200));
      if (!mounted) return;

      await _drawRouteAnimated();
    } else {
      _updateDestPin(widget.dropoffLatLng);
      await _updateRouteAnnotation();
    }

    if (!mounted) return;

    // Pin + status updates
    _updateTripStatus('rider_onboard',
        extra: {'tripStartedAt': FieldValue.serverTimestamp()});
    _showToast('Trip started — navigate to dropoff');

    // Open native maps (Apple Maps on iOS, Google Maps on Android) with dropoff
    _openNativeMaps(widget.dropoffLatLng, widget.dropoffAddress);

    _startRideSwitching = false;
    setState(() {
      _cameraFollowing = true;
      _isOverview      = false;
    });
  }

  /// Open the driver's preferred map app with turn-by-turn to [dest].
  /// Tries Google Maps first (most common), falls back to Apple Maps on iOS
  /// or the default browser handler on Android.
  Future<void> _openNativeMaps(LatLng dest, String label) async {
    final lat = dest.latitude;
    final lng = dest.longitude;

    if (Platform.isIOS) {
      // Try Google Maps first (comgooglemaps:// scheme)
      final gMapsUrl = Uri.parse(
        'comgooglemaps://?daddr=$lat,$lng&directionsmode=driving',
      );
      if (await canLaunchUrl(gMapsUrl)) {
        await launchUrl(gMapsUrl, mode: LaunchMode.externalApplication);
        return;
      }
      // Try Waze
      final wazeUrl = Uri.parse(
        'waze://?ll=$lat,$lng&navigate=yes',
      );
      if (await canLaunchUrl(wazeUrl)) {
        await launchUrl(wazeUrl, mode: LaunchMode.externalApplication);
        return;
      }
      // Fall back to Apple Maps
      final appleMapsUrl = Uri.parse(
        'https://maps.apple.com/?daddr=$lat,$lng&dirflg=d&t=m',
      );
      await launchUrl(appleMapsUrl, mode: LaunchMode.externalApplication);
    } else {
      // Android: Try Google Maps intent first
      final gMapsUrl = Uri.parse(
        'google.navigation:q=$lat,$lng&mode=d',
      );
      if (await canLaunchUrl(gMapsUrl)) {
        await launchUrl(gMapsUrl, mode: LaunchMode.externalApplication);
        return;
      }
      // Try Waze
      final wazeUrl = Uri.parse(
        'waze://?ll=$lat,$lng&navigate=yes',
      );
      if (await canLaunchUrl(wazeUrl)) {
        await launchUrl(wazeUrl, mode: LaunchMode.externalApplication);
        return;
      }
      // Fall back to Google Maps web
      final webUrl = Uri.parse(
        'https://www.google.com/maps/dir/?api=1'
        '&destination=$lat,$lng&travelmode=driving',
      );
      await launchUrl(webUrl, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _completeTrip() async {
    if (_completing) return;
    setState(() => _completing = true);
    HapticFeedback.heavyImpact();
    _sm.arriveAtDropoff();
    _sm.completeTrip();
    await _gpsService.clearTripLocation();
    _gpsService.setActiveTrip(null);
    await TripFirestoreService.clearDriverLocation(widget.tripId.toString());
    await _updateTripStatus('completed',
        extra: {'completedAt': FieldValue.serverTimestamp()});
    if (!mounted) return;
    // Show "Viaje Finalizado" overlay on map
    setState(() => _showCompletionOverlay = true);
    // After 2.5 s auto-navigate to rate rider screen
    _completionTimer = Timer(const Duration(milliseconds: 2500), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, anim, __) => DriverRateRiderScreen(
            tripId: widget.tripId,
            riderName: widget.riderName,
            riderPhotoUrl: widget.riderPhotoUrl,
            riderId: widget.riderId,
            fare: widget.fare,
            dropoffLat: widget.dropoffLatLng.latitude,
            dropoffLng: widget.dropoffLatLng.longitude,
          ),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 400),
        ),
      );
    });
  }

  Future<void> _exitNav() async {
    HapticFeedback.lightImpact();

    // Cancel all running timers/tickers before leaving so nothing fires
    // against the popped widget or its annotation managers.
    _gpsSub?.cancel();
    _etaRefreshTimer?.cancel();
    _iconPulseTimer?.cancel();
    _destPinAnimTimer?.cancel();
    _waitTimer?.cancel();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;

    // Navigate back to ride detail screen (pushReplacement because
    // DriverTripAcceptScreen used pushReplacement to get here)
    Navigator.of(context).pushReplacement(
      slideUpFadeRoute(
        DriverTripAcceptScreen(
          tripId:          widget.tripId,
          riderName:       widget.riderName,
          riderPhotoUrl:   widget.riderPhotoUrl,
          riderRating:     widget.riderRating,
          riderId:         widget.riderId,
          pickupLatLng:    widget.pickupLatLng,
          dropoffLatLng:   widget.dropoffLatLng,
          pickupAddress:   widget.pickupAddress,
          dropoffAddress:  widget.dropoffAddress,
          fare:            widget.fare,
          vehicleType:     widget.vehicleType,
          driverPos:       _pos,
          distToPickupKm:  _distRemainingMi * 1.60934,
          etaMinutes:      _etaMinutes,
          routePoints:     _pickupDropoffRoute,
          riderPhone:      widget.riderPhone,
          arrivedAtPickup: _phase == TripPhase.arrivedPickup || _phase == TripPhase.onTrip,
          rideStarted:     _phase == TripPhase.onTrip,
        ),
      ),
    );
  }

  void _callRider() async {
    if (widget.riderPhone.isEmpty) {
      _showToast(S.of(context).noPhoneNumberAvailable);
      return;
    }
    final uri = Uri.parse('tel:${widget.riderPhone}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _messageRider() async {
    if (widget.riderPhone.isEmpty) {
      _showToast(S.of(context).noPhoneNumberAvailable);
      return;
    }
    final uri = Uri.parse('sms:${widget.riderPhone}');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _showTripOptions() {
    HapticFeedback.mediumImpact();
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF111318),
      isScrollControlled: true,
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
              // Handle
              Container(
                margin: const EdgeInsets.only(bottom: 16),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.24),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              // Rider info
              Row(
                children: [
                  _riderAvatar(size: Responsive.w(50)),
                  SizedBox(width: Responsive.w(14)),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(nh.displayName(widget.riderName, widget.vehicleType),
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: Responsive.sp(17),
                            fontWeight: FontWeight.w800)),
                        const SizedBox(height: 3),
                        Row(
                          children: [
                            const Icon(Icons.star_rounded,
                                color: _gold, size: 14),
                            const SizedBox(width: 3),
                            Text(widget.riderRating.toStringAsFixed(1),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.7),
                                fontSize: 13,
                                fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              // Action buttons
              _tripOptionTile(
                icon: Icons.phone_rounded,
                label: S.of(context).callRider,
                onTap: () {
                  Navigator.pop(ctx);
                  _callRider();
                },
              ),
              _tripOptionTile(
                icon: Icons.message_rounded,
                label: S.of(context).messageRider,
                onTap: () {
                  Navigator.pop(ctx);
                  _messageRider();
                },
              ),
              _tripOptionTile(
                icon: Icons.wrong_location_rounded,
                label: S.of(context).reportWrongAddress,
                color: Colors.orange,
                onTap: () {
                  Navigator.pop(ctx);
                  _showToast('Address issue reported');
                },
              ),
              _tripOptionTile(
                icon: Icons.person_off_rounded,
                label: S.of(context).riderNoShow,
                color: Colors.orange,
                onTap: () {
                  Navigator.pop(ctx);
                  _showToast('No-show reported');
                  _updateTripStatus('rider_no_show');
                },
              ),
              _tripOptionTile(
                icon: Icons.cancel_rounded,
                label: S.of(context).endTripEarly,
                color: _speedRed,
                onTap: () {
                  Navigator.pop(ctx);
                  _exitNav();
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tripOptionTile({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color color = Colors.white,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.05),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Row(
          children: [
            Icon(icon, color: color, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(label,
                style: TextStyle(
                  color: color,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
            ),
            Icon(Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.3), size: 20),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  //  CAR ICON (3D arrow with shadow)
  // =========================================================================

  Future<Uint8List?> _buildArrowIcon() async {
    const double w = 96, h = 96;
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, Rect.fromLTWH(0, 0, w, h));
    final cx  = w / 2;
    final cy  = h / 2;

    // ── 3D elliptical ground shadow (centred below circle) ──
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 12), width: 72, height: 20),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 14),
    );
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 10), width: 52, height: 14),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.22)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    c.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 8), width: 30, height: 8),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // ── White circle body (exactly centred) ──
    c.drawCircle(Offset(cx, cy), 22, Paint()..color = Colors.white);

    // ── Gold ring border ──
    c.drawCircle(
      Offset(cx, cy), 22,
      Paint()
        ..color = const Color(0xFFD4A843).withValues(alpha: 0.50)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.0,
    );

    // ── Gold directional chevron (points UP – rotated with iconRotate) ──
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

  /// Unified gold teardrop pin for destination.
  Future<Uint8List?> _buildDestPin() async {
    return renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 32);
  }

  /// Unified gold teardrop pin for pickup.
  Future<Uint8List?> _buildPickupPin() async {
    return renderCircularPinBytes(icon: CircularPinIcon.dot, isPickup: true, radius: 32);
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

    final screenH = mq.size.height;
    final bottomBarH = math.max(60.0, screenH * 0.08) + bot;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (did, _) { if (!did) _exitNav(); },
      child: Scaffold(
        backgroundColor: const Color(0xFF080C16),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // ── FULL MAP ─────────────────────────────────────────────────
            Positioned.fill(child: _buildMap()),

            // ── TOP HEADER ───────────────────────────────────────────────
            Positioned(
              top: top + 8,
              left: 12,
              right: 12,
              child: _buildNavHeader(top),
            ),

            // ── SPEED OVERLAY (left side, below header) ──────────────────
            Positioned(
              left: 16,
              top: top + 120,
              child: _buildSpeedOverlay(top + 120),
            ),

            // ── BOTTOM BAR / ARRIVED BUTTON ─────────────────────────────
            Positioned(
              bottom: bot + 12,
              left: 12,
              right: 12,
              child: AnimatedCrossFade(
                firstChild: _buildBottomBar(bot),
                secondChild: _buildArrivedButton(),
                crossFadeState: (_nearPickup && _phase == TripPhase.toPickup)
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 400),
                firstCurve: Curves.easeInOut,
                secondCurve: Curves.easeInOut,
              ),
            ),

            // ── RESUME BUTTON (shown when user pans away) ─────────────
            if (!_cameraFollowing && !_isOverview && !_waitingForStart)
              Positioned(
                bottom: bottomBarH + 8,
                left: 0,
                right: 0,
                child: Center(child: _buildResumeButton()),
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
    return RepaintBoundary(
      child: mapbox.MapWidget(
        key: _mapKey,
        textureView: true,
        styleUri: MapboxConfig.styleNavigation,
        cameraOptions: mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(_pos.longitude, _pos.latitude)),
          zoom: 13.0,
          pitch: 0,
          bearing: 0,
        ),
        onMapCreated: (ctrl) async {
          _map      = ctrl;
          _mapReady = true;
          _polyMgr  = await ctrl.annotations.createPolylineAnnotationManager(
            below: "road-label",
          );
          // Pin manager (pickup / dropoff pins) — pitch-aligned to viewport so
          // they stand upright at 55° nav pitch instead of lying flat on the map.
          _pointMgr = await ctrl.annotations.createPointAnnotationManager();
          try { await ctrl.style.setStyleLayerProperty(_pointMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
          try { await ctrl.style.setStyleLayerProperty(_pointMgr!.id, 'icon-rotation-alignment', 'viewport'); } catch (_) {}
          try { await ctrl.style.setStyleLayerProperty(_pointMgr!.id, 'icon-allow-overlap', true); } catch (_) {}
          try { await ctrl.style.setStyleLayerProperty(_pointMgr!.id, 'icon-ignore-placement', true); } catch (_) {}
          try { await ctrl.style.setStyleLayerProperty(_pointMgr!.id, 'icon-anchor', 'bottom'); } catch (_) {}

          // Arrow manager (driver icon only) — rotation-alignment 'map' so
          // iconRotate tracks geographic bearing, not screen-space bearing.
          _arrowMgr = await ctrl.annotations.createPointAnnotationManager();
          try { await ctrl.style.setStyleLayerProperty(_arrowMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
          try { await ctrl.style.setStyleLayerProperty(_arrowMgr!.id, 'icon-rotation-alignment', 'map'); } catch (_) {}
          _updateRouteAnnotation();
          _updateDestPin(widget.startInTripMode ? widget.dropoffLatLng : widget.pickupLatLng);
          // Show pickup pin only during toPickup phase
          if (!widget.startInTripMode) {
            _updatePickupPin(widget.pickupLatLng);
          }
          if (widget.startInTripMode) {
            // Returning from TripAcceptScreen after Start Ride → direct chase
            _cinematicDone = true;
            Future.delayed(const Duration(milliseconds: 400), () {
              if (!mounted) return;
              _deletePickupPin();
              // Compute bearing from route to dropoff
              if (_routePts.length >= 2) {
                _bearing = _bearingBetween(_routePts.first, _routePts[1]);
                _motion.teleport(_pos, _bearing);
              }
              _jumpToNavPosition();
            });
          } else {
            Future.delayed(const Duration(milliseconds: 600), () {
              if (mounted) _startCinematicEntry();
            });
          }
        },
        onStyleLoadedListener: (_) async {
          if (_map != null) await MapTheme.applyNavyGold(_map!);
        },
        onScrollListener: (_) => _onCameraMoveStarted(),
      ),
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

    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        _showUpcomingSteps();
      },
      child: Material(
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 12,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.antiAlias,
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 12),
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
                        Text(isOffRoute ? S.of(context).rerouting : instruction,
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
            // "Then" next step sub-row OR destination address sub-row
            if (nextStep != null && !isOffRoute)
              Container(
                color: bgSub,
                padding: const EdgeInsets.fromLTRB(16, 6, 16, 8),
                child: Row(
                  children: [
                    Text(S.of(context).thenDirection,
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
              )
            else
              // Show destination address when nav hasn't started yet
              Container(
                color: bgSub,
                padding: const EdgeInsets.fromLTRB(16, 5, 16, 7),
                child: Row(
                  children: [
                    Icon(
                      _phase == TripPhase.toPickup
                          ? Icons.radio_button_checked_rounded
                          : Icons.location_on_rounded,
                      color: _phase == TripPhase.toPickup
                          ? const Color(0xFF4CAF50)
                          : const Color(0xFFEF5350),
                      size: 13,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _phase == TripPhase.toPickup || _phase == TripPhase.arrivedPickup
                            ? widget.pickupAddress
                            : widget.dropoffAddress,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.72),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    if (_etaMinutes > 0)
                      Text(
                        '$_etaMinutes min  ·  ${_distRemainingMi.toStringAsFixed(1)} mi',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                  ],
                ),
              ),
          ],
        ),
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
      case TripPhase.toPickup:      return 'Head to pickup';
      case TripPhase.arrivedPickup: return 'Arrived at pickup';
      case TripPhase.onTrip:        return 'Head to drop-off';
      case TripPhase.arrivedDropoff:return 'Arrived at destination';
      default:                       return 'Ready';
    }
  }

  // =========================================================================
  //  RESUME BUTTON (appears when user pans away)
  // =========================================================================

  Widget _buildResumeButton() {
    return GestureDetector(
      onTap: () {
        HapticFeedback.mediumImpact();
        _recenter();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1E28).withValues(alpha: 0.94),
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _gold.withValues(alpha: 0.5), width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: _gold.withValues(alpha: 0.12),
              blurRadius: 16,
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.my_location_rounded, color: _gold, size: 18),
            const SizedBox(width: 8),
            Text(S.of(context).resumeLabel,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              )),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  //  RIGHT FAB COLUMN
  // =========================================================================

  Widget _buildRightFabs() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // 1. Recenter — resumes 3D chase mode
        _mapFab(
          icon: Icons.gps_fixed_rounded,
          onTap: () {
            HapticFeedback.mediumImpact();
            _recenter();
          },
          active: _cameraFollowing && !_isOverview,
        ),
        const SizedBox(height: 10),
        // 4. Mute toggle
        _mapFab(
          icon: _isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _isMuted = !_isMuted);
          },
          active: _isMuted,
        ),
        const SizedBox(height: 10),
        // 5. Safety shield
        _mapFab(
          icon: Icons.shield_rounded,
          onTap: () {
            HapticFeedback.mediumImpact();
            Navigator.of(context).push(PageRouteBuilder(
              pageBuilder: (_, __, ___) => DriverSafetyScreen(
                tripId: widget.tripId,
                riderName: widget.riderName,
                riderPhone: widget.riderPhone,
                pickupAddress: widget.pickupAddress,
                dropoffAddress: widget.dropoffAddress,
              ),
              transitionDuration: const Duration(milliseconds: 280),
              reverseTransitionDuration: const Duration(milliseconds: 220),
              transitionsBuilder: (_, anim, __, child) => FadeTransition(
                opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
                child: child,
              ),
            ));
          },
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

    return Container(
      decoration: BoxDecoration(
        color: _bottomBg,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 14,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: SizedBox(
        height: math.max(68.0, Responsive.h(68)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            SizedBox(width: Responsive.w(12)),
            // Rider avatar — opens trip options
            GestureDetector(
              onTap: _showTripOptions,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: Responsive.w(4)),
                child: _riderAvatar(size: Responsive.w(40)),
              ),
            ),
            // Centered ETA / distance / arrival
            Expanded(
              child: Center(
                child: eta <= 2
                        ? Text(
                            'Arriving soon',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            softWrap: false,
                            style: TextStyle(
                              color: _etaGreen,
                              fontSize: Responsive.sp(16),
                              fontWeight: FontWeight.w800,
                            ))
                        : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text('$eta min',
                                style: TextStyle(
                                  color: _etaGreen,
                                  fontSize: Responsive.sp(22),
                                  fontWeight: FontWeight.w900,
                                  height: 1.0,
                                )),
                              const SizedBox(height: 2),
                              Text('$distStr · $arrStr',
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.5),
                                  fontSize: Responsive.sp(12),
                                  fontWeight: FontWeight.w500,
                                )),
                            ],
                          ),
              ),
            ),
            // Exit button
            GestureDetector(
              onTap: _exitNav,
              child: Container(
                margin: const EdgeInsets.only(right: 12),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1E2E),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(S.of(context).exitLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  //  ARRIVED BUTTON (shown when near pickup)
  // =========================================================================

  Widget _buildArrivedButton() {
    return GestureDetector(
      onTap: _arrivedAndGoBack,
      child: Container(
        height: 68,
        decoration: BoxDecoration(
          color: const Color(0xFF2E7D32),
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFF2E7D32).withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 14,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        child: Center(
          child: Text(S.of(context).arrived,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            )),
        ),
      ),
    );
  }

  // =========================================================================
  //  UPCOMING STEPS PANEL
  // =========================================================================

  void _showUpcomingSteps() {
    final steps = _navService.remainingSteps;
    if (steps.isEmpty) return;

    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1A1E2E),
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => DraggableScrollableSheet(
        initialChildSize: 0.5,
        maxChildSize: 0.9,
        minChildSize: 0.3,
        expand: false,
        builder: (ctx, scrollController) {
          return Column(
            children: [
              // Handle
              Container(
                margin: const EdgeInsets.only(top: 12),
                width: 40, height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.24),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 8),
              // Header
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    const Icon(Icons.alt_route_rounded, color: _gold, size: 20),
                    const SizedBox(width: 8),
                    Text(S.of(context).directions,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 17,
                        fontWeight: FontWeight.w800)),
                    const Spacer(),
                    Text('$_etaMinutes min · ${_distRemainingMi.toStringAsFixed(1)} mi',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Steps list
              Expanded(
                child: ListView.separated(
                  controller: scrollController,
                  padding: const EdgeInsets.all(16),
                  itemCount: steps.length,
                  separatorBuilder: (_, __) =>
                      Divider(color: Colors.white.withValues(alpha: 0.08), height: 24),
                  itemBuilder: (_, i) {
                    final step = steps[i];
                    final mInfo = NavigationService.getManeuverIcon(step.maneuver);
                    final isCurrent = i == 0;
                    return Container(
                      padding: isCurrent
                          ? const EdgeInsets.all(10)
                          : EdgeInsets.zero,
                      decoration: isCurrent
                          ? BoxDecoration(
                              color: _gold.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                  color: _gold.withValues(alpha: 0.25)),
                            )
                          : null,
                      child: Row(
                        children: [
                          SizedBox(
                            width: 56,
                            child: Text(step.distanceText,
                              style: TextStyle(
                                color: isCurrent
                                    ? _gold
                                    : Colors.white.withValues(alpha: 0.5),
                                fontSize: 13,
                                fontWeight: isCurrent
                                    ? FontWeight.w700
                                    : FontWeight.w400,
                              )),
                          ),
                          const SizedBox(width: 12),
                          Icon(mInfo.icon,
                              color: isCurrent ? _gold : Colors.white,
                              size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              step.instruction.isNotEmpty
                                  ? step.instruction
                                  : step.streetName,
                              style: TextStyle(
                                color: isCurrent ? Colors.white : Colors.white,
                                fontSize: 15,
                                fontWeight: isCurrent
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
              // Close button
              Container(
                width: double.infinity,
                color: _bottomBg,
                child: SafeArea(
                  top: false,
                  child: TextButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: Text(S.of(context).closeLabel,
                      style: const TextStyle(color: Colors.white, fontSize: 16)),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  // =========================================================================
  //  SPEED DISPLAY
  // =========================================================================

  Widget _buildSpeedOverlay(double topOffset) {
    final speed = _currentSpeedMph.round();

    // Use dynamic speed limit from Mapbox maxspeed annotation on current step
    final stepLimit = _navState?.currentStep?.maxSpeedMph;
    if (stepLimit == null) {
      // No speed data — show only current speed, hide limit sign
      return Container(
        width: 56, height: 56,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1E2E),
          borderRadius: BorderRadius.circular(10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 8, offset: const Offset(0, 2)),
          ],
        ),
        child: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('$speed',
                style: const TextStyle(
                  color: Colors.white, fontSize: 20,
                  fontWeight: FontWeight.w900, height: 1.0)),
              const Text('mph',
                style: TextStyle(
                  color: Colors.white70, fontSize: 9,
                  fontWeight: FontWeight.w600, height: 1.2)),
            ],
          ),
        ),
      );
    }

    final limit = stepLimit.round();
    final isOver = speed > limit;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Speed limit sign
        Container(
          width: 56, height: 62,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: Colors.red, width: 3),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(S.of(context).maxLabel,
                style: const TextStyle(fontSize: 9, fontWeight: FontWeight.w900,
                    color: Colors.black, height: 1.0)),
              Text('$limit',
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900,
                    color: Colors.black, height: 1.1)),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Current speed
        Container(
          width: 56, height: 56,
          decoration: BoxDecoration(
            color: isOver ? _speedRed : const Color(0xFF1A1E2E),
            borderRadius: BorderRadius.circular(10),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 8, offset: const Offset(0, 2)),
            ],
          ),
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text('$speed',
                  style: const TextStyle(
                    color: Colors.white, fontSize: 20,
                    fontWeight: FontWeight.w900, height: 1.0)),
                const Text('mph',
                  style: TextStyle(
                    color: Colors.white70, fontSize: 9,
                    fontWeight: FontWeight.w600, height: 1.2)),
              ],
            ),
          ),
        ),
      ],
    );
  }



  // =========================================================================
  //  HELPERS
  // =========================================================================

  Widget _riderAvatar({double size = 46}) {
    return VerifiedAvatar(
      photoUrl: widget.riderPhotoUrl.isNotEmpty ? widget.riderPhotoUrl : null,
      radius: size / 2,
      fallbackName: widget.riderName,
      uid: widget.riderId?.toString(),
      role: 'rider',
      isVerified: true,
    );
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

  // ── Toast notification ────────────────────────────────────────────────────
  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(Icons.check_circle_rounded, color: _gold, size: 18),
            const SizedBox(width: 10),
            Expanded(
              child: Text(msg,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 13,
                )),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1A1E2E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

}

