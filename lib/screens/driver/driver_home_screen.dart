import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as amap;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import '../../config/map_styles.dart';
import '../../config/page_transitions.dart';
import '../../config/driver_colors.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/user_session.dart';
import '../welcome_screen.dart';
import '../account_deactivated_screen.dart';
import 'driver_earnings_screen.dart';
import 'driver_trip_history_screen.dart';
import 'driver_menu_screen.dart';
import 'driver_online_screen.dart';
import 'driver_inbox_screen.dart';
import 'driver_profile_photo_screen.dart';
import '../../l10n/app_localizations.dart';

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
  GoogleMapController? _mapController;
  amap.AppleMapController? _appleMapController;
  LatLng? _currentLatLng;
  // ignore: unused_field
  bool _mapReady = false;

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

  // ── Online state (driver pressed back but is still connected) ──
  bool _isStillOnline = false;

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

    _initLocation();
    _loadDriverData();
    _checkVerification();
    _accountStatusTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkAccountStatus(),
    );

    // Listen for photo updates from UserSession
    UserSession.photoNotifier.addListener(_onPhotoUpdated);

    // Delay entrance animations
    Future.delayed(const Duration(milliseconds: 400), () {
      if (mounted) _statsCtrl.forward();
    });
    Future.delayed(const Duration(milliseconds: 600), () {
      if (mounted) _fabCtrl.forward();
    });
  }

  void _onPhotoUpdated() {
    if (mounted) {
      setState(() {
        _photoUrl = UserSession.photoNotifier.value;
      });
    }
  }

  @override
  void dispose() {
    _pulseCtrl.dispose();
    _statsCtrl.dispose();
    _fabCtrl.dispose();
    _mapController?.dispose();
    _accountStatusTimer?.cancel();
    UserSession.photoNotifier.removeListener(_onPhotoUpdated);
    super.dispose();
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
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      setState(() => _currentLatLng = LatLng(pos.latitude, pos.longitude));
      if (Platform.isIOS) {
        _appleMapController?.moveCamera(
          amap.CameraUpdate.newLatLng(
            amap.LatLng(_currentLatLng!.latitude, _currentLatLng!.longitude),
          ),
        );
      } else {
        _mapController?.animateCamera(CameraUpdate.newLatLng(_currentLatLng!));
      }
    } catch (_) {}
  }

  Future<void> _loadDriverData() async {
    try {
      final me = await ApiService.getMe();
      if (me != null && mounted) {
        final firstName = me['first_name'] ?? 'Driver';
        final lastName = me['last_name'] ?? '';
        setState(() {
          _driverName = lastName.isNotEmpty
              ? '$firstName ${lastName[0].toUpperCase()}.'
              : firstName;
          _photoUrl = me['photo_url'];
          // Fallback to cached local photo if server URL is empty
          if ((_photoUrl == null || _photoUrl!.isEmpty) &&
              UserSession.photoNotifier.value.isNotEmpty) {
            _photoUrl = UserSession.photoNotifier.value;
          }
        });
      }
    } catch (_) {}

    // Fetch today's stats
    try {
      final data = await ApiService.getDriverEarnings(period: 'today');
      if (mounted) {
        setState(() {
          _todayEarnings = (data['total'] as num?)?.toDouble() ?? 0.0;
          _todayTrips = (data['trips_count'] as num?)?.toInt() ?? 0;
          _todayHours = (data['online_hours'] as num?)?.toDouble() ?? 0.0;
        });
      }
    } catch (_) {}

    // Fetch unread notification count
    try {
      final notifs = await ApiService.getNotifications();
      if (mounted) {
        setState(() {
          _unreadCount = notifs.where((n) => n['is_read'] != true).length;
        });
      }
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
        transitionDuration: const Duration(milliseconds: 600),
        reverseTransitionDuration: const Duration(milliseconds: 450),
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
              child: ScaleTransition(scale: _fabScale, child: _buildGoButton()),
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
    final dc = DriverColors.of(context);
    if (_currentLatLng == null) {
      return Container(
        color: dc.bg,
        child: const Center(
          child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
        ),
      );
    }

    // Use AppleMap on iOS, GoogleMap on Android
    if (Platform.isIOS) {
      return amap.AppleMap(
        initialCameraPosition: amap.CameraPosition(
          target: amap.LatLng(_currentLatLng!.latitude, _currentLatLng!.longitude),
          zoom: 16,
        ),
        mapType: amap.MapType.standard,
        onMapCreated: (ctrl) {
          _appleMapController = ctrl;
          setState(() => _mapReady = true);
        },
        myLocationEnabled: true,
        myLocationButtonEnabled: false,
        zoomGesturesEnabled: true,
        scrollGesturesEnabled: true,
        rotateGesturesEnabled: false,
      );
    }

    final isDark = Theme.of(context).brightness == Brightness.dark;
    return RepaintBoundary(
      child: GoogleMap(
        style: isDark ? MapStyles.darkIOS : MapStyles.lightIOS,
        initialCameraPosition: CameraPosition(
          target: _currentLatLng!,
          zoom: 16,
        ),
        onMapCreated: (ctrl) {
          _mapController = ctrl;
          setState(() => _mapReady = true);
        },
        myLocationEnabled: true,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        mapToolbarEnabled: false,
        compassEnabled: true,
        buildingsEnabled: false,
        tiltGesturesEnabled: false,
        liteModeEnabled: false,
      ),
    );
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
                  return SlideTransition(
                    position:
                        Tween<Offset>(
                          begin: const Offset(-0.3, 0),
                          end: Offset.zero,
                        ).animate(
                          CurvedAnimation(
                            parent: anim,
                            curve: Curves.easeOutCubic,
                          ),
                        ),
                    child: FadeTransition(
                      opacity: CurvedAnimation(
                        parent: anim,
                        curve: Curves.easeOut,
                      ),
                      child: child,
                    ),
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
                // Avatar
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(colors: [_gold, _goldLight]),
                  ),
                  child: _photoUrl != null && _photoUrl!.isNotEmpty
                      ? ClipOval(
                          child: _photoUrl!.startsWith('http')
                              ? Image.network(
                                  _photoUrl!,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_a, _b, _c) => const Icon(
                                    Icons.person_rounded,
                                    color: Colors.black,
                                    size: 18,
                                  ),
                                )
                              : Image.file(
                                  File(_photoUrl!),
                                  fit: BoxFit.cover,
                                  errorBuilder: (_a, _b, _c) => const Icon(
                                    Icons.person_rounded,
                                    color: Colors.black,
                                    size: 18,
                                  ),
                                ),
                        )
                      : const Icon(
                          Icons.person_rounded,
                          color: Colors.black,
                          size: 18,
                        ),
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
          _mapController?.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(target: _currentLatLng!, zoom: 16),
            ),
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
      onVerticalDragStart: (_) => _dragging = true,
      onVerticalDragUpdate: (d) {
        setState(() {
          final delta = -d.delta.dy / (_panelExpandedH - _panelCollapsedH);
          _panelExtent = (_panelExtent + delta).clamp(0.0, 1.0);
        });
      },
      onVerticalDragEnd: (d) {
        _dragging = false;
        // Snap based on velocity + position
        final velocity = d.primaryVelocity ?? 0;
        double target;
        if (velocity < -300) {
          target = 1.0; // swiped up fast
        } else if (velocity > 300) {
          target = 0.0; // swiped down fast
        } else {
          target = _panelExtent > 0.3 ? 1.0 : 0.0;
        }
        _animatePanel(target);
      },
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
            // ── Drag handle ──
            Padding(
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
            // ── Header row: photo | status | list ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
              child: Row(
                children: [
                  // Driver photo
                  GestureDetector(
                    onTap: () {
                      HapticFeedback.selectionClick();
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const DriverEarningsScreen()));
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: _gold, width: 2),
                      ),
                      child: ClipOval(
                        child: _photoUrl != null && _photoUrl!.isNotEmpty
                            ? (_photoUrl!.startsWith('http')
                                ? Image.network(
                                    _photoUrl!,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_a, _b, _c) => Icon(
                                      Icons.person_rounded,
                                      color: dc.text.withValues(alpha: 0.6),
                                      size: 20,
                                    ),
                                  )
                                : Image.file(
                                    File(_photoUrl!),
                                    fit: BoxFit.cover,
                                    errorBuilder: (_a, _b, _c) => Icon(
                                      Icons.person_rounded,
                                      color: dc.text.withValues(alpha: 0.6),
                                      size: 20,
                                    ),
                                  ))
                            : Icon(
                                Icons.person_rounded,
                                color: dc.text.withValues(alpha: 0.6),
                                size: 20,
                              ),
                      ),
                    ),
                  ),
                  const Spacer(),
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
                        () {},
                      ),
                      _recommendItem(
                        Icons.schedule_rounded,
                        S.of(context).seeDrivingTime,
                        () {},
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
                                  'Go Offline',
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
      ),
    );
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
