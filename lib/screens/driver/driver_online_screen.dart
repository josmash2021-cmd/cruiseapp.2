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
import '../../widgets/map/circular_pin_renderer.dart';
import '../../services/gps_service.dart';
import '../../services/trip_firestore_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import '../home_screen.dart';
import 'driver_home_screen.dart';
import '../../services/map_launcher_service.dart';
import '../../services/preload_service.dart';
import '../../services/user_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/prefs_cache.dart';
import 'driver_trip_accept_screen.dart';
import 'trip_accepted_screen.dart';
import 'scheduled_rides_screen.dart';
import '../../services/notification_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../../widgets/tier_badge.dart';

part 'driver_online_controller.dart';
part 'driver_online_map.dart';
part 'driver_online_widgets.dart';

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
enum _OfferAcceptState { normal, routing }

enum _Phase {
  searching,
  rideRequest,
  enRouteToPickup,
  arrivedAtPickup,
  routeSummary, // Google Maps-style route overview before navigation
  inTrip,
  completed,
}

// Brand colors (top-level for extension access)
const _gold = Color(0xFFD4A843);
const _goldLight = Color(0xFFF5D990);
const _navyRoute = Color(0xFF5BA3F5);
const _navyGlow  = Color(0x405BA3F5);

class _DriverOnlineScreenState extends State<DriverOnlineScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  void _setState(VoidCallback fn) { setState(fn); }

  /// Sync the search-pulse animation to the current phase.
  /// Call this immediately after any setState block that changes _phase.
  void _syncSearchPulse() {
    if (_phase == _Phase.searching) {
      if (!_searchPulse.isAnimating) _searchPulse.repeat();
    } else {
      if (_searchPulse.isAnimating) _searchPulse.stop();
    }
  }

  // ── Map ──
  final _mapKey = GlobalKey();
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PointAnnotationManager? _pinAnnotMgr;   // teardrop pins (icon-anchor: bottom)
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
  DateTime _lastBackendLocSend = DateTime(0);
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
  bool _isPollingOffers = false;

  // ── Pulse animation on card tap ──
  AnimationController? _pulseCtrl;
  Animation<double>? _pulseAnim;
  bool _isCardAnimating = false;

  // ── Scheduled rides badge ──
  int _scheduledAvailCount = 0;
  int _prevScheduledCount = 0;
  Timer? _scheduledPollTimer;
  AnimationController? _scheduledBounceCtrl;
  Animation<double>? _scheduledBounceAnim;
  bool _showScheduledToast = false;
  String? _animatingOfferId; // which card is pulsing
  bool _offerDetailsVisible = false;

  // ── Reject slide-down animation ──
  String? _rejectingOfferId;
  AnimationController? _rejectSlideCtrl;

  // ── Accept card animation state ──
  _OfferAcceptState _offerAcceptState = _OfferAcceptState.normal;
  String? _acceptingCardId;
  final Set<String> _tappedCardIds = {};
  final Set<int> _rejectedOfferIds = {}; // locally rejected — filter from polls
  String? _lastAutoTriggeredOfferId; // prevent duplicate auto-trigger
  bool _isAcceptPressed = false;

  // ── Smooth route draw ──
  List<LatLng> _fullSegOne = [];
  List<LatLng> _fullSegTwo = [];
  Ticker? _routeDrawTicker;
  Ticker? _pinPopTicker;

  // ── Cinematic camera tilt/bearing for offer preview ──
  AnimationController? _offerTiltCtrl;
  Animation<double>? _offerTiltAnim;
  AnimationController? _offerBearingCtrl;
  Animation<double>? _offerBearingAnim;
  double _offerRandomBearing = 0;

  // ── Pre-fetched route cache (offerId → segments) ──
  final Map<String, _CachedOfferRoute> _routeCache = {};

  // ── Reverse-geocoded pickup addresses for generic labels ──
  final Map<String, String> _resolvedAddressCache = {};

  // â”€â”€ Request data (for active trip after acceptance) â”€â”€
  Timer? _pollT;
  StreamSubscription<List<Map<String, dynamic>>>? _offerSseSub;
  Timer? _sseReconnectTimer; // retries SSE after drop
  bool _sseActive = false;
  String _riderName = '';
  String _riderInit = '';
  String _riderPhotoUrl = '';
  String _riderPhone = '';
  String _riderId = '';
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
  Ticker? _smoothTicker;
  Duration _lastTickElapsed = Duration.zero;
  LatLng _targetPos = const LatLng(0, 0); // exponential decay target
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

  // -- 3D car icon for searching mode (replaces flat golden dot) --
  Uint8List? _searchingCarBytes;
  mapbox.PointAnnotation? _searchingCarAnnot;
  bool _searchingCarCreating = false;

  // -- Golden animated dot (legacy — kept for dispose safety) --
  final GoldLocationDot _goldDot = GoldLocationDot();
  Uint8List? _goldPinBytes;
  bool _dotPopDone = false;   // true after first-appearance pop completes
  double _dotPopScale = 0.0;  // 0→1.15→1.0 during pop, then 1.0
  bool _annotUpdateBusy = false; // prevents overlapping annotation updates

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
  double _panelFrac = 0.0; // 0 = collapsed pill, 1 = fully expanded
  AnimationController? _panelAnimCtrl;
  Animation<double>? _panelAnim;

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

  // -- Earnings refresh timer --
  Timer? _earningsRefreshTimer;
  // Track previous amounts for smooth TweenAnimationBuilder transitions
  double _prevEarnings = 0;
  double _prevWeeklyEarnings = 0;
  double _prevLastTripEarnings = 0;

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  LIFECYCLE
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  /// Bounce non-driver users back to the rider home screen.
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
    WidgetsBinding.instance.addObserver(this);
    // Apply initial position from home screen (avoids white flash)
    if (widget.initialPos != null) {
      _pos = widget.initialPos!;
      _heading = widget.initialHeading;
    }

    _driverAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    // Continuous 60fps ticker for ultra-smooth exponential decay movement.
    // Started lazily on first GPS update (_smoothMoveTo) to avoid burning CPU
    // before any position is available.
    _smoothTicker = createTicker(_onSmoothTick);

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
      duration: const Duration(milliseconds: 3000),
    );
    // Start repeating immediately — initial phase is searching.
    _searchPulse.repeat();
    _searchPulseVal = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _searchPulse, curve: Curves.linear),
    );

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

    // Scheduled badge bounce animation
    _scheduledBounceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _scheduledBounceAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.25).chain(CurveTween(curve: Curves.easeOut)), weight: 30),
      TweenSequenceItem(tween: Tween(begin: 1.25, end: 0.9).chain(CurveTween(curve: Curves.easeInOut)), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 0.9, end: 1.1).chain(CurveTween(curve: Curves.easeInOut)), weight: 25),
      TweenSequenceItem(tween: Tween(begin: 1.1, end: 1.0).chain(CurveTween(curve: Curves.easeOut)), weight: 20),
    ]).animate(_scheduledBounceCtrl!);

    // Show offer details immediately — no delay
    _offerDetailsVisible = true;

    _boot();
  }

  bool _appInForeground = true;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.paused) {
      _appInForeground = false;
      _pollT?.cancel();
      _offerSseSub?.cancel();
      _sseReconnectTimer?.cancel();
      _sseActive = false;
      _clock?.cancel();
      _earningsRefreshTimer?.cancel();
      _goldDot.dispose();
    } else if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
      // Reset sound guards so offer sounds play correctly after app resumes
      NotificationService.resetSoundGuards();
      _startPolling();
      _startClock();
      _startEarningsRefresh();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _smoothTicker?.stop();
    _smoothTicker?.dispose();
    _driverAnim.dispose();
    _reqCtrl.dispose();
    _doneCtrl.dispose();
    _searchPulse.dispose();
    _pollT?.cancel();
    _offerSseSub?.cancel();
    _sseReconnectTimer?.cancel();
    _scheduledPollTimer?.cancel();
    _clock?.cancel();
    _navTimer?.cancel();
    _goldDot.dispose();
    _driverPhotoImage?.dispose();
    _posStream?.cancel();
    _gpsService.stopTracking();
    _reFollowTimer?.cancel();
    _earningsRefreshTimer?.cancel();
    _panelAnimCtrl?.dispose();
    _offerPageCtrl.dispose();
    _routePulseCtrl?.dispose();
    _pulseCtrl?.dispose();
    _rejectSlideCtrl?.dispose();
    _scheduledBounceCtrl?.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _pinPopTicker?.stop();
    _pinPopTicker?.dispose();
    _offerTiltCtrl?.dispose();
    _offerBearingCtrl?.dispose();
    _map?.dispose();
    super.dispose();
  }

  // â”€â”€ Build Uber-style 3D car marker sprites at runtime â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  ui.Image? _driverPhotoImage; // decoded driver photo for marker

  /// Get the correct vehicle icon bytes based on the vehicle type.
  Uint8List? get _vehicleIconBytes {
    final vt = _vehicleType.trim().toLowerCase();
    if (vt.contains('suburban') || vt.contains('suv')) return _suvIconBytes;
    if (vt.contains('fusion') || vt.contains('camry') || vt.contains('sedan')) return _sedanIconBytes;
    if (vt.contains('cruisex') || vt.contains('cruise')) return _sedanIconBytes;
    return _suvIconBytes;
  }

  bool _approvalGatePassed = false;

  bool _nearPickupNotified = false;
  bool _nearDropoffNotified = false;


  double _targetHeading = 0;
  int _lastUiRebuildMs = 0; // throttle: only rebuild widget tree at ~15fps
  double? _lastCamLat;  // for gentle camera follow in searching mode
  double? _lastCamLng;

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
        _fetchRouteWithMetrics(_pos!, pickupLL),                                    // [0] segOne + metrics
        _fetchRouteWithMetrics(pickupLL, dropoffLL),                                // [1] segTwo + metrics
        renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32),  // [2] pickup pin
        renderCircularPinBytes(icon: _goldPinIconFor(placeType), isPickup: false, radius: 32), // [3] dropoff pin
      ]).then((results) {
        if (!mounted) return;
        final seg1 = results[0] as ({List<LatLng> pts, double? durSec, double? distM});
        final seg2 = results[1] as ({List<LatLng> pts, double? durSec, double? distM});
        _routeCache[oid] = _CachedOfferRoute(
          segOne: seg1.pts,
          segTwo: seg2.pts,
          cachedAt: DateTime.now(),
          dropoffPlaceType: placeType,
          pickupPin: results[2] as Uint8List?,
          dropoffPin: results[3] as Uint8List?,
          driverToPickupMin: seg1.durSec != null ? seg1.durSec! / 60.0 : null,
          driverToPickupKm: seg1.distM != null ? seg1.distM! / 1000.0 : null,
          pickupToDropoffMin: seg2.durSec != null ? seg2.durSec! / 60.0 : null,
          pickupToDropoffKm: seg2.distM != null ? seg2.distM! / 1000.0 : null,
        );
        if (_pendingOffers.isNotEmpty) setState(() {});
      }).catchError((_) {});

      // Reverse-geocode generic pickup addresses
      final rawPickupAddr = (offer['pickup_address'] ?? '') as String;
      final addrKey = '${pLat}_$pLng';
      if (!_resolvedAddressCache.containsKey(addrKey) &&
          _isGenericAddress(rawPickupAddr)) {
        _reverseGeocode(pLat, pLng).then((resolved) {
          if (resolved != null && mounted) {
            _resolvedAddressCache[addrKey] = resolved;
            if (_pendingOffers.isNotEmpty) setState(() {});
          }
        });
      }
    }
  }

  /// Whether an address string is generic / placeholder and needs reverse geocoding.
  bool _isGenericAddress(String addr) {
    if (addr.isEmpty) return true;
    final lower = addr.toLowerCase().trim();
    return lower == 'current location' ||
        lower == 'ubicación actual' ||
        lower == 'pickup' ||
        lower == 'mi ubicación';
  }

  /// Reverse-geocode coordinates → street address via Mapbox Geocoding API.
  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final url = Uri.parse(
        'https://api.mapbox.com/geocoding/v5/mapbox.places/$lng,$lat.json'
        '?types=address,poi&limit=1&access_token=${MapboxConfig.accessToken}',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final features = data['features'] as List?;
        if (features != null && features.isNotEmpty) {
          return (features[0]['place_name'] as String?)
              ?.replaceAll(RegExp(r',\s*United States$'), '')
              .replaceAll(RegExp(r',\s*Puerto Rico$'), '');
        }
      }
    } catch (_) {}
    return null;
  }

  /// Fetch route points + duration/distance from Directions APIs.
  /// Returns (points, durationSeconds, distanceMeters).
  Future<({List<LatLng> pts, double? durSec, double? distM})> _fetchRouteWithMetrics(LatLng o, LatLng d) async {
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
          final route = data['routes'][0];
          final pts = _decodePoly(route['overview_polyline']['points'] as String);
          final leg = (route['legs'] as List?)?.firstOrNull;
          final dur = (leg?['duration']?['value'] as num?)?.toDouble();
          final dist = (leg?['distance']?['value'] as num?)?.toDouble();
          return (pts: pts, durSec: dur, distM: dist);
        }
      }
    } catch (_) {}
    // OSRM fallback
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
          final r = routes[0];
          final pts = _decodePoly(r['geometry'] as String);
          final dur = (r['duration'] as num?)?.toDouble();
          final dist = (r['distance'] as num?)?.toDouble();
          return (pts: pts, durSec: dur, distM: dist);
        }
      }
    } catch (_) {}
    // Mapbox Directions API fallback
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
          final r = mbxRoutes[0];
          final coords = r['geometry']?['coordinates'] as List?;
          if (coords != null && coords.isNotEmpty) {
            final pts = coords
                .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
            final dur = (r['duration'] as num?)?.toDouble();
            final dist = (r['distance'] as num?)?.toDouble();
            return (pts: pts, durSec: dur, distM: dist);
          }
        }
      }
    } catch (_) {}
    // Straight line fallback — no metrics
    final pts = List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        o.latitude + (d.latitude - o.latitude) * t,
        o.longitude + (d.longitude - o.longitude) * t,
      );
    });
    return (pts: pts, durSec: null, distM: null);
  }

  String get _timeStr {
    final h = _online.inHours,
        m = _online.inMinutes.remainder(60),
        s = _online.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Pause availability temporarily — driver stays online but won't receive offers.
  bool _isPaused = false;
  Timer? _pauseTimer;

  /// Dynamic bottom padding for the GoogleMap based on active overlays
  double get _mapBottomPadding {
    final screenH = MediaQuery.of(context).size.height;
    if (_previewingOffer != null) return screenH * 0.48;
    if (_phase == _Phase.searching && _pendingOffers.isNotEmpty) return screenH * 0.48;
    if (_phase == _Phase.enRouteToPickup) return 270;
    if (_phase == _Phase.arrivedAtPickup) return 290;
    if (_phase == _Phase.routeSummary) return 330;
    if (_phase == _Phase.inTrip) return 270;
    return 200;
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
          clipBehavior: Clip.none,
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
                  ],
                ),
              ),

            // â”€â”€ Side floating buttons (only when searching with no offers) â”€â”€
            // ── Scheduled rides badge (top-right, always visible, hidden during nav) ──
            if (!isNav)
              Positioned(
                top: top + 10,
                right: 16,
                child: ScaleTransition(
                  scale: _scheduledBounceAnim ?? const AlwaysStoppedAnimation(1.0),
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.mediumImpact();
                      _setState(() => _showScheduledToast = false);
                      Navigator.push(
                        context,
                        slideFromRightRoute(
                          const ScheduledRidesScreen(initialTab: 0),
                        ),
                      ).then((_) => _fetchScheduledCount());
                    },
                    child: Container(
                      width: 48,
                      height: 48,
                      decoration: BoxDecoration(
                        color: fabBg,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _scheduledAvailCount > 0
                              ? const Color(0xFFE8C547).withValues(alpha: 0.6)
                              : fabBorder,
                          width: 1,
                        ),
                        boxShadow: _scheduledAvailCount > 0
                            ? [
                                BoxShadow(
                                  color: const Color(0xFFE8C547).withValues(alpha: 0.25),
                                  blurRadius: 10,
                                  spreadRadius: 1,
                                ),
                              ]
                            : null,
                      ),
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          Center(
                            child: Icon(
                              Icons.calendar_today_rounded,
                              size: 22,
                              color: _scheduledAvailCount > 0
                                  ? const Color(0xFFE8C547)
                                  : Colors.white.withValues(alpha: 0.35),
                            ),
                          ),
                          if (_scheduledAvailCount > 0)
                            Positioned(
                              top: -4,
                              right: -4,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: BoxDecoration(
                                  color: const Color(0xFFE8C547),
                                  shape: BoxShape.circle,
                                  border: Border.all(color: Colors.black, width: 1.5),
                                ),
                                child: Text(
                                  '$_scheduledAvailCount',
                                  style: const TextStyle(
                                    color: Colors.black,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w800,
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

            // ── Scheduled rides toast notification ──
            if (!isNav && _showScheduledToast && _scheduledAvailCount > 0)
              Positioned(
                top: top + 68,
                right: 16,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutBack,
                  builder: (context, value, child) => Transform.scale(
                    scale: value,
                    alignment: Alignment.topRight,
                    child: Opacity(opacity: value.clamp(0.0, 1.0), child: child),
                  ),
                  child: GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      _setState(() => _showScheduledToast = false);
                      Navigator.push(
                        context,
                        slideFromRightRoute(const ScheduledRidesScreen(initialTab: 0)),
                      ).then((_) => _fetchScheduledCount());
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1D24),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: const Color(0xFFE8C547).withValues(alpha: 0.4),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFE8C547).withValues(alpha: 0.15),
                            blurRadius: 12,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.calendar_today_rounded,
                            color: Color(0xFFE8C547),
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _scheduledAvailCount == 1
                                ? '1 scheduled ride available'
                                : '$_scheduledAvailCount scheduled rides available',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFFE8C547),
                            size: 16,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

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
                bottom: -30,
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
                  () => _closePreview(),
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
                      child: Stack(
                        children: [
                          _floatingPanel(
                            isDark,
                            surface,
                            textMuted,
                            borderC,
                            textPrimary,
                            shadowC,
                          ),
                        ],
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


/// Cached route segments for a pending offer.
class _CachedOfferRoute {
  final List<LatLng> segOne;
  final List<LatLng> segTwo;
  final DateTime cachedAt;
  final _PlaceType dropoffPlaceType;
  final Uint8List? pickupPin;
  final Uint8List? dropoffPin;
  final double? driverToPickupMin;
  final double? driverToPickupKm;
  final double? pickupToDropoffMin;
  final double? pickupToDropoffKm;
  const _CachedOfferRoute({
    required this.segOne,
    required this.segTwo,
    required this.cachedAt,
    this.dropoffPlaceType = _PlaceType.home,
    this.pickupPin,
    this.dropoffPin,
    this.driverToPickupMin,
    this.driverToPickupKm,
    this.pickupToDropoffMin,
    this.pickupToDropoffKm,
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

/// Map _PlaceType to CircularPinIcon for unified circular pins.
CircularPinIcon _goldPinIconFor(_PlaceType type) {
  switch (type) {
    case _PlaceType.airport:  return CircularPinIcon.airplane;
    case _PlaceType.hotel:    return CircularPinIcon.home;
    case _PlaceType.commerce: return CircularPinIcon.store;
    case _PlaceType.home:     return CircularPinIcon.home;
  }
}

/// Paints an animated gold glow segment around the "Finding trips" panel.
/// Uses 48 micro-segments for a smooth, fluid gradient — no pixelation.
/// [expansion] 0.0 = collapsed (glow runs around ALL 4 sides),
///             1.0 = expanded  (glow runs only across the top edge).
class _SearchingBorderPainter extends CustomPainter {
  final double progress; // 0.0 → 1.0, loops continuously
  final double expansion; // 0.0 = collapsed, 1.0 = expanded
  static const Color _gold = Color(0xFFE8C547);
  static const Color _goldLight = Color(0xFFFBE47A);

  _SearchingBorderPainter({required this.progress, this.expansion = 0.0});

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final botRadius = 20.0 * (1.0 - expansion);
    final rrect = RRect.fromRectAndCorners(
      rect,
      topLeft: const Radius.circular(20),
      topRight: const Radius.circular(20),
      bottomLeft: Radius.circular(botRadius),
      bottomRight: Radius.circular(botRadius),
    );

    // Subtle base border — always visible
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..isAntiAlias = true
        ..color = _gold.withValues(alpha: 0.12),
    );

    // Build path from RRect — Flutter Bézier curves = mathematically smooth corners
    final borderPath = Path()..addRRect(rrect);
    final metricsList = borderPath.computeMetrics().toList();
    if (metricsList.isEmpty) return;
    final pm = metricsList.first;
    final total = pm.length;

    const glowFraction = 0.18;
    final glowLen = total * glowFraction;
    final headDist = (progress * total) % total;

    // 48 micro-segments with smoothstep fade — identical to rider Where-to panel
    const steps = 48;
    final stepLen = glowLen / steps;

    for (int k = 0; k < steps; k++) {
      final t = 1.0 - k / steps; // 1.0 at head → 0.0 at tail
      final fadeAlpha = t * t * (3 - 2 * t); // smoothstep
      if (fadeAlpha < 0.02) continue;

      final segEnd   = (headDist - k * stepLen + total) % total;
      final segStart = (segEnd - stepLen + total) % total;

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
          ..style      = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap  = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true
          ..color = Color.lerp(_gold, _goldLight, t)!
              .withValues(alpha: fadeAlpha * 0.95),
      );

      // Soft outer glow halo (every other step for perf)
      if (k % 2 == 0) {
        canvas.drawPath(
          seg,
          Paint()
            ..style      = PaintingStyle.stroke
            ..strokeWidth = 12
            ..strokeCap  = StrokeCap.round
            ..strokeJoin = StrokeJoin.round
            ..isAntiAlias = true
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
            ..color = _goldLight.withValues(alpha: fadeAlpha * 0.30),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_SearchingBorderPainter old) =>
      old.progress != progress || old.expansion != expansion;
}
