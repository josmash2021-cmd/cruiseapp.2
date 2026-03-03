import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/map_styles.dart';
import '../navigation/car_sprite_manager.dart';
import '../navigation/nav_state_machine.dart';
import '../navigation/route_snapper.dart';
import '../navigation/route_service.dart';
import '../navigation/smooth_motion.dart';
import '../services/navigation_service.dart';

/// Driver full-screen navigation page — Uber / Google Maps "en ruta" style.
///
/// Provides:
///  • 3D follow-camera (tilt 65°, bearing follows heading, zoom 17.5)
///  • High-fidelity 3D car marker via CarRenderer
///  • Google Maps–style turn-by-turn top banner + street name
///  • Bottom bar: ETA, distance, progress bar, action buttons
///  • Route trimming (polyline erased behind driver)
///  • Smooth 60 fps motion with prediction
///  • Trip lifecycle state machine with haptic transitions
///
/// Can run in demo mode (no GPS) or with live GPS.
class DriverNavigationPage extends StatefulWidget {
  const DriverNavigationPage({
    super.key,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    this.tripId = 'demo-trip',
    this.initialDriverPos,
    this.routePoints,
    this.demoMode = true,
    this.riderName = 'Rider',
    this.vehiclePlate = '',
  });

  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String tripId;
  final LatLng? initialDriverPos;
  final List<LatLng>? routePoints;
  final bool demoMode;
  final String riderName;
  final String vehiclePlate;

  @override
  State<DriverNavigationPage> createState() => _DriverNavigationPageState();
}

