/// Pricing for mid-trip route changes (multi-stop v1, 2026-08-05).
///
/// The extra is the STREET-ROUTED delta — route(origin → stop → dropoff)
/// minus route(origin → dropoff) — priced with the SAME anchored
/// per-mile / per-minute rates the trip was priced with
/// (rider_trip_controller.anchorRates — keep the two tables in sync),
/// plus a flat $2.50 stop fee that covers ~3 minutes at the curb.
///
/// A destination change uses the same delta math without the stop fee,
/// and its delta may be NEGATIVE (a closer destination refunds the
/// difference off the fare).
library;

/// (perMile, perMinute) for the pricing family a tier belongs to.
(double, double) stopRatesForTier(String? rawTier) {
  final t = (rawTier ?? '').toLowerCase().replaceAll('_', ' ').trim();
  bool hasAny(List<String> words) => words.any(t.contains);
  if (hasAny(['black', 'vip', 'suburban', 'escalade'])) return (2.75, 0.50);
  if (hasAny(['premium', 'suv', 'traverse'])) return (1.75, 0.30);
  if (hasAny(['compact', 'sedan', 'camry'])) return (1.15, 0.22);
  return (1.00, 0.20); // standard / comfort / fusion / unknown
}

/// Cents to add for an extra stop. Never below the $2.50 stop fee.
int stopExtraCents({
  required String? tier,
  required double deltaMiles,
  required int deltaMins,
}) {
  final (perMile, perMin) = stopRatesForTier(tier);
  final road = deltaMiles.clamp(0.0, 200.0) * perMile +
      deltaMins.clamp(0, 600) * perMin;
  final cents = ((road + 2.50) * 100).round();
  return cents < 250 ? 250 : cents;
}

/// Cents of fare DELTA for a destination change — signed: negative when
/// the new destination is closer than the old one.
int destinationDeltaCents({
  required String? tier,
  required double deltaMiles,
  required int deltaMins,
}) {
  final (perMile, perMin) = stopRatesForTier(tier);
  final road = deltaMiles.clamp(-200.0, 200.0) * perMile +
      deltaMins.clamp(-600, 600) * perMin;
  return (road * 100).round();
}
