import 'dart:async';
import 'dart:math' as math;
import 'package:audioplayers/audioplayers.dart';

import '../services/audio_session_config.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../config/mapbox_config.dart';
import '../config/route_observers.dart';
import '../map/map_surface_coordinator.dart';
import '../config/map_theme.dart';
import 'package:geolocator/geolocator.dart';
import '../services/preload_service.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import '../utils/mapbox_safe.dart';
import 'airport_terminal_sheet.dart';
import 'airport_direction_screen.dart';
import 'biometric_consent_screen.dart';
import 'choose_ride_type_screen.dart';
import 'identity_verification_screen.dart';
import 'schedule_ride_flow.dart';
import 'pickup_dropoff_search_screen.dart';
import 'ride_request_screen.dart';
import 'rider_tracking_screen.dart';
import 'scheduled_rides_screen.dart';
import 'trip_receipt_screen.dart';
import 'account_screen.dart';
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/screen_security_service.dart';
import '../services/directions_service.dart';
import '../services/driver_wait_estimate.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import '../services/places_service.dart';
import '../l10n/app_localizations.dart';
import '../services/user_session.dart';
import 'welcome_screen.dart';
import 'account_deactivated_screen.dart';
import '../widgets/neu_style.dart';
import '../widgets/gold_location_dot.dart';
import '../widgets/car_image_3d.dart';
import '../widgets/offline_banner.dart';
import 'package:firebase_database/firebase_database.dart';
import '../utils/responsive.dart';

part 'home_screen_controller.dart';
part 'home_screen_widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// Bumped by main.dart FCM handler when a scheduled ride status changes
  /// (driver claimed, driver cancelled). HomeScreen listens and refreshes.
  static final scheduledRideRefresh = ValueNotifier<int>(0);

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}


const _gold = Color(0xFFE8C547);
const _goldLight = Color(0xFFFBE47A);

// Self-healing watchdog constant — top-level so part files can reference it
// inside const expressions without relying on class static const visibility.
const int _gpsWatchdogSec = 5;

