import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/scheduler.dart';
import 'package:geocoding/geocoding.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../config/mapbox_config.dart';
import '../config/map_theme.dart';
import 'package:geolocator/geolocator.dart';
import '../services/preload_service.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'airport_terminal_sheet.dart';
import 'identity_verification_screen.dart';
import 'map_picker_screen.dart';
import 'map_screen.dart';
import 'pickup_dropoff_search_screen.dart';
import 'ride_request_screen.dart';
import 'rider_tracking_screen.dart';
import 'scheduled_rides_screen.dart';
import 'schedule_picker_sheet.dart';
import 'trip_receipt_screen.dart';
import 'account_screen.dart';
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import '../services/places_service.dart';
import '../l10n/app_localizations.dart';
import 'package:intl/intl.dart';
import '../services/user_session.dart';
import 'welcome_screen.dart';
import 'account_deactivated_screen.dart';
import '../widgets/gold_location_dot.dart';
import '../widgets/smart_map_pin.dart';
import '../widgets/user_profile_photo.dart';
import '../widgets/verified_avatar.dart';
import '../widgets/offline_banner.dart';
import 'package:firebase_database/firebase_database.dart';
import '../utils/responsive.dart';
import '../utils/name_helper.dart' as nh;

part 'home_screen_controller.dart';
part 'home_screen_map.dart';
part 'home_screen_widgets.dart';

class HomeScreen extends StatefulWidget {
  final bool forceExpandPanel;
  const HomeScreen({super.key, this.forceExpandPanel = false});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}


