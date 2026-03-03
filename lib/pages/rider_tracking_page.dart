import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../config/map_styles.dart';
import '../navigation/car_sprite_manager.dart';
import '../navigation/nav_state_machine.dart';
import '../navigation/route_snapper.dart';
import '../navigation/smooth_motion.dart';

/// Uber-identical rider tracking page.
///
/// Shows:
///  • Top-down map with the driver's car moving smoothly
///  • Blue route polyline from driver → destination
///  • "Meet at pickup" / "Arriving soon" / "On trip" banners
///  • Bottom sheet with driver info, ETA, vehicle details
///  • Call / Message action buttons
///  • Auto-zoom to keep car + destination visible
///  • Animated expandable bottom sheet (drag handle)
///
/// Expects driver location updates via [driverLocationStream].
/// Falls back to demo simulation if no stream is provided.
class RiderTrackingPage extends StatefulWidget {
  const RiderTrackingPage({
    super.key,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    this.driverLocationStream,
    this.driverBearingStream,
    this.routePoints,
    this.driverName = 'Carlos M.',
    this.driverRating = 4.92,
    this.driverPhotoUrl,
    this.vehicleMake = 'Toyota',
    this.vehicleModel = 'Camry',
    this.vehicleColor = 'White',
    this.vehiclePlate = 'ABC-1234',
    this.vehicleYear = '2022',
    this.tripId = 'demo-trip',
    this.initialPhase = TripPhase.toPickup,
    this.onCallDriver,
    this.onMessageDriver,
    this.onCancelRide,
  });

  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final Stream<LatLng>? driverLocationStream;
  final Stream<double>? driverBearingStream;
  final List<LatLng>? routePoints;

  // Driver info
  final String driverName;
  final double driverRating;
  final String? driverPhotoUrl;

  // Vehicle info
  final String vehicleMake;
  final String vehicleModel;
  final String vehicleColor;
  final String vehiclePlate;
  final String vehicleYear;

  final String tripId;
  final TripPhase initialPhase;

  // Callbacks
  final VoidCallback? onCallDriver;
  final VoidCallback? onMessageDriver;
  final VoidCallback? onCancelRide;

  @override
  State<RiderTrackingPage> createState() => _RiderTrackingPageState();
}

