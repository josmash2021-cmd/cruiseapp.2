import 'dart:math' as math;

/// Drive time the driver reads on a ride offer.
///
/// Every leg used to be clamped to 1..99 minutes. A pickup 747 road miles
/// away (the router's own time: about 11 hours) was printed as
/// "1 h 39 min (747.3 mi) away" — 450 mph — and the total ("2 h 7 min") and
/// the $/hr ("$14.45/hr") built on that 99 were wrong with it (owner report
/// 2026-11-01). A leg's minutes now always come from the same source as its
/// miles, with no ceiling.

/// The speed the straight-line fallback assumes: 17.88 m/s = 40 mph.
const double kOfferFallbackSpeedMps = 17.88;

/// Whole minutes for one leg of an offer.
///
/// [roadMinutes] is the router's duration for the same leg as [km]. When the
/// router gave no time (no route, or a distance without a duration), the
/// time is [km] at [kOfferFallbackSpeedMps] — never a flat "1 min" for a leg
/// that has a distance. At least 1, never capped above.
int offerLegMinutes({required double km, double? roadMinutes}) {
  final road = roadMinutes;
  if (road != null && road.isFinite && road > 0) {
    return math.max(1, road.ceil());
  }
  final safeKm = (km.isFinite && km > 0) ? km : 0.0;
  return math.max(1, (safeKm * 1000 / kOfferFallbackSpeedMps / 60).ceil());
}

/// The driver's whole time on the ride: drive to pickup plus the trip.
int offerTotalMinutes(int pickupMinutes, int tripMinutes) =>
    math.max(1, pickupMinutes + tripMinutes);

/// What the ride pays per hour of the driver's time — over
/// [offerTotalMinutes], so the drive to the pickup counts.
double offerPayPerHour(double fare, int totalMinutes) =>
    fare / (math.max(1, totalMinutes) / 60.0);
