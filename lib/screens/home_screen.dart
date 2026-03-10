import 'dart:async';
import 'dart:io' show Platform, File;
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:geocoding/geocoding.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as amap;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'airport_terminal_sheet.dart';
import 'identity_verification_screen.dart';
import 'map_screen.dart';
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
import '../services/local_data_service.dart';
import '../services/places_service.dart';
import '../l10n/app_localizations.dart';
import '../services/user_session.dart';
import 'welcome_screen.dart';
import 'account_deactivated_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> with TickerProviderStateMixin {
  // Brand colors — premium shiny gold
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);

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

  // Verification state
  bool _isVerified = false;

  // Service zone state
  Set<String> _activeServiceStates = {};
  String _userStateName = '';
  bool _serviceZoneActive = true; // default true until Firestore loads
  bool _stateCheckDone = false;
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>? _zonesSub;

  // User profile data
  String _firstName = '';
  String _lastName = '';
  String? _photoPath;

  // Mini-map state
  GoogleMapController? _miniMapController;
  amap.AppleMapController? _appleMinimapController;
  LatLng? _currentLatLng;
  String? _locationError;
  bool _imagesPrecached = false;
  StreamSubscription<Position>? _locationSub;
  BitmapDescriptor? _locationDotGoogle;
  Uint8List? _locationDotBytes;

  @override
  void initState() {
    super.initState();
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
    _buildLocationDot();
    _checkDriversOnline();
    _listenServiceZones();
    _driverCheckTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkDriversOnline(),
    );
    _accountStatusTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkAccountStatus(),
    );
    UserSession.photoNotifier.addListener(_onPhotoChanged);
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
    }
  }

  @override
  void dispose() {
    UserSession.photoNotifier.removeListener(_onPhotoChanged);
    _shimmerController.dispose();
    _boltFlashCtrl.dispose();
    _clockRotateCtrl.dispose();
    _promoShimmerCtrl.dispose();
    _driverCheckTimer?.cancel();
    _accountStatusTimer?.cancel();
    _locationSub?.cancel();
    _zonesSub?.cancel();
    super.dispose();
  }

  void _onPhotoChanged() {
    if (!mounted) return;
    setState(() => _photoPath = UserSession.photoNotifier.value);
  }

  // --- Service Zone support ---

  void _listenServiceZones() {
    _zonesSub = FirebaseFirestore.instance
        .collection('config')
        .doc('serviceZones')
        .snapshots()
        .listen((snap) {
          if (!mounted) return;
          final states = (snap.data()?['activeStates'] as List<dynamic>? ?? [])
              .map((s) => s.toString())
              .toSet();
          setState(() {
            _activeServiceStates = states;
            // If no states configured → allow all (feature not yet set up)
            if (states.isEmpty) {
              _serviceZoneActive = true;
            } else if (_userStateName.isNotEmpty) {
              _serviceZoneActive = states.contains(_userStateName);
            }
          });
        });
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
      _miniMapController?.animateCamera(
        CameraUpdate.newLatLng(_currentLatLng!),
      );
      _appleMinimapController?.animateCamera(
        amap.CameraUpdate.newLatLng(
          amap.LatLng(_currentLatLng!.latitude, _currentLatLng!.longitude),
        ),
      );

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
            _miniMapController?.animateCamera(CameraUpdate.newLatLng(ll));
            _appleMinimapController?.animateCamera(
              amap.CameraUpdate.newLatLng(
                amap.LatLng(ll.latitude, ll.longitude),
              ),
            );
          });
    } catch (e) {
      if (mounted && _currentLatLng == null) {
        setState(() => _locationError = 'Unable to get location');
      }
    }
  }

  Timer? _driverCheckTimer;
  Timer? _accountStatusTimer;

  /// Renders a gold tracking dot bitmap for the minimap location marker.
  Future<void> _buildLocationDot() async {
    const s = 64.0;
    final rec = ui.PictureRecorder();
    final c = Canvas(rec, const Rect.fromLTWH(0, 0, s, s));
    // Outer glow
    c.drawCircle(
      const Offset(s / 2, s / 2),
      s / 2 - 2,
      Paint()..color = _gold.withValues(alpha: 0.22),
    );
    // Gold ring
    c.drawCircle(const Offset(s / 2, s / 2), s / 3, Paint()..color = _gold);
    // White center
    c.drawCircle(
      const Offset(s / 2, s / 2),
      s / 7,
      Paint()..color = Colors.white,
    );
    final img = await rec.endRecording().toImage(s.toInt(), s.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    if (data == null || !mounted) return;
    final bytes = data.buffer.asUint8List();
    setState(() {
      _locationDotBytes = bytes;
      // ignore: deprecated_member_use
      _locationDotGoogle = BitmapDescriptor.fromBytes(bytes);
    });
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
          MaterialPageRoute(builder: (_) => const WelcomeScreen()),
          (_) => false,
        );
      } else if (status == 'deactivated') {
        _accountStatusTimer?.cancel();
        if (!mounted) return;
        Navigator.of(context).pushAndRemoveUntil(
          MaterialPageRoute(builder: (_) => const AccountDeactivatedScreen()),
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
      final lat = _currentLatLng?.latitude ?? 25.7617;
      final lng = _currentLatLng?.longitude ?? -80.1918;
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
      }
    });
  }

  int get _unreadNotifications {
    return _notifications.where((item) => !item.read).length;
  }

  @override
  Widget build(BuildContext context) {
    final screenW = MediaQuery.of(context).size.width;
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final scaffoldBg = const Color(0xFF07080D);

    // Theme color helpers — dark cards everywhere
    // ignore: unused_local_variable
    final textMain = Colors.white;
    // ignore: unused_local_variable
    final textSub = Colors.white.withValues(alpha: 0.45);
    // ignore: unused_local_variable
    final textMuted = Colors.white.withValues(alpha: 0.35);
    // ignore: unused_local_variable
    final textFaint = Colors.white.withValues(alpha: 0.4);
    // ignore: unused_local_variable
    final surface = const Color(0xFF161820);
    // ignore: unused_local_variable
    final cardBg = Colors.white.withValues(alpha: 0.04);
    // ignore: unused_local_variable
    final cardBorder = Colors.white.withValues(alpha: 0.06);
    // ignore: unused_local_variable
    final iconMuted = Colors.white.withValues(alpha: 0.4);
    // ignore: unused_local_variable
    final iconFaint = Colors.white.withValues(alpha: 0.7);
    // ignore: unused_local_variable
    final glassColor = Colors.white.withValues(alpha: 0.06);
    // ignore: unused_local_variable
    final glassBorder = Colors.white.withValues(alpha: 0.08);

    return Scaffold(
      backgroundColor: scaffoldBg,
      body: Stack(
        children: [
          // ── Mesh gradient background ──
          if (isDark) ...[
            Positioned(top: -60, right: -40, child: _glowOrb(180, _gold, 0.07)),
            Positioned(
              top: 300,
              left: -80,
              child: _glowOrb(260, _goldLight, 0.03),
            ),
            Positioned(
              bottom: 120,
              right: -60,
              child: _glowOrb(200, _gold, 0.04),
            ),
          ],

          // ── Main scroll content ──
          CustomScrollView(
            physics: const BouncingScrollPhysics(
              parent: AlwaysScrollableScrollPhysics(),
              decelerationRate: ScrollDecelerationRate.normal,
            ),
            cacheExtent:
                1500, // pre-render more off-screen for buttery smooth scroll
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            slivers: [
              SliverToBoxAdapter(child: SizedBox(height: topPad + 16)),

              // ━━━ TOP BAR: greeting + avatar + bell ━━━
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildTopBar(),
                ),
              ),

              SliverToBoxAdapter(child: const SizedBox(height: 28)),

              // ━━━ HERO: "Where to?" large CTA card ━━━
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildHeroCTA(),
                ),
              ),

              SliverToBoxAdapter(child: const SizedBox(height: 28)),

              // ━━━ CIRCULAR ACTION BUTTONS ━━━
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildCircularActions(),
                ),
              ),

              SliverToBoxAdapter(child: const SizedBox(height: 36)),

              // ━━━ FLEET: Full-width stacked cards ━━━
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildFleetHeader(),
                ),
              ),
              SliverToBoxAdapter(child: const SizedBox(height: 16)),
              SliverToBoxAdapter(
                child: AnimatedCrossFade(
                  firstChild: RepaintBoundary(child: _buildFleetStack(screenW)),
                  secondChild: const SizedBox.shrink(),
                  crossFadeState: _fleetExpanded
                      ? CrossFadeState.showFirst
                      : CrossFadeState.showSecond,
                  duration: const Duration(milliseconds: 300),
                  sizeCurve: Curves.easeInOut,
                ),
              ),

              SliverToBoxAdapter(child: const SizedBox(height: 36)),

              // ━━━ SAVED PLACES ━━━
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildSectionHeader('Quick Access', null, null),
                ),
              ),
              SliverToBoxAdapter(child: const SizedBox(height: 16)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildQuickAccessGrid(),
                ),
              ),

              // ━━━ RECENT TRIPS (timeline style) ━━━
              if (_recentTrips.isNotEmpty) ...[
                SliverToBoxAdapter(child: const SizedBox(height: 36)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _buildSectionHeader(
                      S.of(context).recentActivity,
                      null,
                      null,
                    ),
                  ),
                ),
                SliverToBoxAdapter(child: const SizedBox(height: 16)),
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: _buildRecentTimeline(),
                  ),
                ),
              ] else if (_loadingSavedData) ...[
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 30),
                    child: Center(
                      child: SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                          color: _gold.withValues(alpha: 0.5),
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ],

              // ━━━ LIVE MAP CARD ━━━
              SliverToBoxAdapter(child: const SizedBox(height: 36)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: _buildSectionHeader(
                    S.of(context).liveLocation,
                    null,
                    null,
                  ),
                ),
              ),
              SliverToBoxAdapter(child: const SizedBox(height: 16)),
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: RepaintBoundary(child: _buildLiveMapCard()),
                ),
              ),

              SliverToBoxAdapter(child: SizedBox(height: 90 + bottomPad)),
            ],
          ),

          // ── Resume active ride banner ──
          if (_activeRide != null)
            Positioned(
              bottom: bottomPad + 88,
              left: 24,
              right: 24,
              child: GestureDetector(
                onTap: _resumeActiveRide,
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 18,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(
                      colors: [Color(0xFF1A1D24), Color(0xFF141720)],
                    ),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _gold.withValues(alpha: 0.3)),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.15),
                        blurRadius: 20,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Icon(
                          Icons.directions_car_rounded,
                          color: _gold,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text(
                              'Ride in progress',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              'Tap to resume your current ride',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.arrow_forward_ios_rounded,
                        color: _gold,
                        size: 16,
                      ),
                    ],
                  ),
                ),
              ),
            ),

          // ── Dock-style bottom navigation ──
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _buildDockNav(context, bottomPad),
          ),
        ],
      ),
    );
  }

  // ════════════════════════════════════════════════════
  //  W I D G E T S
  // ════════════════════════════════════════════════════

  Widget _glowOrb(double size, Color color, double opacity) {
    return RepaintBoundary(
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          gradient: RadialGradient(
            colors: [
              color.withValues(alpha: opacity),
              Colors.transparent,
            ],
          ),
        ),
      ),
    );
  }

  // ─── Top bar ───
  Widget _buildTopBar() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final textMain = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final initials = [
      if (_firstName.isNotEmpty) _firstName[0],
      if (_lastName.isNotEmpty) _lastName[0],
    ].join().toUpperCase();
    final displayInitial = initials.isNotEmpty ? initials : '?';
    final displayName = [
      if (_firstName.isNotEmpty) _firstName,
      if (_lastName.isNotEmpty) _lastName,
    ].join(' ');
    final hasPhoto =
        _photoPath != null &&
        _photoPath!.isNotEmpty &&
        (kIsWeb || File(_photoPath!).existsSync());

    return Row(
      children: [
        // Greeting
        Expanded(
          child: GestureDetector(
            onTap: () async {
              await Navigator.of(
                context,
              ).push(slideFromRightRoute(const AccountScreen()));
              _loadSavedData();
            },
            behavior: HitTestBehavior.opaque,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  _getGreeting().toUpperCase(),
                  style: TextStyle(
                    color: _gold,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 2.0,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  displayName.isNotEmpty ? displayName : 'Rider',
                  style: TextStyle(
                    color: textMain,
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.5,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),

        // Notification bell
        _glassIconButton(
          Icons.notifications_none_rounded,
          onTap: _openNotificationsSheet,
          badge: _unreadNotifications,
        ),
        const SizedBox(width: 12),

        // Avatar
        GestureDetector(
          onTap: () async {
            await Navigator.of(
              context,
            ).push(slideFromRightRoute(const AccountScreen()));
            _loadSavedData();
          },
          child: Container(
            width: 44,
            height: 44,
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              gradient: hasPhoto
                  ? null
                  : const LinearGradient(colors: [_gold, _goldLight]),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.35),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: hasPhoto
                ? (kIsWeb
                      ? Image.network(
                          _photoPath!,
                          fit: BoxFit.cover,
                          width: 44,
                          height: 44,
                          gaplessPlayback: true,
                        )
                      : Image.file(
                          File(_photoPath!),
                          fit: BoxFit.cover,
                          width: 44,
                          height: 44,
                          cacheWidth: 200,
                          gaplessPlayback: true,
                          frameBuilder:
                              (context, child, frame, wasSynchronouslyLoaded) {
                                if (wasSynchronouslyLoaded) return child;
                                return AnimatedOpacity(
                                  opacity: frame == null ? 0.0 : 1.0,
                                  duration: const Duration(milliseconds: 300),
                                  curve: Curves.easeOutCubic,
                                  child: child,
                                );
                              },
                        ))
                : Center(
                    child: Text(
                      displayInitial,
                      style: const TextStyle(
                        color: Colors.black87,
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _glassIconButton(IconData icon, {VoidCallback? onTap, int badge = 0}) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: onTap,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: isDark
                  ? Colors.white.withValues(alpha: 0.06)
                  : Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              boxShadow: isDark
                  ? null
                  : [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.04),
                        blurRadius: 8,
                      ),
                    ],
            ),
            child: Icon(
              icon,
              color: Colors.white.withValues(alpha: 0.4),
              size: 22,
            ),
          ),
          if (badge > 0)
            Positioned(
              right: -2,
              top: -2,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(colors: [_gold, _goldLight]),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  badge > 9 ? '9+' : '$badge',
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 9,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  String _getGreeting() {
    final hour = DateTime.now().hour;
    if (hour < 12) return 'Good morning';
    if (hour < 18) return 'Good afternoon';
    return 'Good evening';
  }

  // ─── Hero CTA Card ───
  Widget _buildHeroCTA() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final verifyDisabled = !_isVerified && _activeRide == null;
    final zoneBlocked = !_serviceZoneActive && _activeServiceStates.isNotEmpty;
    final disabled = verifyDisabled || zoneBlocked;
    return GestureDetector(
      onTap: () async {
        if (_activeRide != null) {
          _resumeActiveRide();
          return;
        }
        if (zoneBlocked) {
          showDialog<void>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: const Color(0xFF1C1E24),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Row(
                children: [
                  const Icon(
                    Icons.location_off_rounded,
                    color: Color(0xFFE8C547),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    S.of(ctx).serviceZoneTitle,
                    style: const TextStyle(color: Colors.white, fontSize: 16),
                  ),
                ],
              ),
              content: Text(
                S.of(ctx).noServiceState,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(
                    S.of(ctx).understood,
                    style: const TextStyle(color: Color(0xFFE8C547)),
                  ),
                ),
              ],
            ),
          );
          return;
        }
        if (!await _ensureVerified()) return;
        if (!mounted) return;
        await Navigator.of(
          context,
        ).push(scaleExpandRoute(const RideRequestScreen()));
        if (mounted) _loadSavedData();
      },
      child: ListenableBuilder(
        listenable: _shimmerController,
        builder: (context, child) {
          final v = _shimmerController.value;
          // Traveling glow around the border
          final glowAngle = v * 2 * 3.14159265; // ignore: unused_local_variable
          return Opacity(
            opacity: disabled ? 0.55 : 1.0,
            child: Container(
              height: 140,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(28),
              ),
              child: CustomPaint(
                painter: disabled
                    ? null
                    : _GlowBorderPainter(
                        progress: v,
                        gold: _gold,
                        goldLight: _goldLight,
                        isDark: isDark,
                      ),
                child: Container(
                  padding: const EdgeInsets.all(24),
                  decoration: BoxDecoration(
                    gradient: isDark
                        ? const LinearGradient(
                            colors: [Color(0xFF141210), Color(0xFF0C0B09)],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          )
                        : LinearGradient(
                            colors: [
                              const Color(0xFF161820),
                              const Color(0xFF1C1E24),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                    borderRadius: BorderRadius.circular(28),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(
                          alpha: 0.06 + 0.08 * ((v * 3.14).clamp(0, 1)),
                        ),
                        blurRadius: 30 + 15 * v,
                        offset: const Offset(0, 10),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              S.of(context).whereToQuestion,
                              style: TextStyle(
                                color: disabled
                                    ? Colors.white.withValues(alpha: 0.25)
                                    : isDark
                                    ? Colors.white
                                    : const Color(0xFF1C1C1E),
                                fontSize: 28,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1,
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (disabled)
                              Row(
                                children: [
                                  Icon(
                                    zoneBlocked
                                        ? Icons.location_off_rounded
                                        : Icons.lock_rounded,
                                    color: Colors.white.withValues(alpha: 0.35),
                                    size: 14,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      zoneBlocked
                                          ? S.of(context).noDriversInState
                                          : S.of(context).verifyIdentityToRide,
                                      style: TextStyle(
                                        color: Colors.white.withValues(
                                          alpha: 0.35,
                                        ),
                                        fontSize: 12,
                                        fontWeight: FontWeight.w500,
                                      ),
                                      maxLines: 2,
                                    ),
                                  ),
                                ],
                              )
                            else ...[
                              const SizedBox(height: 4),
                              // ── Now / Later toggle ──
                              GestureDetector(
                                onTap:
                                    () {}, // absorb tap so parent doesn't fire
                                child: Container(
                                  decoration: BoxDecoration(
                                    color: Colors.white.withValues(alpha: 0.06),
                                    borderRadius: BorderRadius.circular(20),
                                  ),
                                  padding: const EdgeInsets.all(3),
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      _nowLaterPill(
                                        'Now',
                                        Icons.bolt_rounded,
                                        _rideNow,
                                        () {
                                          if (!_rideNow) {
                                            setState(() => _rideNow = true);
                                          }
                                        },
                                      ),
                                      _nowLaterPill(
                                        'Later',
                                        Icons.schedule_rounded,
                                        !_rideNow,
                                        () {
                                          if (_rideNow) {
                                            setState(() => _rideNow = false);
                                            _showScheduleSheet();
                                          }
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                      Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: disabled
                                ? [
                                    Colors.white.withValues(alpha: 0.08),
                                    Colors.white.withValues(alpha: 0.04),
                                  ]
                                : const [_gold, _goldLight],
                          ),
                          borderRadius: BorderRadius.circular(18),
                          boxShadow: disabled
                              ? []
                              : [
                                  BoxShadow(
                                    color: _gold.withValues(alpha: 0.4),
                                    blurRadius: 16,
                                    offset: const Offset(0, 4),
                                  ),
                                ],
                        ),
                        child: Icon(
                          disabled
                              ? (zoneBlocked
                                    ? Icons.location_off_rounded
                                    : Icons.lock_rounded)
                              : Icons.arrow_forward_rounded,
                          color: disabled
                              ? Colors.white.withValues(alpha: 0.25)
                              : Colors.black87,
                          size: 26,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ─── Circular action buttons ───
  Widget _buildCircularActions() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: [
        // Bolt — flashes every 2s
        _animatedCircleAction(
          child: AnimatedBuilder(
            animation: _boltFlashCtrl,
            builder: (context, child) {
              final glow = _boltFlashCtrl.value;
              return ShaderMask(
                shaderCallback: (bounds) => LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Color.lerp(
                      const Color(0xFFFBE47A),
                      Colors.white,
                      glow * 0.7,
                    )!,
                    Color.lerp(
                      const Color(0xFFE8C547),
                      const Color(0xFFFBE47A),
                      glow,
                    )!,
                  ],
                ).createShader(bounds),
                child: Icon(Icons.bolt_rounded, color: Colors.white, size: 26),
              );
            },
          ),
          label: S.of(context).fastRide,
          disabled: !_driversOnline,
          onTap: () async {
            if (!_driversOnline) {
              _showFastRideUnavailableDialog();
              return;
            }
            if (!await _ensureVerified()) return;
            if (!mounted) return;
            Navigator.of(
              context,
            ).push(slideUpFadeRoute(const RideRequestScreen(fastRide: true)));
          },
        ),
        // Clock — real clock animation with ticking hands
        _animatedCircleAction(
          child: AnimatedBuilder(
            animation: _clockRotateCtrl,
            builder: (context, child) {
              return SizedBox(
                width: 26,
                height: 26,
                child: CustomPaint(
                  painter: _ClockPainter(_clockRotateCtrl.value),
                ),
              );
            },
          ),
          label: S.of(context).schedule,
          onTap: _openScheduleFlow,
        ),
        // 10% off — shimmer animation, disabled after use, shows trip counter
        _animatedCircleAction(
          child: _promoUsed
              ? Stack(
                  alignment: Alignment.center,
                  children: [
                    ShaderMask(
                      shaderCallback: (bounds) => LinearGradient(
                        colors: [Colors.grey.shade600, Colors.grey.shade500],
                      ).createShader(bounds),
                      child: const Icon(
                        Icons.local_offer_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    ),
                    // Mini trip counter badge
                    Positioned(
                      bottom: 0,
                      right: 0,
                      child: Container(
                        width: 20,
                        height: 20,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2E2E2E),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: const Color(0xFFE8C547),
                            width: 1.5,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            '${3 - _promoTripsLeft}',
                            style: const TextStyle(
                              color: Color(0xFFE8C547),
                              fontSize: 10,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              : AnimatedBuilder(
                  animation: _promoShimmerCtrl,
                  builder: (context, child) {
                    final v = _promoShimmerCtrl.value;
                    return ShaderMask(
                      shaderCallback: (bounds) => LinearGradient(
                        begin: Alignment(-1.0 + 2.0 * v, 0),
                        end: Alignment(1.0 + 2.0 * v, 0),
                        colors: const [
                          Color(0xFFE8C547),
                          Color(0xFFFBE47A),
                          Colors.white,
                          Color(0xFFFBE47A),
                          Color(0xFFE8C547),
                        ],
                        stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
                      ).createShader(bounds),
                      child: const Icon(
                        Icons.local_offer_rounded,
                        color: Colors.white,
                        size: 26,
                      ),
                    );
                  },
                ),
          label: _promoUsed ? '${3 - _promoTripsLeft}/3 rides' : '10% off',
          disabled: _promoUsed,
          onTap: _promoUsed ? _showPromoLockedDialog : _showPromoWelcomeDialog,
        ),
      ],
    );
  }

  Widget _nowLaterPill(
    String label,
    IconData icon,
    bool active,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: active ? _gold : Colors.transparent,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: active
                  ? Colors.black
                  : Colors.white.withValues(alpha: 0.45),
            ),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: active
                    ? Colors.black
                    : Colors.white.withValues(alpha: 0.45),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _animatedCircleAction({
    required Widget child,
    required String label,
    required VoidCallback onTap,
    bool disabled = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Opacity(
        opacity: disabled ? 0.4 : 1.0,
        child: Column(
          children: [
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    Color(0xFF4A4A4A),
                    Color(0xFF3A3A3A),
                    Color(0xFF2E2E2E),
                    Color(0xFF3A3A3A),
                  ],
                  stops: [0.0, 0.3, 0.7, 1.0],
                ),
                border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
                boxShadow: [
                  BoxShadow(
                    color: Colors.white.withValues(alpha: 0.06),
                    blurRadius: 4,
                    offset: const Offset(0, -1),
                  ),
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.4),
                    blurRadius: 8,
                    offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: child,
            ),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: disabled
                    ? Colors.white.withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.55),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  // ─── Section header ───
  Widget _buildSectionHeader(
    String title,
    String? action,
    VoidCallback? onAction,
  ) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      children: [
        Container(
          width: 4,
          height: 20,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [_gold, _goldLight],
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
            ),
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 12),
        Text(
          title,
          style: TextStyle(
            color: isDark ? Colors.white : const Color(0xFF1C1C1E),
            fontSize: 20,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        const Spacer(),
        if (action != null)
          GestureDetector(
            onTap: onAction,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _gold.withValues(alpha: 0.15)),
              ),
              child: Text(
                action,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
      ],
    );
  }

  // ─── Fleet header with collapse/expand toggle ───
  Widget _buildFleetHeader() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return GestureDetector(
      onTap: () => setState(() => _fleetExpanded = !_fleetExpanded),
      behavior: HitTestBehavior.opaque,
      child: Row(
        children: [
          Container(
            width: 4,
            height: 20,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [_gold, _goldLight],
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
              ),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            'Choose a ride',
            style: TextStyle(
              color: isDark ? Colors.white : const Color(0xFF1C1C1E),
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const Spacer(),
          AnimatedRotation(
            turns: _fleetExpanded ? 0.0 : -0.25,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeInOut,
            child: Icon(
              Icons.keyboard_arrow_down_rounded,
              color: Colors.white.withValues(alpha: 0.5),
              size: 24,
            ),
          ),
        ],
      ),
    );
  }

  // ─── Fleet: Full-width stacked cards ───
  Widget _buildFleetStack(double screenW) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final vehicles = [
      {
        'tier': 'VIP',
        'name': 'Suburban',
        'desc': 'Premium luxury SUV',
        'idx': 0,
        'accent': _gold,
        'icon': Icons.airport_shuttle_rounded,
        'scale': 1.35,
      },
      {
        'tier': 'PREMIUM',
        'name': 'Camry',
        'desc': 'Comfortable sedan',
        'idx': 1,
        'accent': _goldLight,
        'icon': Icons.directions_car_filled_rounded,
        'scale': 1.55,
      },
      {
        'tier': 'COMFORT',
        'name': 'Fusion',
        'desc': 'Affordable & reliable',
        'idx': 2,
        'accent': Colors.white,
        'icon': Icons.local_taxi_rounded,
        'scale': 1.55,
      },
    ];

    return Column(
      children: vehicles.map((v) {
        final accent = v['accent'] as Color;
        final idx = v['idx'] as int;
        final carScale = v['scale'] as double;
        return Padding(
          padding: EdgeInsets.only(
            bottom: idx < 2 ? 14 : 0,
            left: 24,
            right: 24,
          ),
          child: GestureDetector(
            onTap: () async {
              if (!await _ensureVerified()) return;
              if (!mounted) return;
              Navigator.of(
                context,
              ).push(slideFromRightRoute(const RideRequestScreen()));
            },
            child: Container(
              height: 120,
              clipBehavior: Clip.hardEdge,
              padding: const EdgeInsets.fromLTRB(20, 14, 0, 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [const Color(0xFF1A1D24), const Color(0xFF141820)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06),
                  width: 1,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 20,
                    offset: const Offset(0, 8),
                  ),
                  BoxShadow(
                    color: accent.withValues(alpha: 0.05),
                    blurRadius: 30,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  // Text info
                  Expanded(
                    flex: 3,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [accent, accent.withValues(alpha: 0.6)],
                            ),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            v['tier'] as String,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 1.8,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          v['name'] as String,
                          style: TextStyle(
                            color: isDark
                                ? Colors.white
                                : const Color(0xFF1C1C1E),
                            fontSize: 22,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          v['desc'] as String,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.45),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Car image — large with overflow
                  SizedBox(
                    width: screenW * 0.38,
                    child: Transform.scale(
                      scale: carScale,
                      alignment: Alignment.centerRight,
                      child: Image.asset(
                        'assets/images/${(v['name'] as String).toLowerCase()}.png',
                        fit: BoxFit.contain,
                        filterQuality: FilterQuality.high,
                        isAntiAlias: true,
                        cacheWidth:
                            (screenW *
                                    0.38 *
                                    carScale *
                                    MediaQuery.of(context).devicePixelRatio)
                                .toInt(),
                        errorBuilder: (ctx, err, st) => Icon(
                          v['icon'] as IconData,
                          color: accent,
                          size: 40,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  // ─── Quick access grid (Home, Work, places) ───
  Widget _buildQuickAccessGrid() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Column(
      children: [
        Row(
          children: [
            Expanded(
              child: _quickAccessTile(
                Icons.home_rounded,
                'Home',
                _homeFavorite?.address ?? 'Add',
                _gold,
                _openOrSaveHomeShortcut,
                onEdit: _editHomeAddress,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _quickAccessTile(
                Icons.work_rounded,
                'Work',
                _workFavorite?.address ?? 'Add',
                _goldLight,
                _openOrSaveWorkShortcut,
                onEdit: _editWorkAddress,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Expanded(
              child: _quickAccessTile(
                Icons.star_rounded,
                _place1Favorite?.label ?? 'Place 1',
                _place1Favorite?.address ?? 'Add',
                _gold,
                _openOrSavePlace1Shortcut,
                onEdit: _editPlace1Address,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _quickAccessTile(
                Icons.star_rounded,
                _place2Favorite?.label ?? 'Place 2',
                _place2Favorite?.address ?? 'Add',
                _goldLight,
                _openOrSavePlace2Shortcut,
                onEdit: _editPlace2Address,
              ),
            ),
          ],
        ),
        // Frequent destinations below
        if (_topDestinations.isNotEmpty) ...[
          const SizedBox(height: 12),
          ..._topDestinations.take(2).map((d) {
            final shortName = d.address.split(',').first;
            return Padding(
              padding: const EdgeInsets.only(bottom: 10),
              child: GestureDetector(
                onTap: () => _openMapWithDropoff(d.address),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white.withValues(alpha: 0.04)
                        : Colors.white,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                    boxShadow: isDark
                        ? null
                        : [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.03),
                              blurRadius: 8,
                            ),
                          ],
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 36,
                        height: 36,
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: const Icon(
                          Icons.near_me_rounded,
                          color: _gold,
                          size: 18,
                        ),
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              shortName,
                              style: TextStyle(
                                color: isDark
                                    ? Colors.white
                                    : const Color(0xFF1C1C1E),
                                fontSize: 14,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${d.count} trips',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.45),
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Icon(
                        Icons.chevron_right_rounded,
                        color: Colors.white.withValues(alpha: 0.4),
                        size: 20,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }),
        ],
      ],
    );
  }

  Widget _quickAccessTile(
    IconData icon,
    String title,
    String subtitle,
    Color accent,
    VoidCallback onTap, {
    VoidCallback? onEdit,
  }) {
    final hasAddress = subtitle != 'Add' && subtitle.trim().isNotEmpty;
    return GestureDetector(
      onTap: () {
        if (!hasAddress) {
          onTap();
          return;
        }
        _showPlaceOptions(title, subtitle, onEdit ?? onTap);
      },
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _gold.withValues(alpha: 0.18)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: _gold, size: 22),
            const SizedBox(height: 6),
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 11,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  void _showPlaceOptions(String label, String address, VoidCallback editTap) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        margin: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 16),
            Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              address,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            // Edit Address
            _placeOptionBtn(Icons.edit_rounded, 'Edit Address', () {
              Navigator.pop(ctx);
              editTap();
            }),
            const SizedBox(height: 8),
            // Request a Ride
            _placeOptionBtn(Icons.directions_car_rounded, 'Request a Ride', () {
              Navigator.pop(ctx);
              _requestRideToAddress(address);
            }, highlight: true),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  Widget _placeOptionBtn(
    IconData icon,
    String label,
    VoidCallback onTap, {
    bool highlight = false,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: highlight
                ? _gold.withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: highlight
                  ? _gold.withValues(alpha: 0.30)
                  : Colors.white.withValues(alpha: 0.08),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: highlight ? _gold : Colors.white, size: 20),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  color: highlight ? _gold : Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
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
          slideUpFadeRoute(RideRequestScreen(initialDropoffAddress: address)),
        )
        .then((_) {
          if (mounted) _loadSavedData();
        });
  }

  // ─── Recent trips timeline ───
  Widget _buildRecentTimeline() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final trips = _recentTrips.take(4).toList();
    return Column(
      children: trips.asMap().entries.map((entry) {
        final i = entry.key;
        final trip = entry.value;
        final shortDest = trip.dropoff.split(',').first;
        final isLast = i == trips.length - 1;

        return GestureDetector(
          onTap: () => _openTripReceipt(trip),
          child: IntrinsicHeight(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Timeline dot + line
                SizedBox(
                  width: 24,
                  child: Column(
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        margin: const EdgeInsets.only(top: 8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: const LinearGradient(
                            colors: [_gold, _goldLight],
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.4),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                      if (!isLast)
                        Expanded(
                          child: Container(
                            width: 1.5,
                            margin: const EdgeInsets.symmetric(vertical: 4),
                            color: Colors.white.withValues(alpha: 0.1),
                          ),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 14),
                // Trip card
                Expanded(
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 14),
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: isDark
                          ? Colors.white.withValues(alpha: 0.04)
                          : Colors.white,
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.1),
                      ),
                      boxShadow: isDark
                          ? null
                          : [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.03),
                                blurRadius: 8,
                              ),
                            ],
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                shortDest,
                                style: TextStyle(
                                  color: isDark
                                      ? Colors.white
                                      : const Color(0xFF1C1C1E),
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                trip.rideName,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.45),
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: _gold.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Text(
                            trip.price,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  // ─── Live map card ───
  Widget _buildLiveMapCard() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return ClipRRect(
      borderRadius: BorderRadius.circular(22),
      child: Container(
        height: 180,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(22),
          border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        ),
        child: Stack(
          children: [
            if (_currentLatLng == null)
              Container(
                color: const Color(0xFF0D0E14),
                child: Center(
                  child: _locationError != null
                      ? Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(
                              Icons.location_off_rounded,
                              color: Colors.white.withValues(alpha: 0.5),
                              size: 28,
                            ),
                            const SizedBox(height: 8),
                            Text(
                              _locationError!,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.5),
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 12),
                            GestureDetector(
                              onTap: () {
                                setState(() => _locationError = null);
                                _fetchCurrentLocation();
                              },
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                decoration: BoxDecoration(
                                  color: _gold.withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: const Text(
                                  'Retry',
                                  style: TextStyle(
                                    color: _gold,
                                    fontWeight: FontWeight.w600,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        )
                      : const CircularProgressIndicator(
                          color: _gold,
                          strokeWidth: 2,
                        ),
                ),
              )
            else
              GoogleMap(
                style: MapStyles.dark,
                initialCameraPosition: CameraPosition(
                  target: _currentLatLng!,
                  zoom: 15,
                ),
                onMapCreated: (controller) {
                  _miniMapController = controller;
                },
                markers: {
                  Marker(
                    markerId: const MarkerId('current'),
                    position: _currentLatLng!,
                    icon: _locationDotGoogle ?? BitmapDescriptor.defaultMarker,
                  ),
                },
                myLocationEnabled: false,
                myLocationButtonEnabled: false,
                zoomControlsEnabled: false,
                mapToolbarEnabled: false,
                scrollGesturesEnabled: false,
                zoomGesturesEnabled: false,
                rotateGesturesEnabled: false,
                tiltGesturesEnabled: false,
                liteModeEnabled: false,
              ),
            // Badge
            Positioned(
              bottom: 12,
              left: 12,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
                decoration: BoxDecoration(
                  color: isDark
                      ? const Color(0xFF0D0E14).withValues(alpha: 0.85)
                      : Colors.white.withValues(alpha: 0.92),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                  boxShadow: isDark
                      ? null
                      : [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 8,
                          ),
                        ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: _gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 6,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      S.of(context).liveLocation,
                      style: TextStyle(
                        color: isDark ? Colors.white : const Color(0xFF1C1C1E),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ─── Dock-style bottom nav with animated gold pill ───
  Widget _buildDockNav(BuildContext context, double bottomPad) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final s = S.of(context);
    final items = [
      (icon: Icons.explore_rounded, label: s.rideLabel),
      (icon: Icons.calendar_today_rounded, label: s.schedule),
      (icon: Icons.person_rounded, label: s.accountLabel),
    ];

    return Container(
      margin: EdgeInsets.fromLTRB(40, 0, 40, bottomPad + 16),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF161820),
        borderRadius: BorderRadius.circular(28),
        border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: isDark ? 0.5 : 0.12),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceEvenly,
        children: List.generate(items.length, (i) {
          final active = i == _dockIndex;
          return GestureDetector(
            onTap: () => _onDockTap(i),
            behavior: HitTestBehavior.opaque,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              curve: Curves.easeOutCubic,
              padding: EdgeInsets.symmetric(
                horizontal: active ? 20 : 18,
                vertical: 10,
              ),
              decoration: BoxDecoration(
                gradient: active
                    ? const LinearGradient(colors: [_gold, _goldLight])
                    : null,
                borderRadius: BorderRadius.circular(22),
                boxShadow: active
                    ? [
                        BoxShadow(
                          color: _gold.withValues(alpha: 0.3),
                          blurRadius: 10,
                          offset: const Offset(0, 3),
                        ),
                      ]
                    : null,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 250),
                    child: Icon(
                      items[i].icon,
                      key: ValueKey('dock_icon_${i}_$active'),
                      color: active
                          ? Colors.black87
                          : Colors.white.withValues(alpha: 0.5),
                      size: 20,
                    ),
                  ),
                  AnimatedSize(
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeOutCubic,
                    child: active
                        ? Padding(
                            padding: const EdgeInsets.only(left: 8),
                            child: Text(
                              items[i].label,
                              style: const TextStyle(
                                color: Colors.black87,
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          )
                        : const SizedBox.shrink(),
                  ),
                ],
              ),
            ),
          );
        }),
      ),
    );
  }

  void _onDockTap(int index) async {
    if (index == _dockIndex) {
      // Already selected — execute action directly
      _executeDockAction(index);
      return;
    }
    setState(() => _dockIndex = index);
    // Small delay for visual feedback before navigation
    await Future.delayed(const Duration(milliseconds: 200));
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

  // Map styles now use shared MapStyles.dark from config/map_styles.dart

  void _openScheduleFlow() => _showScheduleSheet();

  Future<void> _openScheduleSheet() => _showScheduleSheet();

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
      slideFromRightRoute(RideRequestScreen(initialDropoffAddress: query)),
    );
  }

  void _resumeActiveRide() {
    final ride = _activeRide;
    if (ride == null) return;
    Navigator.of(context).push(
      slideUpFadeRoute(
        RiderTrackingScreen(
          pickupLatLng: LatLng(ride.pickupLat, ride.pickupLng),
          dropoffLatLng: LatLng(ride.dropoffLat, ride.dropoffLng),
          routePoints: ride.routePoints.map((p) => LatLng(p[0], p[1])).toList(),
          driverName: ride.driverName,
          driverRating: ride.driverRating,
          vehicleMake: ride.vehicleMake,
          vehicleModel: ride.vehicleModel,
          vehicleColor: ride.vehicleColor,
          vehiclePlate: ride.vehiclePlate,
          vehicleYear: ride.vehicleYear,
          rideName: ride.rideName,
          price: ride.price,
          pickupLabel: ride.pickupLabel,
          dropoffLabel: ride.dropoffLabel,
          tripId: ride.tripId,
          firestoreTripId: ride.firestoreTripId,
          onTripComplete: () {
            LocalDataService.clearActiveRide();
            Navigator.of(context).pop();
            _loadSavedData();
          },
        ),
      ),
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

  /// Full-screen autocomplete address picker using PlacesService.
  Future<String?> _showAddressAutocomplete({
    required String title,
    required String hint,
  }) async {
    return showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _AddressAutocompleteSheet(
        title: title,
        hint: hint,
        currentLatLng: _currentLatLng,
      ),
    );
  }

  void _openTripReceipt(TripHistoryItem trip) {
    Navigator.of(
      context,
    ).push(sharedAxisVerticalRoute(TripReceiptScreen(trip: trip)));
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

  // Sample N points along a rounded rect perimeter (clockwise from top-center)
  static List<Offset> _sampleRRect(RRect rr, int n) {
    final pts = <Offset>[];
    final w = rr.width, h = rr.height;
    final r = rr.tlRadiusX.clamp(0, w / 2);
    // Perimeter segments: top, tr-corner, right, br-corner, bottom, bl-corner, left, tl-corner
    final straight = (w - 2 * r) * 2 + (h - 2 * r) * 2;
    final corners = 2 * 3.14159265 * r; // total corner arc length
    final total = straight + corners;
    for (int i = 0; i < n; i++) {
      var d = (i / n) * total;
      double x, y;
      final topW = w - 2 * r;
      // Top edge (left to right)
      if (d < topW) {
        x = rr.left + r + d;
        y = rr.top;
        pts.add(Offset(x, y));
        continue;
      }
      d -= topW;
      // Top-right corner
      final qArc = 3.14159265 * r / 2;
      if (d < qArc) {
        final a = -3.14159265 / 2 + (d / qArc) * (3.14159265 / 2);
        x = rr.right - r + r * _cos(a);
        y = rr.top + r + r * _sin(a);
        pts.add(Offset(x, y));
        continue;
      }
      d -= qArc;
      // Right edge
      final rightH = h - 2 * r;
      if (d < rightH) {
        x = rr.right;
        y = rr.top + r + d;
        pts.add(Offset(x, y));
        continue;
      }
      d -= rightH;
      // Bottom-right corner
      if (d < qArc) {
        final a = 0.0 + (d / qArc) * (3.14159265 / 2);
        x = rr.right - r + r * _cos(a);
        y = rr.bottom - r + r * _sin(a);
        pts.add(Offset(x, y));
        continue;
      }
      d -= qArc;
      // Bottom edge (right to left)
      if (d < topW) {
        x = rr.right - r - d;
        y = rr.bottom;
        pts.add(Offset(x, y));
        continue;
      }
      d -= topW;
      // Bottom-left corner
      if (d < qArc) {
        final a = 3.14159265 / 2 + (d / qArc) * (3.14159265 / 2);
        x = rr.left + r + r * _cos(a);
        y = rr.bottom - r + r * _sin(a);
        pts.add(Offset(x, y));
        continue;
      }
      d -= qArc;
      // Left edge (bottom to top)
      if (d < rightH) {
        x = rr.left;
        y = rr.bottom - r - d;
        pts.add(Offset(x, y));
        continue;
      }
      d -= rightH;
      // Top-left corner
      if (d < qArc) {
        final a = 3.14159265 + (d / qArc) * (3.14159265 / 2);
        x = rr.left + r + r * _cos(a);
        y = rr.top + r + r * _sin(a);
        pts.add(Offset(x, y));
        continue;
      }
      pts.add(Offset(rr.left + r, rr.top));
    }
    return pts;
  }

  static double _cos(double a) => math.cos(a);
  static double _sin(double a) => math.sin(a);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(28));

    // Base subtle border — always visible
    final basePaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2
      ..color = gold.withValues(alpha: isDark ? 0.12 : 0.20);
    canvas.drawRRect(rrect, basePaint);

    // ── Seamless traveling glow: draw segments along perimeter ──
    const segments = 200;
    const glowLen = 0.18; // fraction of perimeter that glows
    final pts = _sampleRRect(rrect, segments);

    final headIdx = (progress * segments).round() % segments;

    for (int k = 0; k < (segments * glowLen).round(); k++) {
      final idx = (headIdx - k + segments) % segments;
      final nextIdx = (idx + 1) % segments;
      // Fade: 0 at tail → 1 at head
      final t = 1.0 - (k / (segments * glowLen));
      // Bell-curve fade: strong in middle, fades both ends
      final alpha = t * t * (3 - 2 * t); // smoothstep

      // Bright line
      canvas.drawLine(
        pts[idx],
        pts[nextIdx],
        Paint()
          ..strokeWidth = 2.5
          ..color = Color.lerp(
            gold,
            goldLight,
            t,
          )!.withValues(alpha: alpha * 0.95)
          ..strokeCap = StrokeCap.round,
      );
      // Outer glow halo
      canvas.drawLine(
        pts[idx],
        pts[nextIdx],
        Paint()
          ..strokeWidth = 10
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
          ..color = goldLight.withValues(alpha: alpha * 0.35)
          ..strokeCap = StrokeCap.round,
      );
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
                        // Calendar (slides out left, fades out)
                        if (!_showingClock || _animCtrl.isAnimating)
                          SlideTransition(
                            position: _slideOut,
                            child: FadeTransition(
                              opacity: _fadeOut,
                              child: _buildCalendar(),
                            ),
                          ),
                        // Clock (slides in from right, fades in)
                        if (_showingClock)
                          SlideTransition(
                            position: _slideIn,
                            child: FadeTransition(
                              opacity: _fadeIn,
                              child: _buildTimePicker(),
                            ),
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
                onPrimary: Colors.black,
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
          duration: const Duration(milliseconds: 200),
          transitionBuilder: (child, anim) => FadeTransition(
            opacity: anim,
            child: SlideTransition(
              position: Tween<Offset>(
                begin: const Offset(0, 0.3),
                end: Offset.zero,
              ).animate(anim),
              child: child,
            ),
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
                            Icons.location_on_rounded,
                            color: c.textSecondary,
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
