import 'dart:async';
import 'dart:convert';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../../models/lat_lng.dart';
import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../../config/page_transitions.dart';
import '../../services/api_service.dart';
import '../../services/navigation_service.dart';
import '../../widgets/verified_avatar.dart';
import '../../widgets/gold_map_pin.dart';
import '../../services/gps_service.dart';
import '../../services/trip_firestore_service.dart';
import '../../services/map_cache_service.dart';
import '../../services/local_cache.dart';
import '../../services/analytics_service.dart';
import '../../services/chat_service.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/gold_location_dot.dart';
import '../../config/api_keys.dart';
import '../../config/map_styles.dart';
import '../../l10n/app_localizations.dart';
import '../chat_screen.dart';
import '../safety_screen.dart';
import '../../navigation/car_icon_loader.dart';
import 'driver_info_pages.dart';
import 'driver_earnings_screen.dart';
import 'driver_promos_screen.dart';
import 'driver_analytics_screen.dart';
import 'driver_inbox_screen.dart';
import '../../services/map_launcher_service.dart';
import '../../services/preload_service.dart';
import 'package:flutter/foundation.dart' show kDebugMode;
import 'driver_trip_accept_screen.dart';
import 'trip_accepted_screen.dart';

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//  CRUISE DRIVER — ONLINE SCREEN
//  Uber Driver–style: Finding trips bar, trip request card,
//  real-time driver movement, smooth transitions, all backend
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class DriverOnlineScreen extends StatefulWidget {
  final LatLng? initialPos;
  final double initialHeading;
  final String? photoUrl;
  const DriverOnlineScreen({
    super.key,
    this.initialPos,
    this.initialHeading = 0,
    this.photoUrl,
  });
  @override
  State<DriverOnlineScreen> createState() => _DriverOnlineScreenState();
}

/// Card accept animation states.
enum _OfferAcceptState { normal, accepted, routing }

enum _Phase {
  searching,
  rideRequest,
  enRouteToPickup,
  arrivedAtPickup,
  routeSummary, // Google Maps-style route overview before navigation
  inTrip,
  completed,
}

