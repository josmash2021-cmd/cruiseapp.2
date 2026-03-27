import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import '../../config/page_transitions.dart';
import '../../models/lat_lng.dart';
import '../../widgets/map/circular_pin_renderer.dart';
import '../../widgets/verified_avatar.dart';
import 'driver_trip_accept_screen.dart';

/// Full-screen "Viaje Aceptado" confirmation shown after driver accepts a trip.
/// Shows rider info, gold progress bar, then auto-navigates to
/// [DriverTripAcceptScreen] after 3 seconds.
class TripAcceptedScreen extends StatefulWidget {
  const TripAcceptedScreen({
    super.key,
    required this.tripId,
    required this.riderName,
    required this.riderInitials,
    required this.riderRating,
    required this.pickupAddress,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.dropoffAddress,
    required this.fare,
    required this.vehicleType,
    required this.driverPos,
    required this.distToPickupKm,
    required this.etaMinutes,
    this.riderPhotoUrl,
    this.riderVerified = false,
    this.riderPhone = '',
    this.routePoints,
  });

  final int tripId;
  final String riderName;
  final String riderInitials;
  final String? riderPhotoUrl;
  final bool riderVerified;
  final double riderRating;
  final String pickupAddress;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String dropoffAddress;
  final double fare;
  final String vehicleType;
  final LatLng driverPos;
  final double distToPickupKm;
  final int etaMinutes;
  final String riderPhone;
  final List<LatLng>? routePoints;

  @override
  State<TripAcceptedScreen> createState() => _TripAcceptedScreenState();
}

