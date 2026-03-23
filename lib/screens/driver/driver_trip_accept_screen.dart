import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:url_launcher/url_launcher.dart';

import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
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
  late final AnimationController _pulseCtrl;
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _annotMgr;
  mapbox.PolylineAnnotationManager? _polyMgr;
  mapbox.ScreenCoordinate? _pickupPx;

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
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
    _pulseCtrl.dispose();
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
    if (widget.riderPhotoUrl.isNotEmpty) {
      return ClipOval(
        child: Image.network(
          widget.riderPhotoUrl,
          width: 66, height: 66, fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _initialsCircle(init),
        ),
      );
    }
    return _initialsCircle(init);
  }

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
    String address,
  ) => Container(
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
      ],
    ),
  );

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
  /// Fetch a real road route from OSRM. Returns decoded [LatLng] list or null.
  Future<List<mapbox.Position>?> _fetchOsrmRoute() async {
    final o = widget.pickupLatLng;
    final d = widget.dropoffLatLng;
    try {
      final path = '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
      final uri  = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'geometries': 'polyline',
      });
      final res  = await http.get(uri).timeout(const Duration(seconds: 8));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          return _decodePoly(routes[0]['geometry'] as String);
        }
      }
    } catch (_) {}
    return null;
  }

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

    // Fetch real road route from OSRM; fall back to straight line only if network fails
    final osrm = await _fetchOsrmRoute();
    final coords = osrm ?? [
      mapbox.Position(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude),
      mapbox.Position(widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude),
    ];
    await _polyMgr!.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: coords),
      lineColor: _gold.toARGB32(),
      lineWidth: 5.0,
      lineJoin: mapbox.LineJoin.ROUND,
    ));

    // Pickup pin (white ring + gold inner)
    final pickupBytes = await _buildPickupPin();
    if (pickupBytes != null) {
      await _annotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(
          widget.pickupLatLng.longitude, widget.pickupLatLng.latitude,
        )),
        image: pickupBytes,
        iconSize: 1.0,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
    }

    // Dropoff pin (white ring + dark inner + white dot)
    final dropoffBytes = await _buildDropoffPin();
    if (dropoffBytes != null) {
      await _annotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(
          widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude,
        )),
        image: dropoffBytes,
        iconSize: 1.0,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
    }

    // Fit camera to show both pins
    final points = [
      mapbox.Point(coordinates: mapbox.Position(
          widget.pickupLatLng.longitude, widget.pickupLatLng.latitude)),
      mapbox.Point(coordinates: mapbox.Position(
          widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude)),
    ];
    final cam = await ctrl.cameraForCoordinatesPadding(
      points,
      mapbox.CameraOptions(),
      mapbox.MbxEdgeInsets(top: 36, left: 36, bottom: 36, right: 36),
      null, null,
    );
    ctrl.flyTo(cam, mapbox.MapAnimationOptions(duration: 600));

    // Get pickup pixel position for pulsing overlay
    await Future.delayed(const Duration(milliseconds: 750));
    if (!mounted) return;
    try {
      final px = await ctrl.pixelForCoordinate(
        mapbox.Point(coordinates: mapbox.Position(
          widget.pickupLatLng.longitude, widget.pickupLatLng.latitude,
        )),
      );
      if (mounted) setState(() => _pickupPx = px);
    } catch (_) {}
  }

  // ── Pin builders (matching rider app gold theme) ──────────────────────────
  Future<Uint8List?> _buildPickupPin() async => _buildGoldPin(isPickup: true);
  Future<Uint8List?> _buildDropoffPin() async => _buildGoldPin(isPickup: false);

  Future<Uint8List?> _buildGoldPin({required bool isPickup}) async {
    const double w = 100;
    const double h = 130;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
    const cx = w / 2;
    const r = 30.0;
    const headCY = r + 8;
    const tipY = h;
    const gold = Color(0xFFE8C547);

    // ── Teardrop path (tip at exact bottom of canvas) ──
    final path = Path()
      ..moveTo(cx - r, headCY)
      ..arcTo(
        Rect.fromCircle(center: const Offset(cx, headCY), radius: r),
        math.pi, -math.pi, false,
      )
      ..cubicTo(cx + r, headCY + r, cx + r * 0.22, tipY - 4, cx, tipY)
      ..cubicTo(cx - r * 0.22, tipY - 4, cx - r, headCY + r, cx - r, headCY)
      ..close();

    // Shadow
    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // Gold fill
    canvas.drawPath(path, Paint()..color = gold);
    // White border
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.35),
    );
    // Highlight
    canvas.drawCircle(
      Offset(cx - r * 0.25, headCY - r * 0.25),
      r * 0.4,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // White center icon
    final iconPaint = Paint()..color = Colors.white..isAntiAlias = true;
    if (isPickup) {
      canvas.drawCircle(const Offset(cx, headCY), r * 0.22, iconPaint);
    } else {
      final flagPath = Path()
        ..moveTo(cx - r * 0.2, headCY - r * 0.35)
        ..lineTo(cx + r * 0.35, headCY - r * 0.2)
        ..lineTo(cx - r * 0.08, headCY - r * 0.05)
        ..lineTo(cx - r * 0.08, headCY + r * 0.35)
        ..lineTo(cx - r * 0.2, headCY + r * 0.35)
        ..close();
      canvas.drawPath(flagPath, iconPaint);
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(w.toInt(), h.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
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
                      _actionBtn(Icons.message_rounded, 'Message', () {}),
                    ],
                  ),
                ],
              ),
            ),

            // ── Map preview ───────────────────────────────────────────────
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
                      // Pulsing ring overlay at pickup pixel position
                      if (_pickupPx != null)
                        AnimatedBuilder(
                          animation: _pulseCtrl,
                          builder: (_, __) => Positioned(
                            left: _pickupPx!.x - 44,
                            top:  _pickupPx!.y - 44,
                            child: IgnorePointer(
                              child: SizedBox(
                                width: 88, height: 88,
                                child: CustomPaint(
                                  painter: _PulsePainter(_pulseCtrl.value),
                                ),
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

            // ── Pickup address card ───────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: _infoRow(
                Icons.location_on_rounded,
                Colors.white.withValues(alpha: 0.12),
                Colors.white,
                'Pickup',
                widget.pickupAddress,
              ),
            ),

            // ── Dropoff address card ──────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: _infoRow(
                Icons.flag_rounded,
                Colors.white.withValues(alpha: 0.12),
                Colors.white,
                'Dropoff',
                widget.dropoffAddress,
              ),
            ),

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

// ─── Pulsing gold ring painter ────────────────────────────────────────────────
class _PulsePainter extends CustomPainter {
  final double t;
  const _PulsePainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    const color = Color(0xFFD4A843);
    final center = Offset(size.width / 2, size.height / 2);
    for (int i = 0; i < 3; i++) {
      final phase  = (t + i / 3) % 1.0;
      final radius = 22.0 + phase * 22.0;
      final opacity = (1.0 - phase) * 0.45;
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..color = color.withValues(alpha: opacity)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.0,
      );
    }
  }

  @override
  bool shouldRepaint(_PulsePainter old) => old.t != t;
}

// ─── Bottom-sheet item data class ─────────────────────────────────────────────
class _SheetItem {
  final IconData   icon;
  final String     label;
  final String     sub;
  final VoidCallback onTap;
  const _SheetItem(this.icon, this.label, this.sub, this.onTap);
}
