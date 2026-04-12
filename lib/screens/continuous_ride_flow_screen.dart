import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../config/api_keys.dart';
import '../config/mapbox_config.dart';
import '../l10n/app_localizations.dart';
import '../models/lat_lng.dart';
import '../services/places_service.dart';
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

  // ── Pick dropoff state ──────────────────────────────────────────
  // ignore: prefer_final_fields  — mutated by _onConfirmDropoff in next commit
  _FlowPhase _phase = _FlowPhase.pickingDropoff;
  LatLng _center = const LatLng(33.5186, -86.8104); // Pelham AL fallback
  String _dropoffAddress = '';
  bool _addressIsPlaceholder = true;
  bool _geocodingAddress = false;
  bool _geocodeFailed = false;
  Timer? _geocodeDebounce;
  int _geocodeGen = 0;

  final _places = PlacesService(ApiKeys.webServices);

  // Pin settle bounce (tiny scale pulse on map idle)
  late final AnimationController _settleCtrl;
  late final Animation<double> _settleAnim;

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
    super.dispose();
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

  /// Tap "Confirm Dropoff Location" — kicks off the transition
  /// animation in the NEXT commit. For now this is a stub so the
  /// skeleton compiles.
  void _onConfirmDropoff() {
    if (_addressIsPlaceholder || _dropoffAddress.isEmpty) return;
    // TODO: next commit — pin pop, route draw, camera fit, card fade
    debugPrint('[ContinuousRideFlow] confirm dropoff → $_dropoffAddress '
        '(${_center.latitude}, ${_center.longitude})');
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
                  } catch (_) {}
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
