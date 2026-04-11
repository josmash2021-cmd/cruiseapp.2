import 'package:flutter/material.dart';

import '../../config/feature_flags.dart';
import '../../models/airport_models.dart' show AirportSelection;
import '../../services/directions_service.dart' show RouteResult;
import '../../services/places_service.dart' show PlaceDetails;
import '../ride_request_screen.dart';

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
/// Day 1 (2026-04-11): skeleton only. When
/// [FeatureFlags.useRiderFlowShell] is false (the default), the shell is
/// never reached and the app behaves exactly as before. The real phase
/// wiring lands in Day 2 (P01-P05) and Day 3-4 (P06-P09).
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
  @override
  Widget build(BuildContext context) {
    // Safety net: even if something constructs RiderFlowShell directly
    // while the feature flag is off, we fall back to the old screen so
    // no caller ever renders a half-built shell in production.
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

    // Day 1 placeholder — Day 2 replaces this with the real shell UI
    // (single MapWidget + AnimatedSwitcher bottom sheet slot + cards).
    return const Scaffold(
      backgroundColor: Color(0xFF0A0D14),
      body: Center(
        child: Text(
          'RiderFlowShell · Day 1 skeleton',
          style: TextStyle(color: Color(0xFFE8C547), fontSize: 16),
        ),
      ),
    );
  }
}