const _gold = Color(0xFFE8C547);
const _goldLight = Color(0xFFFBE47A);
const double _kMinSheet = 0.42;
const double _kMaxSheet = 1.0; // Full screen when expanded
const int _locAnimDurationMs = 1200; // smooth glide between updates

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
  void _setState(VoidCallback fn) { setState(fn); }
  // Brand colors — premium shiny gold

  late AnimationController _shimmerController;
  late AnimationController _boltFlashCtrl;
  late AnimationController _clockRotateCtrl;
  late AnimationController _promoShimmerCtrl;
  bool _promoUsed = false;
  int _promoTripsLeft = 0; // trips needed to unlock next promo
  bool _rideNow = true;
  bool _driversOnline = false;
  List<FavoritePlace> _favorites = [];
  List<TripHistoryItem> _recentTrips = [];
  List<FrequentDestination> _topDestinations = [];
  List<AppNotificationItem> _notifications = [];
  bool _loadingSavedData = true;
  bool _hasActivePromo = false;
  int _dockIndex = 0; // 0=Ride, 1=Schedule, 2=Account
  bool _fleetExpanded = true;

  // Scheduled ride indicator
  Map<String, dynamic>? _nextScheduledRide;

  // Imminent scheduled ride (≤30 min away)
  Timer? _imminentRideTimer;
  int _minutesUntilRide = 0;

  bool get _hasImminentRide {
    if (_nextScheduledRide == null || _activeRide != null) return false;
    final sa = _nextScheduledRide!['scheduled_at']?.toString();
    if (sa == null) return false;
    final dt = DateTime.tryParse(sa);
    if (dt == null) return false;
    final diff = dt.difference(DateTime.now()).inMinutes;
    return diff <= 30 && diff >= 0;
  }

  void _updateImminentRide() {
    if (_nextScheduledRide == null) {
      _minutesUntilRide = 0;
      return;
    }
    final sa = _nextScheduledRide!['scheduled_at']?.toString();
    if (sa == null) return;
    final dt = DateTime.tryParse(sa);
    if (dt == null) return;
    final diff = dt.difference(DateTime.now()).inMinutes;
    if (mounted) setState(() => _minutesUntilRide = diff.clamp(0, 9999));
  }

  // Active ride state
  ActiveRideInfo? _activeRide;

  // Pending search state — trip exists but no driver yet (reopen/reinstall)
  int? _pendingSearchTripId;
  Timer? _pendingSearchTimer;

  // Panel lock — keeps sheet fully expanded while trip is active
  bool _panelLocked = false;

  // Progress bar countdown state
  int _totalSeconds = 0;
  int _remainingSeconds = 0;
  Timer? _countdownTimer;

  // Verification state — eagerly loaded to prevent banner flash
  bool _isVerified = LocalDataService.isVerifiedSync;
  String _verificationStatus = LocalDataService.isVerifiedSync ? 'approved' : '';
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _verificationSub;

  // Service zone state
  Set<String> _activeServiceStates = {};
  String _userStateName = '';
  bool _serviceZoneActive = true; // default true until Firestore loads
  bool _stateCheckDone = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _zonesSub;

  // ── Map-first draggable sheet ──
  final DraggableScrollableController _sheetController = DraggableScrollableController();
  final GlobalKey _mapKey = GlobalKey();

  // User profile data
  String _firstName = '';
  String _lastName = '';
  String? _photoPath;
  String? _photoUrl;

  // ── Preloaded sound players ──
  final Map<String, AudioPlayer> _soundPlayers = {};

  // Mini-map state
  mapbox.MapboxMap? _miniMapController;
  mapbox.PointAnnotationManager? _miniMapAnnotMgr;
  mapbox.PointAnnotation? _miniMapAnnot;
  LatLng? _currentLatLng;
  String? _locationError;
  bool _imagesPrecached = false;
  StreamSubscription<Position>? _locationSub;
  final GoldLocationDot _miniDot = GoldLocationDot();
  bool _updatingMiniMapAnnot = false; // guard: prevents concurrent annotation updates

  // ── Smooth location interpolation ──
  Ticker? _locTicker;
  LatLng? _locAnimFrom;      // start of interpolation
  LatLng? _locAnimTo;        // target (latest GPS)
  double _locAnimProgress = 1.0; // 0→1
  Duration _locAnimStart = Duration.zero;
  bool _locAnimNeedsRestart = false;

  // ── Active trip driver tracking ──
  LatLng? _driverLocation;
  double _driverBearing = 0.0;
  mapbox.PointAnnotation? _driverMarkerAnnot;
  mapbox.PolylineAnnotation? _tripRouteAnnot;
  StreamSubscription<DatabaseEvent>? _driverLocationSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _tripDocSub;
  Ticker? _driverTicker;
  LatLng? _driverAnimFrom;
  LatLng? _driverAnimTo;
  double _driverAnimProgress = 1.0;
  Duration _driverAnimStart = Duration.zero;
  bool _driverAnimNeedsRestart = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _tripStatusSub;
  String? _trackedDriverId;

  DateTime? _tripStartTime;

  // ── Live route on home map ──
  mapbox.PolylineAnnotationManager? _miniMapPolyMgr;
  mapbox.PointAnnotationManager? _miniMapCarMgr;
  mapbox.PointAnnotation? _driverCarAnnot;
  mapbox.PointAnnotation? _dropoffPinAnnot;
  Uint8List? _cachedCarBytes; // avoid rootBundle.load on every driver update
  bool _rideRouteDrawn = false;
  double _routeProgress = 0.0; // 0→1 based on driver position along route
  List<LatLng> _routeLatLngs = []; // cached route points

  // ── Ride completion fade ──
  late AnimationController _rideFadeCtrl;
  bool _didAutoResumeRide = false; // prevent re-opening tracking on every _loadSavedData

  /// Interpolated position for the current animation frame.
  LatLng get _interpolatedLatLng {
    if (_locAnimFrom == null || _locAnimTo == null) return _currentLatLng ?? const LatLng(0, 0);
    final t = _easedProgress(_locAnimProgress);
    return LatLng(
      _locAnimFrom!.latitude + (_locAnimTo!.latitude - _locAnimFrom!.latitude) * t,
      _locAnimFrom!.longitude + (_locAnimTo!.longitude - _locAnimFrom!.longitude) * t,
    );
  }

  /// Interpolated driver car position.
  LatLng get _interpolatedDriverLoc {
    if (_driverAnimFrom == null || _driverAnimTo == null) return _driverLocation ?? const LatLng(0, 0);
    final t = _easedProgress(_driverAnimProgress);
    return LatLng(
      _driverAnimFrom!.latitude + (_driverAnimTo!.latitude - _driverAnimFrom!.latitude) * t,
      _driverAnimFrom!.longitude + (_driverAnimTo!.longitude - _driverAnimFrom!.longitude) * t,
    );
  }

  /// Called by the Ticker on every vsync frame during location animation.
  int _lastAnnotUpdateMs = 0;

  Future<void> _updateMiniMapAnnotation() async {
    // Guard: prevent concurrent updates that create multiple pins
    if (_updatingMiniMapAnnot) return;
    _updatingMiniMapAnnot = true;
    
    try {
      final mgr = _miniMapAnnotMgr;
      if (mgr == null) return;

      // Hide gold dot when an active ride route is drawn (route + car + dropoff shown instead)
      if (_rideRouteDrawn && _activeRide != null) {
        if (_miniMapAnnot != null) {
          try { await mgr.delete(_miniMapAnnot!); } catch (_) {}
          _miniMapAnnot = null;
        }
        return;
      }

      final bytes = _miniDot.currentBytes;
      if (bytes == null) return;
      final pos = _interpolatedLatLng;
      
      // If annotation already exists → update in-place (no delete+create)
      if (_miniMapAnnot != null) {
        try {
          _miniMapAnnot!.geometry = mapbox.Point(
            coordinates: mapbox.Position(pos.longitude, pos.latitude),
          );
          _miniMapAnnot!.image = bytes;
          await mgr.update(_miniMapAnnot!);
        } catch (_) {
          // If update fails (e.g. annotation was invalidated), recreate
          _miniMapAnnot = null;
        }
      }
      
      // Create annotation only if it doesn't exist yet
      if (_miniMapAnnot == null && _currentLatLng != null) {
        _miniMapAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(pos.longitude, pos.latitude)),
          image: bytes,
          iconSize: 1.3,
          iconAnchor: mapbox.IconAnchor.CENTER,
          iconOffset: [0, 0],
        ));
      }
    } finally {
      _updatingMiniMapAnnot = false;
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _shimmerController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
    _boltFlashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _clockRotateCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 6),
    )..repeat();
    _promoShimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _rideFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1.0, // fully visible
    );
    // Flash bolt every 2 seconds
    Future.doWhile(() async {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return false;
      _boltFlashCtrl.forward().then((_) {
        if (mounted) _boltFlashCtrl.reverse();
      });
      return mounted;
    });
    _loadSavedData();
    _loadPromoUsed();
    _preloadSounds();
    _fetchCurrentLocation();
    // Eagerly load cached user name so greeting never shows "Rider"
    UserSession.getUser().then((user) {
      if (user != null && mounted && _firstName.isEmpty) {
        setState(() {
          _firstName = user['firstName'] ?? '';
          _lastName = user['lastName'] ?? '';
          final path = user['photoPath'] ?? '';
          _photoPath = path.isNotEmpty ? path : null;
          final url = user['photoUrl'] ?? UserSession.photoUrlNotifier.value;
          _photoUrl = url.isNotEmpty ? url : null;
        });
      }
    });
    _miniDot.build(() {
      if (mounted) _updateMiniMapAnnotation();
    });
    _checkDriversOnline();
    _listenServiceZones();
    _listenVerificationStatus();
    _driverCheckTimer = Timer.periodic(
      const Duration(seconds: 120),
      (_) => _checkDriversOnline(),
    );
    // Imminent ride timer — refreshes every 60 seconds
    _imminentRideTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _updateImminentRide(),
    );
    // Start account status polling immediately
    _checkAccountStatus();
    _accountStatusTimer = Timer.periodic(
      const Duration(seconds: 300),
      (_) => _checkAccountStatus(),
    );
    UserSession.photoNotifier.addListener(_onPhotoChanged);
    UserSession.photoUrlNotifier.addListener(_onPhotoChanged);

    // If returning from tracking screen, lock panel open
    if (widget.forceExpandPanel) {
      _panelLocked = true;
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_imagesPrecached) {
      _imagesPrecached = true;
      // Precache car images so they display instantly
      for (final img in ['suburban', 'camry', 'fusion']) {
        precacheImage(AssetImage('assets/images/$img.png'), context);
      }
      for (final img in ['cruisert1', 'cruisert2', 'cruisert3']) {
        precacheImage(AssetImage('assets/images/$img.png'), context);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _driverCheckTimer?.cancel();
      _accountStatusTimer?.cancel();
      _countdownTimer?.cancel();
      _imminentRideTimer?.cancel();
      // Pause animations to save CPU/GPU when backgrounded
      _shimmerController.stop();
      _clockRotateCtrl.stop();
      _promoShimmerCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      // Resume looping animations
      _shimmerController.repeat();
      _clockRotateCtrl.repeat();
      _promoShimmerCtrl.repeat();
      _checkDriversOnline();
      _driverCheckTimer?.cancel();
      _driverCheckTimer = Timer.periodic(
        const Duration(seconds: 120),
        (_) => _checkDriversOnline(),
      );
      _checkAccountStatus();
      _accountStatusTimer?.cancel();
      _accountStatusTimer = Timer.periodic(
        const Duration(seconds: 300),
        (_) => _checkAccountStatus(),
      );
      _updateImminentRide();
      _imminentRideTimer?.cancel();
      _imminentRideTimer = Timer.periodic(
        const Duration(seconds: 60),
        (_) => _updateImminentRide(),
      );
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    UserSession.photoNotifier.removeListener(_onPhotoChanged);
    UserSession.photoUrlNotifier.removeListener(_onPhotoChanged);
    _sheetController.dispose();
    _miniDot.dispose();
    _locTicker?.dispose();
    _driverTicker?.dispose();
    _shimmerController.dispose();
    _boltFlashCtrl.dispose();
    _clockRotateCtrl.dispose();
    _promoShimmerCtrl.dispose();
    _rideFadeCtrl.dispose();
    _driverCheckTimer?.cancel();
    _accountStatusTimer?.cancel();
    _countdownTimer?.cancel();
    _imminentRideTimer?.cancel();
    _pendingSearchTimer?.cancel();
    _locationSub?.cancel();
    _zonesSub?.cancel();
    _driverLocationSub?.cancel();
    _tripDocSub?.cancel();
    _tripStatusSub?.cancel();
    _verificationSub?.cancel();
    for (final player in _soundPlayers.values) {
      player.dispose();
    }
    super.dispose();
  }

  /// Preload ride-related sounds during init so they play instantly later.
  void _preloadSounds() {
    const sounds = ['cruise_online', 'cruise_offer'];
    for (final s in sounds) {
      final player = AudioPlayer();
      player.setSource(AssetSource('sounds/$s.wav')).catchError((_) {});
      _soundPlayers[s] = player;
    }
  }

  Future<void> _checkUserStateZone(LatLng position) async {
    try {
      final placemarks = await placemarkFromCoordinates(
        position.latitude,
        position.longitude,
      );
      if (placemarks.isEmpty || !mounted) return;
      final state = placemarks.first.administrativeArea ?? '';
      setState(() {
        _userStateName = state;
        if (_activeServiceStates.isEmpty) {
          _serviceZoneActive = true;
        } else {
          _serviceZoneActive = _activeServiceStates.contains(state);
        }
      });
    } catch (_) {
      // Geocoding failed → do not block the user
      if (mounted) setState(() => _serviceZoneActive = true);
    }
  }

  /// Returns true if the rider is identity-verified.
  /// If not verified, shows the verification flow and returns false.
  Future<bool> _ensureVerified() async {
    final verified = await LocalDataService.isIdentityVerified();
    if (verified) {
      if (!_isVerified && mounted) setState(() => _isVerified = true);
      return true;
    }
    if (!mounted) return false;
    final result = await Navigator.of(
      context,
    ).push<bool>(slideUpFadeRoute(const IdentityVerificationScreen()));
    if (result == true) {
      if (mounted) setState(() => _isVerified = true);
      return true;
    }
    return false;
  }

  Future<void> _fetchCurrentLocation() async {
    try {
      // Use pre-loaded GPS from splash if available (instant)
      final preloaded = PreloadService.initialPosition;
      if (preloaded != null && mounted) {
        setState(() {
          _currentLatLng = LatLng(preloaded.latitude, preloaded.longitude);
          _locationError = null;
        });
        _locAnimFrom = _currentLatLng;
        _locAnimTo = _currentLatLng;
        _locAnimProgress = 1.0;
        _miniMapController?.flyTo(
          mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(_currentLatLng!.longitude, _currentLatLng!.latitude))),
          mapbox.MapAnimationOptions(duration: 400),
        );
        _updateMiniMapAnnotation();
        if (!_stateCheckDone) {
          _stateCheckDone = true;
          _checkUserStateZone(_currentLatLng!);
        }
        // Still refresh in background for more accurate position
        _refreshGpsInBackground();
        return;
      }

      // 1. Check if location services are enabled
      bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        if (mounted) {
          setState(() => _locationError = S.of(context).locationServicesDisabled);
        }
        return;
      }

      // 2. Check / request permission
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) {
          if (mounted) {
            setState(() => _locationError = S.of(context).locationPermissionDenied);
          }
          return;
        }
      }
      if (perm == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _locationError = S.of(context).locationDeniedForever);
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationPermissionPermanentlyDeniedMsg),
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

      // 3. Try last known first for instant display
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && mounted) {
        setState(() {
          _currentLatLng = LatLng(lastKnown.latitude, lastKnown.longitude);
          _locationError = null;
        });
      }

      // 4. Fetch accurate position
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      setState(() {
        _currentLatLng = LatLng(pos.latitude, pos.longitude);
        _locationError = null;
      });
      // Set initial position without animation (first fix)
      _locAnimFrom = _currentLatLng;
      _locAnimTo = _currentLatLng;
      _locAnimProgress = 1.0;
      _miniMapController?.flyTo(
        mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(_currentLatLng!.longitude, _currentLatLng!.latitude))),
        mapbox.MapAnimationOptions(duration: 800),
      );
      _updateMiniMapAnnotation();

      // Check service zone for this position (once)
      if (!_stateCheckDone) {
        _stateCheckDone = true;
        _checkUserStateZone(_currentLatLng!);
      }

      // Start continuous location stream for always-centered map
      _locationSub?.cancel();
      _locationSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.high,
              distanceFilter: 10,
            ),
          ).listen((Position p) {
            if (!mounted) return;
            final ll = LatLng(p.latitude, p.longitude);
            _currentLatLng = ll;
            _miniDot.setTarget(ll.latitude, ll.longitude);
            _animateToLocation(ll);
          });
    } catch (e) {
      if (mounted && _currentLatLng == null) {
        setState(() => _locationError = S.of(context).unableToGetLocation);
      }
    }
  }

  Timer? _driverCheckTimer;
  Timer? _accountStatusTimer;


  Future<void> _checkAccountStatus() async {
    try {
      final status = await ApiService.getAccountStatus();
      if (!mounted) return;
      if (status == 'blocked' || status == 'deleted') {
        _accountStatusTimer?.cancel();
        await UserSession.logout();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          smoothFadeRoute(const WelcomeScreen()),
          (_) => false,
        );
      } else if (status == 'deactivated') {
        _accountStatusTimer?.cancel();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          smoothFadeRoute(const AccountDeactivatedScreen()),
          (_) => false,
        );
      }
    } catch (_) {}
  }

  Future<void> _loadPromoUsed() async {
    final used = await LocalDataService.getPromoUsed();
    final prefs = await SharedPreferences.getInstance();
    final tripsLeft = prefs.getInt('promo_trips_left') ?? 0;
    if (mounted) {
      setState(() {
        _promoUsed = used && tripsLeft > 0;
        _promoTripsLeft = tripsLeft;
      });
    }
  }

  Future<void> _checkDriversOnline() async {
    try {
      if (_currentLatLng == null) return;
      final lat = _currentLatLng!.latitude;
      final lng = _currentLatLng!.longitude;
      final count = await ApiService.getNearbyDriversCount(lat: lat, lng: lng);
      if (mounted) setState(() => _driversOnline = count > 0);
    } catch (_) {
      if (mounted) setState(() => _driversOnline = false);
    }
  }

  Future<void> _showPromoWelcomeDialog() async {
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        final c = AppColors.of(ctx);
        return AlertDialog(
          backgroundColor: c.panel,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          contentPadding: const EdgeInsets.fromLTRB(28, 28, 28, 12),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFE8C547), Color(0xFFFBE47A)],
                  ),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.card_giftcard_rounded,
                  color: Colors.black,
                  size: 32,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                S.of(context).welcomeGift,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              Text(
                S.of(context).promoWelcomeBody,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE8C547),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: Text(
                    S.of(context).applyAndRide,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              const SizedBox(height: 8),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: Text(
                  S.of(context).cancel,
                  style: TextStyle(color: c.textTertiary, fontSize: 14),
                ),
              ),
            ],
          ),
        );
      },
    );

    if (confirmed == true && mounted) {
      // Mark promo as used and set 3-trip counter for next unlock
      await LocalDataService.setPromoUsed();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt('promo_trips_left', 3);
      if (mounted) {
        setState(() {
          _promoUsed = true;
          _promoTripsLeft = 3;
        });
      }
      if (!await _ensureVerified()) return;
      if (!mounted) return;
      Navigator.of(
        context,
      ).push(slideUpFadeRoute(const RideRequestScreen(applyPromo: true)));
    }
  }

  void _showPromoLockedDialog() {
    final c = AppColors.of(context);
    final completed = 3 - _promoTripsLeft;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: const Color(0xFFE8C547).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.lock_rounded,
                color: Color(0xFFE8C547),
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              S.of(context).promoLocked,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Complete $_promoTripsLeft more ride${_promoTripsLeft == 1 ? '' : 's'} to unlock your next 10% discount!',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 16),
            // Progress bar
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: completed / 3.0,
                minHeight: 8,
                backgroundColor: Colors.white.withValues(alpha: 0.08),
                valueColor: const AlwaysStoppedAnimation<Color>(
                  Color(0xFFE8C547),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              S.of(context).promoLockedProgress(completed),
              style: TextStyle(
                color: c.textTertiary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE8C547),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  S.of(context).gotIt,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showFastRideUnavailableDialog() {
    final c = AppColors.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.panel,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        contentPadding: const EdgeInsets.fromLTRB(24, 24, 24, 16),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: Colors.orange.withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.bolt_rounded,
                color: Colors.orange,
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              S.of(context).fastRideUnavailableTitle,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              S.of(context).fastRideUnavailable,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: c.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 44,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE8C547),
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                  elevation: 0,
                ),
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  S.of(context).understood,
                  style: TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _loadSavedData() async {
    // Promo generation must finish first (it writes data read below)
    final newPromoGenerated =
        await LocalDataService.generateMonthlyPromoIfNeeded();
    if (newPromoGenerated) {
      await LocalDataService.addNotification(
        title: '🎉 New monthly discount!',
        message:
            'You have a new 10% discount available for your next ride. Tap the promo banner on the home screen to apply it!',
        type: 'promo',
      );
    }

    // Fire ALL independent reads in parallel — single await instead of 10+
    final results = await Future.wait([
      LocalDataService.getFavorites(),          // 0
      LocalDataService.getTripHistory(),        // 1
      LocalDataService.getTopDestinations(limit: 3), // 2
      LocalDataService.getNotifications(),      // 3
      UserSession.getUser(),                    // 4
      LocalDataService.hasActivePromo(),        // 5
      LocalDataService.getActiveRide(),         // 6
      LocalDataService.isIdentityVerified(),    // 7
      _loadNextScheduledRide(),                 // 8
    ]);

    final favorites = results[0] as List<FavoritePlace>;
    final trips = results[1] as List<TripHistoryItem>;
    final topDestinations = results[2] as List<FrequentDestination>;
    final notifications = results[3] as List<AppNotificationItem>;
    final user = results[4] as Map<String, dynamic>?;
    final hasPromo = results[5] as bool;
    final activeRide = results[6] as ActiveRideInfo?;
    final verified = results[7] as bool;
    final nextScheduled = results[8] as Map<String, dynamic>?;

    if (!mounted) return;
    setState(() {
      _favorites = favorites;
      _recentTrips = trips;
      _topDestinations = topDestinations;
      _notifications = notifications;
      _hasActivePromo = hasPromo;
      _activeRide = activeRide;
      _isVerified = verified;
      _nextScheduledRide = nextScheduled;
      _loadingSavedData = false;
      if (user != null) {
        _firstName = user['firstName'] ?? '';
        _lastName = user['lastName'] ?? '';
        final path = user['photoPath'] ?? '';
        _photoPath = path.isNotEmpty ? path : null;
        final url = user['photoUrl'] ?? UserSession.photoUrlNotifier.value;
        _photoUrl = url.isNotEmpty ? url : null;
        // Update verification status from cached user data
        final vs = user['verificationStatus'] ?? '';
        if (vs.isNotEmpty) _verificationStatus = vs;
        if (verified) _verificationStatus = 'approved';
      }
    });
    // If not verified locally, check backend — handles reinstall/new device
    if (!_isVerified) {
      _checkBackendVerification();
    }

    // Start ride countdown if there's an active ride
    if (activeRide != null) {
      _startCountdown(activeRide.etaMinutes ?? 10);
      // Auto-open tracking screen on app restart with active ride (once)
      if (!_didAutoResumeRide) {
        _didAutoResumeRide = true;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && _activeRide != null) _resumeActiveRide();
        });
      }
    } else if (!_didAutoResumeRide) {
      // No local active ride — check backend (handles reinstall / re-login)
      _checkBackendActiveTrip();
    }

    // Update imminent ride countdown
    _updateImminentRide();

    // Panel lock: unlock if no active ride, keep locked otherwise
    if (_panelLocked && activeRide == null) {
      _unlockPanel();
    }
  }

  /// Extracted so it can run in parallel with local reads.
  Future<Map<String, dynamic>?> _loadNextScheduledRide() async {
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId != null) {
        final trips = await ApiService.getScheduledTrips(userId);
        if (trips.isNotEmpty) {
          final now = DateTime.now();
          for (final t in trips) {
            // Only consider trips that are still scheduled (not cancelled/completed)
            final status = (t['status'] as String? ?? 'scheduled').toLowerCase();
            if (status != 'scheduled') continue;
            final sa = t['scheduled_at'];
            if (sa != null) {
              final dt = DateTime.tryParse(sa.toString());
              if (dt != null && dt.isAfter(now)) {
                return t;
              }
            }
          }
        }
      }
    } catch (_) {}
    return null;
  }

  int get _unreadNotifications {
    return _notifications.where((item) => !item.read).length;
  }

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: const Color(0xFF07080D),
      body: FadeTransition(
        opacity: _rideFadeCtrl,
        child: Stack(
        children: [
          // Offline connectivity banner
          const Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(child: OfflineBanner()),
          ),
          // ── Full-screen map — scales back as sheet rises ──
          Positioned.fill(
            child: AnimatedBuilder(
              animation: _sheetController,
              builder: (context, child) {
                double frac = 0;
                try {
                  frac = ((_sheetController.size - _kMinSheet) /
                          (_kMaxSheet - _kMinSheet))
                      .clamp(0.0, 1.0);
                } catch (_) {}
                return Transform.translate(
                  offset: Offset(0, frac * 20.0),
                  child: Transform.scale(
                    scale: 1.0 - frac * 0.06,
                    alignment: Alignment.topCenter,
                    child: child!,
                  ),
                );
              },
              child: RepaintBoundary(child: _buildFullMap()),
            ),
          ),

          // ── "Where to?" search bar floating at top ──
          Positioned(
            top: topPad + 12,
            left: 20,
            right: 20,
            child: _buildWhereToBar(),
          ),

          // ── Draggable bottom sheet ──
          RepaintBoundary(
            child: DraggableScrollableSheet(
              controller: _sheetController,
              initialChildSize: _panelLocked ? _kMaxSheet : _kMinSheet,
              minChildSize: _panelLocked ? _kMaxSheet : _kMinSheet,
              maxChildSize: _activeRide != null && !_panelLocked
                  ? _kMinSheet
                  : _kMaxSheet,
              snap: true,
              snapSizes: _panelLocked
                  ? const [_kMaxSheet]
                  : _activeRide != null
                      ? const [_kMinSheet]
                      : const [_kMinSheet, _kMaxSheet],
              // No snapAnimationDuration — let Flutter use velocity-aware defaults
              builder: (ctx, scrollCtrl) =>
                  _buildSheet(scrollCtrl, bottomPad),
            ),
          ),

        ],
      ),
      ),
    );
  }

  double get _tripProgress {
    // Use real route progress from driver location when available
    if (_routeProgress > 0.01) return _routeProgress;
    // Fall back to countdown-based progress
    if (_totalSeconds == 0) return 0.0;
    return 1.0 - (_remainingSeconds / _totalSeconds);
  }

  String get _remainingLabel {
    if (_remainingSeconds <= 0) return 'Arriving...';
    final mins = (_remainingSeconds / 60).ceil();
    return '$mins min remaining';
  }

  /// Smoothly collapse the panel and restore normal drag behavior.
  void _unlockPanel() {
    if (!_panelLocked) return;
    setState(() => _panelLocked = false);
    // After rebuild with new minChildSize, animate to collapsed
    SchedulerBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _sheetController.animateTo(
        _kMinSheet,
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeInOutCubic,
      );
    });
  }

  void _requestRideToAddress(String address) async {
    if (_activeRide != null) {
      _resumeActiveRide();
      return;
    }
    if (!await _ensureVerified()) return;
    if (!mounted) return;
    LocalDataService.incrementDestinationUsage(address);
    Navigator.of(context)
        .push(
          scaleExpandRoute(RideRequestScreen(initialDropoffAddress: address)),
        )
        .then((_) {
          if (mounted) _loadSavedData();
        });
  }

  void _onDockTap(int index) async {
    if (index == _dockIndex) {
      // Already selected — execute action directly
      _executeDockAction(index);
      return;
    }
    setState(() => _dockIndex = index);
    if (!mounted) return;
    _executeDockAction(index);
  }

  void _executeDockAction(int index) async {
    switch (index) {
      case 0:
        if (_activeRide != null) {
          _resumeActiveRide();
          if (mounted) setState(() => _dockIndex = 0);
          return;
        }
        if (!await _ensureVerified()) return;
        if (!mounted) return;
        await Navigator.of(
          context,
        ).push(slideUpFadeRoute(const RideRequestScreen()));
        if (mounted) {
          _loadSavedData();
          setState(() => _dockIndex = 0);
        }
        break;
      case 1:
        await _openScheduleSheet();
        // Reset back to Ride after schedule closes
        if (mounted) setState(() => _dockIndex = 0);
        break;
      case 2:
        await Navigator.of(
          context,
        ).push(slideFromRightRoute(const AccountScreen()));
        _loadSavedData();
        if (mounted) setState(() => _dockIndex = 0);
        break;
    }
  }

  Future<void> _showScheduleSheet() async {
    // First show Airport/Schedule choice
    final choice = await showModalBottomSheet<String>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (context) =>
          _LaterOptionsSheet(isDark: AppColors.of(context).isDark),
    );

    // If cancelled or no choice, revert to Now
    if (choice == null || !mounted) {
      setState(() => _rideNow = true);
      return;
    }

    if (choice == 'airport') {
      // Airport ride — show terminal selector first
      final airportResult = await showModalBottomSheet<AirportSelection>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) =>
            AirportTerminalSheet(isDark: AppColors.of(context).isDark),
      );
      if (airportResult == null || !mounted) {
        setState(() => _rideNow = true);
        return;
      }
      Navigator.of(context).push(
        slideUpFadeRoute(
          RideRequestScreen(
            isAirportTrip: true,
            airportSelection: airportResult,
          ),
        ),
      );
      return;
    }

    // Schedule option - show date/time picker
    final result = await showModalBottomSheet<(DateTime, bool)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) =>
          SchedulePickerSheet(isDark: AppColors.of(context).isDark),
    );

    // If cancelled, revert to Now
    if (result == null || !mounted) {
      setState(() => _rideNow = true);
      return;
    }

    final (scheduledAt, isAirport) = result;

    if (!await _ensureVerified()) return;
    if (!mounted) return;

    // Open search screen so user picks a destination, then pass scheduledAt
    final searchResult = await Navigator.of(context).push<Map<String, dynamic>>(
      sharedAxisZRoute(
        PickupDropoffSearchScreen(
          initialPickupLat: _currentLatLng?.latitude,
          initialPickupLng: _currentLatLng?.longitude,
        ),
        opaque: false,
      ),
    );

    if (searchResult == null || !mounted) {
      setState(() => _rideNow = true);
      return;
    }

    final pickupDetails = searchResult['pickup'] as PlaceDetails?;
    final dropoffDetails = searchResult['dropoff'] as PlaceDetails?;
    final pickupLabel = searchResult['pickupLabel'] as String? ?? '';
    final dropoffLabel = searchResult['dropoffLabel'] as String? ?? '';

    if (dropoffDetails == null) {
      setState(() => _rideNow = true);
      return;
    }

    final effectivePickup = pickupDetails ?? (
      _currentLatLng != null
          ? PlaceDetails(
              address: pickupLabel.isNotEmpty ? pickupLabel : S.of(context).currentLocation,
              lat: _currentLatLng!.latitude,
              lng: _currentLatLng!.longitude,
            )
          : null
    );

    final effectiveDropoffLabel = dropoffLabel.isNotEmpty
        ? dropoffLabel
        : dropoffDetails.address;

    Navigator.of(context).push(
      slideUpFadeRoute(
        RideRequestScreen(
          scheduledAt: scheduledAt,
          isAirportTrip: isAirport,
          initialPickupDetails: effectivePickup,
          initialDropoffDetails: dropoffDetails,
          initialPickupLabel: pickupLabel,
          initialDropoffLabel: effectiveDropoffLabel,
          initialDropoffAddress: effectiveDropoffLabel,
        ),
      ),
    );
  }

  void _openMapWithDropoff(String query) async {
    if (_activeRide != null) {
      _resumeActiveRide();
      return;
    }
    if (!await _ensureVerified()) return;
    if (!mounted) return;
    LocalDataService.incrementDestinationUsage(query);
    Navigator.of(context).push(
      scaleExpandRoute(RideRequestScreen(initialDropoffAddress: query)),
    );
  }

  FavoritePlace? get _homeFavorite {
    for (final favorite in _favorites) {
      if (favorite.label.toLowerCase().trim() == 'home') {
        return favorite;
      }
    }
    return null;
  }

  FavoritePlace? get _workFavorite {
    for (final favorite in _favorites) {
      if (favorite.label.toLowerCase().trim() == 'work') {
        return favorite;
      }
    }
    return null;
  }

  FavoritePlace? get _place1Favorite {
    for (final favorite in _favorites) {
      if (favorite.label.toLowerCase().trim() == 'place 1') {
        return favorite;
      }
    }
    return null;
  }

  FavoritePlace? get _place2Favorite {
    for (final favorite in _favorites) {
      if (favorite.label.toLowerCase().trim() == 'place 2') {
        return favorite;
      }
    }
    return null;
  }

  Future<void> _openOrSaveHomeShortcut() async {
    if (_homeFavorite != null) {
      _requestRideToAddress(_homeFavorite!.address);
      return;
    }
    final s = S.of(context);
    final address = await _showAddressAutocomplete(
      title: s.setHomeAddress,
      hint: s.searchHomeAddress,
    );

    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Home', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _editHomeAddress() async {
    final s = S.of(context);
    final address = await _showAddressAutocomplete(
      title: s.editHomeAddress,
      hint: s.searchHomeAddress,
    );
    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Home', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _openOrSaveWorkShortcut() async {
    if (_workFavorite != null) {
      _requestRideToAddress(_workFavorite!.address);
      return;
    }
    final s = S.of(context);
    final address = await _showAddressAutocomplete(
      title: s.setWorkAddress,
      hint: s.searchWorkAddress,
    );

    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Work', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _editWorkAddress() async {
    final s = S.of(context);
    final address = await _showAddressAutocomplete(
      title: s.editWorkAddress,
      hint: s.searchWorkAddress,
    );
    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Work', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _openOrSavePlace1Shortcut() async {
    if (_place1Favorite != null) {
      _requestRideToAddress(_place1Favorite!.address);
      return;
    }
    final s = S.of(context);
    final address = await _showAddressAutocomplete(
      title: s.savePlace1,
      hint: s.searchAnAddress,
    );
    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Place 1', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _editPlace1Address() async {
    final s = S.of(context);
    final address = await _showAddressAutocomplete(
      title: s.editPlace1,
      hint: s.searchAnAddress,
    );
    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Place 1', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _openOrSavePlace2Shortcut() async {
    if (_place2Favorite != null) {
      _requestRideToAddress(_place2Favorite!.address);
      return;
    }
    final s = S.of(context);
    final address = await _showAddressAutocomplete(
      title: s.savePlace2,
      hint: s.searchAnAddress,
    );
    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Place 2', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _editPlace2Address() async {
    final s = S.of(context);
    final address = await _showAddressAutocomplete(
      title: s.editPlace2,
      hint: s.searchAnAddress,
    );
    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Place 2', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _openNotificationsSheet() async {
    final c = AppColors.of(context);
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: c.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      enableDrag: true,
      useSafeArea: true,
      isScrollControlled: true,
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.6,
      ),
      builder: (context) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4.5,
                    margin: const EdgeInsets.only(bottom: 12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(40),
                    ),
                  ),
                ),
                Text(
                  S.of(context).notificationsTitle,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                if (_notifications.isEmpty)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text(
                      S.of(context).noNotificationsYet,
                      style: TextStyle(color: c.textSecondary),
                    ),
                  )
                else
                  Flexible(
                    child: ListView.builder(
                      physics: const BouncingScrollPhysics(),
                      shrinkWrap: true,
                      itemCount: _notifications.length > 10
                          ? 10
                          : _notifications.length,
                      itemBuilder: (ctx, i) {
                        final item = _notifications[i];
                        return ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: Container(
                            width: 38,
                            height: 38,
                            decoration: BoxDecoration(
                              color: _gold.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(12),
                            ),
                            child: Icon(
                              item.type == 'ride'
                                  ? Icons.directions_car_filled_rounded
                                  : item.type == 'promo'
                                  ? Icons.local_offer_rounded
                                  : Icons.notifications_rounded,
                              color: _gold,
                              size: 18,
                            ),
                          ),
                          title: Text(
                            item.title,
                            style: TextStyle(
                              color: c.textPrimary,
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          subtitle: Text(
                            item.message,
                            style: TextStyle(
                              color: c.textSecondary,
                              fontSize: 13,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        );
                      },
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );

    await LocalDataService.markNotificationsAsRead();
    await _loadSavedData();
  }
}

// ─────────────────────────────────────────────
// Later Options Sheet - Airport or Schedule
// ─────────────────────────────────────────────
class _LaterOptionsSheet extends StatelessWidget {
  final bool isDark;
  const _LaterOptionsSheet({required this.isDark});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Drag handle
            Container(
              width: 40,
              height: 4.5,
              margin: const EdgeInsets.only(bottom: 16),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(40),
              ),
            ),
            Text(
              S.of(context).chooseRideType,
              style: TextStyle(
                color: c.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 24),

            // Airport option
            _optionCard(
              context: context,
              icon: Icons.flight_takeoff_rounded,
              title: S.of(context).airportLabel,
              subtitle: S.of(context).airportSubtitle,
              onTap: () => Navigator.pop(context, 'airport'),
            ),

            const SizedBox(height: 12),

            // Schedule option
            _optionCard(
              context: context,
              icon: Icons.schedule_rounded,
              title: S.of(context).schedule,
              subtitle: S.of(context).scheduleSubtitle,
              onTap: () => Navigator.pop(context, 'schedule'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _optionCard({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isDark ? const Color(0xFF1A1A1A) : Colors.white,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 48,
              height: 48,
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [Color(0xFFE8C547), Color(0xFFFBE47A)],
                ),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: Colors.black87, size: 24),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: c.textSecondary, fontSize: 13),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.arrow_forward_ios_rounded,
              color: c.textSecondary,
              size: 16,
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────
// Animated glow border painter for Where-to card
// Uses PathMetrics on a real RRect path for pixel-perfect smooth corners.
// ─────────────────────────────────────────────
class _GlowBorderPainter extends CustomPainter {
  final double progress;
  final Color gold;
  final Color goldLight;
  final bool isDark;

  _GlowBorderPainter({
    required this.progress,
    required this.gold,
    required this.goldLight,
    required this.isDark,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(28));

    // Base subtle border — smooth RRect, always visible
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..isAntiAlias = true
        ..color = gold.withValues(alpha: isDark ? 0.12 : 0.20),
    );

    // Build the border path from the RRect — Flutter uses Bézier curves
    // internally so corners are mathematically exact (no pixel jaggedness).
    final borderPath = Path()..addRRect(rrect);
    final metricsList = borderPath.computeMetrics().toList();
    if (metricsList.isEmpty) return;
    final pm = metricsList.first;
    final total = pm.length;

    const glowFraction = 0.18; // fraction of perimeter covered by the glow
    final glowLen = total * glowFraction;
    final headDist = (progress * total) % total;

    // Divide glow tail into steps for the fade gradient
    const steps = 48;
    final stepLen = glowLen / steps;

    for (int k = 0; k < steps; k++) {
      final t = 1.0 - k / steps; // 1.0 at head → 0.0 at tail
      final fadeAlpha = t * t * (3 - 2 * t); // smoothstep
      if (fadeAlpha < 0.02) continue;

      final segEnd   = (headDist - k * stepLen + total) % total;
      final segStart = (segEnd - stepLen + total) % total;

      // extractPath handles wrapping correctly when start > end
      final Path seg;
      if (segStart <= segEnd) {
        seg = pm.extractPath(segStart, segEnd);
      } else {
        seg = pm.extractPath(segStart, total)
          ..addPath(pm.extractPath(0, segEnd), Offset.zero);
      }

      // Bright stroke — isAntiAlias + round join = crisp smooth line
      canvas.drawPath(
        seg,
        Paint()
          ..style      = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..strokeCap  = StrokeCap.round
          ..strokeJoin = StrokeJoin.round
          ..isAntiAlias = true
          ..color = Color.lerp(gold, goldLight, t)!
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
            ..color = goldLight.withValues(alpha: fadeAlpha * 0.30),
        );
      }
    }
  }

  @override
  bool shouldRepaint(_GlowBorderPainter old) => old.progress != progress;
}

// ─── Address Autocomplete Bottom Sheet ────────────────────────────────

class _AddressAutocompleteSheet extends StatefulWidget {
  final String title;
  final String hint;
  final LatLng? currentLatLng;

  const _AddressAutocompleteSheet({
    required this.title,
    required this.hint,
    this.currentLatLng,
  });

  @override
  State<_AddressAutocompleteSheet> createState() =>
      _AddressAutocompleteSheetState();
}

class _AddressAutocompleteSheetState extends State<_AddressAutocompleteSheet> {
  final _controller = TextEditingController();
  final _places = PlacesService(ApiKeys.webServices);
  Timer? _debounce;
  List<PlaceSuggestion> _suggestions = [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _suggestions = [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      final results = await _places.autocomplete(
        query,
        latitude: widget.currentLatLng?.latitude,
        longitude: widget.currentLatLng?.longitude,
      );
      if (mounted) {
        setState(() {
          _suggestions = results;
          _loading = false;
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Handle
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: c.iconMuted,
              borderRadius: BorderRadius.circular(40),
            ),
          ),
          const SizedBox(height: 14),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    color: c.textPrimary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    widget.title,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Search field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.border),
              ),
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: TextStyle(color: c.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: widget.hint,
                  hintStyle: TextStyle(color: c.textTertiary, fontSize: 15),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: c.textTertiary,
                    size: 22,
                  ),
                  suffixIcon: _controller.text.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _controller.clear();
                            setState(() {
                              _suggestions = [];
                              _loading = false;
                            });
                          },
                          child: Icon(
                            Icons.close_rounded,
                            color: c.textTertiary,
                            size: 20,
                          ),
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Loading indicator
          if (_loading)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: const Color(0xFFE8C547),
                ),
              ),
            ),
          // Suggestions list
          Expanded(
            child: _suggestions.isEmpty && !_loading
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.place_outlined,
                            color: c.textTertiary,
                            size: 48,
                          ),
                          const SizedBox(height: 12),
                          Text(
                            _controller.text.isEmpty
                                ? S.of(context).typeToSearchForAddress
                                : S.of(context).noResultsFound,
                            style: TextStyle(
                              color: c.textTertiary,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.separated(
                    cacheExtent: 300,
                    padding: EdgeInsets.fromLTRB(12, 4, 12, bottomInset + 20),
                    itemCount: _suggestions.length,
                    separatorBuilder: (context2, idx) =>
                        Divider(color: c.divider, height: 1, indent: 52),
                    itemBuilder: (context, index) {
                      final s = _suggestions[index];
                      return ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: c.border),
                          ),
                          child: Icon(
                            s.icon,
                            color: const Color(0xFFD4AF37),
                            size: 20,
                          ),
                        ),
                        title: Text(
                          s.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        subtitle: s.distanceMiles != null
                            ? Text(
                                '${s.distanceMiles!.toStringAsFixed(1)} mi away',
                                style: TextStyle(
                                  color: c.textTertiary,
                                  fontSize: 12,
                                ),
                              )
                            : null,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onTap: () => Navigator.of(context).pop(s.description),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter that draws a real analog clock face with ticking hands.
class _ClockPainter extends CustomPainter {
  final double progress; // 0.0 to 1.0 (one full cycle = 6 seconds)

  _ClockPainter(this.progress);

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.width / 2;
    const goldColor = Color(0xFFE8C547);
    const goldLight = Color(0xFFFBE47A);

    // Draw clock circle outline
    final circlePaint = Paint()
      ..color = goldColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.8;
    canvas.drawCircle(center, radius - 1, circlePaint);

    // Draw small hour markers
    final tickPaint = Paint()
      ..color = goldLight
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;
    for (int i = 0; i < 12; i++) {
      final angle = (i * 30.0 - 90) * math.pi / 180;
      final outer = Offset(
        center.dx + (radius - 2.5) * math.cos(angle),
        center.dy + (radius - 2.5) * math.sin(angle),
      );
      final inner = Offset(
        center.dx + (radius - (i % 3 == 0 ? 5.5 : 4.0)) * math.cos(angle),
        center.dy + (radius - (i % 3 == 0 ? 5.5 : 4.0)) * math.sin(angle),
      );
      canvas.drawLine(inner, outer, tickPaint);
    }

    // Minute hand — 1 full rotation per cycle
    final minuteAngle = (progress * 360 - 90) * math.pi / 180;
    final minuteLength = radius * 0.7;
    final minuteEnd = Offset(
      center.dx + minuteLength * math.cos(minuteAngle),
      center.dy + minuteLength * math.sin(minuteAngle),
    );
    final minutePaint = Paint()
      ..color = goldLight
      ..strokeWidth = 1.8
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, minuteEnd, minutePaint);

    // Hour hand — moves 1/12th per cycle
    final hourAngle = (progress * 30 - 90) * math.pi / 180;
    final hourLength = radius * 0.45;
    final hourEnd = Offset(
      center.dx + hourLength * math.cos(hourAngle),
      center.dy + hourLength * math.sin(hourAngle),
    );
    final hourPaint = Paint()
      ..color = goldColor
      ..strokeWidth = 2.2
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(center, hourEnd, hourPaint);

    // Center dot
    final dotPaint = Paint()..color = goldLight;
    canvas.drawCircle(center, 1.5, dotPaint);
  }

  @override
  bool shouldRepaint(_ClockPainter oldDelegate) =>
      oldDelegate.progress != progress;
}
