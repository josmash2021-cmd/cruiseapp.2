import 'package:flutter/material.dart';

import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../models/airport_models.dart';
import '../services/places_service.dart';
import 'airline_select_screen.dart';
import 'ride_request_screen.dart';
import '../data/airport_airlines.dart';

/// The post-addresses tail of the schedule flow (2026-08-22).
///
/// Both entries into scheduling land here: the hub's datetime page and any
/// legacy path that already holds a (scheduledAt, searchResult) pair. Kept
/// out of home_screen.dart so the flow's continuation has exactly one owner.
///
/// When the dropoff is a known airport, the airline page is pushed first and
/// the pick (or Skip) travels in the [AirportSelection] the booking reads.
Future<void> continueScheduleToBooking(
  BuildContext context, {
  required DateTime scheduledAt,
  required Map<String, dynamic> searchResult,
  double? fallbackPickupLat,
  double? fallbackPickupLng,
}) async {
  final pickupDetails = searchResult['pickup'] as PlaceDetails?;
  final dropoffDetails = searchResult['dropoff'] as PlaceDetails?;
  final pickupLabel = searchResult['pickupLabel'] as String? ?? '';
  final dropoffLabel = searchResult['dropoffLabel'] as String? ?? '';
  if (dropoffDetails == null) return;

  final effectivePickup = pickupDetails ??
      (fallbackPickupLat != null && fallbackPickupLng != null
          ? PlaceDetails(
              address: pickupLabel.isNotEmpty
                  ? pickupLabel
                  : S.of(context).currentLocation,
              lat: fallbackPickupLat,
              lng: fallbackPickupLng,
            )
          : null);
  final effectiveDropoffLabel =
      dropoffLabel.isNotEmpty ? dropoffLabel : dropoffDetails.address;

  // Airport dropoff → airline select before the booking page. Skip returns
  // null and the ride books without an airline line.
  AirportSelection? airportSelection;
  final airport = detectAirportForAddress(
    '$effectiveDropoffLabel ${dropoffDetails.address}',
  );
  if (airport != null) {
    String? airline;
    await maybeShowAirlineSelect(context, airport.code, (a) => airline = a);
    if (!context.mounted) return;
    airportSelection = AirportSelection(
      airport: airport,
      direction: AirportDirection.toAirport,
      airline: airline,
    );
  }
  if (!context.mounted) return;

  Navigator.of(context).push(
    slideUpFadeRoute(
      RideRequestScreen(
        scheduledAt: scheduledAt,
        isAirportTrip: airportSelection != null,
        airportSelection: airportSelection,
        initialPickupDetails: effectivePickup,
        initialDropoffDetails: dropoffDetails,
        initialPickupLabel: pickupLabel,
        initialDropoffLabel: effectiveDropoffLabel,
        initialDropoffAddress: effectiveDropoffLabel,
        // The intermediate stop the rider added on the addresses page —
        // the booking notes carry it ("Stop: …").
        initialStopAddress: searchResult['stopAddress'] as String?,
      ),
    ),
  );
}
