import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:url_launcher/url_launcher.dart';

import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../chat_screen.dart';
import 'driver_nav_screen.dart';

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
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _annotMgr;
  mapbox.PolylineAnnotationManager? _polyMgr;

  // ── Tilt animation ──
  late final AnimationController _tiltCtrl;
  late final Animation<double>   _tiltAnim;

  // ── Smooth route draw ──
  Ticker? _routeDrawTicker;
  mapbox.PolylineAnnotation? _segOneAnnot;
  mapbox.PolylineAnnotation? _segOneGlow;
  mapbox.PolylineAnnotation? _segTwoAnnot;
  mapbox.PolylineAnnotation? _segTwoGlow;
  mapbox.PolylineAnnotation? _fullRouteGlow;
  AnimationController? _glowPulseCtrl;
  List<LatLng> _fullSegOne = [];
  List<LatLng> _fullSegTwo = [];

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
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);

    // Tilt: flat (0°) → perspective (45°) over 1200ms
    _tiltCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    _tiltAnim = Tween<double>(begin: 0.0, end: 45.0).animate(
      CurvedAnimation(parent: _tiltCtrl, curve: Curves.easeInOutCubic),
    );
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _tiltCtrl.dispose();
    _glowPulseCtrl?.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    super.dispose();
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
          pickupAddress:   widget.pickupAddress,
          dropoffAddress:  widget.dropoffAddress,
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
    final phone = widget.riderPhone.trim();
    if (phone.isEmpty) return;
    final uri = Uri.parse('tel:$phone');
    if (await canLaunchUrl(uri)) await launchUrl(uri);
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
    final init = widget.riderName.isNotEmpty ? widget.riderName[0].toUpperCase() : '?';
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Photo (or fallback initial)
        Container(
          width: 66, height: 66,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: _gold, width: 2),
            boxShadow: [
              BoxShadow(
                color: _gold.withValues(alpha: 0.30),
                blurRadius: 12, spreadRadius: 1,
              ),
            ],
          ),
          child: ClipOval(
            child: widget.riderPhotoUrl.isNotEmpty
              ? CachedNetworkImage(
                  imageUrl: widget.riderPhotoUrl,
                  width: 62, height: 62, fit: BoxFit.cover,
                  fadeInDuration: const Duration(milliseconds: 200),
                  placeholder: (_, __) => _initialsFill(init),
                  errorWidget: (_, __, ___) => _initialsFill(init),
                )
              : _initialsFill(init),
          ),
        ),
        // Gold "Verified" badge at bottom
        Positioned(
          bottom: -4, left: 0, right: 0,
          child: Center(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(8),
                boxShadow: [BoxShadow(
                  color: Colors.black.withValues(alpha: 0.40),
                  blurRadius: 4,
                )],
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.verified, size: 10, color: Colors.black),
                  SizedBox(width: 2),
                  Text('Verified',
                    style: TextStyle(fontSize: 9, fontWeight: FontWeight.w700,
                      color: Colors.black)),
                ],
              ),
            ),
          ),
        ),
      ],
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
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 9),
          decoration: BoxDecoration(
            border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: Colors.white, size: 16),
              const SizedBox(width: 6),
              Text(label,
                style: const TextStyle(color: Colors.white, fontSize: 13,
                    fontWeight: FontWeight.w600)),
            ],
          ),
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
      )),
    );
  }

  // ── Navigation app integration ───────────────────────────────────────────
  void _showNavigationSheet({required bool isPickup}) {
    final coords = isPickup ? widget.pickupLatLng : widget.dropoffLatLng;
    final address = isPickup ? widget.pickupAddress : widget.dropoffAddress;
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
            () => Navigator.pop(context)),
        _SheetItem(Icons.flag_rounded, 'Problem with dropoff address',
            'The dropoff location is incorrect or unclear',
            () => Navigator.pop(context)),
        _SheetItem(Icons.directions_car_rounded, 'Problem with trip',
            'Other issue with this trip',
            () => Navigator.pop(context)),
        _SheetItem(Icons.support_agent_rounded, 'Contact Support',
            'Speak with a support agent',
            () => Navigator.pop(context)),
      ],
    );
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

  Future<void> _onMapReady(mapbox.MapboxMap ctrl) async {
    _map = ctrl;
    await MapTheme.applyNavyGold(ctrl);
    _polyMgr  = await ctrl.annotations.createPolylineAnnotationManager();
    _annotMgr = await ctrl.annotations.createPointAnnotationManager();

    // 1. Fetch both route segments in parallel
    final segFutures = await Future.wait([
      _fetchRoutePoints(widget.driverPos, widget.pickupLatLng),
      _fetchRoutePoints(widget.pickupLatLng, widget.dropoffLatLng),
    ]);
    _fullSegOne = segFutures[0];
    _fullSegTwo = segFutures[1];
    if (!mounted) return;

    // 2. Fit camera to show all three points
    final allPts = [
      mapbox.Point(coordinates: mapbox.Position(widget.driverPos.longitude, widget.driverPos.latitude)),
      mapbox.Point(coordinates: mapbox.Position(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude)),
      mapbox.Point(coordinates: mapbox.Position(widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude)),
    ];
    final cam = await ctrl.cameraForCoordinatesPadding(
      allPts,
      mapbox.CameraOptions(),
      mapbox.MbxEdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
      null, null,
    );
    ctrl.flyTo(cam, mapbox.MapAnimationOptions(duration: 600));

    // 3. Build & place teardrop pins (matching CruiseMapPin)
    final pinResults = await Future.wait([
      _buildTeardropPin(const Color(0xFF5BA3F5)), // driver — blue tip
      _buildTeardropPin(_gold),                    // pickup — gold tip
      _buildTeardropPin(Colors.white),             // dropoff — white tip
    ]);
    if (_annotMgr != null && mounted) {
      if (pinResults[0] != null) {
        await _annotMgr!.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(
            widget.driverPos.longitude, widget.driverPos.latitude)),
          image: pinResults[0], iconSize: 1.0, iconAnchor: mapbox.IconAnchor.BOTTOM,
        ));
      }
      if (pinResults[1] != null) {
        await _annotMgr!.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(
            widget.pickupLatLng.longitude, widget.pickupLatLng.latitude)),
          image: pinResults[1], iconSize: 1.0, iconAnchor: mapbox.IconAnchor.BOTTOM,
        ));
      }
      if (pinResults[2] != null) {
        await _annotMgr!.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(
            widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude)),
          image: pinResults[2], iconSize: 1.0, iconAnchor: mapbox.IconAnchor.BOTTOM,
        ));
      }
    }

    // 4. Start tilt animation
    _tiltCtrl.forward(from: 0);
    _tiltAnim.addListener(_applyMapTilt);

    // 5. Animate segment 1 (driver→pickup, gold, 900ms)
    await _animateSegmentSmooth(
      points: _fullSegOne,
      color: _gold,
      duration: const Duration(milliseconds: 900),
      onAnnotCreated: (main, glow) {
        _segOneAnnot = main;
        _segOneGlow = glow;
      },
    );
    if (!mounted) return;

    await Future.delayed(const Duration(milliseconds: 100));

    // 6. Animate segment 2 (pickup→dropoff, white, 700ms)
    await _animateSegmentSmooth(
      points: _fullSegTwo,
      color: Colors.white,
      duration: const Duration(milliseconds: 700),
      onAnnotCreated: (main, glow) {
        _segTwoAnnot = main;
        _segTwoGlow = glow;
      },
    );
    if (!mounted) return;

    // 7. Start glow pulse
    _startGlowPulse();
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
    // Straight line fallback
    return List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        o.latitude  + (d.latitude  - o.latitude)  * t,
        o.longitude + (d.longitude - o.longitude) * t,
      );
    });
  }

  /// Smooth 60fps progressive polyline draw using Ticker + easeInOutCubic
  Future<void> _animateSegmentSmooth({
    required List<LatLng> points,
    required Color color,
    required Duration duration,
    required void Function(mapbox.PolylineAnnotation?, mapbox.PolylineAnnotation?) onAnnotCreated,
  }) async {
    final polyMgr = _polyMgr;
    if (polyMgr == null || points.length < 2) return;

    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    final totalMs = duration.inMilliseconds;
    mapbox.PolylineAnnotation? mainAnnot;
    mapbox.PolylineAnnotation? glowAnnot;
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
      final eased = Curves.easeInOutCubic.transform(progress);
      final count = (eased * points.length).round().clamp(2, points.length);

      if (count != lastCount) {
        lastCount = count;
        final subset = points.sublist(0, count);
        final coords = subset.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final geo = mapbox.LineString(coordinates: coords);
        if (mainAnnot == null) {
          glowAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
            geometry: geo,
            lineColor: color.withValues(alpha: 0.20).toARGB32(),
            lineWidth: 12.0,
            lineJoin: mapbox.LineJoin.ROUND,
          ));
          mainAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
            geometry: geo,
            lineColor: color.toARGB32(),
            lineWidth: 5.0,
            lineJoin: mapbox.LineJoin.ROUND,
          ));
        } else {
          mainAnnot!.geometry = geo;
          await polyMgr.update(mainAnnot!);
          if (glowAnnot != null) {
            glowAnnot!.geometry = geo;
            await polyMgr.update(glowAnnot!);
          }
        }
      }
      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final fullGeo = mapbox.LineString(coordinates: fullCoords);
        if (mainAnnot != null) { mainAnnot!.geometry = fullGeo; await polyMgr.update(mainAnnot!); }
        if (glowAnnot != null) { glowAnnot!.geometry = fullGeo; await polyMgr.update(glowAnnot!); }
        onAnnotCreated(mainAnnot, glowAnnot);
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  /// Gold glow pulse on full combined route after animation completes
  void _startGlowPulse() {
    _glowPulseCtrl?.dispose();
    final allPts = [..._fullSegOne, ..._fullSegTwo];
    if (allPts.length < 2 || _polyMgr == null) return;

    final coords = allPts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    final geo = mapbox.LineString(coordinates: coords);
    _polyMgr!.create(mapbox.PolylineAnnotationOptions(
      geometry: geo,
      lineColor: _gold.withValues(alpha: 0.10).toARGB32(),
      lineWidth: 16.0,
      lineJoin: mapbox.LineJoin.ROUND,
    )).then((a) => _fullRouteGlow = a);

    _glowPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _glowPulseCtrl!.addListener(() {
      final glow = _fullRouteGlow;
      if (glow == null || _polyMgr == null) return;
      final alpha = (0.06 + _glowPulseCtrl!.value * 0.20).clamp(0.0, 1.0);
      glow.lineColor = _gold.withValues(alpha: alpha).toARGB32();
      glow.lineWidth = 14.0 + _glowPulseCtrl!.value * 4.0;
      _polyMgr!.update(glow);
    });
  }

  // ── Pin builders (matching CruiseMapPin teardrop from rider map) ──────────
  Future<Uint8List?> _buildPickupPin() async => _buildTeardropPin(_gold);
  Future<Uint8List?> _buildDropoffPin() async => _buildTeardropPin(Colors.white);

  /// Teardrop pin: navy→tipColor gradient, person avatar, border — matches CruiseMapPin
  Future<Uint8List?> _buildTeardropPin(Color tipColor) async {
    const double w = 72;
    const double h = 88;
    const double r = w / 2;
    const double cx = w / 2;

    final rec = ui.PictureRecorder();
    final cv = Canvas(rec, const Rect.fromLTWH(0, 0, w, h));

    final path = Path()
      ..moveTo(cx, h)
      ..quadraticBezierTo(0, r + (h - r) * 0.35, 0, r)
      ..arcTo(const Rect.fromLTWH(0, 0, w, w), math.pi, -math.pi, false)
      ..quadraticBezierTo(w, r + (h - r) * 0.35, cx, h)
      ..close();

    cv.drawShadow(path, Colors.black, 6, false);

    cv.drawPath(path, Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [const Color(0xFF1A1F2E), tipColor],
        stops: const [0.0, 0.85],
      ).createShader(const Rect.fromLTWH(0, 0, w, h)));

    cv.drawPath(path, Paint()
      ..color = tipColor.withValues(alpha: 0.45)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5);

    // Person avatar
    const avatarR = 48.0 / 2;
    const avatarCy = 8.0 + avatarR;
    cv.drawCircle(const Offset(cx, avatarCy), avatarR, Paint()..color = const Color(0xFF1A1F2E));
    cv.drawCircle(const Offset(cx, avatarCy), avatarR, Paint()
      ..color = Colors.white.withValues(alpha: 0.24)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0);
    final iconPaint = Paint()..color = Colors.white..style = PaintingStyle.fill;
    cv.drawCircle(const Offset(cx, avatarCy - 5), 6, iconPaint);
    final bodyPath = Path()
      ..moveTo(cx - 8, avatarCy + 14)
      ..quadraticBezierTo(cx - 8, avatarCy + 2, cx, avatarCy + 2)
      ..quadraticBezierTo(cx + 8, avatarCy + 2, cx + 8, avatarCy + 14)
      ..close();
    cv.drawPath(bodyPath, iconPaint);

    final img = await rec.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
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
      body: FadeTransition(
        opacity: _fadeAnim,
        child: Column(
          children: [
            // ── Header ────────────────────────────────────────────────────
            Container(
              color: _bg,
              padding: EdgeInsets.fromLTRB(16, top + 10, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row: back / help icons
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          Navigator.pop(context);
                        },
                        child: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: const Icon(Icons.chevron_left_rounded,
                              color: Colors.white, size: 24),
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: _showSafetyMenu,
                        child: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.shield_rounded,
                              color: Colors.white.withValues(alpha: 0.75), size: 19),
                        ),
                      ),
                      const SizedBox(width: 10),
                      GestureDetector(
                        onTap: _showHelpMenu,
                        child: Container(
                          width: 36, height: 36,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.07),
                            borderRadius: BorderRadius.circular(10),
                          ),
                          child: Icon(Icons.help_outline_rounded,
                              color: Colors.white.withValues(alpha: 0.75), size: 19),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  // Title
                  Text('Ride for ${widget.riderName}',
                    style: const TextStyle(
                      color: Colors.white, fontSize: 24,
                      fontWeight: FontWeight.w800, height: 1.15)),
                  const SizedBox(height: 3),
                  Text(_timeLabel(),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.42),
                      fontSize: 13, fontWeight: FontWeight.w400)),
                  const SizedBox(height: 16),
                  // Rider row: avatar + info + call/msg
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _avatar(),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(widget.riderName,
                              style: const TextStyle(
                                color: Colors.white, fontSize: 15,
                                fontWeight: FontWeight.w700)),
                            const SizedBox(height: 4),
                            _stars(widget.riderRating),
                            const SizedBox(height: 3),
                            Text('${widget.riderRating.toStringAsFixed(1)} rating',
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.42),
                                fontSize: 11)),
                          ],
                        ),
                      ),
                      _actionBtn(Icons.phone_rounded, 'Call', _call),
                      const SizedBox(width: 8),
                      _actionBtn(Icons.message_rounded, 'Message', _openChat),
                    ],
                  ),
                ],
              ),
            ),

            // ── Map preview (tilt animation on enter) ─────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(16),
                child: SizedBox(
                  height: 190,
                  child: Stack(
                    children: [
                      mapbox.MapWidget(
                        styleUri: MapboxConfig.styleDark,
                        cameraOptions: mapbox.CameraOptions(
                          center: mapbox.Point(coordinates: mapbox.Position(
                            widget.pickupLatLng.longitude,
                            widget.pickupLatLng.latitude,
                          )),
                          zoom: 13.5,
                          pitch: 0,
                        ),
                        onMapCreated: _onMapReady,
                        onStyleLoadedListener: (_) async {
                          if (_map != null) await MapTheme.applyNavyGold(_map!);
                        },
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
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: GestureDetector(
                onTap: () => _showNavigationSheet(isPickup: true),
                child: _infoRow(
                  Icons.location_on_rounded,
                  _gold.withValues(alpha: 0.15),
                  _gold,
                  'Pickup',
                  widget.pickupAddress,
                  showChevron: true,
                ),
              ),
            ),
            if (widget.pickupInstructions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: _buildHangingInstruction(widget.pickupInstructions),
              ),
            const SizedBox(height: 8),

            // ── Dropoff address card + hanging instructions ───────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
              child: GestureDetector(
                onTap: () => _showNavigationSheet(isPickup: false),
                child: _infoRow(
                  Icons.flag_rounded,
                  _gold.withValues(alpha: 0.15),
                  _gold,
                  'Dropoff',
                  widget.dropoffAddress,
                  showChevron: true,
                ),
              ),
            ),
            if (widget.dropoffInstructions.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                child: _buildHangingInstruction(widget.dropoffInstructions),
              ),
            const SizedBox(height: 10),

            const Spacer(),

            // ── Action buttons ────────────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, bot + 18),
              child: Column(
                children: [
                  // Continue (gold)
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: () => _goNavigate(overview: false),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Continue',
                        style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w800,
                          color: Colors.black)),
                    ),
                  ),
                  const SizedBox(height: 10),
                  // Directions (outline)
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: OutlinedButton(
                      onPressed: () => _goNavigate(overview: true),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white,
                        side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.22)),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14)),
                      ),
                      child: const Text('Directions',
                        style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600,
                          color: Colors.white)),
                    ),
                  ),
                ],
              ),
            ),
          ],
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
