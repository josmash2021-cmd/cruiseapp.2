/// Meta-phases for the single-map rider flow shell.
///
/// This enum is the shell's OWN state (separate from the inner
/// [RiderTripController] and [RiderTrackingController] state machines —
/// those continue to run unchanged). The shell listens to both inner
/// controllers and maps their RiderPhase / _TrackPhase values onto one
/// of the values below so we have a single variable that decides:
///
///   1. Which card to render in the bottom sheet slot
///   2. Which map annotations to show / hide
///   3. What camera animation to run
///
/// Mapping of inner phases → shell phase lives in
/// [RiderFlowController._mapInnerPhaseToShellPhase].
enum RiderFlowPhase {
  /// P01 — user just confirmed pickup + dropoff, the choose-vehicle card
  /// is up and the route is drawn.
  chooseVehicle,

  /// P02 — user tapped "Request Ride", the Stripe sheet is up and the
  /// "Confirming your ride…" content is visible as an overlay card.
  confirmingPayment,

  /// P03 — payment done, the "Finding the best driver for you…" card is
  /// on the map with the route still visible. Backend is dispatching.
  searchingDriver,

  /// P04 — backend matched a driver. Brief celebration overlay ("Driver
  /// found!") before transitioning to driverEnRoute.
  driverFound,

  /// P05 — driver is on their way to the pickup, live tracking of the
  /// driver's car on the map. First tracking-controller phase.
  driverEnRoute,

  /// P06 — driver arrived at pickup. The "Confirm pickup location"
  /// overlay is up so the rider can tap to confirm they're boarding.
  arrived,

  /// P07 — rider confirmed pickup, driver started the trip, car is
  /// moving along the route toward the dropoff.
  inTrip,

  /// P08 — car is close to the dropoff. Separate phase mainly so the
  /// ETA treatment can change (seconds instead of minutes, etc.).
  nearDestination,

  /// P09 — trip completed. The rating card is up in the same shell
  /// (no Navigator.pushReplacement to a separate screen anymore).
  completed,

  /// Terminal — trip was cancelled by rider, driver, dispatch, or an
  /// auto-cancel timer. Shell shows a gold toast and exits back to home.
  cancelled,
}