class _HomeScreenState extends State<HomeScreen>
    with
        TickerProviderStateMixin,
        WidgetsBindingObserver,
        SecureScreenMixin,
        RouteAware {
  void _setState(VoidCallback fn) { if (mounted) setState(fn); }
  // Brand colors — premium shiny gold

  late AnimationController _boltFlashCtrl;
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

  // Progress bar countdown state
  int _totalSeconds = 0;
  int _remainingSeconds = 0;
  Timer? _countdownTimer;

  // Verification state — eagerly loaded to prevent banner flash
  bool _isVerified = LocalDataService.isVerifiedSync;
  String _verificationStatus = LocalDataService.isVerifiedSync ? 'approved' : '';
  // True once the verification state is actually known (local cache hit or a
  // completed backend check). Until then the hero must NOT show the
  // "not verified" blocked state — prevents the flash on fresh logins where
  // the local cache is empty but the account is approved.
  bool _verificationResolved = LocalDataService.isVerifiedSync;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? _verificationSub;
  int _verificationRetryCount = 0;
  Timer? _verificationRetryTimer;

  // Service zone state
  Set<String> _activeServiceStates = {};
  String _userStateName = '';
  bool _serviceZoneActive = true; // default true until Firestore loads
  bool _stateCheckDone = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _zonesSub;

  // Self-healing watchdog — detects and recovers from a stuck GPS stream.
  DateTime _lastGpsFixAt = DateTime(0);
  Timer? _gpsStreamWatchdog;
  // Throttle for the "never got a GPS fix" retry (no permission spam).
  DateTime? _lastGpsRetryAt;

  // User profile data
  String _firstName = '';
  String _lastName = '';

  // ── Preloaded sound players ──
  final Map<String, AudioPlayer> _soundPlayers = {};

  // ── Location state (GPS — seeds pickup defaults + the live mini map) ──
  LatLng? _currentLatLng;
  bool _imagesPrecached = false;
  StreamSubscription<Position>? _locationSub;
  bool _fetchingLocation = false; // re-entry guard for _fetchCurrentLocation

  // ── Home mini map ("Your location" card) ──
  mapbox.MapboxMap? _homeMiniMapCtrl;
  mapbox.PointAnnotationManager? _homeDotAnnotMgr;
  mapbox.PointAnnotation? _homeDotAnnot;
  bool _creatingHomeDotAnnot = false; // guard: prevents parallel annotation creation
  Timer? _homeDotRetryTimer; // backoff ladder until the dot actually draws
  int _homeDotRetryAttempt = 0;
  final GoldLocationDot _homeDot = GoldLocationDot();
  // Throttle camera recentering so it doesn't fight the dot ticker.
  DateTime _lastMiniMapRecenter = DateTime(0);

  // ── Active trip driver tracking (RTDB → hero card progress bar) ──
  StreamSubscription<DatabaseEvent>? _driverLocationSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _tripDocSub;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _tripStatusSub;
  String? _trackedDriverId;
  int _driverLocationGeneration = 0;

  DateTime? _tripStartTime;

  // ── Route progress (pure math — feeds the hero card progress bar) ──
  double _routeProgress = 0.0; // 0→1 based on driver position along route
  List<LatLng> _routeLatLngs = []; // cached route points
  double _routeTotalDist = 0.0; // cached total route length in meters

  // ── Ride completion fade ──
  late AnimationController _rideFadeCtrl;
  bool _didAutoResumeRide = false; // prevent re-opening tracking on every _loadSavedData
  bool _openingRideFlow = false; // re-entry guard for _openSearchThenRide so back+retry doesn't double-push or skip dropoff
  bool _openingScheduleFlow = false; // re-entry guard for _showScheduleSheet (Schedule + Later switch + Airport via Schedule)





  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Optimized: fewer animation controllers to reduce CPU usage
    _boltFlashCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _promoShimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _rideFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1.0, // fully visible
    );
    // Flash bolt every 2 seconds
    _boltFlashLoop();
    // Defer heavy loading until after first frame for faster startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadSavedData();
        _loadPromoUsed();
        _preloadSounds();
        // Register/refresh the rider FCM token (covers fresh logins).
        unawaited(NotificationService.registerTokenWithBackend());
      }
    });
    _fetchCurrentLocation();
    // Eagerly load cached user name so greeting never shows "Rider"
    UserSession.getUser().then((user) {
      if (user != null && mounted && _firstName.isEmpty) {
        setState(() {
          _firstName = user['firstName'] ?? '';
          _lastName = user['lastName'] ?? '';
        });
      }
    });
    // Self-healing watchdog: restart dead GPS streams.
    _startLocationWatchdogs();
    // Gold dot for the "Your location" mini map — the ticker drives
    // annotation redraws; camera follow is throttled in the GPS listener.
    unawaited(_homeDot.build(this, _updateHomeDotAnnotation, onFrame: () {
      if (!mounted) return;
      _miniDotFrame.value++;   // repaint the Flutter dot with the frame
      _recenterHomeMiniMap();  // and keep the map under it
    }));
    // Defer driver check until after first frame to avoid blocking startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkDriversOnline();
    });
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
    // Defer account status check to post-frame — don't block UI startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkAccountStatus();
    });
    _accountStatusTimer = Timer.periodic(
      const Duration(seconds: 300),
      (_) => _checkAccountStatus(),
    );
    HomeScreen.scheduledRideRefresh.addListener(_onScheduledRideRefresh);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) {
      mapRouteObserver.subscribe(this, route);
    }
    // Post-frame so ModalRoute is settled — on a cold start with an active
    // ride the tracking push may already be on its way, and then this
    // correctly declines to mount.
    if (!_claimedMapSurfaceOnce) {
      _claimedMapSurfaceOnce = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_acquireMapSurface());
      });
    }
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
      // Battery fix: fully release the GPS stream and its watchdog while
      // backgrounded — otherwise Geolocator keeps the location radio awake.
      _locationSub?.cancel();
      _locationSub = null;
      _gpsStreamWatchdog?.cancel();
      _gpsStreamWatchdog = null;
      // Pause animations to save CPU/GPU when backgrounded
      _promoShimmerCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      // Resume looping animations
      _promoShimmerCtrl.repeat();
      // FIX: Restart GPS stream — Geolocator stream can die in background
      // on some Android/iOS devices. Re-establish it after resume.
      _fetchCurrentLocation();
      // Restart the GPS stream watchdog that was cancelled on pause.
      _startLocationWatchdogs();
      // Ensure the mini map dot ticker is running after resume.
      _homeDot.ensureRunning();
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
      // Refresh scheduled ride status so card reflects real-time state
      // Guard: only reload data if home screen is the current route to avoid
      // duplicate tracking screen pushes when resuming from another screen.
      final isCurrent = ModalRoute.of(context)?.isCurrent ?? false;
      if (isCurrent) {
        _loadNextScheduledRide().then((ride) {
          if (!mounted) return;
          setState(() => _nextScheduledRide = ride);
          _updateImminentRide();
        });
      }
    }
  }

  void _onScheduledRideRefresh() {
    _loadNextScheduledRide().then((ride) {
      if (!mounted) return;
      setState(() => _nextScheduledRide = ride);
      _updateImminentRide();
    });
  }

  // ── RouteAware: one live Mapbox surface at a time ──
  //
  // This screen is the bottom of the rider stack and its mini map stayed
  // mounted under every screen opened from here — the booking flow, the
  // location picker, the scheduled rides list. Each of those brings its own
  // native Mapbox view, so a single tap left two live surfaces up, which is
  // a native crash on iOS: the app just closes.
  //
  // The observer is typed on PageRoute, so bottom sheets and dialogs never
  // reach here — opening a sheet over the map must not tear it down.

  /// Hides the mini map while another full screen covers it.
  bool _miniMapSuspended = true;

  /// Identifies this screen to [MapSurfaceCoordinator].
  ///
  /// Registering matters for timing, not just for correctness: a screen that
  /// claims the surface revokes this one and *waits* for it to be gone before
  /// mounting its own, so the two never overlap. The [didPushNext] fallback
  /// below only fires 600 ms later, which would leave both alive in between.
  static const String _mapSurfaceOwner = 'RiderHome';
  bool _claimedMapSurfaceOnce = false;

  /// Claim the one live Mapbox surface before mounting the mini map.
  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || _miniMapSuspended) return;
        setState(() => _miniMapSuspended = true);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    setState(() => _miniMapSuspended = false);
  }

  @override
  void didPushNext() {
    // The delay lets a route that is only passing through (a picker the
    // rider dismisses immediately) come back without a map rebuild.
    Future.delayed(const Duration(milliseconds: 600), () {
      if (!mounted) return;
      if (ModalRoute.of(context)?.isCurrent == true) return;
      if (_miniMapSuspended) return;
      // A registered screen already took it and owns the teardown.
      if (MapSurfaceCoordinator.instance.currentOwner != _mapSurfaceOwner) {
        return;
      }
      setState(() => _miniMapSuspended = true);
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    });
  }

  @override
  void didPopNext() {
    if (!mounted || !_miniMapSuspended) return;
    unawaited(_acquireMapSurface());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    mapRouteObserver.unsubscribe(this);
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    HomeScreen.scheduledRideRefresh.removeListener(_onScheduledRideRefresh);
    // The dot owns the ticker that writes to the notifier, so it goes
    // first. The other order leaves a live ticker pointed at a disposed
    // ValueNotifier.
    _homeDot.dispose();
    _miniDotFrame.dispose();
    _homeDotRetryTimer?.cancel();
    _homeDotRetryTimer = null;
    _boltFlashCtrl.dispose();
    _promoShimmerCtrl.dispose();
    _rideFadeCtrl.dispose();
    _driverCheckTimer?.cancel();
    _accountStatusTimer?.cancel();
    _countdownTimer?.cancel();
    _imminentRideTimer?.cancel();
    _pendingSearchTimer?.cancel();
    _pendingSearchTimer = null;
    _locationSub?.cancel();
    _stopLocationWatchdogs();
    _zonesSub?.cancel();
    _driverLocationSub?.cancel();
    _tripDocSub?.cancel();
    _tripStatusSub?.cancel();
    _verificationRetryTimer?.cancel();
    _verificationSub?.cancel();
    for (final player in _soundPlayers.values) {
      player.dispose();
    }
    super.dispose();
  }

  /// Preload ride-related sounds during init so they play instantly later.
  void _preloadSounds() {
    // Settle the audio category first. These players are created during
    // startup, before NotificationService finishes its deferred init, so
    // this is the earliest an AudioPlayer exists in the rider app — and
    // whichever one touches the session first decides whether the user's
    // music survives opening Cruise.
    unawaited(ensureNonInterruptingAudio().then((_) {
      if (!mounted) return;
      const sounds = ['cruise_online', 'cruise_offer'];
      for (final s in sounds) {
        final player = AudioPlayer();
        player.setSource(AssetSource('sounds/$s.wav')).catchError((_) {});
        _soundPlayers[s] = player;
      }
    }));
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
    // Biometric consent gate (BIPA-style informed consent): show the
    // dedicated consent screen ONCE before any liveness capture.
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return false;
    if (prefs.getBool('biometric_consent_v1') != true) {
      final consented = await Navigator.of(
        context,
      ).push<bool>(slideUpFadeRoute(const BiometricConsentScreen()));
      if (consented != true) return false;
      if (!mounted) return false;
    }
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
    // Prevent the GPS watchdog or rapid lifecycle events from stacking
    // multiple concurrent location fetches / streams.
    if (_fetchingLocation) return;
    _fetchingLocation = true;
    try {
      // Use pre-loaded GPS from splash if available (instant)
      final preloaded = PreloadService.initialPosition;
      if (preloaded != null && mounted) {
        setState(() {
          _currentLatLng = LatLng(preloaded.latitude, preloaded.longitude);
        });
        // Draw the dot straight away. This path used to only snapTo and
        // return, leaving the dot invisible until _refreshGpsInBackground's
        // getCurrentPosition resolved (up to 15 s) — which is exactly why
        // the dot was missing on a cold open.
        _feedHomeDot(_currentLatLng!.latitude, _currentLatLng!.longitude);
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
      if (!serviceEnabled) return;

      // 2. Check / request permission
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
        if (perm == LocationPermission.denied) return;
      }
      if (perm == LocationPermission.deniedForever) {
        if (mounted) {
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
        });
        // Show the dot on the cached fix rather than waiting out the
        // 15 s getCurrentPosition below — this path set the field but
        // never told the map to draw.
        _feedHomeDot(lastKnown.latitude, lastKnown.longitude);
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
      });
      // Glides if lastKnown already rendered a dot, snaps if this is the
      // first position we've had.
      _feedHomeDot(_currentLatLng!.latitude, _currentLatLng!.longitude);

      // Check service zone for this position (once)
      if (!_stateCheckDone) {
        _stateCheckDone = true;
        _checkUserStateZone(_currentLatLng!);
      }

      // Start continuous location stream so _currentLatLng stays fresh
      // (it seeds the default pickup). distanceFilter: 0 -> every GPS fix.
      _lastGpsFixAt = DateTime.now();
      _locationSub?.cancel();
      _locationSub =
          Geolocator.getPositionStream(
            locationSettings: const LocationSettings(
              accuracy: LocationAccuracy.bestForNavigation,
              distanceFilter: 0,
            ),
          ).listen((Position p) {
            if (!mounted) return;
            _lastGpsFixAt = DateTime.now();
            final ll = LatLng(p.latitude, p.longitude);
            _currentLatLng = ll;
            // Feed the mini map dot (SmoothMotion glides) + throttled
            // follow camera — the platform channel stays unsaturated.
            _feedHomeDot(ll.latitude, ll.longitude);
            _recenterHomeMiniMap();
          });
    } catch (_) {
      // Location unavailable — the rider can still type a pickup manually.
    } finally {
      _fetchingLocation = false;
    }
  }

  /// Single entry point for feeding a GPS fix to the mini map dot.
  ///
  /// The first fix snaps (nothing is rendered yet, so a glide from a null
  /// position would be meaningless). Every later fix sets a target so
  /// SmoothMotion glides the dot instead of teleporting it across the
  /// card — the preloaded position and the first accurate fix are often
  /// tens of metres apart, and snapping both made the dot jump.
  ///
  /// Always ends with a direct draw: the ticker bails out when the dot
  /// hasn't moved (gold_location_dot.dart — `if (!posChanged) return`),
  /// so a stationary rider gets no redraw from it at all.
  void _feedHomeDot(double lat, double lng) {
    if (_homeDot.lat == null) {
      _homeDot.snapTo(lat, lng);
      // First real fix: put the map there at once. Waiting for the next
      // frame is what left the card showing the fallback city a beat longer
      // than it had to.
      _recenterHomeMiniMap();
    } else {
      _homeDot.ensureRunning();
      _homeDot.setTarget(lat, lng);
    }
    unawaited(_updateHomeDotAnnotation());
  }

  /// Redraw the gold dot on the "Your location" mini map. Driven by the
  /// GoldLocationDot ticker (throttled to ~30fps internally).
  /// Pattern v494: deleteAll() before create, and null the handle
  /// immediately if an update fails so the next tick recreates it.
  Future<void> _updateHomeDotAnnotation() async {
    if (!mounted) return;
    final mgr = _homeDotAnnotMgr;
    if (mgr == null) return;

    final lat = _homeDot.lat ?? _currentLatLng?.latitude;
    final lng = _homeDot.lng ?? _currentLatLng?.longitude;
    if (lat == null || lng == null) return;

    final point = safePoint(lng, lat);
    if (point == null) return;

    final bytes = _homeDot.currentBytes;
    if (bytes == null) return;

    // First-time creation must be guarded — without it the per-frame
    // ticker would attempt to create N annotations in parallel and we'd
    // end up with stacked dots.
    if (_homeDotAnnot == null) {
      if (_creatingHomeDotAnnot) return;
      _creatingHomeDotAnnot = true;
      try {
        // Defensive cleanup: delete any stale annotation left behind by a
        // failed update or a style reload, so we never draw two gold dots.
        try { await mgr.deleteAll(); } catch (_) {}
        final created = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: point,
          image: bytes,
          iconSize: 1.05,
          iconAnchor: mapbox.IconAnchor.CENTER,
          iconOffset: [0, 0],
        ));
        // A style reload can swap the manager while create() is in flight.
        // Publishing this handle then would leave _homeDotAnnot non-null
        // pointing at an annotation on a dead manager — invisible, yet
        // enough to stop the retry ladder. Drop it and let the retry run.
        if (!mounted || _homeDotAnnotMgr != mgr) {
          try { await mgr.delete(created); } catch (_) {}
          return;
        }
        _homeDotAnnot = created;
      } catch (e) {
        if (kDebugMode) debugPrint('[HomeScreen] Mini map dot create failed: $e');
        // Don't leave the dot missing until the next GPS fix — a stationary
        // rider may not get one for minutes.
        _retryHomeDotDraw();
      } finally {
        _creatingHomeDotAnnot = false;
      }
      return;
    }

    // Subsequent updates: write geometry in memory and fire the Mapbox
    // update without awaiting — the ticker must not stall on the platform
    // channel. Only geometry changes; the image bytes are static.
    final annot = _homeDotAnnot!;
    try {
      annot.geometry = point;
      mgr.update(annot).catchError((e) {
        // Update failed: null the handle immediately so the next tick
        // recreates, and delete the stale annotation fire-and-forget.
        // Otherwise the old dot stays visible and we get stacked dots.
        if (_homeDotAnnot == annot) {
          _homeDotAnnot = null;
          mgr.delete(annot).catchError((_) {});
          // THE dot is now off the map. "The next tick recreates it" only
          // holds while the rider is moving — GoldLocationDot skips the
          // callback when the position is unchanged, so a stationary rider
          // would watch the dot vanish and never come back. Kick the retry
          // ladder so it is redrawn within a second.
          _retryHomeDotDraw();
        }
        if (kDebugMode) debugPrint('[HomeScreen] Mini map dot update failed: $e');
      });
    } catch (e) {
      if (kDebugMode) debugPrint('[HomeScreen] Mini map dot geometry write failed: $e');
      _homeDotAnnot = null;
      _retryHomeDotDraw(); // same reasoning as above
    }
  }

  /// Backoff schedule for [_retryHomeDotDraw] — ~12 s of total coverage.
  static const List<int> _homeDotRetryDelaysMs = [
    250, 400, 600, 800, 1000, 1200, 1500, 2000, 2000, 2000,
  ];

  /// Keep retrying the mini map dot draw until it actually lands.
  ///
  /// The draw needs four things at once: the annotation manager, a GPS
  /// position, a valid point and the rendered dot bytes. On a cold start
  /// every one of them is racing (native map init, style download, first
  /// fix), and the ticker is no safety net — GoldLocationDot skips the
  /// callback entirely when the dot hasn't moved, so a stationary rider
  /// gets nothing. The old version fired three fixed shots (500/1500/
  /// 3000 ms) and then gave up forever, which is why the dot could stay
  /// missing for the whole session.
  ///
  /// This retries on a backoff and stops as soon as the annotation
  /// exists, so a slow map or a slow GPS no longer loses the race.
  void _retryHomeDotDraw() {
    // Restart from scratch: a fresh map or style reload means any pending
    // attempt is chasing a manager that no longer exists.
    _homeDotRetryTimer?.cancel();
    _homeDotRetryAttempt = 0;
    _scheduleHomeDotRetry();
  }

  void _scheduleHomeDotRetry() {
    if (_homeDotRetryAttempt >= _homeDotRetryDelaysMs.length) return;
    final ms = _homeDotRetryDelaysMs[_homeDotRetryAttempt++];
    _homeDotRetryTimer = Timer(Duration(milliseconds: ms), () async {
      if (!mounted || _homeDotAnnot != null) return; // already on screen
      // The dot bitmap is rendered once in initState. If that rasterise
      // failed, currentBytes stays null and every draw below is a silent
      // no-op forever — rebuild it here so the retry can actually succeed.
      if (!_homeDot.isReady) {
        await _homeDot.build(this, _updateHomeDotAnnotation, onFrame: () {
          if (!mounted) return;
          _miniDotFrame.value++;
          _recenterHomeMiniMap();
        });
      }
      if (!mounted) return;
      await _updateHomeDotAnnotation();
      if (mounted && _homeDotAnnot == null) _scheduleHomeDotRetry();
    });
  }

  /// Recenter the mini map camera on the rider at most once per [interval].
  /// Uses the interpolated dot position so camera and annotation stay in
  /// sync. easeTo keeps zoom/bearing/pitch constant — only the center glides.
  /// Keep the mini map under the dot.
  ///
  /// Was a 250 ms easeTo throttled to twice a second. Two animations then
  /// described the same movement at different speeds — the dot gliding on
  /// its own ticker, the map easing in half-second hops after it — so the
  /// dot drifted off centre and snapped back, twice a second, forever.
  ///
  /// One instant write per dot frame instead, dropped rather than queued
  /// while the previous is in flight. The smoothing already happened in the
  /// dot; the map only has to agree with it.
  void _recenterHomeMiniMap({Duration interval = Duration.zero}) {
    if (!mounted || _homeMiniMapCtrl == null) return;
    if (_miniCamBusy) return;
    final lat = _homeDot.lat ?? _currentLatLng?.latitude;
    final lng = _homeDot.lng ?? _currentLatLng?.longitude;
    if (lat == null || lng == null) return;

    final point = safePoint(lng, lat);
    if (point == null) return;

    _miniCamBusy = true;
    try {
      _homeMiniMapCtrl!
          .setCamera(mapbox.CameraOptions(
        center: point,
        zoom: 15.0,
        pitch: 0,
        bearing: 0,
      ))
          .then((_) {
        _miniCamBusy = false;
      }).catchError((Object e) {
        // The native map can be torn down mid-write (backgrounding, style
        // reload) and rejects asynchronously; the try/catch below only sees
        // synchronous throws.
        _miniCamBusy = false;
      });
    } catch (e) {
      _miniCamBusy = false;
      if (kDebugMode) debugPrint('[HomeScreen] Mini map recenter failed: $e');
    }
  }

  /// A mini-map camera write is crossing the platform channel.
  bool _miniCamBusy = false;

  /// Ticks once per dot frame so the Flutter-painted dot repaints with it.
  /// The screen's own setState runs nowhere near often enough — see the
  /// same notifier on the driver screens.
  final ValueNotifier<int> _miniDotFrame = ValueNotifier<int>(0);

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
      // Do NOT mark the promo as used here. The previous flow burned
      // the discount the moment the rider tapped "Apply and Ride",
      // even if they backed out without requesting the trip. Now the
      // promo is only consumed once the ride is actually confirmed
      // (LocalDataService.usePromo is called inside the trip-request
      // success path). If the rider cancels along the way, the 10%
      // stays available on the next attempt.
      //
      // Reuse the standard Now flow (search -> ride_request) so the
      // promo button shares the same re-entry guards and pickup/dropoff
      // experience, just with applyPromo=true so the picked vehicle
      // card shows the discounted price.
      await _openSearchThenRide(applyPromo: true);
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

  void _boltFlashLoop() async {
    while (mounted) {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) break;
      _boltFlashCtrl.forward().then((_) {
        if (mounted) _boltFlashCtrl.reverse();
      });
    }
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
    // Each future wrapped with .catchError() so one failure doesn't crash all
    final results = await Future.wait([
      LocalDataService.getFavorites()
          .catchError((_) => <FavoritePlace>[]),          // 0
      LocalDataService.getTripHistory()
          .catchError((_) => <TripHistoryItem>[]),        // 1
      LocalDataService.getTopDestinations(limit: 3)
          .catchError((_) => <FrequentDestination>[]),    // 2
      LocalDataService.getNotifications()
          .catchError((_) => <AppNotificationItem>[]),    // 3
      UserSession.getUser()
          .catchError((_) => null),                       // 4
      LocalDataService.hasActivePromo()
          .catchError((_) => false),                      // 5
      LocalDataService.getActiveRide()
          .catchError((_) => null),                       // 6
      LocalDataService.isIdentityVerified()
          .catchError((_) => false),                      // 7
      _loadNextScheduledRide()
          .catchError((_) => null),                       // 8
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
      // A local verified hit also counts as resolved.
      _verificationResolved = _verificationResolved || verified;
      _nextScheduledRide = nextScheduled;
      _loadingSavedData = false;
      if (user != null) {
        _firstName = user['firstName'] ?? '';
        _lastName = user['lastName'] ?? '';
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
      // Verify against backend BEFORE auto-resuming. If dispatch cancelled
      // the trip remotely while the rider was on home, the local cache
      // can still hold a stale "active" ride — without this check we'd
      // happily push the tracking screen for a dead trip.
      _verifyActiveRideAgainstBackend(activeRide);
      _startCountdown(activeRide.etaMinutes ?? 10);
      // Auto-open tracking screen on app restart with active ride (once).
      // Note: do NOT pre-set _didAutoResumeRide here — _resumeActiveRide()
      // owns that flag. Setting it before the post-frame callback would
      // make _resumeActiveRide() bail on its own guard and the rider
      // would stay stuck on home with the "Ride in progress" banner
      // instead of being pushed into the live tracking screen.
      if (!_didAutoResumeRide) {
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
            // Show all scheduled-origin trips until completed/canceled by driver/rider
            final status = (t['status'] as String? ?? 'scheduled').toLowerCase();
            const dismissedStatuses = {'completed', 'canceled', 'cancelled'};
            if (dismissedStatuses.contains(status)) continue;
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
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Scaffold(
      backgroundColor: neuBase,
      body: FadeTransition(
        opacity: _rideFadeCtrl,
        child: Stack(
        children: [
          // Offline connectivity banner
          const Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(child: OfflineBanner()),
          ),

          // ── Bottom sheet — permanently full-screen (no map behind it) ──
          // A plain full-screen widget now: a DraggableScrollableSheet
          // locked to a single snap size still installed drag recognizers
          // that fought the inner CustomScrollView (stuttery scroll).
          RepaintBoundary(
            child: _buildSheet(bottomPad),
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
        // Same flow as the hero "Where to?" CTA: address search first,
        // then RideRequestScreen with the results pre-filled.
        await _openSearchThenRide();
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
    // Re-entry guard so back-then-retry from any step inside the
    // schedule/airport flow can't re-open the picker on top of itself
    // or skip a step. Released in finally so every early return + back
    // pop + uncaught navigator error still frees the lock.
    if (_openingScheduleFlow) return;
    _openingScheduleFlow = true;
    try {
      // First show Airport/Schedule choice — now a full-screen picker
      // with animated cards and dynamic calendar date.
      final choice = await Navigator.of(context).push<String>(
        slideUpFadeRoute(const ChooseRideTypeScreen()),
      );

      // If cancelled or no choice, revert to Now
      if (choice == null || !mounted) {
        if (mounted) setState(() => _rideNow = true);
        return;
      }

      // ── Airport branch: direction picker FIRST (Take me TO / Pick me
      // up FROM), then date & time, then the airport terminal sheet. ──
      if (choice == 'airport') {
        final direction = await Navigator.of(context).push<AirportDirection>(
          slideUpFadeRoute(const AirportDirectionScreen()),
        );
        if (direction == null || !mounted) {
          if (mounted) setState(() => _rideNow = true);
          return;
        }

        final airportTime = await showScheduleRideFlow(
          context,
          initialPickupLat: _currentLatLng?.latitude,
          initialPickupLng: _currentLatLng?.longitude,
          initialIsAirport: true,
        );
        if (airportTime == null || !mounted) {
          if (mounted) setState(() => _rideNow = true);
          return;
        }
        final (scheduledAt, _, _) = airportTime;

        if (!await _ensureVerified()) return;
        if (!mounted) return;

        final airportResult = await showModalBottomSheet<AirportSelection>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          useSafeArea: true,
          builder: (_) => AirportTerminalSheet(
            isDark: AppColors.of(context).isDark,
            initialDirection: direction,
          ),
        );
        if (airportResult == null || !mounted) {
          if (mounted) setState(() => _rideNow = true);
          return;
        }
        Navigator.of(context).push(
          slideUpFadeRoute(
            RideRequestScreen(
              scheduledAt: scheduledAt,
              isAirportTrip: true,
              airportSelection: airportResult,
            ),
          ),
        );
        return;
      }

      // ── Schedule branch: calendar + time picker first, then the
      // pickup/dropoff search (or the airport sheet if the user flipped
      // the airport toggle inside the calendar). ──
      final result = await showScheduleRideFlow(
        context,
        initialPickupLat: _currentLatLng?.latitude,
        initialPickupLng: _currentLatLng?.longitude,
      );

      if (result == null || !mounted) {
        if (mounted) setState(() => _rideNow = true);
        return;
      }

      final (scheduledAt, isAirportFromToggle, searchResult) = result;
      final bool isAirportTrip = isAirportFromToggle;

      if (!await _ensureVerified()) return;
      if (!mounted) return;

      if (isAirportTrip) {
        // Airport branch — pick airport / terminal / airline / flight
        // BEFORE creating the trip, then push ride_request with both
        // the scheduledAt and the airport selection.
        final airportResult = await showModalBottomSheet<AirportSelection>(
          context: context,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          useSafeArea: true,
          builder: (_) =>
              AirportTerminalSheet(isDark: AppColors.of(context).isDark),
        );
        if (airportResult == null || !mounted) {
          if (mounted) setState(() => _rideNow = true);
          return;
        }
        Navigator.of(context).push(
          slideUpFadeRoute(
            RideRequestScreen(
              scheduledAt: scheduledAt,
              isAirportTrip: true,
              airportSelection: airportResult,
            ),
          ),
        );
        return;
      }

      // Schedule (non-airport) branch — the flow already pushed the
      // pickup/dropoff search ON TOP of the time picker, so back goes
      // to "Select Time" instead of home. The confirmed addresses come
      // back inside the flow record.
      if (searchResult == null) {
        if (mounted) setState(() => _rideNow = true);
        return;
      }

      final pickupDetails = searchResult['pickup'] as PlaceDetails?;
      final dropoffDetails = searchResult['dropoff'] as PlaceDetails?;
      final pickupLabel = searchResult['pickupLabel'] as String? ?? '';
      final dropoffLabel = searchResult['dropoffLabel'] as String? ?? '';

      if (dropoffDetails == null) {
        if (mounted) setState(() => _rideNow = true);
        return;
      }

      final effectivePickup = pickupDetails ?? (
        _currentLatLng != null
            ? PlaceDetails(
                address: pickupLabel.isNotEmpty
                    ? pickupLabel
                    : S.of(context).currentLocation,
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
            isAirportTrip: false,
            initialPickupDetails: effectivePickup,
            initialDropoffDetails: dropoffDetails,
            initialPickupLabel: pickupLabel,
            initialDropoffLabel: effectiveDropoffLabel,
            initialDropoffAddress: effectiveDropoffLabel,
          ),
        ),
      );
    } finally {
      // Always release the guard, then refresh saved data so the home
      // never reads stale _activeRide on the next attempt.
      if (mounted) {
        _openingScheduleFlow = false;
        _loadSavedData();
      }
    }
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
      height: MediaQuery.of(context).size.height,
      decoration: const BoxDecoration(
        color: neuBase,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          // Handle (below the status bar now that the sheet is full-screen)
          SizedBox(height: MediaQuery.of(context).padding.top + 10),
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
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: neuBox(radius: 14, pressed: true),
                    child: Icon(
                      Icons.arrow_back_rounded,
                      color: c.textPrimary,
                      size: 22,
                    ),
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
          // Search field — inset neumorphic well
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: neuBox(radius: 14, pressed: true),
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
                          decoration: neuBox(radius: 12, pressed: true),
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