class _RiderTrackingPageState extends State<RiderTrackingPage>
    with TickerProviderStateMixin {
  GoogleMapController? _map;

  late final NavStateMachine _sm;
  late final SmoothMotion _motion;

  // Driver state
  LatLng _driverPos = const LatLng(0, 0);
  double _driverBearing = 0;
  int _snapSegIdx = 0;

  // Route
  List<LatLng> _routePts = [];

  // ETA / distance
  double _distRemainingMi = 0;
  int _etaMinutes = 0;

  // Streams
  StreamSubscription? _locSub;
  StreamSubscription? _bearSub;
  Timer? _demoTimer;
  Timer? _cameraTimer;

  bool _mapReady = false;
  bool _showArrivingSoon = false;
  bool _sheetExpanded = false;

  // Animation
  late AnimationController _bannerCtrl;
  late Animation<double> _bannerAnim;

  @override
  void initState() {
    super.initState();

    _sm = NavStateMachine(
      onPhaseChanged: (_) {
        if (mounted) setState(() {});
      },
    );
    _sm.startTrip(
      tripId: widget.tripId,
      pickup: widget.pickupLatLng,
      dropoff: widget.dropoffLatLng,
    );

    _driverPos = widget.pickupLatLng;

    _motion = SmoothMotion(
      onTick: _onMotionTick,
      lerpFactor: 0.12,
      enablePrediction: true,
    );
    _motion.start(this);

    _routePts = widget.routePoints ?? _generateRoute();
    _loadIcon();
    _subscribeStreams();

    // Banner animation
    _bannerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _bannerAnim = CurvedAnimation(
      parent: _bannerCtrl,
      curve: Curves.easeOutCubic,
    );

    // Periodic camera fit
    _cameraTimer = Timer.periodic(
      const Duration(seconds: 3),
      (_) => _smartCameraFit(),
    );
  }

  @override
  void dispose() {
    _locSub?.cancel();
    _bearSub?.cancel();
    _demoTimer?.cancel();
    _cameraTimer?.cancel();
    _motion.dispose();
    _sm.dispose();
    _bannerCtrl.dispose();
    _map?.dispose();
    super.dispose();
  }

  // ─── BOOT ───

  Future<void> _loadIcon() async {
    await CarSpriteManager.init();
    if (mounted) setState(() {});
  }

  void _subscribeStreams() {
    if (widget.driverLocationStream != null) {
      _locSub = widget.driverLocationStream!.listen(_onDriverLocation);
      _bearSub = widget.driverBearingStream?.listen((b) {
        _driverBearing = b;
      });
    } else {
      _startDemoSimulation();
    }
  }

  // ─── DEMO SIMULATION ───

  void _startDemoSimulation() {
    int idx = 0;
    _driverPos = _routePts.first;
    _motion.teleport(_routePts.first, 0);

    _demoTimer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (!mounted) return;
      idx = (idx + 1).clamp(0, _routePts.length - 1);
      final pos = _routePts[idx];
      final bearing = idx > 0
          ? SmoothMotion.computeBearing(_routePts[idx - 1], pos)
          : 0.0;
      _onDriverLocation(pos);
      _driverBearing = bearing;

      // Phase transitions
      if (_sm.phase == TripPhase.toPickup && idx >= _routePts.length ~/ 2) {
        _sm.arriveAtPickup();
        Future.delayed(const Duration(seconds: 3), () {
          if (mounted) _sm.beginTrip();
        });
      }
      if (idx >= _routePts.length - 1) {
        _demoTimer?.cancel();
        _sm.arriveAtDropoff();
      }
    });
  }

  // ─── DRIVER LOCATION UPDATE ───

  void _onDriverLocation(LatLng raw) {
    final snap = RouteSnapper.snap(raw, _routePts, lastIndex: _snapSegIdx);
    _snapSegIdx = snap.segmentIndex;

    // Always use route-tangent bearing (never raw GPS delta)
    _driverBearing = snap.bearingDeg;

    _motion.pushTarget(snap.snapped, snap.bearingDeg);

    // Update ETA / distance
    final dest = _sm.phase == TripPhase.onTrip
        ? widget.dropoffLatLng
        : widget.pickupLatLng;
    final distM = _haversineM(snap.snapped, dest);
    final wasFar = _distRemainingMi > 0.1;

    setState(() {
      _distRemainingMi = distM / 1609.34;
      _etaMinutes = (distM / 500 / 60).ceil().clamp(1, 99);
    });

    // "Arriving soon" detection (within ~200m of pickup)
    if (_sm.phase == TripPhase.toPickup &&
        distM < 200 &&
        !_showArrivingSoon &&
        wasFar) {
      setState(() => _showArrivingSoon = true);
      _bannerCtrl.forward();
      HapticFeedback.mediumImpact();
    }
  }

  void _onMotionTick(LatLng pos, double bearing) {
    if (!mounted) return;
    _driverPos = pos;
    _driverBearing = bearing;
    setState(() {});
  }

  // ─── CAMERA ───

  void _smartCameraFit() {
    if (_map == null || !_mapReady) return;

    final dest = _sm.phase == TripPhase.onTrip
        ? widget.dropoffLatLng
        : widget.pickupLatLng;

    final points = [_driverPos, dest];

    // Include pickup if toPickup phase
    if (_sm.phase == TripPhase.toPickup) {
      points.add(widget.pickupLatLng);
    }

    _fitBounds(points);
  }

  void _fitBounds(List<LatLng> points) {
    if (points.length < 2) return;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    // Add padding for bottom sheet
    final latPad = (maxLat - minLat) * 0.15;
    final lngPad = (maxLng - minLng) * 0.15;
    _map?.animateCamera(
      CameraUpdate.newLatLngBounds(
        LatLngBounds(
          southwest: LatLng(minLat - latPad, minLng - lngPad),
          northeast: LatLng(maxLat + latPad, maxLng + lngPad),
        ),
        60,
      ),
    );
  }

  // ─── ROUTE ───

  List<LatLng> _generateRoute() {
    final from = widget.pickupLatLng;
    final to = widget.dropoffLatLng;
    const steps = 80;
    return List.generate(steps + 1, (i) {
      final t = i / steps;
      return LatLng(
        from.latitude + (to.latitude - from.latitude) * t,
        from.longitude + (to.longitude - from.longitude) * t,
      );
    });
  }

  // ─── MARKERS ───

  Set<Marker> get _allMarkers {
    final m = <Marker>{};

    // Driver car — sprite already oriented, flat: false for 3D tilt
    m.add(
      Marker(
        markerId: const MarkerId('driver_car'),
        position: _driverPos,
        icon: CarSpriteManager.iconForBearing(_driverBearing),
        rotation: 0,
        flat: false,
        anchor: const Offset(0.5, 0.7),
        zIndex: 100,
      ),
    );

    // Pickup marker
    if (_sm.phase == TripPhase.toPickup ||
        _sm.phase == TripPhase.arrivedPickup) {
      m.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: widget.pickupLatLng,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
          zIndex: 90,
        ),
      );
    }

    // Dropoff marker
    m.add(
      Marker(
        markerId: const MarkerId('dropoff'),
        position: widget.dropoffLatLng,
        icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        zIndex: 90,
      ),
    );

    return m;
  }

  Set<Polyline> get _polylines {
    if (_routePts.length < 2) return {};
    return {
      // Route shadow
      Polyline(
        polylineId: const PolylineId('route_shadow'),
        points: _routePts,
        color: const Color(0x30000000),
        width: 8,
      ),
      // Main route
      Polyline(
        polylineId: const PolylineId('route'),
        points: _routePts,
        color: const Color(0xFF276EF1),
        width: 5,
      ),
    };
  }

  // ─── BUILD ───

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final top = MediaQuery.of(context).padding.top;
    final bot = MediaQuery.of(context).padding.bottom;

    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
    );

    return Scaffold(
      backgroundColor: isDark ? const Color(0xFF111111) : Colors.white,
      body: Stack(
        children: [
          // ─── MAP ───
          GoogleMap(
            initialCameraPosition: CameraPosition(
              target: widget.pickupLatLng,
              zoom: 14,
              tilt: 0,
              bearing: 0,
            ),
            onMapCreated: (c) {
              _map = c;
              _mapReady = true;
              try {
                c.setMapStyle(isDark ? MapStyles.dark : MapStyles.light);
              } catch (_) {}
              Future.delayed(const Duration(milliseconds: 400), () {
                _fitBounds([widget.pickupLatLng, widget.dropoffLatLng]);
              });
            },
            markers: _allMarkers,
            polylines: _polylines,
            myLocationEnabled: false,
            myLocationButtonEnabled: false,
            zoomControlsEnabled: false,
            mapToolbarEnabled: false,
            compassEnabled: false,
            buildingsEnabled: false,
            padding: EdgeInsets.only(top: top + 80, bottom: 260),
          ),

          // ─── TOP STATUS BANNER ───
          Positioned(top: 0, left: 0, right: 0, child: _topBanner(isDark, top)),

          // ─── "ARRIVING SOON" FLOATING BANNER ───
          if (_showArrivingSoon && _sm.phase == TripPhase.toPickup)
            Positioned(
              top: top + 90,
              left: 32,
              right: 32,
              child: FadeTransition(
                opacity: _bannerAnim,
                child: SlideTransition(
                  position: Tween<Offset>(
                    begin: const Offset(0, -0.5),
                    end: Offset.zero,
                  ).animate(_bannerAnim),
                  child: _arrivingSoonBanner(isDark),
                ),
              ),
            ),

          // ─── BOTTOM SHEET ───
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: _bottomSheet(isDark, bot),
          ),
        ],
      ),
    );
  }

  // ─── TOP BANNER ───

  Widget _topBanner(bool isDark, double topPad) {
    final bg = isDark ? const Color(0xE6111111) : const Color(0xE6FFFFFF);
    final text = isDark ? Colors.white : const Color(0xFF1C1C1E);

    String title;
    IconData icon;
    Color iconColor;

    switch (_sm.phase) {
      case TripPhase.toPickup:
        title = 'Meet at pickup';
        icon = Icons.directions_walk_rounded;
        iconColor = const Color(0xFF276EF1);
        break;
      case TripPhase.arrivedPickup:
        title = 'Driver has arrived';
        icon = Icons.local_taxi_rounded;
        iconColor = const Color(0xFF34A853);
        break;
      case TripPhase.onTrip:
        title = 'On your way';
        icon = Icons.navigation_rounded;
        iconColor = const Color(0xFF276EF1);
        break;
      case TripPhase.arrivedDropoff:
        title = 'You\'ve arrived';
        icon = Icons.flag_rounded;
        iconColor = const Color(0xFF34A853);
        break;
      case TripPhase.completed:
        title = 'Trip completed';
        icon = Icons.check_circle_rounded;
        iconColor = const Color(0xFF34A853);
        break;
      default:
        title = 'Finding driver...';
        icon = Icons.search_rounded;
        iconColor = Colors.grey;
    }

    return ClipRRect(
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
        child: Container(
          padding: EdgeInsets.only(
            top: topPad + 12,
            bottom: 14,
            left: 20,
            right: 20,
          ),
          decoration: BoxDecoration(
            color: bg,
            border: Border(
              bottom: BorderSide(
                color: isDark
                    ? Colors.white10
                    : Colors.black.withValues(alpha: 0.06),
              ),
            ),
          ),
          child: Row(
            children: [
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: isDark
                        ? Colors.white10
                        : Colors.black.withValues(alpha: 0.05),
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: text,
                    size: 18,
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    color: text,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              // ETA pill
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xFF276EF1),
                  borderRadius: BorderRadius.circular(20),
                ),
                child: Text(
                  '$_etaMinutes min',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ─── ARRIVING SOON BANNER ───

  Widget _arrivingSoonBanner(bool isDark) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF276EF1),
        borderRadius: BorderRadius.circular(14),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF276EF1).withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        children: [
          const Icon(
            Icons.directions_car_rounded,
            color: Colors.white,
            size: 24,
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Your driver is arriving',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  'Meet at the pickup spot',
                  style: TextStyle(color: Colors.white70, fontSize: 12),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.2),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Text(
              '$_etaMinutes min',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── BOTTOM SHEET ───

  Widget _bottomSheet(bool isDark, double botPad) {
    final bg = isDark ? const Color(0xFF1A1A1A) : Colors.white;
    final text = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final sub = isDark ? Colors.white54 : Colors.black45;
    final divider = isDark
        ? Colors.white10
        : Colors.black.withValues(alpha: 0.06);

    return GestureDetector(
      onVerticalDragUpdate: (d) {
        if (d.delta.dy < -5 && !_sheetExpanded) {
          setState(() => _sheetExpanded = true);
        } else if (d.delta.dy > 5 && _sheetExpanded) {
          setState(() => _sheetExpanded = false);
        }
      },
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
        decoration: BoxDecoration(
          color: bg,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.15),
              blurRadius: 24,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: Padding(
          padding: EdgeInsets.only(bottom: botPad + 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 6),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: sub.withValues(alpha: 0.3),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),

              // ── ETA + Distance strip ──
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Row(
                  children: [
                    // ETA
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '$_etaMinutes',
                            style: TextStyle(
                              color: text,
                              fontSize: 34,
                              fontWeight: FontWeight.w900,
                              fontFeatures: const [
                                FontFeature.tabularFigures(),
                              ],
                              height: 1,
                            ),
                          ),
                          Text(
                            'min away',
                            style: TextStyle(
                              color: sub,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Distance
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          '${_distRemainingMi.toStringAsFixed(1)} mi',
                          style: TextStyle(
                            color: text,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            fontFeatures: const [FontFeature.tabularFigures()],
                          ),
                        ),
                        Text(
                          _sm.phase == TripPhase.onTrip
                              ? 'to destination'
                              : 'to pickup',
                          style: TextStyle(color: sub, fontSize: 12),
                        ),
                      ],
                    ),
                  ],
                ),
              ),

              // Progress bar
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: _phaseProgress,
                    minHeight: 3,
                    backgroundColor: isDark
                        ? Colors.white12
                        : Colors.black.withValues(alpha: 0.06),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                      Color(0xFF276EF1),
                    ),
                  ),
                ),
              ),

              const SizedBox(height: 14),

              // Divider
              Container(height: 1, color: divider),

              // ── Driver info row ──
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 8),
                child: Row(
                  children: [
                    // Avatar
                    Container(
                      width: 52,
                      height: 52,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: isDark
                            ? const Color(0xFF333333)
                            : const Color(0xFFE5E5E5),
                        border: Border.all(
                          color: const Color(0xFF276EF1).withValues(alpha: 0.3),
                          width: 2,
                        ),
                      ),
                      child: widget.driverPhotoUrl != null
                          ? ClipOval(
                              child: Image.network(
                                widget.driverPhotoUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Icon(
                                  Icons.person_rounded,
                                  color: text,
                                  size: 28,
                                ),
                              ),
                            )
                          : Icon(Icons.person_rounded, color: text, size: 28),
                    ),
                    const SizedBox(width: 14),
                    // Name + rating
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.driverName,
                            style: TextStyle(
                              color: text,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Row(
                            children: [
                              const Icon(
                                Icons.star_rounded,
                                color: Color(0xFFFFC107),
                                size: 16,
                              ),
                              const SizedBox(width: 3),
                              Text(
                                widget.driverRating.toStringAsFixed(2),
                                style: TextStyle(
                                  color: sub,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Call button
                    _actionCircle(
                      Icons.phone_rounded,
                      isDark,
                      widget.onCallDriver ?? () {},
                    ),
                    const SizedBox(width: 10),
                    // Message button
                    _actionCircle(
                      Icons.message_rounded,
                      isDark,
                      widget.onMessageDriver ?? () {},
                    ),
                  ],
                ),
              ),

              // ── Vehicle info ──
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 4, 20, 4),
                child: Row(
                  children: [
                    // Vehicle icon
                    Container(
                      width: 44,
                      height: 28,
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white10
                            : Colors.black.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Icon(
                        Icons.directions_car_rounded,
                        color: sub,
                        size: 18,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Text(
                        '${widget.vehicleColor} ${widget.vehicleMake} ${widget.vehicleModel}',
                        style: TextStyle(
                          color: text,
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    // Plate
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isDark
                            ? Colors.white10
                            : Colors.black.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isDark ? Colors.white12 : Colors.black12,
                        ),
                      ),
                      child: Text(
                        widget.vehiclePlate,
                        style: TextStyle(
                          color: text,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                          fontFeatures: const [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ),
              ),

              // ── Expanded content ──
              if (_sheetExpanded) ...[
                const SizedBox(height: 8),
                Container(height: 1, color: divider),
                const SizedBox(height: 12),

                // Trip details
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  child: Column(
                    children: [
                      _tripDetailRow(
                        Icons.circle,
                        const Color(0xFF34A853),
                        'Pickup',
                        'Your location',
                        isDark,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 10),
                        child: Container(width: 2, height: 24, color: divider),
                      ),
                      _tripDetailRow(
                        Icons.circle,
                        const Color(0xFFEF5350),
                        'Dropoff',
                        'Destination',
                        isDark,
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // Cancel ride button
                if (_sm.phase == TripPhase.toPickup ||
                    _sm.phase == TripPhase.arrivedPickup)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      width: double.infinity,
                      child: TextButton(
                        onPressed:
                            widget.onCancelRide ??
                            () {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text('Cancel ride — coming soon'),
                                ),
                              );
                            },
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                        ),
                        child: const Text(
                          'Cancel ride',
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _tripDetailRow(
    IconData dotIcon,
    Color dotColor,
    String label,
    String address,
    bool isDark,
  ) {
    final text = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final sub = isDark ? Colors.white54 : Colors.black45;

    return Row(
      children: [
        Icon(dotIcon, color: dotColor, size: 10),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: sub,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                address,
                style: TextStyle(
                  color: text,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _actionCircle(IconData icon, bool isDark, VoidCallback onTap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: isDark ? const Color(0xFF2A2A2A) : const Color(0xFFF0F0F0),
          border: Border.all(
            color: isDark
                ? Colors.white10
                : Colors.black.withValues(alpha: 0.06),
          ),
        ),
        child: Icon(
          icon,
          color: isDark ? Colors.white70 : Colors.black54,
          size: 20,
        ),
      ),
    );
  }

  double get _phaseProgress {
    switch (_sm.phase) {
      case TripPhase.idle:
        return 0;
      case TripPhase.toPickup:
        return 0.25;
      case TripPhase.arrivedPickup:
        return 0.45;
      case TripPhase.onTrip:
        return 0.70;
      case TripPhase.arrivedDropoff:
        return 0.95;
      case TripPhase.completed:
        return 1.0;
    }
  }

  // ─── UTILS ───

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
