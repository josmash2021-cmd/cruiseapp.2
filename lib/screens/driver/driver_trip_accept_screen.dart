import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import '../../config/page_transitions.dart';
import '../../widgets/verified_avatar.dart';
import '../../widgets/map/circular_pin_renderer.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../chat_screen.dart';
import '../help_screen.dart';
import 'driver_home_screen.dart';
import 'driver_online_screen.dart';
import 'driver_rate_rider_screen.dart';
import '../../services/api_service.dart';
import '../../services/gps_service.dart';
import '../../services/trip_firestore_service.dart';
import '../../navigation/nav_state_machine.dart';
import '../../utils/responsive.dart';
import '../../utils/name_helper.dart' as nh;

// ═══════════════════════════════════════════════════════════════════════════
//  DRIVER TRIP ACCEPT SCREEN  — DoorDash-style trip details sheet
//  Shown after driver accepts a ride offer.
//  • Client photo + star rating
//  • Mini Mapbox map preview centred on pickup
//  • Continue  → full navigation to pickup
//  • Directions → same navigation (overview-first)
// ═══════════════════════════════════════════════════════════════════════════

class DriverTripAcceptScreen extends StatefulWidget {
  const DriverTripAcceptScreen({
    super.key,
    required this.tripId,
    required this.riderName,
    this.riderPhotoUrl = '',
    this.riderRating = 4.8,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.fare,
    required this.vehicleType,
    required this.driverPos,
    required this.distToPickupKm,
    required this.etaMinutes,
    this.routePoints,
    this.riderPhone = '',
    this.pickupInstructions = '',
    this.dropoffInstructions = '',
    this.arrivedAtPickup = false,
    this.rideStarted = false,
  });

  final int tripId;
  final String riderName;
  final String riderPhotoUrl;
  final double riderRating;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String pickupAddress;
  final String dropoffAddress;
  final double fare;
  final String vehicleType;
  final LatLng driverPos;
  final double distToPickupKm;
  final int etaMinutes;
  final List<LatLng>? routePoints;
  final String riderPhone;
  final String pickupInstructions;
  final String dropoffInstructions;
  final bool arrivedAtPickup;
  final bool rideStarted;

  @override
  State<DriverTripAcceptScreen> createState() => _DriverTripAcceptScreenState();
}

