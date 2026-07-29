import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../services/haptic_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:flutter/foundation.dart' show kIsWeb;
import '../../widgets/neu_style.dart';
import '../../models/lat_lng.dart';
import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import '../../config/map_styles.dart';
import '../../config/page_transitions.dart';
import '../../config/driver_colors.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/notification_service.dart';
import '../../services/user_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/prefs_cache.dart';
import '../home_screen.dart';
import '../welcome_screen.dart';
import '../../utils/mapbox_safe.dart';
import '../../services/map_controller_cache.dart';
import '../account_deactivated_screen.dart';
import 'driver_earnings_screen.dart';
import 'driver_trip_history_screen.dart';
import 'driver_menu_screen.dart';
import 'driver_online_screen.dart';
import 'driver_trip_accept_screen.dart';
import 'driver_inbox_screen.dart';
import 'driver_promos_screen.dart';
import 'driver_analytics_screen.dart';
import 'driver_vehicle_screen.dart';
import 'driver_documents_screen.dart';
import 'scheduled_rides_screen.dart';
import 'scheduled_ride_details_screen.dart';
import '../../l10n/app_localizations.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../../widgets/gold_location_dot.dart';
import '../../widgets/user_profile_photo.dart';
import '../../widgets/verified_avatar.dart';
import '../../widgets/velocity_aware_panel.dart';
import '../../utils/responsive.dart';
import '../../utils/name_helper.dart' as nh;

