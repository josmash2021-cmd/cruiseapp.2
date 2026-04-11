import 'package:flutter/material.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../../config/feature_flags.dart';
import '../../config/mapbox_config.dart';
import '../../config/page_transitions.dart';
import '../../models/airport_models.dart' show AirportSelection;
import '../../models/lat_lng.dart' as model_ll;
import '../../services/directions_service.dart' show RouteResult;
import '../../services/places_service.dart' show PlaceDetails;
import '../../state/rider_trip_controller.dart';
import '../ride_request_screen.dart';
import '../rider_tracking_screen.dart';
import 'rider_flow_cards.dart';
import 'rider_flow_phase.dart';

/// Single-map rider flow shell.
///
/// Replaces the 3-screen stack
///   RideRequestScreen → SearchingDriverScreen → RiderTrackingScreen
/// with one continuous widget where a single [MapWidget] stays alive and
/// the bottom-sheet cards fade + slide between phases.
///
/// The shell OWNS the two existing state machines
/// ([RiderTripController] + [RiderTrackingController]) but **never
/// reimplements their logic**. Every backend call, listener, timer, and
/// navigator guard from the old flow is preserved — only the presentation
/// layer changes.
///
/// Day 1 (2026-04-11): file skeleton only, delegating to RideRequestScreen.
/// Day 2 (2026-04-11): state listener + meta-phase mapping + placeholder
///   cards per shell phase (P01-P05). Still no map — that lands Day 2b.
///   Flag stays off in production.
///
/// Constructor signature intentionally mirrors [RideRequestScreen] so any
/// caller that constructs one can construct the other without touching
/// the arg list — the feature flag picks the implementation.
/// Factory used by the existing rider navigation paths. Returns the
/// new [RiderFlowShell] when [FeatureFlags.useRiderFlowShell] is true
/// and the legacy [RideRequestScreen] otherwise. Call sites that used
/// to construct `RideRequestScreen(...)` can switch to
/// `riderFlowEntry(...)` once and the flag picks the implementation
/// at runtime — no call-site-by-call-site edits when we flip the flag.
Widget riderFlowEntry({
  Key? key,
  bool fastRide = false,
  bool applyPromo = false,
  bool isAirportTrip = false,
  DateTime? scheduledAt,
  AirportSelection? airportSelection,
  String? initialDropoffAddress,
  PlaceDetails? initialPickupDetails,
  PlaceDetails? initialDropoffDetails,
  String? initialPickupLabel,
  String? initialDropoffLabel,
  RouteResult? preloadedRoute,
  String? initialRideId,
}) {
  if (FeatureFlags.useRiderFlowShell) {
    return RiderFlowShell(
      key: key,
      fastRide: fastRide,
      applyPromo: applyPromo,
      isAirportTrip: isAirportTrip,
      scheduledAt: scheduledAt,
      airportSelection: airportSelection,
      initialDropoffAddress: initialDropoffAddress,
      initialPickupDetails: initialPickupDetails,
      initialDropoffDetails: initialDropoffDetails,
      initialPickupLabel: initialPickupLabel,
      initialDropoffLabel: initialDropoffLabel,
      preloadedRoute: preloadedRoute,
      initialRideId: initialRideId,
    );
  }
  return RideRequestScreen(
    key: key,
    fastRide: fastRide,
    applyPromo: applyPromo,
    isAirportTrip: isAirportTrip,
    scheduledAt: scheduledAt,
    airportSelection: airportSelection,
    initialDropoffAddress: initialDropoffAddress,
    initialPickupDetails: initialPickupDetails,
    initialDropoffDetails: initialDropoffDetails,
    initialPickupLabel: initialPickupLabel,
    initialDropoffLabel: initialDropoffLabel,
    preloadedRoute: preloadedRoute,
    initialRideId: initialRideId,
  );
}

class RiderFlowShell extends StatefulWidget {
  final bool fastRide;
  final bool applyPromo;
  final bool isAirportTrip;
  final DateTime? scheduledAt;
  final AirportSelection? airportSelection;
  final String? initialDropoffAddress;
  final PlaceDetails? initialPickupDetails;
  final PlaceDetails? initialDropoffDetails;
  final String? initialPickupLabel;
  final String? initialDropoffLabel;
  final RouteResult? preloadedRoute;
  final String? initialRideId;

