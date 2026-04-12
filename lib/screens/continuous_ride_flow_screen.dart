import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../config/api_keys.dart';
import '../config/mapbox_config.dart';
import '../l10n/app_localizations.dart';
import '../models/lat_lng.dart';
import '../services/directions_service.dart';
import '../services/places_service.dart';
import '../state/rider_trip_controller.dart' show RideOption;
import '../widgets/map/circular_pin_renderer.dart';

/// Continuous single-map rider flow that replaces the
/// map_picker → pickup_dropoff_search → home → ride_request chain with
/// ONE screen. The rider picks their dropoff on the map, the pin
/// anchors, the pickup pin pops in, the route draws smooth, the
/// choose-a-ride card fades in, and so on — all without any screen
/// push between phases.
///
/// Day 1 (2026-04-11): minimal picking-dropoff phase only. Subsequent
/// commits add the confirm animation, the choose-a-ride card, the
/// inline payment + searching overlays, and the handoff to tracking
/// when the driver is matched.
class ContinuousRideFlowScreen extends StatefulWidget {
  final double? initialLat;
  final double? initialLng;

  const ContinuousRideFlowScreen({
    super.key,
    this.initialLat,
    this.initialLng,
  });

  @override
  State<ContinuousRideFlowScreen> createState() =>
      _ContinuousRideFlowScreenState();
}

/// Phase of the continuous flow. The whole journey from map pick to
/// driver match is one state machine inside ONE widget.
enum _FlowPhase {
  /// Central pin visible, rider is moving the map to set dropoff.
  pickingDropoff,

  /// Confirm tapped — pin drop + pickup pop + route draw + camera fit
  /// animations are running. Cards fade between pickingDropoff and
  /// choosingVehicle during this phase.
  transitioning,

  /// Route drawn, choose-a-ride card visible, rider selects vehicle.
  choosingVehicle,

  /// Tap "Request Ride" — Stripe sheet + "Confirming your ride…"
  /// overlay rendered inline on the same map.
  confirmingPayment,

  /// Payment done, "Finding the best driver for you…" card with the
  /// pickup→dropoff summary + cancel button.
  searchingDriver,
}

