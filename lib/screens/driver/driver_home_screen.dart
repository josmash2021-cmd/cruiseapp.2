import 'dart:async';
import 'dart:io' show File;
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
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
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);
  // ignore: unused_field
  static const _surface = Color(0xFF111111);
  static const _card = Color(0xFF1C1C1E);

  // ── Map ──
  mapbox.MapboxMap? _mapController;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PointAnnotation? _myLocAnnot;
  LatLng? _currentLatLng;
  // ignore: unused_field
  bool _mapReady = false;
  final GoldLocationDot _goldDot = GoldLocationDot();
  StreamSubscription<Position>? _posStream;

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
  // ignore: unused_field
  late Animation<double> _statsAnim;
  late AnimationController _fabCtrl;
  late Animation<double> _fabScale;

  // ── Bottom panel ──
  static const double _panelCollapsedH = 76.0;
  static const double _panelExpandedH = 380.0; // Increased for full content
  bool _dragging = false;

  // ── Inbox unread count ──
  int _unreadCount = 0;

  // ── Verification ──
  bool _isVerified = false;

  // ── Bottom nav ──
  int _navIndex = 0;

  // ── Online state (driver pressed back but is still connected) ──
  bool _isStillOnline = false;
  Timer? _tripPollTimer;
  Timer? _statsRefreshTimer;
  int? _driverId;
  Map<String, dynamic>? _activeTripData;

  // ── Vehicle document approval ──
  bool _vehicleDocsApproved = false;
  bool _hasExpiredDocs = false;
  bool _docStatusLoaded = false;
  late AnimationController _btnColorCtrl;
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
        statusBarBrightness: Brightness.dark,
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
      duration: const Duration(milliseconds: 800),
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
    _goldDot.build(() {
      if (mounted) {
        setState(() {});
        _syncDotAnnotation(); // Keep dot pulsing on map
      }
    });
    _initLocation();
    _loadDriverData();
    _checkVerification().then((_) => _checkVehicleDocStatus());
    // Start account status polling immediately
    _checkAccountStatus();
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

  Future<void> _registerFcmToken() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      final token = await messaging.getToken();
      if (token != null) ApiService.saveFcmToken(token);
      messaging.onTokenRefresh.listen((t) => ApiService.saveFcmToken(t));
    } catch (_) {}
  }

  @override
  void dispose() {
    disposePanelAnimation();
    _pulseCtrl.dispose();
    _glossCtrl.dispose();
    _btnColorCtrl.dispose();
    _statsCtrl.dispose();
    _fabCtrl.dispose();
    _goldDot.dispose();
    _posStream?.cancel();
    _accountStatusTimer?.cancel();
    _tripPollTimer?.cancel();
    _statsRefreshTimer?.cancel();
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

  Future<void> _updateMyLocAnnotation() async {
    if (_updatingLocAnnot) return;
    _updatingLocAnnot = true;
    try {
      final mgr = _pointAnnotMgr;
      if (mgr == null) return;
      final bytes = _goldDot.currentBytes;
      if (bytes == null) return;

      // Use interpolated position from GoldLocationDot for smooth gliding
      final lat = _goldDot.lat ?? _currentLatLng?.latitude;
      final lng = _goldDot.lng ?? _currentLatLng?.longitude;
      if (lat == null || lng == null) return;

      final point = mapbox.Point(coordinates: mapbox.Position(lng, lat));

      if (_myLocAnnot == null) {
        _myLocAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: point,
          image: bytes,
          iconSize: 1.0,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      } else {
        _myLocAnnot!.geometry = point;
        _myLocAnnot!.image = bytes;
        try { await mgr.update(_myLocAnnot!); } catch (_) {}
      }
    } finally {
      _updatingLocAnnot = false;
    }
  }

  /// Re-sync the location dot annotation whenever the dot animation frame changes.
  void _syncDotAnnotation() {
    if (!mounted) return;
    _updateMyLocAnnotation();
  }

  // ═══════════════════════════════════════════════════
  //  ACCOUNT STATUS CHECK
  // ═══════════════════════════════════════════════════
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

      // ── Real-time GPS stream (high accuracy, 10m filter — battery-friendly) ──
      _posStream?.cancel();
      _posStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
        ),
      ).listen((p) {
        if (!mounted) return;
        final ll = LatLng(p.latitude, p.longitude);
        _currentLatLng = ll;
        _goldDot.setTarget(ll.latitude, ll.longitude);
        // Camera follows smoothly — dot glides via GoldLocationDot interpolation
        _mapController?.flyTo(
          mapbox.CameraOptions(
            center: mapbox.Point(coordinates: mapbox.Position(ll.longitude, ll.latitude)),
            zoom: 16.0,
            pitch: 0.0,
            bearing: 0.0,
          ),
          mapbox.MapAnimationOptions(duration: 800, startDelay: 0),
        );
      });
    } catch (_) {}
  }

  Future<void> _loadDriverData() async {
    // Cache-first: show last-known data instantly
    final prefs = PrefsCache.instanceSync ?? await PrefsCache.instance;
    final cachedName = prefs.getString('driver_cached_name');
    final cachedEarnings = prefs.getDouble('driver_cached_earnings');
    final cachedTrips = prefs.getInt('driver_cached_trips');
    if (cachedName != null && mounted) {
      setState(() {
        _driverName = cachedName;
        _todayEarnings = cachedEarnings ?? 0.0;
        _todayTrips = cachedTrips ?? 0;
      });
    }

    // Background refresh from API
    final results = await Future.wait([
      ApiService.getMe().catchError((_) => null),
      ApiService.getDriverEarnings(period: 'today').catchError((_) => <String, dynamic>{}),
      ApiService.getNotifications().catchError((_) => <Map<String, dynamic>>[]),
    ]);

    if (!mounted) return;
    final me = results[0] as Map<String, dynamic>?;
    final earnings = results[1] as Map<String, dynamic>? ?? {};
    final notifs = results[2] as List<dynamic>? ?? [];

    setState(() {
      if (me != null) {
        final firstName = me['first_name'] ?? 'Driver';
        final lastName = me['last_name'] ?? '';
        _driverName = lastName.isNotEmpty
            ? '$firstName ${lastName[0].toUpperCase()}.'
            : firstName;
        if (UserSession.photoNotifier.value.isNotEmpty) {
          _photoUrl = UserSession.photoNotifier.value;
        } else {
          final serverPhoto = me['photo_url']?.toString() ?? '';
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
      final result = await ApiService.canGoOnline();
      if (!mounted) return;

      final canGo = result['can_go_online'] == true;
      final expired = result['has_expired_docs'] == true;

      // Sync approval status locally
      if (result['approved'] == true) {
        await LocalDataService.setDriverApprovalStatus('approved');
      }

      setState(() {
        _vehicleDocsApproved = canGo;
        _hasExpiredDocs = expired;
        _docStatusLoaded = true;
      });
      _btnColorCtrl.value = 1.0;
    } catch (e) {
      debugPrint('[DriverHome] _checkVehicleDocStatus error: $e');
      // On error don't block — let driver try to go online
      if (mounted) {
        setState(() {
          _vehicleDocsApproved = true;
          _docStatusLoaded = true;
        });
      }
    }
  }

  // ═══════════════════════════════════════════════════
  //  GO ONLINE — navigate to DriverOnlineScreen
  // ═══════════════════════════════════════════════════
  void _goOnline() async {
    if (!await _ensureVerified()) return;
    if (!mounted) return;

    // If docs expired, navigate to documents page to re-upload
    if (_hasExpiredDocs) {
      HapticFeedback.mediumImpact();
      await Navigator.of(context).push(
        slideFromRightRoute(const DriverDocumentsScreen()),
      );
      if (mounted) await _checkVehicleDocStatus();
      return;
    }

    // If vehicle docs not approved, navigate to documents page
    if (!_vehicleDocsApproved) {
      HapticFeedback.mediumImpact();
      await Navigator.of(context).push(
        slideFromRightRoute(const DriverDocumentsScreen()),
      );
      if (mounted) await _checkVehicleDocStatus();
      return;
    }

    // Quick check: if we already know there's an active trip, resume immediately
    if (_activeTripData != null) {
      await _resumeActiveTrip();
      return;
    }

    // Resolve driver ID in background — don't block navigation
    if (_driverId == null) {
      unawaited(_resolveDriverId());
    }

    // Navigate immediately — no waiting on API calls
    HapticFeedback.heavyImpact();
    NotificationService.playOnlineSound();
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (ctx, anim1, anim2) =>
            DriverOnlineScreen(photoUrl: _photoUrl),
        transitionDuration: const Duration(milliseconds: 500),
        reverseTransitionDuration: const Duration(milliseconds: 400),
        transitionsBuilder: (ctx2, anim, anim2b, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
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
    }
  }

  void _startTripPolling() {
    _tripPollTimer?.cancel();
    _tripPollTimer = Timer.periodic(const Duration(seconds: 15), (_) {
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
        HapticFeedback.heavyImpact();
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
        opaque: false,
        pageBuilder: (ctx, anim1, anim2) =>
            DriverOnlineScreen(photoUrl: _photoUrl),
        transitionDuration: const Duration(milliseconds: 500),
        reverseTransitionDuration: const Duration(milliseconds: 400),
        transitionsBuilder: (ctx2, anim, anim2b, child) {
          final curved = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
          return FadeTransition(
            opacity: curved,
            child: ScaleTransition(
              scale: Tween<double>(begin: 0.96, end: 1.0).animate(curved),
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
    } else {
      _stopTripPolling();
    }
  }

  // ═══════════════════════════════════════════════════
  //  BOTTOM NAVIGATION BAR
  // ═══════════════════════════════════════════════════
  Widget _buildBottomNav(dynamic dc) {
    return NavigationBar(
      backgroundColor: const Color(0xFF111111),
      indicatorColor: const Color(0xFFE8C547).withValues(alpha: 0.15),
      surfaceTintColor: Colors.transparent,
      elevation: 0,
      height: 64,
      labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
      selectedIndex: _navIndex,
      onDestinationSelected: (i) {
        HapticFeedback.selectionClick();
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
          label: 'Home',
        ),
        NavigationDestination(
          icon: Icon(Icons.attach_money_rounded, color: Colors.white.withValues(alpha: 0.5), size: 22),
          selectedIcon: const Icon(Icons.attach_money_rounded, color: Color(0xFFE8C547), size: 22),
          label: 'Earnings',
        ),
        NavigationDestination(
          icon: Stack(
            clipBehavior: Clip.none,
            children: [
              Icon(Icons.history_rounded, color: Colors.white.withValues(alpha: 0.5), size: 22),
            ],
          ),
          selectedIcon: const Icon(Icons.history_rounded, color: Color(0xFFE8C547), size: 22),
          label: 'Trips',
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
          label: 'Account',
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
      backgroundColor: dc.bg,
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
                    Colors.black.withValues(alpha: 0.75),
                    Colors.black.withValues(alpha: 0.0),
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
    if (_currentLatLng == null) {
      return Container(
        color: dc.bg,
        child: const Center(
          child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
        ),
      );
    }

    return RepaintBoundary(
      child: mapbox.MapWidget(
        styleUri: MapboxConfig.styleDark,
        cameraOptions: mapbox.CameraOptions(
          center: mapbox.Point(coordinates: mapbox.Position(_currentLatLng!.longitude, _currentLatLng!.latitude)),
          zoom: 16.0,
          pitch: 0.0,
          bearing: 0.0,
        ),
        onMapCreated: (ctrl) async {
          _mapController = ctrl;
          _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
          try { await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}
          setState(() => _mapReady = true);
          // Wait a moment for dot to be ready, then show it
          if (_goldDot.isReady) {
            _updateMyLocAnnotation();
          } else {
            // Retry when dot is ready
            Future.delayed(const Duration(milliseconds: 100), () {
              if (mounted && _goldDot.isReady) _updateMyLocAnnotation();
            });
          }
        },
        onStyleLoadedListener: (_) async {
          if (_mapController != null) await _applyNavyGoldTheme(_mapController!);
        },
      ),
    );
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
            HapticFeedback.selectionClick();
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

        // Greeting
        Expanded(
          child: Container(
            padding: EdgeInsets.symmetric(horizontal: Responsive.w(16), vertical: Responsive.h(10)),
            decoration: BoxDecoration(
              color: dc.glassBg,
              borderRadius: BorderRadius.circular(28),
              border: Border.all(color: dc.divider),
            ),
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
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: Responsive.sp(11),
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _driverName,
                        style: TextStyle(
                          color: Colors.white,
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

        // Inbox
        _glassBtn(
          Icons.inbox_rounded,
          onTap: () {
            HapticFeedback.selectionClick();
            Navigator.of(
              context,
            ).push(slideFromRightRoute(const DriverInboxScreen()));
          },
          badge: _unreadCount > 0 ? _unreadCount : null,
        ),
      ],
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
            decoration: BoxDecoration(
              color: dc.glassBg,
              shape: BoxShape.circle,
              border: Border.all(color: dc.divider),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.15),
                  blurRadius: 8,
                ),
              ],
            ),
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
        decoration: BoxDecoration(
          color: _card,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 12,
            ),
          ],
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Icon(
          Icons.my_location_rounded,
          color: Colors.white.withValues(alpha: 0.7),
          size: 22,
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  FLOATING GO BUTTON — inner pulse glow
  // ═══════════════════════════════════════════════════
  Widget _buildGoButton() {
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
          final colorT = _btnColorAnim.value;
          final g = _glossCtrl.value;
          final docsOk = _vehicleDocsApproved || !_docStatusLoaded;

          const goldTop1 = Color(0xFFF0D060);
          const goldTop2 = Color(0xFFF5DC7A);
          const goldBot = Color(0xFFD4A800);

          final topColor = Color.lerp(goldTop1, goldTop2, p)!;
          final botColor = goldBot;
          final glowColor = _gold;

          // Disabled look when docs missing or not verified
          final buttonOpacity = !_isVerified ? 0.55
              : !docsOk ? 0.45
              : 1.0;

          return Opacity(
            opacity: buttonOpacity,
            child: ClipRRect(
              borderRadius: BorderRadius.circular(30),
              child: Stack(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(30),
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
                    ),
                    child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.15),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(
                      !docsOk
                          ? (_hasExpiredDocs ? Icons.warning_amber_rounded : Icons.upload_file_rounded)
                          : (_activeTripData != null || _isStillOnline)
                              ? Icons.play_arrow_rounded
                              : Icons.power_settings_new_rounded,
                      color: Colors.black87,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _isVerified
                        ? (!docsOk
                            ? (_hasExpiredDocs ? 'EXPIRED DOCS' : 'DOCUMENTS')
                            : (_activeTripData != null || _isStillOnline)
                                ? S.of(context).resumeOnline
                                : S.of(context).goOnline)
                        : S.of(context).verifyFirst,
                    style: const TextStyle(
                      color: Colors.black87,
                      fontSize: 14,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
                  // ── Gloss shimmer sweep ──
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
        color: dc.card,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 16,
            offset: const Offset(0, -4),
          ),
        ],
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
                  color: Colors.white.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
          ),
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
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: dc.text.withValues(alpha: 0.3),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isStillOnline
                            ? S.of(context).findingTrips
                            : S.of(context).youreOffline,
                        style: TextStyle(
                          color: dc.text.withValues(alpha: 0.7),
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.of(context).push(
                        slideFromRightRoute(const DriverTripHistoryScreen()),
                      );
                    },
                    child: Icon(
                      Icons.format_list_bulleted_rounded,
                      color: dc.text.withValues(alpha: 0.6),
                      size: 24,
                    ),
                  ),
                ],
              ),
            ),
            ),
            // ── Expanded content ──
            if (panelExtent > 0.02)
              Expanded(
                child: Opacity(
                  opacity: panelExtent.clamp(0.0, 1.0),
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
                          color: dc.text,
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 14),
                      // ── Recommendation items ──
                      _recommendItem(
                        Icons.bar_chart_rounded,
                        S.of(context).seeEarningsTrends,
                        () {
                          Navigator.of(context).push(
                            slideFromRightRoute(const DriverEarningsScreen()),
                          );
                        },
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
                      _recommendItem(
                        Icons.schedule_rounded,
                        S.of(context).seeDrivingTime,
                        () {
                          Navigator.of(context).push(
                            slideFromRightRoute(const DriverAnalyticsScreen()),
                          );
                        },
                      ),
                      SizedBox(height: pad.bottom + 16),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),    // close AnimatedContainer
    );      // close GestureDetector
  }

  Widget _recommendItem(IconData icon, String label, VoidCallback onTap) {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 4),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(color: dc.divider),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: dc.text.withValues(alpha: 0.7), size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: dc.text,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: dc.text.withValues(alpha: 0.25),
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  Widget _panelStat(IconData icon, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          children: [
            Icon(icon, color: _gold, size: 18),
            const SizedBox(height: 6),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
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
        HapticFeedback.selectionClick();
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
            rawDriverStr.replaceFirst(RegExp(r'^sql_'), '') == driverIdStr;
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
  /// may be empty). Only sets _activeTripData so RESUME button appears —
  /// does NOT auto-navigate. Driver taps RESUME to go to the trip.
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

      // Store backend data so _resumeActiveTrip can use it via RESUME button
      if (!mounted) return;
      setState(() {
        _activeTripData = trip;
        _isStillOnline = true;
      });
    } catch (e) {
      debugPrint('[DriverHome] Backend active trip check failed: $e');
    }
  }

  Future<void> _resumeActiveTrip() async {
    // Try to refresh from Firestore, but keep existing data if Firestore
    // returns nothing (backend data may have been set by _checkBackendActiveTrip)
    final existing = _activeTripData;
    await _refreshActiveTripStatus();
    if (_activeTripData == null && existing != null) {
      _activeTripData = existing; // restore backend data
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
          riderRating: _pickDouble(trip, ['riderRating', 'rider_rating']) ?? 4.8,
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
    if (!mounted) return;
    await _refreshActiveTripStatus();
    if (_activeTripData != null) {
      // Trip still active — go back immediately
      _resumeActiveTrip();
    } else if (_isStillOnline) {
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
