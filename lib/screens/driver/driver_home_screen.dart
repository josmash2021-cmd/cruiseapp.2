import 'dart:async';
import 'dart:io' show File;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
import '../../services/user_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../welcome_screen.dart';
import '../account_deactivated_screen.dart';
import 'driver_earnings_screen.dart';
import 'driver_trip_history_screen.dart';
import 'driver_menu_screen.dart';
import 'driver_online_screen.dart';
import 'driver_inbox_screen.dart';
import 'driver_promos_screen.dart';
import 'driver_analytics_screen.dart';
import 'driver_profile_photo_screen.dart';
import '../../l10n/app_localizations.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../../widgets/gold_location_dot.dart';
import '../../widgets/user_profile_photo.dart';
import '../../widgets/verified_avatar.dart';

/// ═══════════════════════════════════════════════════════════════
///  CRUISE DRIVER HOME — Premium dashboard with map, stats, go-online
/// ═══════════════════════════════════════════════════════════════
class DriverHomeScreen extends StatefulWidget {
  const DriverHomeScreen({super.key});

  @override
  State<DriverHomeScreen> createState() => _DriverHomeScreenState();
}

class _DriverHomeScreenState extends State<DriverHomeScreen>
    with TickerProviderStateMixin {
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
  late AnimationController _statsCtrl;
  // ignore: unused_field
  late Animation<double> _statsAnim;
  late AnimationController _fabCtrl;
  late Animation<double> _fabScale;

  // ── Bottom panel ──
  double _panelExtent = 0.0; // 0 = collapsed, 1 = expanded
  static const double _panelCollapsedH = 62.0;
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
  int? _driverId;

  @override
  void initState() {
    super.initState();
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

    _goldDot.build(() {
      if (mounted) {
        setState(() {});
        _syncDotAnnotation(); // Keep dot pulsing on map
      }
    });
    _initLocation();
    _loadDriverData();
    _checkVerification();
    // Start account status polling immediately
    _checkAccountStatus();
    _accountStatusTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkAccountStatus(),
    );

    // Listen for photo updates from UserSession
    UserSession.photoNotifier.addListener(_onPhotoUpdated);
    UserSession.photoUrlNotifier.addListener(_onPhotoUpdated);

    // Resolve driver ID for trip polling
    _resolveDriverId();
    _registerFcmToken();

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
    _pulseCtrl.dispose();
    _statsCtrl.dispose();
    _fabCtrl.dispose();
    _goldDot.dispose();
    _posStream?.cancel();
    _accountStatusTimer?.cancel();
    _tripPollTimer?.cancel();
    UserSession.photoNotifier.removeListener(_onPhotoUpdated);
    UserSession.photoUrlNotifier.removeListener(_onPhotoUpdated);
    super.dispose();
  }

  Future<void> _updateMyLocAnnotation() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null || _currentLatLng == null) return;
    final bytes = _goldDot.currentBytes;
    if (bytes == null) return; // Dot not ready yet

    final point = mapbox.Point(
      coordinates: mapbox.Position(
        _currentLatLng!.longitude, _currentLatLng!.latitude));

    if (_myLocAnnot == null) {
      // First time: create the annotation once
      _myLocAnnot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: point,
        image: bytes,
        iconSize: 1.0,
      ));
    } else {
      // Update existing — no delete/recreate, no duplicates
      _myLocAnnot!.geometry = point;
      _myLocAnnot!.image = bytes;
      try { await mgr.update(_myLocAnnot!); } catch (_) {}
    }
  }

  /// Re-sync the location dot annotation whenever the dot animation frame changes.
  void _syncDotAnnotation() {
    if (!mounted || _currentLatLng == null) return;
    // Update annotation without full setState - just refresh the icon
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
        setState(() => _currentLatLng = LatLng(last.latitude, last.longitude));
      }

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      setState(() => _currentLatLng = LatLng(pos.latitude, pos.longitude));
      _updateMyLocAnnotation();
      _mapController?.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(coordinates: mapbox.Position(_currentLatLng!.longitude, _currentLatLng!.latitude)),
          zoom: 16, pitch: 0, bearing: 0,
        ),
        mapbox.MapAnimationOptions(duration: 800),
      );

      // ── Real-time GPS stream (3m filter, best accuracy) ──
      _posStream?.cancel();
      _posStream = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 3,
        ),
      ).listen((p) {
        if (!mounted) return;
        final ll = LatLng(p.latitude, p.longitude);
        setState(() => _currentLatLng = ll);
        _updateMyLocAnnotation();
        // Smooth 800ms flyTo — no jumps
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
    final prefs = await SharedPreferences.getInstance();
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
  //  GO ONLINE — navigate to DriverOnlineScreen
  // ═══════════════════════════════════════════════════
  void _goOnline() async {
    if (!await _ensureVerified()) return;
    if (!mounted) return;

    // Require profile photo before going online
    if (_photoUrl == null || _photoUrl!.isEmpty) {
      final result = await Navigator.of(context).push<String?>(
        slideFromRightRoute(const DriverProfilePhotoScreen(returnOnly: true)),
      );
      if (result != null && mounted) {
        setState(() => _photoUrl = result);
      } else {
        return; // user cancelled — don't go online
      }
    }

    HapticFeedback.heavyImpact();
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (ctx, anim1, anim2) =>
            DriverOnlineScreen(photoUrl: _photoUrl),
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        transitionsBuilder: (ctx2, anim, anim2b, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          );
        },
      ),
    );
    if (!mounted) return;
    final stillOnline = result?['stillOnline'] == true;
    setState(() => _isStillOnline = stillOnline);
    if (stillOnline) {
      _startTripPolling();
    } else {
      _stopTripPolling();
    }
  }

  Future<void> _resolveDriverId() async {
    try {
      final id = await ApiService.getCurrentUserId();
      if (id != null && mounted) _driverId = id;
    } catch (_) {}
  }

  void _startTripPolling() {
    _tripPollTimer?.cancel();
    _tripPollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
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
    if (!mounted) return;
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (ctx, anim1, anim2) =>
            DriverOnlineScreen(photoUrl: _photoUrl),
        transitionDuration: const Duration(milliseconds: 280),
        reverseTransitionDuration: const Duration(milliseconds: 220),
        transitionsBuilder: (ctx2, anim, anim2b, child) {
          return FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOut),
            child: child,
          );
        },
      ),
    );
    if (!mounted) return;
    final stillOnline = result?['stillOnline'] == true;
    setState(() => _isStillOnline = stillOnline);
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
        _panelCollapsedH + (_panelExpandedH - _panelCollapsedH) * _panelExtent;

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
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
                  radius: 18,
                  fallbackName: _driverName,
                  uid: UserSession.currentUid,
                  isVerified: _isVerified,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _getGreeting(context),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      Text(
                        _driverName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
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
                    fontSize: 9,
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
            width: 48,
            height: 48,
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
            child: Icon(icon, color: dc.text, size: 22),
          ),
          if (badge != null)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                width: 18,
                height: 18,
                decoration: const BoxDecoration(
                  color: Color(0xFFEF4444),
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    '$badge',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
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
      child: ListenableBuilder(
        listenable: _pulseAnim,
        builder: (_, __) {
          final p = _pulseAnim.value;
          return Opacity(
            opacity: _isVerified ? 1.0 : 0.55,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 13),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(30),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.3 + 0.15 * p),
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
                  colors: [
                    Color.lerp(
                      const Color(0xFFF0D060),
                      const Color(0xFFF5DC7A),
                      p,
                    )!,
                    const Color(0xFFD4A800),
                  ],
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
                      _isStillOnline
                          ? Icons.play_arrow_rounded
                          : Icons.power_settings_new_rounded,
                      color: Colors.black87,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    _isVerified
                        ? (_isStillOnline
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
        _panelCollapsedH + (_panelExpandedH - _panelCollapsedH) * _panelExtent;

    return GestureDetector(
      // Consume taps so panel never opens on tap — swipe-only
      onTap: () {},
      child: AnimatedContainer(
      duration: _dragging ? Duration.zero : const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
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
              setState(() {
                final delta =
                    -d.delta.dy / (_panelExpandedH - _panelCollapsedH);
                _panelExtent = (_panelExtent + delta).clamp(0.0, 1.0);
              });
            },
            onVerticalDragEnd: (d) {
              setState(() => _dragging = false);
              final velocity = d.primaryVelocity ?? 0;
              double target;
              if (velocity < -300) {
                target = 1.0;
              } else if (velocity > 300) {
                target = 0.0;
              } else {
                target = _panelExtent > 0.3 ? 1.0 : 0.0;
              }
              _animatePanel(target);
            },
            child: Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 4),
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
                setState(() {
                  final delta =
                      -d.delta.dy / (_panelExpandedH - _panelCollapsedH);
                  _panelExtent = (_panelExtent + delta).clamp(0.0, 1.0);
                });
              },
              onVerticalDragEnd: (d) {
                setState(() => _dragging = false);
                final velocity = d.primaryVelocity ?? 0;
                double target;
                if (velocity < -300) {
                  target = 1.0;
                } else if (velocity > 300) {
                  target = 0.0;
                } else {
                  target = _panelExtent > 0.3 ? 1.0 : 0.0;
                }
                _animatePanel(target);
              },
              child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
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
                          fontSize: 15,
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
            if (_panelExtent > 0.02)
              Expanded(
                child: Opacity(
                  opacity: _panelExtent.clamp(0.0, 1.0),
                  child: ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 8,
                    ),
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
                      const SizedBox(height: 16),
                      // Go offline button
                      if (_isStillOnline)
                        GestureDetector(
                          onTap: () {
                            HapticFeedback.mediumImpact();
                            setState(() => _isStillOnline = false);
                          },
                          child: Container(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF4444).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: const Color(0xFFEF4444).withValues(alpha: 0.3),
                              ),
                            ),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.stop_circle_outlined,
                                  color: const Color(0xFFEF4444),
                                  size: 20,
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  S.of(context).goOffline,
                                  style: TextStyle(
                                    color: const Color(0xFFEF4444),
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      SizedBox(height: pad.bottom + 16),
                    ],
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

  void _animatePanel(double target) {
    final start = _panelExtent;
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    ctrl.addListener(() {
      if (mounted) {
        setState(() {
          _panelExtent =
              start +
              (target - start) * Curves.easeOutCubic.transform(ctrl.value);
        });
      }
    });
    ctrl.addStatusListener((status) {
      if (status == AnimationStatus.completed) ctrl.dispose();
    });
    ctrl.forward();
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
}
