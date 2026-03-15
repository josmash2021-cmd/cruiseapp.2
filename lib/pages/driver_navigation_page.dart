import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/map_styles.dart';
import '../navigation/nav_state_machine.dart';
import '../navigation/route_snapper.dart';
import '../navigation/route_service.dart';
import '../navigation/smooth_motion.dart';
import '../services/api_service.dart';
import '../services/navigation_service.dart';
import '../l10n/app_localizations.dart';

class DriverNavigationPage extends StatefulWidget {
  const DriverNavigationPage({
    super.key,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    this.tripId = '',
    this.initialDriverPos,
    this.routePoints,
    this.riderName = 'Rider',
    this.riderPhotoUrl = '',
    this.riderRating = 0,
    this.pickupLabel = '',
    this.dropoffLabel = '',
    this.vehiclePlate = '',
    this.speedLimitMph = 35,
  });

  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String tripId;
  final LatLng? initialDriverPos;
  final List<LatLng>? routePoints;
  final String riderName;
  final String riderPhotoUrl;
  final double riderRating;
  final String pickupLabel;
  final String dropoffLabel;
  final String vehiclePlate;
  final int speedLimitMph;

  @override
  State<DriverNavigationPage> createState() => _DriverNavigationPageState();
}

class _DriverNavigationPageState extends State<DriverNavigationPage>
    with TickerProviderStateMixin {
  GoogleMapController? _map;
  bool _mapReady = false;
  late final NavStateMachine _sm;
  late final SmoothMotion _motion;
  final NavigationService _navService = NavigationService();

  LatLng _pos = const LatLng(0, 0);
  double _bearing = 0;
  int _snapIdx = 0;
  bool _cameraFollowing = true;
  Timer? _reFollowTimer;
  bool _hasResumedOnce = false;
  DateTime? _lastCameraUpdate;

  List<LatLng> _routePts = [];
  List<LatLng> _displayRoutePts = [];
  NavigationState? _navState;

  double _distRemainingMi = 0;
  int _etaMinutes = 0;

  StreamSubscription? _gpsSub;
  bool _muted = false;
  BitmapDescriptor? _arrowIcon;
  Uint8List? _arrowIconBytes;
  double _currentSpeedMph = 0;

  static const _navy = Color(0xFF0A2463);
  static const _green = Color(0xFF34A853);
  static const _red = Color(0xFFEF5350);
  static const _gold = Color(0xFFD4A24C);
  static const _cardBg = Color(0xFF1A1E2E);
  static const _cardBorder = Color(0xFF2A2F42);
  static const _textPrimary = Color(0xFFF0F0F5);
  static const _textSecondary = Color(0xFF8A8FA0);

  @override
  void initState() {
    super.initState();
    _pos = widget.initialDriverPos ?? widget.pickupLatLng;
    _sm = NavStateMachine(
      onPhaseChanged: (p) {
        if (mounted) setState(() {});
        _onPhaseChanged(p);
      },
    );
    _sm.startTrip(
      tripId: widget.tripId,
      pickup: widget.pickupLatLng,
      dropoff: widget.dropoffLatLng,
    );
    _motion = SmoothMotion(
      onTick: _onMotionTick,
      lerpFactor: 0.22,
      enablePrediction: true,
    );
    _motion.start(this);
    _motion.teleport(_pos, 0);
    _buildArrowIcon();
    _routePts =
        widget.routePoints ?? _makeStraightRoute(_pos, widget.pickupLatLng);
    _displayRoutePts = List.of(_routePts);
    _buildRouteOnInit();
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _reFollowTimer?.cancel();
    _motion.dispose();
    _sm.dispose();
    _map?.dispose();
    super.dispose();
  }

  Future<void> _buildRouteOnInit() async {
    if (widget.routePoints == null) {
      final dest = (_sm.phase == TripPhase.toPickup)
          ? widget.pickupLatLng
          : widget.dropoffLatLng;
      final route = await RouteService.fetchNavRoute(
        origin: _pos,
        destination: dest,
      );
      if (route != null && mounted) {
        _routePts = route.overviewPolyline;
        _displayRoutePts = List.of(_routePts);
        _navService.startNavigation(route);
      }
    }
    if (mounted) setState(() {});
    _startGPS();
  }

  void _startGPS() {
    _gpsSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 1,
          ),
        ).listen((pos) {
          if (!mounted) return;
          // speed is in m/s, convert to mph
          _currentSpeedMph = (pos.speed * 2.23694).clamp(0, 200);
          _onRawPosition(LatLng(pos.latitude, pos.longitude), pos.heading);
        });
  }

  void _onRawPosition(LatLng raw, double rawBearing) {
    final snap = RouteSnapper.snap(raw, _routePts, lastIndex: _snapIdx);
    _snapIdx = snap.segmentIndex;
    _motion.pushTarget(snap.snapped, snap.bearingDeg);
    if (_navService.isNavigating) {
      _navState = _navService.updatePosition(snap.snapped);
    }
    _sm.checkProximity(snap.snapped);
    _trimRouteBehind(snap.segmentIndex);
    final dest = _sm.phase == TripPhase.onTrip
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    final dM = _haversineM(snap.snapped, dest);
    setState(() {
      _distRemainingMi = dM / 1609.34;
      _etaMinutes =
          _navState?.etaMinutes ?? (dM / 500 / 60).ceil().clamp(1, 99);
    });
  }

  void _trimRouteBehind(int segIdx) {
    if (segIdx < 2 || segIdx >= _routePts.length) return;
    _displayRoutePts = _routePts.sublist(segIdx);
  }

  void _onMotionTick(LatLng pos, double bearing) {
    if (!mounted) return;
    _pos = pos;
    _bearing = bearing;
    setState(() {});

    // Throttle camera to ~20 Hz for fluid real-time tracking
    final now = DateTime.now();
    if (_cameraFollowing &&
        _map != null &&
        _mapReady &&
        (_lastCameraUpdate == null ||
            now.difference(_lastCameraUpdate!).inMilliseconds > 50)) {
      _lastCameraUpdate = now;
      _animateCameraNav(pos, zoom: 17, bearing: bearing, tilt: 60);
    }
  }

  void _onPhaseChanged(TripPhase phase) {
    if (phase == TripPhase.onTrip) {
      _hasResumedOnce = false;
      _cameraFollowing = true;
      _switchToDropoffRoute();
    }
  }

  Future<void> _switchToDropoffRoute() async {
    final route = await RouteService.fetchNavRoute(
      origin: _pos,
      destination: widget.dropoffLatLng,
    );
    if (route != null && mounted) {
      _routePts = route.overviewPolyline;
      _displayRoutePts = List.of(_routePts);
      _navService.startNavigation(route);
      _snapIdx = 0;
      setState(() {});
    } else if (mounted) {
      _routePts = _makeStraightRoute(_pos, widget.dropoffLatLng);
      _displayRoutePts = List.of(_routePts);
      _snapIdx = 0;
      setState(() {});
    }
  }

  // =========================================================================
  //  NAVIGATION ARROW ICON — painted on Canvas, rotated via Marker.rotation
  // =========================================================================

  Future<void> _buildArrowIcon() async {
    const double w = 100;
    const double h = 160;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

    const double cx = w / 2;
    const double cy = h / 2;
    const double bW = 32.0;  // half-width at widest
    const double bH = 54.0;  // half-height
    const double depth = 12.0;
    const body = Color(0xFF0A2463);
    const bodyHi = Color(0xFF1A3A8A);
    const win = Color(0xFF1C2040);
    const headlight = Color(0xFFFFE082);
    const taillight = Color(0xFFEF5350);

    // Car body silhouette path
    Path carPath(double ox, double oy, double w2, double h2) => Path()
      ..moveTo(ox, oy - h2 * 0.95)
      ..quadraticBezierTo(ox + w2 * 0.55, oy - h2 * 0.94, ox + w2 * 0.72, oy - h2 * 0.78)
      ..quadraticBezierTo(ox + w2 * 0.92, oy - h2 * 0.62, ox + w2 * 0.92, oy - h2 * 0.40)
      ..lineTo(ox + w2 * 0.88, oy + h2 * 0.30)
      ..quadraticBezierTo(ox + w2 * 0.86, oy + h2 * 0.68, ox + w2 * 0.68, oy + h2 * 0.85)
      ..quadraticBezierTo(ox + w2 * 0.40, oy + h2 * 0.95, ox, oy + h2 * 0.96)
      ..quadraticBezierTo(ox - w2 * 0.40, oy + h2 * 0.95, ox - w2 * 0.68, oy + h2 * 0.85)
      ..quadraticBezierTo(ox - w2 * 0.86, oy + h2 * 0.68, ox - w2 * 0.88, oy + h2 * 0.30)
      ..lineTo(ox - w2 * 0.92, oy - h2 * 0.40)
      ..quadraticBezierTo(ox - w2 * 0.92, oy - h2 * 0.62, ox - w2 * 0.72, oy - h2 * 0.78)
      ..quadraticBezierTo(ox - w2 * 0.55, oy - h2 * 0.94, ox, oy - h2 * 0.95)
      ..close();

    // Shadow
    canvas.drawPath(
      carPath(cx, cy + 4, bW + 5, bH + 4),
      Paint()..color = Colors.black.withValues(alpha: 0.30)..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    // 3D bottom face
    canvas.drawPath(
      carPath(cx, cy + depth * 0.4, bW, bH).shift(const Offset(0, 1)),
      Paint()..color = Color.lerp(body, Colors.black, 0.50)!,
    );
    // Left depth strip
    canvas.drawPath(
      Path()
        ..moveTo(cx - bW * 0.92, cy - bH * 0.50)
        ..lineTo(cx - bW * 0.92 - depth * 0.25, cy - bH * 0.40)
        ..lineTo(cx - bW * 0.92 - depth * 0.25, cy + bH * 0.70 + depth * 0.3)
        ..lineTo(cx - bW * 0.78, cy + bH * 0.82)
        ..close(),
      Paint()..color = Color.lerp(body, Colors.black, 0.38)!,
    );
    // Right depth strip
    canvas.drawPath(
      Path()
        ..moveTo(cx + bW * 0.92, cy - bH * 0.50)
        ..lineTo(cx + bW * 0.92 + depth * 0.25, cy - bH * 0.40)
        ..lineTo(cx + bW * 0.92 + depth * 0.25, cy + bH * 0.70 + depth * 0.3)
        ..lineTo(cx + bW * 0.78, cy + bH * 0.82)
        ..close(),
      Paint()..color = Color.lerp(body, Colors.black, 0.28)!,
    );

    // Wheels
    for (final wp in [
      Offset(cx - bW * 0.94, cy - bH * 0.48),
      Offset(cx + bW * 0.94, cy - bH * 0.48),
      Offset(cx - bW * 0.90, cy + bH * 0.50),
      Offset(cx + bW * 0.90, cy + bH * 0.50),
    ]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(Rect.fromCenter(center: wp, width: 8, height: 16), const Radius.circular(3)),
        Paint()..color = const Color(0xFF1A1A1A),
      );
    }

    // Body
    final bp = carPath(cx, cy, bW, bH);
    final bRect = bp.getBounds();
    canvas.drawPath(bp, Paint()..color = body);
    canvas.drawPath(bp, Paint()..shader = RadialGradient(
      center: const Alignment(-0.25, -0.4), radius: 0.9, colors: [bodyHi, body],
    ).createShader(bRect));
    canvas.drawPath(bp, Paint()..color = Color.lerp(body, Colors.black, 0.15)!..style = PaintingStyle.stroke..strokeWidth = 1.5..strokeJoin = StrokeJoin.round);

    // Hood creases
    for (final s in [-1.0, 1.0]) {
      canvas.drawLine(
        Offset(cx + s * bW * 0.28, cy - bH * 0.80),
        Offset(cx + s * bW * 0.22, cy - bH * 0.38),
        Paint()..color = Color.lerp(body, Colors.black, 0.08)!..strokeWidth = 0.8..strokeCap = StrokeCap.round,
      );
    }

    // Windshield
    canvas.drawPath(
      Path()
        ..moveTo(cx - bW * 0.56, cy - bH * 0.36)
        ..lineTo(cx - bW * 0.48, cy - bH * 0.12)
        ..lineTo(cx + bW * 0.48, cy - bH * 0.12)
        ..lineTo(cx + bW * 0.56, cy - bH * 0.36)
        ..close(),
      Paint()..color = win,
    );
    // Roof panel
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy + bH * 0.04), width: bW * 0.90, height: bH * 0.20),
        const Radius.circular(3),
      ),
      Paint()..color = Color.lerp(body, bodyHi, 0.3)!,
    );
    // Rear window
    canvas.drawPath(
      Path()
        ..moveTo(cx - bW * 0.46, cy + bH * 0.18)
        ..lineTo(cx - bW * 0.40, cy + bH * 0.38)
        ..lineTo(cx + bW * 0.40, cy + bH * 0.38)
        ..lineTo(cx + bW * 0.46, cy + bH * 0.18)
        ..close(),
      Paint()..color = win,
    );
    // Side windows
    for (final s in [-1.0, 1.0]) {
      canvas.drawPath(
        Path()
          ..moveTo(cx + s * bW * 0.52, cy - bH * 0.30)
          ..lineTo(cx + s * bW * 0.80, cy - bH * 0.20)
          ..lineTo(cx + s * bW * 0.80, cy + bH * 0.10)
          ..lineTo(cx + s * bW * 0.52, cy + bH * 0.10)
          ..close(),
        Paint()..color = win.withValues(alpha: 0.7),
      );
    }

    // Headlights
    for (final s in [-1.0, 1.0]) {
      canvas.drawPath(
        Path()
          ..moveTo(cx + s * bW * 0.48, cy - bH * 0.87)
          ..quadraticBezierTo(cx + s * bW * 0.80, cy - bH * 0.83, cx + s * bW * 0.76, cy - bH * 0.72)
          ..lineTo(cx + s * bW * 0.56, cy - bH * 0.74)
          ..close(),
        Paint()..color = headlight,
      );
    }
    // Taillights
    for (final s in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(center: Offset(cx + s * bW * 0.46, cy + bH * 0.87), width: bW * 0.44, height: 5),
          const Radius.circular(3),
        ),
        Paint()..color = taillight,
      );
    }
    // Side mirrors
    for (final s in [-1.0, 1.0]) {
      canvas.drawOval(
        Rect.fromCenter(center: Offset(cx + s * (bW + 4), cy - bH * 0.26), width: 6, height: 8),
        Paint()..color = body,
      );
    }

    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
    if (!mounted) return;
    final raw = bytes!.buffer.asUint8List();
    setState(() {
      // ignore: deprecated_member_use
      _arrowIcon = BitmapDescriptor.fromBytes(raw);
      _arrowIconBytes = raw;
    });
  }

  void _onCameraMoveStarted() {
    if (!_cameraFollowing) return;
    setState(() => _cameraFollowing = false);
    _reFollowTimer?.cancel();
    _reFollowTimer = Timer(const Duration(seconds: 7), _recenter);
  }

  void _recenter() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    setState(() {
      _cameraFollowing = true;
      _hasResumedOnce = true;
    });
    _animateCameraNav(_pos, zoom: 16.5, bearing: _bearing);
  }

  Set<Marker> get _allMarkers {
    final m = <Marker>{};
    m.add(
      Marker(
        markerId: const MarkerId('driver'),
        position: _pos,
        icon: _arrowIcon ?? BitmapDescriptor.defaultMarker,
        rotation: _bearing,
        flat: true,
        anchor: const Offset(0.5, 0.5),
        zIndexInt: 100,
      ),
    );
    final dest =
        _sm.phase == TripPhase.onTrip || _sm.phase == TripPhase.arrivedDropoff
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    m.add(
      Marker(
        markerId: const MarkerId('destination'),
        position: dest,
        icon: BitmapDescriptor.defaultMarkerWithHue(45.0),
        zIndexInt: 90,
      ),
    );
    return m;
  }

  Set<Polyline> get _polylines {
    final s = <Polyline>{};
    if (_displayRoutePts.length >= 2) {
      s.add(
        Polyline(
          polylineId: const PolylineId('shadow'),
          points: _displayRoutePts,
          color: const Color(0x405BA3F5),
          width: 14,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      );
      s.add(
        Polyline(
          polylineId: const PolylineId('route'),
          points: _displayRoutePts,
          color: const Color(0xFF5BA3F5),
          width: 7,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      );
    }
    return s;
  }

  void _animateCameraNav(
    LatLng pos, {
    double zoom = 17,
    double bearing = 0,
    double tilt = 55,
  }) {
    _map?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: pos, zoom: zoom, bearing: bearing, tilt: tilt),
      ),
    );
  }

  // =========================================================================
  //  BUILD
  // =========================================================================

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final top = mq.padding.top;
    final bot = mq.padding.bottom;

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );

    return Scaffold(
      backgroundColor: const Color(0xFF080c16),
      body: Stack(
        children: [
          // ── FULLSCREEN MAP ────────────────────────────────────────────────
          Positioned.fill(
            child: GoogleMap(
              style: MapStyles.navigation,
              initialCameraPosition: CameraPosition(
                target: _pos,
                zoom: 17,
                tilt: 55,
                bearing: _bearing,
              ),
              onMapCreated: (c) {
                _map = c;
                _mapReady = true;
                _map!.moveCamera(
                  CameraUpdate.newCameraPosition(
                    CameraPosition(target: _pos, zoom: 17, tilt: 55, bearing: _bearing),
                  ),
                );
              },
              onCameraMoveStarted: _onCameraMoveStarted,
              markers: _allMarkers,
              polylines: _polylines,
              myLocationEnabled: false,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              mapToolbarEnabled: false,
              compassEnabled: false,
              buildingsEnabled: true,
              trafficEnabled: false,
              padding: EdgeInsets.only(top: top + 140, bottom: 200 + bot),
            ),
          ),

          // ── TOP NAV BANNER ────────────────────────────────────────────────
          Positioned(top: top + 8, left: 12, right: 12, child: _navBanner()),

          // ── SPEED LIMIT SIGN (bottom-left above ETA bar) ──────────────────
          Positioned(bottom: 172 + bot, left: 14, child: _speedLimitSign()),

          // ── RIGHT FLOATING BUTTON STACK ───────────────────────────────────
          Positioned(right: 14, bottom: 192 + bot, child: _rightFabStack()),

          // ── RECENTER BUTTON ───────────────────────────────────────────────
          if (!_cameraFollowing)
            Positioned(
              bottom: 290 + bot,
              left: _hasResumedOnce ? 80 : 0,
              right: _hasResumedOnce ? null : 0,
              child: _hasResumedOnce
                  ? _recenterButton()
                  : Center(child: _resumePill()),
            ),

          // ── BOTTOM PANEL: Rider info + ETA + Action ────────────────────────
          Positioned(bottom: 0, left: 0, right: 0, child: _bottomPanel(bot)),
        ],
      ),
    );
  }

  // =========================================================================
  //  TOP NAV BANNER
  // =========================================================================

  Widget _navBanner() {
    final maneuver = _navState?.currentManeuver ?? 'straight';
    final mInfo = NavigationService.getManeuverIcon(maneuver);
    final distText = _navState?.distanceToTurnText ?? '';
    final instruction = _navState?.currentInstruction ?? _phaseInstruction;
    final streetName = _navState?.currentStep?.streetName ?? '';
    final isOffRoute = _navState?.isOffRoute ?? false;
    final nextStep = _navState?.nextStep;
    final nextMInfo = nextStep != null
        ? NavigationService.getManeuverIcon(nextStep.maneuver)
        : null;

    // Banner color: green for pickup, blue for trip, red if off-route
    final bannerColor = isOffRoute
        ? const Color(0xFFD32F2F)
        : (_sm.phase == TripPhase.toPickup
              ? const Color(0xFF2E7D32)
              : const Color(0xFF1A73E8));

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // ── PRIMARY TURN CARD (Google Maps style) ──
        Container(
          decoration: BoxDecoration(
            color: bannerColor,
            borderRadius: BorderRadius.circular(14),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 16,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          clipBehavior: Clip.hardEdge,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Main turn row
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Large maneuver icon
                    Icon(mInfo.icon, color: Colors.white, size: 44),
                    const SizedBox(width: 12),
                    // Distance + road info
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            crossAxisAlignment: CrossAxisAlignment.baseline,
                            textBaseline: TextBaseline.alphabetic,
                            children: [
                              if (distText.isNotEmpty)
                                Text(
                                  distText,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 28,
                                    fontWeight: FontWeight.w900,
                                    height: 1.0,
                                    fontFeatures: [FontFeature.tabularFigures()],
                                  ),
                                ),
                              if (streetName.isNotEmpty) ...[
                                const SizedBox(width: 10),
                                // Road badge (like Google Maps highway shields)
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: Text(
                                    streetName,
                                    style: TextStyle(
                                      color: bannerColor,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w800,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            instruction,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                              height: 1.2,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (isOffRoute)
                      Container(
                        margin: const EdgeInsets.only(left: 6),
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'OFF\nROUTE',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                            height: 1.2,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // ── Lane guidance arrows row ──
              _laneGuidanceRow(maneuver, bannerColor),
              // ── Next step preview ──
              if (nextStep != null && nextMInfo != null)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  color: bannerColor.withValues(alpha: 0.85),
                  child: Row(
                    children: [
                      Text(
                        'Then',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.7),
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(nextMInfo.icon, color: Colors.white.withValues(alpha: 0.8), size: 16),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          nextStep.streetName.isNotEmpty
                              ? nextStep.streetName
                              : nextStep.distanceText,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }

  /// Lane guidance arrows (Google Maps style green/white arrows)
  Widget _laneGuidanceRow(String maneuver, Color bannerColor) {
    // Determine lane arrows based on current maneuver
    final isLeft = maneuver.contains('left');
    final isRight = maneuver.contains('right');
    final isStraight = maneuver == 'straight' || maneuver.isEmpty;
    final isRamp = maneuver.contains('ramp') || maneuver.contains('fork');
    final laneCount = isRamp ? 4 : 5;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 6),
      color: bannerColor.withValues(alpha: 0.7),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: List.generate(laneCount, (i) {
          final isHighlighted = isStraight
              ? true
              : isLeft
                  ? (i == 0)
                  : isRight
                      ? (i == laneCount - 1)
                      : (i == laneCount ~/ 2);
          final arrowIcon = isStraight
              ? Icons.straight
              : (i == 0 && isLeft)
                  ? Icons.turn_left
                  : (i == laneCount - 1 && isRight)
                      ? Icons.turn_right
                      : Icons.straight;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: Icon(
              arrowIcon,
              size: 18,
              color: isHighlighted
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.3),
            ),
          );
        }),
      ),
    );
  }

  String get _phaseInstruction {
    final s = S.of(context);
    switch (_sm.phase) {
      case TripPhase.toPickup:
        return s.headToPickup;
      case TripPhase.arrivedPickup:
        return s.arrivedAtPickup;
      case TripPhase.onTrip:
        return s.headToDropOff;
      case TripPhase.arrivedDropoff:
        return s.arrivedAtDest;
      case TripPhase.completed:
        return s.tripComplete;
      default:
        return s.readyLabel;
    }
  }

  // =========================================================================
  //  SPEED + SPEED LIMIT — Google Maps style (current speed + limit badge)
  // =========================================================================

  Widget _speedLimitSign() {
    final speed = _currentSpeedMph.round();
    final overLimit = speed > widget.speedLimitMph + 5;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Speed limit badge (MUTCD style)
        Container(
          width: 44,
          padding: const EdgeInsets.symmetric(vertical: 3, horizontal: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.black87, width: 2),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'SPEED\nLIMIT',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.black87,
                  fontSize: 6,
                  fontWeight: FontWeight.w900,
                  height: 1.1,
                ),
              ),
              Text(
                '${widget.speedLimitMph}',
                style: const TextStyle(
                  color: Colors.black87,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                  height: 1.1,
                  fontFeatures: [FontFeature.tabularFigures()],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 6),
        // Current speed (large, like Google Maps)
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            color: overLimit ? _red : _cardBg,
            shape: BoxShape.circle,
            border: Border.all(
              color: overLimit ? _red : _cardBorder,
              width: 2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '$speed',
                style: TextStyle(
                  color: overLimit ? Colors.white : _textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                  height: 1,
                  fontFeatures: const [FontFeature.tabularFigures()],
                ),
              ),
              Text(
                'mph',
                style: TextStyle(
                  color: overLimit
                      ? Colors.white.withValues(alpha: 0.8)
                      : _textSecondary,
                  fontSize: 9,
                  fontWeight: FontWeight.w600,
                  height: 1,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // =========================================================================
  //  RIGHT FLOATING ACTION BUTTONS
  // =========================================================================

  Widget _rightFabStack() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        _circleFab(
          icon: Icons.home_rounded,
          tooltip: S.of(context).goHomeLabel,
          iconColor: _textSecondary,
          onTap: () => Navigator.of(context).pop(),
        ),
        const SizedBox(height: 10),
        _circleFab(
          icon: _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          tooltip: _muted ? S.of(context).unmuteLabel : S.of(context).muteLabel,
          iconColor: _muted ? _gold : _textSecondary,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _muted = !_muted);
          },
        ),
        const SizedBox(height: 10),
        _circleFab(
          icon: Icons.report_problem_rounded,
          tooltip: S.of(context).reportIncident,
          iconColor: _textSecondary,
          onTap: () {
            HapticFeedback.mediumImpact();
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(S.of(context).incidentReported),
                duration: const Duration(seconds: 1),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _circleFab({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    Color? iconColor,
    bool active = false,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _cardBg,
            shape: BoxShape.circle,
            border: Border.all(color: _cardBorder, width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            icon,
            color: iconColor ?? (active ? _gold : _textSecondary),
            size: 22,
          ),
        ),
      ),
    );
  }

  // =========================================================================
  //  RECENTER BUTTON
  // =========================================================================

  Widget _recenterButton() {
    return GestureDetector(
      onTap: _recenter,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: _cardBg,
          shape: BoxShape.circle,
          border: Border.all(color: _cardBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.navigation_rounded, color: _gold, size: 24),
      ),
    );
  }

  Widget _resumePill() {
    return GestureDetector(
      onTap: _recenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(24),
          border: Border.all(color: _cardBorder, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.35),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.navigation_rounded, color: _gold, size: 20),
            const SizedBox(width: 8),
            Text(
              S.of(context).resumeNav,
              style: TextStyle(
                color: _gold,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.2,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // =========================================================================
  //  BOTTOM PANEL — Uber-style: rider info + ETA + phase action button
  // =========================================================================

  Widget _bottomPanel(double botPad) {
    final arrival = DateTime.now().add(Duration(minutes: _etaMinutes));
    final h12 = arrival.hour % 12 == 0 ? 12 : arrival.hour % 12;
    final min = arrival.minute.toString().padLeft(2, '0');
    final ampm = arrival.hour < 12 ? 'AM' : 'PM';
    final arrivalStr = '$h12:$min $ampm';
    final distStr = _distRemainingMi < 0.1
        ? '${(_distRemainingMi * 5280).round()} ft'
        : '${_distRemainingMi.toStringAsFixed(1)} mi';

    return Container(
      decoration: const BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(color: Color(0x55000000), blurRadius: 16, offset: Offset(0, -4)),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── Google Maps style ETA row: green ETA left, details right ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                // Big green ETA
                Text(
                  '$_etaMinutes min',
                  style: const TextStyle(
                    color: Color(0xFF34A853),
                    fontSize: 24,
                    fontWeight: FontWeight.w900,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                if (!_muted)
                  Padding(
                    padding: const EdgeInsets.only(left: 6),
                    child: Icon(Icons.volume_up_rounded, color: _green, size: 18),
                  ),
                const Spacer(),
                // Distance · Arrival
                Text(
                  '$distStr · $arrivalStr',
                  style: const TextStyle(
                    color: _textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(width: 10),
                // Recenter / compass button (Google Maps style)
                GestureDetector(
                  onTap: _recenter,
                  child: Container(
                    width: 36, height: 36,
                    decoration: BoxDecoration(
                      color: const Color(0xFF232840),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: _cardBorder, width: 1),
                    ),
                    child: const Icon(Icons.near_me_rounded, color: _textSecondary, size: 18),
                  ),
                ),
              ],
            ),
          ),
          Container(height: 1, color: _cardBorder),
          // ── Rider info row ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 6),
            child: Row(
              children: [
                // Avatar
                Container(
                  width: 40, height: 40,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: _gold, width: 2),
                    image: widget.riderPhotoUrl.isNotEmpty
                        ? DecorationImage(
                            image: NetworkImage(widget.riderPhotoUrl),
                            fit: BoxFit.cover,
                          )
                        : null,
                    color: const Color(0xFF2A2F42),
                  ),
                  child: widget.riderPhotoUrl.isEmpty
                      ? const Icon(Icons.person, color: _textSecondary, size: 20)
                      : null,
                ),
                const SizedBox(width: 10),
                // Name + rating
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.riderName,
                        style: const TextStyle(
                          color: _textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1, overflow: TextOverflow.ellipsis,
                      ),
                      if (widget.riderRating > 0)
                        Row(
                          children: [
                            const Icon(Icons.star_rounded, color: _gold, size: 13),
                            const SizedBox(width: 2),
                            Text(
                              widget.riderRating.toStringAsFixed(1),
                              style: const TextStyle(
                                color: _textSecondary, fontSize: 11, fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
                // Address pill
                Expanded(
                  child: _currentAddressPill(),
                ),
                // Contact buttons
                _miniBtn(Icons.message_rounded, () => HapticFeedback.lightImpact()),
                const SizedBox(width: 6),
                _miniBtn(Icons.phone_rounded, () => HapticFeedback.lightImpact()),
              ],
            ),
          ),
          // ── Phase action button ──
          Padding(
            padding: EdgeInsets.fromLTRB(16, 6, 16, botPad + 12),
            child: _actionButton(),
          ),
        ],
      ),
    );
  }

  Widget _currentAddressPill() {
    final isPickupPhase = _sm.phase == TripPhase.toPickup || _sm.phase == TripPhase.arrivedPickup;
    final label = isPickupPhase ? widget.pickupLabel : widget.dropoffLabel;
    if (label.isEmpty) return const SizedBox.shrink();
    final icon = isPickupPhase ? Icons.radio_button_checked : Icons.location_on_rounded;
    final color = isPickupPhase ? const Color(0xFF4CAF50) : _red;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 12),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            style: const TextStyle(color: _textSecondary, fontSize: 11, fontWeight: FontWeight.w500),
            maxLines: 1, overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _miniBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: const Color(0xFF232840),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: _cardBorder, width: 1),
        ),
        child: Icon(icon, color: _textSecondary, size: 16),
      ),
    );
  }

  // =========================================================================
  //  ACTION BUTTON — context-aware (Uber-style slide-to-act feel)
  // =========================================================================

  Widget _actionButton() {
    String label;
    Color bg;
    IconData icon;
    VoidCallback onTap;
    final s = S.of(context);

    switch (_sm.phase) {
      case TripPhase.toPickup:
        label = s.arrivedAtPickup;
        bg = const Color(0xFF2E7D32);
        icon = Icons.check_circle_outline_rounded;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.arriveAtPickup();
        };
      case TripPhase.arrivedPickup:
        label = s.startTrip;
        bg = _gold;
        icon = Icons.play_arrow_rounded;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.beginTrip();
        };
      case TripPhase.onTrip:
        label = s.endTrip;
        bg = _red;
        icon = Icons.stop_rounded;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.arriveAtDropoff();
        };
      case TripPhase.arrivedDropoff:
        label = s.finishRide;
        bg = _gold;
        icon = Icons.flag_rounded;
        onTap = () async {
          HapticFeedback.heavyImpact();
          _sm.completeTrip();
          final tid = int.tryParse(widget.tripId);
          if (tid != null) {
            try {
              await ApiService.updateTripStatus(tripId: tid, status: 'completed');
            } catch (_) {}
          }
          if (context.mounted) Navigator.of(context).pop();
        };
      default:
        return const SizedBox.shrink();
    }

    return SizedBox(
      width: double.infinity,
      height: 52,
      child: ElevatedButton.icon(
        onPressed: onTap,
        icon: Icon(icon, size: 22),
        label: Text(
          label.toUpperCase(),
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w900,
            letterSpacing: 1.2,
          ),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          elevation: 6,
          shadowColor: bg.withValues(alpha: 0.4),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        ),
      ),
    );
  }

  // =========================================================================
  //  UTILS
  // =========================================================================

  List<LatLng> _makeStraightRoute(LatLng from, LatLng to) {
    const n = 60;
    return List.generate(n + 1, (i) {
      final t = i / n;
      return LatLng(
        from.latitude + (to.latitude - from.latitude) * t,
        from.longitude + (to.longitude - from.longitude) * t,
      );
    });
  }

  double _haversineM(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = _r(b.latitude - a.latitude);
    final dLng = _r(b.longitude - a.longitude);
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_r(a.latitude)) *
            math.cos(_r(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  double _r(double d) => d * math.pi / 180;
}