class _DriverOnlineScreenState extends State<DriverOnlineScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // â”€â”€ Brand â”€â”€
  static const _gold = Color(0xFFD4A843);
  static const _goldLight = Color(0xFFF5D990);
  // — Route polyline —
  static const _navyRoute = Color(0xFF5BA3F5);
  static const _navyGlow  = Color(0x405BA3F5);

  // ── Map ──
  final _mapKey = GlobalKey();
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  // Active annotations
  mapbox.PointAnnotation? _carAnnot;
  mapbox.PointAnnotation? _goldDotAnnot;
  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;
  mapbox.PointAnnotation? _prevDriverAnnot;
  mapbox.PointAnnotation? _prevPickupAnnot;
  mapbox.PointAnnotation? _prevDropoffAnnot;
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.PolylineAnnotation? _previewPickupAnnot;
  mapbox.PolylineAnnotation? _previewDropoffAnnot;
  LatLng? _pos;
  StreamSubscription<Position>? _posStream;
  final _gpsService = GpsService();
  DateTime _lastNavSetState = DateTime(0);
  bool _lastStyleDark = true;
  // Cache: offerId → Future<String> static map URL (with real routed polyline)
  final Map<String, Future<String>> _offerMapUrlCache = {};

  void _animateToPosition(
    LatLng pos, {
    double zoom = 15.5,
    double bearing = 0,
    double tilt = 45,
  }) {
    _map?.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: mapbox.Position(pos.longitude, pos.latitude)),
        zoom: zoom,
        bearing: bearing,
        pitch: tilt,
      ),
      mapbox.MapAnimationOptions(duration: 600),
    );
  }

  void _moveToLatLng(LatLng pos) {
    _animateToPosition(pos);
  }

  // â”€â”€ Trip â”€â”€
  _Phase _phase = _Phase.searching;
  int? _tripId;
  int? _driverId;
  int? _currentOfferId;

  // â”€â”€ Pending ride offers (stacked cards, Spark-style) â”€â”€
  List<Map<String, dynamic>> _pendingOffers = [];
  // _offersExpanded removed — cards always visible via PageView


  // ── Route preview for a tapped offer ──
  Map<String, dynamic>? _previewingOffer;
  bool _offerRouteShown = false; // true after route draw completes
  AnimationController? _routePulseCtrl;

  // ── Pulse animation on card tap ──
  AnimationController? _pulseCtrl;
  Animation<double>? _pulseAnim;
  bool _isCardAnimating = false;
  String? _animatingOfferId; // which card is pulsing
  bool _offerDetailsVisible = false;

  // ── Reject slide-down animation ──
  String? _rejectingOfferId;
  AnimationController? _rejectSlideCtrl;

  // ── Accept card animation state ──
  _OfferAcceptState _offerAcceptState = _OfferAcceptState.normal;
  String? _acceptingCardId;
  final Set<String> _tappedCardIds = {};
  bool _showAcceptedBottomCard = false;
  String _acceptedPickupAddr = '';
  bool _isAcceptPressed = false;

  // ── Smooth route draw ──
  List<LatLng> _fullSegOne = [];
  List<LatLng> _fullSegTwo = [];
  Ticker? _routeDrawTicker;

  // ── Pre-fetched route cache (offerId → segments) ──
  final Map<String, _CachedOfferRoute> _routeCache = {};

  // â”€â”€ Request data (for active trip after acceptance) â”€â”€
  Timer? _pollT;
  String _riderName = '';
  String _riderInit = '';
  String _riderPhone = '';
  String _pickupAddr = '';
  String _dropoffAddr = '';
  double _fare = 0;
  double _distToPickup = 0;
  int _etaToPickup = 0; // ignore: unused_field
  double _tripDist = 0;
  int _tripEta = 0; // ignore: unused_field
  String _vehicleType = '';
  LatLng _pickupLL = const LatLng(0, 0);
  LatLng _dropoffLL = const LatLng(0, 0);

  // â”€â”€ Navigation â”€â”€
  double _navDist = 0;
  int _navEta = 0;
  String _navInstruct = '';
  double _navProgress = 0;
  List<LatLng> _routePts = [];
  Timer? _navTimer;
  bool _isPickupSummary = false;

  // â”€â”€ Session â”€â”€
  double _earnings = 0;
  int _trips = 0;
  Duration _online = Duration.zero;
  Timer? _clock;

  // -- Driver smooth animation --
  late AnimationController _driverAnim;
  LatLng _animFrom = const LatLng(0, 0);
  LatLng _animTo = const LatLng(0, 0);
  double _heading = 0;
  double _smoothedBearing = 0;
  Uint8List? _arrowIconBytes;

  // -- 3D nav car bytes --
  Uint8List? _navCarIconBytes;

  // -- Multi-angle 3D car sprites (8 directions) --
  List<Uint8List>? _navCarSprites;
  double _cameraBearing = 0;
  final int _lastSpriteIdx = -1;

  // -- Vehicle-based markers (asset images) --
  Uint8List? _suvIconBytes;
  Uint8List? _sedanIconBytes;
  final String _activeVehicleAsset = 'suburban';

  // -- Golden animated dot --
  final GoldLocationDot _goldDot = GoldLocationDot();
  Uint8List? _goldPinBytes;
  bool _dotPopDone = false;   // true after first-appearance pop completes
  double _dotPopScale = 0.0;  // 0→1.15→1.0 during pop, then 1.0

  // -- Turn-by-turn navigation --
  final NavigationService _navService = NavigationService();
  NavRoute? _currentNavRoute;
  NavigationState? _navState;
  bool _isRerouting = false;
  int _rerouteCount = 0;
  DateTime? _lastRerouteTime;
  // â”€â”€ UI animations â”€â”€
  late AnimationController _reqCtrl;
  late Animation<Offset> _reqSlide; // ignore: unused_field
  late AnimationController _doneCtrl;
  late Animation<double> _doneScale;
  late AnimationController _searchPulse;
  late Animation<double> _searchPulseVal;

  // â”€â”€ Slide confirm â”€â”€
  double _slideVal = 0;
  bool _slid = false;
  int _stars = 5;


  // -- Camera follow mode --
  bool _cameraFollowing = true;
  Timer? _reFollowTimer;

  // â”€â”€ Draggable panel â”€â”€
  bool _panelOpen = false;
  final _panelSheetCtrl = DraggableScrollableController();

  // ── Finding trips bar visibility ──
  bool _hideFindingBar = false;

  // ── Offer PageView swipe state ──
  final _offerPageCtrl = PageController(viewportFraction: 0.92);
  int _currentOfferIndex = 0;
  final Set<String> _expandedOfferIds = {};

  // -- Driver profile photo --
  String? _driverPhotoUrl;

  // -- Earnings pill swipe --
  double _weeklyEarnings = 0;
  double _lastTripEarnings = 0;
  int _earningsPage = 1; // 0=weekly, 1=today, 2=last trip
  double _currentSpeedMph = 0.0;

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  LIFECYCLE
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Apply initial position from home screen (avoids white flash)
    if (widget.initialPos != null) {
      _pos = widget.initialPos!;
      _heading = widget.initialHeading;
    }

    _driverAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400), // Short duration for smooth interpolation
    );
    _driverAnim.addListener(_onDriverAnimTick);

    _reqCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _reqSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _reqCtrl, curve: Curves.easeOutCubic));

    _doneCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _doneScale = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _doneCtrl, curve: Curves.elasticOut));

    _searchPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _searchPulseVal = Tween<double>(begin: 0.0, end: 1.0).animate(_searchPulse);

    // Pulse + ripple for offer card tap (tap-down scale)
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 100),
    );
    _pulseAnim = Tween<double>(begin: 1.0, end: 0.97).animate(
      CurvedAnimation(parent: _pulseCtrl!, curve: Curves.easeOut),
    );

    // Reject slide-down animation
    _rejectSlideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 300),
    );

    // Show offer details immediately — no delay
    _offerDetailsVisible = true;

    _boot();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pollT?.cancel();
      _clock?.cancel();
      _goldDot.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _startPolling();
      _startClock();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _driverAnim.removeListener(_onDriverAnimTick);
    _driverAnim.dispose();
    _reqCtrl.dispose();
    _doneCtrl.dispose();
    _searchPulse.dispose();
    _pollT?.cancel();
    _clock?.cancel();
    _navTimer?.cancel();
    _goldDot.dispose();
    _driverPhotoImage?.dispose();
    _posStream?.cancel();
    _gpsService.stopTracking();
    _reFollowTimer?.cancel();
    _panelSheetCtrl.dispose();
    _offerPageCtrl.dispose();
    _routePulseCtrl?.dispose();
    _pulseCtrl?.dispose();
    _rejectSlideCtrl?.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _map?.dispose();
    super.dispose();
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BOOT
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _boot() async {
    // Retry getting driver ID up to 3 times (critical for dispatch)
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('âœ… Got driverId=$_driverId on attempt $attempt');
          break;
        }
      } catch (e) {
        debugPrint('âš ï¸ getCurrentUserId attempt $attempt failed: $e');
      }
      if (attempt < 3) await Future.delayed(const Duration(seconds: 1));
    }
    if (_driverId == null) {
      debugPrint('âŒ Could not get driver ID after 3 attempts');
    }
    await _locate();
    await _buildVehicleIcons();
    // Gate: check verification / background check status before going online
    await _verifyDriverApproval();
    _goOnlineBackend();

    // Pre-cache map tiles around driver's current area (silent background)
    if (_pos != null) {
      MapCacheService().precacheArea(
        regionId: 'driver_area_${_driverId ?? 0}',
        lat: _pos!.latitude,
        lng: _pos!.longitude,
        minZoom: 10,
        maxZoom: 16,
        radiusKm: 5.0,
      );
    }

    _startClock();
    _startPolling();
    _startPosStream();
    _loadWeeklyEarnings();
  }

  Future<void> _loadWeeklyEarnings() async {
    try {
      final data = await ApiService.getDriverEarnings(period: 'week');
      if (mounted) {
        setState(() {
          _weeklyEarnings = (data['total'] as num?)?.toDouble() ?? 0;
        });
      }
    } catch (_) {}
  }

  Future<void> _locate() async {
    // Use pre-loaded GPS from splash if available (instant first fix)
    final preloaded = PreloadService.initialPosition;
    if (preloaded != null && _pos == null) {
      _pos = LatLng(preloaded.latitude, preloaded.longitude);
      if (mounted) setState(() {});
    }

    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationServicesDisabledMsg),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(S.of(ctx).cancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    openAppSettings();
                  },
                  child: Text(S.of(ctx).openSettings),
                ),
              ],
            ),
          );
        }
        return;
      }
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
        if (p == LocationPermission.denied) return;
      }
      if (p == LocationPermission.deniedForever) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationRequiredForDriver),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(S.of(ctx).cancel),
                ),
                TextButton(
                  onPressed: () {
                    Navigator.pop(ctx);
                    openAppSettings();
                  },
                  child: Text(S.of(ctx).openSettings),
                ),
              ],
            ),
          );
        }
        return;
      }
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      final ll = LatLng(pos.latitude, pos.longitude);
      setState(() => _pos = ll);
      _moveToLatLng(ll);
    } catch (_) {}
  }

  // â”€â”€ Build Uber-style 3D car marker sprites at runtime â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  ui.Image? _driverPhotoImage; // decoded driver photo for marker

  Future<void> _buildVehicleIcons() async {
    _suvIconBytes = await CarIconLoader.loadForRideBytes('Suburban');
    _sedanIconBytes = await CarIconLoader.loadForRideBytes('Camry');
    _arrowIconBytes = _suvIconBytes;
    // Skip PNG navatar sprites (contain blue circle overlay); use single rotated canvas car
    _navCarSprites = null;
    _navCarIconBytes = await CarIconLoader.loadUberBytes();
    await _loadDriverPhoto();
    await _goldDot.build(() { if (mounted) _updateDriverAnnotation(); });
    _goldPinBytes = await renderGoldPinBytes(icon: GoldPinIcon.car, isPickup: true);
    if (mounted) setState(() {});
  }

  /// Download and decode the driver's profile photo for the map marker.
  Future<void> _loadDriverPhoto() async {
    final url = widget.photoUrl;
    if (url == null || url.isEmpty) return;
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final codec = await ui.instantiateImageCodec(resp.bodyBytes);
        final frame = await codec.getNextFrame();
        _driverPhotoImage = frame.image;
      }
    } catch (_) {
      // fallback to golden dot
    }
  }

  /// Renders a top-down car marker with proper car silhouette using Canvas.
  ///  - Car points UP (north) so `rotation = bearing` works correctly.
  ///  - Shaped like a real car: rounded nose, wide body, tapered trunk.
  ///  - 3D depth panels visible at 55° tilt.
  Future<Uint8List> _paintCarSprite({
    required Color bodyColor,
    required Color bodyHighlight,
    required Color windowColor,
    required Color windowShine,
    required Color trimColor,
    required Color wheelColor,
    required Color shadowColor,
    required Color headlightColor,
    required Color taillightColor,
    required double widthRatio,
    required double heightRatio,
    required double roofHeightRatio,
  }) async {
    const double cW = 180.0;
    const double cH = 300.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, cW, cH));

    final double cx = cW / 2;
    final double cy = cH / 2;
    final double bW = 60.0 * widthRatio;   // half-width at widest
    final double bH = 100.0 * heightRatio; // half-height
    final double depth = 20.0 * heightRatio;

    // ── 1. DROP SHADOW ───────────────────────────────────────────────────
    canvas.drawPath(
      _carBodyPath(cx, cy + 5, bW + 8, bH + 6),
      Paint()
        ..color = shadowColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 16),
    );

    // ── 2. 3D DEPTH — bottom face (rear bumper, visible when tilted) ─────
    canvas.drawPath(
      _carBodyPath(cx, cy + depth * 0.45, bW, bH).shift(const Offset(0, 2)),
      Paint()..color = Color.lerp(bodyColor, Colors.black, 0.50)!,
    );
    // Left side depth strip
    final sideL = Path()
      ..moveTo(cx - bW * 0.92, cy - bH * 0.55)
      ..lineTo(cx - bW * 0.92 - depth * 0.3, cy - bH * 0.45)
      ..lineTo(cx - bW * 0.92 - depth * 0.3, cy + bH * 0.75 + depth * 0.4)
      ..lineTo(cx - bW * 0.78, cy + bH * 0.85)
      ..close();
    canvas.drawPath(sideL, Paint()..color = Color.lerp(bodyColor, Colors.black, 0.38)!);
    // Right side depth strip
    final sideR = Path()
      ..moveTo(cx + bW * 0.92, cy - bH * 0.55)
      ..lineTo(cx + bW * 0.92 + depth * 0.3, cy - bH * 0.45)
      ..lineTo(cx + bW * 0.92 + depth * 0.3, cy + bH * 0.75 + depth * 0.4)
      ..lineTo(cx + bW * 0.78, cy + bH * 0.85)
      ..close();
    canvas.drawPath(sideR, Paint()..color = Color.lerp(bodyColor, Colors.black, 0.28)!);

    // ── 3. WHEELS ────────────────────────────────────────────────────────
    final double wW = 16.0 * widthRatio;
    final double wH = 32.0 * heightRatio;
    final wheels = [
      Offset(cx - bW * 0.94, cy - bH * 0.48),
      Offset(cx + bW * 0.94, cy - bH * 0.48),
      Offset(cx - bW * 0.90, cy + bH * 0.50),
      Offset(cx + bW * 0.90, cy + bH * 0.50),
    ];
    for (final wp in wheels) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: wp, width: wW, height: wH),
          const Radius.circular(4),
        ),
        Paint()..color = wheelColor,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: wp, width: wW * 0.45, height: wH * 0.45),
          const Radius.circular(3),
        ),
        Paint()..color = const Color(0xFF555555),
      );
    }

    // ── 4. BODY (car silhouette path — rounded nose, wide hips, tapered rear)
    final bodyPath = _carBodyPath(cx, cy, bW, bH);
    // Base fill
    canvas.drawPath(bodyPath, Paint()..color = bodyColor);
    // Highlight gradient
    final bodyBounds = bodyPath.getBounds();
    canvas.drawPath(
      bodyPath,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.25, -0.4),
          radius: 0.9,
          colors: [bodyHighlight, bodyColor],
        ).createShader(bodyBounds),
    );
    // Outline
    canvas.drawPath(
      bodyPath,
      Paint()
        ..color = Color.lerp(bodyColor, Colors.black, 0.15)!
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..strokeJoin = StrokeJoin.round,
    );

    // ── 5. HOOD LINES (subtle creases on the hood) ───────────────────────
    for (final sign in [-1.0, 1.0]) {
      canvas.drawLine(
        Offset(cx + sign * bW * 0.28, cy - bH * 0.82),
        Offset(cx + sign * bW * 0.22, cy - bH * 0.38),
        Paint()
          ..color = Color.lerp(bodyColor, Colors.black, 0.08)!
          ..strokeWidth = 1.2
          ..strokeCap = StrokeCap.round,
      );
    }

    // ── 6. WINDSHIELD (front — wider, trapezoid shape) ───────────────────
    final wsPath = Path()
      ..moveTo(cx - bW * 0.58, cy - bH * 0.38)
      ..lineTo(cx - bW * 0.50, cy - bH * 0.12)
      ..lineTo(cx + bW * 0.50, cy - bH * 0.12)
      ..lineTo(cx + bW * 0.58, cy - bH * 0.38)
      ..close();
    canvas.drawPath(wsPath, Paint()..color = windowColor);
    // Sheen
    final sheenPath = Path()
      ..moveTo(cx - bW * 0.52, cy - bH * 0.35)
      ..lineTo(cx - bW * 0.42, cy - bH * 0.16)
      ..lineTo(cx - bW * 0.30, cy - bH * 0.16)
      ..lineTo(cx - bW * 0.38, cy - bH * 0.35)
      ..close();
    canvas.drawPath(sheenPath, Paint()..color = windowShine.withValues(alpha: 0.22));

    // ── 7. ROOF PANEL (between windows) ──────────────────────────────────
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + bH * 0.04),
          width: bW * 0.94,
          height: bH * 0.22,
        ),
        const Radius.circular(4),
      ),
      Paint()..color = Color.lerp(bodyColor, bodyHighlight, 0.3)!,
    );

    // ── 8. REAR WINDOW (narrower trapezoid) ──────────────────────────────
    final rwPath = Path()
      ..moveTo(cx - bW * 0.48, cy + bH * 0.18)
      ..lineTo(cx - bW * 0.42, cy + bH * 0.40)
      ..lineTo(cx + bW * 0.42, cy + bH * 0.40)
      ..lineTo(cx + bW * 0.48, cy + bH * 0.18)
      ..close();
    canvas.drawPath(rwPath, Paint()..color = windowColor);

    // ── 9. SIDE WINDOWS (small trapezoids left & right) ──────────────────
    for (final sign in [-1.0, 1.0]) {
      final swPath = Path()
        ..moveTo(cx + sign * bW * 0.54, cy - bH * 0.32)
        ..lineTo(cx + sign * bW * 0.82, cy - bH * 0.22)
        ..lineTo(cx + sign * bW * 0.82, cy + bH * 0.12)
        ..lineTo(cx + sign * bW * 0.54, cy + bH * 0.12)
        ..close();
      canvas.drawPath(swPath, Paint()..color = windowColor.withValues(alpha: 0.7));
    }

    // ── 10. HEADLIGHTS (wraparound at front corners) ─────────────────────
    for (final sign in [-1.0, 1.0]) {
      final hlPath = Path()
        ..moveTo(cx + sign * bW * 0.50, cy - bH * 0.88)
        ..quadraticBezierTo(
          cx + sign * bW * 0.82, cy - bH * 0.84,
          cx + sign * bW * 0.78, cy - bH * 0.72,
        )
        ..lineTo(cx + sign * bW * 0.58, cy - bH * 0.74)
        ..close();
      canvas.drawPath(hlPath, Paint()..color = headlightColor);
    }

    // ── 11. TAILLIGHTS (wide bars at rear) ───────────────────────────────
    for (final sign in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + sign * bW * 0.48, cy + bH * 0.88),
            width: bW * 0.48,
            height: 8,
          ),
          const Radius.circular(4),
        ),
        Paint()..color = taillightColor,
      );
    }
    // Tail connector strip
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: Offset(cx, cy + bH * 0.88),
          width: bW * 0.5,
          height: 4,
        ),
        const Radius.circular(2),
      ),
      Paint()..color = taillightColor.withValues(alpha: 0.4),
    );

    // ── 12. SIDE MIRRORS ─────────────────────────────────────────────────
    for (final sign in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + sign * (bW + 6), cy - bH * 0.28),
          width: 10,
          height: 14,
        ),
        Paint()..color = bodyColor,
      );
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(cx + sign * (bW + 6), cy - bH * 0.28),
          width: 10,
          height: 14,
        ),
        Paint()
          ..color = Color.lerp(bodyColor, Colors.black, 0.15)!
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2,
      );
    }

    // ── 13. ENCODE ───────────────────────────────────────────────────────
    final picture = recorder.endRecording();
    final image = await picture.toImage(cW.toInt(), cH.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return Uint8List(0);
    return byteData.buffer.asUint8List();
  }

  /// Car body silhouette path — rounded nose, wide at cabin, tapered trunk.
  /// Front = top, rear = bottom.
  static Path _carBodyPath(double cx, double cy, double bW, double bH) {
    return Path()
      // Start at front-center (nose)
      ..moveTo(cx, cy - bH * 0.95)
      // Front bumper curve (rounded nose)
      ..quadraticBezierTo(cx + bW * 0.55, cy - bH * 0.94, cx + bW * 0.72, cy - bH * 0.78)
      // Front fender flare
      ..quadraticBezierTo(cx + bW * 0.92, cy - bH * 0.62, cx + bW * 0.92, cy - bH * 0.40)
      // Straight body sides (widest point at doors)
      ..lineTo(cx + bW * 0.88, cy + bH * 0.30)
      // Rear fender taper
      ..quadraticBezierTo(cx + bW * 0.86, cy + bH * 0.68, cx + bW * 0.68, cy + bH * 0.85)
      // Rear bumper curve
      ..quadraticBezierTo(cx + bW * 0.40, cy + bH * 0.95, cx, cy + bH * 0.96)
      // Mirror left side
      ..quadraticBezierTo(cx - bW * 0.40, cy + bH * 0.95, cx - bW * 0.68, cy + bH * 0.85)
      ..quadraticBezierTo(cx - bW * 0.86, cy + bH * 0.68, cx - bW * 0.88, cy + bH * 0.30)
      ..lineTo(cx - bW * 0.92, cy - bH * 0.40)
      ..quadraticBezierTo(cx - bW * 0.92, cy - bH * 0.62, cx - bW * 0.72, cy - bH * 0.78)
      ..quadraticBezierTo(cx - bW * 0.55, cy - bH * 0.94, cx, cy - bH * 0.95)
      ..close();
  }

  /// Get the correct vehicle icon bytes based on the vehicle type.
  Uint8List? get _vehicleIconBytes {
    final vt = _vehicleType.trim().toLowerCase();
    if (vt.contains('suburban') || vt.contains('suv')) return _suvIconBytes;
    if (vt.contains('fusion') || vt.contains('camry') || vt.contains('sedan')) return _sedanIconBytes;
    if (vt.contains('cruisex') || vt.contains('cruise')) return _sedanIconBytes;
    return _suvIconBytes;
  }

  bool _approvalGatePassed = false;

  Future<void> _verifyDriverApproval() async {
    try {
      final me = await ApiService.getMe();
      if (me == null) return;
      final bgStatus = me['background_check_status'] as String? ?? 'none';
      final verStatus = me['verification_status'] as String? ?? 'none';
      if (bgStatus == 'clear' || verStatus == 'approved') {
        _approvalGatePassed = true;
        return;
      }
      _approvalGatePassed = false;
      if (!mounted) return;
      String title;
      String message;
      if (bgStatus == 'pending' || bgStatus == 'processing') {
        title = 'Background Check In Progress';
        message = 'Your background check is still being processed. You\'ll be notified when it\'s complete.';
      } else if (bgStatus == 'consider' || bgStatus == 'suspended') {
        title = 'Background Check Issue';
        message = 'There is an issue with your background check. Please contact support.';
      } else {
        title = 'Verification Required';
        message = 'Please complete your documents and background check before going online.';
      }
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1C1C1E),
          title: Text(title, style: const TextStyle(color: Colors.white)),
          content: Text(message, style: TextStyle(color: Colors.white.withValues(alpha: 0.7))),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK', style: TextStyle(color: Color(0xFFE8C547))),
            ),
          ],
        ),
      );
    } catch (e) {
      debugPrint('_verifyDriverApproval error: $e');
      _approvalGatePassed = true;
    }
  }

  void _goOnlineBackend() {
    if (_driverId == null) {
      debugPrint('âš ï¸ _goOnlineBackend: _driverId is null, skipping');
      return;
    }
    debugPrint(
      'ðŸŸ¢ Going online: driverId=$_driverId lat=${_pos?.latitude} lng=${_pos?.longitude}',
    );
    if (!_approvalGatePassed) {
      debugPrint('_goOnlineBackend: approval gate not passed, skipping');
      return;
    }
    if (_pos == null) return;
    // Save last known location for startup pre-caching
    LocalCache.set('last_driver_lat', _pos!.latitude);
    LocalCache.set('last_driver_lng', _pos!.longitude);
    ApiService.updateDriverLocation(
          driverId: _driverId!,
          lat: _pos!.latitude,
          lng: _pos!.longitude,
          isOnline: true,
        )
        .then((_) {
          debugPrint('âœ… Driver online successfully');
          AnalyticsService.instance.logDriverOnline();
        })
        .catchError((e) {
          debugPrint('âŒ Failed to go online: $e');
        });
  }

  void _goOfflineBackend() {
    if (_driverId == null || _pos == null) return;
    AnalyticsService.instance.logDriverOffline();
    ApiService.updateDriverLocation(
      driverId: _driverId!,
      lat: _pos!.latitude,
      lng: _pos!.longitude,
      isOnline: false,
    ).catchError((_) => <String, dynamic>{});
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  DRIVER POSITION STREAM (smooth movement on map)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startPosStream() {
    // Start GpsService for Firebase RTDB uploads + presence
    if (_driverId != null) {
      _gpsService.startTracking(_driverId.toString());
    }

    _posStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 1, // 1 meter for maximum smooth movement
          ),
        ).listen((pos) {
          if (!mounted) return;
          final newLL = LatLng(pos.latitude, pos.longitude);
          _smoothedBearing = _lerpAngle(_smoothedBearing, pos.heading, 0.30);
          _currentSpeedMph = (pos.speed * 2.23694).clamp(0.0, 200.0);
          // Snap to route polyline — prevents GPS drift off-road
          final snappedLL = _snapToRoute(newLL);
          _smoothMoveTo(snappedLL, _smoothedBearing);

          // Feed GpsService for RTDB upload (800ms throttled)
          _gpsService.updatePosition(newLL, pos.heading, pos.speed);

          _trimRouteBehindDriver(snappedLL);

          // Phase-specific nav stats (camera handled by _onDriverAnimTick)
          if (_phase == _Phase.routeSummary) {
            final dist = _hav(newLL, _dropoffLL);
            final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
            _navDist = dist;
            _navEta = eta;
            final now = DateTime.now();
            if (now.difference(_lastNavSetState).inMilliseconds > 500) {
              _lastNavSetState = now;
              setState(() {});
            }
          } else if (_phase == _Phase.enRouteToPickup) {
            _updateNavState(newLL);
            final dist = _hav(newLL, _pickupLL);
            final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
            final progress = _distToPickup > 0
                ? (1.0 - dist / _distToPickup).clamp(0.0, 1.0)
                : 0.0;
            _navDist = dist;
            _navEta = eta;
            _navProgress = progress;
            final now1 = DateTime.now();
            if (now1.difference(_lastNavSetState).inMilliseconds > 500) {
              _lastNavSetState = now1;
              setState(() {});
            }
            if (dist < 0.05) {
              _onNearPickup();
            }
          } else if (_phase == _Phase.inTrip) {
            _updateNavState(newLL);
            final dist = _hav(newLL, _dropoffLL);
            final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
            final progress = _tripDist > 0
                ? (1.0 - dist / _tripDist).clamp(0.0, 1.0)
                : 0.0;
            _navDist = dist;
            _navEta = eta;
            _navProgress = progress;
            final now2 = DateTime.now();
            if (now2.difference(_lastNavSetState).inMilliseconds > 500) {
              _lastNavSetState = now2;
              setState(() {});
            }
            if (dist < 0.05) {
              _onNearDropoff();
            }
          }

          // Always update driver location to backend
          if (_driverId != null) {
            ApiService.updateDriverLocation(
              driverId: _driverId!,
              lat: pos.latitude,
              lng: pos.longitude,
            ).catchError((_) => <String, dynamic>{});
          }
          // Sync driver GPS to Firestore so rider tracking gets real position
          if (_tripId != null) {
            TripFirestoreService.syncDriverLocation(
              _tripId!.toString(),
              pos.latitude,
              pos.longitude,
              _smoothedBearing,
            );
          }
        }, onError: (_) {});
  }

  /// Update turn-by-turn navigation state from GPS position.
  void _updateNavState(LatLng pos) {
    if (!_navService.isNavigating) return;
    final state = _navService.updatePosition(pos);
    if (state == null) return;

    _navState = state;

    // Update displayed instruction & distance from NavigationService
    if (state.currentInstruction.isNotEmpty) {
      _navInstruct = state.currentInstruction;
    }
    _navEta = state.etaMinutes;
    _navDist = state.distanceRemainingMiles;
    _navProgress = state.progress;

    // Off-route detection & auto-reroute
    if (state.isOffRoute && !_isRerouting) {
      final now = DateTime.now();
      final canReroute =
          _lastRerouteTime == null ||
          now.difference(_lastRerouteTime!).inSeconds > 10;
      if (canReroute && _rerouteCount < 5) {
        _triggerReroute(pos);
      }
    }
  }

  /// Reroute from current position to the active destination.
  Future<void> _triggerReroute(LatLng from) async {
    if (_isRerouting) return;
    _isRerouting = true;
    _lastRerouteTime = DateTime.now();
    _rerouteCount++;
    debugPrint('Rerouting (#$_rerouteCount)');
    HapticFeedback.mediumImpact();

    final dest = _phase == _Phase.enRouteToPickup ? _pickupLL : _dropoffLL;
    final routeId = _phase == _Phase.enRouteToPickup ? 'pickup' : 'trip';
    await _drawRoute(from, dest, routeId, _navyRoute);
    _isRerouting = false;
  }

  bool _nearPickupNotified = false;
  bool _nearDropoffNotified = false;

  void _onNearPickup() {
    if (_nearPickupNotified || _phase != _Phase.enRouteToPickup) return;
    _nearPickupNotified = true;
    HapticFeedback.heavyImpact();
    // Send final position to backend so rider sees driver at pickup
    if (_driverId != null) {
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _pickupLL.latitude,
        lng: _pickupLL.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    // Show ARRIVED button
    setState(() {});
  }

  void _onNearDropoff() {
    if (_nearDropoffNotified || _phase != _Phase.inTrip) return;
    _nearDropoffNotified = true;
    HapticFeedback.heavyImpact();
    // Send final position to backend so rider sees driver at dropoff
    if (_driverId != null) {
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _dropoffLL.latitude,
        lng: _dropoffLL.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    // Show FINISH TRIP button in panel
    setState(() {});
  }


  double _targetHeading = 0;

  void _smoothMoveTo(LatLng target, double heading) {
    _animFrom = _pos!;
    _animTo = target;
    _targetHeading = heading;
    _driverAnim.forward(from: 0);
  }

  /// Trim the route polyline behind the driver so only upcoming road is shown.
  /// Google Maps navigation style — route "disappears" behind the car.
  void _trimRouteBehindDriver(LatLng driverPos) {
    if (_routePts.length < 3) return;
    if (_phase != _Phase.enRouteToPickup && _phase != _Phase.inTrip) return;

    // Find the closest point on the DISPLAY route (not the simulation copy)
    int closestIdx = 0;
    double closestDist = double.infinity;
    for (int i = 0; i < _routePts.length; i++) {
      final d = _hav(driverPos, _routePts[i]) * 1000; // meters
      if (d < closestDist) {
        closestDist = d;
        closestIdx = i;
      }
    }

    // Only trim if we've passed at least 1 point
    if (closestIdx > 0) {
      _routePts = _routePts.sublist(closestIdx);
    }
    // Always put driver at front for seamless line
    if (_routePts.isNotEmpty) {
      _routePts[0] = driverPos;
    }

    // Rebuild route annotation with trimmed route
    _setRouteAnnotation(List.from(_routePts), _navyRoute);
  }

  void _onDriverAnimTick() {
    if (!mounted) return;
    final t = Curves.easeInOutCubic.transform(_driverAnim.value);
    final lat =
        _animFrom.latitude + (_animTo.latitude - _animFrom.latitude) * t;
    final lng =
        _animFrom.longitude + (_animTo.longitude - _animFrom.longitude) * t;
    _pos = LatLng(lat, lng);

    // Super smooth bearing interpolation
    double diff = _targetHeading - _heading;
    while (diff > 180) { diff -= 360; }
    while (diff < -180) { diff += 360; }
    _heading += diff * (t * 0.25).clamp(0.0, 1.0);

    // Unified camera following (single source of truth for all phases)
    final isNav = _phase == _Phase.enRouteToPickup || _phase == _Phase.inTrip;
    if (_phase == _Phase.searching) {
      // Searching: smooth top-down follow using lerped position
      _map?.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          zoom: 15.5,
          bearing: 0,
          pitch: 0,
        ),
        mapbox.MapAnimationOptions(duration: 800),
      );
    } else if (isNav && _cameraFollowing) {
      // Navigation: 2.5D chase cam using lerped position + bearing
      _cameraBearing = _heading;
      _map?.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          zoom: 17.5,
          bearing: _heading,
          pitch: 55,
        ),
        mapbox.MapAnimationOptions(duration: 600),
      );
    }

    _updateDriverAnnotation();
    setState(() {});
  }

  /// Update the driver car / golden dot annotation on the Mapbox map.
  Future<void> _updateDriverAnnotation() async {
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;

    final isNav = _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;

    if (!isNav) {
      final dotBytes = _goldDot.currentBytes;
      if (dotBytes == null) return;
      // Remove car annotation if switching to gold dot
      if (_carAnnot != null) {
        try { await pointMgr.delete(_carAnnot!); } catch (_) {}
        _carAnnot = null;
      }
      if (_goldDotAnnot != null) {
        try {
          _goldDotAnnot!.geometry = mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude));
          _goldDotAnnot!.image = dotBytes;
          _goldDotAnnot!.iconSize = _dotPopScale;
          await pointMgr.update(_goldDotAnnot!);
        } catch (_) { _goldDotAnnot = null; }
      }
      if (_pos == null) return;
      if (_goldDotAnnot == null) {
        _goldDotAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          image: dotBytes,
          iconSize: _dotPopScale,
        ));
        // Trigger fade+pop on first creation
        if (!_dotPopDone) _animateDotPop();
      }
    } else if (isNav) {
      // Remove dot annotation if switching to car
      if (_goldDotAnnot != null) {
        try { await pointMgr.delete(_goldDotAnnot!); } catch (_) {}
        _goldDotAnnot = null;
      }
      // Use single rotated canvas car — sprites disabled (caused duplicate marker)
      final Uint8List? carBytes = _navCarIconBytes ?? _vehicleIconBytes ?? _arrowIconBytes;
      if (carBytes != null) {
        if (_carAnnot != null) {
          try {
            _carAnnot!.geometry = mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude));
            _carAnnot!.iconRotate = _heading;
            await pointMgr.update(_carAnnot!);
          } catch (_) { _carAnnot = null; }
        }
        if (_carAnnot == null) {
          _carAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
            image: carBytes,
            iconSize: 1.2,
            iconRotate: _heading,
          ));
          // Car icon rotates relative to map, not camera
          try {
            await _map?.style.setStyleLayerProperty(
              pointMgr.id, 'icon-rotation-alignment', 'map');
          } catch (_) {}
        }
      }
    }
  }

  /// Fade + pop animation when the gold dot first appears.
  /// Scale: 0 → 1.15 (overshoot) → 1.0 (settle). ~350 ms total.
  Future<void> _animateDotPop() async {
    _dotPopDone = true;
    // Phase 1: scale 0 → 1.15 over ~200 ms (12 frames × 16 ms)
    const riseSteps = 12;
    for (int i = 1; i <= riseSteps; i++) {
      await Future.delayed(const Duration(milliseconds: 16));
      if (!mounted) return;
      _dotPopScale = (i / riseSteps) * 1.15;
      _updateDriverAnnotation();
    }
    // Phase 2: bounce back 1.15 → 1.0 over ~150 ms (9 frames × 16 ms)
    const bounceSteps = 9;
    for (int i = 1; i <= bounceSteps; i++) {
      await Future.delayed(const Duration(milliseconds: 16));
      if (!mounted) return;
      _dotPopScale = 1.15 - (0.15 * (i / bounceSteps));
      _updateDriverAnnotation();
    }
    _dotPopScale = 1.0;
    if (mounted) _updateDriverAnnotation();
  }

  /// Snap a raw GPS coordinate to the nearest point on the active route polyline.
  /// Only snaps within 40 m — beyond that threshold the raw GPS is authoritative.
  LatLng _snapToRoute(LatLng raw) {
    if (_routePts.length < 2 ||
        (_phase != _Phase.enRouteToPickup && _phase != _Phase.inTrip)) {
      return raw;
    }
    double bestDist = double.infinity;
    LatLng best = raw;
    for (int i = 0; i < _routePts.length - 1; i++) {
      final candidate = _closestPointOnSegment(
        raw,
        _routePts[i],
        _routePts[i + 1],
      );
      final d = _hav(raw, candidate);
      if (d < bestDist) {
        bestDist = d;
        best = candidate;
      }
    }
    return bestDist <= 0.040 ? best : raw; // 40 m snap radius
  }

  /// Closest point on segment [a→b] to point [p] (flat lat/lng approximation).
  LatLng _closestPointOnSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return a;
    final t =
        ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
        len2;
    final tc = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + tc * dy, a.longitude + tc * dx);
  }

  double _bearingBetween(LatLng a, LatLng b) {
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final aLat = a.latitude * math.pi / 180;
    final bLat = b.latitude * math.pi / 180;
    final x = math.sin(dLng) * math.cos(bLat);
    final y =
        math.cos(aLat) * math.sin(bLat) -
        math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
    return (math.atan2(x, y) * 180 / math.pi + 360) % 360;
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  POLLING & CLOCK
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startPolling() {
    _pollT?.cancel();
    _pollT = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _phase != _Phase.searching) return;
      _poll();
    });
  }

  Future<void> _poll() async {
    if (_driverId == null) {
      debugPrint(
        'âš ï¸ _poll: _driverId is null, retrying getCurrentUserId...',
      );
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('âœ… Recovered driverId=$_driverId during polling');
          _goOnlineBackend(); // Re-establish online status
        }
      } catch (_) {}
      if (_driverId == null) return;
    }
    try {
      final offers = await ApiService.getDriverPendingOffers(_driverId!);
      debugPrint('ðŸ“¡ Poll result: ${offers.length} offer(s)');
      if (!mounted || _phase != _Phase.searching) return;
      if (offers.isNotEmpty && _pendingOffers.isEmpty) {
        HapticFeedback.heavyImpact();
      }
      final hadOffers = _pendingOffers.isNotEmpty;
      setState(() {
        _pendingOffers = offers;
        _currentOfferIndex = _currentOfferIndex.clamp(0, offers.length - 1);
        // Hide finding bar when offers appear, show when all dismissed
        if (offers.isNotEmpty && !hadOffers) _hideFindingBar = true;
        if (offers.isEmpty && hadOffers) _hideFindingBar = false;
      });
      _preFetchOfferRoutes(offers);
      // Auto-trigger cinematic route preview when first offer arrives
      if (offers.isNotEmpty && !hadOffers) {
        _autoTriggerRoutePreview(offers.first);
      }
    } catch (e) {
      debugPrint('âŒ Poll error: $e');
    }
  }

  /// Pre-fetch routes for incoming offers so they are cached before card tap.
  void _preFetchOfferRoutes(List<Map<String, dynamic>> offers) {
    if (_pos == null) return;
    // Auto-evict entries older than 10 minutes
    final now = DateTime.now();
    _routeCache.removeWhere((_, v) => now.difference(v.cachedAt).inMinutes > 10);
    for (final offer in offers) {
      // Pre-warm rider photo so it's instant when card shows
      final photoUrl = (offer['rider_photo_url'] ?? offer['photo_url'] ?? '') as String;
      if (photoUrl.isNotEmpty) {
        CachedNetworkImageProvider(photoUrl).resolve(const ImageConfiguration());
      }
      final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();
      if (oid.isEmpty || _routeCache.containsKey(oid)) continue;
      final pLat = (offer['pickup_lat'] as num?)?.toDouble() ?? 0;
      final pLng = (offer['pickup_lng'] as num?)?.toDouble() ?? 0;
      final dLat = (offer['dropoff_lat'] as num?)?.toDouble() ?? 0;
      final dLng = (offer['dropoff_lng'] as num?)?.toDouble() ?? 0;
      if (pLat == 0 || pLng == 0 || dLat == 0 || dLng == 0) continue;
      final pickupLL  = LatLng(pLat, pLng);
      final dropoffLL = LatLng(dLat, dLng);
      // Pre-cache map tiles for pickup + dropoff areas (silent background)
      MapCacheService().precacheRoute(
        offerId: oid,
        pickupLat: pLat,
        pickupLng: pLng,
        dropoffLat: dLat,
        dropoffLng: dLng,
      );

      // Pre-detect dropoff place type from address
      final dropoffAddr = (offer['dropoff_address'] ?? '') as String;
      final placeType = _detectPlaceType(dropoffAddr);

      // Pre-build unified gold pins + fetch routes in parallel
      Future.wait<Object?>([
        _fetchRoutePoints(_pos!, pickupLL),                                         // [0] segOne
        _fetchRoutePoints(pickupLL, dropoffLL),                                     // [1] segTwo
        renderGoldPinBytes(icon: GoldPinIcon.car, isPickup: true),               // [2] driver pos pin
        renderGoldPinBytes(icon: GoldPinIcon.person, isPickup: true),               // [3] pickup pin
        renderGoldPinBytes(icon: _goldPinIconFor(placeType), isPickup: false),      // [4] dropoff pin
      ]).then((results) {
        if (!mounted) return;
        _routeCache[oid] = _CachedOfferRoute(
          segOne: results[0] as List<LatLng>,
          segTwo: results[1] as List<LatLng>,
          cachedAt: DateTime.now(),
          dropoffPlaceType: placeType,
          driverPin: results[2] as Uint8List?,
          pickupPin: results[3] as Uint8List?,
          dropoffPin: results[4] as Uint8List?,
        );
      }).catchError((_) {});
    }
  }

  void _startClock() {
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _online += const Duration(seconds: 1));
    });
  }

  String get _timeStr {
    final h = _online.inHours,
        m = _online.inMinutes.remainder(60),
        s = _online.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  RIDE OFFER ACTIONS (Spark-style: persistent cards)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _acceptOffer(Map<String, dynamic> r) async {
    // Prevent double-tap
    final oid = (r['offer_id'] ?? r['id'] ?? '').toString();
    if (_offerAcceptState != _OfferAcceptState.normal) return;

    HapticFeedback.heavyImpact();

    // Immediately mark as accepted (visual feedback)
    setState(() {
      _acceptingCardId = oid;
      _offerAcceptState = _OfferAcceptState.accepted;
    });

    final offerId = r['offer_id'] as int?;
    final tripId = r['trip_id'] as int? ?? r['id'] as int?;

    // Accept via API (fire-and-forget for speed, catch errors)
    if (!_isSimulationMode) {
      if (offerId != null && _driverId != null) {
        try {
          await ApiService.acceptRideOffer(
            offerId: offerId,
            driverId: _driverId!,
          );
        } catch (e) {
          if (mounted) _snack(S.of(context).tripNoLongerAvailable);
          setState(() {
            _pendingOffers.removeWhere((o) => o['offer_id'] == offerId);
            _offerAcceptState = _OfferAcceptState.normal;
            _acceptingCardId = null;
          });
          return;
        }
      } else if (tripId != null && _driverId != null) {
        try {
          await ApiService.acceptTrip(tripId: tripId, driverId: _driverId!);
        } catch (e) {
          if (mounted) _snack(S.of(context).tripNoLongerAvailable);
          setState(() {
            _pendingOffers.removeWhere((o) => o['trip_id'] == tripId);
            _offerAcceptState = _OfferAcceptState.normal;
            _acceptingCardId = null;
          });
          return;
        }
      }
    }

    // Reject all other pending offers silently
    for (final other in _pendingOffers) {
      final otherId = other['offer_id'] as int?;
      if (otherId != null && otherId != offerId && _driverId != null) {
        ApiService.rejectRideOffer(
          offerId: otherId,
          driverId: _driverId!,
        ).catchError((_) => <String, dynamic>{});
      }
    }

    // Populate active trip data from the accepted offer
    final name = (r['rider_name'] ?? 'Rider') as String;
    _pickupLL = LatLng(
      (r['pickup_lat'] as num?)?.toDouble() ?? 0.0,
      (r['pickup_lng'] as num?)?.toDouble() ?? 0.0,
    );
    _dropoffLL = LatLng(
      (r['dropoff_lat'] as num?)?.toDouble() ?? 0.0,
      (r['dropoff_lng'] as num?)?.toDouble() ?? 0.0,
    );

    _currentOfferId = offerId;
    _tripId = tripId;
    _riderName = name;
    _riderInit = name.isNotEmpty ? name[0].toUpperCase() : '?';
    _riderPhone = (r['rider_phone'] ?? '') as String;
    _pickupAddr = r['pickup_address'] ?? 'Pickup';
    _dropoffAddr = r['dropoff_address'] ?? 'Drop-off';
    _fare = (r['fare'] as num?)?.toDouble() ?? 0;
    _vehicleType = _mapRideType((r['vehicle_type'] ?? 'Comfort') as String);
    _distToPickup = _hav(_pos!, _pickupLL);
    _etaToPickup = (_distToPickup * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    _tripDist = _hav(_pickupLL, _dropoffLL);
    _tripEta = (_tripDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);

    // ── Extract cached route BEFORE clearing cache ──
    final cachedRouteData = _routeCache[oid];
    final preRoutePoints = cachedRouteData?.segOne;

    setState(() => _pendingOffers = []);
    _routeCache.clear();
    _expandedOfferIds.clear();
    _pollT?.cancel();
    _nearPickupNotified = false;
    _nearDropoffNotified = false;

    // ── Reset offer state and navigate to full-screen accepted screen ──
    _acceptedPickupAddr = _pickupAddr;
    _tappedCardIds.clear();
    setState(() {
      _showAcceptedBottomCard = false;
      _offerAcceptState = _OfferAcceptState.normal;
      _acceptingCardId = null;
    });

    final riderPhotoUrl = (r['rider_photo_url'] ?? r['photo_url'] ?? '') as String;
    final riderRating   = (r['rider_rating']   as num?)?.toDouble() ?? 4.8;
    final riderInit     = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final result = await Navigator.of(context).push<String>(
      smoothFadeRoute(
        TripAcceptedScreen(
          tripId:         tripId ?? offerId ?? 0,
          riderName:      name,
          riderInitials:  riderInit,
          riderPhotoUrl:  riderPhotoUrl.isNotEmpty ? riderPhotoUrl : null,
          riderRating:    riderRating,
          pickupLatLng:   _pickupLL,
          dropoffLatLng:  _dropoffLL,
          pickupAddress:  _pickupAddr,
          dropoffAddress: _dropoffAddr,
          fare:           _fare,
          vehicleType:    _vehicleType,
          driverPos:      _pos!,
          distToPickupKm: _distToPickup,
          etaMinutes:     _etaToPickup,
          riderPhone:     _riderPhone,
          routePoints:    preRoutePoints,
        ),
      ),
    );
    if (!mounted) return;
    if (result == 'completed') {
      // Show the earnings / completed overlay (mirrors _complete())
      setState(() {
        _trips++;
        _earnings += _fare;
        _lastTripEarnings = _fare;
        _phase = _Phase.completed;
        _stars = 5;
      });
      _doneCtrl.forward(from: 0);
    } else {
      // Cancelled or back-pressed — return to searching
      _cancel();
    }
  }

  Future<void> _rejectOffer(Map<String, dynamic> r) async {
    HapticFeedback.lightImpact();
    final offerId = r['offer_id'] as int?;

    // INSTANT dismiss — remove card + clear map in the same frame
    setState(() {
      _rejectingOfferId = null;
      _pendingOffers.removeWhere((o) => o['offer_id'] == offerId);
      if (_pendingOffers.isEmpty) _hideFindingBar = false;
      _previewingOffer = null;
      _offerRouteShown = false;
      _fullSegOne = [];
      _fullSegTwo = [];
    });
    _rejectSlideCtrl?.reset();
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);

    // Fire-and-forget API rejection — UI already updated
    if (offerId != null && _driverId != null) {
      ApiService.rejectRideOffer(
        offerId: offerId,
        driverId: _driverId!,
      ).catchError((_) => <String, dynamic>{});
    }
    if (offerId != null) _routeCache.remove(offerId.toString());
  }

  // â”€â”€ _accept and _decline removed — now using _acceptOffer / _rejectOffer â”€â”€

  Future<void> _runAcceptCameraSequence() async {
    if (_map == null || !mounted) return;

    // Phase 1: Fit route bounds with padding for bottom card
    try {
      final cam = await _map!.cameraForCoordinatesPadding(
        [
          mapbox.Point(coordinates: mapbox.Position(_pickupLL.longitude, _pickupLL.latitude)),
          mapbox.Point(coordinates: mapbox.Position(_dropoffLL.longitude, _dropoffLL.latitude)),
        ],
        mapbox.CameraOptions(),
        mapbox.MbxEdgeInsets(top: 80, left: 60, bottom: 280, right: 60),
        null, null,
      );
      if (!mounted) return;
      await _map?.flyTo(cam, mapbox.MapAnimationOptions(duration: 300));
    } catch (_) {}

    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    // Phase 2: Tilt to 55
    _map?.flyTo(
      mapbox.CameraOptions(pitch: 55),
      mapbox.MapAnimationOptions(duration: 800),
    );
    await Future.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    // Phase 3: Rotate 20
    _map?.flyTo(
      mapbox.CameraOptions(bearing: 20),
      mapbox.MapAnimationOptions(duration: 600),
    );
  }

  Future<void> _showPickupSummary() async {
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(
          tripId: _tripId!,
          status: 'driver_en_route',
        );
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _isPickupSummary = true;
      _phase = _Phase.routeSummary;
      _cameraFollowing = false;
      _navDist = _hav(_pos!, _pickupLL);
      _navEta = (_navDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _navInstruct = S.of(context).headToPickup;
      _navProgress = 0;
      _slideVal = 0;
      _slid = false;
    });
    _setPickupDropoffAnnotations();
    await _drawRoute(_pos!, _pickupLL, 'pickup', _navyRoute);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitBounds(_pos!, _pickupLL);
    });
  }

  Future<void> _toPickup() async {
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(
          tripId: _tripId!,
          status: 'driver_en_route',
        );
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _phase = _Phase.enRouteToPickup;
      _cameraFollowing = true;
      _reFollowTimer?.cancel();
      _navDist = _hav(_pos!, _pickupLL);
      _navEta = (_navDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _navInstruct = S.of(context).headToPickup;
      _navProgress = 0;
      _slideVal = 0;
      _slid = false;
    });
    _setPickupAnnotation();
    await _drawRoute(_pos!, _pickupLL, 'pickup', _navyRoute);
    // Fit bounds after frame renders with updated map padding
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitBounds(_pos!, _pickupLL);
    });
  }

  Future<void> _arrivePickup() async {
    HapticFeedback.mediumImpact();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(tripId: _tripId!, status: 'arrived');
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _phase = _Phase.arrivedAtPickup;
      _slideVal = 0;
      _slid = false;
    });
    _clearRouteAnnotation();
    _setDropoffAnnotation();
    _animateToPosition(_pickupLL, zoom: 17);
  }

  Future<void> _startTrip() async {
    HapticFeedback.heavyImpact();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(tripId: _tripId!, status: 'in_trip');
      } catch (_) {}
    }
    if (!mounted) return;
    // Show route summary with Start Navigation button
    setState(() {
      _isPickupSummary = false;
      _phase = _Phase.routeSummary;
      _cameraFollowing = false;
      _reFollowTimer?.cancel();
      _navDist = _hav(_pos!, _dropoffLL);
      _navEta = (_navDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _navInstruct = S.of(context).headToDropOff;
      _navProgress = 0;
      _slideVal = 0;
      _slid = false;
    });
    _setDropoffAnnotation();
    await _drawRoute(_pos!, _dropoffLL, 'trip', _navyRoute);
    _nearDropoffNotified = false;
    // Fit bounds after frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fitBounds(_pos!, _dropoffLL);
    });
  }

  /// User pressed "Start Navigation" from the route summary — begin actual nav.
  /// If _isPickupSummary, transition to enRouteToPickup; otherwise inTrip.
  Future<void> _beginNavigation() async {
    HapticFeedback.heavyImpact();

    if (_isPickupSummary) {
      // ── Navigate to pickup ──
      setState(() {
        _isPickupSummary = false;
        _phase = _Phase.enRouteToPickup;
        _cameraFollowing = true;
        _reFollowTimer?.cancel();
        _slideVal = 0;
        _slid = false;
      });
      _setPickupAnnotation();
      _cameraBearing = _heading;
      _animateToPosition(_pos!, zoom: 17.5, bearing: _heading, tilt: 55);
      if (!_isSimulationMode) {
        MapLauncherService.prefersInApp().then((inApp) {
          if (!inApp) {
            MapLauncherService.navigate(
              destLat: _pickupLL.latitude,
              destLng: _pickupLL.longitude,
            );
          }
        });
      }
    } else {
      // ── Navigate to dropoff ──
      setState(() {
        _phase = _Phase.inTrip;
        _cameraFollowing = true;
        _reFollowTimer?.cancel();
        _slideVal = 0;
        _slid = false;
      });
      _setDropoffAnnotation();
      _cameraBearing = _heading;
      _animateToPosition(_pos!, zoom: 17.5, bearing: _heading, tilt: 55);
      if (!_isSimulationMode) {
        MapLauncherService.prefersInApp().then((inApp) {
          if (!inApp) {
            MapLauncherService.navigate(
              destLat: _dropoffLL.latitude,
              destLng: _dropoffLL.longitude,
            );
          }
        });
      }
    }
  }

  void _decline() {
    // Reject all pending offers if any
    for (final offer in _pendingOffers) {
      final oid = offer['offer_id'] as int?;
      if (oid != null && _driverId != null) {
        ApiService.rejectRideOffer(
          offerId: oid,
          driverId: _driverId!,
        ).catchError((_) => <String, dynamic>{});
      }
    }
    if (_currentOfferId != null && _driverId != null) {
      ApiService.rejectRideOffer(
        offerId: _currentOfferId!,
        driverId: _driverId!,
      ).catchError((_) => <String, dynamic>{});
    }
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _pendingOffers = [];
    });
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    _startPolling();
  }

  Future<void> _complete() async {
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    HapticFeedback.heavyImpact();
    _navTimer?.cancel();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(
          tripId: _tripId!,
          status: 'completed',
        );
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _trips++;
      _earnings += _fare;
      _lastTripEarnings = _fare;
      _phase = _Phase.completed;
      _stars = 5;
    });
    _doneCtrl.forward(from: 0);
  }

  void _afterComplete() {
    // Submit the driver's rating for this rider (fire-and-forget)
    if (_tripId != null) {
      ApiService.rateTrip(
        tripId: _tripId!,
        stars: _stars,
      ).catchError((_) => <String, dynamic>{});
      // Clean up RTDB chat node
      ChatService().deleteChat(_tripId.toString());
    }
    _doneCtrl.reverse();
    // INSTANT reset — no delay
    setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _routePts = [];
      _pendingOffers = [];
    });
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    _startPolling();
  }

  void _goOffline() {
    // Block going offline while an offer is visible
    if (_pendingOffers.isNotEmpty || _previewingOffer != null) {
      HapticFeedback.heavyImpact();
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: const Color(0xFF1A1A1A),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
          title: const Text(
            'Active Offer',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
          ),
          content: const Text(
            'You have an active ride offer. Accept or dismiss it before going offline.',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('OK', style: TextStyle(color: Color(0xFFE8C547))),
            ),
          ],
        ),
      );
      return;
    }
    HapticFeedback.mediumImpact();
    _goOfflineBackend();
    Navigator.of(context).pop<Map<String, dynamic>>({
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': false,
    });
  }

  /// Pause availability temporarily — driver stays online but won't receive offers.
  bool _isPaused = false;
  Timer? _pauseTimer;
  
  void _pauseAvailability() {
    HapticFeedback.mediumImpact();
    setState(() => _isPaused = true);
    
    // Stop polling for offers while paused
    _pollT?.cancel();
    
    // Show pause dialog with timer options
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('⏸️ Paused'),
          content: const Text(
            'You are paused and won\'t receive new trip requests.\n\nHow long do you want to pause?',
          ),
          actions: [
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _resumeFromPause();
              },
              child: const Text('Resume Now'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _scheduleResume(minutes: 15);
                _snack('⏸️ Paused for 15 minutes');
              },
              child: const Text('15 min'),
            ),
            TextButton(
              onPressed: () {
                Navigator.pop(ctx);
                _scheduleResume(minutes: 30);
                _snack('⏸️ Paused for 30 minutes');
              },
              child: const Text('30 min'),
            ),
          ],
        );
      },
    );
  }
  
  void _resumeFromPause() {
    setState(() => _isPaused = false);
    _pauseTimer?.cancel();
    _startPolling(); // Resume polling
    _snack('▶️ Back online - receiving trip requests');
  }
  
  void _scheduleResume({required int minutes}) {
    _pauseTimer?.cancel();
    _pauseTimer = Timer(Duration(minutes: minutes), () {
      if (mounted && _isPaused) {
        _resumeFromPause();
      }
    });
  }

  /// Go back to home without going offline — driver stays connected.
  void _goBack() {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop<Map<String, dynamic>>({
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': true,
    });
  }

  Future<void> _cancel() async {
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    _navTimer?.cancel();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(tripId: _tripId!, status: 'canceled');
      } catch (_) {}
    }
    setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _routePts = [];
      _pendingOffers = [];
    });
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
    _startPolling();
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  NAV — Real GPS drives the navigation now.
  //  _simNav is kept as a no-op for backward compat.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _simNav() {
    // No-op: real GPS position stream handles all nav updates
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  DIRECTIONS API
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _drawRoute(LatLng o, LatLng d, String id, Color c) async {
    debugPrint(
      'ðŸ—ºï¸ _drawRoute: ${o.latitude},${o.longitude} â†’ ${d.latitude},${d.longitude}',
    );

    // Try Google Directions API with multiple parameter variants
    final variants = <Map<String, String>>[
      {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
        'alternatives': 'true',
      },
      {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
      },
    ];

    for (final query in variants) {
      try {
        final uri = Uri.https(
          'maps.googleapis.com',
          '/maps/api/directions/json',
          query,
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        debugPrint('ðŸ—ºï¸ Directions API status: ${res.statusCode}');
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          debugPrint(
            'ðŸ—ºï¸ Directions API response status: ${data['status']}',
          );
          if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
            final route = data['routes'][0];
            final pts = _decodePoly(
              route['overview_polyline']['points'] as String,
            );
            final leg = route['legs'][0];
            final steps = leg['steps'] as List;
            String instr = mounted ? S.of(context).headToDestination : '';
            if (steps.isNotEmpty) {
              instr = (steps[0]['html_instructions']?.toString() ?? '')
                  .replaceAll(RegExp(r'<[^>]*>'), '');
            }

            // Parse turn-by-turn NavRoute for live navigation
            final navRoute = NavigationService.fromDirectionsResponse(data);
            if (navRoute != null) {
              _currentNavRoute = navRoute;
              _navService.startNavigation(navRoute);
              _rerouteCount = 0;
              debugPrint('Nav: ${navRoute.steps.length} steps parsed');
            }

            debugPrint('ðŸ—ºï¸ Google route OK: ${pts.length} points');
            setState(() {
              _routePts = pts;
              _navDist = (leg['distance']['value'] as int) / 1609.34;
              _navEta = ((leg['duration']['value'] as int) / 60).ceil();
              _navInstruct = instr;
            });
            _setRouteAnnotation(pts, c);
            return;
          }
        }
      } catch (e) {
        debugPrint('ðŸ—ºï¸ Google Directions attempt failed: $e');
      }
    }

    // Fallback: OSRM (free, no API key needed)
    debugPrint('ðŸ—ºï¸ Trying OSRM fallback...');
    try {
      final path =
          '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'steps': 'true',
        'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic> &&
          data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final route = routes[0];
          final pts = _decodePoly(route['geometry'] as String);
          final distM = (route['distance'] as num?)?.toInt() ?? 0;
          final durS = (route['duration'] as num?)?.toInt() ?? 0;
          String instr = mounted ? S.of(context).headToDestination : '';
          final legs = route['legs'] as List?;
          if (legs != null && legs.isNotEmpty) {
            final rawSteps = legs[0]['steps'] as List? ?? [];
            if (rawSteps.isNotEmpty) {
              instr = rawSteps[0]['name']?.toString().isNotEmpty == true
                  ? 'Head on ${rawSteps[0]['name']}'
                  : instr;
            }
            // Build NavRoute from OSRM steps for turn-by-turn instructions
            final navSteps = <NavStep>[];
            for (int i = 0; i < rawSteps.length - 1; i++) {
              final step = rawSteps[i] as Map<String, dynamic>;
              final nextStep = rawSteps[i + 1] as Map<String, dynamic>;
              final mv = step['maneuver'] as Map<String, dynamic>? ?? {};
              final type = mv['type']?.toString() ?? 'straight';
              final mod = mv['modifier']?.toString() ?? '';
              String maneuver;
              if (type == 'turn') {
                if (mod == 'left') {
                  maneuver = 'turn-left';
                } else if (mod == 'right') {
                  maneuver = 'turn-right';
                } else if (mod == 'slight left') {
                  maneuver = 'turn-slight-left';
                } else if (mod == 'slight right') {
                  maneuver = 'turn-slight-right';
                } else if (mod == 'sharp left') {
                  maneuver = 'turn-sharp-left';
                } else if (mod == 'sharp right') {
                  maneuver = 'turn-sharp-right';
                } else {
                  maneuver = 'straight';
                }
              } else if (type == 'merge') {
                maneuver = 'merge';
              } else if (type == 'fork') {
                maneuver = mod.contains('left') ? 'fork-left' : 'fork-right';
              } else if (type == 'ramp') {
                maneuver = mod.contains('left') ? 'ramp-left' : 'ramp-right';
              } else {
                maneuver = 'straight';
              }
              final locArr = mv['location'] as List? ?? [0, 0];
              final stepLoc = LatLng(
                (locArr[1] as num).toDouble(),
                (locArr[0] as num).toDouble(),
              );
              final nMv = nextStep['maneuver'] as Map<String, dynamic>? ?? {};
              final nArr = nMv['location'] as List? ?? [0, 0];
              final nextLoc = LatLng(
                (nArr[1] as num).toDouble(),
                (nArr[0] as num).toDouble(),
              );
              final sName = step['name']?.toString() ?? '';
              final sDist = (step['distance'] as num?)?.toDouble() ?? 0;
              final sDur = (step['duration'] as num?)?.toDouble() ?? 0;
              String instrText;
              if (type == 'depart') {
                instrText = sName.isNotEmpty ? 'Head on $sName' : 'Depart';
              } else if (type == 'arrive') {
                instrText = 'Arrive at destination';
              } else if (type == 'turn') {
                instrText = 'Turn $mod${sName.isNotEmpty ? ' on $sName' : ''}';
              } else if (type == 'merge') {
                instrText = 'Merge${sName.isNotEmpty ? ' onto $sName' : ''}';
              } else if (type == 'fork') {
                instrText = 'Keep $mod at fork${sName.isNotEmpty ? ' onto $sName' : ''}';
              } else if (type == 'ramp') {
                instrText = 'Take ramp${sName.isNotEmpty ? ' to $sName' : ''}';
              } else {
                instrText = sName.isNotEmpty ? 'Continue on $sName' : 'Continue';
              }
              List<LatLng> stepPoly = [stepLoc, nextLoc];
              final stepGeo = step['geometry'];
              if (stepGeo is String && stepGeo.isNotEmpty) {
                final dec = _decodePoly(stepGeo);
                if (dec.isNotEmpty) stepPoly = dec;
              }
              navSteps.add(NavStep(
                instruction: instrText,
                maneuver: maneuver,
                distanceMeters: sDist,
                durationSeconds: sDur.toInt(),
                streetName: sName,
                startLocation: stepLoc,
                endLocation: nextLoc,
                polyline: stepPoly,
              ));
            }
            if (navSteps.isNotEmpty) {
              final navRoute = NavRoute(
                overviewPolyline: pts,
                steps: navSteps,
                totalDistanceMeters: distM.toDouble(),
                totalDurationSeconds: durS,
                startAddress: '',
                endAddress: '',
              );
              _currentNavRoute = navRoute;
              _navService.startNavigation(navRoute);
              _rerouteCount = 0;
              instr = navSteps.first.instruction;
              debugPrint('OSRM Nav: ${navSteps.length} steps parsed');
            }
          }
          debugPrint('ðŸ—ºï¸ OSRM route OK: ${pts.length} points');
          setState(() {
            _routePts = pts;
            _navDist = distM / 1609.34;
            _navEta = (durS / 60).ceil().clamp(1, 999);
            _navInstruct = instr;
          });
          _setRouteAnnotation(pts, c);
          return;
        }
      }
    } catch (e) {
      debugPrint('ðŸ—ºï¸ OSRM fallback failed: $e');
    }

    // Last resort: straight line
    debugPrint('ðŸ—ºï¸ Using straight-line fallback');
    _fallbackRoute(o, d, id, c);
  }

  List<LatLng> _decodePoly(String enc) {
    final pts = <LatLng>[];
    int i = 0, lat = 0, lng = 0;
    while (i < enc.length) {
      int s = 0, r = 0, b;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0;
      r = 0;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return pts;
  }

  void _fallbackRoute(LatLng a, LatLng b, String id, Color c) {
    final pts = List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );
    });
    setState(() {
      _routePts = pts;
    });
    _setRouteAnnotation(pts, c);
  }

  // ═══════════════════════════════════════════════════════════
  //  MAPBOX ANNOTATION HELPERS
  // ═══════════════════════════════════════════════════════════

  Future<void> _setRouteAnnotation(List<LatLng> pts, Color c) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || pts.length < 2) return;
    if (_routeAnnot != null) {
      try { await polyMgr.delete(_routeAnnot!); } catch (_) {}
      _routeAnnot = null;
    }
    final coords = pts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: c.toARGB32(),
      lineWidth: 5.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
  }

  Future<void> _clearRouteAnnotation() async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null) return;
    for (final a in [_routeAnnot, _previewPickupAnnot, _previewDropoffAnnot]) {
      if (a != null) try { await polyMgr.delete(a); } catch (_) {}
    }
    _routeAnnot = null;
    _previewPickupAnnot = null;
    _previewDropoffAnnot = null;
  }

  Future<void> _setPickupAnnotation() async {
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;
    await _clearPickupDropoffAnnotations();
    final bytes = await _buildCirclePin(const Color(0xFF4CAF50), 22);
    _pickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(_pickupLL.longitude, _pickupLL.latitude)),
      image: bytes,
      iconSize: 1.0,
    ));
  }

  Future<void> _setDropoffAnnotation() async {
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;
    await _clearPickupDropoffAnnotations();
    final bytes = await _buildRingPin(Colors.white, 22);
    _dropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(_dropoffLL.longitude, _dropoffLL.latitude)),
      image: bytes,
      iconSize: 1.0,
    ));
  }

  Future<void> _setPickupDropoffAnnotations() async {
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;
    await _clearPickupDropoffAnnotations();
    final pickupBytes  = await _buildCirclePin(const Color(0xFF4CAF50), 22);
    final dropoffBytes = await _buildRingPin(Colors.white, 22);
    _pickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(_pickupLL.longitude, _pickupLL.latitude)),
      image: pickupBytes,
      iconSize: 1.0,
    ));
    _dropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(_dropoffLL.longitude, _dropoffLL.latitude)),
      image: dropoffBytes,
      iconSize: 1.0,
    ));
  }

  Future<void> _clearPickupDropoffAnnotations() async {
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;
    for (final annot in [_pickupAnnot, _dropoffAnnot, _prevDriverAnnot, _prevPickupAnnot, _prevDropoffAnnot]) {
      if (annot != null) try { await pointMgr.delete(annot); } catch (_) {}
    }
    _pickupAnnot = null;
    _dropoffAnnot = null;
    _prevDriverAnnot = null;
    _prevPickupAnnot = null;
    _prevDropoffAnnot = null;
  }

  Future<void> _clearAllAnnotations() async {
    await _clearRouteAnnotation();
    await _clearPickupDropoffAnnotations();
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;
    for (final annot in [_carAnnot, _goldDotAnnot]) {
      if (annot != null) try { await pointMgr.delete(annot); } catch (_) {}
    }
    _carAnnot = null;
    _goldDotAnnot = null;
    _dotPopDone = false;
    _dotPopScale = 0.0;
  }

  static String _mapRideType(String raw) {
    final lower = raw.toLowerCase().trim();
    if (lower.contains('premium')) return 'Premium';
    if (lower.contains('sedan')) return 'Sedan';
    if (lower.contains('comfort')) return 'Comfort';
    if (lower == 'cruisex' || lower == 'cruise_x' || lower == 'cruise') return 'Comfort';
    // Fallback: capitalize first letter
    if (raw.isEmpty) return 'Comfort';
    return raw[0].toUpperCase() + raw.substring(1);
  }

  double _hav(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  /// Dynamic bottom padding for the GoogleMap based on active overlays
  double get _mapBottomPadding {
    final screenH = MediaQuery.of(context).size.height;
    if (_previewingOffer != null) return screenH * 0.42;
    if (_phase == _Phase.searching && _pendingOffers.isNotEmpty) return screenH * 0.42;
    if (_phase == _Phase.enRouteToPickup) return 270;
    if (_phase == _Phase.arrivedAtPickup) return 290;
    if (_phase == _Phase.routeSummary) return 330;
    if (_phase == _Phase.inTrip) return 270;
    return 200;
  }

  void _fitBounds(LatLng a, LatLng b) {
    _fitBoundsMulti([a, b]);
  }

  void _fitBoundsMulti(List<LatLng> points) {
    if (points.isEmpty || _map == null) return;
    final coords = points
        .map((p) => mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();
    _map!.cameraForCoordinatesPadding(
      coords,
      mapbox.CameraOptions(),
      mapbox.MbxEdgeInsets(top: 80, left: 60, bottom: _mapBottomPadding + 60, right: 60),
      null, null,
    ).then((cam) {
      if (mounted) _map?.flyTo(cam, mapbox.MapAnimationOptions(duration: 700));
    });
  }

  /// Auto-trigger cinematic route preview when first offer arrives.
  /// Uses the same logic as card tap but runs automatically.
  void _autoTriggerRoutePreview(Map<String, dynamic> offer) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _pendingOffers.isEmpty) return;
      _onOfferCardTap(offer);
    });
  }

  // ── Cinematic offer card tap → full animation sequence ──
  // Everything is pre-loaded: route, pins, place type, bounds.
  // Zero network calls on tap.
  Future<void> _onOfferCardTap(Map<String, dynamic> offer) async {
    if (_isCardAnimating) return;
    final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();
    _isCardAnimating = true;

    final pickupLat  = (offer['pickup_lat']  as num?)?.toDouble() ?? 0;
    final pickupLng  = (offer['pickup_lng']  as num?)?.toDouble() ?? 0;
    final dropoffLat = (offer['dropoff_lat'] as num?)?.toDouble() ?? 0;
    final dropoffLng = (offer['dropoff_lng'] as num?)?.toDouble() ?? 0;
    final pickupLL  = LatLng(pickupLat,  pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);

    setState(() {
      _previewingOffer = offer;
      _animatingOfferId = oid;
      _tappedCardIds.add(oid);
    });
    await _clearAllAnnotations();

    // Load from cache (pre-fetched on offer arrival)
    final cached = _routeCache[oid];
    if (cached != null) {
      _fullSegOne = cached.segOne;
      _fullSegTwo = cached.segTwo;
    } else {
      // Fallback: fetch now (should be rare)
      final routeFutures = await Future.wait([
        _fetchRoutePoints(_pos!, pickupLL),
        _fetchRoutePoints(pickupLL, dropoffLL),
      ]);
      _fullSegOne = routeFutures[0];
      _fullSegTwo = routeFutures[1];
    }
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 1: Smooth zoom out to show full route (instant) ──
    _fitBoundsMulti([_pos!, pickupLL, dropoffLL]);

    // ── PHASE 3: Pins pop in (after one frame for camera to settle) ──
    await Future.delayed(const Duration(milliseconds: 50));
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // Place pins using pre-built images (or build now as fallback)
    final dropoffAddr = (offer['dropoff_address'] ?? '') as String;
    final placeType = cached?.dropoffPlaceType ?? _detectPlaceType(dropoffAddr);
    Uint8List? driverPinImg = cached?.driverPin;
    Uint8List? pickupPinImg = cached?.pickupPin;
    Uint8List? dropoffPinImg = cached?.dropoffPin;
    if (driverPinImg == null || pickupPinImg == null || dropoffPinImg == null) {
      final pinResults = await Future.wait([
        renderGoldPinBytes(icon: GoldPinIcon.person, isPickup: true),          // driver position
        renderGoldPinBytes(icon: GoldPinIcon.person, isPickup: true),          // pickup
        renderGoldPinBytes(icon: _goldPinIconFor(placeType), isPickup: false), // dropoff
      ]);
      driverPinImg ??= pinResults[0];
      pickupPinImg ??= pinResults[1];
      dropoffPinImg ??= pinResults[2];
    }

    final pointMgr = _pointAnnotMgr;
    if (pointMgr != null && mounted) {
      // Driver pin — person icon showing driver's current position
      _prevDriverAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
        image: driverPinImg, iconSize: 0.01, iconAnchor: mapbox.IconAnchor.BOTTOM,
      ));
      // Pickup pin — person icon
      _prevPickupAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(pickupLL.longitude, pickupLL.latitude)),
        image: pickupPinImg, iconSize: 0.01, iconAnchor: mapbox.IconAnchor.BOTTOM,
      ));
      // Dropoff pin — smart icon (house/store/airplane)
      _prevDropoffAnnot = await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(dropoffLL.longitude, dropoffLL.latitude)),
        image: dropoffPinImg, iconSize: 0.01, iconAnchor: mapbox.IconAnchor.BOTTOM,
      ));

      // Animate pin pop: scale 0.01 → 1.2 → 0.9 → 1.0 over 600ms
      await _animatePinPop();
    }

    // ── PHASE 4 (t=700ms): Gold gloss route draws ──
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }
    final fullRoute = [..._fullSegOne, ..._fullSegTwo];
    await _drawGoldGlossRoute(fullRoute);
    if (!mounted || _previewingOffer == null) { _isCardAnimating = false; return; }

    // ── PHASE 5: Route shown ──

    if (mounted && _previewingOffer != null) {
      setState(() => _offerRouteShown = true);
    }

    // Re-fit camera for final framing (next frame)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _previewingOffer != null) {
        _fitBoundsMulti([_pos!, pickupLL, dropoffLL]);
      }
    });
    _isCardAnimating = false;
  }

  /// Animate all preview pins from tiny → overshoot → settle (spring feel)
  Future<void> _animatePinPop() async {
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null) return;
    const totalMs = 600;
    final stopwatch = Stopwatch()..start();
    final completer = Completer<void>();

    // Spring-like TweenSequence: 0→1.2→0.9→1.0
    double springScale(double t) {
      if (t < 0.6) {
        // 0→1.2 with easeOutCubic
        final p = (t / 0.6).clamp(0.0, 1.0);
        return Curves.easeOutCubic.transform(p) * 1.2;
      } else if (t < 0.8) {
        // 1.2→0.9
        final p = ((t - 0.6) / 0.2).clamp(0.0, 1.0);
        return 1.2 - 0.3 * Curves.easeInOut.transform(p);
      } else {
        // 0.9→1.0
        final p = ((t - 0.8) / 0.2).clamp(0.0, 1.0);
        return 0.9 + 0.1 * Curves.elasticOut.transform(p);
      }
    }

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) async {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final scale = springScale(progress);

      for (final annot in [_prevDriverAnnot, _prevPickupAnnot, _prevDropoffAnnot]) {
        if (annot != null) {
          annot.iconSize = scale;
          try { await pointMgr.update(annot); } catch (_) {}
        }
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  /// Draw a single gold route line with progressive 60fps draw over 1 second.
  Future<void> _drawGoldGlossRoute(List<LatLng> points) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) return;

    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    const totalMs = 1000;

    mapbox.PolylineAnnotation? mainLine;
    int lastCount = 0;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) async {
      if (!mounted || _previewingOffer == null) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }

      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final eased = Curves.easeInOutSine.transform(progress);
      final count = (eased * points.length).round().clamp(2, points.length);

      if (count != lastCount) {
        lastCount = count;
        final subset = points.sublist(0, count);
        final coords = subset.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final geo = mapbox.LineString(coordinates: coords);

        if (mainLine == null) {
          mainLine = await polyMgr.create(mapbox.PolylineAnnotationOptions(
            geometry: geo,
            lineColor: const Color(0xFFFFD700).toARGB32(),
            lineWidth: 5.0,
            lineJoin: mapbox.LineJoin.ROUND,
          ));
        } else {
          mainLine!.geometry = geo;
          try { await polyMgr.update(mainLine!); } catch (_) {}
        }
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final fullGeo = mapbox.LineString(coordinates: fullCoords);
        if (mainLine != null) {
          mainLine!.geometry = fullGeo;
          try { await polyMgr.update(mainLine!); } catch (_) {}
        }
        // Store for later cleanup
        _previewPickupAnnot = mainLine;
        if (!completer.isCompleted) completer.complete();
      }
    });

    _routeDrawTicker!.start();
    return completer.future;
  }

  // Keep _previewOfferRoute for backward compat (delegates to cinematic tap)
  Future<void> _previewOfferRoute(Map<String, dynamic> offer) async {
    return _onOfferCardTap(offer);
  }

  /// Fetch route points from Google Directions → OSRM → straight line fallback
  Future<List<LatLng>> _fetchRoutePoints(LatLng o, LatLng d) async {
    List<LatLng>? pts;
    // Google Directions API
    try {
      final uri = Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
          pts = _decodePoly(data['routes'][0]['overview_polyline']['points'] as String);
        }
      }
    } catch (_) {}
    // OSRM fallback
    if (pts == null) {
      try {
        final path = '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
        final uri = Uri.https('router.project-osrm.org', path, {
          'overview': 'full', 'geometries': 'polyline',
        });
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        final data = jsonDecode(res.body);
        if (data is Map<String, dynamic> && data['code']?.toString().toUpperCase() == 'OK') {
          final routes = data['routes'] as List?;
          if (routes != null && routes.isNotEmpty) {
            pts = _decodePoly(routes[0]['geometry'] as String);
          }
        }
      } catch (_) {}
    }
    // Mapbox Directions API fallback
    if (pts == null) {
      try {
        final mbxUrl = Uri.parse(
          'https://api.mapbox.com/directions/v5/mapbox/driving/'
          '${o.longitude},${o.latitude};${d.longitude},${d.latitude}'
          '?geometries=geojson&overview=full&steps=false'
          '&access_token=${MapboxConfig.accessToken}',
        );
        final mbxRes = await http.get(mbxUrl).timeout(const Duration(seconds: 8));
        if (mbxRes.statusCode == 200) {
          final mbxData = jsonDecode(mbxRes.body);
          final mbxRoutes = mbxData['routes'] as List?;
          if (mbxRoutes != null && mbxRoutes.isNotEmpty) {
            final coords = mbxRoutes[0]['geometry']?['coordinates'] as List?;
            if (coords != null && coords.isNotEmpty) {
              pts = coords
                  .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                  .toList();
            }
          }
        }
      } catch (_) {}
    }
    // Straight line fallback
    pts ??= List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        o.latitude  + (d.latitude  - o.latitude)  * t,
        o.longitude + (d.longitude - o.longitude) * t,
      );
    });
    if (pts.isNotEmpty) { pts[0] = o; pts[pts.length - 1] = d; }
    return pts;
  }


  /// Solid filled circle pin (e.g. driver dot, pickup dot)
  Future<Uint8List?> _buildCirclePin(Color fill, double radius) async {
    final s = (radius * 2 + 8).roundToDouble();
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, Rect.fromLTWH(0, 0, s, s));
    final cx  = s / 2;
    // Shadow
    c.drawCircle(Offset(cx, cx + 2), radius,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    // White border
    c.drawCircle(Offset(cx, cx), radius, Paint()..color = Colors.white);
    // Fill
    c.drawCircle(Offset(cx, cx), radius - 3, Paint()..color = fill);
    final img   = await rec.endRecording().toImage(s.toInt(), s.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  /// Ring-only pin (e.g. dropoff marker — white ring, dark center)
  Future<Uint8List?> _buildRingPin(Color ringColor, double radius) async {
    final s = (radius * 2 + 8).roundToDouble();
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, Rect.fromLTWH(0, 0, s, s));
    final cx  = s / 2;
    // Shadow
    c.drawCircle(Offset(cx, cx + 2), radius,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5));
    // White ring
    c.drawCircle(Offset(cx, cx), radius, Paint()..color = ringColor);
    // Dark inner
    c.drawCircle(Offset(cx, cx), radius - 5,
        Paint()..color = const Color(0xFF0A0C12));
    // White center dot
    c.drawCircle(Offset(cx, cx), 4, Paint()..color = ringColor);
    final img   = await rec.endRecording().toImage(s.toInt(), s.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  void _closePreview() {
    _routePulseCtrl?.stop();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;
    setState(() {
      _previewingOffer = null;
      _offerRouteShown = false;
      _fullSegOne = [];
      _fullSegTwo = [];
    });
    _clearAllAnnotations();
    if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0);
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          s,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BUILD
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bot = MediaQuery.of(context).padding.bottom;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Adapt status bar icons — always light (white) during navigation so they show over dark teal header
    final isNav = _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness:
            isNav ? Brightness.light : (isDark ? Brightness.light : Brightness.dark),
      ),
    );

    // Live-switch map style
    _applyMapStyle(isDark);

    // Theme-aware colors
    final bg = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF2F2F7);
    final surface = isDark ? const Color(0xFF111111) : Colors.white;
    final card = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final fabBg = isDark
        ? const Color(0xFF1A1A1A).withValues(alpha: 0.75)
        : Colors.white.withValues(alpha: 0.85);
    final fabBorder = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final fabIcon = isDark
        ? Colors.white.withValues(alpha: 0.8)
        : Colors.black.withValues(alpha: 0.65);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final textMuted = isDark
        ? Colors.white.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.35);
    final borderC = fabBorder;
    final overlayBg = isDark
        ? Colors.black.withValues(alpha: 0.75)
        : Colors.black.withValues(alpha: 0.45);
    final shadowC = isDark
        ? Colors.black.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.08);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        backgroundColor: bg,
        body: Stack(
          children: [
            // Offline connectivity banner
            const Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(child: OfflineBanner()),
            ),

            // Offline connectivity banner
            const Positioned(
              top: 0, left: 0, right: 0,
              child: SafeArea(child: OfflineBanner()),
            ),

            // â”€â”€ Map â”€â”€
            _mapW(isDark),

            // â”€â”€ Nav header (during navigation phases) â”€â”€
            if (isNav)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _navHeader(),
              ),

            // â”€â”€ Top-left: Home button (hidden during nav — nav header has its own back) â”€â”€
            if (!isNav)
              Positioned(
                top: top + 10,
                left: 16,
                child: _fab(
                  Icons.arrow_back_ios_new_rounded,
                  48,
                  fabBg,
                  fabBorder,
                  fabIcon,
                  _goBack,
                ),
              ),

            // â”€â”€ Top-center: Earnings pill + TODAY (hidden during nav) â”€â”€
            if (!isNav)
              Positioned(
                top: top + 10,
                left: 0,
                right: 0,
                child: Column(
                  children: [
                    Center(child: _earningsPill(isDark)),
                    // Simulation mode indicator badge
                    if (kDebugMode && _isSimulationMode)
                      Container(
                        margin: const EdgeInsets.only(top: 8),
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: const Color(0xFFE8C547).withValues(alpha: 0.9),
                          borderRadius: BorderRadius.circular(20),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.videogame_asset_rounded,
                              color: Colors.black,
                              size: 14,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              'PRACTICE MODE',
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),

            // â”€â”€ Side floating buttons (only when searching with no offers) â”€â”€
            if (_phase == _Phase.searching && _pendingOffers.isEmpty) ...[
              Positioned(
                bottom: 54 + bot + 60,
                left: 16,
                child: Column(
                  children: [
                    _fab(
                      Icons.shield_outlined,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        slideFromRightRoute(const SafetyScreen()),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                bottom: 54 + bot + 60,
                right: 16,
                child: Column(
                  children: [
                    _fab(
                      Icons.message_outlined,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        slideFromRightRoute(const DriverInboxScreen()),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _fab(
                      Icons.campaign_rounded,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        slideFromRightRoute(const DriverPromosScreen()),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _fab(
                      Icons.bar_chart_rounded,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        slideFromRightRoute(const DriverAnalyticsScreen()),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // â”€â”€ Re-center button during navigation (inTrip / routeSummary) â”€â”€
            // -- Re-center FAB: appears when user pans away during navigation --
            if (!_cameraFollowing &&
                (_phase == _Phase.enRouteToPickup ||
                    _phase == _Phase.inTrip ||
                    _phase == _Phase.routeSummary))
              Positioned(
                bottom: _mapBottomPadding + 12,
                right: 16,
                child: _fab(
                  Icons.navigation_rounded,
                  48,
                  fabBg,
                  fabBorder,
                  const Color(0xFF4285F4),
                  () {
                    HapticFeedback.mediumImpact();
                    _recenterCamera();
                  },
                ),
              ),

            // â”€â”€ Completed overlay â”€â”€
            if (_phase == _Phase.completed)
              Positioned.fill(
                child: _completedOverlay(
                  isDark,
                  overlayBg,
                  card,
                  textPrimary,
                  borderC,
                  shadowC,
                ),
              ),

            // â”€â”€ Stacked Ride Offer Cards (Spark-style) â”€â”€
            if (_phase == _Phase.searching &&
                _pendingOffers.isNotEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _rideOfferCards(
                  isDark,
                  card,
                  textPrimary,
                  textMuted,
                  borderC,
                  shadowC,
                ),
              ),

            // Accepted trip bottom card (replaces offer cards after accept)
            if (_showAcceptedBottomCard)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: AnimatedOpacity(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeInOut,
                  opacity: _showAcceptedBottomCard ? 1.0 : 0.0,
                  child: SafeArea(
                    top: false,
                    child: Container(
                    margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                    clipBehavior: Clip.antiAlias,
                    decoration: BoxDecoration(
                      color: const Color(0xFF0A0A0A),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: const Color(0xFFD4AF37).withValues(alpha: 0.30),
                        width: 1.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFD4AF37).withValues(alpha: 0.12),
                          blurRadius: 24,
                          spreadRadius: 2,
                        ),
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.50),
                          blurRadius: 24,
                          spreadRadius: -2,
                          offset: const Offset(0, 10),
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
                    child: Row(
                      children: [
                        TweenAnimationBuilder<double>(
                          tween: Tween(begin: 0.0, end: 1.0),
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.elasticOut,
                          builder: (_, scale, child) =>
                              Transform.scale(scale: scale, child: child),
                          child: Container(
                            width: 52,
                            height: 52,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: const Color(0xFFD4AF37).withValues(alpha: 0.15),
                              border: Border.all(color: const Color(0xFFD4AF37), width: 2),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFD4AF37).withValues(alpha: 0.3),
                                  blurRadius: 20,
                                  spreadRadius: 2,
                                ),
                              ],
                            ),
                            child: const Icon(Icons.check_rounded, color: Color(0xFFD4AF37), size: 28),
                          ),
                        ),
                        const SizedBox(width: 16),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'Viaje Aceptado',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                _acceptedPickupAddr,
                                style: const TextStyle(color: Colors.white54, fontSize: 13),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                        _buildAcceptLoadingDots(),
                      ],
                    ),
                  ),
                  ),
                ),
              ),

            // â”€â”€ X button to close preview (top-right) â”€â”€
            if (_previewingOffer != null)
              Positioned(
                top: top + 10,
                right: 16,
                child: _fab(
                  Icons.close_rounded,
                  48,
                  fabBg,
                  fabBorder,
                  fabIcon,
                  _closePreview,
                ),
              ),

            // â”€â”€ Bottom: Phase-specific panel â”€â”€
            if (_phase == _Phase.searching)
              Positioned.fill(
                child: AnimatedSlide(
                  offset: _pendingOffers.isNotEmpty ? const Offset(0, 1) : Offset.zero,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: AnimatedOpacity(
                    opacity: _pendingOffers.isNotEmpty ? 0.0 : 1.0,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      ignoring: _pendingOffers.isNotEmpty,
                      child: _draggablePanel(
                        isDark,
                        surface,
                        textMuted,
                        borderC,
                        textPrimary,
                        shadowC,
                      ),
                    ),
                  ),
                ),
              )
            else if (_phase != _Phase.searching || _pendingOffers.isEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _bottomArea(
                  isDark,
                  bg,
                  surface,
                  textPrimary,
                  textMuted,
                  borderC,
                  shadowC,
                ),
              ),
          ],
        ),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  MAP
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _applyMapStyle(bool isDark) {
    if (isDark == _lastStyleDark) return;
    _lastStyleDark = isDark;
    setState(() {}); // rebuild map with new style
  }

  /// Called when a camera movement is initiated by user gesture.
  /// Pauses auto-follow so the driver can freely explore the map.
  void _onCameraMoveStarted() {
    // Only pause follow during active navigation phases
    final isNav =
        _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;
    if (!isNav) return;
    if (!_cameraFollowing) return; // already paused
    setState(() => _cameraFollowing = false);
    _reFollowTimer?.cancel();
    // Auto-resume after 8 seconds of inactivity
    _reFollowTimer = Timer(const Duration(seconds: 8), _recenterCamera);
  }

  /// Resume camera follow mode and snap back to driver position.
  void _recenterCamera() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    setState(() => _cameraFollowing = true);
    final bearing = _smoothedBearing;
    _cameraBearing = bearing; // sync for sprite selection
    if (_pos != null) _animateToPosition(_pos!, zoom: 17.5, bearing: bearing, tilt: 55);
  }

  Widget _mapW(bool isDark) {
    if (_pos == null) {
      return Container(
        color: const Color(0xFF07080D),
        child: const Center(
          child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
        ),
      );
    }
    return RepaintBoundary(
      child: mapbox.MapWidget(
        key: _mapKey,
        styleUri: MapboxConfig.styleDark,
        cameraOptions: mapbox.CameraOptions(
          center: mapbox.Point(coordinates: mapbox.Position(_pos!.longitude, _pos!.latitude)),
          zoom: 15.5,
          bearing: 0,
          pitch: 0,
        ),
        onMapCreated: (ctrl) async {
          _map = ctrl;
          _lastStyleDark = isDark;
          // Polyline manager with no 'below' constraint — avoids silent failure
          // when the layer name doesn't exist in the style.
          _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
            below: "road-label",
          );
          _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
          // Always fly to real GPS — never the Miami default
          try {
            final gps = await Geolocator.getCurrentPosition(
              locationSettings: const LocationSettings(
                accuracy: LocationAccuracy.high,
                timeLimit: Duration(seconds: 6),
              ),
            );
            if (mounted) {
              setState(() => _pos = LatLng(gps.latitude, gps.longitude));
            }
          } catch (_) {}
          if (_pos != null) _animateToPosition(_pos!, zoom: 15.5, bearing: _heading, tilt: 0);
          _updateDriverAnnotation();
          // Re-draw route if map initialised after _drawRoute already ran
          if (_routePts.length > 1) {
            _setRouteAnnotation(_routePts, _navyRoute);
            await Future.delayed(const Duration(milliseconds: 200));
            final dest = (_phase == _Phase.enRouteToPickup || _phase == _Phase.routeSummary)
                ? _pickupLL
                : _dropoffLL;
            if (_pos != null) _fitBounds(_pos!, dest);
          }
        },
        onStyleLoadedListener: (_) async {
          if (_map != null) await MapTheme.applyNavyGold(_map!);
        },
        onScrollListener: (_) {
          _onCameraMoveStarted();
        },
      ),
    );
  }


  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  EARNINGS PILL (top center — Uber style)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _earningsPill(bool isDark) {
    final pillBg = isDark
        ? const Color(0xFF1A1A1A).withValues(alpha: 0.85)
        : Colors.white.withValues(alpha: 0.9);
    final pillBorder = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final pillText = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final pillSub = isDark ? Colors.white38 : Colors.black38;
    final dotActive = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final dotInactive = isDark
        ? Colors.white.withValues(alpha: 0.2)
        : Colors.black.withValues(alpha: 0.15);

    final amounts = [
      '\$${_weeklyEarnings.toStringAsFixed(2)}',
      '\$${_earnings.toStringAsFixed(2)}',
      '\$${_lastTripEarnings.toStringAsFixed(2)}',
    ];
    final labels = [
      S.of(context).thisWeek.toUpperCase(),
      S.of(context).today.toUpperCase(),
      S.of(context).lastTripLabel.toUpperCase(),
    ];

    Widget pillPage(String amount, String label) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: pillBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  amount,
                  style: TextStyle(
                    color: pillText,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: pillSub,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(width: 6),
                    for (int i = 0; i < 3; i++) ...[
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == _earningsPage ? dotActive : dotInactive,
                        ),
                      ),
                      if (i < 2) const SizedBox(width: 3),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return GestureDetector(
      onHorizontalDragEnd: (details) {
        if (details.primaryVelocity == null) return;
        if (details.primaryVelocity! < -200 && _earningsPage < 2) {
          setState(() => _earningsPage++);
        } else if (details.primaryVelocity! > 200 && _earningsPage > 0) {
          setState(() => _earningsPage--);
        }
      },
      child: SizedBox(
        width: 160,
        height: 52,
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 400),
          reverseDuration: const Duration(milliseconds: 300),
          switchInCurve: Curves.easeInOut,
          switchOutCurve: Curves.easeInOut,
          transitionBuilder: (child, animation) => FadeTransition(
            opacity: animation,
            child: child,
          ),
          child: Center(
            key: ValueKey<int>(_earningsPage),
            child: pillPage(
              amounts[_earningsPage],
              labels[_earningsPage],
            ),
          ),
        ),
      ),
    );
  }

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//  NAV HEADER (Google Maps–style full-width turn bar)
// ═══════════════════════════════════════════════════════════════════════════════
Widget _navHeader() {
  final toPickup = _phase == _Phase.enRouteToPickup;
  final maneuverStr = _navState?.currentManeuver ?? 'straight';
  final maneuverInfo = NavigationService.getManeuverIcon(maneuverStr);
  final distToTurn = _navState?.distanceToTurnText ?? '';
  final isOffRoute = _navState?.isOffRoute ?? false;
  final topPad = MediaQuery.of(context).padding.top;

  // Google Maps–style dark teal (matches Google nav header closely)
  const Color navBg = Color(0xFF1C3F5E);
  const Color navBgSub = Color(0xFF162F46);
  final Color bg = isOffRoute ? const Color(0xFFC0392B) : navBg;
  final Color bgSub = isOffRoute ? const Color(0xFFA93226) : navBgSub;

  return Material(
    color: Colors.transparent,
    child: Container(
      color: bg,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Status bar safe area — same dark colour
          SizedBox(height: topPad),
          // ── Main turn instruction row ──────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Turn arrow box
                Container(
                  width: 58,
                  height: 58,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    maneuverInfo.icon,
                    color: Colors.white,
                    size: 36,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (!isOffRoute && distToTurn.isNotEmpty)
                        Text(
                          distToTurn,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w900,
                            height: 1.0,
                          ),
                        ),
                      if (isOffRoute)
                        Text(
                          S.of(context).rerouting,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                            height: 1.1,
                          ),
                        ),
                      const SizedBox(height: 2),
                      Text(
                        isOffRoute ? S.of(context).offRoute : _navInstruct,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.9),
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Cancel button (pickup only)
                if (toPickup)
                  GestureDetector(
                    onTap: _cancel,
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        color: Colors.white,
                        size: 18,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // ── "Then" next-maneuver sub-row ───────────────────────
          if (_navState?.nextStep != null && !isOffRoute)
            Container(
              color: bgSub,
              padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
              child: Row(
                children: [
                  Text(
                    S.of(context).thenLabel,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.8,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    NavigationService.getManeuverIcon(
                      _navState!.nextStep!.maneuver,
                    ).icon,
                    color: Colors.white.withValues(alpha: 0.75),
                    size: 17,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _navState!.nextStep!.instruction,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  // Progress + ETA compact row
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$_navEta min  ·  ${(_navDist * 0.621371).toStringAsFixed(1)} mi',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.6),
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(width: 8),
                      SizedBox(
                        width: 40,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(2),
                          child: LinearProgressIndicator(
                            value: _navProgress,
                            backgroundColor: Colors.white.withValues(alpha: 0.15),
                            valueColor: const AlwaysStoppedAnimation(Colors.white),
                            minHeight: 3,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
        ],
      ),
    ),
  );
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//  BOTTOM AREA (per phase)
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _bottomArea(
    bool isDark,
    Color bg,
    Color surface,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    switch (_phase) {
      case _Phase.searching:
        return _searchingBar(isDark, surface, textMuted, borderC);
      case _Phase.rideRequest:
        return const SizedBox.shrink(); // handled by stacked cards overlay
      case _Phase.enRouteToPickup:
        return _pickupPanel(
          isDark,
          bg,
          textPrimary,
          textMuted,
          borderC,
          shadowC,
        );
      case _Phase.arrivedAtPickup:
        return _arrivedPanel(
          isDark,
          bg,
          textPrimary,
          textMuted,
          borderC,
          shadowC,
        );
      case _Phase.routeSummary:
        return _routeSummaryPanel(
          isDark,
          bg,
          textPrimary,
          textMuted,
          borderC,
          shadowC,
        );
      case _Phase.inTrip:
        return _tripPanel(isDark, bg, textPrimary, textMuted, borderC, shadowC);
      case _Phase.completed:
        return const SizedBox.shrink();
    }
  }

  // â”€â”€ SEARCHING: Uber-style "Finding trips" bar â”€â”€
  Widget _searchingBar(
    bool isDark,
    Color surface,
    Color textMuted,
    Color borderC,
  ) {
    return GestureDetector(
      onVerticalDragUpdate: (d) {
        // Detect swipe up (negative dy) to open the panel
        if (d.delta.dy < -3) _showOnlinePanel();
      },
      behavior: HitTestBehavior.opaque,
      child: ListenableBuilder(
        listenable: _searchPulseVal,
        builder: (_, __) => CustomPaint(
          foregroundPainter: _SearchingBorderPainter(
            progress: _searchPulseVal.value,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
              border: Border(top: BorderSide(color: borderC)),
            ),
            child: SafeArea(
              top: false,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 2), // Spacer for border glow
                  // Drag handle
                  Padding(
                    padding: const EdgeInsets.only(top: 10, bottom: 4),
                    child: Container(
                      width: 36,
                      height: 4,
                      decoration: BoxDecoration(
                        color: textMuted.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  // Practice Mode toggle — always visible
                  GestureDetector(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  setState(() => _isSimulationMode = !_isSimulationMode);
                  _snack(_isSimulationMode
                    ? '🎮 Practice Mode ON'
                    : '🎮 Practice Mode OFF');
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                  decoration: BoxDecoration(
                    color: _isSimulationMode
                        ? _gold.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isSimulationMode
                          ? _gold.withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.12),
                      width: 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isSimulationMode
                            ? Icons.videogame_asset_rounded
                            : Icons.videogame_asset_off_rounded,
                        color: _isSimulationMode ? _gold : Colors.white.withValues(alpha: 0.5),
                        size: 18,
                      ),
                      const SizedBox(width: 10),
                      Text(
                        'Practice Mode',
                        style: TextStyle(
                          color: _isSimulationMode ? _gold : Colors.white.withValues(alpha: 0.6),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      Container(
                        width: 40,
                        height: 22,
                        decoration: BoxDecoration(
                          color: _isSimulationMode
                              ? _gold
                              : Colors.grey.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: AnimatedAlign(
                          duration: const Duration(milliseconds: 200),
                          alignment: _isSimulationMode
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            width: 18,
                            height: 18,
                            margin: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              // Status bar — swipe on parent opens panel
              SizedBox(
                height: 44,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    VerifiedAvatar(
                      photoUrl: widget.photoUrl,
                      radius: 15,
                      fallbackName: null,
                      isVerified: false,
                    ),
                    const Spacer(),
                    Text(
                      S.of(context).findingTrips,
                      style: TextStyle(
                        color: textMuted,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.format_list_bulleted_rounded,
                      color: textMuted,
                      size: 22,
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
        ),
      ),
    );
  }

  // â”€â”€ STACKED RIDE OFFER CARDS (Spark-style — persistent, no timeout) â”€â”€
  Widget _rideOfferCards(
    bool isDark,
    Color card,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    final bot = MediaQuery.of(context).padding.bottom;
    // â”€â”€ Always use dark styling for offer cards â”€â”€
    const cCardBg = Color(0xFF1A1A1A);
    final cCardBorder = _gold.withValues(alpha: 0.12);
    final cRejectBg = Colors.red.withValues(alpha: 0.08);
    const cRejectText = Color(0xFFFF6B6B);
    const cTextPrimary = Colors.white;
    final cTextMuted = Colors.white.withValues(alpha: 0.5);
    final cBorderC = Colors.white.withValues(alpha: 0.06);
    final acceptBg = _gold;

    final safeIdx = _currentOfferIndex.clamp(0, (_pendingOffers.length - 1).clamp(0, 999));
    final currentOid = _pendingOffers.isNotEmpty
        ? (_pendingOffers[safeIdx]['offer_id'] ?? _pendingOffers[safeIdx]['id'] ?? '').toString()
        : '';
    final isCardExpanded = _expandedOfferIds.contains(currentOid);

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
              // â”€â”€ Tappable header: handle + title + chevron â”€â”€
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Column(
                children: [
                  const SizedBox(height: 10),
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    S.of(context).ridesAvailable(_pendingOffers.length),
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 14,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            // ── Horizontal swipeable offer cards ──
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              height: (MediaQuery.of(context).size.height * 0.45).clamp(280, 380).toDouble(),
              child: PageView.builder(
                controller: _offerPageCtrl,
                onPageChanged: (index) {
                  setState(() => _currentOfferIndex = index);
                  HapticFeedback.selectionClick();
                  if (index < _pendingOffers.length) {
                    _autoTriggerRoutePreview(_pendingOffers[index]);
                  }
                },
                itemCount: _pendingOffers.length,
                itemBuilder: (ctx, i) {
                  final offer = _pendingOffers[i];
                  final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();
                  final isAnimating = _animatingOfferId == oid;
                  final isRejecting = _rejectingOfferId == oid;
                  Widget card = _offerCard(
                    offer,
                    true,
                    cCardBg,
                    cCardBorder,
                    cTextPrimary,
                    cTextMuted,
                    cRejectBg,
                    cRejectText,
                    acceptBg,
                    cBorderC,
                  );
                  // Pulse scale on tap-down/tap-up
                  if (isAnimating && _pulseAnim != null) {
                    card = AnimatedBuilder(
                      animation: _pulseAnim!,
                      builder: (_, child) => Transform.scale(
                        scale: _pulseAnim!.value,
                        child: child,
                      ),
                      child: card,
                    );
                  }
                  // Reject slide-down animation
                  if (isRejecting && _rejectSlideCtrl != null) {
                    card = AnimatedBuilder(
                      animation: _rejectSlideCtrl!,
                      builder: (_, child) => Transform.translate(
                        offset: Offset(0, _rejectSlideCtrl!.value * 400),
                        child: Opacity(
                          opacity: (1.0 - _rejectSlideCtrl!.value).clamp(0.0, 1.0),
                          child: child,
                        ),
                      ),
                      child: card,
                    );
                  }
                  return GestureDetector(
                    onTapDown: (_) {
                      setState(() => _animatingOfferId = oid);
                      _pulseCtrl?.forward();
                    },
                    onTapUp: (_) {
                      _pulseCtrl?.reverse().then((_) {
                        if (mounted) _onOfferCardTap(offer);
                      });
                    },
                    onTapCancel: () {
                      _pulseCtrl?.reverse();
                    },
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      child: card,
                    ),
                  );
                },
              ),
            ),
            // ── Page indicator dots ──
            if (_pendingOffers.length > 1)
              Padding(
                padding: const EdgeInsets.only(top: 8, bottom: 4),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: List.generate(_pendingOffers.length, (i) {
                    final active = i == _currentOfferIndex;
                    return AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      width: active ? 18 : 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: active ? _gold : Colors.white.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(3),
                      ),
                    );
                  }),
                ),
              ),
              // â”€â”€ Scrollable card list (hidden when collapsed) â”€â”€

              // â”€â”€ "Finding trips" bar at the bottom â”€â”€
              ClipRect(
                child: AnimatedSlide(
                  offset: _hideFindingBar ? const Offset(0, 1) : Offset.zero,
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeInOut,
                  child: AnimatedOpacity(
                    opacity: _hideFindingBar ? 0.0 : 1.0,
                    duration: const Duration(milliseconds: 300),
                    child: GestureDetector(
                      onTap: _hideFindingBar ? null : _showGoOfflineSheet,
                      onVerticalDragUpdate: _hideFindingBar ? null : (details) {
                        if (details.delta.dy < -5) {
                          _showGoOfflineSheet();
                        }
                      },
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        decoration: BoxDecoration(
                          color: const Color(0xFF111111),
                          border: Border(
                            top: BorderSide(
                              color: Colors.white.withValues(alpha: 0.06),
                            ),
                          ),
                        ),
                        child: SafeArea(
                          top: false,
                          child: SizedBox(
                            height: 52,
                            child: Row(
                              children: [
                                const SizedBox(width: 16),
                                Icon(
                                  Icons.tune_rounded,
                                  color: Colors.white.withValues(alpha: 0.5),
                                  size: 22,
                                ),
                                const Spacer(),
                                Text(
                                  S.of(context).findingTrips,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 14,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const Spacer(),
                                Icon(
                                  Icons.format_list_bulleted_rounded,
                                  color: Colors.white.withValues(alpha: 0.5),
                                  size: 22,
                                ),
                                const SizedBox(width: 16),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
    );
  }

  /// Shows the Go Offline bottom sheet (accessible from Finding trips bar)
  void _showGoOfflineSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF111111) : Colors.white;
    final textPrimary = isDark ? Colors.white : Colors.black;
    final textMuted = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.5);
    final borderC = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final panelItemText = isDark
        ? Colors.white.withValues(alpha: 0.7)
        : Colors.black.withValues(alpha: 0.6);
    final panelItemIcon = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.4);
    final panelItemChevron = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.12);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      enableDrag: true,
      builder: (ctx) {
        final maxH = MediaQuery.of(ctx).size.height * 0.82;
        return ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH),
          child: Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(top: BorderSide(color: _gold.withValues(alpha: 0.08))),
            ),
            child: SafeArea(
              top: false,
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: textMuted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Icon(Icons.tune_rounded, color: textMuted, size: 22),
                    const Spacer(),
                    Text(
                      S.of(context).findingTrips,
                      style: TextStyle(
                        color: textMuted,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.format_list_bulleted_rounded,
                      color: textMuted,
                      size: 22,
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: borderC),
              const SizedBox(height: 12),
              // PRACTICE MODE toggle — always visible at top
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _isSimulationMode = !_isSimulationMode);
                  Navigator.pop(context);
                  _snack(_isSimulationMode
                    ? '🎮 Practice Mode ON - Viajes simulados activos'
                    : '🎮 Practice Mode OFF - Solo viajes reales');
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: _isSimulationMode
                        ? const Color(0xFFE8C547).withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isSimulationMode
                          ? const Color(0xFFE8C547).withValues(alpha: 0.5)
                          : Colors.white.withValues(alpha: 0.15),
                      width: _isSimulationMode ? 1.5 : 1,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isSimulationMode ? Icons.videogame_asset_rounded : Icons.videogame_asset_off_rounded,
                        color: _isSimulationMode ? const Color(0xFFE8C547) : Colors.white.withValues(alpha: 0.7),
                        size: 22,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Practice Mode',
                              style: TextStyle(
                                color: _isSimulationMode ? const Color(0xFFE8C547) : Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              _isSimulationMode ? 'Viajes simulados activos' : 'Activa para practicar',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 48,
                        height: 26,
                        decoration: BoxDecoration(
                          color: _isSimulationMode ? const Color(0xFFE8C547) : Colors.grey.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: AnimatedAlign(
                          duration: const Duration(milliseconds: 200),
                          alignment: _isSimulationMode ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            width: 22,
                            height: 22,
                            margin: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: borderC),
              const SizedBox(height: 16),
              Text(
                S.of(context).recommendedForYou,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              _panelItem(
                Icons.bar_chart_rounded,
                S.of(context).seeEarningsTrends,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    slideFromRightRoute(const DriverEarningsScreen()),
                  );
                },
              ),
              _panelItem(
                Icons.star_outline_rounded,
                S.of(context).seeUpcomingPromotions,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    slideFromRightRoute(const DriverPromosScreen()),
                  );
                },
              ),
              _panelItem(
                Icons.access_time_rounded,
                S.of(context).seeDrivingTime,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    slideFromRightRoute(const DriverAnalyticsScreen()),
                  );
                },
              ),
              const SizedBox(height: 20),
              // SIMULATION SPEED control (only visible when simulation mode is on)
              if (_isSimulationMode)
                Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: borderC),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.speed_rounded,
                            color: const Color(0xFFE8C547),
                            size: 20,
                          ),
                          const SizedBox(width: 10),
                          Text(
                            'Simulation Speed',
                            style: TextStyle(
                              color: textPrimary,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8C547).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              '${(_simulationSpeed * 40).round()} mph',
                              style: TextStyle(
                                color: const Color(0xFFE8C547),
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: const Color(0xFFE8C547),
                          inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
                          thumbColor: const Color(0xFFE8C547),
                          overlayColor: const Color(0xFFE8C547).withValues(alpha: 0.2),
                          trackHeight: 4,
                        ),
                        child: Slider(
                          value: _simulationSpeed,
                          min: 0.5,
                          max: 3.0,
                          divisions: 5,
                          onChanged: (v) {
                            setState(() => _simulationSpeed = v);
                          },
                        ),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Slow',
                            style: TextStyle(
                              color: textMuted.withValues(alpha: 0.7),
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            'Normal',
                            style: TextStyle(
                              color: textMuted.withValues(alpha: 0.7),
                              fontSize: 12,
                            ),
                          ),
                          Text(
                            'Fast',
                            style: TextStyle(
                              color: textMuted.withValues(alpha: 0.7),
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              const SizedBox(height: 20),
              // PAUSE and GO OFFLINE buttons row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  // PAUSE button
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      _pauseAvailability();
                    },
                    child: Column(
                      children: [
                        Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(0xFFFFA500).withValues(alpha: 0.15),
                            border: Border.all(
                              color: const Color(0xFFFFA500).withValues(alpha: 0.3),
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.pause_circle_filled_rounded,
                            color: Color(0xFFFFA500),
                            size: 26,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'PAUSE'.toUpperCase(),
                          style: const TextStyle(
                            color: Color(0xFFFFA500),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // GO OFFLINE button
                  GestureDetector(
                    onTap: () {
                      Navigator.pop(context);
                      _goOffline();
                    },
                    child: Column(
                      children: [
                        Container(
                          width: 62,
                          height: 62,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: const Color(
                              0xFFCC3333,
                            ).withValues(alpha: 0.15),
                            border: Border.all(
                              color: const Color(
                                0xFFCC3333,
                              ).withValues(alpha: 0.3),
                              width: 2,
                            ),
                          ),
                          child: const Icon(
                            Icons.pan_tool_rounded,
                            color: Color(0xFFCC3333),
                            size: 26,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          S.of(context).goOffline.toUpperCase(),
                          style: const TextStyle(
                            color: Color(0xFFCC3333),
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// Decode a Google/OSRM polyline string into a list of [lng,lat] coordinate pairs.
  static List<List<double>> _decodePolylineCoords(String encoded) {
    final pts = <List<double>>[];
    int i = 0, lat = 0, lng = 0;
    while (i < encoded.length) {
      int s = 0, r = 0, b;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0; r = 0;
      do {
        b = encoded.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add([lng / 1E5, lat / 1E5]);
    }
    return pts;
  }

  /// Fetch both legs (driver→pickup + pickup→dropoff) from OSRM and build
  /// a Mapbox Static API URL with the real road polyline overlaid.
  Future<String> _buildOfferMapUrl(
    LatLng driver,
    LatLng pickup,
    LatLng dropoff,
  ) async {
    final token = MapboxConfig.accessToken;
    final dLng = driver.longitude.toStringAsFixed(6);
    final dLat = driver.latitude.toStringAsFixed(6);
    final pLng = pickup.longitude.toStringAsFixed(6);
    final pLat = pickup.latitude.toStringAsFixed(6);
    final oLng = dropoff.longitude.toStringAsFixed(6);
    final oLat = dropoff.latitude.toStringAsFixed(6);

    // Fetch two legs from OSRM
    List<List<double>> allPts = [];
    try {
      // Leg 1: driver → pickup
      final uri1 = Uri.https(
        'router.project-osrm.org',
        '/route/v1/driving/${driver.longitude},${driver.latitude};${pickup.longitude},${pickup.latitude}',
        {'overview': 'full', 'geometries': 'polyline'},
      );
      final r1 = await http.get(uri1).timeout(const Duration(seconds: 6));
      final d1 = jsonDecode(r1.body);
      if (d1 is Map && d1['code']?.toString().toUpperCase() == 'OK') {
        final geo1 = (d1['routes'] as List?)?.first?['geometry']?.toString();
        if (geo1 != null) allPts.addAll(_decodePolylineCoords(geo1));
      }
    } catch (_) {}

    try {
      // Leg 2: pickup → dropoff
      final uri2 = Uri.https(
        'router.project-osrm.org',
        '/route/v1/driving/${pickup.longitude},${pickup.latitude};${dropoff.longitude},${dropoff.latitude}',
        {'overview': 'full', 'geometries': 'polyline'},
      );
      final r2 = await http.get(uri2).timeout(const Duration(seconds: 6));
      final d2 = jsonDecode(r2.body);
      if (d2 is Map && d2['code']?.toString().toUpperCase() == 'OK') {
        final geo2 = (d2['routes'] as List?)?.first?['geometry']?.toString();
        if (geo2 != null) allPts.addAll(_decodePolylineCoords(geo2));
      }
    } catch (_) {}

    // Pins
    final driverPin = 'pin-s-car+1a73e8($dLng,$dLat)';
    final pickupPin  = 'pin-s+00c853($pLng,$pLat)';
    final dropoffPin = 'pin-s+333333($oLng,$oLat)';

    String pathOverlay;
    if (allPts.length >= 2) {
      // Subsample to ≤100 points so URL stays within Mapbox's 8192-char limit
      final step = allPts.length > 100 ? (allPts.length / 100).ceil() : 1;
      final sampled = <List<double>>[];
      for (int k = 0; k < allPts.length; k += step) {
        sampled.add(allPts[k]);
      }
      if (sampled.last != allPts.last) sampled.add(allPts.last);
      final coords = sampled.map((p) => '${p[0].toStringAsFixed(5)},${p[1].toStringAsFixed(5)}').join(';');
      pathOverlay = 'path-4+3b82f6-1($coords)';
    } else {
      // Fallback: straight line
      pathOverlay = 'path-3+3b82f6-0.8($dLng,$dLat;$pLng,$pLat;$oLng,$oLat)';
    }

    return 'https://api.mapbox.com/styles/v1/mapbox/dark-v11/static/'
        '$driverPin,$pickupPin,$dropoffPin,$pathOverlay'
        '/auto/700x320@2x?padding=70,50,50,50&access_token=$token';
  }

  Widget _offerCard(
    Map<String, dynamic> offer,
    bool isDark,
    Color cardBg,
    Color cardBorder,
    Color textPrimary,
    Color textMuted,
    Color rejectBg,
    Color rejectText,
    Color acceptBg,
    Color borderC,
  ) {
    const luxGold = Color(0xFFD4AF37);
    const deepBlack = Color(0xFF0F0F0F);
    const mutedGray = Color(0xFF9A9A9A);

    // Parse offer data
    final rating = (offer['rider_rating'] as num?)?.toDouble() ?? 4.8;
    final fare = (offer['fare'] as num?)?.toDouble() ?? 0;
    final pickupAddr = (offer['pickup_address'] ?? 'Pickup') as String;
    final dropoffAddr = (offer['dropoff_address'] ?? 'Drop-off') as String;
    final pickupLat = (offer['pickup_lat'] as num?)?.toDouble() ?? 0;
    final pickupLng = (offer['pickup_lng'] as num?)?.toDouble() ?? 0;
    final dropoffLat = (offer['dropoff_lat'] as num?)?.toDouble() ?? 0;
    final dropoffLng = (offer['dropoff_lng'] as num?)?.toDouble() ?? 0;
    final vehicleType = _mapRideType((offer['vehicle_type'] ?? 'Comfort') as String);
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);

    final distToPickupKm = _hav(_pos!, pickupLL);
    final etaToPickup = (distToPickupKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    final distToPickupMi = distToPickupKm * 0.621371;
    final tripDistKm = _hav(pickupLL, dropoffLL);
    final tripEta = (tripDistKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    final tripDistMi = tripDistKm * 0.621371;

    // Cache per offer so we don't re-fetch on every rebuild
    final offerId = (offer['offer_id'] ?? offer['id'] ?? '${pickupLat}_$pickupLng').toString();
    _offerMapUrlCache.putIfAbsent(
      offerId,
      () => _buildOfferMapUrl(_pos!, pickupLL, dropoffLL),
    );

    final isExpanded = _expandedOfferIds.contains(offerId);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: deepBlack,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFFE8C547).withValues(alpha: 0.25),
          width: 1,
        ),
      ),
      child: Padding(
        padding: EdgeInsets.fromLTRB(14, isExpanded ? 10 : 8, 14, isExpanded ? 10 : 8),
        child: AnimatedSwitcher(
          duration: const Duration(milliseconds: 350),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          transitionBuilder: (child, anim) =>
              FadeTransition(opacity: anim, child: child),
          child: _acceptingCardId == offerId &&
                  _offerAcceptState == _OfferAcceptState.accepted
              ? _buildAcceptedCardContent(pickupAddr)
              : _acceptingCardId == offerId &&
                      _offerAcceptState == _OfferAcceptState.routing
                  ? _buildRoutingCardContent()
                  : _buildNormalCardContent(
                      offer: offer,
                      offerId: offerId,
                      fare: fare,
                      rating: rating,
                      vehicleType: vehicleType,
                      etaToPickup: etaToPickup,
                      distToPickupMi: distToPickupMi,
                      pickupAddr: pickupAddr,
                      tripEta: tripEta,
                      tripDistMi: tripDistMi,
                      dropoffAddr: dropoffAddr,
                      isExpanded: isExpanded,
                    ),
        ),
      ),
    );
  }

  // ── Normal card content (default offer view) ──
  Widget _buildNormalCardContent({
    required Map<String, dynamic> offer,
    required String offerId,
    required double fare,
    required double rating,
    required String vehicleType,
    required int etaToPickup,
    required double distToPickupMi,
    required String pickupAddr,
    required int tripEta,
    required double tripDistMi,
    required String dropoffAddr,
    required bool isExpanded,
  }) {
    const goldAccent = Color(0xFFE8C547);
    const rejectRed = Color(0xFFE53935);
    final totalMins = etaToPickup + tripEta;
    final totalMiles = distToPickupMi + tripDistMi;

    return Column(
      key: const ValueKey('compact'),
      mainAxisSize: MainAxisSize.max,
      children: [
        // ── ROW 1: Rating (left) · Comfort badge (center) · X reject (right) ──
        Row(
          children: [
            // Rating badge
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: goldAccent.withValues(alpha: 0.2)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.star_rounded, color: goldAccent, size: 14),
                  const SizedBox(width: 3),
                  Text(
                    rating.toStringAsFixed(1),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            // Service tier badge (Comfort/VIP/Premium)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A1A),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: goldAccent.withValues(alpha: 0.3),
                  width: 1,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.person_rounded, size: 14, color: goldAccent),
                  const SizedBox(width: 6),
                  Text(
                    vehicleType,
                    style: const TextStyle(
                      color: goldAccent,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            const Spacer(),
            // X Reject button — RED
            GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                HapticFeedback.lightImpact();
                _rejectOffer(offer);
              },
              child: Container(
                width: 44,
                height: 44,
                alignment: Alignment.center,
                child: Container(
                  width: 28,
                  height: 28,
                  decoration: const BoxDecoration(
                    color: Color(0xFF2A2A2A),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(Icons.close, color: rejectRed, size: 16),
                ),
              ),
            ),
          ],
        ),

        const SizedBox(height: 6),

        // ── ROW 2: Price (centered) + Tips label ──
        Text(
          '\$${fare.toStringAsFixed(2)}',
          style: const TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 1),
        Text(
          '+ Tips',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 12,
          ),
        ),

        const SizedBox(height: 8),

        // ── ROW 3: Route indicator (gold ● line ■ with addresses) ──
        Expanded(
          child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Gold ● | ■ indicator column
              Padding(
                padding: const EdgeInsets.only(top: 3),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Gold filled circle (pickup)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: const BoxDecoration(
                        color: Color(0xFFD4A843),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Gold vertical line
                    Container(
                      width: 2,
                      height: 22,
                      color: const Color(0xFFD4A843).withValues(alpha: 0.4),
                    ),
                    const SizedBox(height: 4),
                    // Black square with gold shadow (dropoff)
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: Colors.black,
                        borderRadius: BorderRadius.circular(2),
                        boxShadow: const [
                          BoxShadow(
                            color: Color(0x55D4A843),
                            blurRadius: 6,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              // Address details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Pickup info
                    Text(
                      '$etaToPickup min (${distToPickupMi.toStringAsFixed(1)} mi) away',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 10,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      pickupAddr,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 10),
                    // Dropoff info
                    Text(
                      '$tripEta min (${tripDistMi.toStringAsFixed(1)} mi) trip',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 10,
                      ),
                    ),
                    const SizedBox(height: 1),
                    Text(
                      dropoffAddr,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          ),
        ),

        const SizedBox(height: 6),

        // ── ROW 4: Time + Miles chips (compact) ──
        Row(
          children: [
            Expanded(child: _buildOfferChip(
              icon: Icons.timer_outlined,
              value: '$totalMins min',
              label: 'Total time',
            )),
            const SizedBox(width: 6),
            Expanded(child: _buildOfferChip(
              icon: Icons.straighten_rounded,
              value: '${totalMiles.toStringAsFixed(1)} mi',
              label: 'Total distance',
            )),
          ],
        ),

        const SizedBox(height: 4),

        // ── Divider ──
        Container(
          height: 0.5,
          color: const Color(0xFF333333),
        ),

        const SizedBox(height: 6),

        // ── ROW 5: Accept button — GOLD — ALWAYS VISIBLE ──
        GestureDetector(
          onTapDown: (_) => setState(() => _isAcceptPressed = true),
          onTapUp: (_) {
            setState(() => _isAcceptPressed = false);
            _acceptOffer(offer);
          },
          onTapCancel: () => setState(() => _isAcceptPressed = false),
          child: AnimatedScale(
            scale: _isAcceptPressed ? 0.97 : 1.0,
            duration: const Duration(milliseconds: 100),
            child: Container(
              width: double.infinity,
              height: 48,
              decoration: BoxDecoration(
                color: const Color(0xFFD4A843),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Center(
                child: Text(
                  S.of(context).accept,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 15,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Chip widget for time/distance display on offer card (compact).
  Widget _buildOfferChip({
    required IconData icon,
    required String value,
    required String label,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(icon, color: const Color(0xFFE8C547), size: 12),
          const SizedBox(width: 5),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                value,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              Text(
                label,
                style: const TextStyle(color: Colors.white38, fontSize: 9),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── "Viaje Aceptado" inline card (shown inside AnimatedSwitcher in offer card) ──
  Widget _buildAcceptedCardContent(String pickupAddr) {
    const luxGold = Color(0xFFD4AF37);
    return Padding(
      key: const ValueKey('accepted'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          // Gold check circle
          TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 500),
            curve: Curves.elasticOut,
            builder: (_, scale, child) =>
                Transform.scale(scale: scale, child: child),
            child: Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: luxGold.withValues(alpha: 0.15),
                border: Border.all(color: luxGold, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: luxGold.withValues(alpha: 0.3),
                    blurRadius: 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(Icons.check_rounded, color: luxGold, size: 28),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Viaje Aceptado',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  pickupAddr,
                  style: const TextStyle(color: Colors.white54, fontSize: 13),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          // Animated loading dots
          _buildAcceptLoadingDots(),
        ],
      ),
    );
  }

  // ── "Enrutando..." state ──
  Widget _buildRoutingCardContent() {
    const luxGold = Color(0xFFD4AF37);
    return Padding(
      key: const ValueKey('routing'),
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Row(
        children: [
          const _RoutingDotsAnimation(),
          const SizedBox(width: 16),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Enrutando...',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                SizedBox(height: 4),
                Text(
                  'Preparando tu ruta',
                  style: TextStyle(color: luxGold, fontSize: 13),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Animated 3-dot gold loader for accepted card.
  Widget _buildAcceptLoadingDots() {
    return _AnimatedLoadingDots();
  }

  Widget _buildStatItem({
    required IconData icon,
    required String value,
    required String label,
  }) {
    const luxGold = Color(0xFFD4AF37);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: luxGold, size: 16),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              label,
              style: const TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }

  Widget _uberAddressRow({
    required IconData icon,
    required Color iconColor,
    required double iconSize,
    required String topLine,
    required String bottomLine,
    required bool showConnector,
    bool darkMode = false,
  }) {
    final subColor = darkMode
        ? Colors.white.withValues(alpha: 0.45)
        : const Color(0xFF666666);
    final mainColor = darkMode ? Colors.white : const Color(0xFF111111);
    final lineColor = darkMode
        ? Colors.white.withValues(alpha: 0.15)
        : const Color(0xFFCCCCCC);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Icon + connector line column
        SizedBox(
          width: 20,
          child: Column(
            children: [
              const SizedBox(height: 4),
              Icon(icon, color: iconColor, size: iconSize),
              if (showConnector)
                Container(
                  width: 1.5,
                  height: 36,
                  color: lineColor,
                  margin: const EdgeInsets.symmetric(vertical: 3),
                ),
            ],
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                topLine,
                style: TextStyle(
                  color: subColor,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                bottomLine,
                style: TextStyle(
                  color: mainColor,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              if (showConnector) const SizedBox(height: 10),
            ],
          ),
        ),
      ],
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  ROUTE PREVIEW PANEL (shown when tapping an offer card)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _routePreviewPanel(bool isDark) {
    final offer = _previewingOffer!;
    final name = (offer['rider_name'] ?? 'Rider') as String;
    final init = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final rating = (offer['rider_rating'] as num?)?.toDouble() ?? 4.8;
    final fare = (offer['fare'] as num?)?.toDouble() ?? 0;
    final pickupAddr = (offer['pickup_address'] ?? 'Pickup') as String;
    final dropoffAddr = (offer['dropoff_address'] ?? 'Drop-off') as String;
    final pickupLat = (offer['pickup_lat'] as num?)?.toDouble() ?? 0;
    final pickupLng = (offer['pickup_lng'] as num?)?.toDouble() ?? 0;
    final dropoffLat = (offer['dropoff_lat'] as num?)?.toDouble() ?? 0;
    final dropoffLng = (offer['dropoff_lng'] as num?)?.toDouble() ?? 0;
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);
    final vehicleType = _mapRideType((offer['vehicle_type'] ?? 'Comfort') as String);
    final distToPickup = _hav(_pos!, pickupLL);
    final etaToPickup = (distToPickup * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    final tripDist = _hav(pickupLL, dropoffLL);
    final tripEta = (tripDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);

    const cCardBg = Color(0xFF1A1A1A); // ignore: unused_local_variable
    const cTextPrimary = Colors.white;
    final cTextMuted = Colors.white.withValues(alpha: 0.5);
    final cBorderC = Colors.white.withValues(alpha: 0.06);
    final chipBg = Colors.white.withValues(alpha: 0.04);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A).withValues(alpha: 0.97),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // â”€â”€ Top row: Avatar + Name + Fare â”€â”€
                  Row(
                    children: [
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.11),
                          borderRadius: BorderRadius.circular(13),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.28),
                          ),
                        ),
                        child: const Icon(
                          Icons.directions_car_rounded,
                          color: _gold,
                          size: 23,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              vehicleType,
                              style: const TextStyle(
                                color: cTextPrimary,
                                fontSize: 17,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 5),
                            Row(
                              children: [
                                const Icon(Icons.star_rounded, color: _gold, size: 13),
                                const SizedBox(width: 3),
                                Text(
                                  rating.toStringAsFixed(1),
                                  style: const TextStyle(
                                    color: _gold, fontSize: 12,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Text(
                          '\$${fare.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // â”€â”€ Info chips â”€â”€
                  Row(
                    children: [
                      _infoChip(
                        Icons.near_me_rounded,
                        '${(distToPickup * 0.621371).toStringAsFixed(1)} mi',
                        chipBg,
                        cTextMuted,
                      ),
                      const SizedBox(width: 8),
                      _infoChip(
                        Icons.timer_rounded,
                        '$etaToPickup min',
                        chipBg,
                        cTextMuted,
                      ),
                      const SizedBox(width: 8),
                      _infoChip(
                        Icons.route_rounded,
                        '${(tripDist * 0.621371).toStringAsFixed(1)} mi trip',
                        chipBg,
                        cTextMuted,
                      ),
                      const SizedBox(width: 8),
                      _infoChip(
                        Icons.schedule_rounded,
                        '$tripEta min',
                        chipBg,
                        cTextMuted,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // â”€â”€ Route: Driver â†’ Pickup â†’ Dropoff â”€â”€
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.02),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cBorderC),
                    ),
                    child: Column(
                      children: [
                        // Driver location
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.blueAccent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 1.5,
                                  height: 20,
                                  color: cBorderC,
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.of(context).yourLocation,
                                    style: TextStyle(
                                      color: cTextMuted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    S.of(context).currentPosition,
                                    style: const TextStyle(
                                      color: cTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // Pickup
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.greenAccent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 1.5,
                                  height: 20,
                                  color: cBorderC,
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.of(context).pickupLabel,
                                    style: TextStyle(
                                      color: cTextMuted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    pickupAddr,
                                    style: const TextStyle(
                                      color: cTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // Dropoff
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white54,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.of(context).dropOffLabel,
                                    style: TextStyle(
                                      color: cTextMuted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    dropoffAddr,
                                    style: const TextStyle(
                                      color: cTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // â”€â”€ Action buttons: Back + Accept â”€â”€
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: _closePreview,
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              color: Colors.white70,
                              size: 18,
                            ),
                            label: Text(
                              S.of(context).back,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.06,
                              ),
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              _closePreview();
                              _acceptOffer(offer);
                            },
                            icon: const Icon(
                              Icons.check_rounded,
                              color: Colors.black,
                              size: 18,
                            ),
                            label: Text(
                              S.of(context).acceptRide,
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _gold,
                              foregroundColor: Colors.black,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _infoChip(IconData ic, String txt, Color bg, Color textColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ic, size: 14, color: _gold.withValues(alpha: 0.7)),
            const SizedBox(height: 2),
            Text(
              txt,
              style: TextStyle(
                color: textColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(IconData ic, String txt, Color c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ic, size: 12, color: c),
          const SizedBox(width: 4),
          Text(
            txt,
            style: TextStyle(
              color: c,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryBadge(IconData icon, String text, Color primary, Color muted) {
    return Column(
      children: [
        Icon(icon, color: _gold, size: 20),
        const SizedBox(height: 4),
        Text(
          text,
          style: TextStyle(
            color: primary,
            fontSize: 13,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }

  // â”€â”€ ROUTE SUMMARY PANEL (Google Maps-style overview before navigation) â”€â”€
  Widget _routeSummaryPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return _wrapInDraggableSheet(
      isDark: isDark,
      surface: bg,
      shadowC: shadowC,
      minChildSize: 0.45,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(isDark),
          const SizedBox(height: 10),
          // Rider info header with fare
          Row(
            children: [
              _avatar(42, showBadge: true),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _riderName,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      _vehicleType,
                      style: TextStyle(
                        color: _gold,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Text(
                '\$${_fare.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: _gold,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Distance / ETA / Trip info badges
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _summaryBadge(
                Icons.navigation_rounded,
                '${(_navDist * 0.621371).toStringAsFixed(1)} mi',
                textPrimary,
                textMuted,
              ),
              _summaryBadge(
                Icons.access_time_rounded,
                '$_navEta min',
                textPrimary,
                textMuted,
              ),
              _summaryBadge(
                Icons.route_rounded,
                '${(_tripDist * 0.621371).toStringAsFixed(1)} mi trip',
                textPrimary,
                textMuted,
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Pickup & Dropoff addresses
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _gold.withValues(alpha: 0.10)),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    const Icon(Icons.location_on_rounded, color: _gold, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _pickupAddr,
                        style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 3,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
                Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Container(
                      width: 2, height: 16,
                      color: _gold.withValues(alpha: 0.3),
                    ),
                  ),
                ),
                Row(
                  children: [
                    const Icon(Icons.flag_rounded, color: _gold, size: 18),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _dropoffAddr,
                        style: TextStyle(color: textPrimary, fontSize: 13, fontWeight: FontWeight.w600),
                        maxLines: 3,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Re-center button + Start Navigation button
          Row(
            children: [
              // Re-center / overview button
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  _fitBoundsMulti([_pos!, _pickupLL, _dropoffLL]);
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _gold.withValues(alpha: 0.2)),
                  ),
                  child: const Icon(
                    Icons.center_focus_strong_rounded,
                    color: _gold,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Start Navigation button
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: () => _beginNavigation(),
                    icon: const Icon(
                      Icons.navigation_rounded,
                      color: Colors.black,
                      size: 20,
                    ),
                    label: Flexible(
                      child: Text(
                        S.of(context).startNavigation,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      elevation: 4,
                      shadowColor: _gold.withValues(alpha: 0.3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── PICKUP PANEL ──
  Widget _pickupPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.12),
            blurRadius: 14,
            offset: const Offset(0, -4),
          )
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Center(
                child: Container(
                  width: 40, height: 4,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    color: borderC,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              Row(
                children: [
                  const Icon(Icons.location_on_rounded, color: _gold, size: 20),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _riderName,
                          style: TextStyle(
                            color: textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _pickupAddr,
                          style: TextStyle(
                            color: textMuted,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 3,
                          softWrap: true,
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      if (_riderPhone.isNotEmpty) {
                        final uri = Uri(scheme: 'tel', path: _riderPhone);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }
                    },
                    icon: const Icon(Icons.phone, color: _gold, size: 22),
                    style: IconButton.styleFrom(
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.05),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Navigate button row
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => MapLauncherService.navigate(
                        destLat: _pickupLL.latitude,
                        destLng: _pickupLL.longitude,
                      ),
                      icon: const Icon(Icons.navigation_rounded, size: 18),
                      label: const Text('NAVIGATE'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isDark ? Colors.white : Colors.black,
                        side: BorderSide(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.2)
                              : Colors.black.withValues(alpha: 0.2),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: const Size.fromHeight(48),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _arrivePickup,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.black,
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _nearPickupNotified
                        ? S.of(context).arrived.toUpperCase()
                        : S.of(context).arrivedAtPickup.toUpperCase(),
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── ARRIVED PANEL ──
  Widget _arrivedPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return _wrapInDraggableSheet(
      isDark: isDark,
      surface: bg,
      shadowC: shadowC,
      minChildSize: 0.38,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(isDark),
          const SizedBox(height: 12),
          // Waiting status
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: _goldLight.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _goldLight.withValues(alpha: 0.1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(
                      _goldLight.withValues(alpha: 0.8),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  S.of(context).waitingForRider,
                  style: TextStyle(
                    color: textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _avatar(50, showBadge: true),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _riderName,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _vehicleType,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _actionBtn(Icons.phone_rounded, () async {
                if (_riderPhone.isNotEmpty) {
                  final uri = Uri(scheme: 'tel', path: _riderPhone);
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                }
              }),
              const SizedBox(width: 8),
              Stack(
                clipBehavior: Clip.none,
                children: [
                  _actionBtn(Icons.chat_bubble_rounded, () {
                    Navigator.of(context).push(
                      slideFromRightRoute(ChatScreen(
                        recipientName: _riderName,
                        recipientPhone: _riderPhone,
                        tripId: _tripId,
                        currentUserId: _driverId?.toString(),
                        currentRole: 'driver',
                      )),
                    );
                  }),
                  if (_tripId != null)
                    StreamBuilder<int>(
                      stream: ChatService().unreadCountStream(
                        rideId: _tripId.toString(),
                        readerRole: 'driver',
                      ),
                      builder: (context, snap) {
                        final count = snap.data ?? 0;
                        if (count == 0) return const SizedBox.shrink();
                        return Positioned(
                          right: -4,
                          top: -4,
                          child: Container(
                            padding: const EdgeInsets.all(4),
                            decoration: const BoxDecoration(
                              color: Color(0xFFEF4444),
                              shape: BoxShape.circle,
                            ),
                            constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                            child: Text(
                              count > 9 ? '9+' : '$count',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                              textAlign: TextAlign.center,
                            ),
                          ),
                        );
                      },
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          // START TRIP button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _startTrip,
              icon: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.black,
                size: 22,
              ),
              label: Text(
                S.of(context).startTrip,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                elevation: 4,
                shadowColor: _gold.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _cancelRow(isDark),
        ],
      ),
    );
  }

  // â”€â”€ IN-TRIP PANEL â”€â”€
  // NAV STAT CHIP (icon + label, used in Google Maps-style ETA strip)
  Widget _navStat(IconData icon, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _tripPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 16,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ETA strip - Uber style
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '$_navEta min',
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          height: 1.0,
                        ),
                      ),
                      Text(
                        '${(_navDist * 0.621371).toStringAsFixed(1)} mi away',
                        style: TextStyle(
                          color: textMuted,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '\$${_fare.toStringAsFixed(2)}',
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 24,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              // Rider info with avatar + badge
              Row(
                children: [
                  _avatar(42, showBadge: true),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _riderName,
                          style: TextStyle(
                            color: textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _vehicleType,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: () async {
                      if (_riderPhone.isNotEmpty) {
                        final uri = Uri(scheme: 'tel', path: _riderPhone);
                        if (await canLaunchUrl(uri)) await launchUrl(uri);
                      }
                    },
                    icon: const Icon(
                      Icons.phone,
                      color: _gold,
                      size: 22,
                    ),
                    style: IconButton.styleFrom(
                      backgroundColor: isDark
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.black.withValues(alpha: 0.05),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // Dropoff address card — full text, gold icon
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: isDark ? const Color(0xFF1A1A1A) : Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.flag_rounded, color: _gold, size: 20),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _dropoffAddr,
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 3,
                        softWrap: true,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              // Navigate to dropoff button
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => MapLauncherService.navigate(
                        destLat: _dropoffLL.latitude,
                        destLng: _dropoffLL.longitude,
                      ),
                      icon: const Icon(Icons.navigation_rounded, size: 18),
                      label: const Text('NAVIGATE'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: isDark ? Colors.white : Colors.black,
                        side: BorderSide(
                          color: isDark
                              ? Colors.white.withValues(alpha: 0.2)
                              : Colors.black.withValues(alpha: 0.2),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        minimumSize: const Size.fromHeight(48),
                        textStyle: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              // COMPLETE TRIP button - Uber style
              SizedBox(
                width: double.infinity,
                height: 56,
                child: ElevatedButton(
                  onPressed: _complete,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _nearDropoffNotified
                        ? Colors.black
                        : Colors.black.withValues(alpha: 0.3),
                    foregroundColor: Colors.white,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  child: Text(
                    _nearDropoffNotified
                        ? S.of(context).finishTrip.toUpperCase()
                        : 'COMPLETE TRIP',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // â”€â”€ COMPLETED OVERLAY â”€â”€
  Widget _completedOverlay(
    bool isDark,
    Color overlayBg,
    Color card,
    Color textPrimary,
    Color borderC,
    Color shadowC,
  ) {
    final subtleText = isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.35);
    final subtleBg = isDark
        ? Colors.white.withValues(alpha: 0.03)
        : Colors.black.withValues(alpha: 0.04);

    return GestureDetector(
      onTap: () {},
      child: Container(
        color: overlayBg,
        child: Center(
          child: FadeTransition(
            opacity: _doneScale,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: card,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _gold.withValues(alpha: 0.2)),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.08),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.15),
                          _gold.withValues(alpha: 0.05),
                        ],
                      ),
                      border: Border.all(
                        color: _gold.withValues(alpha: 0.3),
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: _gold,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    S.of(context).tripComplete,
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Fare
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _gold.withValues(alpha: 0.1)),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '\$${_fare.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          S.of(context).fareEarned,
                          style: TextStyle(color: subtleText, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Rating
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: subtleBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text(
                          S.of(context).rateRider,
                          style: TextStyle(color: subtleText, fontSize: 11),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                            5,
                            (i) => GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _stars = i + 1);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                child: Icon(
                                  Icons.star_rounded,
                                  color: i < _stars
                                      ? _gold
                                      : _gold.withValues(alpha: 0.15),
                                  size: 30,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Session summary
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _sumStat(
                        '\$${_earnings.toStringAsFixed(2)}',
                        S.of(context).totalLabel,
                        textPrimary,
                        subtleText,
                      ),
                      _sumStat(
                        '$_trips',
                        S.of(context).tripsLabel,
                        textPrimary,
                        subtleText,
                      ),
                      _sumStat(
                        _timeStr,
                        S.of(context).onlineLabel,
                        textPrimary,
                        subtleText,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _afterComplete,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 4,
                        shadowColor: _gold.withValues(alpha: 0.3),
                      ),
                      child: Text(
                        S.of(context).continueDriving,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  ONLINE PANEL (draggable with GO OFFLINE)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _showOnlinePanel() {
    final screenH = MediaQuery.of(context).size.height;
    final botPad = MediaQuery.of(context).padding.bottom;
    final minFrac = ((86 + botPad) / screenH).clamp(0.10, 0.20);
    final isOpen = _panelSheetCtrl.isAttached &&
        _panelSheetCtrl.size > (minFrac + 0.05);
    _panelSheetCtrl.animateTo(
      isOpen ? minFrac : 0.85,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOut,
    );
    setState(() => _panelOpen = !isOpen);
  }

  Widget _draggablePanel(
    bool isDark,
    Color surface,
    Color textMuted,
    Color borderC,
    Color textPrimary,
    Color shadowC,
  ) {
    final screenH = MediaQuery.of(context).size.height;
    final botPad = MediaQuery.of(context).padding.bottom;
    final minFrac = ((86 + botPad) / screenH).clamp(0.10, 0.20);
    final panelItemText = isDark
        ? Colors.white.withValues(alpha: 0.7)
        : Colors.black.withValues(alpha: 0.6);
    final panelItemIcon = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.4);
    final panelItemChevron = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.12);

    return DraggableScrollableSheet(
      controller: _panelSheetCtrl,
      initialChildSize: minFrac,
      minChildSize: minFrac,
      maxChildSize: 0.85,
      snap: true,
      snapSizes: [minFrac, 0.55, 0.85],
      builder: (ctx, scrollCtrl) {
        return Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: _gold.withValues(alpha: 0.08)),
            ),
            boxShadow: [
              BoxShadow(
                color: shadowC,
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: ListView(
            controller: scrollCtrl,
            padding: EdgeInsets.zero,
            children: [
              ListenableBuilder(
                listenable: _searchPulseVal,
                builder: (_, __) => SizedBox(
                  height: 2,
                  child: LinearProgressIndicator(
                    value: null,
                    backgroundColor: Colors.transparent,
                    valueColor: AlwaysStoppedAnimation(
                      _gold.withValues(alpha: 0.5),
                    ),
                    minHeight: 2,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              _handle(isDark),
              Icon(
                Icons.keyboard_arrow_up_rounded,
                color: textMuted.withValues(alpha: 0.5),
                size: 18,
              ),
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Icon(Icons.tune_rounded, color: textMuted, size: 22),
                    const Spacer(),
                    Text(
                      S.of(context).findingTrips,
                      style: TextStyle(
                        color: textMuted,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.format_list_bulleted_rounded,
                      color: textMuted,
                      size: 22,
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
              ),

              const SizedBox(height: 12),
              Divider(height: 1, color: borderC),
              const SizedBox(height: 12),
              // ── Practice Mode toggle ──
              GestureDetector(
                onTap: () {
                  HapticFeedback.mediumImpact();
                  setState(() => _isSimulationMode = !_isSimulationMode);
                  _snack(_isSimulationMode
                    ? '🎮 Practice Mode ON'
                    : '🎮 Practice Mode OFF');
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: _isSimulationMode
                        ? _gold.withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isSimulationMode
                          ? _gold.withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isSimulationMode
                            ? Icons.videogame_asset_rounded
                            : Icons.videogame_asset_off_rounded,
                        color: _isSimulationMode ? _gold : Colors.white.withValues(alpha: 0.6),
                        size: 22,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Practice Mode',
                              style: TextStyle(
                                color: _isSimulationMode ? _gold : Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              _isSimulationMode
                                  ? 'Viajes simulados activos'
                                  : 'Toca para activar viajes de práctica',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 46,
                        height: 26,
                        decoration: BoxDecoration(
                          color: _isSimulationMode
                              ? _gold
                              : Colors.grey.withValues(alpha: 0.4),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: AnimatedAlign(
                          duration: const Duration(milliseconds: 200),
                          alignment: _isSimulationMode
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            width: 22,
                            height: 22,
                            margin: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Divider(height: 1, color: borderC),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  S.of(context).recommendedForYou,
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _panelItem(
                Icons.bar_chart_rounded,
                S.of(context).seeEarningsTrends,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.push(
                    context,
                    slideFromRightRoute(const DriverEarningsScreen()),
                  );
                },
              ),
              _panelItem(
                Icons.star_outline_rounded,
                S.of(context).seeUpcomingPromotions,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.push(
                    context,
                    slideFromRightRoute(const DriverPromosScreen()),
                  );
                },
              ),
              _panelItem(
                Icons.access_time_rounded,
                S.of(context).seeDrivingTime,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.push(
                    context,
                    slideFromRightRoute(const DriverAnalyticsScreen()),
                  );
                },
              ),
              const SizedBox(height: 20),
              // GO OFFLINE button
              Center(
                child: GestureDetector(
                  onTap: _goOffline,
                  child: Column(
                    children: [
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(
                            0xFFCC3333,
                          ).withValues(alpha: 0.15),
                          border: Border.all(
                            color: const Color(
                              0xFFCC3333,
                            ).withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.pan_tool_rounded,
                          color: Color(0xFFCC3333),
                          size: 26,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        S.of(context).goOffline.toUpperCase(),
                        style: const TextStyle(
                          color: Color(0xFFCC3333),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        );
      },
    );
  }

  Widget _panelItem(
    IconData ic,
    String txt,
    Color iconC,
    Color textC,
    Color chevronC,
    VoidCallback tap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        onTap: () {
          HapticFeedback.selectionClick();
          tap();
        },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(ic, color: iconC, size: 22),
        title: Text(
          txt,
          style: TextStyle(
            color: textC,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: chevronC, size: 20),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  SHARED WIDGETS
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _slideToAction(
    String label,
    Color c,
    bool isDark,
    VoidCallback onDone,
  ) {
    final labelColor = isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.30);

    return StatefulBuilder(
      builder: (ctx, setLocal) {
        return Container(
          height: 56,
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: c.withValues(alpha: 0.18), width: 1.5),
          ),
          child: LayoutBuilder(
            builder: (_, cons) {
              final max = cons.maxWidth - 60;
              return Stack(
                children: [
                  Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: labelColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: FractionallySizedBox(
                        widthFactor: _slideVal,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                c.withValues(alpha: 0.12),
                                c.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: _slideVal * max + 4,
                    top: 4,
                    bottom: 4,
                    child: GestureDetector(
                      onHorizontalDragUpdate: (d) {
                        setLocal(() {
                          _slideVal += d.delta.dx / max;
                          _slideVal = _slideVal.clamp(0.0, 1.0);
                        });
                        if (_slideVal >= 0.88 && !_slid) {
                          _slid = true;
                          HapticFeedback.heavyImpact();
                          onDone();
                        }
                      },
                      onHorizontalDragEnd: (_) {
                        if (!_slid) setLocal(() => _slideVal = 0);
                      },
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: c.withValues(alpha: 0.35),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.black,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _bottomSheet(bool isDark, Color bg, Color shadowC, Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: _gold.withValues(alpha: 0.08))),
        boxShadow: [
          BoxShadow(
            color: shadowC,
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: child,
        ),
      ),
    );
  }

  Widget _wrapInDraggableSheet({
    required bool isDark,
    required Color surface,
    required Color shadowC,
    required Widget child,
    double minChildSize = 0.18,
  }) {
    final screenH = MediaQuery.of(context).size.height;
    return SizedBox(
      height: screenH,
      child: DraggableScrollableSheet(
        initialChildSize: minChildSize,
        minChildSize: minChildSize,
        maxChildSize: 0.85,
        snap: true,
        snapSizes: [minChildSize, 0.55, 0.85],
        builder: (ctx, scrollCtrl) {
          return Container(
            decoration: BoxDecoration(
              color: surface,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border(
                top: BorderSide(color: _gold.withValues(alpha: 0.08)),
              ),
              boxShadow: [
                BoxShadow(
                  color: shadowC,
                  blurRadius: 20,
                  offset: const Offset(0, -4),
                ),
              ],
            ),
            child: ListView(
              controller: scrollCtrl,
              physics: const BouncingScrollPhysics(),
              padding: EdgeInsets.zero,
              children: [
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
                    child: child,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _handle(bool isDark) => Center(
    child: Container(
      width: 40,
      height: 5,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(3),
      ),
    ),
  );

  Widget _fab(
    IconData ic,
    double sz,
    Color bg,
    Color border,
    Color iconColor,
    VoidCallback tap,
  ) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        tap();
      },
      child: Container(
        width: sz,
        height: sz,
        decoration: BoxDecoration(
          color: bg,
          shape: BoxShape.circle,
          border: Border.all(color: border),
        ),
        child: Icon(ic, color: iconColor, size: sz * 0.44),
      ),
    );
  }

  Widget _avatar(double s, {bool showBadge = false}) {
    final circle = Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(colors: [_gold, _goldLight]),
      ),
      child: Center(
        child: Text(
          _riderInit,
          style: TextStyle(
            color: Colors.black,
            fontSize: s * 0.42,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
    if (!showBadge) return circle;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        circle,
        Positioned(
          bottom: -2,
          right: -2,
          child: Container(
            width: s * 0.38,
            height: s * 0.38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _gold,
              border: Border.all(color: const Color(0xFF0A0A0A), width: 1.5),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.4),
                  blurRadius: 6,
                  spreadRadius: 1,
                ),
              ],
            ),
            child: Icon(
              Icons.check,
              color: Colors.black,
              size: s * 0.22,
            ),
          ),
        ),
      ],
    );
  }

  Widget _actionBtn(IconData ic, VoidCallback tap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        tap();
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.1),
          shape: BoxShape.circle,
          border: Border.all(color: _gold.withValues(alpha: 0.2)),
        ),
        child: Icon(ic, color: _gold, size: 18),
      ),
    );
  }

  Widget _cancelRow(bool isDark) => TextButton(
    onPressed: _cancel,
    child: Text(
      S.of(context).cancelTrip,
      style: TextStyle(
        color: isDark
            ? Colors.white.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.25),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _sumStat(String v, String l, Color vColor, Color lColor) => Column(
    children: [
      Text(
        v,
        style: TextStyle(
          color: vColor,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
      Text(l, style: TextStyle(color: lColor, fontSize: 10)),
    ],
  );
}

// ──────────────────────────────────────────────────
//  Pulsing radar for driver searching panel
// ──────────────────────────────────────────────────
class _DriverRadar extends StatefulWidget {
  final Color color;
  const _DriverRadar({required this.color});
  @override
  State<_DriverRadar> createState() => _DriverRadarState();
}

class _DriverRadarState extends State<_DriverRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _DriverRadarPainter(
          progress: _ctrl.value,
          color: widget.color,
        ),
      ),
    );
  }
}

class _DriverRadarPainter extends CustomPainter {
  final double progress;
  final Color color;
  _DriverRadarPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;

    for (int i = 0; i < 3; i++) {
      final wave = ((progress + i / 3.0) % 1.0);
      final radius = maxR * wave;
      final opacity = (1.0 - wave) * 0.6;
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(center, radius, paint);
    }

    // Center dot
    canvas.drawCircle(
      center,
      6,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_DriverRadarPainter old) => old.progress != progress;
}

/// Self-contained animated loading dots (gold, 3 dots, pulsing).
class _AnimatedLoadingDots extends StatefulWidget {
  @override
  State<_AnimatedLoadingDots> createState() => _AnimatedLoadingDotsState();
}

class _AnimatedLoadingDotsState extends State<_AnimatedLoadingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final phase = (_ctrl.value + i * 0.2) % 1.0;
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 2),
            width: 6,
            height: 6,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: const Color(0xFFD4AF37).withValues(alpha: 0.3 + phase * 0.7),
            ),
          );
        }),
      ),
    );
  }
}

/// Cached route segments for a pending offer.
class _CachedOfferRoute {
  final List<LatLng> segOne;
  final List<LatLng> segTwo;
  final DateTime cachedAt;
  final _PlaceType dropoffPlaceType;
  final Uint8List? driverPin;
  final Uint8List? pickupPin;
  final Uint8List? dropoffPin;
  const _CachedOfferRoute({
    required this.segOne,
    required this.segTwo,
    required this.cachedAt,
    this.dropoffPlaceType = _PlaceType.home,
    this.driverPin,
    this.pickupPin,
    this.dropoffPin,
  });
}

/// Place type for smart dropoff icon detection.
enum _PlaceType { home, commerce, hotel, airport }

_PlaceType _detectPlaceType(String address) {
  final lower = address.toLowerCase();
  bool has(List<String> kw) => kw.any((k) => lower.contains(k));

  if (has(['airport', 'aeropuerto', 'intl', 'international', 'terminal'])) {
    return _PlaceType.airport;
  }
  if (has(['hotel', 'inn', 'suites', 'resort', 'marriott', 'hilton',
           'hyatt', 'holiday', 'motel', 'lodge'])) {
    return _PlaceType.hotel;
  }
  if (has(['mall', 'plaza', 'center', 'centre', 'walmart', 'target',
           'store', 'market', 'shop', 'restaurant', 'cafe', 'bar',
           'gym', 'clinic', 'hospital', 'school', 'university'])) {
    return _PlaceType.commerce;
  }
  return _PlaceType.home;
}

IconData _dropoffIconFor(_PlaceType type) {
  switch (type) {
    case _PlaceType.airport:  return Icons.local_airport_rounded;
    case _PlaceType.hotel:    return Icons.apartment_rounded;
    case _PlaceType.commerce: return Icons.storefront_rounded;
    case _PlaceType.home:     return Icons.home_rounded;
  }
}

/// Map _PlaceType to GoldPinIcon for unified gold pins.
GoldPinIcon _goldPinIconFor(_PlaceType type) {
  switch (type) {
    case _PlaceType.airport:  return GoldPinIcon.airplane;
    case _PlaceType.hotel:    return GoldPinIcon.house;
    case _PlaceType.commerce: return GoldPinIcon.store;
    case _PlaceType.home:     return GoldPinIcon.house;
  }
}

// ═════════════════════════════════════════════════════════════════════════════
//  ROUTING DOTS ANIMATION — 3 bouncing gold dots for "Enrutando..." state
// ═════════════════════════════════════════════════════════════════════════════
class _RoutingDotsAnimation extends StatefulWidget {
  const _RoutingDotsAnimation();
  @override
  State<_RoutingDotsAnimation> createState() => _RoutingDotsAnimationState();
}

class _RoutingDotsAnimationState extends State<_RoutingDotsAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          final delay = i / 3;
          final progress = ((_ctrl.value - delay) % 1.0).clamp(0.0, 1.0);
          final scale = 0.6 + (math.sin(progress * math.pi) * 0.6);
          return Container(
            margin: const EdgeInsets.symmetric(horizontal: 4),
            child: Transform.scale(
              scale: scale,
              child: Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  color: Color(0xFFD4AF37),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

/// Paints an animated gold glow segment that follows the rounded top border
/// of the "Finding trips" panel, creating a premium search animation effect.
class _SearchingBorderPainter extends CustomPainter {
  final double progress; // 0.0 → 1.0, loops continuously
  static const double _borderRadius = 18.0;
  static const Color _gold = Color(0xFFD4AF37);
  static const Color _goldLight = Color(0xFFF5E6A3);

  _SearchingBorderPainter({required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    // Build path for the top portion of the rounded rect (pill-shaped top)
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndCorners(
      rect,
      topLeft: const Radius.circular(_borderRadius),
      topRight: const Radius.circular(_borderRadius),
    );

    // Subtle base border — always visible
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.0
        ..isAntiAlias = true
        ..color = _gold.withValues(alpha: 0.08),
    );

    // Build the border path from the RRect
    final borderPath = Path()..addRRect(rrect);
    final metricsList = borderPath.computeMetrics().toList();
    if (metricsList.isEmpty) return;
    final pm = metricsList.first;
    final total = pm.length;

    const glowFraction = 0.18; // 18% of perimeter
    final glowLen = total * glowFraction;
    final headDist = (progress * total) % total;

    // Divide glow tail into steps for the fade gradient
    const steps = 36;
    final stepLen = glowLen / steps;

    for (int k = 0; k < steps; k++) {
      final t = 1.0 - k / steps; // 1.0 at head → 0.0 at tail
      final fadeAlpha = t * t * (3 - 2 * t); // smoothstep
      if (fadeAlpha < 0.02) continue;

      final segEnd = (headDist - k * stepLen + total) % total;
      final segStart = (segEnd - stepLen + total) % total;

      // extractPath handles wrapping
      final Path seg;
      if (segStart <= segEnd) {
        seg = pm.extractPath(segStart, segEnd);
      } else {
        seg = pm.extractPath(segStart, total)
          ..addPath(pm.extractPath(0, segEnd), Offset.zero);
      }

      // Bright stroke
      canvas.drawPath(
        seg,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true
          ..color = Color.lerp(_gold, _goldLight, t)!
              .withValues(alpha: fadeAlpha * 0.9),
      );

      // Soft outer glow halo (every other step for perf)
      if (k % 2 == 0) {
        canvas.drawPath(
          seg,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 8
            ..strokeCap = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6)
            ..color = _goldLight.withValues(alpha: fadeAlpha * 0.25),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SearchingBorderPainter old) => old.progress != progress;
}