/// ═══════════════════════════════════════════════════════════════
///  CRUISE DRIVER HOME — Premium dashboard with map, stats, go-online
/// ═══════════════════════════════════════════════════════════════
class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key, this.returnFromTrip = false});

  /// When true the driver came back from an active-trip screen — keep them
  /// in the "still online" state so the bottom bar shows "Buscando viajes"
  /// and the main button reads REANUDAR.
  final bool returnFromTrip;

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver, VelocityAwarePanelMixin {
  static final _sqlPrefixRe = RegExp(r'^sql_');
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);
  // ignore: unused_field
  static const _surface = Color(0xFF1A1A1F);

  // ── Map ──
  mapbox.MapboxMap? _mapController;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PointAnnotation? _myLocAnnot;
  LatLng? _currentLatLng;
  // ignore: unused_field
  bool _mapReady = false;
  final GoldLocationDot _goldDot = GoldLocationDot();
  // Retries the first dot draw until it lands. _updateMyLocAnnotation() no-ops
  // until BOTH the annotation manager and the dot image exist, and the dot
  // ticker only fires when the position actually changes — so a driver sitting
  // still while the map view is still coming up would never get a dot at all.
  // Self-cancels as soon as the annotation exists.
  Timer? _dotCreateWatchdog;
  StreamSubscription<Position>? _posStream;
  StreamSubscription<String>? _fcmTokenRefreshSub;

  // ── Stats ──
  double _todayEarnings = 0.0;
  int _todayTrips = 0;
  double _todayHours = 0.0;
  String _driverName = 'Driver';
  String? _photoUrl;

  // ── Animations ──
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _glossCtrl; // gloss shimmer sweep
  late AnimationController _statsCtrl;
  late Animation<double> _statsAnim;
  late AnimationController _fabCtrl;
  late Animation<double> _fabScale;

  // ── Bottom panel ──
  // Collapsed height shows only the drag handle + status header row
  // ("You're offline" / "Finding trips"); the stats & recommendations stay
  // hidden until the user swipes the panel up.
  static const double _panelBaseH = 92.0;
  // Extra height reserved while the scheduled-rides banner is shown above the
  // header (finding-trips state). Without it the banner's ~46px eats into the
  // scroll viewport and clips the bottom rows on devices with small insets.
  static const double _panelBannerH = 50.0;
  // Travel for the spring drag (must stay > 0 — drag deltas divide by it).
  // Collapsed (92) + travel (400) = 492 expanded, which fits the full content
  // (status row + 3 stat cards + all 3 recommended rows) without clipping.
  static const double _panelTravelH = 400.0;

  bool get _scheduledBannerVisible =>
      _isStillOnline && _activeTripData == null && _scheduledAvailableCount > 0;

  double get _panelCollapsedH =>
      _panelBaseH + (_scheduledBannerVisible ? _panelBannerH : 0);
  double get _panelExpandedH => _panelCollapsedH + _panelTravelH;
  bool _dragging = false;

  // ── Inbox unread count ──
  int _unreadCount = 0;

  // ── Verification ──
  bool _isVerified = false;

  // ── Bottom nav ──
  int _navIndex = 0;

  // ── Online state (driver pressed back but is still connected) ──
  bool _isStillOnline = false;
  // Prevents _resumeActiveTrip() from pushing DriverTripAcceptScreen twice.
  // Six different code paths call _resumeActiveTrip (initState, app resume,
  // polling, notification tap, refresh-complete, Firestore listener). Without
  // this guard two of them firing within the same frame stack two trip
  // screens on top of each other — the duplicate the rider reported.
  bool _resumingActiveTrip = false;
  Timer? _tripPollTimer;
  Timer? _statsRefreshTimer;
  int? _driverId;
  Map<String, dynamic>? _activeTripData;

  // ── Scheduled rides banner ──
  int _scheduledAvailableCount = 0;
  Timer? _scheduledBannerTimer;

  // ── Vehicle document approval ──
  bool _vehicleDocsApproved = false;
  bool _hasExpiredDocs = false;
  bool _docStatusLoaded = false;
  bool _isNavigatingToOnline = false; // true while navigating to online screen
  late AnimationController _btnColorCtrl;
  StreamSubscription<DocumentSnapshot>? _docApprovalSub;
  late Animation<double> _btnColorAnim;

  @override
  double get panelTravelHeight => _panelExpandedH - _panelCollapsedH;

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
    initPanelAnimation();
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarIconBrightness: Brightness.light,
      ),
    );

    // Pulsing glow for Go Online button
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    // Gloss shimmer sweep across button
    _glossCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();

    // Red → gold color transition for Go Online button
    _btnColorCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _btnColorAnim = CurvedAnimation(
      parent: _btnColorCtrl,
      curve: Curves.easeInOut,
    );

    // Stats panel entrance
    _statsCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _statsAnim = CurvedAnimation(
      parent: _statsCtrl,
      curve: Curves.easeOutCubic,
    );

    // FAB scale
    _fabCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fabScale = CurvedAnimation(parent: _fabCtrl, curve: Curves.elasticOut);

    if (widget.returnFromTrip) _isStillOnline = true;
    _goldDot.build(this, () {
      // Update the Mapbox annotation directly — no setState needed (avoids rebuild storm)
      if (mounted) _syncDotAnnotation();
    });
    _startDotCreateWatchdog();
    _initLocation();
    _loadDriverData();
    _checkVerification().then((_) => _checkVehicleDocStatus());
    _startDocApprovalListener();
    // Defer account status check to post-frame — don't block UI startup
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _checkAccountStatus();
    });
    _accountStatusTimer = Timer.periodic(
      const Duration(seconds: 300),
      (_) => _checkAccountStatus(),
    );

    // Listen for photo updates from UserSession
    UserSession.photoNotifier.addListener(_onPhotoUpdated);
    UserSession.photoUrlNotifier.addListener(_onPhotoUpdated);

    // Resolve driver ID then check Firestore for active trip.
    // _checkBackendActiveTrip uses auth token (no driver ID needed) so runs in parallel.
    _resolveDriverIdThenRefresh();
    _checkBackendActiveTrip();
    _checkScheduledRideLockout();
    _registerFcmToken();

    // Observe lifecycle — restart polling when app returns from background
    WidgetsBinding.instance.addObserver(this);

    // Restore online state persisted from last session
    PrefsCache.instance.then((prefs) {
      if (!mounted) return;
      final wasOnline = prefs.getBool('driver_was_online') ?? false;
      if (wasOnline && !_isStillOnline) {
        setState(() => _isStillOnline = true);
        _startTripPolling();
      }
    });

    // Periodic stats refresh (every 60s) for real-time chips
    _statsRefreshTimer = Timer.periodic(
      const Duration(seconds: 60),
      (_) => _refreshStats(),
    );

    // Poll scheduled ride count every 90s to update banner
    _refreshScheduledCount();
    _scheduledBannerTimer = Timer.periodic(
      const Duration(seconds: 90),
      (_) => _refreshScheduledCount(),
    );

    // Entrance animations
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _statsCtrl.forward();
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _fabCtrl.forward();
    });
  }

  void _onPhotoUpdated() {
    if (mounted) {
      setState(() {
        _photoUrl = UserSession.photoUrlNotifier.value.isNotEmpty
            ? UserSession.photoUrlNotifier.value
            : UserSession.photoNotifier.value;
      });
    }
  }

  /// Register this device for push, retrying until it lands.
  ///
  /// Every driver row in production holds fcm_token NULL, so no ride offer
  /// can ever wake a phone — and this method could not say why, because it
  /// ignored the permission result, ignored a null token, did not await the
  /// save, and buried the lot in `catch (_) {}`. Each failure mode now
  /// names itself in the log.
  ///
  /// The retry matters: the save is a no-op until the session JWT exists,
  /// and without a second attempt a device that got here a moment early
  /// stayed unregistered for the whole session.
  Future<void> _registerFcmToken() async {
    try {
      final messaging = FirebaseMessaging.instance;

      final settings = await messaging.requestPermission(
        alert: true, badge: true, sound: true,
      );
      if (settings.authorizationStatus == AuthorizationStatus.denied) {
        debugPrint('[DriverHome] FCM: push permission DENIED by the user — '
            'no ride offers can be delivered while the app is closed');
        return;
      }

      final token = await messaging.getToken();
      if (token == null) {
        // Typically APNs not wired up on iOS: no APNs token, no FCM token.
        // A Firebase/Xcode configuration problem, not something the app can
        // recover from at runtime — but it must not be silent.
        debugPrint('[DriverHome] FCM: getToken() returned null — check APNs '
            'setup in Firebase and the Xcode capabilities');
        return;
      }

      var saved = await ApiService.saveFcmToken(token);
      for (var attempt = 1; !saved && attempt <= 3; attempt++) {
        await Future.delayed(Duration(seconds: attempt * 3));
        if (!mounted) return;
        debugPrint('[DriverHome] FCM: retrying token registration ($attempt/3)');
        saved = await ApiService.saveFcmToken(token);
      }
      if (!saved) {
        debugPrint('[DriverHome] FCM: token could NOT be registered after 3 '
            'retries — this driver will not receive ride offers in background');
      }

      _fcmTokenRefreshSub?.cancel();
      _fcmTokenRefreshSub = messaging.onTokenRefresh.listen((t) {
        debugPrint('[DriverHome] FCM: token rotated, re-registering');
        ApiService.saveFcmToken(t);
      });
    } catch (e) {
      debugPrint('[DriverHome] FCM registration failed: $e');
    }
  }

  @override
  void dispose() {
    _fcmTokenRefreshSub?.cancel();
    disposePanelAnimation();
    _pulseCtrl.dispose();
    _glossCtrl.dispose();
    _btnColorCtrl.dispose();
    _statsCtrl.dispose();
    _fabCtrl.dispose();
    _goldDot.dispose();
    _dotCreateWatchdog?.cancel();
    _posStream?.cancel();
    _accountStatusTimer?.cancel();
    _tripPollTimer?.cancel();
    _statsRefreshTimer?.cancel();
    _docApprovalSub?.cancel();
    _scheduledBannerTimer?.cancel();
    UserSession.photoNotifier.removeListener(_onPhotoUpdated);
    UserSession.photoUrlNotifier.removeListener(_onPhotoUpdated);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      // Always re-check vehicle doc approval when app comes back
      if (!_vehicleDocsApproved) _checkVehicleDocStatus();
      // Re-check scheduled ride lockout (driver may return from background)
      _checkScheduledRideLockout();
    }
    if (state == AppLifecycleState.resumed && _isStillOnline && mounted) {
      // App returned from background — refresh trip status then restart polling
      _refreshActiveTripStatus().then((_) {
        if (!mounted) return;
        if (_activeTripData != null) {
          // Active trip exists — go straight back to the trip screen
          _resumeActiveTrip();
          return;
        }
        _startTripPolling();
      });
    }
  }

  bool _updatingLocAnnot = false;

  /// Write-then-flush update of the driver's gold-dot annotation.
  /// Same pattern as the rider home dot (1.0.2+376) — the previous
  /// full-await guard dropped every frame that landed mid-IPC, so the
  /// dot only moved ~1×/sec. Now we always write the freshest position
  /// into the annotation in memory (cheap), and only fire mgr.update()
  /// when the previous IPC finished. The next IPC always carries the
  /// latest position, no information lost.
  Future<void> _updateMyLocAnnotation() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    final bytes = _goldDot.currentBytes;
    if (bytes == null) return;

    final lat = _goldDot.lat ?? _currentLatLng?.latitude;
    final lng = _goldDot.lng ?? _currentLatLng?.longitude;
    if (lat == null || lng == null) return;

    final point = safePoint(lng, lat);
    if (point == null) return;

    // First-time creation must be guarded — without it the per-frame
    // ticker would parallel-create N annotations and stack dots.
    if (_myLocAnnot == null) {
      if (_updatingLocAnnot) return;
      _updatingLocAnnot = true;
      try {
        _myLocAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: point,
          image: bytes,
          iconSize: 1.0,
          iconAnchor: mapbox.IconAnchor.CENTER,
          iconOffset: [0, 0],
        ));
      } catch (_) {
        // creation failed — leave null so we retry next frame
      } finally {
        _updatingLocAnnot = false;
      }
      return;
    }

    // Update geometry + image every frame — no skip guard.
    // The Ticker runs at 60fps and advances _goldDot smoothly.
    // Mapbox internally handles rapid updates; skipping frames caused stutter.
    try {
      _myLocAnnot!.geometry = point;
      _myLocAnnot!.image = bytes;
      mgr.update(_myLocAnnot!).catchError((_) {
        _myLocAnnot = null;
      });
    } catch (_) {
      _myLocAnnot = null;
    }

    // Smooth camera follow — instant setCamera on every dot tick (~30fps,
    // throttled inside GoldLocationDot). The camera glides frame-by-frame
    // with the INTERPOLATED dot position, so the driver sees a continuous
    // slide instead of discrete flyTo jumps.
    _mapController?.setCamera(
      mapbox.CameraOptions(
        center: point,
        zoom: 16.0,
        pitch: 0.0,
        bearing: 0.0,
      ),
    );
  }

  /// Update the gold dot PointAnnotation with latest interpolated position + frame.
  void _syncDotAnnotation() {
    _updateMyLocAnnotation();
  }

  /// Poll until the dot annotation actually exists, then stop.
  /// Covers the startup race where the GPS fix arrives before the map's
  /// annotation manager (or the rendered dot image) is ready.
  void _startDotCreateWatchdog() {
    _dotCreateWatchdog?.cancel();
    _dotCreateWatchdog = Timer.periodic(const Duration(seconds: 2), (t) async {
      if (!mounted || _myLocAnnot != null) {
        t.cancel();
        _dotCreateWatchdog = null;
        return;
      }
      // Rasterising the dot bitmap can fail (GPU context lost, OOM) and
      // GoldLocationDot leaves currentBytes null when it does — every draw
      // is then a silent no-op, and nothing else rebuilds it on this
      // screen. Same retry the rider home does in _scheduleHomeDotRetry.
      if (!_goldDot.isReady) {
        await _goldDot.build(this, () {
          if (mounted) _syncDotAnnotation();
        });
        if (!mounted) return;
      }
      _updateMyLocAnnotation();
    });
  }

  // ═══════════════════════════════════════════════════
  //  ACCOUNT STATUS CHECK
  // ═══════════════════════════════════════════════════
  Timer? _accountStatusTimer;

  Future<void> _checkAccountStatus() async {
    try {
      final status = await ApiService.getAccountStatus().timeout(const Duration(seconds: 15));
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

  // ═══════════════════════════════════════════════════
  //  LOCATION
  // ═══════════════════════════════════════════════════
  Future<void> _initLocation() async {
    try {
      bool svc = await Geolocator.isLocationServiceEnabled();
      if (!svc) {
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

      final last = await Geolocator.getLastKnownPosition();
      if (last != null && mounted) {
        _currentLatLng = LatLng(last.latitude, last.longitude);
        _goldDot.setTarget(last.latitude, last.longitude);
        setState(() {});
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      _currentLatLng = LatLng(pos.latitude, pos.longitude);
      _goldDot.setTarget(pos.latitude, pos.longitude);
      setState(() {});
      _updateMyLocAnnotation();
      _mapController?.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(coordinates: mapbox.Position(_currentLatLng!.longitude, _currentLatLng!.latitude)),
          zoom: 16, pitch: 0, bearing: 0,
        ),
        mapbox.MapAnimationOptions(duration: 800),
      );

      // ── Real-time GPS stream ──
      // distanceFilter: 2 -> accept fixes every 2 meters.
      // SmoothMotion interpolates smoothly between fixes.
      // Balance between accuracy and battery life.
      _posStream?.cancel();
      _posStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 2,
        ),
      ).listen((p) {
        if (!mounted) return;
        final ll = LatLng(p.latitude, p.longitude);
        _currentLatLng = ll;
        _goldDot.setTarget(ll.latitude, ll.longitude);
        debugPrint('[DriverHome] GPS update: ${ll.latitude.toStringAsFixed(5)},${ll.longitude.toStringAsFixed(5)} '
            'speed=${p.speed.toStringAsFixed(1)}m/s accuracy=${p.accuracy.toStringAsFixed(1)}m');
        // Camera follow is handled per dot-tick in _updateMyLocAnnotation
        // (instant setCamera at ~30fps). The old 800ms-throttled flyTo
        // restarted its animation on every fix and made the map — and the
        // dot relative to the screen — visibly jump.
      });
    } catch (_) {}
  }

  Future<void> _loadDriverData() async {
    // Cache-first: show last-known data instantly
    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
    final cachedName = prefs.getString('driver_cached_name');
    final cachedEarnings = prefs.getDouble('driver_cached_earnings');
    final cachedTrips = prefs.getInt('driver_cached_trips');
    final cachedUserId = prefs.getString('driver_cached_user_id');
    final currentUserId = (await ApiService.getCurrentUserId().timeout(const Duration(seconds: 15)))?.toString();
    // Only use cache if it belongs to the current driver (prevents
    // showing another driver's earnings after logout/login).
    final cacheValid = currentUserId != null && currentUserId == cachedUserId;
    if (cachedName != null && mounted && cacheValid) {
      setState(() {
        _driverName = cachedName;
        _todayEarnings = cachedEarnings ?? 0.0;
        _todayTrips = cachedTrips ?? 0;
      });
    } else if (!cacheValid && mounted) {
      // Reset to zero when switching drivers
      setState(() {
        _todayEarnings = 0.0;
        _todayTrips = 0;
      });
    }

    // Background refresh from API — use dashboard (single call)
    final dashboard = await ApiService.getDashboard().catchError((_) => null);
    final notifs = await ApiService.getNotifications().catchError((_) => <Map<String, dynamic>>[]);

    if (!mounted) return;
    final profile = dashboard?['profile'] as Map<String, dynamic>?;
    final driverData = dashboard?['driver_data'] as Map<String, dynamic>?;
    final earnings = driverData?['earnings'] as Map<String, dynamic>? ?? {};

    setState(() {
      if (profile != null) {
        final firstName = profile['first_name'] ?? 'Driver';
        final lastName = profile['last_name'] ?? '';
        _driverName = lastName.isNotEmpty
            ? '$firstName ${lastName[0].toUpperCase()}.'
            : firstName;
        if (UserSession.photoNotifier.value.isNotEmpty) {
          _photoUrl = UserSession.photoNotifier.value;
        } else {
          final serverPhoto = profile['photo_url']?.toString() ?? '';
          if (serverPhoto.isNotEmpty) {
            _photoUrl = serverPhoto.startsWith('http')
                ? serverPhoto
                : '${ApiService.publicBaseUrl}$serverPhoto';
          }
        }
      }
      _todayEarnings = (earnings['total'] as num?)?.toDouble() ?? 0.0;
      _todayTrips = (earnings['trips_count'] as num?)?.toInt() ?? 0;
      _todayHours = (earnings['online_hours'] as num?)?.toDouble() ?? 0.0;
      _unreadCount = notifs.where((n) => n['is_read'] != true).length;
    });

    // Update local cache
    prefs.setString('driver_cached_name', _driverName);
    prefs.setDouble('driver_cached_earnings', _todayEarnings);
    prefs.setInt('driver_cached_trips', _todayTrips);
    if (currentUserId != null) {
      prefs.setString('driver_cached_user_id', currentUserId);
    }
  }

  /// Lightweight periodic refresh for the 3 stats chips (no name/photo reload).
  Future<void> _refreshStats() async {
    try {
      final earnings = await ApiService.getDriverEarnings(period: 'today')
          .catchError((_) => <String, dynamic>{});
      if (!mounted) return;
      setState(() {
        _todayEarnings = (earnings['total'] as num?)?.toDouble() ?? _todayEarnings;
        _todayTrips    = (earnings['trips_count'] as num?)?.toInt() ?? _todayTrips;
        _todayHours    = (earnings['online_hours'] as num?)?.toDouble() ?? _todayHours;
      });
    } catch (_) {}
  }

  // ═══════════════════════════════════════════════════
  //  IDENTITY VERIFICATION GATE
  // ═══════════════════════════════════════════════════
  Future<void> _checkVerification() async {
    // Driver reached this screen after passing splash/login approval gates,
    // so they are already verified. Sync local status to match.
    await LocalDataService.setDriverApprovalStatus('approved');
    if (mounted) setState(() => _isVerified = true);
  }

  Future<bool> _ensureVerified() async {
    if (_isVerified) return true;
    // Driver is on home screen — they passed all gates already
    if (mounted) setState(() => _isVerified = true);
    return true;
  }

  // ═══════════════════════════════════════════════════
  //  VEHICLE DOCUMENT STATUS CHECK
  // ═══════════════════════════════════════════════════
  Future<void> _checkVehicleDocStatus() async {
    try {
      final result = await ApiService.canGoOnline().timeout(const Duration(seconds: 15));
      if (!mounted) return;

      final canGo = result['can_go_online'] == true;
      final expired = result['has_expired_docs'] == true;

      // Sync approval status locally
      if (result['approved'] == true) {
        await LocalDataService.setDriverApprovalStatus('approved');
      }
      if (!mounted) return;

      setState(() {
        _vehicleDocsApproved = canGo;
        _hasExpiredDocs = expired;
        _docStatusLoaded = true;
      });
      _btnColorCtrl.value = 1.0;
    } catch (e) {
      debugPrint('[DriverHome] _checkVehicleDocStatus error: $e');
      // On error, fail-closed: require docs to be explicitly approved
      if (mounted) {
        setState(() {
          _vehicleDocsApproved = false;
          _docStatusLoaded = true;
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════
  //  REAL-TIME DOC APPROVAL LISTENER
  //  Fires immediately when admin approves docs in Firestore,
  //  so the driver doesn't need to restart the app.
  // ═══════════════════════════════════════════════════
  Future<void> _startDocApprovalListener() async {
    try {
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
    } catch (e) {
      debugPrint('[DriverHome] Firebase Auth for doc listener failed: $e');
      return;
    }

    final user = await UserSession.getUser();
    final userIdStr = user?['userId'] ?? '';
    final userIdInt = int.tryParse(userIdStr) ?? 0;
    if (userIdInt <= 0) return;

    final docId = 'sql_$userIdInt';
    _docApprovalSub?.cancel();
    _docApprovalSub = FirebaseFirestore.instance
        .collection('verifications')
        .doc(docId)
        .snapshots()
        .listen((snap) {
      if (!mounted || !snap.exists) return;
      final data = snap.data() ?? {};
      final status = data['status'] as String? ??
          data['verificationStatus'] as String? ??
          data['approvalStatus'] as String? ??
          '';
      final isApproved = status == 'approved' ||
          status == 'active' ||
          data['isVerified'] == true ||
          data['isApproved'] == true;
      if (isApproved && !_vehicleDocsApproved) {
        debugPrint('[DriverHome] Firestore doc-approval listener fired — refreshing doc status');
        _checkVehicleDocStatus();
      }
    }, onError: (e) {
      debugPrint('[DriverHome] Doc approval listener error: $e');
    });
  }

  // ═══════════════════════════════════════════════════
  //  GO ONLINE — navigate to DriverOnlineScreen
  // ═══════════════════════════════════════════════════
  void _goOnline() async {
    // Show immediate feedback — button will display loading state
    setState(() => _isNavigatingToOnline = true);

    // _ensureVerified is always synchronous — inline the check
    if (!_isVerified) setState(() => _isVerified = true);

    // If doc status has loaded, enforce doc gates synchronously (no await)
    if (_docStatusLoaded) {
      // If docs expired, navigate to documents page to re-upload
      if (_hasExpiredDocs) {
        HapticService.mediumImpact();
        await Navigator.of(context).push(
          slideFromRightRoute(const DriverDocumentsScreen()),
        );
        if (mounted) await _checkVehicleDocStatus();
        return;
      }

      // If vehicle docs not approved, navigate to documents page
      if (!_vehicleDocsApproved) {
        HapticService.mediumImpact();
        await Navigator.of(context).push(
          slideFromRightRoute(const DriverDocumentsScreen()),
        );
        if (mounted) await _checkVehicleDocStatus();
        return;
      }
    }
    // else: doc status not loaded yet — don't block. The online screen's
    // _verifyAndGoOnline() will handle the backend check in background.
    // Driver already passed splash/login approval gates to reach this screen.

    // Quick check: if we already know there's an active trip, resume immediately
    if (_activeTripData != null) {
      await _resumeActiveTrip();
      return;
    }

    // Resolve driver ID in background — don't block navigation
    if (_driverId == null) {
      unawaited(_resolveDriverId());
    }

    // Navigate immediately — no waiting on API calls.
    //
    // 2026-04-27 freeze fix:
    //   The old order was haptic + sound + push, which stacked three
    //   MethodChannel round-trips on the same frame the route transition
    //   was supposed to start animating. Result: ~1s freeze the moment
    //   the driver tapped Go Online.
    //
    //   New order: kick off the navigation FIRST (its animation now owns
    //   the next frames cleanly), then schedule haptic + sound on the
    //   post-frame callback so they cross the platform boundary AFTER
    //   the route transition has begun.
    final pushFuture = Navigator.of(context).push<Map<String, dynamic>>(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (ctx, anim1, anim2) =>
            DriverOnlineScreen(photoUrl: _photoUrl, initialPos: _currentLatLng, initialHeading: 0),
        transitionDuration: const Duration(milliseconds: 420),
        reverseTransitionDuration: const Duration(milliseconds: 300),
        transitionsBuilder: (ctx2, anim, anim2b, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.02),
                end: Offset.zero,
              ).animate(curved),
              child: ScaleTransition(
                scale: Tween<double>(begin: 0.98, end: 1.0).animate(curved),
                child: child,
              ),
            ),
          );
        },
      ),
    );
    // Schedule haptic + sound after the route transition has owned the
    // first frame. WidgetsBinding.addPostFrameCallback fires once the
    // current build/layout phase is done, which is exactly when the
    // PageRouteBuilder transition kicks in — so the MethodChannel
    // round-trips happen in parallel with the fade/scale, not before.
    //
    // 2026-04-27 freeze fix #2: Defer haptic+sound an extra 300ms.
    // The haptic engine + AVAudioPlayer init on iOS can block the
    // platform thread for 200-400ms. If that happens during the first
    // 150ms of the fade+scale transition, the driver still feels a
    // ~1s freeze. By waiting 300ms the transition is already 75%
    // done and the user perceives it as smooth.
    // Sound + haptic: fire AFTER the route transition has finished its
    // first frames. Calling them synchronously here (or even on the
    // immediate post-frame) still stacks MethodChannel round-trips on the
    // 200ms fade/scale transition and the page freezes until the clip's
    // platform-channel work settles. A 300ms deferral lets the transition
    // complete first, so the screen never freezes while the sound plays.
    Future.delayed(const Duration(milliseconds: 300), () {
      HapticService.lightImpact();
      NotificationService.playOnlineSound();
    });
    final result = await pushFuture;
    if (!mounted) return;
    setState(() => _isNavigatingToOnline = false);
    final stillOnline = result?['stillOnline'] == true;
    setState(() => _isStillOnline = stillOnline);
    PrefsCache.instance.then((p) => p.setBool('driver_was_online', stillOnline));
    _refreshStats();
    if (stillOnline) {
      _startTripPolling();
      // Immediately check for an active trip so the Resume button appears
      // without waiting for the 15-second poll interval.
      unawaited(_refreshActiveTripStatus());
    } else {
      _stopTripPolling();
    }
  }

  /// Resolve driver ID (used by polling and other callers).
  Future<void> _resolveDriverId() async {
    try {
      final id = await ApiService.getCurrentUserId();
      if (id != null && mounted) {
        _driverId = id;
      }
    } catch (_) {}
  }

  /// Resolve driver ID first, THEN check Firestore for active trip.
  /// This prevents the race where _refreshActiveTripStatus runs with null _driverId.
  Future<void> _resolveDriverIdThenRefresh() async {
    await _resolveDriverId();
    if (_driverId != null && mounted) {
      await _refreshActiveTripStatus();
      // Auto-navigate to active trip on cold start (same as background resume)
      if (_activeTripData != null && mounted) {
        _resumeActiveTrip();
      }
    }
  }

  void _startTripPolling() {
    _tripPollTimer?.cancel();
    _tripPollTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !_isStillOnline) {
        _tripPollTimer?.cancel();
        return;
      }
      _pollForTrips();
    });
  }

  void _stopTripPolling() {
    _tripPollTimer?.cancel();
    _tripPollTimer = null;
  }

  Future<void> _pollForTrips() async {
    if (_driverId == null) {
      await _resolveDriverId();
      if (_driverId == null) return;
    }
    await _refreshActiveTripStatus();
    if (_activeTripData != null) {
      // Active trip found — auto-resume it immediately
      _stopTripPolling();
      if (mounted) _resumeActiveTrip();
      return;
    }
    try {
      final offers = await ApiService.getDriverPendingOffers(_driverId!);
      if (!mounted || !_isStillOnline) return;
      if (offers.isNotEmpty) {
        // Trip arrived! Redirect to online screen
        _stopTripPolling();
        HapticService.heavyImpact();
        _navigateToOnlineScreen();
      }
    } catch (_) {}
  }

  void _navigateToOnlineScreen() async {
    if (_driverId == null) {
      await _resolveDriverId();
    }

    await _refreshActiveTripStatus();
    if (!mounted) return;
    if (_activeTripData != null) {
      await _resumeActiveTrip();
      return;
    }
    if (!mounted) return;
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      PageRouteBuilder(
        opaque: true,
        pageBuilder: (ctx, anim1, anim2) =>
            DriverOnlineScreen(photoUrl: _photoUrl, initialPos: _currentLatLng),
        transitionDuration: const Duration(milliseconds: 400),
        reverseTransitionDuration: const Duration(milliseconds: 350),
        transitionsBuilder: (ctx2, anim, anim2b, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.97, end: 1.0).animate(curved),
              child: child,
            ),
          );
        },
      ),
    );
    if (!mounted) return;
    final stillOnline = result?['stillOnline'] == true;
    setState(() => _isStillOnline = stillOnline);
    PrefsCache.instance.then((p) => p.setBool('driver_was_online', stillOnline));
    _refreshStats();
    if (stillOnline) {
      _startTripPolling();
      // Immediately check for an active trip so the Resume button appears
      // without waiting for the 15-second poll interval.
      unawaited(_refreshActiveTripStatus());
    } else {
      _stopTripPolling();
    }
  }

  // ═══════════════════════════════════════════════════
  //  BOTTOM NAVIGATION BAR
  // ═══════════════════════════════════════════════════
  Widget _buildBottomNav(dynamic dc) {
    return NavigationBar(
      backgroundColor: const Color(0xFF1A1A1F),
      indicatorColor: const Color(0xFFE8C547).withValues(alpha: 0.15),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      selectedIndex: _navIndex,
      onDestinationSelected: (i) {
        HapticService.selectionClick();
        if (i == 0) { setState(() => _navIndex = 0); return; }
        setState(() => _navIndex = i);
        final route = i == 1
            ? slideFromRightRoute(const DriverEarningsScreen())
            : i == 2
                ? slideFromRightRoute(const DriverTripHistoryScreen())
                : slideFromRightRoute(const DriverMenuScreen());
        Navigator.of(context).push(route).then((_) {
          if (mounted) setState(() => _navIndex = 0);
        });
      },
      destinations: [
        NavigationDestination(
          icon: Icon(Icons.map_outlined, color: Colors.white.withValues(alpha: 0.5), size: 22),
          selectedIcon: const Icon(Icons.map_rounded, color: Color(0xFFE8C547), size: 22),
          label: S.of(context).homeNav,
        ),
        NavigationDestination(
          icon: Icon(Icons.attach_money_rounded, color: Colors.white.withValues(alpha: 0.5), size: 22),
          selectedIcon: const Icon(Icons.attach_money_rounded, color: Color(0xFFE8C547), size: 22),
          label: S.of(context).earningsNav,
        ),
        NavigationDestination(
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.history_rounded, color: Colors.white.withValues(alpha: 0.5), size: 22),
            ],
          ),
          selectedIcon: const Icon(Icons.history_rounded, color: Color(0xFFE8C547), size: 22),
          label: S.of(context).tripsNav,
        ),
        NavigationDestination(
          icon: _unreadCount > 0
              ? Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Icon(Icons.person_outline_rounded, color: Colors.white.withValues(alpha: 0.5), size: 22),
                    Positioned(
                      top: -4,
                      right: -4,
                      child: Container(
                        width: 10,
                        height: 10,
                        decoration: const BoxDecoration(
                          color: Color(0xFFEF4444),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ],
                )
              : Icon(Icons.person_outline_rounded, color: Colors.white.withValues(alpha: 0.5), size: 22),
          selectedIcon: const Icon(Icons.person_rounded, color: Color(0xFFE8C547), size: 22),
          label: S.of(context).accountNav,
        ),
      ],
    );
  }

  // ═══════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════
  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final panelH =
        _panelCollapsedH + (_panelExpandedH - _panelCollapsedH) * panelExtent;

    final dc = DriverColors.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          // ── Full-screen map ──
          _buildMap(),

          // ── Top gradient overlay ──
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: Container(
              height: pad.top + 80,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    neuBase.withValues(alpha: 0.85),
                    neuBase.withValues(alpha: 0.0),
                  ],
                ),
              ),
            ),
          ),

          // ── Top bar: menu + greeting + inbox ──
          Positioned(
            top: pad.top + 12,
            left: 16,
            right: 16,
            child: _buildTopBar(),
          ),

          // ── Floating GO button (centered above bottom panel) ──
          Positioned(
            bottom: pad.bottom + panelH + 16,
            left: 0,
            right: 0,
            child: Center(
              child: FadeTransition(opacity: _fabScale, child: _buildGoButton()),
            ),
          ),

          // ── Draggable bottom panel ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildDraggablePanel(pad),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  MAP
  // ═══════════════════════════════════════════════════
  Widget _buildMap() {
    // Use Google Maps on both iOS and Android
    final dc = DriverColors.of(context);
    // Mapbox Maps Flutter has no web implementation — its MapWidget crashes
    // during the first layout. On web show a static placeholder instead.
    if (kIsWeb) {
      return Container(
        decoration: neuBox(radius: 24),
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.map_outlined,
                color: const Color(0xFFE8C547).withValues(alpha: 0.5),
                size: 44,
              ),
              const SizedBox(height: 10),
              Text(
                'Map preview is not available on web',
                style: TextStyle(
                  color: dc.textSecondary,
                  fontSize: 13,
                ),
              ),
            ],
          ),
        ),
      );
    }
    // FIX: Always show map, even if GPS hasn't loaded yet. Use default location
    // and move camera when GPS arrives. Prevents blank screen on slow GPS.
    final pos = _currentLatLng ?? const LatLng(40.7128, -74.0060);

    return RepaintBoundary(
      child: mapbox.MapWidget(
        styleUri: MapboxConfig.styleDark,
        cameraOptions: mapbox.CameraOptions(
          center: mapbox.Point(coordinates: mapbox.Position(pos.longitude, pos.latitude)),
          zoom: 16.0,
          pitch: 0.0,
          bearing: 0.0,
        ),
        // FIX: textureView works on more devices than surfaceView (default)
        textureView: true,
        onMapCreated: (ctrl) async {
          try {
            _mapController = ctrl;
            // Cache controller for reuse across driver screens
            MapControllerCache.instance.cache(ctrl);
            // Disable Mapbox native puck IMMEDIATELY before any annotation creation
            await ctrl.location.updateSettings(mapbox.LocationComponentSettings(enabled: false));
            
            // FIX: Create annotation manager with error handling
            try {
              _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
            } catch (e) {
              debugPrint('[DriverMap] Failed to create annotation manager: $e');
            }
            
            if (_pointAnnotMgr != null) {
              try {
                await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
                await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true);
              } catch (_) {}
            }
            
            setState(() => _mapReady = true);

            // A fresh manager means any annotation we still hold belongs to
            // the previous platform view (Android destroys it in background)
            // and can never be updated again. Drop it, draw the dot on the
            // new map right away, and re-arm the watchdog in case this ran
            // before the first GPS fix.
            _myLocAnnot = null;
            _updateMyLocAnnotation();
            _startDotCreateWatchdog();
          } catch (e) {
            debugPrint('[DriverMap] onMapCreated error: $e');
          }
        },
        onStyleLoadedListener: (_) async {
          try {
            if (_mapController != null) {
              // Re-disable puck after style reload (Mapbox may re-enable it)
              await _mapController!.location.updateSettings(mapbox.LocationComponentSettings(enabled: false));
              await _applyNavyGoldTheme(_mapController!);
              if (_pointAnnotMgr != null) {
                try {
                  await _mapController!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                  await _mapController!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
                  await _mapController!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true);
                } catch (_) {}
              }
            }
          } catch (e) {
            debugPrint('[DriverMap] onStyleLoaded error: $e');
          }
        },
        // FIX: Catch map load errors
        onMapLoadErrorListener: (err) {
          debugPrint('[DriverMap] Load error: ${err.message} (type: ${err.type})');
        },
      ),
    );
  }

  Future<Uint8List> _buildGoldPuckImage() async {
    const size = 24.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    final center = Offset(size / 2, size / 2);
    canvas.drawCircle(center, size / 2, Paint()..color = Colors.white);
    canvas.drawCircle(center, size / 2 - 3, Paint()..color = const Color(0xFFE8C547));
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes!.buffer.asUint8List();
  }

  // ── Dark navy + gold freeway theme ──
  Future<void> _applyNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
  }

  // ═══════════════════════════════════════════════════
  //  TOP BAR
  // ═══════════════════════════════════════════════════
  Widget _buildTopBar() {
    final dc = DriverColors.of(context);
    return Row(
      children: [
        // Menu
        _glassBtn(
          Icons.menu_rounded,
          onTap: () {
            HapticService.selectionClick();
            Navigator.of(context).push(
              PageRouteBuilder(
                pageBuilder: (ctx, a, sa) => const DriverMenuScreen(),
                transitionDuration: const Duration(milliseconds: 350),
                reverseTransitionDuration: const Duration(milliseconds: 300),
                transitionsBuilder: (ctx2, anim, sa, child) {
                  return FadeTransition(
                    opacity: CurvedAnimation(
                      parent: anim,
                      curve: Curves.easeInOut,
                    ),
                    child: child,
                  );
                },
              ),
            );
          },
        ),

        const SizedBox(width: 12),

        // Greeting pill — raised neumorphic surface.
        Expanded(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: Responsive.w(16), vertical: Responsive.h(10)),
            decoration: neuBox(radius: 28),
            child: Row(
              children: [
                // Avatar with gold border
                VerifiedAvatar(
                  photoUrl: UserSession.photoUrlNotifier.value.isNotEmpty
                      ? UserSession.photoUrlNotifier.value
                      : (_photoUrl != null && _photoUrl!.startsWith('http') ? _photoUrl : null),
                  photoPath: _photoUrl != null && !_photoUrl!.startsWith('http') ? _photoUrl : null,
                  radius: Responsive.w(18),
                  fallbackName: _driverName,
                  uid: UserSession.currentUid,
                  role: 'driver',
                  isVerified: _isVerified,
                ),
                SizedBox(width: Responsive.w(10)),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _getGreeting(context),
                        style: TextStyle(
                          color: dc.textSecondary,
                          fontSize: Responsive.sp(11),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _driverName,
                        style: TextStyle(
                          color: dc.text,
                          fontSize: Responsive.sp(15),
                          fontWeight: FontWeight.w800,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Text(
                  'CRUISE',
                  style: TextStyle(
                    color: _gold.withValues(alpha: 0.35),
                    fontSize: Responsive.sp(9),
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2,
                  ),
                ),
              ],
            ),
          ),
        ),

        const SizedBox(width: 12),

        // Scheduled rides marketplace
        _glassBtn(
          Icons.event_note_rounded,
          badge: _scheduledAvailableCount > 0 ? _scheduledAvailableCount : null,
          onTap: () {
            HapticService.selectionClick();
            Navigator.of(context).push(
              slideFromRightRoute(const ScheduledRidesScreen()),
            );
          },
        ),

      ],
    );
  }

  /// Fetch count of available scheduled rides matching driver's vehicle type.
  int _lastNotifiedScheduledCount = 0;
  Future<void> _refreshScheduledCount() async {
    if (!_isStillOnline || _activeTripData != null) return;
    try {
      final trips = await ApiService.getAvailableScheduledTrips(lat: 0, lng: 0, radiusKm: 100);
      if (!mounted) return;
      final newCount = trips.length;
      // Backend sends FCM push to 'drivers_available' topic when new scheduled
      // rides enter the marketplace. No local notification needed here — the
      // OS shows the push when the app is backgrounded, and the banner below
      // handles the in-app visual cue.
      _lastNotifiedScheduledCount = newCount;
      setState(() => _scheduledAvailableCount = newCount);
    } catch (_) {}
  }

  /// Animated banner above "Finding trips" showing scheduled ride count.
  Widget _buildScheduledRidesBanner() {
    if (_scheduledAvailableCount == 0) return const SizedBox.shrink();
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        Navigator.of(context).push(
          slideFromRightRoute(const ScheduledRidesScreen()),
        );
      },
      child: TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.0, end: 1.0),
        duration: const Duration(milliseconds: 500),
        curve: Curves.easeOutBack,
        builder: (context, scale, child) => Transform.scale(
          scaleY: scale,
          alignment: Alignment.topCenter,
          child: child,
        ),
        child: Container(
          margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: neuBox(
            radius: 16,
            borderColor: _gold.withValues(alpha: 0.35),
          ),
          child: Row(
            children: [
              const Icon(Icons.event_available_rounded, color: _gold, size: 18),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  S.of(context).scheduledRidesAvailableLabel(_scheduledAvailableCount),
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              const Icon(Icons.chevron_right_rounded, color: _gold, size: 18),
            ],
          ),
        ),
      ),
    );
  }

  String _getGreeting(BuildContext context) {
    final s = S.of(context);
    final h = DateTime.now().hour;
    if (h < 12) return s.goodMorning;
    if (h < 17) return s.goodAfternoon;
    return s.goodEvening;
  }

  Widget _glassBtn(IconData icon, {required VoidCallback onTap, int? badge}) {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: Responsive.w(48),
            height: Responsive.w(48),
            decoration: neuBox(radius: 14, pressed: true),
            child: Icon(icon, color: dc.text, size: Responsive.sp(22)),
          ),
          if (badge != null)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                width: Responsive.w(18),
                height: Responsive.w(18),
                decoration: const BoxDecoration(
                  color: Color(0xFFEF4444),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '$badge',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: Responsive.sp(10),
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildRecenterBtn() {
    return GestureDetector(
      onTap: () {
        if (_currentLatLng != null) {
          _mapController?.flyTo(
            mapbox.CameraOptions(
              center: mapbox.Point(coordinates: mapbox.Position(_currentLatLng!.longitude, _currentLatLng!.latitude)),
              zoom: 16, pitch: 45,
            ),
            mapbox.MapAnimationOptions(duration: 600),
          );
        }
      },
      child: Container(
        width: 48,
        height: 48,
        decoration: neuBox(radius: 14, pressed: true),
        child: const Icon(
          Icons.my_location_rounded,
          color: _gold,
          size: 22,
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  FLOATING GO BUTTON — inner pulse glow
  // ═══════════════════════════════════════════════════
  Widget _buildGoButton() {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: _isVerified
          ? _goOnline
          : () async {
              await _ensureVerified();
            },
      child: AnimatedBuilder(
        animation: Listenable.merge([_pulseAnim, _btnColorAnim, _glossCtrl]),
        builder: (_, __) {
          final p = _pulseAnim.value;
          final g = _glossCtrl.value;
          final docsOk = _vehicleDocsApproved || !_docStatusLoaded;
          // Disabled when docs missing or not verified — sunken neu well.
          final enabled = _isVerified && docsOk;

          const goldTop1 = Color(0xFFF0D060);
          const goldTop2 = Color(0xFFF5DC7A);
          const goldBot = Color(0xFFD4A800);

          final topColor = Color.lerp(goldTop1, goldTop2, p)!;
          final botColor = goldBot;
          final glowColor = _gold;

          final fgColor = enabled ? Colors.black87 : dc.textSecondary;

          return ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: Stack(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
                  decoration: enabled
                      ? BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: glowColor.withValues(alpha: 0.3 + 0.15 * p),
                              blurRadius: 16 + 8 * p,
                              spreadRadius: 0,
                              offset: const Offset(0, 3),
                            ),
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.28),
                              blurRadius: 10,
                              offset: const Offset(0, 2),
                            ),
                          ],
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [topColor, botColor],
                          ),
                        )
                      : neuBox(radius: 16, pressed: true),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        width: 28,
                        height: 28,
                        decoration: BoxDecoration(
                          color: enabled
                              ? Colors.black.withValues(alpha: 0.15)
                              : Colors.white.withValues(alpha: 0.08),
                          shape: BoxShape.circle,
                        ),
                        child: _isNavigatingToOnline
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  color: enabled ? Colors.black87 : _gold,
                                  strokeWidth: 2,
                                ),
                              )
                            : Icon(
                                !docsOk
                                    ? (_hasExpiredDocs ? Icons.warning_amber_rounded : Icons.upload_file_rounded)
                                    : (_activeTripData != null || _isStillOnline)
                                        ? Icons.play_arrow_rounded
                                        : Icons.power_settings_new_rounded,
                                color: fgColor,
                                size: 16,
                              ),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        _isNavigatingToOnline
                            ? 'GOING ONLINE...'
                            : _isVerified
                                ? (!docsOk
                                    ? (_hasExpiredDocs ? 'EXPIRED DOCS' : 'DOCUMENTS')
                                    : (_activeTripData != null || _isStillOnline)
                                        ? S.of(context).resumeOnline
                                        : S.of(context).goOnline)
                                : S.of(context).verifyFirst,
                        style: TextStyle(
                          color: fgColor,
                          fontSize: 14,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ],
                  ),
                ),
                // ── Gloss shimmer sweep (enabled state only) ──
                if (enabled)
                  Positioned.fill(
                    child: IgnorePointer(
                      child: Transform.translate(
                        offset: Offset((g * 3.0 - 1.0) * 200, 0), // sweep left to right
                        child: Container(
                          width: 60,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                Colors.white.withValues(alpha: 0.0),
                                Colors.white.withValues(alpha: 0.18),
                                Colors.white.withValues(alpha: 0.0),
                              ],
                              stops: const [0.0, 0.5, 1.0],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  DRAGGABLE BOTTOM PANEL (Uber Driver style)
  // ═══════════════════════════════════════════════════
  Widget _buildDraggablePanel(EdgeInsets pad) {
    final dc = DriverColors.of(context);
    final panelH =
        _panelCollapsedH + (_panelExpandedH - _panelCollapsedH) * panelExtent;
    final hasActiveTrip = _activeTripData != null;

    return GestureDetector(
      // Consume taps so panel never opens on tap — swipe-only
      onTap: () {},
      child: Container(
      height: panelH + pad.bottom,
      decoration: BoxDecoration(
        // Raised neumorphic sheet — neuBox can't express top-only radius,
        // so replicate its dual-shadow treatment on neuSurface.
        color: neuSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            offset: const Offset(6, 6),
            blurRadius: 14,
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.045),
            offset: const Offset(-4, -4),
            blurRadius: 10,
          ),
        ],
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.04)),
        ),
      ),
      child: Column(
        children: [
          // ── Drag handle — drag only registered here ──
          GestureDetector(
            behavior: HitTestBehavior.translucent,
            onVerticalDragStart: (_) => setState(() => _dragging = true),
            onVerticalDragUpdate: (d) {
              setState(() => _dragging = true);
              updatePanelDrag(d.primaryDelta ?? 0);
            },
            onVerticalDragEnd: (d) {
              setState(() => _dragging = false);
              endPanelDrag(d.primaryVelocity ?? 0);
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 10, bottom: 6),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
            // ── Scheduled Rides Banner (only when online & no active trip) ──
            if (_isStillOnline && _activeTripData == null)
              _buildScheduledRidesBanner(),

            // ── Header row: photo | status | list — also draggable ──
            GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (_) => setState(() => _dragging = true),
              onVerticalDragUpdate: (d) {
                setState(() => _dragging = true);
                updatePanelDrag(d.primaryDelta ?? 0);
              },
              onVerticalDragEnd: (d) {
                setState(() => _dragging = false);
                endPanelDrag(d.primaryVelocity ?? 0);
              },
              child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
              child: Row(
                children: [
                  // Status text
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _isStillOnline
                              ? const Color(0xFF34C759)
                              : dc.text.withValues(alpha: 0.3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isStillOnline
                            ? S.of(context).findingTrips
                            : S.of(context).youreOffline,
                        style: TextStyle(
                          color: dc.text,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      HapticService.selectionClick();
                      Navigator.of(context).push(
                        slideFromRightRoute(const DriverTripHistoryScreen()),
                      );
                    },
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: neuBox(radius: 14, pressed: true),
                      child: Icon(
                        Icons.format_list_bulleted_rounded,
                        color: dc.textSecondary,
                        size: 20,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            ),
            // ── Panel content — hidden when collapsed; fades/slides in
            // proportionally to the drag for a fluid open gesture ──
            Expanded(
              child: Opacity(
                // 0 when closed → fully visible ~60% through the swipe up
                opacity: (panelExtent * 1.7).clamp(0.0, 1.0),
                child: FadeTransition(
                opacity: _statsAnim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, 0.05),
                    end: Offset.zero,
                  ).animate(_statsAnim),
                  child: SingleChildScrollView(
                    physics: const NeverScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                      Divider(
                        color: dc.divider,
                        height: 1,
                      ),
                      const SizedBox(height: 16),
                      // ── Today's stats row ──
                      Row(
                        children: [
                          _panelStat(
                            Icons.attach_money_rounded,
                            '\$${_todayEarnings.toStringAsFixed(2)}',
                            S.of(context).earningsToday,
                          ),
                          const SizedBox(width: 8),
                          _panelStat(
                            Icons.local_taxi_rounded,
                            '$_todayTrips',
                            S.of(context).tripsToday,
                          ),
                          const SizedBox(width: 8),
                          _panelStat(
                            Icons.schedule_rounded,
                            '${_todayHours.toStringAsFixed(1)}h',
                            S.of(context).hoursOnline,
                          ),
                        ],
                      ),
                      const SizedBox(height: 16),
                      Text(
                        S.of(context).recommendedForYou,
                        style: TextStyle(
                          color: dc.textSecondary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.1,
                        ),
                      ),
                      const SizedBox(height: 12),
                      // ── Recommendation items — raised neu group ──
                      Container(
                        decoration: neuBox(radius: 20),
                        child: Column(
                          children: [
                            _recommendItem(
                              Icons.bar_chart_rounded,
                              S.of(context).seeEarningsTrends,
                              () {
                                Navigator.of(context).push(
                                  slideFromRightRoute(const DriverEarningsScreen()),
                                );
                              },
                            ),
                            Divider(
                              height: 1,
                              indent: 68,
                              color: Colors.white.withValues(alpha: 0.05),
                            ),
                            _recommendItem(
                              Icons.star_outline_rounded,
                              S.of(context).seeUpcomingPromotions,
                              () {
                                Navigator.of(context).push(
                                  slideFromRightRoute(const DriverPromosScreen()),
                                );
                              },
                            ),
                            Divider(
                              height: 1,
                              indent: 68,
                              color: Colors.white.withValues(alpha: 0.05),
                            ),
                            _recommendItem(
                              Icons.schedule_rounded,
                              S.of(context).seeDrivingTime,
                              () {
                                Navigator.of(context).push(
                                  slideFromRightRoute(const DriverAnalyticsScreen()),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                      SizedBox(height: pad.bottom + 16),
                      ],
                    ),
                  ),
                  ),
                ),
              ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _recommendItem(IconData icon, String label, VoidCallback onTap) {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: neuBox(radius: 14, pressed: true),
              child: Icon(icon, color: _gold, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: dc.text,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: dc.textSecondary,
              size: 20,
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelStat(IconData icon, String value, String label) {
    final dc = DriverColors.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: neuBox(radius: 18),
        child: Column(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: neuBox(radius: 12, pressed: true),
              child: Icon(icon, color: _gold, size: 18),
            ),
            const SizedBox(height: 8),
            Text(
              value,
              style: TextStyle(
                color: dc.text,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: TextStyle(
                color: dc.textSecondary,
                fontSize: 12,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _quickStat(String value, String label, IconData icon) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, color: _gold, size: 18),
          const SizedBox(height: 6),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statDivider() {
    return Container(
      width: 1,
      height: 36,
      color: Colors.white.withValues(alpha: 0.06),
    );
  }

  Widget _actionTile(IconData icon, String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, color: _gold, size: 18),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.7),
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Map style now from MapStyles.dark (config/map_styles.dart)

  Future<void> _refreshActiveTripStatus() async {
    final driverId = _driverId;
    if (driverId == null) return;
    try {
      final snap = await FirebaseFirestore.instance
          .collection('trips')
          .where('status', whereIn: const [
            'accepted',
            'driver_arriving',
            'driver_en_route',
            'en_route_to_pickup',
            'arrived',
            'driver_arrived',
            'in_trip',
            'in_progress',
            'rider_onboard',
            'on_trip',
          ])
          .limit(25)
          .get();

      Map<String, dynamic>? active;
      for (final doc in snap.docs) {
        final data = doc.data();
        final rawDriverId = data['driverId'] ?? data['driver_id'];
        final rawDriverStr = (rawDriverId ?? '').toString().trim();
        final driverIdStr = driverId.toString();
        final matches = rawDriverStr == driverIdStr ||
            rawDriverStr == 'sql_$driverIdStr' ||
            rawDriverStr.replaceFirst(_sqlPrefixRe, '') == driverIdStr;
        if (matches) {
          active = {'_docId': doc.id, ...data};
          break;
        }
      }

      if (!mounted) return;
      setState(() {
        // Only overwrite if Firestore found a trip, OR if backend hasn't set one.
        // This prevents Firestore (empty cache) from erasing backend-found trip data.
        if (active != null) {
          _activeTripData = active;
          _isStillOnline = true;
        }
      });
    } catch (_) {
      // Keep current UI state if this lookup fails.
    }
  }

  /// Check backend for active trip (handles reinstall where Firestore cache
  /// may be empty). Auto-navigates to the trip screen on cold start.
  Future<void> _checkBackendActiveTrip() async {
    try {
      // Skip if Firestore already found an active trip
      if (_activeTripData != null) return;
      final trip = await ApiService.getActiveTrip();
      if (!mounted || trip == null) return;
      final status = (trip['status'] ?? '').toString();
      if (status == 'completed' || status == 'canceled' || status == 'cancelled') return;
      final activeStatuses = {'accepted', 'driver_en_route', 'driver_arriving',
          'en_route_to_pickup', 'arrived', 'driver_arrived', 'in_trip',
          'in_progress', 'rider_onboard', 'on_trip'};
      if (!activeStatuses.contains(status)) return;

      if (!mounted) return;
      setState(() {
        _activeTripData = trip;
        _isStillOnline = true;
      });
      // Auto-navigate to the active trip screen
      if (mounted) _resumeActiveTrip();
    } catch (e) {
      debugPrint('[DriverHome] Backend active trip check failed: $e');
    }
  }

  /// Check if driver has a scheduled ride approaching — navigate to details if locked.
  Future<void> _checkScheduledRideLockout() async {
    try {
      final data = await ApiService.getActiveScheduledTrip();
      if (!mounted) return;
      final hasTrip = data['has_scheduled_trip'] == true;
      final isLocked = data['is_locked'] == true;
      if (hasTrip && isLocked && data['trip'] != null) {
        final minutesUntil = (data['minutes_until'] as num?)?.toDouble() ?? 30;
        final trip = data['trip'] as Map<String, dynamic>;

        // ── Auto-start: <=15 min → start trip + navigate to trip screen directly ──
        // BUT only if driver doesn't already have an active trip
        if (minutesUntil <= 15 && _activeTripData == null) {
          try {
            final tripId = trip['id'] as int;
            await ApiService.startScheduledTrip(tripId);
            if (!mounted) return;
            _navigateToScheduledTripScreen(trip);
          } catch (e) {
            debugPrint('[DriverHome] Auto-start scheduled trip failed: $e — showing countdown instead');
            if (!mounted) return;
            _showScheduledCountdown(trip, minutesUntil);
          }
          return;
        }

        // ── >15 min but locked → show countdown screen ──
        _showScheduledCountdown(trip, minutesUntil);
      }
    } catch (e) {
      debugPrint('[DriverHome] Scheduled ride check failed: $e');
    }
  }

  void _showScheduledCountdown(Map<String, dynamic> trip, double minutesUntil) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => ScheduledRideDetailsScreen(
          trip: trip,
          minutesUntil: minutesUntil,
        ),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 500),
        reverseTransitionDuration: const Duration(milliseconds: 400),
      ),
    );
  }

  /// Navigate directly to DriverTripAcceptScreen for a scheduled trip.
  void _navigateToScheduledTripScreen(Map<String, dynamic> trip) {
    final pickupLat = _pickDouble(trip, ['pickup_lat']);
    final pickupLng = _pickDouble(trip, ['pickup_lng']);
    final dropoffLat = _pickDouble(trip, ['dropoff_lat']);
    final dropoffLng = _pickDouble(trip, ['dropoff_lng']);
    if (pickupLat == null || pickupLng == null ||
        dropoffLat == null || dropoffLng == null) {
      return;
    }

    final pickup = LatLng(pickupLat, pickupLng);
    final dropoff = LatLng(dropoffLat, dropoffLng);
    final driverPos = _currentLatLng ?? pickup;
    final distKm = _haversineKm(driverPos, pickup);
    final etaMinutes = ((distKm * 1000) / 17.88 / 60).ceil().clamp(1, 99);
    final tripId = (trip['id'] as num?)?.toInt() ?? 0;
    final riderName = _pickString(trip, ['rider_name'], fallback: 'Rider');
    final riderId = int.tryParse((trip['rider_id'] ?? '').toString());

    Navigator.of(context).push(
      slideFromRightRoute(
        DriverTripAcceptScreen(
          tripId: tripId,
          riderName: riderName,
          riderPhotoUrl: _normalizePhotoUrl(trip['rider_photo_url']?.toString() ?? ''),
          riderRating: (trip['rider_rating'] as num?)?.toDouble() ?? 0,
          riderIsNew: trip['rider_is_new'] == true,
          riderId: riderId,
          pickupLatLng: pickup,
          dropoffLatLng: dropoff,
          pickupAddress: _pickString(trip, ['pickup_address'], fallback: 'Pickup'),
          dropoffAddress: _pickString(trip, ['dropoff_address'], fallback: 'Drop-off'),
          fare: _pickDouble(trip, ['fare']) ?? 0,
          vehicleType: _pickString(trip, ['vehicle_type'], fallback: 'Comfort'),
          driverPos: driverPos,
          distToPickupKm: distKm,
          etaMinutes: etaMinutes,
          riderPhone: _pickString(trip, ['rider_phone']),
          tripAlreadyStarted: true,
        ),
      ),
    );
  }

  Future<void> _resumeActiveTrip() async {
    // Idempotency guard — 6 callers, any two firing concurrently would
    // push DriverTripAcceptScreen twice.
    if (_resumingActiveTrip) {
      debugPrint('[DriverHome] _resumeActiveTrip skipped — already in progress');
      return;
    }
    // Don't re-push DriverTripAcceptScreen if DriverHomeScreen is not the
    // topmost route — that means a trip screen is already on the stack and
    // pushing another one on top would reset its local state (the Arrived
    // slider, Start Ride button, etc.) back to phase 1. This fires on every
    // app-resume after the driver used Google Maps for turn-by-turn.
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      debugPrint('[DriverHome] _resumeActiveTrip skipped — another route is on top');
      return;
    }
    _resumingActiveTrip = true;
    try {
      await _resumeActiveTripBody();
    } finally {
      _resumingActiveTrip = false;
    }
  }

  Future<void> _resumeActiveTripBody() async {
    // Use existing trip data immediately — don't block on Firestore.
    // Refresh in background for status updates, but navigate instantly.
    if (_activeTripData != null) {
      unawaited(_refreshActiveTripStatus());
    } else {
      // No cached data — must fetch before navigating
      await _refreshActiveTripStatus();
    }
    final trip = _activeTripData;
    if (!mounted || trip == null) return;

    final pickupLat = _pickDouble(trip, ['pickupLat', 'pickup_lat']);
    final pickupLng = _pickDouble(trip, ['pickupLng', 'pickup_lng']);
    final dropoffLat = _pickDouble(trip, ['dropoffLat', 'dropoff_lat']);
    final dropoffLng = _pickDouble(trip, ['dropoffLng', 'dropoff_lng']);
    if (pickupLat == null || pickupLng == null || dropoffLat == null || dropoffLng == null) {
      return;
    }

    final pickup = LatLng(pickupLat, pickupLng);
    final dropoff = LatLng(dropoffLat, dropoffLng);
    final driverPos = _currentLatLng ?? pickup;
    final tripId = _pickInt(trip, ['id', 'tripId', 'trip_id']) ?? int.tryParse((trip['_docId'] ?? '').toString()) ?? 0;
    final riderName = _pickString(trip, ['riderName', 'rider_name', 'passengerName', 'passenger_name'], fallback: 'Rider');
    final riderPhone = _pickString(trip, ['rider_phone', 'passengerPhone', 'passenger_phone']);
    final pickupAddress = _pickString(trip, ['pickupAddress', 'pickup_address'], fallback: 'Pickup');
    final dropoffAddress = _pickString(trip, ['dropoffAddress', 'dropoff_address'], fallback: 'Drop-off');
    final fare = _pickDouble(trip, ['fare']) ?? 0;
    final vehicleType = _pickString(trip, ['vehicleType', 'vehicle_type'], fallback: 'Ride');

    final distKm = _haversineKm(driverPos, pickup);
    final etaMinutes = ((distKm * 1000) / 17.88 / 60).ceil().clamp(1, 99);

    // Determine trip phase from Firestore status so the screen resumes
    // at the correct phase instead of resetting to "Slide Start Trip".
    final status = _pickString(trip, ['status'], fallback: 'accepted');
    final arrivedAtPickup = (status == 'arrived' || status == 'driver_arrived');
    final rideStarted = (status == 'in_trip' || status == 'in_progress' || status == 'rider_onboard');

    // Extract rider SQL integer ID from riderId/passengerId ("sql_123" → 123)
    final passengerIdRaw = _pickString(trip, ['riderId', 'rider_id', 'passengerId', 'passenger_id']);
    final resumeRiderId = int.tryParse(passengerIdRaw.replaceFirst('sql_', ''));

    await Navigator.of(context).push(
      slideFromRightRoute(
        DriverTripAcceptScreen(
          tripId: tripId,
          riderName: riderName,
          riderPhotoUrl: _normalizePhotoUrl(
            _pickString(trip, ['riderPhotoUrl', 'rider_photo_url', 'passengerPhotoUrl', 'passenger_photo_url']),
          ),
          riderRating: _pickDouble(trip, ['riderRating', 'rider_rating']) ?? 0,
          riderIsNew: trip['rider_is_new'] == true,
          riderId: resumeRiderId,
          pickupLatLng: pickup,
          dropoffLatLng: dropoff,
          pickupAddress: pickupAddress,
          dropoffAddress: dropoffAddress,
          fare: fare,
          vehicleType: vehicleType,
          driverPos: driverPos,
          distToPickupKm: distKm,
          etaMinutes: etaMinutes,
          riderPhone: riderPhone,
          pickupInstructions: _pickString(trip, ['pickupInstructions', 'pickup_instructions']),
          dropoffInstructions: _pickString(trip, ['dropoffInstructions', 'dropoff_instructions']),
          arrivedAtPickup: arrivedAtPickup,
          rideStarted: rideStarted,
          tripAlreadyStarted: true,
        ),
      ),
    );

    // After trip screen pops, re-check if the trip is still active.
    // If completed/cancelled, clear state and resume polling for new trips.
    // If still active, just refresh _activeTripData so RESUME button shows —
    // do NOT auto-navigate back (driver chose to go home).
    if (!mounted) return;
    await _refreshActiveTripStatus();
    if (_activeTripData == null && _isStillOnline) {
      _startTripPolling();
    }
  }

  double? _pickDouble(Map<String, dynamic> data, List<String> keys) {
    for (final k in keys) {
      final v = data[k];
      if (v is num) return v.toDouble();
      final parsed = double.tryParse(v?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  int? _pickInt(Map<String, dynamic> data, List<String> keys) {
    for (final k in keys) {
      final v = data[k];
      if (v is int) return v;
      if (v is num) return v.toInt();
      final parsed = int.tryParse(v?.toString() ?? '');
      if (parsed != null) return parsed;
    }
    return null;
  }

  String _pickString(Map<String, dynamic> data, List<String> keys, {String fallback = ''}) {
    for (final k in keys) {
      final v = data[k]?.toString().trim();
      if (v != null && v.isNotEmpty) return v;
    }
    return fallback;
  }

  String _normalizePhotoUrl(String rawUrl) {
    final raw = rawUrl.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '${ApiService.publicBaseUrl}$raw';
    return '${ApiService.publicBaseUrl}/$raw';
  }

  double _haversineKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sa = math.sin(dLat / 2);
    final sb = math.sin(dLng / 2);
    final aa = sa * sa +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sb * sb;
    return r * 2 * math.atan2(math.sqrt(aa), math.sqrt(1 - aa));
  }
}
