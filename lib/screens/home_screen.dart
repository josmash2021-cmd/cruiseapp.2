import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
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
import 'trip_receipt_screen.dart';
import 'account_screen.dart';
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/places_service.dart';
import '../l10n/app_localizations.dart';
import '../services/user_session.dart';
import 'welcome_screen.dart';
import 'account_deactivated_screen.dart';
import '../widgets/gold_location_dot.dart';
import '../widgets/user_profile_photo.dart';
import '../widgets/verified_avatar.dart';
import '../widgets/offline_banner.dart';

part 'home_screen_controller.dart';
part 'home_screen_map.dart';
part 'home_screen_widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}


const _gold = Color(0xFFE8C547);
const _goldLight = Color(0xFFFBE47A);
const double _kMinSheet = 0.42;
const double _kMaxSheet = 1.0; // Full screen when expanded
const int _locAnimDurationMs = 2800; // smooth glide between updates

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin, WidgetsBindingObserver {
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

  // Active ride state
  ActiveRideInfo? _activeRide;

  // Progress bar countdown state
  int _totalSeconds = 0;
  int _remainingSeconds = 0;
  Timer? _countdownTimer;

  // Verification state
  bool _isVerified = false;

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

  /// Interpolated position for the current animation frame.
  LatLng get _interpolatedLatLng {
    if (_locAnimFrom == null || _locAnimTo == null) return _currentLatLng ?? const LatLng(0, 0);
    final t = _easedProgress(_locAnimProgress);
    return LatLng(
      _locAnimFrom!.latitude + (_locAnimTo!.latitude - _locAnimFrom!.latitude) * t,
      _locAnimFrom!.longitude + (_locAnimTo!.longitude - _locAnimFrom!.longitude) * t,
    );
  }

  /// Called by the Ticker on every vsync frame during location animation.
  int _lastAnnotUpdateMs = 0;

  bool _locAnimNeedsRestart = false;

  Future<void> _updateMiniMapAnnotation() async {
    // Guard: prevent concurrent updates that create multiple pins
    if (_updatingMiniMapAnnot) return;
    _updatingMiniMapAnnot = true;
    
    try {
      final mgr = _miniMapAnnotMgr;
      if (mgr == null) return;
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
          iconSize: 1.0,
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
    _fetchCurrentLocation();
    _miniDot.build(() {
      if (mounted) _updateMiniMapAnnotation();
    });
    _checkDriversOnline();
    _listenServiceZones();
    _driverCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkDriversOnline(),
    );
    // Start account status polling immediately
    _checkAccountStatus();
    _accountStatusTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkAccountStatus(),
    );
    UserSession.photoNotifier.addListener(_onPhotoChanged);
    UserSession.photoUrlNotifier.addListener(_onPhotoChanged);
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
    } else if (state == AppLifecycleState.resumed) {
      _checkDriversOnline();
      _driverCheckTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _checkDriversOnline(),
      );
      _checkAccountStatus();
      _accountStatusTimer = Timer.periodic(
        const Duration(seconds: 30),
        (_) => _checkAccountStatus(),
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
    _shimmerController.dispose();
    _boltFlashCtrl.dispose();
    _clockRotateCtrl.dispose();
    _promoShimmerCtrl.dispose();
    _driverCheckTimer?.cancel();
    _accountStatusTimer?.cancel();
    _countdownTimer?.cancel();
    _locationSub?.cancel();
    _zonesSub?.cancel();
    super.dispose();
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
          setState(() => _locationError = 'Location services disabled');
        }
        return;
      }

      // 2. Check / request permission
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) {
          if (mounted) {
            setState(() => _locationError = 'Location permission denied');
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
            setState(() => _currentLatLng = ll);
            // Smoothly animate pin + camera to new position
            _animateToLocation(ll);
          });
    } catch (e) {
      if (mounted && _currentLatLng == null) {
        setState(() => _locationError = 'Unable to get location');
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
                'As a welcome to Cruise, enjoy 10% off your first ride! '
                'This exclusive offer can only be used once and will be '
                'applied automatically to your next ride.',
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
              'Promo Locked',
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
              '$completed / 3 rides completed',
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
                child: const Text(
                  'Got it',
                  style: TextStyle(fontWeight: FontWeight.w700),
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
    // Check if a new monthly promo needs to be generated
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

    final favorites = await LocalDataService.getFavorites();
    final trips = await LocalDataService.getTripHistory();
    final topDestinations = await LocalDataService.getTopDestinations(limit: 3);
    final notifications = await LocalDataService.getNotifications();
    final user = await UserSession.getUser();
    final hasPromo = await LocalDataService.hasActivePromo();
    final activeRide = await LocalDataService.getActiveRide();
    final verified = await LocalDataService.isIdentityVerified();
    if (!mounted) return;
    setState(() {
      _favorites = favorites;
      _recentTrips = trips;
      _topDestinations = topDestinations;
      _notifications = notifications;
      _hasActivePromo = hasPromo;
      _activeRide = activeRide;
      _isVerified = verified;
      _loadingSavedData = false;
      if (user != null) {
        _firstName = user['firstName'] ?? '';
        _lastName = user['lastName'] ?? '';
        final path = user['photoPath'] ?? '';
        _photoPath = path.isNotEmpty ? path : null;
        final url = user['photoUrl'] ?? UserSession.photoUrlNotifier.value;
        _photoUrl = url.isNotEmpty ? url : null;
      }
    });
    // Start ride countdown if there's an active ride
    if (activeRide != null) {
      _startCountdown(activeRide.etaMinutes ?? 10);
    }
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
      body: Stack(
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
            right: 64,
            child: _buildWhereToBar(),
          ),

          // ── Notification button floating top-right ──
          Positioned(
            top: topPad + 12,
            right: 16,
            child: _buildMapFab(),
          ),

          // ── Draggable bottom sheet ──
          RepaintBoundary(
            child: DraggableScrollableSheet(
              controller: _sheetController,
              initialChildSize: _kMinSheet,
              minChildSize: _kMinSheet,
              maxChildSize: _kMaxSheet,
              snap: true,
              snapSizes: const [_kMinSheet, _kMaxSheet],
              // No snapAnimationDuration — let Flutter use velocity-aware defaults
              builder: (ctx, scrollCtrl) =>
                  _buildSheet(scrollCtrl, bottomPad),
            ),
          ),

        ],
      ),
    );
  }

  double get _tripProgress {
    if (_totalSeconds == 0) return 0.0;
    return 1.0 - (_remainingSeconds / _totalSeconds);
  }

  String get _remainingLabel {
    if (_remainingSeconds <= 0) return 'Arriving...';
    final mins = (_remainingSeconds / 60).ceil();
    return '$mins min remaining';
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
          _ScheduleBottomSheet(isDark: AppColors.of(context).isDark),
    );

    // If cancelled, revert to Now
    if (result == null || !mounted) {
      setState(() => _rideNow = true);
      return;
    }

    final (scheduledAt, isAirport) = result;
    final formattedDate =
        '${scheduledAt.month}/${scheduledAt.day}/${scheduledAt.year}';
    final formattedTime = TimeOfDay.fromDateTime(scheduledAt).format(context);

    final airportLabel = isAirport ? ' ✈ Airport' : '';
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: _gold,
        content: Text(
          'Ride scheduled for $formattedDate at $formattedTime$airportLabel',
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w600,
          ),
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );

    if (!await _ensureVerified()) return;
    if (!mounted) return;

    Navigator.of(context).push(
      slideUpFadeRoute(
        RideRequestScreen(scheduledAt: scheduledAt, isAirportTrip: isAirport),
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
    final address = await _showAddressAutocomplete(
      title: 'Set Home address',
      hint: 'Search your home address',
    );

    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Home', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _editHomeAddress() async {
    final address = await _showAddressAutocomplete(
      title: 'Edit Home address',
      hint: 'Search your home address',
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
    final address = await _showAddressAutocomplete(
      title: 'Set Work address',
      hint: 'Search your work address',
    );

    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Work', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _editWorkAddress() async {
    final address = await _showAddressAutocomplete(
      title: 'Edit Work address',
      hint: 'Search your work address',
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
    final address = await _showAddressAutocomplete(
      title: 'Save Place 1',
      hint: 'Search an address',
    );
    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Place 1', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _editPlace1Address() async {
    final address = await _showAddressAutocomplete(
      title: 'Edit Place 1',
      hint: 'Search an address',
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
    final address = await _showAddressAutocomplete(
      title: 'Save Place 2',
      hint: 'Search an address',
    );
    if (address == null || address.isEmpty) return;
    await LocalDataService.saveFavorite(
      FavoritePlace(label: 'Place 2', address: address),
    );
    await _loadSavedData();
  }

  Future<void> _editPlace2Address() async {
    final address = await _showAddressAutocomplete(
      title: 'Edit Place 2',
      hint: 'Search an address',
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
                  'Notifications',
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
                      'No notifications yet.',
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

// ─────────────────────────────────────────────
// Schedule bottom sheet with calendar → clock
// ─────────────────────────────────────────────
class _ScheduleBottomSheet extends StatefulWidget {
  final bool isDark;
  const _ScheduleBottomSheet({required this.isDark});

  @override
  State<_ScheduleBottomSheet> createState() => _ScheduleBottomSheetState();
}

class _ScheduleBottomSheetState extends State<_ScheduleBottomSheet>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  late final AnimationController _animCtrl;
  late final Animation<double> _fadeOut;
  late final Animation<double> _fadeIn;
  late final Animation<Offset> _slideOut;
  late final Animation<Offset> _slideIn;

  bool _showingClock = false;
  bool _isAirport = false;
  DateTime _selectedDate = DateTime.now();
  int _selectedHour = TimeOfDay.now().hour;
  int _selectedMinute = (TimeOfDay.now().minute ~/ 5) * 5; // rounded to 5

  @override
  void initState() {
    super.initState();
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeOut = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _animCtrl,
        curve: const Interval(0.0, 0.4, curve: Curves.easeOut),
      ),
    );
    _fadeIn = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _animCtrl,
        curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
      ),
    );
    _slideOut = Tween<Offset>(begin: Offset.zero, end: const Offset(-0.15, 0.0))
        .animate(
          CurvedAnimation(
            parent: _animCtrl,
            curve: const Interval(0.0, 0.4, curve: Curves.easeIn),
          ),
        );
    _slideIn = Tween<Offset>(begin: const Offset(0.15, 0.0), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _animCtrl,
            curve: const Interval(0.4, 1.0, curve: Curves.easeOut),
          ),
        );
  }

  @override
  void dispose() {
    _animCtrl.dispose();
    super.dispose();
  }

  void _goToClock() {
    setState(() => _showingClock = true);
    _animCtrl.forward(from: 0);
  }

  void _goBackToCalendar() {
    setState(() => _showingClock = false);
    _animCtrl.reverse(from: 1);
  }

  void _confirm() {
    final scheduled = DateTime(
      _selectedDate.year,
      _selectedDate.month,
      _selectedDate.day,
      _selectedHour,
      _selectedMinute,
    );
    Navigator.of(context).pop((scheduled, _isAirport));
  }

  Color get _bg => const Color(0xFF161820);
  Color get _surface => const Color(0xFF1A1D24);
  Color get _textPrimary => Colors.white;
  Color get _textSecondary => Colors.white54;
  Color get _border => Colors.white10;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: _bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Handle bar
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: _textSecondary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),

              // Title row
              Row(
                children: [
                  if (_showingClock)
                    GestureDetector(
                      onTap: _goBackToCalendar,
                      child: Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: Icon(
                          Icons.arrow_back_ios_rounded,
                          color: _gold,
                          size: 20,
                        ),
                      ),
                    ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Text(
                      _showingClock ? 'Select Time' : 'Schedule a Ride',
                      key: ValueKey(_showingClock),
                      style: TextStyle(
                        color: _textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  const Spacer(),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    child: Icon(
                      _showingClock
                          ? Icons.access_time_filled_rounded
                          : Icons.calendar_month_rounded,
                      key: ValueKey(_showingClock),
                      color: _gold,
                      size: 26,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Align(
                alignment: Alignment.centerLeft,
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 250),
                  child: Text(
                    _showingClock
                        ? 'Pick your preferred time'
                        : 'Choose a date for your ride',
                    key: ValueKey(_showingClock),
                    style: TextStyle(color: _textSecondary, fontSize: 13),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Content area with transition
              AnimatedBuilder(
                animation: _animCtrl,
                builder: (context, _) {
                  return SizedBox(
                    height: 320,
                    child: Stack(
                      children: [
                        // Calendar (fades out)
                        if (!_showingClock || _animCtrl.isAnimating)
                          FadeTransition(
                            opacity: _fadeOut,
                            child: _buildCalendar(),
                          ),
                        // Clock (fades in)
                        if (_showingClock)
                          FadeTransition(
                            opacity: _fadeIn,
                            child: _buildTimePicker(),
                          ),
                      ],
                    ),
                  );
                },
              ),
              const SizedBox(height: 16),

              // Airport toggle
              GestureDetector(
                onTap: () => setState(() => _isAirport = !_isAirport),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    color: _isAirport
                        ? const Color(0xFF4285F4).withValues(alpha: 0.12)
                        : _surface,
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _isAirport
                          ? const Color(0xFF4285F4).withValues(alpha: 0.4)
                          : _border,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        Icons.flight_rounded,
                        size: 20,
                        color: _isAirport
                            ? const Color(0xFF4285F4)
                            : _textSecondary,
                      ),
                      const SizedBox(width: 12),
                      Text(
                        'Airport trip',
                        style: TextStyle(
                          color: _isAirport
                              ? const Color(0xFF4285F4)
                              : _textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 42,
                        height: 24,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(12),
                          color: _isAirport
                              ? const Color(0xFF4285F4)
                              : Colors.white12,
                        ),
                        child: AnimatedAlign(
                          duration: const Duration(milliseconds: 200),
                          alignment: _isAirport
                              ? Alignment.centerRight
                              : Alignment.centerLeft,
                          child: Container(
                            width: 20,
                            height: 20,
                            margin: const EdgeInsets.symmetric(horizontal: 2),
                            decoration: const BoxDecoration(
                              shape: BoxShape.circle,
                              color: Colors.white,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Action button
              GestureDetector(
                onTap: _showingClock ? _confirm : _goToClock,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: double.infinity,
                  height: 52,
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [_gold, _goldLight]),
                    borderRadius: BorderRadius.circular(16),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.35),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Center(
                    child: AnimatedSwitcher(
                      duration: const Duration(milliseconds: 250),
                      child: Row(
                        key: ValueKey(_showingClock),
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _showingClock
                                ? Icons.check_rounded
                                : Icons.access_time_rounded,
                            color: Colors.black87,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _showingClock ? 'Confirm & Book' : 'Select Time',
                            style: const TextStyle(
                              color: Colors.black87,
                              fontWeight: FontWeight.w700,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
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

  Widget _buildCalendar() {
    final now = DateTime.now();
    final firstDay = DateTime(now.year, now.month, now.day);
    final lastDay = firstDay.add(const Duration(days: 30));

    return Theme(
      data: (widget.isDark ? ThemeData.dark() : ThemeData.light()).copyWith(
        colorScheme: widget.isDark
            ? ColorScheme.dark(
                primary: _gold,
                onPrimary: Colors.white,
                surface: _bg,
                onSurface: Colors.white,
              )
            : ColorScheme.light(
                primary: _gold,
                onPrimary: Colors.white,
                surface: _bg,
                onSurface: const Color(0xFF1A1D24),
              ),
        datePickerTheme: DatePickerThemeData(
          backgroundColor: _bg,
          headerBackgroundColor: _bg,
          headerForegroundColor: _textPrimary,
          dayForegroundColor: WidgetStatePropertyAll(_textPrimary),
          todayForegroundColor: const WidgetStatePropertyAll(_gold),
          todayBorder: const BorderSide(color: _gold, width: 1),
          yearForegroundColor: WidgetStatePropertyAll(_textPrimary),
          weekdayStyle: TextStyle(
            color: _textSecondary,
            fontWeight: FontWeight.w600,
          ),
          dayStyle: TextStyle(color: _textPrimary),
        ),
      ),
      child: CalendarDatePicker(
        initialDate: _selectedDate,
        firstDate: firstDay,
        lastDate: lastDay,
        onDateChanged: (date) => setState(() => _selectedDate = date),
      ),
    );
  }

  Widget _buildTimePicker() {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 8),
          // AM/PM indicator
          Text(
            _selectedHour < 12 ? 'AM' : 'PM',
            style: TextStyle(
              color: _gold,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.5,
            ),
          ),
          const SizedBox(height: 12),
          // Time display
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _timeDigit(
                value: _selectedHour == 0
                    ? 12
                    : (_selectedHour > 12 ? _selectedHour - 12 : _selectedHour),
                label: 'Hour',
                onUp: () =>
                    setState(() => _selectedHour = (_selectedHour + 1) % 24),
                onDown: () => setState(
                  () => _selectedHour = (_selectedHour - 1 + 24) % 24,
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Text(
                  ':',
                  style: TextStyle(
                    color: _gold,
                    fontSize: 44,
                    fontWeight: FontWeight.w300,
                  ),
                ),
              ),
              _timeDigit(
                value: _selectedMinute,
                label: 'Min',
                padZero: true,
                onUp: () => setState(
                  () => _selectedMinute = (_selectedMinute + 5) % 60,
                ),
                onDown: () => setState(
                  () => _selectedMinute = (_selectedMinute - 5 + 60) % 60,
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // AM / PM toggle
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _amPmChip('AM', _selectedHour < 12, () {
                if (_selectedHour >= 12) setState(() => _selectedHour -= 12);
              }),
              const SizedBox(width: 12),
              _amPmChip('PM', _selectedHour >= 12, () {
                if (_selectedHour < 12) setState(() => _selectedHour += 12);
              }),
            ],
          ),
          const SizedBox(height: 20),
          // Summary
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.event_rounded, color: _gold, size: 18),
                const SizedBox(width: 8),
                Text(
                  '${_selectedDate.month}/${_selectedDate.day}/${_selectedDate.year}',
                  style: TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
                const SizedBox(width: 14),
                Icon(Icons.schedule_rounded, color: _gold, size: 18),
                const SizedBox(width: 8),
                Text(
                  _formatTime(),
                  style: TextStyle(
                    color: _textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _timeDigit({
    required int value,
    required String label,
    bool padZero = false,
    required VoidCallback onUp,
    required VoidCallback onDown,
  }) {
    final display = padZero
        ? value.toString().padLeft(2, '0')
        : value.toString();
    return Column(
      children: [
        GestureDetector(
          onTap: onUp,
          child: Container(
            width: 70,
            height: 36,
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _border),
            ),
            child: Icon(
              Icons.keyboard_arrow_up_rounded,
              color: _gold,
              size: 24,
            ),
          ),
        ),
        const SizedBox(height: 6),
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 280),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          ),
          child: Text(
            display,
            key: ValueKey(value),
            style: TextStyle(
              color: _textPrimary,
              fontSize: 44,
              fontWeight: FontWeight.w300,
            ),
          ),
        ),
        Text(
          label,
          style: TextStyle(
            color: _textSecondary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 6),
        GestureDetector(
          onTap: onDown,
          child: Container(
            width: 70,
            height: 36,
            decoration: BoxDecoration(
              color: _surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: _border),
            ),
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: _gold,
              size: 24,
            ),
          ),
        ),
      ],
    );
  }

  Widget _amPmChip(String text, bool active, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 10),
        decoration: BoxDecoration(
          color: active ? _gold.withValues(alpha: 0.15) : _surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: active ? _gold : _border,
            width: active ? 1.5 : 1,
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            color: active ? _gold : _textSecondary,
            fontWeight: FontWeight.w700,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  String _formatTime() {
    final h = _selectedHour == 0
        ? 12
        : (_selectedHour > 12 ? _selectedHour - 12 : _selectedHour);
    final m = _selectedMinute.toString().padLeft(2, '0');
    final ampm = _selectedHour < 12 ? 'AM' : 'PM';
    return '$h:$m $ampm';
  }
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
                                ? 'Type to search for an address'
                                : 'No results found',
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