  const RiderFlowShell({
    super.key,
    this.fastRide = false,
    this.applyPromo = false,
    this.isAirportTrip = false,
    this.scheduledAt,
    this.airportSelection,
    this.initialDropoffAddress,
    this.initialPickupDetails,
    this.initialDropoffDetails,
    this.initialPickupLabel,
    this.initialDropoffLabel,
    this.preloadedRoute,
    this.initialRideId,
  });

  @override
  State<RiderFlowShell> createState() => _RiderFlowShellState();
}

class _RiderFlowShellState extends State<RiderFlowShell> {
  /// The same state machine that RideRequestScreen owns. The shell
  /// NEVER reimplements its logic — it just listens + renders.
  ///
  /// Lazily created: when [FeatureFlags.useRiderFlowShell] is false we
  /// never allocate the controller or attach listeners, so wiring the
  /// shell into production call sites is zero-cost until the flag
  /// flips on.
  RiderTripController? _ctrlRef;
  RiderTripController get _ctrl => _ctrlRef!;

  RiderFlowPhase _shellPhase = RiderFlowPhase.chooseVehicle;

  // ── Mapbox — single instance alive for the whole flow ──────────────
  mapbox.MapboxMap? _map;
  mapbox.PolylineAnnotationManager? _polylineMgr;
  mapbox.PointAnnotationManager? _pointMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;
  bool _cameraFitted = false;

  // ── Tracking handoff ────────────────────────────────────────────────
  // Day 3: once the backend marks the driver as on-the-way, we push
  // the existing RiderTrackingScreen on top of the shell so its
  // battle-tested tracking logic (RTDB driver GPS, route erasing,
  // arrived/in_trip/near-destination/completed state machine) runs
  // unchanged. The shell is PRESENTATION-ONLY for P01-P05 — we do
  // NOT reimplement the tracking screen, we just reuse it from here.
  bool _trackingPushed = false;

  @override
  void initState() {
    super.initState();
    // Lazy: only spin up the controller + listeners if the shell is
    // actually going to render its own UI. When the flag is off, build()
    // delegates straight to RideRequestScreen and we must NOT allocate
    // a second controller — that would duplicate backend calls.
    if (!FeatureFlags.useRiderFlowShell) return;

    _ctrlRef = RiderTripController();
    _ctrl.addListener(_onTripStateChange);

    // Seed the controller with the same inputs RideRequestScreen would.
    // This preserves the exact pre-flow data path from the map picker.
    if (widget.isAirportTrip) {
      _ctrl.setAirportTrip(true);
    }
    if (widget.scheduledAt != null) {
      _ctrl.setSchedule(widget.scheduledAt);
    }
    if (widget.preloadedRoute != null &&
        widget.initialPickupDetails != null &&
        widget.initialDropoffDetails != null) {
      _ctrl.setPreloadedRoute(
        pickup: widget.initialPickupDetails!,
        dropoff: widget.initialDropoffDetails!,
        route: widget.preloadedRoute!,
        pickupLabel: widget.initialPickupLabel ?? '',
        dropoffLabel: widget.initialDropoffLabel ?? '',
      );
    } else {
      if (widget.initialPickupDetails != null) {
        _ctrl.setPickup(
            widget.initialPickupDetails!, widget.initialPickupLabel ?? '');
      }
      if (widget.initialDropoffDetails != null) {
        _ctrl.setDropoff(
            widget.initialDropoffDetails!, widget.initialDropoffLabel ?? '');
      }
    }
  }

  @override
  void dispose() {
    if (_ctrlRef != null) {
      _ctrl.removeListener(_onTripStateChange);
      _ctrl.dispose();
      _ctrlRef = null;
    }
    super.dispose();
  }