class _DriverTripAcceptScreenState extends State<DriverTripAcceptScreen>
    with TickerProviderStateMixin {
  // ── Colours ──────────────────────────────────────────────────────────────
  static const _gold   = Color(0xFFD4A843);
  static const _bg     = Color(0xFF0A0A0A);
  static const _card   = Color(0xFF1A1A1A);
  static const _border = Color(0xFF262626);

  // ── Firestore doc ID (matches backend convention) ─────────────────────
  String get _fsDocId => 'sql_${widget.tripId}';

  // ── State ─────────────────────────────────────────────────────────────────
  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;
  late final AnimationController _slideCtrl;
  late final Animation<Offset>   _slideAnim;
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _annotMgr;
  mapbox.PolylineAnnotationManager? _polyMgr;

  // ── Start Trip → Continue/Directions fade ──
  bool _tripStarted = false;
  late final AnimationController _btnFadeCtrl;
  late final Animation<double>   _btnFadeAnim;

  // ── Resolved addresses (replace generic placeholders) ──
  late String _pickupAddr;
  late String _dropoffAddr;
  bool _resolvingAddresses = false;

  // ── Tilt animation ──
  late final AnimationController _tiltCtrl;
  late final Animation<double>   _tiltAnim;

  // ── Smooth route draw ──
  Ticker? _routeDrawTicker;
  mapbox.PolylineAnnotation? _routeAnnot;
  List<LatLng> _routePoints = [];

  // ── Pin pop animation ──
  late final AnimationController _pinPopCtrl;
  late final Animation<double> _pinPopAnim;
  final List<mapbox.PointAnnotation> _pinAnnots = [];

  // ── Slide-to-confirm state ──
  double _slideVal = 0;
  bool   _slid     = false;

  // ── Mini map animation already played flag ──
  bool _miniMapAnimDone = false;

  // ── Arrived at pickup detection ──
  bool _nearPickup = false;
  StreamSubscription<Position>? _gpsSub;
  static const _pickupRadiusMeters = 100.0;

  // ── Arrived at pickup confirmation (driver slid "Arrived") ──
  bool _arrivedConfirmed = false;
  double _arrivedSlideVal = 0;
  bool _arrivedSlidDone = false;

  // ── Ride started (passenger picked up → second "Start Trip") ──
  bool _rideStarted = false;
  double _startRideSlideVal = 0;
  bool _startRideSlidDone = false;

  // ── Dropoff proximity + trip finish ──
  bool _nearDropoff = false;
  StreamSubscription<Position>? _dropoffGpsSub;
  static const _dropoffRadiusMeters = 100.0;
  double _finishSlideVal = 0;
  bool _finishSlidDone = false;
  bool _tripFinished = false;
  Timer? _finishNavTimer;
  late final AnimationController _finishFadeCtrl;
  late final Animation<double> _finishFadeAnim;

  // ── Trip distance pickup→dropoff ─────────────────────────────────────────
  double get _tripKm {
    const r = 6371.0;
    final lat1 = widget.pickupLatLng.latitude  * math.pi / 180;
    final lat2 = widget.dropoffLatLng.latitude * math.pi / 180;
    final dLat = (widget.dropoffLatLng.latitude  - widget.pickupLatLng.latitude)  * math.pi / 180;
    final dLng = (widget.dropoffLatLng.longitude - widget.pickupLatLng.longitude) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) *
        math.sin(dLng / 2) * math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
  int get _tripEta => (_tripKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);

  @override
  void initState() {
    super.initState();
    _pickupAddr = widget.pickupAddress;
    _dropoffAddr = widget.dropoffAddress;
    _resolveGenericAddresses();

    // If returning from nav (trip already started), skip slide-to-confirm
    if (widget.arrivedAtPickup) {
      _tripStarted = true;
      _slid = true;
      _nearPickup = true;
      _arrivedConfirmed = true;
      _arrivedSlidDone = true;
    }
    // If ride already started (returning from dropoff nav), skip both sliders
    if (widget.rideStarted) {
      _tripStarted = true;
      _slid = true;
      _nearPickup = true;
      _arrivedConfirmed = true;
      _arrivedSlidDone = true;
      _rideStarted = true;
      _startRideSlidDone = true;
    }

    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);

    // Slide-up animation: fast snap
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..forward();
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));

    // Tilt controller: smooth 0° → 55° camera tilt
    _tiltCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );
    _tiltAnim = Tween<double>(begin: 0.0, end: 55.0).animate(
      CurvedAnimation(parent: _tiltCtrl, curve: Curves.easeInOutCubic),
    );
    _tiltCtrl.addListener(_applyMapTilt);

    // Pin pop controller (kept for compat, pins placed at full size now)
    _pinPopCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1),
    );
    _pinPopAnim = Tween<double>(begin: 1.0, end: 1.0).animate(_pinPopCtrl);

    // Button fade controller for Start Trip → Continue/Directions transition
    _btnFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: (widget.arrivedAtPickup || widget.rideStarted) ? 1.0 : 0.0,
    );
    _btnFadeAnim = CurvedAnimation(parent: _btnFadeCtrl, curve: Curves.easeOut);

    // Start GPS proximity detection for pickup (only if not already picked up)
    if (!widget.rideStarted) _startPickupProximityDetection();
    // Start dropoff proximity detection if ride already started
    if (widget.rideStarted) _startDropoffProximityDetection();

    // Finish overlay fade controller
    _finishFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _finishFadeAnim = CurvedAnimation(parent: _finishFadeCtrl, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _dropoffGpsSub?.cancel();
    _finishNavTimer?.cancel();
    _fadeCtrl.dispose();
    _slideCtrl.dispose();
    _tiltCtrl.dispose();
    _pinPopCtrl.dispose();
    _btnFadeCtrl.dispose();
    _finishFadeCtrl.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routePoints = [];
    _pinAnnots.clear();
    super.dispose();
  }

  // ── Resolve generic / placeholder addresses via reverse geocoding ────────
  static bool _isGenericAddress(String addr) {
    if (addr.isEmpty) return true;
    final lower = addr.toLowerCase().trim();
    return lower == 'current location' ||
        lower == 'ubicación actual' ||
        lower == 'pickup' ||
        lower == 'drop-off' ||
        lower == 'mi ubicación';
  }

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

  Future<void> _resolveGenericAddresses() async {
    final needsPickup = _isGenericAddress(_pickupAddr);
    final needsDropoff = _isGenericAddress(_dropoffAddr);
    if (!needsPickup && !needsDropoff) return;
    if (mounted) setState(() => _resolvingAddresses = true);
    if (needsPickup) {
      final resolved = await _reverseGeocode(
          widget.pickupLatLng.latitude, widget.pickupLatLng.longitude);
      if (mounted) {
        setState(() {
          _pickupAddr = resolved ??
              '${widget.pickupLatLng.latitude.toStringAsFixed(5)}, '
              '${widget.pickupLatLng.longitude.toStringAsFixed(5)}';
        });
      }
    }
    if (needsDropoff) {
      final resolved = await _reverseGeocode(
          widget.dropoffLatLng.latitude, widget.dropoffLatLng.longitude);
      if (mounted) {
        setState(() {
          _dropoffAddr = resolved ??
              '${widget.dropoffLatLng.latitude.toStringAsFixed(5)}, '
              '${widget.dropoffLatLng.longitude.toStringAsFixed(5)}';
        });
      }
    }
    if (mounted) setState(() => _resolvingAddresses = false);
  }

  // ── GPS proximity detection for pickup ──────────────────────────────────
  void _startPickupProximityDetection() {
    // Check initial position
    _checkPickupProximity(widget.driverPos);
    // Listen to GPS updates
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      if (!mounted || _nearPickup) return;
      _checkPickupProximity(LatLng(pos.latitude, pos.longitude));
    });
  }

  void _checkPickupProximity(LatLng driverPos) {
    final distM = _haversineMeters(driverPos, widget.pickupLatLng);
    if (distM <= _pickupRadiusMeters && !_nearPickup) {
      setState(() => _nearPickup = true);
      HapticFeedback.heavyImpact();
      _gpsSub?.cancel(); // Stop listening once arrived
    }
  }

  double _haversineMeters(LatLng a, LatLng b) {
    const r = 6371000.0; // Earth radius in meters
    final dLat = (b.latitude  - a.latitude)  * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
        math.cos(b.latitude * math.pi / 180) *
        math.sin(dLng / 2) * math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(s), math.sqrt(1 - s));
  }

  // ── Navigate to dropoff (ride started) ─────────────────────────────────
  void _goNavigateDropoff({bool overview = false}) {
    HapticFeedback.mediumImpact();
    _openNativeMaps(widget.dropoffLatLng);
  }

  // ── GPS proximity detection for DROPOFF ─────────────────────────────────
  void _startDropoffProximityDetection() {
    // Check current driver position first
    _checkDropoffProximity(widget.driverPos);
    _dropoffGpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      if (!mounted || _nearDropoff) return;
      _checkDropoffProximity(LatLng(pos.latitude, pos.longitude));
    });
  }

  void _checkDropoffProximity(LatLng driverPos) {
    final distM = _haversineMeters(driverPos, widget.dropoffLatLng);
    if (distM <= _dropoffRadiusMeters && !_nearDropoff) {
      setState(() => _nearDropoff = true);
      HapticFeedback.heavyImpact();
      _dropoffGpsSub?.cancel();
    }
  }

  // ── Confirm arrival at pickup (Arrived slider) ──────────────────────────
  Future<void> _confirmArrival() async {
    Future.delayed(const Duration(milliseconds: 300), () {
      if (!mounted) return;
      setState(() => _arrivedConfirmed = true);
    });
    // Notify rider + update backend status to 'arrived'
    try {
      await ApiService.updateTripStatus(tripId: widget.tripId, status: 'arrived');
    } catch (_) {}
    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(_fsDocId)
          .update({
        'status': 'arrived',
        'arrivedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  // ── Update trip status to in_trip when second Start Trip is slid ────────
  Future<void> _updateTripInTrip() async {
    try {
      await ApiService.updateTripStatus(tripId: widget.tripId, status: 'in_trip');
    } catch (_) {}
    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(_fsDocId)
          .update({
        'status': 'in_trip',
        'rideStartedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}
  }

  // ── Complete trip (API + Firestore + navigate to online) ────────────────
  Future<void> _finishTrip() async {
    if (_tripFinished) return;
    setState(() => _tripFinished = true);
    HapticFeedback.heavyImpact();

    // Update backend + Firestore
    try {
      await ApiService.updateTripStatus(tripId: widget.tripId, status: 'completed');
    } catch (_) {}
    try {
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(_fsDocId)
          .update({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
      });
    } catch (_) {}

    // Clear GPS trip tracking
    final gps = GpsService();
    try { await gps.clearTripLocation(); } catch (_) {}
    gps.setActiveTrip(null);
    try {
      await TripFirestoreService.clearDriverLocation(_fsDocId);
    } catch (_) {}

    // Show "Viaje Finalizado" overlay
    _finishFadeCtrl.forward();

    // After 3 seconds navigate to DriverRateRiderScreen
    _finishNavTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          pageBuilder: (_, anim, __) => DriverRateRiderScreen(
            tripId: widget.tripId,
            riderName: widget.riderName,
            riderPhotoUrl: widget.riderPhotoUrl,
            fare: widget.fare,
          ),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOutCubic),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 600),
        ),
        (route) => false,
      );
    });
  }

  // ── Navigation ────────────────────────────────────────────────────────────
  void _goNavigate({bool overview = false}) {
    HapticFeedback.mediumImpact();
    _openNativeMaps(widget.pickupLatLng);
  }

  Future<void> _openNativeMaps(LatLng dest) async {
    final lat = dest.latitude;
    final lng = dest.longitude;
    if (Platform.isIOS) {
      final gMapsUrl = Uri.parse(
        'comgooglemaps://?daddr=$lat,$lng&directionsmode=driving',
      );
      if (await canLaunchUrl(gMapsUrl)) {
        await launchUrl(gMapsUrl, mode: LaunchMode.externalApplication);
        return;
      }
      final wazeUrl = Uri.parse('waze://?ll=$lat,$lng&navigate=yes');
      if (await canLaunchUrl(wazeUrl)) {
        await launchUrl(wazeUrl, mode: LaunchMode.externalApplication);
        return;
      }
      await launchUrl(
        Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=d&t=m'),
        mode: LaunchMode.externalApplication,
      );
    } else {
      final gMapsUrl = Uri.parse('google.navigation:q=$lat,$lng&mode=d');
      if (await canLaunchUrl(gMapsUrl)) {
        await launchUrl(gMapsUrl, mode: LaunchMode.externalApplication);
        return;
      }
      final wazeUrl = Uri.parse('waze://?ll=$lat,$lng&navigate=yes');
      if (await canLaunchUrl(wazeUrl)) {
        await launchUrl(wazeUrl, mode: LaunchMode.externalApplication);
        return;
      }
      await launchUrl(
        Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving'),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  // ── Phone / Message ───────────────────────────────────────────────────────
  Future<void> _call() async {
    String phone = widget.riderPhone.trim();
    if (phone.isEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('trips')
            .doc(_fsDocId)
            .get();
        final data = snap.data();
        phone = (data?['rider_phone'] ?? data?['passengerPhone'] ?? '').toString().trim();
      } catch (_) {}
    }
    if (phone.isEmpty) return;
    final uri = Uri(scheme: 'tel', path: phone);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String _timeLabel() {
    final now = DateTime.now();
    int h = now.hour % 12;
    if (h == 0) h = 12;
    final m   = now.minute.toString().padLeft(2, '0');
    final ap  = now.hour >= 12 ? 'PM' : 'AM';
    return 'by $h:$m $ap';
  }

  Widget _avatar() {
    return VerifiedAvatar(
      photoUrl: widget.riderPhotoUrl.isNotEmpty ? widget.riderPhotoUrl : null,
      radius: Responsive.w(33),
      fallbackName: widget.riderName,
      isVerified: true,
    );
  }

  Widget _initialsFill(String init) => Container(
    color: const Color(0xFF1A1F35),
    child: Center(
      child: Text(init,
        style: const TextStyle(color: _gold, fontSize: 22, fontWeight: FontWeight.w700)),
    ),
  );

  Widget _initialsCircle(String init) => Container(
    width: 66, height: 66,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        colors: [Color(0xFFD4A843), Color(0xFFF5D990)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Text(init,
        style: const TextStyle(color: Colors.black, fontSize: 26, fontWeight: FontWeight.w900)),
    ),
  );

  Widget _stars(double r) {
    final full = r.floor();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Icon(
        i < full ? Icons.star_rounded
                 : (i < r ? Icons.star_half_rounded : Icons.star_outline_rounded),
        color: _gold, size: 15,
      )),
    );
  }

  Widget _actionBtn(IconData icon, String label, VoidCallback onTap) =>
      GestureDetector(
        onTap: onTap,
        child: Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(color: const Color(0xFFFFD700), width: 1.5),
          ),
          child: Icon(icon, color: const Color(0xFFFFD700), size: 18),
        ),
      );

  Widget _infoRow(
    IconData icon,
    Color iconBg,
    Color iconColor,
    String label,
    String address, {
    bool showChevron = false,
  }) => Container(
    padding: const EdgeInsets.all(14),
    decoration: BoxDecoration(
      color: _card,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: _border),
    ),
    child: Row(
      children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: iconBg,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: iconColor, size: 19),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 11, fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                )),
              const SizedBox(height: 2),
              Text(address,
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w600),
                maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        if (showChevron)
          Icon(Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.24), size: 22),
      ],
    ),
  );

  // ── Chat ─────────────────────────────────────────────────────────────────
  void _openChat() {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      slideFromRightRoute(ChatScreen(
        recipientName: widget.riderName,
        recipientPhone: widget.riderPhone,
        tripId: widget.tripId,
        currentRole: 'driver',
      )),
    );
  }

  // ── Navigation app integration ───────────────────────────────────────────
  void _showNavigationSheet({required bool isPickup}) {
    final coords = isPickup ? widget.pickupLatLng : widget.dropoffLatLng;
    final address = isPickup ? _pickupAddr : _dropoffAddr;
    final bot = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, bot + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Icon(isPickup ? Icons.location_on_rounded : Icons.flag_rounded,
                  color: _gold, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(address,
                  style: const TextStyle(color: Colors.white, fontSize: 15,
                      fontWeight: FontWeight.w700),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ]),
            const SizedBox(height: 20),
            _navOption(
              icon: Icons.map_rounded,
              label: 'Open in Apple Maps',
              onTap: () {
                Navigator.pop(context);
                _openAppleMaps(coords);
              },
            ),
            const SizedBox(height: 8),
            _navOption(
              icon: Icons.map_outlined,
              label: 'Open in Google Maps',
              onTap: () {
                Navigator.pop(context);
                _openGoogleMaps(coords);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _navOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white70, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 14,
              fontWeight: FontWeight.w600))),
        Icon(Icons.chevron_right_rounded,
            color: Colors.white.withValues(alpha: 0.28), size: 18),
      ]),
    ),
  );

  Future<void> _openAppleMaps(LatLng coords) async {
    final uri = Uri.parse(
      'https://maps.apple.com/?daddr=${coords.latitude},${coords.longitude}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openGoogleMaps(LatLng coords) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&destination=${coords.latitude},${coords.longitude}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── Safety / Help menus ───────────────────────────────────────────────────
  void _showSafetyMenu() {
    HapticFeedback.mediumImpact();
    _showSheet(
      title: 'Safety Center',
      icon: Icons.shield_rounded,
      iconColor: const Color(0xFF4CAF50),
      items: [
        _SheetItem(Icons.emergency_rounded, 'Emergency',
            'Call 911 or emergency services', () {
          Navigator.pop(context);
          launchUrl(Uri.parse('tel:911'));
        }),
        _SheetItem(Icons.report_problem_rounded, 'Report Safety Issue',
            'Report a safety concern about this trip', () => Navigator.pop(context)),
        _SheetItem(Icons.share_location_rounded, 'Share My Location',
            'Share trip with a trusted contact', () => Navigator.pop(context)),
      ],
    );
  }

  void _showHelpMenu() {
    HapticFeedback.mediumImpact();
    _showSheet(
      title: 'Help',
      icon: Icons.help_rounded,
      iconColor: _gold,
      items: [
        _SheetItem(Icons.location_on_rounded, 'Problem with pickup address',
            'The pickup location is incorrect or unclear',
            () { Navigator.pop(context); _showPickupProblem(); }),
        _SheetItem(Icons.flag_rounded, 'Problem with dropoff address',
            'The dropoff location is incorrect or unclear',
            () { Navigator.pop(context); _showDropoffProblem(); }),
        _SheetItem(Icons.directions_car_rounded, 'Problem with trip',
            'Other issue with this trip',
            () { Navigator.pop(context); _showTripProblem(); }),
        _SheetItem(Icons.support_agent_rounded, 'Contact Support',
            'Speak with a support agent',
            () { Navigator.pop(context); _openSupportChat(); }),
      ],
    );
  }

  // ── Help button 1 — Pickup address problem ─────────────────────────────
  void _showPickupProblem() {
    _showReportSheet(
      title: 'Problema con dirección de recogida',
      type: 'pickup_address_problem',
      reasons: [
        'La dirección es incorrecta',
        'No puedo encontrar el lugar',
        'El rider no está en la ubicación',
        'Otra razón',
      ],
    );
  }

  // ── Help button 2 — Dropoff address problem ────────────────────────────
  void _showDropoffProblem() {
    _showReportSheet(
      title: 'Problema con dirección de destino',
      type: 'dropoff_address_problem',
      reasons: [
        'La dirección es incorrecta',
        'No puedo llegar a ese lugar',
        'El destino no existe',
        'Otra razón',
      ],
    );
  }

  // ── Help button 3 — Trip problem ───────────────────────────────────────
  void _showTripProblem() {
    _showReportSheet(
      title: 'Problema con el viaje',
      type: 'trip_problem',
      reasons: [
        'El rider no aparece',
        'El rider canceló de forma inapropiada',
        'Problema de seguridad',
        'El viaje fue modificado sin mi consentimiento',
        'Otra razón',
      ],
    );
  }

  // ── Help button 4 — Contact Support (live chat) ────────────────────────
  void _openSupportChat() {
    HapticFeedback.lightImpact();
    Navigator.of(context).push(
      slideFromRightRoute(const CruiseSupportChatScreen()),
    );
  }

  // ── Generic report bottom sheet ────────────────────────────────────────
  void _showReportSheet({
    required String title,
    required String type,
    required List<String> reasons,
  }) {
    final bot = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1a1a2e),
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          border: Border(top: BorderSide(color: Color(0xFFc8a951), width: 1)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, bot + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Align(
              alignment: Alignment.centerLeft,
              child: Text(title, style: const TextStyle(
                color: Colors.white, fontSize: 17, fontWeight: FontWeight.w800)),
            ),
            const SizedBox(height: 14),
            ...reasons.map((reason) => _reportOption(ctx, reason, type)),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text('Cancelar',
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.42),
                    fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _reportOption(BuildContext ctx, String reason, String type) {
    return GestureDetector(
      onTap: () {
        Navigator.pop(ctx);
        if (type == 'trip_problem' && reason == 'Problema de seguridad') {
          _showSafetyConfirmation(reason, type);
        } else {
          _submitReport(type: type, reason: reason, urgent: false);
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF0d0d1a),
          borderRadius: BorderRadius.circular(12),
          border: const Border(left: BorderSide(color: Color(0xFFc8a951), width: 2)),
        ),
        child: Row(children: [
          Expanded(child: Text(reason,
            style: const TextStyle(color: Colors.white, fontSize: 14,
              fontWeight: FontWeight.w700))),
          const Icon(Icons.chevron_right_rounded, color: Color(0xFFc8a951), size: 20),
        ]),
      ),
    );
  }

  // ── Safety emergency confirmation ──────────────────────────────────────
  void _showSafetyConfirmation(String reason, String type) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a2e),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('¿Necesitas ayuda de emergencia?',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.w800, fontSize: 17)),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.pop(ctx);
              _submitReport(type: type, reason: reason, urgent: true);
            },
            child: Text('No, solo reportar',
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _submitReport(type: type, reason: reason, urgent: true);
              launchUrl(Uri.parse('tel:911'));
            },
            child: const Text('Sí, llamar al 911',
              style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  // ── Submit report to Firestore ─────────────────────────────────────────
  Future<void> _submitReport({
    required String type,
    required String reason,
    required bool urgent,
  }) async {
    try {
      final driverId = FirebaseAuth.instance.currentUser?.uid ?? '';
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(_fsDocId)
          .collection('reports')
          .add({
        'type': type,
        'reason': reason,
        'reportedAt': FieldValue.serverTimestamp(),
        'tripId': widget.tripId,
        'driverId': driverId,
        if (urgent) 'urgent': true,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Reporte enviado. El equipo lo revisará.'),
        backgroundColor: Color(0xFF1a1a2e),
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error al enviar reporte: $e'),
        backgroundColor: Colors.red,
      ));
    }
  }

  void _showSheet({
    required String title,
    required IconData icon,
    required Color iconColor,
    required List<_SheetItem> items,
  }) {
    final bot = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1A),
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, bot + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 10),
              Text(title, style: const TextStyle(
                  color: Colors.white, fontSize: 17,
                  fontWeight: FontWeight.w800)),
            ]),
            const SizedBox(height: 14),
            ...items.map(_buildSheetItem),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetItem(_SheetItem item) => GestureDetector(
    onTap: item.onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(item.icon, color: Colors.white70, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(item.label,
              style: const TextStyle(color: Colors.white, fontSize: 14,
                  fontWeight: FontWeight.w600)),
            if (item.sub.isNotEmpty) ...[const SizedBox(height: 2),
              Text(item.sub,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.42),
                    fontSize: 12)),
            ],
          ],
        )),
        Icon(Icons.chevron_right_rounded,
            color: Colors.white.withValues(alpha: 0.28), size: 18),
      ]),
    ),
  );

  // ── Map ─────────────────────────────────────────────────────────────────────

  List<mapbox.Position> _decodePoly(String encoded) {
    final pts = <mapbox.Position>[];
    int i = 0, lat = 0, lng = 0;
    while (i < encoded.length) {
      int s = 0, r = 0, b;
      do { b = encoded.codeUnitAt(i++) - 63; r |= (b & 0x1F) << s; s += 5; } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0; r = 0;
      do { b = encoded.codeUnitAt(i++) - 63; r |= (b & 0x1F) << s; s += 5; } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add(mapbox.Position(lng / 1E5, lat / 1E5));
    }
    return pts;
  }

  /// Load route: prefer cached widget.routePoints, fallback to OSRM fetch
  Future<List<LatLng>> _loadRoute() async {
    // Use cached route from offer pre-fetch (instant, no straight-line bug)
    if (widget.routePoints != null && widget.routePoints!.length >= 2) {
      return List<LatLng>.from(widget.routePoints!);
    }
    // Fallback — fetch fresh pickup→dropoff only
    return _fetchRoutePoints(widget.pickupLatLng, widget.dropoffLatLng);
  }

  // onMapCreated — capture controller + disable all gestures for preview perf.
  void _onMapReady(mapbox.MapboxMap ctrl) {
    _map = ctrl;
    // Disable all interaction — this is a read-only preview map.
    ctrl.gestures.updateSettings(mapbox.GesturesSettings(
      scrollEnabled: false,
      rotateEnabled: false,
      pinchToZoomEnabled: false,
      doubleTapToZoomInEnabled: false,
      doubleTouchToZoomOutEnabled: false,
      pitchEnabled: false,
      quickZoomEnabled: false,
      simultaneousRotateAndPinchToZoomEnabled: false,
    ));
    // Hide compass + attribution for clean preview.
    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    ctrl.attribution.updateSettings(mapbox.AttributionSettings(
      iconColor: 0x00000000,
      position: mapbox.OrnamentPosition.BOTTOM_LEFT,
    ));
    ctrl.logo.updateSettings(mapbox.LogoSettings(
      position: mapbox.OrnamentPosition.BOTTOM_LEFT,
      marginLeft: -100,
    ));
  }

  // onStyleLoadedListener — style is guaranteed ready here; run all setup.
  Future<void> _onStyleLoaded(mapbox.StyleLoadedEventData _) async {
    final ctrl = _map;
    if (ctrl == null || !mounted) return;

    // Fire all independent setup in parallel for speed.
    final setupFutures = <Future>[
      MapTheme.applyNavyGold(ctrl),
      ctrl.annotations.createPolylineAnnotationManager().then((m) => _polyMgr = m),
      ctrl.annotations.createPointAnnotationManager().then((m) async {
        _annotMgr = m;
        try {
          // 'map' keeps pin tips glued to the map surface — prevents floating
          // when camera is tilted. 'bottom' anchors the teardrop tip at the coordinate.
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-pitch-alignment', 'map');
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-rotation-alignment', 'viewport');
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-allow-overlap', true);
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-ignore-placement', true);
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-anchor', 'bottom');
        } catch (_) {}
      }),
    ];
    await Future.wait(setupFutures);
    if (!mounted) return;

    // Load route + render pins in parallel.
    final results = await Future.wait([
      _loadRoute(),
      renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32),
      renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 32),
    ]);
    if (!mounted) return;

    _routePoints = results[0] as List<LatLng>;
    final pickupPinBytes = results[1] as Uint8List;
    final dropoffPinBytes = results[2] as Uint8List;

    if (_routePoints.length < 2) return;

    // Cap route endpoints to exact pin positions so polyline meets the pins
    _routePoints[0] = widget.pickupLatLng;
    _routePoints[_routePoints.length - 1] = widget.dropoffLatLng;

    // Include driver position + pickup + dropoff + route in bounds so everything is visible.
    final allPoints = [
      widget.driverPos,
      widget.pickupLatLng,
      widget.dropoffLatLng,
      ..._routePoints,
    ];
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in allPoints) {
      if (p.latitude  < minLat) minLat = p.latitude;
      if (p.latitude  > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final bounds = mapbox.CoordinateBounds(
      southwest: mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
      northeast: mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
      infiniteBounds: false,
    );
    // Compute a small auto-bearing based on route direction for a pleasant angle.
    final rBearing = _routeBearing(_routePoints);
    final prettBearing = (rBearing + 15.0) % 360;

    // ── If returning (animation already played), show final state instantly ──
    if (_miniMapAnimDone || widget.arrivedAtPickup) {
      _miniMapAnimDone = true;
      final cam = await ctrl.cameraForCoordinateBounds(
        bounds,
        mapbox.MbxEdgeInsets(top: 24, left: 24, bottom: 34, right: 24),
        prettBearing,
        55,
        null, null,
      );
      if (!mounted) return;
      final targetZoom = ((cam.zoom ?? 13) + 0.3).clamp(11.5, 15.5);
      ctrl.setCamera(mapbox.CameraOptions(
        center: cam.center, zoom: targetZoom, bearing: prettBearing, pitch: 55.0,
      ));
      // Place pins + route instantly
      final pickupPoint = mapbox.Position(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude);
      final dropoffPoint = mapbox.Position(widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude);
      _pinAnnots.clear();
      if (_annotMgr != null) {
        final pins = await Future.wait([
          _annotMgr!.create(mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(coordinates: pickupPoint),
            image: pickupPinBytes, iconSize: 1.0, iconAnchor: mapbox.IconAnchor.BOTTOM,
          )),
          _annotMgr!.create(mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(coordinates: dropoffPoint),
            image: dropoffPinBytes, iconSize: 1.0, iconAnchor: mapbox.IconAnchor.BOTTOM,
          )),
        ]);
        _pinAnnots.addAll(pins);
      }
      if (_polyMgr != null && _routePoints.length >= 2) {
        try {
          final coords = _routePoints
              .where((p) => p.latitude.isFinite && p.longitude.isFinite)
              .map((p) => mapbox.Position(p.longitude, p.latitude))
              .toList();
          if (coords.length >= 2) {
            _routeAnnot = await _polyMgr!.create(mapbox.PolylineAnnotationOptions(
              geometry: mapbox.LineString(coordinates: coords),
              lineColor: const Color(0xFFFFD700).toARGB32(),
              lineWidth: 5.0,
              lineJoin: mapbox.LineJoin.ROUND,
            ));
          }
        } catch (_) {}
      }
      return;
    }

    // ── First visit: animated sequence ──

    // STEP 1: Fit bounds at pitch 0 (top-down) so everything is visible flat
    final camFlat = await ctrl.cameraForCoordinateBounds(
      bounds,
      mapbox.MbxEdgeInsets(top: 24, left: 24, bottom: 34, right: 24),
      prettBearing,
      0, // pitch 0 for flat fit
      null, null,
    );
    if (!mounted) return;
    final targetZoom = ((camFlat.zoom ?? 13) + 0.3).clamp(11.5, 15.5);
    ctrl.setCamera(mapbox.CameraOptions(
      center: camFlat.center, zoom: targetZoom, bearing: prettBearing, pitch: 0.0,
    ));

    // STEP 2: Pins pop in (scale 0 → 1.0 with spring)
    final pickupPoint = mapbox.Position(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude);
    final dropoffPoint = mapbox.Position(widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude);
    _pinAnnots.clear();
    if (_annotMgr != null) {
      final pins = await Future.wait([
        _annotMgr!.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: pickupPoint),
          image: pickupPinBytes, iconSize: 0.01, iconAnchor: mapbox.IconAnchor.BOTTOM,
        )),
        _annotMgr!.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: dropoffPoint),
          image: dropoffPinBytes, iconSize: 0.01, iconAnchor: mapbox.IconAnchor.BOTTOM,
        )),
      ]);
      _pinAnnots.addAll(pins);
    }
    // Animate pins: 0.01 → 1.15 → 1.0 over 400ms
    const pinMs = 400;
    final pinSw = Stopwatch()..start();
    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 16));
      if (!mounted) return false;
      final t = (pinSw.elapsedMilliseconds / pinMs).clamp(0.0, 1.0);
      double scale;
      if (t < 0.6) {
        scale = Curves.easeOutCubic.transform(t / 0.6) * 1.15;
      } else if (t < 0.85) {
        scale = 1.15 - 0.15 * Curves.easeInOut.transform((t - 0.6) / 0.25);
      } else {
        scale = 1.0;
      }
      for (final pin in _pinAnnots) {
        pin.iconSize = scale;
        try { await _annotMgr?.update(pin); } catch (_) {}
      }
      return t < 1.0;
    });
    if (!mounted) return;

    // STEP 3: Animated route draw (use robust ticker-based method)
    if (_polyMgr != null && _routePoints.length >= 2) {
      try {
        // Filter out any invalid coordinates before drawing
        final validPts = _routePoints.where((p) =>
          p.latitude.isFinite && p.longitude.isFinite &&
          p.latitude.abs() <= 90 && p.longitude.abs() <= 180
        ).toList();
        if (validPts.length >= 2) {
          await _animateGoldRoute(
            points: validPts,
            duration: const Duration(milliseconds: 800),
          );
        }
      } catch (_) {
        // Fallback: draw full route instantly if animation fails
        if (_polyMgr != null && _routePoints.length >= 2 && mounted) {
          try {
            final coords = _routePoints.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
            _routeAnnot ??= await _polyMgr!.create(mapbox.PolylineAnnotationOptions(
              geometry: mapbox.LineString(coordinates: coords),
              lineColor: const Color(0xFFFFD700).toARGB32(),
              lineWidth: 5.0,
              lineJoin: mapbox.LineJoin.ROUND,
            ));
          } catch (_) {}
        }
      }
    }
    if (!mounted) return;

    // STEP 4: Camera tilt 0° → 55° (last animation)
    await Future.delayed(const Duration(milliseconds: 200));
    if (mounted) _tiltCtrl.forward();

    _miniMapAnimDone = true;
  }

  void _updatePinScale() {
    if (_annotMgr == null || _pinAnnots.isEmpty) return;
    final s = _pinPopAnim.value;
    for (final pin in _pinAnnots) {
      pin.iconSize = s;
      _annotMgr!.update(pin);
    }
  }

  void _applyMapTilt() {
    if (_map == null || !mounted) return;
    _map!.setCamera(mapbox.CameraOptions(pitch: _tiltAnim.value));
  }

  /// Compute overall bearing of the route (start → end) for camera orientation.
  double _routeBearing(List<LatLng> pts) {
    if (pts.length < 2) return 0;
    final a = pts.first;
    final b = pts.last;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Fetch route points: Google Directions → OSRM → straight line
  Future<List<LatLng>> _fetchRoutePoints(LatLng o, LatLng d) async {
    // OSRM
    try {
      final path = '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full', 'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final positions = _decodePoly(routes[0]['geometry'] as String);
          final pts = positions.map((p) => LatLng(p.lat.toDouble(), p.lng.toDouble())).toList();
          return pts;
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
          final coords = mbxRoutes[0]['geometry']?['coordinates'] as List?;
          if (coords != null && coords.isNotEmpty) {
            final pts = coords
                .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
            return pts;
          }
        }
      }
    } catch (_) {}
    // Straight line fallback
    return List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        o.latitude  + (d.latitude  - o.latitude)  * t,
        o.longitude + (d.longitude - o.longitude) * t,
      );
    });
  }

  /// Smooth 60fps 4-layer gold gloss route draw using Ticker + easeInOutSine
  Future<void> _animateGoldRoute({
    required List<LatLng> points,
    required Duration duration,
  }) async {
    final polyMgr = _polyMgr;
    if (polyMgr == null || points.length < 2) return;

    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    final totalMs = duration.inMilliseconds;
    int lastCount = 0;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) async {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final eased = Curves.easeInOutSine.transform(progress);
      final count = (eased * points.length).round().clamp(2, points.length);

      if (count != lastCount) {
        lastCount = count;
        final subset = points.sublist(0, count);
        final coords = subset.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final geo = mapbox.LineString(coordinates: coords);

        if (_routeAnnot == null) {
          // Single 5px gold line
          _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
            geometry: geo,
            lineColor: const Color(0xFFFFD700).toARGB32(),
            lineWidth: 5.0,
            lineJoin: mapbox.LineJoin.ROUND,
          ));
        } else {
          _routeAnnot!.geometry = geo;
          await polyMgr.update(_routeAnnot!);
        }
      }
      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final fullGeo = mapbox.LineString(coordinates: fullCoords);
        if (_routeAnnot != null) { _routeAnnot!.geometry = fullGeo; await polyMgr.update(_routeAnnot!); }
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  // ── Hanging instruction card ────────────────────────────────────────────
  Widget _buildHangingInstruction(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Gold connector line
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Column(
            children: [
              Container(
                width: 1.5,
                height: 28,
                color: _gold.withValues(alpha: 0.40),
              ),
              Icon(Icons.sticky_note_2_outlined,
                  size: 16, color: _gold.withValues(alpha: 0.70)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        // Instruction card
        Expanded(
          child: Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1F35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _gold.withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.82),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bot = MediaQuery.of(context).padding.bottom;

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarColor:           Colors.transparent,
      statusBarIconBrightness:  Brightness.light,
    ));

    return Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Column(
          children: [
            // ── Header ────────────────────────────────────────────────────
            Container(
              color: _bg,
              padding: EdgeInsets.fromLTRB(Responsive.w(16), top + 10, Responsive.w(16), Responsive.h(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row: back / help icons
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          Navigator.of(context).pushAndRemoveUntil(
                            MaterialPageRoute(builder: (_) => const DriverHomeScreen(returnFromTrip: true)),
                            (route) => false,
                          );
                        },
                        child: Container(
                          width: Responsive.w(36), height: Responsive.w(36),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.chevron_left_rounded,
                              color: Colors.white, size: Responsive.sp(24)),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _showSafetyMenu,
                        child: Container(
                          width: Responsive.w(36), height: Responsive.w(36),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.shield_rounded,
                              color: Colors.white.withValues(alpha: 0.75), size: Responsive.sp(19)),
                        ),
                      ),
                      SizedBox(width: Responsive.w(10)),
                      GestureDetector(
                        onTap: _showHelpMenu,
                        child: Container(
                          width: Responsive.w(36), height: Responsive.w(36),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.help_outline_rounded,
                              color: Colors.white.withValues(alpha: 0.75), size: Responsive.sp(19)),
                        ),
                      ),
                    ],
                  ),
                  SizedBox(height: Responsive.h(16)),
                  // Title
                  Text('Ride for ${nh.displayName(widget.riderName, widget.vehicleType)}',
                    style: TextStyle(
                      color: Colors.white, fontSize: Responsive.sp(24),
                      fontWeight: FontWeight.w800, height: 1.15)),
                  const SizedBox(height: 3),
                  Text(_timeLabel(),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.42),
                      fontSize: Responsive.sp(13), fontWeight: FontWeight.w400)),
                  SizedBox(height: Responsive.h(16)),
                  // Rider row: avatar + info + call/msg
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _avatar(),
                      SizedBox(width: Responsive.w(12)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(nh.displayName(widget.riderName, widget.vehicleType),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white, fontSize: Responsive.sp(15),
                                fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            _stars(widget.riderRating),
                            const SizedBox(height: 3),
                            Text('${widget.riderRating.toStringAsFixed(1)} rating',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.42),
                                fontSize: Responsive.sp(11))),
                          ],
                        ),
                      ),
                      SizedBox(width: Responsive.w(10)),
                      _actionBtn(Icons.phone_rounded, 'Call', _call),
                      SizedBox(width: Responsive.w(8)),
                      _actionBtn(Icons.message_rounded, 'Message', _openChat),
                    ],
                  ),
                ],
              ),
            ),

            // ── Map preview (tilt animation on enter) ─────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), Responsive.h(12)),
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(16),
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.12),
                      blurRadius: 24,
                      spreadRadius: -2,
                      offset: const Offset(0, 8),
                    ),
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.50),
                      blurRadius: 32,
                      spreadRadius: 2,
                      offset: const Offset(0, 12),
                    ),
                  ],
                ),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    height: Responsive.h(190),
                    child: Stack(
                      children: [
                        RepaintBoundary(
                          child: mapbox.MapWidget(
                            styleUri: MapboxConfig.styleDark,
                            cameraOptions: mapbox.CameraOptions(
                              center: mapbox.Point(coordinates: mapbox.Position(
                                widget.pickupLatLng.longitude,
                                widget.pickupLatLng.latitude,
                              )),
                              zoom: 12.0,
                              pitch: 0.0,
                              bearing: 0.0,
                            ),
                            onMapCreated: _onMapReady,
                            onStyleLoadedListener: _onStyleLoaded,
                          ),
                        ),
                        // 3D fade vignette — top edge
                        Positioned(
                          top: 0, left: 0, right: 0,
                          height: 28,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.topCenter,
                                end: Alignment.bottomCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.45),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                        // 3D fade vignette — bottom edge
                        Positioned(
                          bottom: 0, left: 0, right: 0,
                          height: 36,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              gradient: LinearGradient(
                                begin: Alignment.bottomCenter,
                                end: Alignment.topCenter,
                                colors: [
                                  Colors.black.withValues(alpha: 0.55),
                                  Colors.transparent,
                                ],
                              ),
                            ),
                          ),
                        ),
                        // ETA chip
                        Positioned(
                          top: 10, right: 10,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.72),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              '$_tripEta min trip',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        ),
                        // Mapbox attribution — plain text, no box
                        Positioned(
                          bottom: 5, left: 8,
                          child: Text(' Mapbox',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 9,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),

            // ── Pickup address card + hanging instructions ────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), 0),
              child: GestureDetector(
                onTap: () => _showNavigationSheet(isPickup: true),
                child: _infoRow(
                  Icons.location_on_rounded,
                  _gold.withValues(alpha: 0.15),
                  _gold,
                  'Pickup',
                  _resolvingAddresses && _pickupAddr.isEmpty
                      ? 'Obteniendo direcci\u00f3n...'
                      : _pickupAddr,
                  showChevron: true,
                ),
              ),
            ),
            if (widget.pickupInstructions.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), 0),
                child: _buildHangingInstruction(widget.pickupInstructions),
              ),
            const SizedBox(height: 8),

            // ── Dropoff address card + hanging instructions ───────────────
            Padding(
              padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), 0),
              child: GestureDetector(
                onTap: () => _showNavigationSheet(isPickup: false),
                child: _infoRow(
                  Icons.flag_rounded,
                  _gold.withValues(alpha: 0.15),
                  _gold,
                  'Dropoff',
                  _resolvingAddresses && _dropoffAddr.isEmpty
                      ? 'Obteniendo direcci\u00f3n...'
                      : _dropoffAddr,
                  showChevron: true,
                ),
              ),
            ),
            if (widget.dropoffInstructions.isNotEmpty)
              Padding(
                padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), 0),
                child: _buildHangingInstruction(widget.dropoffInstructions),
              ),
            const SizedBox(height: 10),

            const Spacer(),

            // ── Bottom buttons: 6 phases ─────────────────────────────────
            // Phase 1: Slide "Start Trip" (driving to pickup)
            // Phase 2: Continue/Directions (pickup nav)
            // Phase 3: Slide "Arrived" (near pickup, GPS detected)
            // Phase 4: Slide "Start Trip" #2 (confirmed arrival → go to dropoff)
            // Phase 5: Continue/Directions (dropoff nav)
            // Phase 6: Slide "Finalizar Viaje" (near dropoff, GPS detected)
            if (!_tripFinished)
            Padding(
              padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), bot + 18),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 350),
                switchInCurve: Curves.easeOut,
                switchOutCurve: Curves.easeIn,
                child: _buildCurrentPhaseWidget(),
              ),
            ),
          ],
        ),
      ),
      ),

      // ── Phase 4: "Viaje Finalizado" full-screen overlay ───────────────
      if (_tripFinished)
        Positioned.fill(
          child: FadeTransition(
          opacity: _finishFadeAnim,
          child: Container(
            color: Colors.black.withValues(alpha: 0.85),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 80, height: 80,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _gold.withValues(alpha: 0.15),
                      border: Border.all(color: _gold, width: 2.5),
                    ),
                    child: const Icon(Icons.check_rounded,
                        color: _gold, size: 44),
                  ),
                  const SizedBox(height: 24),
                  const Text('Viaje Finalizado',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text('\$${widget.fare.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 22,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(widget.riderName,
                    style: TextStyle(
                      color: Colors.grey[400],
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
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
    );
  }

  // ── Phase router: returns the correct widget for the current state ────
  Widget _buildCurrentPhaseWidget() {
    // Phase 6: Near dropoff → Finalizar Viaje
    if (_rideStarted && _nearDropoff) {
      return _buildSlideFinishTrip();
    }
    // Phase 5: Ride started, not near dropoff → Continue/Directions (dropoff)
    if (_rideStarted && !_nearDropoff) {
      return _buildContinueDirectionsDropoff();
    }
    // Phase 4: Arrived confirmed, ride not started → second Start Trip
    if (_arrivedConfirmed && !_rideStarted) {
      return _buildSlideStartRide();
    }
    // Phase 3: Near pickup, not confirmed → Arrived slider
    if (_tripStarted && _nearPickup && !_arrivedConfirmed) {
      return _buildSlideArrived();
    }
    // Phase 2: Trip started, not near pickup → Continue/Directions (pickup)
    if (_tripStarted && !_nearPickup) {
      return _buildContinueDirections();
    }
    // Phase 1: Slide Start Trip
    return _buildSlideStartTrip();
  }

  // ── Slide-to-confirm "Start Trip" widget ────────────────────────────────
  Widget _buildSlideStartTrip() {
    const height = 62.0;
    const thumbW = 62.0;
    return Container(
      key: const ValueKey('slide_start_trip'),
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final trackW = constraints.maxWidth;
          final maxDrag = trackW - thumbW - 4;
          return SizedBox(
            height: height,
            child: Stack(
              children: [
                // Fill
                Positioned(
                  left: 0, top: 0, bottom: 0,
                  width: (_slideVal * maxDrag + thumbW).clamp(thumbW.toDouble(), trackW),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.45),
                          _gold.withValues(alpha: 0.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                ),
                // Label
                Center(
                  child: AnimatedOpacity(
                    opacity: 1.0 - _slideVal,
                    duration: const Duration(milliseconds: 100),
                    child: const Text('Start Trip  →',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
                // Thumb
                Positioned(
                  left: 2 + _slideVal * maxDrag,
                  top: 3, bottom: 3,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) {
                      if (_slid) return;
                      setState(() {
                        _slideVal = (_slideVal + d.delta.dx / maxDrag)
                            .clamp(0.0, 1.0);
                      });
                      if (_slideVal >= 0.88) {
                        setState(() => _slid = true);
                        HapticFeedback.heavyImpact();
                        // Gloss re-animate the route polyline then open maps
                        Future.delayed(const Duration(milliseconds: 300), () async {
                          if (!mounted) return;
                          // Re-draw the existing route with gloss animation
                          if (_routePoints.length >= 2) {
                            // Remove existing route so re-draw is visible
                            if (_routeAnnot != null && _polyMgr != null) {
                              try { await _polyMgr!.delete(_routeAnnot!); } catch (_) {}
                              _routeAnnot = null;
                            }
                            await _animateGoldRoute(
                              points: _routePoints,
                              duration: const Duration(milliseconds: 600),
                            );
                          }
                          if (!mounted) return;
                          setState(() => _tripStarted = true);
                          _openNativeMaps(widget.pickupLatLng);
                        });
                      }
                    },
                    onHorizontalDragEnd: (_) {
                      if (!_slid) setState(() => _slideVal = 0);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: thumbW - 4,
                      decoration: BoxDecoration(
                        color: _slid ? _gold.withValues(alpha: 0.8) : _gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Icon(
                        _slid ? Icons.check_rounded : Icons.chevron_right_rounded,
                        color: Colors.black,
                        size: 28,
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

  // ── Continue / Directions buttons (shown after slide) ───────────────────
  Widget _buildContinueDirections() {
    return Column(
      key: const ValueKey('continue_directions_pickup'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Continue button — gold filled
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: () => _goNavigate(overview: false),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              elevation: 0,
            ),
            child: const Text('Continue',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 12),
        // Directions button — outlined
        SizedBox(
          width: double.infinity,
          height: 56,
          child: OutlinedButton(
            onPressed: () => _goNavigate(overview: true),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              foregroundColor: Colors.white,
            ),
            child: const Text('Directions',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }

  // ── Slide-to-confirm "Arrived" (at pickup) ──────────────────────────────
  Widget _buildSlideArrived() {
    const height = 62.0;
    const thumbW = 62.0;
    return Container(
      key: const ValueKey('slide_arrived'),
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final trackW = constraints.maxWidth;
          final maxDrag = trackW - thumbW - 4;
          return SizedBox(
            height: height,
            child: Stack(
              children: [
                // Fill
                Positioned(
                  left: 0, top: 0, bottom: 0,
                  width: (_arrivedSlideVal * maxDrag + thumbW).clamp(thumbW.toDouble(), trackW),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.45),
                          _gold.withValues(alpha: 0.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                ),
                // Label
                Center(
                  child: AnimatedOpacity(
                    opacity: 1.0 - _arrivedSlideVal,
                    duration: const Duration(milliseconds: 100),
                    child: const Text('Arrived  →',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
                // Thumb
                Positioned(
                  left: 2 + _arrivedSlideVal * maxDrag,
                  top: 3, bottom: 3,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) {
                      if (_arrivedSlidDone) return;
                      setState(() {
                        _arrivedSlideVal = (_arrivedSlideVal + d.delta.dx / maxDrag)
                            .clamp(0.0, 1.0);
                      });
                      if (_arrivedSlideVal >= 0.88) {
                        setState(() => _arrivedSlidDone = true);
                        HapticFeedback.heavyImpact();
                        _confirmArrival();
                      }
                    },
                    onHorizontalDragEnd: (_) {
                      if (!_arrivedSlidDone) setState(() => _arrivedSlideVal = 0);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: thumbW - 4,
                      decoration: BoxDecoration(
                        color: _arrivedSlidDone ? _gold.withValues(alpha: 0.8) : _gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Icon(
                        _arrivedSlidDone ? Icons.check_rounded : Icons.chevron_right_rounded,
                        color: Colors.black,
                        size: 28,
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

  // ── Slide-to-confirm "Start Trip" #2 (pickup confirmed → go to dropoff) ─
  Widget _buildSlideStartRide() {
    const height = 62.0;
    const thumbW = 62.0;
    return Container(
      key: const ValueKey('slide_start_ride'),
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final trackW = constraints.maxWidth;
          final maxDrag = trackW - thumbW - 4;
          return SizedBox(
            height: height,
            child: Stack(
              children: [
                // Fill
                Positioned(
                  left: 0, top: 0, bottom: 0,
                  width: (_startRideSlideVal * maxDrag + thumbW).clamp(thumbW.toDouble(), trackW),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.45),
                          _gold.withValues(alpha: 0.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                ),
                // Label
                Center(
                  child: AnimatedOpacity(
                    opacity: 1.0 - _startRideSlideVal,
                    duration: const Duration(milliseconds: 100),
                    child: const Text('Start Trip  →',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
                // Thumb
                Positioned(
                  left: 2 + _startRideSlideVal * maxDrag,
                  top: 3, bottom: 3,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) {
                      if (_startRideSlidDone) return;
                      setState(() {
                        _startRideSlideVal = (_startRideSlideVal + d.delta.dx / maxDrag)
                            .clamp(0.0, 1.0);
                      });
                      if (_startRideSlideVal >= 0.88) {
                        setState(() => _startRideSlidDone = true);
                        HapticFeedback.heavyImpact();
                        // Update status + gloss animate dropoff route + navigate
                        Future.delayed(const Duration(milliseconds: 300), () async {
                          if (!mounted) return;
                          setState(() => _rideStarted = true);
                          _startDropoffProximityDetection();
                          _updateTripInTrip();
                          // Fetch and animate driver→dropoff route with gloss
                          try {
                            // Remove existing pickup route
                            if (_routeAnnot != null && _polyMgr != null) {
                              try { await _polyMgr!.delete(_routeAnnot!); } catch (_) {}
                              _routeAnnot = null;
                            }
                            final driverPos = await Geolocator.getCurrentPosition(
                              locationSettings: const LocationSettings(accuracy: LocationAccuracy.high),
                            ).timeout(const Duration(seconds: 5));
                            final origin = LatLng(driverPos.latitude, driverPos.longitude);
                            final dropoffRoute = await _fetchRoutePoints(origin, widget.dropoffLatLng);
                            if (mounted && dropoffRoute.length >= 2) {
                              _routePoints = dropoffRoute;
                              await _animateGoldRoute(
                                points: dropoffRoute,
                                duration: const Duration(milliseconds: 800),
                              );
                            }
                          } catch (_) {}
                          if (mounted) _openNativeMaps(widget.dropoffLatLng);
                        });
                      }
                    },
                    onHorizontalDragEnd: (_) {
                      if (!_startRideSlidDone) setState(() => _startRideSlideVal = 0);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: thumbW - 4,
                      decoration: BoxDecoration(
                        color: _startRideSlidDone ? _gold.withValues(alpha: 0.8) : _gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Icon(
                        _startRideSlidDone ? Icons.check_rounded : Icons.chevron_right_rounded,
                        color: Colors.black,
                        size: 28,
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

  // ── Slide-to-confirm "Finalizar Viaje" (near dropoff) ───────────────────
  Widget _buildSlideFinishTrip() {
    const height = 62.0;
    const thumbW = 62.0;
    return Container(
      key: const ValueKey('slide_finish_trip'),
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final trackW = constraints.maxWidth;
          final maxDrag = trackW - thumbW - 4;
          return SizedBox(
            height: height,
            child: Stack(
              children: [
                // Fill
                Positioned(
                  left: 0, top: 0, bottom: 0,
                  width: (_finishSlideVal * maxDrag + thumbW).clamp(thumbW.toDouble(), trackW),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.45),
                          _gold.withValues(alpha: 0.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                ),
                // Label
                Center(
                  child: AnimatedOpacity(
                    opacity: 1.0 - _finishSlideVal,
                    duration: const Duration(milliseconds: 100),
                    child: const Text('Finalizar Viaje  →',
                      style: TextStyle(
                        color: Colors.white70,
                        fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
                // Thumb
                Positioned(
                  left: 2 + _finishSlideVal * maxDrag,
                  top: 3, bottom: 3,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) {
                      if (_finishSlidDone) return;
                      setState(() {
                        _finishSlideVal = (_finishSlideVal + d.delta.dx / maxDrag)
                            .clamp(0.0, 1.0);
                      });
                      if (_finishSlideVal >= 0.88) {
                        setState(() => _finishSlidDone = true);
                        _finishTrip();
                      }
                    },
                    onHorizontalDragEnd: (_) {
                      if (!_finishSlidDone) setState(() => _finishSlideVal = 0);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: thumbW - 4,
                      decoration: BoxDecoration(
                        color: _finishSlidDone ? _gold.withValues(alpha: 0.8) : _gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Icon(
                        _finishSlidDone ? Icons.check_rounded : Icons.chevron_right_rounded,
                        color: Colors.black,
                        size: 28,
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

  // ── Continue / Directions for DROPOFF (after ride started) ──────────────
  Widget _buildContinueDirectionsDropoff() {
    return Column(
      key: const ValueKey('continue_directions_dropoff'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: () => _goNavigateDropoff(overview: false),
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              elevation: 0,
            ),
            child: const Text('Continue',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: OutlinedButton(
            onPressed: () => _goNavigateDropoff(overview: true),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              foregroundColor: Colors.white,
            ),
            child: const Text('Directions',
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }
}

// ─── Bottom-sheet item data class ─────────────────────────────────────────────
class _SheetItem {
  final IconData   icon;
  final String     label;
  final String     sub;
  final VoidCallback onTap;
  const _SheetItem(this.icon, this.label, this.sub, this.onTap);
}
