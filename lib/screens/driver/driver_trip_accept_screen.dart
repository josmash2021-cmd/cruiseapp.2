import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
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
import 'driver_nav_screen.dart';
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

  // ── State ─────────────────────────────────────────────────────────────────
  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;
  late final AnimationController _slideCtrl;
  late final Animation<Offset>   _slideAnim;
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _annotMgr;
  mapbox.PolylineAnnotationManager? _polyMgr;

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
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);

    // Slide-up animation: 400ms from bottom
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..forward();
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.08),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));

    // Tilt: start at 55° for instant 3D view (no flat start)
    _tiltCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _tiltAnim = Tween<double>(begin: 55.0, end: 55.0).animate(
      CurvedAnimation(parent: _tiltCtrl, curve: Curves.easeInOutCubic),
    );

    // Pin pop: 0 → 1.15 → 0.95 → 1.0 (spring overshoot)
    _pinPopCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _pinPopAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.01, end: 1.15), weight: 60),
      TweenSequenceItem(tween: Tween(begin: 1.15, end: 0.95), weight: 20),
      TweenSequenceItem(tween: Tween(begin: 0.95, end: 1.0), weight: 20),
    ]).animate(CurvedAnimation(parent: _pinPopCtrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _slideCtrl.dispose();
    _tiltCtrl.dispose();
    _pinPopCtrl.dispose();
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

  // ── Navigation ────────────────────────────────────────────────────────────
  void _goNavigate({bool overview = false}) {
    HapticFeedback.mediumImpact();
    Navigator.of(context).pushReplacement(
      slideUpFadeRoute(
        DriverNavScreen(
          tripId:          widget.tripId,
          riderName:       widget.riderName,
          riderPhotoUrl:   widget.riderPhotoUrl,
          riderRating:     widget.riderRating,
          pickupLatLng:    widget.pickupLatLng,
          dropoffLatLng:   widget.dropoffLatLng,
          pickupAddress:   _pickupAddr,
          dropoffAddress:  _dropoffAddr,
          fare:            widget.fare,
          vehicleType:     widget.vehicleType,
          driverPos:       widget.driverPos,
          routePoints:     widget.routePoints,
          riderPhone:      widget.riderPhone,
          startWithOverview: overview,
        ),
      ),
    );
  }

  // ── Phone / Message ───────────────────────────────────────────────────────
  Future<void> _call() async {
    String phone = widget.riderPhone.trim();
    if (phone.isEmpty) {
      try {
        final snap = await FirebaseFirestore.instance
            .collection('trips')
            .doc(widget.tripId.toString())
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
      OutlinedButton(
        onPressed: onTap,
        style: OutlinedButton.styleFrom(
          side: const BorderSide(color: Color(0xFFFFD700), width: 1.5),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          foregroundColor: Colors.white,
          backgroundColor: Colors.transparent,
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: const Color(0xFFFFD700), size: 16),
            const SizedBox(width: 6),
            Text(label,
              style: const TextStyle(color: Colors.white, fontSize: 13,
                  fontWeight: FontWeight.w600)),
          ],
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
          .doc(widget.tripId.toString())
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
      return widget.routePoints!;
    }
    // Fallback — fetch fresh pickup→dropoff only
    return _fetchRoutePoints(widget.pickupLatLng, widget.dropoffLatLng);
  }

  Future<void> _onMapReady(mapbox.MapboxMap ctrl) async {
    _map = ctrl;
    await MapTheme.applyNavyGold(ctrl);
    _polyMgr  = await ctrl.annotations.createPolylineAnnotationManager();
    _annotMgr = await ctrl.annotations.createPointAnnotationManager();
    try { await ctrl.style.setStyleLayerProperty(_annotMgr!.id, 'icon-pitch-alignment', 'viewport'); } catch (_) {}

    // 1. Load route (cache-first — prevents straight-line bug)
    _routePoints = await _loadRoute();
    if (!mounted) return;

    // 2. Build unified gold teardrop pins in parallel (don't place yet)
    final pinResults = await Future.wait([
      renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32),  // pickup
      renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 32),  // dropoff
    ]);
    if (!mounted) return;

    if (_routePoints.length < 2) return;
    final routeCoordinates = _routePoints
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();

    // Build bounds from every route coordinate so the whole line is visible.
    final minLat = routeCoordinates.map((c) => c.lat.toDouble()).reduce(math.min);
    final maxLat = routeCoordinates.map((c) => c.lat.toDouble()).reduce(math.max);
    final minLng = routeCoordinates.map((c) => c.lng.toDouble()).reduce(math.min);
    final maxLng = routeCoordinates.map((c) => c.lng.toDouble()).reduce(math.max);
    final bounds = mapbox.CoordinateBounds(
      southwest: mapbox.Point(coordinates: mapbox.Position(minLng - 0.003, minLat - 0.003)),
      northeast: mapbox.Point(coordinates: mapbox.Position(maxLng + 0.003, maxLat + 0.003)),
      infiniteBounds: false,
    );
    final cam = await ctrl.cameraForCoordinateBounds(
      bounds,
      mapbox.MbxEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
      null,
      null,
      null,
      null,
    );
    ctrl.setCamera(mapbox.CameraOptions(
      center: cam.center,
      zoom: (cam.zoom ?? 13) - 0.5,
      bearing: 15.0,
      pitch: 0,
    ));

    // 4. Pins must use exact line endpoints (not geocoded address coords).
    final pickupPoint = routeCoordinates.first;
    final dropoffPoint = routeCoordinates.last;

    // 5. Pop pins in
    if (!mounted) return;

    _pinAnnots.clear();
    if (_annotMgr != null) {
      // Pickup pin — unified gold pin
      final pickupAnnot = await _annotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: pickupPoint),
        image: pinResults[0], iconSize: 0.01, iconAnchor: mapbox.IconAnchor.BOTTOM,
      ));
      _pinAnnots.add(pickupAnnot);
      // Dropoff pin — unified gold pin
      final dropoffAnnot = await _annotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: dropoffPoint),
        image: pinResults[1], iconSize: 0.01, iconAnchor: mapbox.IconAnchor.BOTTOM,
      ));
      _pinAnnots.add(dropoffAnnot);
    }
    // Animate pin pop: 0.01 → 1.15 → 0.95 → 1.0
    _pinPopAnim.addListener(_updatePinScale);
    _pinPopCtrl.forward(from: 0);
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;

    // 6. Draw single gold gloss route animated (~1s regardless of route length)
    await _animateGoldRoute(
      points: _routePoints,
      duration: const Duration(milliseconds: 1000),
    );
    if (!mounted) return;
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
          if (pts.isNotEmpty) { pts[0] = o; pts[pts.length - 1] = d; }
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
            if (pts.isNotEmpty) { pts[0] = o; pts[pts.length - 1] = d; }
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
      body: SlideTransition(
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
                            MaterialPageRoute(builder: (_) => const DriverHomeScreen()),
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
                            zoom: 13.5,
                            pitch: 55.0,
                          ),
                          onMapCreated: _onMapReady,
                          onStyleLoadedListener: (_) async {
                            if (_map != null) await MapTheme.applyNavyGold(_map!);
                          },
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

            // ── Action buttons ────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), bot + 18),
              child: Column(
                children: [
                  // Continue (gold)
                  SizedBox(
                    width: double.infinity,
                    height: Responsive.h(52),
                    child: ElevatedButton(
                      onPressed: () => _goNavigate(overview: false),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text('Continue',
                        style: TextStyle(
                          fontSize: Responsive.sp(17), fontWeight: FontWeight.w800,
                          color: Colors.black)),
                    ),
                  ),
                  SizedBox(height: Responsive.h(10)),
                  // Directions (outline)
                  SizedBox(
                    width: double.infinity,
                    height: Responsive.h(52),
                    child: OutlinedButton(
                      onPressed: () => _goNavigate(overview: true),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.22)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: Text('Directions',
                        style: TextStyle(
                          fontSize: Responsive.sp(17), fontWeight: FontWeight.w600,
                          color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      ),
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
