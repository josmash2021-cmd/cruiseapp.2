/// The next ride a driver booked while still driving another one.
///
/// Dispatch flags an offer `chained` when it goes to a driver with an
/// active trip (backend/routers/dispatch.py). Accepting it on the trip
/// screen locks the ride on the backend inside its countdown window — but
/// the screen that would naturally remember it (DriverOnlineScreen, owner
/// of `_chainedNextOffer`) is destroyed at trip end by
/// DriverRateRiderScreen's pushAndRemoveUntil((route) => false). A static
/// store is the only thing that survives that navigation: written at
/// accept on DriverTripAcceptScreen, read when the next trip starts (rate
/// screen) or when a cancelled trip hands it back to the online screen.
///
/// One ride deep, like `_chainedNextOffer` — the backend does not offer a
/// second chained ride to a driver who already has one booked.
class ChainedRideStore {
  ChainedRideStore._();

  /// The accepted offer payload, whole — it already carries everything the
  /// next trip page needs (trip_id, offer_id, rider name/photo, both
  /// endpoints, fare, vehicle type).
  static Map<String, dynamic>? _offer;

  static bool get hasRide => _offer != null;
  static Map<String, dynamic>? get offer => _offer;

  static void set(Map<String, dynamic> offer) => _offer = offer;

  /// Read once and forget. Every consumer owns the ride from that moment;
  /// leaving it here would start the same trip twice.
  static Map<String, dynamic>? take() {
    final o = _offer;
    _offer = null;
    return o;
  }

  static void clear() => _offer = null;
}
