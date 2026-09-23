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
import '../map/web_map_view.dart';
import '../map/map_surface_coordinator.dart';
import '../config/map_theme.dart';
import 'package:geolocator/geolocator.dart';
import '../services/preload_service.dart';
import '../services/heading_service.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import '../utils/mapbox_safe.dart';
import '../utils/driver_location_settings.dart';
import 'biometric_consent_screen.dart';
import 'identity_verification_screen.dart';
import 'schedule_hub_screen.dart';
import 'pickup_dropoff_search_screen.dart';
import 'ride_request_screen.dart';
import 'rider_tracking_screen.dart';
import 'trip_receipt_screen.dart';
import 'account_screen.dart';
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import '../services/places_service.dart';
import '../services/socket_service.dart';
import '../services/firebase_auth_recovery.dart';
import '../l10n/app_localizations.dart';
import '../widgets/cancel_reason_sheet.dart';
import '../services/user_session.dart';
import 'welcome_screen.dart';
import 'account_deactivated_screen.dart';
import 'rider_permissions_screen.dart';
import '../widgets/neu_style.dart';
import '../widgets/gold_location_dot.dart';
import '../widgets/car_image_3d.dart';
import '../widgets/offline_banner.dart';
import '../widgets/tier_detail_sheet.dart';
import 'package:firebase_database/firebase_database.dart';
import '../utils/responsive.dart';

