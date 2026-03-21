import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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
    with SingleTickerProviderStateMixin {
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

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
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

  Widget _infoRow(IconData icon, String topText, String subText) => Container(
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
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white54, size: 20),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(topText,
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w600),
                maxLines: 1, overflow: TextOverflow.ellipsis),
              if (subText.isNotEmpty) ...[
                const SizedBox(height: 2),
                Text(subText,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 12),
                  maxLines: 1, overflow: TextOverflow.ellipsis),
              ],
            ],
          ),
        ),
      ],
    ),
  );

  // ── Map ───────────────────────────────────────────────────────────────────
  Future<void> _onMapReady(mapbox.MapboxMap ctrl) async {
    _map = ctrl;
    await MapTheme.applyNavyGold(ctrl);
    _annotMgr = await ctrl.annotations.createPointAnnotationManager();

    // Build a house-pin icon from canvas
    final iconBytes = await _buildPickupPin();
    if (iconBytes != null && _annotMgr != null && mounted) {
      await _annotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(
          widget.pickupLatLng.longitude, widget.pickupLatLng.latitude,
        )),
        image: iconBytes,
        iconSize: 1.0,
      ));
    }
  }

  Future<Uint8List?> _buildPickupPin() async {
    const double s = 80;
    final rec = ui.PictureRecorder();
    final c   = Canvas(rec, const Rect.fromLTWH(0, 0, s, s));

    // Shadow
    c.drawCircle(const Offset(s / 2, s / 2 + 3), 20,
        Paint()
          ..color = Colors.black.withValues(alpha: 0.35)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8));
    // White circle
    c.drawCircle(const Offset(s / 2, s / 2), 20, Paint()..color = Colors.white);
    // Blue inner
    c.drawCircle(const Offset(s / 2, s / 2), 13,
        Paint()..color = const Color(0xFF4285F4));

    final img   = await rec.endRecording().toImage(s.toInt(), s.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    return bytes?.buffer.asUint8List();
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final top    = MediaQuery.of(context).padding.top;
    final bot    = MediaQuery.of(context).padding.bottom;
    final distMi = (widget.distToPickupKm * 0.621371).toStringAsFixed(1);

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
                      Icon(Icons.shield_rounded,
                          color: Colors.white.withValues(alpha: 0.4), size: 21),
                      const SizedBox(width: 14),
                      Icon(Icons.help_outline_rounded,
                          color: Colors.white.withValues(alpha: 0.4), size: 21),
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
                  height: 170,
                  child: Stack(
                    children: [
                      mapbox.MapWidget(
                        styleUri: MapboxConfig.styleDark,
                        cameraOptions: mapbox.CameraOptions(
                          center: mapbox.Point(coordinates: mapbox.Position(
                            widget.pickupLatLng.longitude,
                            widget.pickupLatLng.latitude,
                          )),
                          zoom: 14.5,
                          pitch: 0,
                        ),
                        onMapCreated: _onMapReady,
                      ),
                      // Mapbox logo overlay
                      Positioned(
                        bottom: 6, left: 10,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(5),
                          child: BackdropFilter(
                            filter: ui.ImageFilter.blur(sigmaX: 4, sigmaY: 4),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 7, vertical: 3),
                              color: Colors.black.withValues(alpha: 0.5),
                              child: const Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.map_rounded,
                                      color: Colors.white54, size: 10),
                                  SizedBox(width: 3),
                                  Text('mapbox',
                                    style: TextStyle(
                                        color: Colors.white54, fontSize: 9)),
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
            ),

            // ── Address card ──────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: _infoRow(
                Icons.home_rounded,
                widget.pickupAddress,
                widget.dropoffAddress,
              ),
            ),

            // ── Vehicle + fare ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
              child: Container(
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
                        color: _gold.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: const Icon(Icons.directions_car_rounded,
                          color: _gold, size: 20),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(widget.vehicleType,
                            style: const TextStyle(color: Colors.white,
                                fontSize: 14, fontWeight: FontWeight.w600)),
                          const SizedBox(height: 2),
                          Text('$distMi mi · ${widget.etaMinutes} min away',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.42),
                              fontSize: 12)),
                        ],
                      ),
                    ),
                    Text('\$${widget.fare.toStringAsFixed(2)}',
                      style: const TextStyle(
                        color: _gold, fontSize: 19,
                        fontWeight: FontWeight.w800)),
                  ],
                ),
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
