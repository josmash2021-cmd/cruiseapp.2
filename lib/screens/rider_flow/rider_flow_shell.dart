import 'package:flutter/material.dart';

import '../../config/feature_flags.dart';
import '../../models/airport_models.dart' show AirportSelection;
import '../../services/directions_service.dart' show RouteResult;
import '../../services/places_service.dart' show PlaceDetails;
import '../../state/rider_trip_controller.dart';
import '../ride_request_screen.dart';
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
  final RiderTripController _ctrl = RiderTripController();

  RiderFlowPhase _shellPhase = RiderFlowPhase.chooseVehicle;

  @override
  void initState() {
    super.initState();
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
    _ctrl.removeListener(_onTripStateChange);
    _ctrl.dispose();
    super.dispose();
  }

  /// Map the inner [RiderPhase] onto the shell meta-phase so a single
  /// switcher decides which card to render. Keeps all the business logic
  /// inside [RiderTripController] — the shell is a pure consumer.
  void _onTripStateChange() {
    if (!mounted) return;
    final innerPhase = _ctrl.state.phase;
    final next = _mapInnerPhaseToShellPhase(innerPhase);
    if (next != _shellPhase) {
      setState(() => _shellPhase = next);
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

    // Day 2 — single-map shell with placeholder cards per phase.
    // The real MapWidget lands in Day 2b; for now the bottom layer is a
    // dark canvas so the AnimatedSwitcher logic can be verified in isolation.
    return Scaffold(
      backgroundColor: const Color(0xFF0A0D14),
      body: Stack(
        children: [
          // ── Map layer (placeholder for now) ────────────────────────
          const Positioned.fill(
            child: ColoredBox(color: Color(0xFF0A0D14)),
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

  /// Returns a placeholder card for the given shell phase. Day 2 uses
  /// minimal stubs so the fade/slide wiring can be smoke-tested without
  /// touching the real ride option / confirming / searching widgets.
  /// Day 2b replaces each stub with the real widget from
  /// `ride_request_widgets.dart`.
  Widget _buildCardForPhase(RiderFlowPhase phase) {
    final label = _phaseLabel(phase);
    return _StubCard(
      key: ValueKey(phase),
      title: label,
      subtitle: 'Day 2 stub — real widget lands in Day 2b',
    );
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

/// Minimal placeholder card used for the Day 2 smoke test of the
/// AnimatedSwitcher wiring. Stripped of any animation / business logic —
/// real phase cards are extracted in Day 2b.
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
