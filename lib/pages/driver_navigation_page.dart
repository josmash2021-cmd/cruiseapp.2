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
    this.vehiclePlate = '',
    this.speedLimitMph = 35,
  });

  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String tripId;
  final LatLng? initialDriverPos;
  final List<LatLng>? routePoints;
  final String riderName;
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

  static const _blue = Color(0xFF4285F4);
  static const _green = Color(0xFF34A853);
  static const _red = Color(0xFFEF5350);
  static const _gold = Color(0xFFD4A24C);

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
      lerpFactor: 0.15,
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

    // Throttle camera to ~10 Hz for smooth performance
    final now = DateTime.now();
    if (_cameraFollowing &&
        _map != null &&
        _mapReady &&
        (_lastCameraUpdate == null ||
            now.difference(_lastCameraUpdate!).inMilliseconds > 100)) {
      _lastCameraUpdate = now;
      _animateCameraNav(pos, zoom: 16.5, bearing: bearing);
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
    const double w = 64;
    const double h = 80;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, w, h));

    // Chevron-arrow path: tip = top-center
    final path = Path()
      ..moveTo(w / 2, 4) // tip
      ..lineTo(w - 10, h - 20) // right shoulder
      ..lineTo(w / 2 + 9, h - 34) // right notch (chevron indent)
      ..lineTo(w / 2, h - 20) // bottom center
      ..lineTo(w / 2 - 9, h - 34) // left notch
      ..lineTo(10, h - 20) // left shoulder
      ..close();

    // Drop shadow
    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    // White outline
    canvas.drawPath(
      path,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6
        ..strokeJoin = StrokeJoin.round,
    );
    // Blue fill
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF4285F4)
        ..style = PaintingStyle.fill,
    );

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
          color: const Color(0x33000000),
          width: 14,
        ),
      );
      s.add(
        Polyline(
          polylineId: const PolylineId('route'),
          points: _displayRoutePts,
          color: const Color(0xFF4285F4),
          width: 9,
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
              trafficEnabled: true,
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
              bottom: 190 + bot,
              left: _hasResumedOnce ? 80 : 0,
              right: _hasResumedOnce ? null : 0,
              child: _hasResumedOnce
                  ? _recenterButton()
                  : Center(child: _resumePill()),
            ),

          // ── ACTION PILL (ARRIVED / START / END TRIP) ──────────────────────
          if (_showActionPill)
            Positioned(
              bottom: 132 + bot,
              left: 16,
              right: 16,
              child: _actionPill(),
            ),

          // ── BOTTOM ETA BAR ────────────────────────────────────────────────
          Positioned(bottom: 0, left: 0, right: 0, child: _etaBar(bot)),
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

    // Strip color: red if off-route, dark-green for pickup leg, blue for trip
    final stripColor = isOffRoute
        ? const Color(0xFFD32F2F)
        : (_sm.phase == TripPhase.toPickup
              ? const Color(0xFF2E7D32)
              : const Color(0xFF1A73E8));

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      clipBehavior: Clip.hardEdge,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Colored top accent strip
          Container(height: 5, color: stripColor),
          // Main row
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Maneuver icon with colored background
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: stripColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    mInfo.icon,
                    color: stripColor,
                    size: 32,
                  ),
                ),
                const SizedBox(width: 14),
                // Distance + instruction + off-route badge
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (distText.isNotEmpty)
                        Text(
                          distText,
                          style: TextStyle(
                            color: stripColor,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                            height: 1.0,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                      const SizedBox(height: 3),
                      Text(
                        instruction,
                        style: const TextStyle(
                          color: Color(0xFF202124),
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
                    margin: const EdgeInsets.only(left: 8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFFD32F2F),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      S.of(context).offRoute.toUpperCase(),
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1,
                        height: 1.2,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Street name sub-row
          if (streetName.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: const Color(0xFFF8F9FA),
                border: const Border(
                  top: BorderSide(color: Color(0xFFE8EAED), width: 1),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    Icons.turn_slight_right_rounded,
                    size: 14,
                    color: Colors.grey.shade500,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      streetName,
                      style: const TextStyle(
                        color: Color(0xFF5F6368),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.2,
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
  //  SPEED LIMIT SIGN — US MUTCD style (white box, black border, number)
  // =========================================================================

  Widget _speedLimitSign() {
    return Container(
      width: 48,
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.black, width: 2.5),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 3),
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
              color: Colors.black,
              fontSize: 7.5,
              fontWeight: FontWeight.w900,
              height: 1.15,
              letterSpacing: 0.2,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            '${widget.speedLimitMph}',
            style: const TextStyle(
              color: Colors.black,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              height: 1,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
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
          iconColor: Colors.grey.shade700,
          onTap: () => Navigator.of(context).pop(),
        ),
        const SizedBox(height: 10),
        _circleFab(
          icon: _muted ? Icons.volume_off_rounded : Icons.volume_up_rounded,
          tooltip: _muted ? S.of(context).unmuteLabel : S.of(context).muteLabel,
          iconColor: _muted ? _blue : Colors.grey.shade700,
          onTap: () {
            HapticFeedback.lightImpact();
            setState(() => _muted = !_muted);
          },
        ),
        const SizedBox(height: 10),
        _circleFab(
          icon: Icons.report_problem_rounded,
          tooltip: S.of(context).reportIncident,
          iconColor: Colors.grey.shade700,
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
            color: Colors.white,
            shape: BoxShape.circle,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 8,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Icon(
            icon,
            color: iconColor ?? (active ? _blue : Colors.grey.shade700),
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
          color: Colors.white,
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.navigation_rounded, color: _blue, size: 24),
      ),
    );
  }

  Widget _resumePill() {
    return GestureDetector(
      onTap: _recenter,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(24),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.navigation_rounded, color: _blue, size: 20),
            const SizedBox(width: 8),
            Text(
              S.of(context).resumeNav,
              style: TextStyle(
                color: _blue,
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
  //  BOTTOM ETA BAR  — 3 columns: arrival | time remaining | distance
  // =========================================================================

  Widget _etaBar(double botPad) {
    final arrival = DateTime.now().add(Duration(minutes: _etaMinutes));
    final h12 = arrival.hour % 12 == 0 ? 12 : arrival.hour % 12;
    final min = arrival.minute.toString().padLeft(2, '0');
    final ampm = arrival.hour < 12 ? 'AM' : 'PM';
    final arrivalStr = '$h12:$min $ampm';
    final distStr = _distRemainingMi < 0.1
        ? '${(_distRemainingMi * 5280).round()} ft'
        : '${_distRemainingMi.toStringAsFixed(1)} mi';

    return Container(
      padding: EdgeInsets.only(top: 14, bottom: botPad + 14),
      decoration: const BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Color(0x22000000),
            blurRadius: 16,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: Row(
        children: [
          Expanded(
            child: _etaCell(primary: arrivalStr, secondary: S.of(context).arrivalLabel),
          ),
          _etaDivider(),
          Expanded(
            child: _etaCell(
              primary: '$_etaMinutes min',
              secondary: S.of(context).remainingLabel,
            ),
          ),
          _etaDivider(),
          Expanded(
            child: _etaCell(primary: distStr, secondary: S.of(context).distance),
          ),
        ],
      ),
    );
  }

  Widget _etaCell({required String primary, required String secondary}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          primary,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF202124),
            fontSize: 17,
            fontWeight: FontWeight.w800,
            fontFeatures: [FontFeature.tabularFigures()],
            height: 1,
          ),
        ),
        const SizedBox(height: 3),
        Text(
          secondary,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Color(0xFF5F6368),
            fontSize: 11,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  Widget _etaDivider() =>
      Container(width: 1, height: 28, color: const Color(0xFFE8EAED));

  // =========================================================================
  //  ACTION PILL  — floating above bottom bar, only when action needed
  // =========================================================================

  bool get _showActionPill =>
      _sm.phase == TripPhase.toPickup ||
      _sm.phase == TripPhase.arrivedPickup ||
      _sm.phase == TripPhase.onTrip ||
      _sm.phase == TripPhase.arrivedDropoff;

  Widget _actionPill() {
    String label;
    Color bg;
    VoidCallback onTap;
    switch (_sm.phase) {
      case TripPhase.toPickup:
        label = S.of(context).arrivedAtPickup;
        bg = const Color(0xFF2E7D32);
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.arriveAtPickup();
        };
        break;
      case TripPhase.arrivedPickup:
        label = S.of(context).startTrip;
        bg = _gold;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.beginTrip();
        };
        break;
      case TripPhase.onTrip:
        label = S.of(context).endTrip;
        bg = _red;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.arriveAtDropoff();
        };
        break;
      case TripPhase.arrivedDropoff:
        label = S.of(context).finishRide;
        bg = _gold;
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
        break;
      default:
        return const SizedBox.shrink();
    }
    return SizedBox(
      height: 50,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: Colors.white,
          elevation: 4,
          shadowColor: Colors.black54,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(25),
          ),
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.1,
          ),
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