class _DriverNavigationPageState extends State<DriverNavigationPage>
    with TickerProviderStateMixin {
  // ─── MAP ───
  GoogleMapController? _map;

  // ─── STATE ───
  late final NavStateMachine _sm;
  late final SmoothMotion _motion;
  final NavigationService _navService = NavigationService();

  LatLng _pos = const LatLng(0, 0);
  double _bearing = 0;
  int _snapIdx = 0;
  bool _cameraFollowing = true;
  Timer? _reFollowTimer;

  // ─── ROUTE ───
  List<LatLng> _routePts = [];
  List<LatLng> _displayRoutePts = []; // trimmed polyline (behind driver erased)
  NavigationState? _navState;

  // ─── STATS ───
  double _distRemainingMi = 0;
  int _etaMinutes = 0;
  double _speedMph = 0;

  // ─── STREAMS ───
  StreamSubscription? _gpsSub;

  // ─── DEMO ───
  Timer? _demoTimer;
  int _demoIdx = 0;

  bool _mapReady = false;

  // Theme colors
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

    _routePts =
        widget.routePoints ?? _makeStraightRoute(_pos, widget.pickupLatLng);
    _displayRoutePts = List.of(_routePts);
    _buildRouteOnInit();
    _loadIcon();
  }

  @override
  void dispose() {
    _gpsSub?.cancel();
    _demoTimer?.cancel();
    _reFollowTimer?.cancel();
    _motion.dispose();
    _sm.dispose();
    _map?.dispose();
    super.dispose();
  }

  // ─── BOOT ───

  Future<void> _loadIcon() async {
    await CarSpriteManager.init();
    if (mounted) setState(() {});
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

    if (widget.demoMode) {
      _startDemo();
    } else {
      _startGPS();
    }
  }

  // ─── GPS ───

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

  // ─── DEMO SIMULATION ───

  void _startDemo() {
    if (_routePts.length < 2) return;
    _demoIdx = 0;
    _demoTimer = Timer.periodic(const Duration(milliseconds: 600), (_) {
      if (!mounted) return;
      _demoIdx = (_demoIdx + 1).clamp(0, _routePts.length - 1);
      final pt = _routePts[_demoIdx];
      final prev = _routePts[(_demoIdx - 1).clamp(0, _routePts.length - 1)];
      final bearing = SmoothMotion.computeBearing(prev, pt);
      _onRawPosition(pt, bearing);

      if (_demoIdx >= _routePts.length - 1) {
        _demoTimer?.cancel();
        if (_sm.phase == TripPhase.toPickup) {
          _sm.arriveAtPickup();
        } else if (_sm.phase == TripPhase.onTrip) {
          _sm.arriveAtDropoff();
        }
      }
    });
  }

  // ─── POSITION PROCESSING ───

  void _onRawPosition(LatLng raw, double rawBearing) {
    final snap = RouteSnapper.snap(raw, _routePts, lastIndex: _snapIdx);
    _snapIdx = snap.segmentIndex;

    // Always use route-tangent bearing from snap, never raw GPS heading
    _motion.pushTarget(snap.snapped, snap.bearingDeg);
    // Nav service update
    if (_navService.isNavigating) {
      _navState = _navService.updatePosition(snap.snapped);
    }

    // Proximity check
    _sm.checkProximity(snap.snapped);

    // Trim route behind driver (Google Maps style)
    _trimRouteBehind(snap.segmentIndex);

    // Update stats
    final dest = _sm.phase == TripPhase.onTrip
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    final dM = _haversineM(snap.snapped, dest);
    setState(() {
      _distRemainingMi = dM / 1609.34;
      _etaMinutes =
          _navState?.etaMinutes ?? (dM / 500 / 60).ceil().clamp(1, 99);
      _speedMph = _motion.estimatedSpeedMps * 2.237;
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

    if (_cameraFollowing && _map != null && _mapReady) {
      _map!.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: pos, zoom: 17.5, bearing: bearing, tilt: 65),
        ),
      );
    }
  }

  // ─── PHASE TRANSITIONS ───

  void _onPhaseChanged(TripPhase phase) {
    if (phase == TripPhase.onTrip) {
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
      if (widget.demoMode) {
        _demoTimer?.cancel();
        _startDemo();
      }
    } else if (mounted) {
      _routePts = _makeStraightRoute(_pos, widget.dropoffLatLng);
      _displayRoutePts = List.of(_routePts);
      _snapIdx = 0;
      setState(() {});
      if (widget.demoMode) {
        _demoTimer?.cancel();
        _startDemo();
      }
    }
  }

  // ─── CAMERA CONTROL ───

  void _onCameraMoveStarted() {
    if (!_cameraFollowing) return;
    setState(() => _cameraFollowing = false);
    _reFollowTimer?.cancel();
    _reFollowTimer = Timer(const Duration(seconds: 5), _recenter);
  }

  void _recenter() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    setState(() => _cameraFollowing = true);
    _map?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _pos, zoom: 17.5, bearing: _bearing, tilt: 65),
      ),
    );
  }

  // ─── MARKERS ───

  Set<Marker> get _allMarkers {
    final m = <Marker>{};

    m.add(
      Marker(
        markerId: const MarkerId('driver'),
        position: _pos,
        icon: CarSpriteManager.iconForBearing(_bearing),
        rotation: 0,
        flat: false,
        anchor: const Offset(0.5, 0.7),
        zIndex: 100,
      ),
    );

    final dest =
        _sm.phase == TripPhase.onTrip || _sm.phase == TripPhase.arrivedDropoff
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    final destHue = (_sm.phase == TripPhase.toPickup)
        ? BitmapDescriptor.hueGreen
        : BitmapDescriptor.hueRed;

    m.add(
      Marker(
        markerId: const MarkerId('destination'),
        position: dest,
        icon: BitmapDescriptor.defaultMarkerWithHue(destHue),
        zIndex: 90,
      ),
    );

    if (_sm.phase == TripPhase.toPickup) {
      m.add(
        Marker(
          markerId: const MarkerId('dropoff_preview'),
          position: widget.dropoffLatLng,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueOrange,
          ),
          zIndex: 80,
        ),
      );
    }

    return m;
  }

  Set<Polyline> get _polylines {
    final s = <Polyline>{};
    if (_displayRoutePts.length >= 2) {
      // Main route
      s.add(
        Polyline(
          polylineId: const PolylineId('nav_route'),
          points: _displayRoutePts,
          color: _sm.phase == TripPhase.toPickup
              ? const Color(0xFF34A853)
              : const Color(0xFF4285F4),
          width: 6,
        ),
      );
      // Route outline (shadow below main)
      s.add(
        Polyline(
          polylineId: const PolylineId('nav_route_shadow'),
          points: _displayRoutePts,
          color: const Color(0x30000000),
          width: 10,
        ),
      );
    }
    return s;
  }

  // ─── BUILD ───

  @override
  Widget build(BuildContext context) {
    final isDark = true; // Driver nav is always dark (like Google Maps nav)
    final top = MediaQuery.of(context).padding.top;
    final bot = MediaQuery.of(context).padding.bottom;

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
      ),
    );

    return Scaffold(
      body: Stack(
        children: [
          // ─── MAP ───
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: _pos,
              zoom: 17.5,
              bearing: 0,
              tilt: 65,
            ),
            onMapCreated: (c) {
              _map = c;
              _mapReady = true;
              try {
                c.setMapStyle(MapStyles.dark);
              } catch (_) {}
              _map!.moveCamera(
                CameraUpdate.newCameraPosition(
                  CameraPosition(
                    target: _pos,
                    zoom: 17.5,
                    bearing: 0,
                    tilt: 65,
                  ),
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
            padding: EdgeInsets.only(top: top + 130, bottom: 220),
          ),

          // ─── NAV HEADER (turn-by-turn) ───
          Positioned(top: top, left: 0, right: 0, child: _navHeader()),

          // ─── SPEED INDICATOR ───
          Positioned(bottom: 230 + bot, left: 16, child: _speedBadge()),

          // ─── RECENTER FAB ───
          if (!_cameraFollowing)
            Positioned(
              bottom: 230 + bot,
              right: 16,
              child: _fab(
                Icons.navigation_rounded,
                48,
                _recenter,
                iconColor: const Color(0xFF4285F4),
              ),
            ),

          // ─── BOTTOM BAR ───
          Positioned(bottom: 0, left: 0, right: 0, child: _bottomBar(bot)),
        ],
      ),
    );
  }

  // ─── NAV HEADER ───

  Widget _navHeader() {
    final maneuver = _navState?.currentManeuver ?? 'straight';
    final mInfo = NavigationService.getManeuverIcon(maneuver);
    final distText = _navState?.distanceToTurnText ?? '';
    final instruction = _navState?.currentInstruction ?? _phaseInstruction;
    final streetName = _navState?.currentStep?.streetName ?? '';
    final isOffRoute = _navState?.isOffRoute ?? false;

    final bgColor = isOffRoute
        ? const Color(0xFFEF5350)
        : (_sm.phase == TripPhase.toPickup
              ? const Color(0xFF1B5E20)
              : const Color(0xFF0D47A1));

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(16),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 14,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Main turn instruction
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
            child: Row(
              children: [
                Container(
                  width: 52,
                  height: 52,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    IconData(mInfo.iconCodePoint, fontFamily: 'MaterialIcons'),
                    color: Colors.white,
                    size: 30,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (distText.isNotEmpty)
                        Text(
                          distText,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w900,
                            fontFeatures: [FontFeature.tabularFigures()],
                          ),
                        ),
                      Text(
                        instruction,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.92),
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                if (isOffRoute)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Text(
                      'OFF\nROUTE',
                      textAlign: TextAlign.center,
                      style: TextStyle(
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
          // Street name bar
          if (streetName.isNotEmpty)
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25),
                borderRadius: const BorderRadius.only(
                  bottomLeft: Radius.circular(16),
                  bottomRight: Radius.circular(16),
                ),
              ),
              child: Text(
                streetName,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.8),
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
        ],
      ),
    );
  }

  String get _phaseInstruction {
    switch (_sm.phase) {
      case TripPhase.toPickup:
        return 'Head to pickup';
      case TripPhase.arrivedPickup:
        return 'Arrived at pickup';
      case TripPhase.onTrip:
        return 'Head to drop-off';
      case TripPhase.arrivedDropoff:
        return 'Arrived at destination';
      case TripPhase.completed:
        return 'Trip complete';
      default:
        return 'Waiting...';
    }
  }

  // ─── SPEED BADGE ───

  Widget _speedBadge() {
    return Container(
      width: 56,
      height: 56,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A).withValues(alpha: 0.85),
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(color: Colors.black.withValues(alpha: 0.3), blurRadius: 8),
        ],
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            '${_speedMph.round()}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 18,
              fontWeight: FontWeight.w900,
              fontFeatures: [FontFeature.tabularFigures()],
              height: 1,
            ),
          ),
          Text(
            'mph',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 9,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  // ─── BOTTOM BAR ───

  Widget _bottomBar(double botPad) {
    return Container(
      padding: EdgeInsets.only(
        top: 16,
        bottom: botPad + 12,
        left: 20,
        right: 20,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF111111),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 36,
            height: 4,
            margin: const EdgeInsets.only(bottom: 14),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          // ETA strip
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              _statChip(Icons.access_time_rounded, '$_etaMinutes min', 'ETA'),
              Container(width: 1, height: 32, color: Colors.white12),
              _statChip(
                Icons.straighten_rounded,
                '${_distRemainingMi.toStringAsFixed(1)} mi',
                'Distance',
              ),
              Container(width: 1, height: 32, color: Colors.white12),
              _statChip(
                Icons.speed_rounded,
                '${_navState?.progress != null ? (_navState!.progress * 100).round() : 0}%',
                'Progress',
              ),
            ],
          ),
          const SizedBox(height: 12),
          // Progress bar
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _navState?.progress ?? 0,
              minHeight: 4,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(
                _sm.phase == TripPhase.toPickup
                    ? const Color(0xFF34A853)
                    : const Color(0xFF4285F4),
              ),
            ),
          ),
          const SizedBox(height: 16),
          // Action button
          _actionButton(),
        ],
      ),
    );
  }

  Widget _statChip(IconData icon, String value, String label) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: Colors.white54),
            const SizedBox(width: 4),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w700,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 10,
          ),
        ),
      ],
    );
  }

  Widget _actionButton() {
    String label;
    Color bgColor;
    VoidCallback? onTap;

    switch (_sm.phase) {
      case TripPhase.toPickup:
        label = 'ARRIVED AT PICKUP';
        bgColor = const Color(0xFF2E7D32);
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.arriveAtPickup();
        };
        break;
      case TripPhase.arrivedPickup:
        label = 'START TRIP';
        bgColor = _gold;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.beginTrip();
        };
        break;
      case TripPhase.onTrip:
        label = 'END TRIP';
        bgColor = const Color(0xFFEF5350);
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.arriveAtDropoff();
        };
        break;
      case TripPhase.arrivedDropoff:
        label = 'FINISH RIDE';
        bgColor = _gold;
        onTap = () {
          HapticFeedback.heavyImpact();
          _sm.completeTrip();
          Navigator.of(context).pop();
        };
        break;
      case TripPhase.completed:
        label = 'DONE';
        bgColor = Colors.grey;
        onTap = () => Navigator.of(context).pop();
        break;
      default:
        label = 'WAITING...';
        bgColor = Colors.grey;
        onTap = null;
    }

    return SizedBox(
      width: double.infinity,
      height: 54,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bgColor,
          foregroundColor: Colors.white,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          elevation: 0,
        ),
        child: Text(
          label,
          style: const TextStyle(
            fontSize: 17,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
          ),
        ),
      ),
    );
  }

  // ─── FAB HELPER ───

  Widget _fab(
    IconData icon,
    double size,
    VoidCallback onTap, {
    Color? iconColor,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A).withValues(alpha: 0.85),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white10),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(icon, color: iconColor ?? Colors.white70, size: size * 0.5),
      ),
    );
  }

  // ─── UTILS ───

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