part 'home_screen_controller.dart';
part 'home_screen_widgets.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  /// Bumped by main.dart FCM handler when a scheduled ride status changes
  /// (driver claimed, driver cancelled). HomeScreen listens and refreshes.
  static final scheduledRideRefresh = ValueNotifier<int>(0);

  /// Process-wide latch for the active-ride auto-resume. Every HomeScreen
  /// built in-session used to start its own false, so backing out of the
  /// tracking screen landed on a FRESH home whose _loadSavedData found the
  /// persisted ride and pushed tracking straight back — the rider could
  /// never sit on home mid-trip. The auto-resume is a cold-start behavior:
  /// it fires once per process, and backing out of tracking sets this
  /// before home is even built.
  static bool autoResumeConsumed = false;

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

        RouteAware {
  void _setState(VoidCallback fn) { if (mounted) setState(fn); }
  // Brand colors — premium shiny gold

  // The bolt/promo animation controllers and the promo counters left with
  // the circular shortcut row (2026-08-22 home redesign); the promo data
  // itself still loads in _loadSavedData for the request flow.
  // The drivers-online probe and the promo counters left with the circular
  // shortcut row they fed (2026-08-22 redesign); the promo data itself still
  // loads in _loadSavedData for the inbox notification.
  List<FavoritePlace> _favorites = [];
  List<TripHistoryItem> _recentTrips = [];
  List<FrequentDestination> _topDestinations = [];
  bool _loadingSavedData = true;
  // Hero switch thumb position: true = Ride (bolt), false = Schedule.
  bool _rideNow = true;
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

  /// Whether this process has ever seen the account NOT approved.
  ///
  /// The celebration is for the MOMENT of approval, so it needs a
  /// transition, and `!_isVerified` is not one — it is seeded from a local
  /// cache that logout wipes, so on every fresh sign-in of an
  /// already-approved rider it read false, the first Firestore snapshot came
  /// back approved, and the dialog fired again. People who had been verified
  /// for months got congratulated every time they logged in.
  ///
  /// Deliberately NOT persisted: a rider waiting for approval is the only
  /// one who can set it, and they set it from the very first snapshot.
  bool _sawUnapprovedThisSession = false;
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
  /// One-shot watch that re-arms the service-zone listen once a Firebase
  /// session finally exists — see `_listenServiceZones`.
  StreamSubscription<User?>? _zonesAuthSub;

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

  /// Web counterpart of the home mini map controller (GL JS). The native
  /// controller above stays null in the browser.
  WebMapController? _homeWebMapCtrl;
  bool _creatingHomeDotAnnot = false; // guard: prevents parallel annotation creation
  final GoldLocationDot _homeDot = GoldLocationDot();

  /// Where the mini-map arrow points: GPS course while moving, compass at a
  /// standstill — the same source the driver's own pages use, so the rider's
  /// arrow behaves exactly like the driver's.
  final HeadingService _headingSource = HeadingService();
  StreamSubscription<double>? _headingSub;
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
  // Instance view of the process-wide latch — see HomeScreen.autoResumeConsumed.
  bool get _didAutoResumeRide => HomeScreen.autoResumeConsumed;
  set _didAutoResumeRide(bool v) => HomeScreen.autoResumeConsumed = v;
  bool _openingRideFlow = false; // re-entry guard for _openSearchThenRide so back+retry doesn't double-push or skip dropoff





  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _rideFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
      value: 1.0, // fully visible
    );
    // Defer heavy loading until after first frame for faster startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) {
        _loadSavedData();
        _preloadSounds();
        // Register/refresh the rider FCM token (covers fresh logins).
        unawaited(NotificationService.registerTokenWithBackend());
      }
    });
    // Rider permission flow (once per install: location → notifications;
    // then once per cold start: the status page while anything is missing).
    // The map's location fetch waits for it so the two never race the same
    // system dialog.
    _runRiderPermissionFlow().whenComplete(() {
      if (mounted) _fetchCurrentLocation();
    });
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
    // The mini map's dot.
    //
    // Nothing here draws it — it is a CustomPaint pinned to the centre of
    // the card. What this runs for is the motion: GoldLocationDot smooths
    // the GPS fixes, and every tick slides the map underneath so the rider
    // stays under the dot. Walking looks like the map gliding past, the way
    // it does in Google Maps, rather than a marker being re-placed.
    unawaited(_homeDot.build(this, _recenterHomeMiniMap, onFrame: () {
      if (!mounted) return;
      _miniDotFrame.value++;   // repaint the Flutter dot with the frame
      _recenterHomeMiniMap();  // and keep the map under it
    }));
    // The arrow's direction: course while moving, compass parked — the
    // dot's SmoothMotion low-passes it into the same silky turn the
    // driver's arrow makes.
    _headingSource.start();
    _headingSub?.cancel();
    _headingSub = _headingSource.stream.listen((deg) {
      _homeDot.setBearing(deg);
    });
    _listenServiceZones();
    _listenVerificationStatus();
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
    // Real-time account status push — the poll above stays as fallback.
    _accountStatusSub =
        SocketService.accountStatusStream.listen(_onAccountStatusPush);
    // Pending-approval poll. Every real-time approval channel can be dead
    // for a brand-new session (socket born before the token, Firestore
    // rules deny the listener, FCM token not registered yet), and the
    // 300 s account poll above never asks about approval — so the rider
    // sat on "Verification pending" until an app restart. This asks the
    // backend directly every 20 s, but ONLY while the banner state is
    // actually pending (identity captured, not yet approved) — a no-op
    // string check for everyone else.
    _pendingVerifyTimer = Timer.periodic(
      const Duration(seconds: 20),
      (_) => _pollPendingVerification(),
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
      _accountStatusTimer?.cancel();
      _pendingVerifyTimer?.cancel();
      _countdownTimer?.cancel();
      _imminentRideTimer?.cancel();
      // Battery fix: fully release the GPS stream and its watchdog while
      // backgrounded — otherwise Geolocator keeps the location radio awake.
      _locationSub?.cancel();
      _locationSub = null;
      _gpsStreamWatchdog?.cancel();
      _gpsStreamWatchdog = null;
      // Pause animations to save CPU/GPU when backgrounded
    } else if (state == AppLifecycleState.resumed) {
      // FIX: Restart GPS stream — Geolocator stream can die in background
      // on some Android/iOS devices. Re-establish it after resume.
      _fetchCurrentLocation();
      // Restart the GPS stream watchdog that was cancelled on pause.
      _startLocationWatchdogs();
      // Ensure the mini map dot ticker is running after resume.
      _homeDot.ensureRunning();
      _checkAccountStatus();
      _accountStatusTimer?.cancel();
      _accountStatusTimer = Timer.periodic(
        const Duration(seconds: 300),
        (_) => _checkAccountStatus(),
      );
      // Restart the pending-approval poll (cancelled on pause) and fire
      // one check immediately: an approval that landed while backgrounded
      // should unlock the instant the rider comes back, not 20 s later.
      _pendingVerifyTimer?.cancel();
      _pendingVerifyTimer = Timer.periodic(
        const Duration(seconds: 20),
        (_) => _pollPendingVerification(),
      );
      _pollPendingVerification();
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
        // The GL JS controller dies with the widget — a kept handle would
        // have the dot's recenter (every GPS frame) writing flyTo into a
        // removed map, throwing once a second from home underneath
        // whatever screen took the surface.
        _homeWebMapCtrl = null;
        // The NATIVE handle is worse than a dead channel: pigeon channels
        // are keyed by a recycled suffix, and MapboxMap.dispose() sets no
        // disposed flag — after the picker mounts on the freed suffix, a
        // kept _homeMiniMapCtrl writes setCamera(rider live GPS, zoom 15)
        // once per dot frame INTO THE PICKER'S MAP. That was the "picker
        // re-centers on me in an infinite loop, can't drag" bug: the GPS
        // stream and dot ticker keep running while home is covered.
        _homeMiniMapCtrl = null;
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
      _homeWebMapCtrl = null; // same stale-handle rule as onRevoke above
      _homeMiniMapCtrl = null; // native handle too — see onRevoke comment
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
    _headingSub?.cancel();
    _headingSource.dispose();
    _miniDotFrame.dispose();
    _rideFadeCtrl.dispose();
    _accountStatusTimer?.cancel();
    _pendingVerifyTimer?.cancel();
    _accountStatusSub?.cancel();
    _countdownTimer?.cancel();
    _imminentRideTimer?.cancel();
    _pendingSearchTimer?.cancel();
    _pendingSearchTimer = null;
    _locationSub?.cancel();
    _stopLocationWatchdogs();
    _zonesSub?.cancel();
    _zonesAuthSub?.cancel();
    _driverLocationSub?.cancel();
    _tripDocSub?.cancel();
    _tripStatusSub?.cancel();
    _verificationRetryTimer?.cancel();
    _verificationSub?.cancel();
    for (final player in _soundPlayers.values) {
      // dispose() is a platform call and can time out like any other. In
      // dispose() there is nobody left to catch it, so it catches itself.
      player.dispose().catchError((Object e) {
        debugPrint('[HomeScreen] sound player dispose failed: $e');
      });
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

  /// Returns true if the rider may book: identity captured AND the account
  /// approved. Approval, not just verification — a rider who finished the
  /// KYC steps at signup but is still waiting on dispatch used to pass this
  /// gate and book rides with the account unreviewed.
  /// If not verified, shows the verification flow and returns false.
  Future<bool> _ensureVerified() async {
    final verified = await LocalDataService.isIdentityVerified();
    if (verified) {
      if (_verificationStatus == 'approved') {
        if (!_isVerified && mounted) setState(() => _isVerified = true);
        return true;
      }
      // Not approved in memory — ask the backend ONCE right now before
      // saying "wait". Every real-time approval channel can be dead in a
      // fresh session (socket born before the token, Firestore rules
      // deny, FCM token unregistered) and the 20 s poll may not have
      // ticked yet; a rider auto-approved seconds ago must not be blocked
      // by a stale flag.
      await _checkBackendVerification();
      if (!mounted) return false;
      if (_verificationStatus == 'approved') {
        if (!_isVerified) setState(() => _isVerified = true);
        return true;
      }
      // Verified on device, not yet approved — the answer is "wait", not
      // the verification flow again.
      _showApprovalRequiredDialog();
      return false;
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

  // ── Rider permission flow ────────────────────────────────────────────────
  //
  /// True once the status page was shown this process — it reappears on the
  /// next cold start while a permission is still missing, never twice in one.
  static bool _permsScreenShownThisProcess = false;

  /// Ordered permission asks for the rider (spec 2026-08-22).
  ///
  /// Fresh install, first home after login/signup: location FIRST, then
  /// notifications — once per install (`rider_perms_prompted_v1`). The map's
  /// own `_fetchCurrentLocation` is deferred until this settles so the two
  /// never race the same system dialog.
  ///
  /// Later cold starts with a session: whatever is still missing gets the
  /// [RiderPermissionsScreen] status page (Settings route), once per process
  /// — iOS will not show the system dialog a second time, so re-asking in
  /// app would be a dead tap.
  Future<void> _runRiderPermissionFlow() async {
    if (kIsWeb) return;
    try {
      final mode = await UserSession.getMode();
      if (mode != 'rider' || !mounted) return;
      final prefs = await SharedPreferences.getInstance();
      if (!mounted) return;
      final prompted = prefs.getBool('rider_perms_prompted_v1') == true;
      if (!prompted) {
        // 1. Location.
        var perm = await Geolocator.checkPermission();
        if (perm == LocationPermission.denied) {
          perm = await Geolocator.requestPermission();
        }
        if (!mounted) return;
        // 2. Notifications — after location, never before.
        await NotificationService.requestPermission();
        if (!mounted) return;
        unawaited(NotificationService.registerTokenWithBackend());
        await prefs.setBool('rider_perms_prompted_v1', true);
        // The system dialogs just ran; the status page would double-ask.
        return;
      }
      if (_permsScreenShownThisProcess) return;
      final locPerm = await Geolocator.checkPermission();
      final locOk = locPerm == LocationPermission.always ||
          locPerm == LocationPermission.whileInUse;
      final notifOk = await NotificationService.isPermissionGranted();
      if (!mounted || (locOk && notifOk)) return;
      _permsScreenShownThisProcess = true;
      await Navigator.of(context)
          .push(slideUpFadeRoute(const RiderPermissionsScreen()));
    } catch (_) {}
  }

  /// Told to a rider whose identity is captured but whose account is still
  /// waiting on approval: booking stays locked, and re-opening the KYC flow
  /// would not change that.
  void _showApprovalRequiredDialog() {    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1E24),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Row(
          children: [
            const Icon(Icons.hourglass_top_rounded, color: Color(0xFFE8C547)),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                S.of(ctx).accountPendingTitle,
                style: const TextStyle(color: Colors.white, fontSize: 16),
              ),
            ),
          ],
        ),
        content: Text(
          S.of(ctx).accountPendingDesc,
          style: const TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              S.of(ctx).ok,
              style: const TextStyle(color: Color(0xFFE8C547)),
            ),
          ),
        ],
      ),
    );
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
      // geolocator_web throws here unconditionally, which aborted the whole
      // location sequence — no stream, no position, no wait estimates.
      final lastKnown = kIsWeb ? null : await Geolocator.getLastKnownPosition();
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
            // riderLocationSettings, not a bare LocationSettings: the bare
            // form floors Android at one fix per 5 s (native default
            // interval), so the dot froze and then jumped metres at once.
            locationSettings: riderLocationSettings(distanceFilter: 0),
          ).listen((Position p) {
            if (!mounted) return;
            _lastGpsFixAt = DateTime.now();
            final ll = LatLng(p.latitude, p.longitude);
            _currentLatLng = ll;
            // Feed the compass/course arbiter the same fix the driver pages
            // feed theirs — it decides which source the arrow trusts.
            _headingSource.onFix(p);
            // Feed the mini map dot (SmoothMotion glides) + throttled
            // follow camera — the platform channel stays unsaturated.
            _feedHomeDot(ll.latitude, ll.longitude,
                accuracyM: p.accuracy,
                timestampMs: p.timestamp.millisecondsSinceEpoch.toDouble());
            _recenterHomeMiniMap();
          }, onError: (Object e) {
            // Platform channel errors (permission revoked, location services
            // off) arrive here instead of escaping as unhandled async errors
            // into the zone handler — which reports them as FATAL crashes.
            debugPrint('[Home] position stream error: $e');
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
  void _feedHomeDot(double lat, double lng,
      {double? accuracyM, double? timestampMs}) {
    if (_homeDot.lat == null) {
      _homeDot.snapTo(lat, lng);
      // First real fix: put the map there at once. Waiting for the next
      // frame is what left the card showing the fallback city a beat longer
      // than it had to.
      _recenterHomeMiniMap();
    } else {
      _homeDot.ensureRunning();
      _homeDot.setTarget(lat, lng,
          accuracyM: accuracyM, timestampMs: timestampMs);
    }
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
    if (!mounted) return;
    // NEVER write while the mini map is suspended (surface handed to
    // another screen). The handle is nulled on revoke, but this guard is
    // the belt to that suspender: a stale native handle here does not
    // throw — pigeon suffixes get recycled, so the write lands on
    // WHATEVER MAP NOW OWNS THE SUFFIX (the dropoff picker), re-centering
    // it on the rider's live GPS once per dot frame.
    if (_miniMapSuspended) return;
    final lat = _homeDot.lat ?? _currentLatLng?.latitude;
    final lng = _homeDot.lng ?? _currentLatLng?.longitude;
    if (lat == null || lng == null) return;

    // Web: the mini map is a GL JS WebMapView — its controller takes the
    // same follow-the-rider camera, short glides instead of snap sets.
    if (kIsWeb) {
      _homeWebMapCtrl?.flyTo(
          lng: lng, lat: lat, zoom: 15.0, durationMs: 300);
      return;
    }

    if (_homeMiniMapCtrl == null || _miniCamBusy) return;

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

  Timer? _accountStatusTimer;
  Timer? _pendingVerifyTimer;
  StreamSubscription<Map<String, dynamic>>? _accountStatusSub;

  /// 20 s tick while (and only while) the account sits in "Verification
  /// pending": identity captured on device but not approved yet. Resolves
  /// the approval over HTTP so the rider unlocks without any working push
  /// channel — and without restarting the app.
  Future<void> _pollPendingVerification() async {
    if (!mounted || _verificationStatus == 'approved') return;
    final captured = await LocalDataService.isIdentityVerified();
    if (!captured || !mounted) return;
    await _checkBackendVerification();
  }

  /// Server-pushed account status (SocketService.accountStatusStream):
  /// blocked/deleted → logout to Welcome; deactivated → deactivated screen;
  /// approved → refresh the local verification state so booking unlocks.
  /// The 300 s poll in [_checkAccountStatus] stays as the fallback.
  Future<void> _onAccountStatusPush(Map<String, dynamic> data) async {
    final status = (data['status'] ?? '').toString();
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
    } else if (status == 'approved') {
      _checkBackendVerification();
    }
  }

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
      UserSession.getUser()
          .catchError((_) => null),                       // 3
      LocalDataService.getActiveRide()
          .catchError((_) => null),                       // 4
      LocalDataService.isIdentityVerified()
          .catchError((_) => false),                      // 5
      _loadNextScheduledRide()
          .catchError((_) => null),                       // 6
    ]);

    final favorites = results[0] as List<FavoritePlace>;
    final trips = results[1] as List<TripHistoryItem>;
    final topDestinations = results[2] as List<FrequentDestination>;
    final user = results[3] as Map<String, dynamic>?;
    final activeRide = results[4] as ActiveRideInfo?;
    final verified = results[5] as bool;
    final nextScheduled = results[6] as Map<String, dynamic>?;

    if (!mounted) return;
    setState(() {
      _favorites = favorites;
      _recentTrips = trips;
      _topDestinations = topDestinations;
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
                      // Race guard: ListView can request stale indices beyond
                      // the new itemCount mid-frame when _suggestions is
                      // replaced by a shorter list. Never index out of
                      // range — that threw RangeError in production.
                      if (index < 0 || index >= _suggestions.length) {
                        return const SizedBox.shrink();
                      }
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