class _ContinuousRideFlowScreenState extends State<ContinuousRideFlowScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  // ── Map ──────────────────────────────────────────────────────────
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _pointMgr;
  mapbox.PolylineAnnotationManager? _polylineMgr;
  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;
  mapbox.PolylineAnnotation? _routeAnnot;
  Uint8List? _pickupPinBytes;
  Uint8List? _dropoffPinBytes;

  // ── Pick dropoff state ──────────────────────────────────────────
  _FlowPhase _phase = _FlowPhase.pickingDropoff;
  LatLng _center = const LatLng(33.5186, -86.8104); // Pelham AL fallback
  String _dropoffAddress = '';
  bool _addressIsPlaceholder = true;
  bool _geocodingAddress = false;
  bool _geocodeFailed = false;
  Timer? _geocodeDebounce;
  int _geocodeGen = 0;

  // ── Transition state ────────────────────────────────────────────
  LatLng? _pickupLatLng;
  List<LatLng> _routePoints = [];
  RouteResult? _route;

  // ── Choose vehicle state ────────────────────────────────────────
  List<RideOption> _rideOptions = [];
  RideOption? _selectedOption;

  final _places = PlacesService(ApiKeys.webServices);
  final _directions = DirectionsService(ApiKeys.webServices);

  // Pin settle bounce (tiny scale pulse on map idle)
  late final AnimationController _settleCtrl;
  late final Animation<double> _settleAnim;

  // Progressive route draw (1.2 s ticker clamped to current slice)
  late final AnimationController _routeDrawCtrl;

  // Pickup pin pop (0 → 1.1 → 1.0 spring, 600 ms)
  late final AnimationController _pickupPopCtrl;

  @override
  void initState() {
    super.initState();
    _settleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _settleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.05), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0), weight: 50),
    ]).animate(CurvedAnimation(parent: _settleCtrl, curve: Curves.easeOut));

    _routeDrawCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..addListener(_onRouteDrawTick);

    _pickupPopCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    )..addListener(_onPickupPopTick);

    if (widget.initialLat != null && widget.initialLng != null) {
      _center = LatLng(widget.initialLat!, widget.initialLng!);
    } else {
      _resolveGpsCenter();
    }
  }

  @override
  void dispose() {
    _geocodeDebounce?.cancel();
    _settleCtrl.dispose();
    _routeDrawCtrl.dispose();
    _pickupPopCtrl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════
  //  Pin icon rasterizer — draws a simple gold circle with white
  //  border directly to bytes so Mapbox can show it as a
  //  PointAnnotation icon. No dependency on Flutter-tree rendering.
  // ═══════════════════════════════════════════════════════════════
  Future<Uint8List?> _buildPinBytes({required Color color}) async {
    const size = 64.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(
      recorder,
      const Rect.fromLTWH(0, 0, size, size),
    );
    const center = Offset(size / 2, size / 2);
    // Soft outer glow
    canvas.drawCircle(
      center,
      size / 2 - 2,
      Paint()
        ..color = color.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // White ring
    canvas.drawCircle(
      center,
      size / 2 - 6,
      Paint()..color = Colors.white,
    );
    // Gold core
    canvas.drawCircle(
      center,
      size / 2 - 10,
      Paint()..color = color,
    );
    final img = await recorder
        .endRecording()
        .toImage(size.toInt(), size.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data?.buffer.asUint8List();
  }

  /// When no initial coordinates are provided, snap to the rider's
  /// current GPS position so the picker opens on "you are here".
  Future<void> _resolveGpsCenter() async {
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 5));
      if (!mounted) return;
      _center = LatLng(pos.latitude, pos.longitude);
      final map = _map;
      if (map != null) {
        await map.flyTo(
          mapbox.CameraOptions(
            center: mapbox.Point(
              coordinates: mapbox.Position(pos.longitude, pos.latitude),
            ),
            zoom: 15.5,
          ),
          mapbox.MapAnimationOptions(duration: 800),
        );
      }
    } catch (_) {
      // GPS unavailable — stay on the default fallback
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  Pick dropoff phase — central pin + reverse geocode
  // ═══════════════════════════════════════════════════════════════

  void _onCameraChanged(mapbox.CameraChangedEventData event) {
    final map = _map;
    if (map == null) return;
    map.getCameraState().then((state) {
      final coords = state.center.coordinates;
      _center = LatLng(coords.lat.toDouble(), coords.lng.toDouble());
    });
  }

  void _onMapIdle(mapbox.MapIdleEventData event) {
    if (_phase != _FlowPhase.pickingDropoff) return;
    _settleCtrl.forward(from: 0);
    _scheduleGeocode();
  }

  void _scheduleGeocode() {
    _geocodeDebounce?.cancel();
    _geocodeDebounce =
        Timer(const Duration(milliseconds: 500), _runReverseGeocode);
  }

  Future<void> _runReverseGeocode() async {
    _geocodeDebounce?.cancel();
    if (!mounted || _phase != _FlowPhase.pickingDropoff) return;
    final gen = ++_geocodeGen;
    final snap = LatLng(_center.latitude, _center.longitude);
    if (_addressIsPlaceholder || _geocodeFailed) {
      setState(() {
        _geocodingAddress = true;
        _geocodeFailed = false;
      });
    }
    String? addr;
    for (int attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 800));
      }
      if (!mounted || gen != _geocodeGen) return;
      try {
        addr = await _places.reverseGeocode(
          lat: snap.latitude,
          lng: snap.longitude,
        );
        if (addr != null && addr.isNotEmpty) break;
      } catch (_) {}
    }
    if (!mounted || gen != _geocodeGen) return;
    setState(() {
      if (addr != null && addr.isNotEmpty) {
        _dropoffAddress = addr;
        _addressIsPlaceholder = false;
        _geocodeFailed = false;
      } else {
        _addressIsPlaceholder = true;
        _geocodeFailed = true;
      }
      _geocodingAddress = false;
    });
  }

  /// Tap "Confirm Dropoff Location" — runs the full transition
  /// sequence on the SAME map, then moves into choosingVehicle
  /// (the card renders in the next commit).
  ///
  /// Sequence:
  ///   t=0     Dropoff pin anchors as a PointAnnotation at _center
  ///   t=100   Pickup pin annotation created at GPS (scale 0) and
  ///           pop ticker starts (0 → 1.1 → 1.0 spring, 600 ms)
  ///   t=200   Route draw ticker starts (progressive polyline,
  ///           1200 ms to full length)
  ///   t=300   Camera easeTo (pitch 55° + fit pickup+dropoff with
  ///           bottom 320 px inset) — 800 ms
  ///   t=1300  Phase flips to choosingVehicle (card will fade in
  ///           once Phase 3 adds it)
  Future<void> _onConfirmDropoff() async {
    if (_addressIsPlaceholder || _dropoffAddress.isEmpty) return;
    if (_phase != _FlowPhase.pickingDropoff) return;
    if (_map == null || _pointMgr == null || _polylineMgr == null) return;

    // Snapshot dropoff coordinates before the central pin disappears.
    final dropoff = LatLng(_center.latitude, _center.longitude);

    // Resolve rider GPS for pickup. Fall back to dropoff minus a small
    // offset if GPS is unavailable so the animation still plays.
    LatLng pickup;
    try {
      final pos = await Geolocator.getCurrentPosition(
        locationSettings:
            const LocationSettings(accuracy: LocationAccuracy.high),
      ).timeout(const Duration(seconds: 4));
      pickup = LatLng(pos.latitude, pos.longitude);
    } catch (_) {
      pickup = LatLng(
        dropoff.latitude + 0.004,
        dropoff.longitude + 0.004,
      );
    }
    if (!mounted) return;

    setState(() {
      _phase = _FlowPhase.transitioning;
      _pickupLatLng = pickup;
    });

    // Fetch route. If fetching fails, synthesize a 2-point straight
    // line so the draw animation still plays and the rider can proceed.
    RouteResult? route;
    try {
      route = await _directions.getRoute(
        origin: pickup,
        destination: dropoff,
      );
    } catch (_) {}
    if (!mounted) return;
    _route = route;
    _routePoints = (route?.points != null && route!.points.length >= 2)
        ? List<LatLng>.from(route.points)
        : [pickup, dropoff];
    _rideOptions = _buildRideOptions(route);

    // ── t=0  Drop dropoff pin as a map-anchored annotation ──
    try {
      if (_dropoffPinBytes != null) {
        _dropoffAnnot = await _pointMgr!.create(
          mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
              coordinates:
                  mapbox.Position(dropoff.longitude, dropoff.latitude),
            ),
            image: _dropoffPinBytes!,
            iconAnchor: mapbox.IconAnchor.BOTTOM,
            iconSize: 1.0,
          ),
        );
      }
    } catch (e) {
      debugPrint('[ContinuousRideFlow] dropoff pin create: $e');
    }

    // ── t=100  Pickup pin at scale 0, then start the pop ticker ──
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    try {
      if (_pickupPinBytes != null) {
        _pickupAnnot = await _pointMgr!.create(
          mapbox.PointAnnotationOptions(
            geometry: mapbox.Point(
              coordinates:
                  mapbox.Position(pickup.longitude, pickup.latitude),
            ),
            image: _pickupPinBytes!,
            iconAnchor: mapbox.IconAnchor.BOTTOM,
            iconSize: 0.01,
          ),
        );
      }
    } catch (e) {
      debugPrint('[ContinuousRideFlow] pickup pin create: $e');
    }
    _pickupPopCtrl.forward(from: 0);

    // ── t=200  Start progressive route draw ──
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    _routeDrawCtrl.forward(from: 0);

    // ── t=300  Animate camera to 55° fit ──
    await Future.delayed(const Duration(milliseconds: 100));
    if (!mounted) return;
    try {
      final cam = await _map!.cameraForCoordinatesPadding(
        [
          mapbox.Point(
            coordinates:
                mapbox.Position(pickup.longitude, pickup.latitude),
          ),
          mapbox.Point(
            coordinates:
                mapbox.Position(dropoff.longitude, dropoff.latitude),
          ),
        ],
        mapbox.CameraOptions(pitch: 55.0),
        mapbox.MbxEdgeInsets(top: 120, left: 60, bottom: 320, right: 60),
        null,
        null,
      );
      await _map!.easeTo(
        cam,
        mapbox.MapAnimationOptions(duration: 800),
      );
    } catch (e) {
      debugPrint('[ContinuousRideFlow] camera fit: $e');
    }

    // ── t=1300  Transition phase to choosingVehicle ──
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    setState(() => _phase = _FlowPhase.choosingVehicle);
  }

  /// Generate the 3 ride options (VIP, Sedan, Comfort) from a route.
  /// Mirrors RiderTripController._generateRideOptions so we get the
  /// same pricing the rest of the app uses, without depending on the
  /// whole controller for the choose-vehicle phase.
  List<RideOption> _buildRideOptions(RouteResult? route) {
    if (route == null) return [];
    final mins = route.durationSeconds != null && route.durationSeconds! > 0
        ? (route.durationSeconds! / 60.0).ceil()
        : 8;
    final miles = route.distanceMeters / 1609.344;
    final baseFare = 2.50 + (miles * 1.50) + (mins * 0.25);
    final baseDuration = mins.clamp(1, 120);
    double r(double v) => (v * 100).roundToDouble() / 100;
    return [
      RideOption(
        id: 'suburban',
        name: 'VIP',
        description: 'Spacious • Leather • Snacks & Drinks',
        priceEstimate: r(baseFare * 2.20),
        etaMinutes: baseDuration + 3,
        icon: '🚐',
        capacity: 7,
      ),
      RideOption(
        id: 'camry',
        name: 'Premium',
        description: 'Comfort • Climate • Charger',
        priceEstimate: r(baseFare * 1.35),
        etaMinutes: baseDuration + 2,
        icon: '🚙',
        capacity: 4,
      ),
      RideOption(
        id: 'fusion',
        name: 'Comfort',
        description: 'Clean • Safe • Efficient',
        priceEstimate: r(baseFare),
        etaMinutes: baseDuration,
        icon: '🚗',
        capacity: 4,
      ),
    ];
  }

  /// Select a ride option from the card. Animates the camera from
  /// pitch 55° down to 15° over 600 ms, keeping the route framed
  /// above the card (bottom 320 px inset).
  Future<void> _onSelectRide(RideOption option) async {
    if (_map == null) return;
    setState(() => _selectedOption = option);
    final pickup = _pickupLatLng;
    if (pickup == null) return;
    final dropoff = LatLng(_center.latitude, _center.longitude);
    try {
      final cam = await _map!.cameraForCoordinatesPadding(
        [
          mapbox.Point(
            coordinates:
                mapbox.Position(pickup.longitude, pickup.latitude),
          ),
          mapbox.Point(
            coordinates:
                mapbox.Position(dropoff.longitude, dropoff.latitude),
          ),
        ],
        mapbox.CameraOptions(pitch: 15.0),
        mapbox.MbxEdgeInsets(top: 120, left: 60, bottom: 320, right: 60),
        null,
        null,
      );
      await _map!.easeTo(
        cam,
        mapbox.MapAnimationOptions(duration: 600),
      );
    } catch (e) {
      debugPrint('[ContinuousRideFlow] tilt camera: $e');
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  Choose-a-ride card (P03)
  // ═══════════════════════════════════════════════════════════════

  /// Returns the bottom sheet card shown during the choosingVehicle
  /// phase. Pure fade in (no slide), with each option row
  /// stagger-fading in after the container so the card feels alive.
  Widget _buildChooseRideCard() {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F1218),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: const Color(0xFFE8C547).withValues(alpha: 0.25),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.55),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 14),
            const Text(
              'Choose a ride',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            if (_rideOptions.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 20),
                child: Center(
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Color(0xFFE8C547),
                  ),
                ),
              )
            else
              ..._rideOptions.asMap().entries.map((entry) {
                final i = entry.key;
                final opt = entry.value;
                return TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: Duration(milliseconds: 300 + i * 80),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) {
                    return Opacity(opacity: t, child: child);
                  },
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _RideOptionRow(
                      option: opt,
                      selected: _selectedOption?.id == opt.id,
                      onTap: () => _onSelectRide(opt),
                    ),
                  ),
                );
              }),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFFE8C547),
                  foregroundColor: Colors.black,
                  disabledBackgroundColor:
                      const Color(0xFFE8C547).withValues(alpha: 0.35),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                  elevation: 0,
                ),
                onPressed: _selectedOption == null
                    ? null
                    : _onRequestRide,
                child: const Text(
                  'Request Ride',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Stub — Phase 4 replaces this with the real Stripe flow + inline
  /// confirming card + inline searching driver card.
  void _onRequestRide() {
    debugPrint('[ContinuousRideFlow] request ride → ${_selectedOption?.name}');
  }

  /// Pickup pin pop animation tick. Spring 0 → 1.1 → 1.0 over 600 ms
  /// pushing the iconSize of the existing PointAnnotation.
  void _onPickupPopTick() {
    final annot = _pickupAnnot;
    final mgr = _pointMgr;
    if (annot == null || mgr == null) return;
    final t = _pickupPopCtrl.value;
    double scale;
    if (t < 0.7) {
      scale = 1.1 * Curves.easeOutCubic.transform(t / 0.7);
    } else {
      scale = 1.1 - 0.1 * Curves.easeOut.transform((t - 0.7) / 0.3);
    }
    annot.iconSize = scale;
    // Fire-and-forget — the Mapbox plugin handles throttling.
    mgr.update(annot);
  }

  /// Route draw animation tick. Every frame takes the first
  /// `ceil(t * len)` points of the full route and replaces the
  /// polyline geometry so the line appears to draw itself.
  void _onRouteDrawTick() {
    final mgr = _polylineMgr;
    if (mgr == null || _routePoints.length < 2) return;
    final t = Curves.easeOutCubic.transform(_routeDrawCtrl.value);
    final n = (t * _routePoints.length)
        .ceil()
        .clamp(2, _routePoints.length);
    final slice = _routePoints.sublist(0, n);
    final coords = slice
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();
    final geometry = mapbox.LineString(coordinates: coords);
    if (_routeAnnot == null) {
      mgr
          .create(
        mapbox.PolylineAnnotationOptions(
          geometry: geometry,
          lineColor: 0xFFE8C547,
          lineWidth: 5.5,
          lineOpacity: 0.95,
        ),
      )
          .then((a) {
        if (mounted) _routeAnnot = a;
      });
    } else {
      _routeAnnot!.geometry = geometry;
      mgr.update(_routeAnnot!);
    }
  }

  // ═══════════════════════════════════════════════════════════════
  //  UI
  // ═══════════════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D14),
      body: Stack(
        children: [
          // ── Dark backdrop under the map ────────────────────────
          const Positioned.fill(
            child: ColoredBox(color: Color(0xFF0A0D14)),
          ),

          // ── Shared Mapbox layer ────────────────────────────────
          Positioned.fill(
            child: RepaintBoundary(
              child: mapbox.MapWidget(
                styleUri: MapboxConfig.styleDark,
                cameraOptions: mapbox.CameraOptions(
                  center: mapbox.Point(
                    coordinates:
                        mapbox.Position(_center.longitude, _center.latitude),
                  ),
                  zoom: 15.5,
                ),
                onMapCreated: (ctrl) async {
                  _map = ctrl;
                  try {
                    await ctrl.scaleBar
                        .updateSettings(mapbox.ScaleBarSettings(enabled: false));
                    await ctrl.compass
                        .updateSettings(mapbox.CompassSettings(enabled: false));
                    await ctrl.attribution.updateSettings(
                        mapbox.AttributionSettings(enabled: false));
                    await ctrl.logo
                        .updateSettings(mapbox.LogoSettings(enabled: false));
                    // Polyline manager BELOW road labels so street names stay
                    // readable over the route. Point manager sits on top so
                    // the pickup + dropoff pins are never hidden.
                    _polylineMgr = await ctrl.annotations
                        .createPolylineAnnotationManager(below: 'road-label');
                    _pointMgr =
                        await ctrl.annotations.createPointAnnotationManager();
                  } catch (e) {
                    debugPrint('[ContinuousRideFlow] map setup: $e');
                  }
                  // Rasterize both pin icons in the background so they are
                  // ready by the time the rider taps Confirm Dropoff.
                  _buildPinBytes(color: const Color(0xFFE8C547))
                      .then((b) => _dropoffPinBytes = b);
                  _buildPinBytes(color: const Color(0xFFE8C547))
                      .then((b) => _pickupPinBytes = b);
                  Future.delayed(
                    const Duration(milliseconds: 800),
                    _runReverseGeocode,
                  );
                },
                onCameraChangeListener: _onCameraChanged,
                onMapIdleListener: _onMapIdle,
              ),
            ),
          ),

          // ── Central pin (only in pickingDropoff phase) ─────────
          if (_phase == _FlowPhase.pickingDropoff)
            Center(
              child: Transform.translate(
                offset: const Offset(0, -23),
                child: ScaleTransition(
                  scale: _settleAnim,
                  child: const CircularMapPin(
                    size: 46,
                    icon: CircularPinIcon.flag,
                    isPickup: false,
                  ),
                ),
              ),
            ),

          // ── Top "move map to set dropoff" hint ─────────────────
          if (_phase == _FlowPhase.pickingDropoff)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 0,
              right: 0,
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0A0D14).withValues(alpha: 0.9),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: _gold.withValues(alpha: 0.25),
                    ),
                  ),
                  child: Text(
                    s.setDropoffOnMap,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),

          // ── Back button ────────────────────────────────────────
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 16,
            child: GestureDetector(
              onTap: () => Navigator.of(context).pop(),
              child: Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: const Color(0xFF0A0D14).withValues(alpha: 0.9),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.arrow_back_rounded,
                  color: Colors.white,
                  size: 22,
                ),
              ),
            ),
          ),

          // ── Bottom card — Choose a ride (fade in only) ─────────
          // Rendered when the shell leaves pickingDropoff. The whole
          // card fades in together and every option row stagger-
          // fades after the container appears (no slide on any of
          // them — the user specifically asked for pure fade).
          if (_phase == _FlowPhase.choosingVehicle ||
              _phase == _FlowPhase.confirmingPayment ||
              _phase == _FlowPhase.searchingDriver)
            Positioned(
              left: 16,
              right: 16,
              bottom: 16,
              child: SafeArea(
                top: false,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 420),
                  curve: Curves.easeOutCubic,
                  builder: (context, t, child) {
                    return Opacity(opacity: t, child: child);
                  },
                  child: _buildChooseRideCard(),
                ),
              ),
            ),

          // ── Bottom card — pick dropoff confirm ─────────────────
          if (_phase == _FlowPhase.pickingDropoff)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF0F1218),
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(24),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x4D000000),
                      blurRadius: 20,
                      offset: Offset(0, -4),
                    ),
                  ],
                ),
                child: SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 20, 12),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 40,
                          height: 4,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 16),
                        Row(
                          children: [
                            const Icon(
                              Icons.location_on_rounded,
                              color: _gold,
                              size: 22,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _geocodingAddress
                                  ? Text(
                                      s.findingAddress,
                                      style: TextStyle(
                                        color: Colors.white
                                            .withValues(alpha: 0.55),
                                        fontSize: 15,
                                      ),
                                    )
                                  : GestureDetector(
                                      onTap: _geocodeFailed
                                          ? _runReverseGeocode
                                          : null,
                                      child: Text(
                                        _addressIsPlaceholder
                                            ? s.pinnedLocation
                                            : _dropoffAddress,
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 15,
                                          fontWeight: FontWeight.w600,
                                        ),
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        SizedBox(
                          width: double.infinity,
                          height: 52,
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _gold,
                              foregroundColor: Colors.black,
                              disabledBackgroundColor:
                                  _gold.withValues(alpha: 0.35),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(26),
                              ),
                              elevation: 0,
                            ),
                            onPressed: _addressIsPlaceholder
                                ? null
                                : _onConfirmDropoff,
                            child: Text(
                              s.confirmDropoffLocation,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
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
}

/// Single ride-option row inside the Choose a ride card.
///
/// Tap animates the container's border to gold and hands control
/// back to [_onSelectRide] so the shell can run its camera tilt.
class _RideOptionRow extends StatelessWidget {
  final RideOption option;
  final bool selected;
  final VoidCallback onTap;

  const _RideOptionRow({
    required this.option,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFE8C547);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: selected
              ? gold.withValues(alpha: 0.12)
              : const Color(0xFF151820),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? gold : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          children: [
            Text(option.icon, style: const TextStyle(fontSize: 26)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    option.name,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    option.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.55),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '\$${option.priceEstimate.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: gold,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                Text(
                  '${option.etaMinutes} min',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