  /// Map the inner [RiderPhase] onto the shell meta-phase so a single
  /// switcher decides which card to render. Keeps all the business logic
  /// inside [RiderTripController] — the shell is a pure consumer.
  void _onTripStateChange() {
    if (!mounted) return;
    final innerPhase = _ctrl.state.phase;

    // Handoff: once the backend marks the driver as on-the-way, we push
    // the existing RiderTrackingScreen on top so its real-time RTDB GPS
    // + state machine runs unchanged. This is intentionally the same
    // handoff point the old RideRequestScreen uses.
    if (!_trackingPushed &&
        (innerPhase == RiderPhase.driverArriving ||
            innerPhase == RiderPhase.onTrip)) {
      _trackingPushed = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pushRiderTrackingScreen();
      });
      return;
    }

    final next = _mapInnerPhaseToShellPhase(innerPhase);
    if (next != _shellPhase) {
      setState(() => _shellPhase = next);
    }
    // Route / pickup / dropoff may arrive after the initial seed if the
    // user edits the trip in the choose-vehicle phase. Re-sync on every
    // state change — the manager caches the annotations so this is cheap.
    _syncMapAnnotations();
  }

  /// Push the existing [RiderTrackingScreen] onto the shell's navigator.
  /// Every field is read from the current [RiderTripController] state so
  /// we hand off identical data to what the old flow used to pass. When
  /// the tracking screen pops (trip completed, cancelled, or back-home),
  /// the shell pops too — the user ends up back on the home screen.
  Future<void> _pushRiderTrackingScreen() async {
    final state = _ctrl.state;
    final pickup = state.pickup;
    final dropoff = state.dropoff;
    if (pickup == null || dropoff == null) return;
    final driver = state.driver;

    final routePts = state.route?.points
        .map((p) => model_ll.LatLng(p.latitude, p.longitude))
        .toList();

    await Navigator.of(context).push(
      slideUpFadeRoute(
        RiderTrackingScreen(
          pickupLatLng: model_ll.LatLng(pickup.lat, pickup.lng),
          dropoffLatLng: model_ll.LatLng(dropoff.lat, dropoff.lng),
          routePoints: routePts,
          driverName: driver?.name ?? 'Driver',
          driverPhone: driver?.phone,
          driverRating: driver?.rating ?? 0,
          vehicleMake: driver?.vehicleMake ?? '',
          vehicleModel: driver?.vehicleModel ?? '',
          vehicleColor: driver?.vehicleColor ?? '',
          vehiclePlate: driver?.vehiclePlate ?? '',
          vehicleYear: driver?.vehicleYear ?? '',
          pickupLabel: state.pickupLabel,
          dropoffLabel: state.dropoffLabel,
          tripId: state.tripId,
          driverPhotoUrl: driver?.photoUrl,
          driverId: driver?.id,
        ),
      ),
    );
    // Tracking screen popped — trip is either completed or cancelled,
    // either way close the shell so the rider returns to home.
    if (mounted) Navigator.of(context).maybePop();
  }

  // ═══════════════════════════════════════════════════════════════
  //  Map wiring
  // ═══════════════════════════════════════════════════════════════

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _map = ctrl;
    try {
      await ctrl.scaleBar
          .updateSettings(mapbox.ScaleBarSettings(enabled: false));
      await ctrl.compass
          .updateSettings(mapbox.CompassSettings(enabled: false));
      await ctrl.attribution
          .updateSettings(mapbox.AttributionSettings(enabled: false));
      await ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
      _polylineMgr = await ctrl.annotations
          .createPolylineAnnotationManager(below: 'road-label');
      _pointMgr = await ctrl.annotations.createPointAnnotationManager();
    } catch (e) {
      debugPrint('[RiderFlowShell] map setup error: $e');
    }
    await _syncMapAnnotations();
  }

  /// Draw / refresh pickup + dropoff markers and the route polyline
  /// based on the current [RiderTripState]. Cheap — only hits Mapbox
  /// when the coordinates actually change between calls.
  Future<void> _syncMapAnnotations() async {
    if (_map == null || _polylineMgr == null || _pointMgr == null) return;
    final state = _ctrl.state;
    final pickup = state.pickup;
    final dropoff = state.dropoff;
    final route = state.route;

    // ── Route polyline ────────────────────────────────────────────
    if (route != null && route.points.length >= 2) {
      final coords = route.points
          .map((p) => mapbox.Position(p.longitude, p.latitude))
          .toList();
      try {
        if (_routeAnnot != null) {
          await _polylineMgr!.delete(_routeAnnot!);
          _routeAnnot = null;
        }
        _routeAnnot = await _polylineMgr!.create(
          mapbox.PolylineAnnotationOptions(
            geometry: mapbox.LineString(coordinates: coords),
            lineColor: 0xFFE8C547,
            lineWidth: 5.5,
            lineOpacity: 0.95,
          ),
        );
      } catch (e) {
        debugPrint('[RiderFlowShell] route draw error: $e');
      }
    }

    // ── Pickup + dropoff point annotations ────────────────────────
    try {
      if (pickup != null) {
        final p = mapbox.Point(
          coordinates: mapbox.Position(pickup.lng, pickup.lat),
        );
        if (_pickupAnnot != null) {
          _pickupAnnot!.geometry = p;
          await _pointMgr!.update(_pickupAnnot!);
        } else {
          _pickupAnnot = await _pointMgr!.create(
            mapbox.PointAnnotationOptions(
              geometry: p,
              iconAnchor: mapbox.IconAnchor.BOTTOM,
              iconSize: 1.0,
            ),
          );
        }
      }
      if (dropoff != null) {
        final p = mapbox.Point(
          coordinates: mapbox.Position(dropoff.lng, dropoff.lat),
        );
        if (_dropoffAnnot != null) {
          _dropoffAnnot!.geometry = p;
          await _pointMgr!.update(_dropoffAnnot!);
        } else {
          _dropoffAnnot = await _pointMgr!.create(
            mapbox.PointAnnotationOptions(
              geometry: p,
              iconAnchor: mapbox.IconAnchor.BOTTOM,
              iconSize: 1.0,
            ),
          );
        }
      }
    } catch (e) {
      debugPrint('[RiderFlowShell] point annot error: $e');
    }

    // ── First-fit camera to pickup + dropoff ──────────────────────
    if (!_cameraFitted && pickup != null && dropoff != null) {
      try {
        final camera = await _map!.cameraForCoordinatesPadding(
          [
            mapbox.Point(
                coordinates: mapbox.Position(pickup.lng, pickup.lat)),
            mapbox.Point(
                coordinates: mapbox.Position(dropoff.lng, dropoff.lat)),
          ],
          mapbox.CameraOptions(pitch: 35.0),
          mapbox.MbxEdgeInsets(top: 140, left: 60, bottom: 320, right: 60),
          null,
          null,
        );
        await _map!.easeTo(
          camera,
          mapbox.MapAnimationOptions(duration: 800),
        );
        _cameraFitted = true;
      } catch (e) {
        debugPrint('[RiderFlowShell] camera fit error: $e');
      }
    }
  }

  static RiderFlowPhase _mapInnerPhaseToShellPhase(RiderPhase inner) {
    switch (inner) {
      case RiderPhase.idle:
      case RiderPhase.selectingLocations:
      case RiderPhase.previewRoute:
      case RiderPhase.selectingRide:
        return RiderFlowPhase.chooseVehicle;
      case RiderPhase.requesting:
        return RiderFlowPhase.confirmingPayment;
      case RiderPhase.searchingDriver:
        return RiderFlowPhase.searchingDriver;
      case RiderPhase.driverAssigned:
        return RiderFlowPhase.driverFound;
      case RiderPhase.driverArriving:
        return RiderFlowPhase.driverEnRoute;
      case RiderPhase.onTrip:
        return RiderFlowPhase.inTrip;
      case RiderPhase.completed:
        return RiderFlowPhase.completed;
      case RiderPhase.cancelled:
        return RiderFlowPhase.cancelled;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Safety net: when the feature flag is off, ALWAYS delegate straight
    // to the existing RideRequestScreen so callers that accidentally hit
    // the shell in production get the old, battle-tested behaviour.
    if (!FeatureFlags.useRiderFlowShell) {
      return RideRequestScreen(
        fastRide: widget.fastRide,
        applyPromo: widget.applyPromo,
        isAirportTrip: widget.isAirportTrip,
        scheduledAt: widget.scheduledAt,
        airportSelection: widget.airportSelection,
        initialDropoffAddress: widget.initialDropoffAddress,
        initialPickupDetails: widget.initialPickupDetails,
        initialDropoffDetails: widget.initialDropoffDetails,
        initialPickupLabel: widget.initialPickupLabel,
        initialDropoffLabel: widget.initialDropoffLabel,
        preloadedRoute: widget.preloadedRoute,
        initialRideId: widget.initialRideId,
      );
    }

    // Day 2c — single Mapbox MapWidget + phase cards. The map is created
    // ONCE and never disposed between phases, which is the whole point of
    // the shell refactor (no per-screen style reload, no camera reset,
    // no black flash).
    final initialCenter = _ctrl.state.pickup;
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D14),
      body: Stack(
        children: [
          // ── Shared map layer ───────────────────────────────────────
          Positioned.fill(
            child: RepaintBoundary(
              child: mapbox.MapWidget(
                styleUri: MapboxConfig.styleDark,
                cameraOptions: mapbox.CameraOptions(
                  center: mapbox.Point(
                    coordinates: mapbox.Position(
                      initialCenter?.lng ?? -86.8,
                      initialCenter?.lat ?? 33.5,
                    ),
                  ),
                  zoom: 14.5,
                  pitch: 35.0,
                ),
                onMapCreated: _onMapCreated,
              ),
            ),
          ),

          // ── Bottom sheet slot — AnimatedSwitcher with fade + slide ─
          Align(
            alignment: Alignment.bottomCenter,
            child: SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                child: AnimatedSwitcher(
                  duration: const Duration(milliseconds: 320),
                  switchInCurve: Curves.easeOutCubic,
                  switchOutCurve: Curves.easeInCubic,
                  transitionBuilder: (child, anim) {
                    final slide = Tween<Offset>(
                      begin: const Offset(0, 0.08),
                      end: Offset.zero,
                    ).animate(anim);
                    return FadeTransition(
                      opacity: anim,
                      child: SlideTransition(
                        position: slide,
                        child: child,
                      ),
                    );
                  },
                  child: _buildCardForPhase(_shellPhase),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Returns the real card widget for the current shell phase. Each
  /// card is wrapped in a ValueKey(phase) so AnimatedSwitcher treats
  /// phase changes as widget replacements (triggering fade + slide).
  ///
  /// Day 6-9 (arrived / inTrip / nearDestination / completed) still
  /// fall through to the stub card — they land in Day 3-4 when the
  /// RiderTrackingController is plugged into the shell.
  Widget _buildCardForPhase(RiderFlowPhase phase) {
    switch (phase) {
      case RiderFlowPhase.chooseVehicle:
        return ChooseVehicleCard(
          key: const ValueKey(RiderFlowPhase.chooseVehicle),
          state: _ctrl.state,
          onSelect: _ctrl.selectRideOption,
          onRequest: () {
            // Fire-and-forget — the controller handles its own
            // isRequesting guard + state transitions.
            _ctrl.requestRide();
          },
        );
      case RiderFlowPhase.confirmingPayment:
        return const ConfirmingPaymentCard(
          key: ValueKey(RiderFlowPhase.confirmingPayment),
        );
      case RiderFlowPhase.searchingDriver:
        return SearchingDriverCard(
          key: const ValueKey(RiderFlowPhase.searchingDriver),
          state: _ctrl.state,
          onCancel: _ctrl.cancelRide,
        );
      case RiderFlowPhase.driverFound:
        return DriverFoundCard(
          key: const ValueKey(RiderFlowPhase.driverFound),
          state: _ctrl.state,
        );
      case RiderFlowPhase.driverEnRoute:
        return DriverEnRouteCard(
          key: const ValueKey(RiderFlowPhase.driverEnRoute),
          state: _ctrl.state,
        );
      case RiderFlowPhase.arrived:
      case RiderFlowPhase.inTrip:
      case RiderFlowPhase.nearDestination:
      case RiderFlowPhase.completed:
      case RiderFlowPhase.cancelled:
        // Placeholder until Day 3-4 plugs in the RiderTrackingController.
        return _StubCard(
          key: ValueKey(phase),
          title: _phaseLabel(phase),
          subtitle: 'Day 3-4 stub — tracking controller lands next',
        );
    }
  }

  static String _phaseLabel(RiderFlowPhase phase) {
    switch (phase) {
      case RiderFlowPhase.chooseVehicle:
        return 'P01 · Choose a ride';
      case RiderFlowPhase.confirmingPayment:
        return 'P02 · Confirming your ride…';
      case RiderFlowPhase.searchingDriver:
        return 'P03 · Finding the best driver for you…';
      case RiderFlowPhase.driverFound:
        return 'P04 · Driver found!';
      case RiderFlowPhase.driverEnRoute:
        return 'P05 · Driver on the way';
      case RiderFlowPhase.arrived:
        return 'P06 · Driver arrived';
      case RiderFlowPhase.inTrip:
        return 'P07 · Trip in progress';
      case RiderFlowPhase.nearDestination:
        return 'P08 · Almost there';
      case RiderFlowPhase.completed:
        return 'P09 · Trip completed';
      case RiderFlowPhase.cancelled:
        return 'Cancelled';
    }
  }
}

/// Minimal placeholder card used for phases that haven't been migrated
/// yet (P06-P09 — tracking phases land in Day 3-4).
class _StubCard extends StatelessWidget {
  final String title;
  final String subtitle;

  const _StubCard({super.key, required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
      decoration: BoxDecoration(
        color: const Color(0xFF0F1218),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(
          color: const Color(0xFFE8C547).withValues(alpha: 0.25),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: const TextStyle(
              color: Color(0xFFE8C547),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