class _TripAcceptedScreenState extends State<TripAcceptedScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFD4AF37);
  static const _bg = Color(0xFF0A0A0A);
  static const _card = Color(0xFF1A1A1A);

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  // Slide-up animation for the content card
  late final AnimationController _slideCtrl;
  late final Animation<Offset> _slideAnim;
  late final Animation<double> _slideFadeAnim;

  // Map tilt animation: 0° → 55°
  late final AnimationController _tiltCtrl;
  late final Animation<double> _tiltAnim;

  // Route draw
  mapbox.MapboxMap? _mapCtrl;
  mapbox.PolylineAnnotationManager? _polyMgr;
  mapbox.PointAnnotationManager? _pointMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  List<LatLng> _routePoints = [];
  Ticker? _routeDrawTicker;
  bool _routeFetching = false;

  Timer? _navTimer;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeInOut);
    _fadeCtrl.forward();

    // Slide-up + fade for the bottom card
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.3),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));
    _slideFadeAnim = CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic);

    // Start slide after a brief delay for map to appear first
    Future.delayed(const Duration(milliseconds: 150), () {
      if (mounted) _slideCtrl.forward();
    });

    // Map tilt: 0° → 55° over 1s
    _tiltCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1000),
    );
    _tiltAnim = Tween<double>(begin: 0.0, end: 20.0).animate(
      CurvedAnimation(parent: _tiltCtrl, curve: Curves.easeInOutCubic),
    );

    // Pre-fetch route in background
    _prefetchRoute();

    // Auto-navigate to active trip screen after 3 seconds
    _navTimer = Timer(const Duration(seconds: 3), _goToTripScreen);
  }

  @override
  void dispose() {
    _navTimer?.cancel();
    _fadeCtrl.dispose();
    _slideCtrl.dispose();
    _tiltCtrl.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    super.dispose();
  }

  /// Compute bearing from driver to pickup in degrees.
  double _bearingToPickup() {
    final dLng = (widget.pickupLatLng.longitude - widget.driverPos.longitude) * math.pi / 180;
    final lat1 = widget.driverPos.latitude * math.pi / 180;
    final lat2 = widget.pickupLatLng.latitude * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) - math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Pre-fetch route points: use cached, or fetch from OSRM/Mapbox.
  Future<void> _prefetchRoute() async {
    if (widget.routePoints != null && widget.routePoints!.length >= 2) {
      _routePoints = widget.routePoints!;
      return;
    }
    setState(() => _routeFetching = true);
    _routePoints = await _fetchRoutePoints(widget.driverPos, widget.pickupLatLng);
    if (mounted) setState(() => _routeFetching = false);
  }

  /// Fetch route via OSRM → Mapbox → straight line fallback.
  Future<List<LatLng>> _fetchRoutePoints(LatLng o, LatLng d) async {
    // OSRM
    try {
      final path = '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full', 'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 6));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final positions = _decodePoly(routes[0]['geometry'] as String);
          if (positions.isNotEmpty) return positions;
        }
      }
    } catch (_) {}
    // Mapbox fallback
    try {
      final mbxUrl = Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/driving/'
        '${o.longitude},${o.latitude};${d.longitude},${d.latitude}'
        '?geometries=geojson&overview=full&steps=false'
        '&access_token=${MapboxConfig.accessToken}',
      );
      final mbxRes = await http.get(mbxUrl).timeout(const Duration(seconds: 6));
      if (mbxRes.statusCode == 200) {
        final mbxData = jsonDecode(mbxRes.body);
        final mbxRoutes = mbxData['routes'] as List?;
        if (mbxRoutes != null && mbxRoutes.isNotEmpty) {
          final coords = mbxRoutes[0]['geometry']?['coordinates'] as List?;
          if (coords != null && coords.isNotEmpty) {
            return coords
                .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
          }
        }
      }
    } catch (_) {}
    // Straight line fallback
    return List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        o.latitude + (d.latitude - o.latitude) * t,
        o.longitude + (d.longitude - o.longitude) * t,
      );
    });
  }

  List<LatLng> _decodePoly(String encoded) {
    final pts = <LatLng>[];
    int i = 0, lat = 0, lng = 0;
    while (i < encoded.length) {
      int s = 0, r = 0, b;
      do { b = encoded.codeUnitAt(i++) - 63; r |= (b & 0x1F) << s; s += 5; } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0; r = 0;
      do { b = encoded.codeUnitAt(i++) - 63; r |= (b & 0x1F) << s; s += 5; } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return pts;
  }

  /// Animated route draw (gold polyline, 500ms progressive).
  Future<void> _animateRouteDraw() async {
    final polyMgr = _polyMgr;
    if (polyMgr == null || _routePoints.length < 2) return;

    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    const totalMs = 500;
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
      final count = (eased * _routePoints.length).round().clamp(2, _routePoints.length);

      if (count != lastCount) {
        lastCount = count;
        final subset = _routePoints.sublist(0, count);
        final coords = subset.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final geo = mapbox.LineString(coordinates: coords);

        if (_routeAnnot == null) {
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
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  /// Called when map is ready — apply theme, tilt, route.
  Future<void> _onMapReady(mapbox.MapboxMap ctrl) async {
    _mapCtrl = ctrl;
    await MapTheme.applyNavyGold(ctrl);
    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));

    _polyMgr = await ctrl.annotations.createPolylineAnnotationManager();
    _pointMgr = await ctrl.annotations.createPointAnnotationManager();

    // Add smart pins (pickup + dropoff)
    _addSmartPins();

    // Fit camera to show driver + pickup, then animate tilt
    final bearing = _bearingToPickup();
    final midLat = (widget.driverPos.latitude + widget.pickupLatLng.latitude) / 2;
    final midLng = (widget.driverPos.longitude + widget.pickupLatLng.longitude) / 2;

    ctrl.flyTo(
      mapbox.CameraOptions(
        center: mapbox.Point(coordinates: mapbox.Position(midLng, midLat)),
        zoom: 14.5,
        bearing: bearing,
        pitch: 0,
      ),
      mapbox.MapAnimationOptions(duration: 300),
    );
    await Future.delayed(const Duration(milliseconds: 350));
    if (!mounted) return;

    // Animate tilt 0° → 55°
    _tiltAnim.addListener(_applyMapTilt);
    _tiltCtrl.forward();

    // Wait for route to be ready, then draw it
    while (_routeFetching && mounted) {
      await Future.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted) return;
    if (_routePoints.length >= 2) {
      await _animateRouteDraw();
    }
  }

  void _applyMapTilt() {
    if (_mapCtrl == null || !mounted) return;
    _mapCtrl!.setCamera(mapbox.CameraOptions(pitch: _tiltAnim.value));
  }

  Future<void> _addSmartPins() async {
    final mgr = _pointMgr;
    if (mgr == null) return;
    // Pickup pin (person icon)
    final pickupBytes = await renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32);
    await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
        coordinates: mapbox.Position(
          widget.pickupLatLng.longitude,
          widget.pickupLatLng.latitude,
        ),
      ),
      image: pickupBytes,
      iconSize: 0.5,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
    // Dropoff pin (location icon)
    final dropoffBytes = await renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 32);
    if (!mounted) return;
    await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(
        coordinates: mapbox.Position(
          widget.dropoffLatLng.longitude,
          widget.dropoffLatLng.latitude,
        ),
      ),
      image: dropoffBytes,
      iconSize: 0.5,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
  }

  void _goToTripScreen() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      smoothFadeRoute(
        DriverTripAcceptScreen(
          tripId: widget.tripId,
          riderName: widget.riderName,
          riderPhotoUrl: widget.riderPhotoUrl ?? '',
          riderRating: widget.riderRating,
          pickupLatLng: widget.pickupLatLng,
          dropoffLatLng: widget.dropoffLatLng,
          pickupAddress: widget.pickupAddress,
          dropoffAddress: widget.dropoffAddress,
          fare: widget.fare,
          vehicleType: widget.vehicleType,
          driverPos: widget.driverPos,
          distToPickupKm: widget.distToPickupKm,
          etaMinutes: widget.etaMinutes,
          riderPhone: widget.riderPhone,
          routePoints: widget.routePoints,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: _bg,
        body: FadeTransition(
          opacity: _fadeAnim,
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Real Mapbox map background — full screen with tilt + route
              Positioned.fill(
                child: RepaintBoundary(
                  child: mapbox.MapWidget(
                    styleUri: MapboxConfig.styleDark,
                    cameraOptions: mapbox.CameraOptions(
                      center: mapbox.Point(
                        coordinates: mapbox.Position(
                          widget.pickupLatLng.longitude,
                          widget.pickupLatLng.latitude,
                        ),
                      ),
                      zoom: 14.5,
                      pitch: 0.0,
                    ),
                    onMapCreated: _onMapReady,
                    onStyleLoadedListener: (_) async {
                      if (_mapCtrl != null) await MapTheme.applyNavyGold(_mapCtrl!);
                    },
                  ),
                ),
              ),
              // Subtle dark gradient overlay (lighter than before — let map show through)
              Positioned.fill(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        Colors.black.withValues(alpha: 0.15),
                        Colors.black.withValues(alpha: 0.55),
                        Colors.black.withValues(alpha: 0.85),
                      ],
                      stops: const [0.0, 0.5, 1.0],
                    ),
                  ),
                ),
              ),
              // Content — slide up from bottom, no empty space at top
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: SlideTransition(
                  position: _slideAnim,
                  child: FadeTransition(
                    opacity: _slideFadeAnim,
                    child: SafeArea(
                      top: false,
                      child: Padding(
                        padding: EdgeInsets.fromLTRB(16, 0, 16, 16 + bottomPad),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                // ── Gold check circle ──
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 600),
                  curve: Curves.elasticOut,
                  builder: (_, scale, child) =>
                      Transform.scale(scale: scale, child: child),
                  child: Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _gold.withValues(alpha: 0.15),
                      border: Border.all(color: _gold, width: 2),
                      boxShadow: [
                        BoxShadow(
                          color: _gold.withValues(alpha: 0.3),
                          blurRadius: 24,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: _gold,
                      size: 36,
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // ── Title ──
                const Text(
                  'Viaje Aceptado',
                  style: TextStyle(
                    color: _gold,
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    letterSpacing: -0.5,
                  ),
                ),

                const SizedBox(height: 6),

                // ── Subtitle ──
                Text(
                  '${widget.riderName.split(' ').first} está esperando',
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 16,
                  ),
                ),

                const SizedBox(height: 20),

                // ── Rider info card ──
                Container(
                  decoration: BoxDecoration(
                    color: _card,
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _gold.withValues(alpha: 0.2),
                      width: 1,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.08),
                        blurRadius: 20,
                        spreadRadius: 2,
                      ),
                    ],
                  ),
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      // Rider avatar
                      VerifiedAvatar(
                        uid: widget.tripId.toString(),
                        fallbackName: widget.riderInitials,
                        photoUrl: widget.riderPhotoUrl,
                        isVerified: widget.riderVerified,
                        radius: 28,
                      ),
                      const SizedBox(width: 12),
                      // Rider info
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              widget.riderName,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                const Icon(Icons.star_rounded,
                                    color: _gold, size: 14),
                                const SizedBox(width: 4),
                                Text(
                                  widget.riderRating.toStringAsFixed(1),
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Text(
                                  '${widget.etaMinutes} min · ${widget.distToPickupKm.toStringAsFixed(1)} km',
                                  style: const TextStyle(
                                    color: Colors.white38,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // ── Pickup address pill ──
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: _gold.withValues(alpha: 0.3)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.location_on_rounded,
                          color: _gold, size: 16),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          widget.pickupAddress,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 16),

                // ── Gold progress bar (fills over 3 seconds) ──
                TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(seconds: 3),
                  curve: Curves.easeInOut,
                  builder: (_, value, __) => ClipRRect(
                    borderRadius: BorderRadius.circular(2),
                    child: LinearProgressIndicator(
                      value: value,
                      backgroundColor: Colors.white12,
                      valueColor:
                          const AlwaysStoppedAnimation<Color>(_gold),
                      minHeight: 3,
                    ),
                  ),
                ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
