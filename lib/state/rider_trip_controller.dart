import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/lat_lng.dart';
import '../models/ride_quote.dart';

import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/places_service.dart';
import '../services/cache_service.dart';
import '../services/socket_service.dart';
import '../config/api_keys.dart';

export '../models/ride_quote.dart';

typedef RideQuoteFetcher = Future<Map<String, dynamic>> Function(
  Map<String, dynamic> body,
);
typedef PricingRevisionFetcher = Future<Map<String, dynamic>> Function();

// ═══════════════════════════════════════════════════════════════════
//  Rider trip phases — mirrors Uber rider flow
// ═══════════════════════════════════════════════════════════════════
enum RiderPhase {
  idle, // Home screen — "Where to?"
  selectingLocations, // Typing pickup / dropoff
  pickingLocation, // Dragging the map to drop a pin (map picker mode)
  previewRoute, // Map shows route preview
  selectingRide, // Ride options (X, Comfort, XL, Black)
  requesting, // "Looking for a driver…"
  searchingDriver, // Searching animation
  driverAssigned, // Driver matched — show info
  driverArriving, // Car moving to pickup
  onTrip, // Rider in the car
  completed, // Trip done
  cancelled, // Cancelled by rider or driver
}

// ═══════════════════════════════════════════════════════════════════
//  Driver info after match
// ═══════════════════════════════════════════════════════════════════
class MatchedDriver {
  final String id;
  final String name;
  final double rating;
  final int totalTrips;
  final String vehicleMake;
  final String vehicleModel;
  final String vehicleColor;
  final String vehiclePlate;
  final String vehicleYear;
  final String? photoUrl;
  final String phone;

  const MatchedDriver({
    required this.id,
    required this.name,
    required this.rating,
    required this.totalTrips,
    required this.vehicleMake,
    required this.vehicleModel,
    required this.vehicleColor,
    required this.vehiclePlate,
    required this.vehicleYear,
    this.photoUrl,
    this.phone = '',
  });
}

// ═══════════════════════════════════════════════════════════════════
//  State snapshot emitted by the controller
// ═══════════════════════════════════════════════════════════════════
const Object _unsetRiderValue = Object();

class RiderTripState {
  final RiderPhase phase;

  // Locations
  final PlaceDetails? pickup;
  final PlaceDetails? dropoff;
  final String pickupLabel;
  final String dropoffLabel;

  // Route and its server-side price snapshot.
  final RouteResult? route;
  final RideQuote? quote;
  final bool quoteLoading;
  final bool quoteFailed;
  final List<RideOption> rideOptions;
  final RideOption? selectedOption;

  // After match
  final MatchedDriver? driver;
  final int etaMinutes;

  // Driver location (for tracking)
  final LatLng? driverLocation;
  final double driverBearing;

  // Scheduling & airport
  final DateTime? scheduledAt;
  final bool isAirportTrip;
  final bool meetInside;

  // Airport metadata — populated when the rider comes through the
  // AirportTerminalSheet flow. Mirrors the Shopify widget's
  // createTrip/dispatch payload fields.
  final String? airportCode;
  final String? airportTerminal;
  final String? airportPickupZone; // door (from) or airline (to)
  final String? airportFlight;

  /// The rider's note for the driver ("I'm at the corner of…"), saved on
  /// the pickup-confirm page. Travels in the booking notes.
  final String? pickupNote;

  /// The optional intermediate stop chosen on the addresses page. The
  /// booking endpoint takes no stop field, so it travels in the notes
  /// ("Stop: …") — the live-trip stop endpoint stays the real-time path.
  final String? stopAddress;

  /// The stop's coordinates — the booking map draws the stop pin and the
  /// pickup → stop → dropoff route from these (the address alone is text
  /// for the notes; a pin needs a point).
  final double? stopLat;
  final double? stopLng;

  // Backend trip IDs
  final int? tripId;
  final String? firestoreTripId;

  // Cancel reason from dispatch — user-friendly message already resolved.
  final String? cancelReason;

  // Raw cancel code from the backend (e.g. "auto:no_driver_found_10min").
  // Used by the UI to branch into the smooth-toast flow vs the regular
  // cancel dialog. See RiderTripCancelCodes for the known values.
  final String? cancelCode;

  // Route fetch failed — show retry
  final bool routeFetchFailed;

  const RiderTripState({
    this.phase = RiderPhase.idle,
    this.pickup,
    this.dropoff,
    this.pickupLabel = '',
    this.dropoffLabel = '',
    this.route,
    this.quote,
    this.quoteLoading = false,
    this.quoteFailed = false,
    this.rideOptions = const [],
    this.selectedOption,
    this.driver,
    this.etaMinutes = 0,
    this.driverLocation,
    this.driverBearing = 0,
    this.scheduledAt,
    this.isAirportTrip = false,
    this.meetInside = false,
    this.airportCode,
    this.airportTerminal,
    this.airportPickupZone,
    this.airportFlight,
    this.pickupNote,
    this.stopAddress,
    this.stopLat,
    this.stopLng,
    this.tripId,
    this.firestoreTripId,
    this.cancelReason,
    this.cancelCode,
    this.routeFetchFailed = false,
  });

  RiderTripState copyWith({
    RiderPhase? phase,
    PlaceDetails? pickup,
    PlaceDetails? dropoff,
    String? pickupLabel,
    String? dropoffLabel,
    RouteResult? route,
    Object? quote = _unsetRiderValue,
    bool? quoteLoading,
    bool? quoteFailed,
    List<RideOption>? rideOptions,
    Object? selectedOption = _unsetRiderValue,
    MatchedDriver? driver,
    int? etaMinutes,
    LatLng? driverLocation,
    double? driverBearing,
    DateTime? scheduledAt,
    bool? isAirportTrip,
    bool? meetInside,
    String? airportCode,
    String? airportTerminal,
    String? airportPickupZone,
    String? airportFlight,
    String? pickupNote,
    String? stopAddress,
    double? stopLat,
    double? stopLng,
    int? tripId,
    String? firestoreTripId,
    String? cancelReason,
    String? cancelCode,
    bool? routeFetchFailed,
  }) {
    return RiderTripState(
      phase: phase ?? this.phase,
      pickup: pickup ?? this.pickup,
      dropoff: dropoff ?? this.dropoff,
      pickupLabel: pickupLabel ?? this.pickupLabel,
      dropoffLabel: dropoffLabel ?? this.dropoffLabel,
      route: route ?? this.route,
      quote:
          identical(quote, _unsetRiderValue) ? this.quote : quote as RideQuote?,
      quoteLoading: quoteLoading ?? this.quoteLoading,
      quoteFailed: quoteFailed ?? this.quoteFailed,
      rideOptions: rideOptions ?? this.rideOptions,
      selectedOption: identical(selectedOption, _unsetRiderValue)
          ? this.selectedOption
          : selectedOption as RideOption?,
      driver: driver ?? this.driver,
      etaMinutes: etaMinutes ?? this.etaMinutes,
      driverLocation: driverLocation ?? this.driverLocation,
      driverBearing: driverBearing ?? this.driverBearing,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      isAirportTrip: isAirportTrip ?? this.isAirportTrip,
      meetInside: meetInside ?? this.meetInside,
      airportCode: airportCode ?? this.airportCode,
      airportTerminal: airportTerminal ?? this.airportTerminal,
      airportPickupZone: airportPickupZone ?? this.airportPickupZone,
      airportFlight: airportFlight ?? this.airportFlight,
      pickupNote: pickupNote ?? this.pickupNote,
      stopAddress: stopAddress ?? this.stopAddress,
      stopLat: stopLat ?? this.stopLat,
      stopLng: stopLng ?? this.stopLng,
      tripId: tripId ?? this.tripId,
      firestoreTripId: firestoreTripId ?? this.firestoreTripId,
      cancelReason: cancelReason ?? this.cancelReason,
      cancelCode: cancelCode ?? this.cancelCode,
      routeFetchFailed: routeFetchFailed ?? this.routeFetchFailed,
    );
  }
}

/// Canonical cancel code identifiers used across the rider trip flow.
/// Backend codes use the `auto:` / `system:` prefix and are written
/// to trips.cancel_reason. Client-side codes use the `client:` prefix
/// and are set when the local controller fails before any server
/// commit (no internet, no session, etc.). The UI consumes these to
/// pick a localised user-friendly string and to choose between the
/// smooth toast flow vs the regular cancel dialog.
class RiderTripCancelCodes {
  // ── Backend (auto) ───────────────────────────────────────────
  static const autoNoDriver10Min = 'auto:no_driver_found_10min';
  static const autoScheduledNoDriver30Min = 'auto:scheduled_no_driver_30min';
  static const autoGuardianGhost = 'auto:guardian_ghost_stale';

  // ── Client-side error codes ──────────────────────────────────
  // These never reach the backend; they're set by the controller
  // when local prerequisites fail before the trip is even created.
  static const clientNoInternet = 'client:no_internet';
  static const clientNoSession = 'client:no_session';
  static const clientCreateFailed = 'client:create_failed';
  static const clientConnectionError = 'client:connection_error';
  static const clientPaymentDeclined = 'client:payment_declined';
  static const clientQuoteRefreshRequired = 'client:quote_refresh_required';

  /// True when the cancel was the "no driver available" timeout for an
  /// on-demand request. Gets the smooth home-screen handoff + gold toast.
  static bool isNoDriverAutoCancel(String? code) {
    if (code == null) return false;
    return code == autoNoDriver10Min || code == autoScheduledNoDriver30Min;
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Main controller
// ═══════════════════════════════════════════════════════════════════
class RiderTripController extends ChangeNotifier with WidgetsBindingObserver {
  RiderTripState _state = const RiderTripState();
  RiderTripState get state => _state;

  static const Duration _dispatchPollInterval = Duration(milliseconds: 800);
  static const Duration _quotePollInterval = Duration(seconds: 20);
  static const Duration _quoteDebounceDelay = Duration(milliseconds: 350);

  final DirectionsService _directions = DirectionsService(ApiKeys.webServices);
  final RideQuoteFetcher _quoteFetcher;
  final PricingRevisionFetcher _revisionFetcher;

  Timer? _searchTimer;
  Timer? _pollTimer;
  Timer? _timeoutTimer; // Fix 1: client-side search timeout
  Timer? _fsCancelDebounce; // Debounce timer for stale Firestore cancel events
  StreamSubscription<DocumentSnapshot>?
      _fsMatchSub; // Firestore trip doc watcher
  StreamSubscription<Map<String, dynamic>>? _pricingSub;
  Timer? _quoteDebounce;
  Timer? _quotePollTimer;
  Future<void>? _quoteInFlight;
  int _routeSeq = 0;
  int _quoteSeq = 0;
  int _revisionSeq = 0;
  int? _pricingVersion;
  String? _promotionsRevision;
  bool _quoteFrozen = false;
  String? _frozenQuoteSignature;
  bool _categoryVisible = true;
  bool _appInForeground = true;
  bool _disposed = false;
  bool _isRequesting = false; // Fix 2: anti-double-tap guard
  bool _driverMatched =
      false; // true once driver match is confirmed — blocks stale polls
  String?
      _currentStatus; // Last confirmed backend status string for transition validation
  /// True while RiderTrackingScreen is on the navigation stack.
  /// Prevents _refreshActiveTripOnResume from falsely transitioning to cancelled.
  bool isOnTrackingScreen = false;

  RiderTripController({
    RideQuoteFetcher? quoteFetcher,
    PricingRevisionFetcher? revisionFetcher,
    Stream<Map<String, dynamic>>? pricingUpdates,
  })  : _quoteFetcher = quoteFetcher ?? ApiService.createRideQuote,
        _revisionFetcher = revisionFetcher ?? ApiService.getPricingRevision {
    WidgetsBinding.instance.addObserver(this); // M3: observe lifecycle
    _pricingSub = (pricingUpdates ?? SocketService.pricingUpdatedStream)
        .listen(_onPricingUpdated);
  }

  /// Save trip state to persistent cache for instant recovery on app reopen.
  /// Triggered after every state change.
  Future<void> _saveTripStateToCache() async {
    // Save trip ID when trip is active
    final tripId = _state.tripId;
    if (tripId != null &&
        (_state.phase == RiderPhase.driverAssigned ||
        _state.phase == RiderPhase.driverArriving ||
        _state.phase == RiderPhase.onTrip)) {
      await CacheService.saveActiveTripId(tripId.toString());
      
      // Save full trip data snapshot
      final tripData = {
        'tripId': tripId,
        'phase': _state.phase.toString(),
        'pickupAddress': _state.pickup?.address,
        'pickupLat': _state.pickup?.lat,
        'pickupLng': _state.pickup?.lng,
        'dropoffAddress': _state.dropoff?.address,
        'dropoffLat': _state.dropoff?.lat,
        'dropoffLng': _state.dropoff?.lng,
        'pickupLabel': _state.pickupLabel,
        'dropoffLabel': _state.dropoffLabel,
        'driverName': _state.driver?.name,
        'driverId': _state.driver?.id,
        'etaMinutes': _state.etaMinutes,
        'createdAt': DateTime.now().toIso8601String(),
      };
      await CacheService.saveActiveTrip(tripData);
    } else if (tripId == null || 
        _state.phase == RiderPhase.completed ||
        _state.phase == RiderPhase.cancelled) {
      // Clear trip cache when no longer active
      await CacheService.clearActiveTrip();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
      _refreshActiveTripOnResume();
      _syncQuotePolling();
      unawaited(_checkPricingRevision());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.inactive ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      _appInForeground = false;
      _quoteDebounce?.cancel();
      _quotePollTimer?.cancel();
    }
    }

  void setCategorySelectionVisible(bool visible) {
    if (_categoryVisible == visible) return;
    _categoryVisible = visible;
    _syncQuotePolling();
    if (visible) unawaited(_checkPricingRevision());
  }

  Future<void> _refreshActiveTripOnResume() async {
    final tripId = _state.tripId;
    if (tripId == null) {
      return;
    } // no trip
    // Skip if the tracking screen is active — it manages its own real-time listeners
    if (isOnTrackingScreen) {
      return;
    }
    final phase = _state.phase;
    // Only refresh when actively on-trip. Skip driverAssigned/driverArriving —
    // those phases already have a confirmed match and the UI is transitioning
    // to the tracking screen. Re-checking here causes false cancellations
    // (e.g. when an FCM push triggers a lifecycle resumed event).
    if (phase != RiderPhase.onTrip) {
      return;
    }
    try {
      final status = await ApiService.getDispatchStatus(tripId);
      final tripStatus = status['status']?.toString() ?? '';
      if (tripStatus == 'completed') {
        _pollTimer?.cancel();
        _timeoutTimer?.cancel();
        _state = _state.copyWith(phase: RiderPhase.completed);
        notifyListeners();
        // Clear cache on completion
        await CacheService.clearActiveTrip();
      } else if (tripStatus == 'cancelled' || tripStatus == 'canceled') {
        _pollTimer?.cancel();
        _timeoutTimer?.cancel();
        _isRequesting = false;
        final rawReason = status['cancel_reason']?.toString();
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: _userFriendlyCancelReason(rawReason),
          cancelCode: rawReason,
        );
        notifyListeners();
        await CacheService.clearActiveTrip();
      }
    } catch (e) {
      debugPrint('⚠️ resume trip refresh failed: $e');
    }
  }

  // ─── Location selection ──────────────────────────────────────

  void setPickup(PlaceDetails place, String label) {
    final previous = _state.pickup;
    final unchanged = previous?.lat == place.lat && previous?.lng == place.lng;
    _state = _state.copyWith(pickup: place, pickupLabel: label);
    notifyListeners();
    if (!unchanged || _state.route == null) _tryFetchRoute();
  }

  void setDropoff(PlaceDetails place, String label) {
    final previous = _state.dropoff;
    final unchanged = previous?.lat == place.lat && previous?.lng == place.lng;
    _state = _state.copyWith(dropoff: place, dropoffLabel: label);
    notifyListeners();
    if (!unchanged || _state.route == null) _tryFetchRoute();
  }

  /// The driver's note from the pickup-confirm page. Empty clears — the
  /// copyWith null-coalesce cannot express "back to null", so the cleared
  /// state is the empty string and the notes composition skips empties.
  void setPickupNote(String? note) {
    _state = _state.copyWith(pickupNote: note?.trim() ?? '');
    notifyListeners();
  }

  /// The intermediate stop from the addresses page (same clearing rule as
  /// the note: empty string, not null). lat/lng ride along so the booking
  /// map can pin the stop and route through it.
  void setStopAddress(String? address, {double? lat, double? lng}) {
    _state = _state.copyWith(
      stopAddress: address?.trim() ?? '',
      stopLat: lat,
      stopLng: lng,
    );
    notifyListeners();
    _tryFetchRoute();
  }

  /// The stop as a point, or null when there is none (or only the text
  /// address — a pin and a route leg need real coordinates).
  LatLng? get stopPoint {
    final a = _state.stopAddress ?? '';
    final lat = _state.stopLat;
    final lng = _state.stopLng;
    if (a.isEmpty || lat == null || lng == null) return null;
    return LatLng(lat, lng);
  }

  /// Retry fetching the route after a failure.
  void retryFetchRoute() => _tryFetchRoute();

  /// Set a pre-fetched route directly; pricing still comes from the server.
  void setPreloadedRoute({
    required PlaceDetails pickup,
    required String pickupLabel,
    required PlaceDetails dropoff,
    required String dropoffLabel,
    required RouteResult route,
  }) {
    _routeSeq++;
    _state = _state.copyWith(
      pickup: pickup,
      pickupLabel: pickupLabel,
      dropoff: dropoff,
      dropoffLabel: dropoffLabel,
      route: route,
      phase: RiderPhase.previewRoute,
      routeFetchFailed: false,
    );
    _restartQuoteForInputs();
  }

  void startLocationSelection() {
    _state = _state.copyWith(phase: RiderPhase.selectingLocations);
    notifyListeners();
  }

  /// Drop into the in-place map picker — keeps the same Mapbox canvas
  /// alive while the user drags the map under a fixed center pin.
  void startPickingLocation() {
    _state = _state.copyWith(phase: RiderPhase.pickingLocation);
    notifyListeners();
  }

  /// Leave the in-place map picker after a confirmed pick. _tryFetchRoute
  /// deliberately keeps pickingLocation now (its flip was the mid-drag
  /// camera snap), so the picker's Confirm exits through here instead.
  void finishPickingLocation() {
    if (_state.phase != RiderPhase.pickingLocation) return;
    _state = _state.copyWith(phase: RiderPhase.previewRoute);
    notifyListeners();
    _syncQuotePolling();
  }

  void setSchedule(DateTime? dateTime) {
    if (_state.scheduledAt == dateTime) return;
    _state = _state.copyWith(scheduledAt: dateTime);
    _restartQuoteForInputs();
  }

  /// Stash all the airport metadata at once so the dispatch call can
  /// include code/terminal/pickup_zone/flight on the payload.
  void setAirportMetadata({
    required bool isAirport,
    String? code,
    String? terminal,
    String? pickupZone,
    String? flight,
  }) {
    _state = _state.copyWith(
      isAirportTrip: isAirport,
      airportCode: code,
      airportTerminal: terminal,
      airportPickupZone: pickupZone,
      airportFlight: flight,
    );
    _restartQuoteForInputs();
  }

  /// Wipe airport metadata back to null / false. Call this whenever a
  /// fresh, non-airport ride is started so the previous airport trip's
  /// code / terminal / flight don't leak into the new dispatch payload.
  void clearAirportMetadata() {
    if (!_state.isAirportTrip &&
        !_state.meetInside &&
        _state.airportCode == null &&
        _state.airportTerminal == null &&
        _state.airportPickupZone == null &&
        _state.airportFlight == null) {
      return; // already clean
    }
    _state = RiderTripState(
      phase: _state.phase,
      pickup: _state.pickup,
      dropoff: _state.dropoff,
      pickupLabel: _state.pickupLabel,
      dropoffLabel: _state.dropoffLabel,
      route: _state.route,
      driver: _state.driver,
      etaMinutes: _state.etaMinutes,
      driverLocation: _state.driverLocation,
      driverBearing: _state.driverBearing,
      scheduledAt: _state.scheduledAt,
      isAirportTrip: false,
      pickupNote: _state.pickupNote,
      stopAddress: _state.stopAddress,
      stopLat: _state.stopLat,
      stopLng: _state.stopLng,
      tripId: _state.tripId,
      firestoreTripId: _state.firestoreTripId,
      cancelReason: _state.cancelReason,
      cancelCode: _state.cancelCode,
      routeFetchFailed: _state.routeFetchFailed,
    );
    _restartQuoteForInputs();
  }

  void setAirportTrip(bool isAirport) {
    if (_state.isAirportTrip == isAirport) return;
    _state = _state.copyWith(isAirportTrip: isAirport);
    _restartQuoteForInputs();
  }

  void setMeetInside(bool value) {
    if (_state.meetInside == value) return;
    _state = _state.copyWith(meetInside: value);
    _restartQuoteForInputs();
  }

  // ─── Route preview ──────────────────────────────────────────

  Future<void> _tryFetchRoute() async {
    if (_state.pickup == null || _state.dropoff == null) return;

    final requestSeq = ++_routeSeq;
    final origin = LatLng(_state.pickup!.lat, _state.pickup!.lng);
    final dest = LatLng(_state.dropoff!.lat, _state.dropoff!.lng);
    // A stop makes the route origin → stop → destination, one continuous
    // line (user spec: "se dibujara asi de esa forma continua").
    final stop = stopPoint;
    final waypoints = stop == null ? null : [stop];

    final estimatedRoute = _directions.getEstimatedRoute(
      origin: origin,
      destination: dest,
      waypoints: waypoints,
    );
    final airportTrip = _state.airportCode != null ||
        _isAirport(_state.pickupLabel) ||
        _isAirport(_state.dropoffLabel);
    _state = _state.copyWith(
      // Never flip the phase out of the map picker: that flip mid-drag
      // unmounted the picker overlays and fired the route-fit flight
      // behind the rider's finger (the picker "snap back"). The picker's
      // Confirm exits via finishPickingLocation() instead.
      phase: switch (_state.phase) {
        RiderPhase.pickingLocation => RiderPhase.pickingLocation,
        // Post-request phases must survive a late route refetch — flipping
        // back to previewRoute here resurrected the vehicle sheet while the
        // trip was already dispatched (build 587 bug).
        RiderPhase.requesting ||
        RiderPhase.searchingDriver ||
        RiderPhase.driverAssigned ||
        RiderPhase.driverArriving ||
        RiderPhase.onTrip =>
          _state.phase,
        _ => RiderPhase.previewRoute,
      },
      route: estimatedRoute,
      isAirportTrip: airportTrip,
      routeFetchFailed: false,
    );
    _restartQuoteForInputs();

    try {
      final routeResult = await _directions.getRoute(
        origin: origin,
        destination: dest,
        waypoints: waypoints,
      );
      if (_disposed || requestSeq != _routeSeq) return;
      if (routeResult == null) {
        _state = _state.copyWith(routeFetchFailed: true);
      } else {
        _state = _state.copyWith(
          phase: switch (_state.phase) {
            RiderPhase.pickingLocation => RiderPhase.pickingLocation,
            RiderPhase.requesting ||
            RiderPhase.searchingDriver ||
            RiderPhase.driverAssigned ||
            RiderPhase.driverArriving ||
            RiderPhase.onTrip =>
              _state.phase,
            _ => RiderPhase.previewRoute,
          },
          route: routeResult,
          routeFetchFailed: false,
        );
      }
          notifyListeners();
    } catch (e) {
      if (_disposed || requestSeq != _routeSeq) return;
      debugPrint('[RiderTrip] route fetch failed: $e');
        _state = _state.copyWith(routeFetchFailed: true);
        notifyListeners();
      }
  }

  static bool _isAirport(String label) {
    final l = label.toLowerCase();
    return l.contains('airport') ||
        l.contains('aeropuerto') ||
        l.contains('intl') ||
        l.contains('terminal') ||
        l.contains('aviation') ||
        RegExp(r'\b(mia|jfk|lax|atl|ord|dfw|bhm|sfo|ewr|lga)\b').hasMatch(l);
  }

  int _routeDurationMinutes(RouteResult? route) {
    if (route == null) return 0;
    final seconds = route.durationSeconds;
    if (seconds != null && seconds > 0) return (seconds / 60).ceil();
    return _parseDurationMinutes(route.durationText);
    }

  List<RideOption> _placeholderRideOptions() {
    final duration = _routeDurationMinutes(_state.route);
    return [
      RideOption(
        id: 'suburban',
        name: 'VIP',
        description: 'Spacious • Leather • Snacks & Drinks',
        priceEstimate: 0,
        etaMinutes: duration == 0 ? 0 : duration + 3,
        icon: '🚐',
        capacity: 7,
      ),
      RideOption(
        id: 'suv_xl',
        name: 'SUV XL',
        description: 'Up to 6 • XL luggage • Climate',
        priceEstimate: 0,
        etaMinutes: duration == 0 ? 0 : duration + 2,
        icon: '🚙',
        capacity: 6,
      ),
      RideOption(
        id: 'electric_pro',
        name: 'Electric Pro',
        description: 'Electric • Zero emissions • Silent ride',
        priceEstimate: 0,
        etaMinutes: duration == 0 ? 0 : duration + 2,
        icon: '⚡',
        capacity: 5,
      ),
      RideOption(
        id: 'camry',
        name: 'Sedan',
        description: 'Comfort • Climate • Charger',
        priceEstimate: 0,
        etaMinutes: duration == 0 ? 0 : duration + 2,
        icon: '🚙',
        capacity: 4,
      ),
      RideOption(
        id: 'fusion',
        name: 'Comfort',
        description: 'Clean • Safe • Efficient',
        priceEstimate: 0,
        etaMinutes: duration,
        icon: '🚗',
        capacity: 4,
      ),
    ];
  }

  bool get _hasQuoteEndpoints =>
      _state.pickup != null && _state.dropoff != null;

  void _restartQuoteForInputs() {
    _quoteFrozen = false;
    _frozenQuoteSignature = null;
    _quoteSeq++;
    _quoteDebounce?.cancel();
    final options = _placeholderRideOptions();
    final selectedId = _state.selectedOption?.id;
    RideOption? selected;
    for (final option in options) {
      if (option.id == selectedId) selected = option;
    }
    _state = _state.copyWith(
      quote: null,
      quoteLoading: _hasQuoteEndpoints,
      quoteFailed: false,
      rideOptions: options,
      selectedOption: selected,
    );
    notifyListeners();
    if (_hasQuoteEndpoints) {
      _scheduleQuoteRefresh();
    } else {
      _syncQuotePolling();
    }
  }

  double _quoteCoordinate(double value) =>
      double.parse(value.toStringAsFixed(6));

  Map<String, dynamic>? _quoteBody() {
    final pickup = _state.pickup;
    final dropoff = _state.dropoff;
    if (pickup == null || dropoff == null) return null;
    final stopLat = _state.stopLat;
    final stopLng = _state.stopLng;
    return <String, dynamic>{
      'pickup_lat': _quoteCoordinate(pickup.lat),
      'pickup_lng': _quoteCoordinate(pickup.lng),
      'dropoff_lat': _quoteCoordinate(dropoff.lat),
      'dropoff_lng': _quoteCoordinate(dropoff.lng),
      if (stopLat != null && stopLng != null) ...{
        'stop_lat': _quoteCoordinate(stopLat),
        'stop_lng': _quoteCoordinate(stopLng),
      },
      'is_scheduled': _state.scheduledAt != null,
      'is_airport': _state.isAirportTrip,
      'meet_inside': _state.meetInside,
    };
  }

  String _quoteSignature(Map<String, dynamic> body) => <Object?>[
        body['pickup_lat'],
        body['pickup_lng'],
        body['dropoff_lat'],
        body['dropoff_lng'],
        body['stop_lat'],
        body['stop_lng'],
        body['is_scheduled'],
        body['is_airport'],
        body['meet_inside'],
      ].join('|');

  bool get _canAutoRefreshQuote =>
      !_disposed &&
      !_quoteFrozen &&
      _appInForeground &&
      _categoryVisible &&
      _hasQuoteEndpoints &&
      (_state.phase == RiderPhase.previewRoute ||
          _state.phase == RiderPhase.selectingRide);

  void _onPricingUpdated(Map<String, dynamic> _) {
    if (_canAutoRefreshQuote) _scheduleQuoteRefresh();
  }

  void _syncQuotePolling() {
    _quotePollTimer?.cancel();
    if (!_canAutoRefreshQuote) return;
    _quotePollTimer = Timer.periodic(_quotePollInterval, (_) {
      unawaited(_checkPricingRevision());
    });
  }

  void _scheduleQuoteRefresh() {
    if (_disposed || _quoteFrozen) return;
    _quoteDebounce?.cancel();
    _quoteDebounce = Timer(_quoteDebounceDelay, () {
      if (!_disposed && !_quoteFrozen) unawaited(refreshQuote());
    });
  }

  Future<void> refreshQuote() {
    _quoteDebounce?.cancel();
    return _requestQuote();
  }

  Future<void> _requestQuote() {
    final body = _quoteBody();
    if (body == null) return Future.value();
    final signature = _quoteSignature(body);
    final requestSeq = ++_quoteSeq;
    if (_state.quote == null && !_state.quoteLoading) {
      _state = _state.copyWith(quoteLoading: true, quoteFailed: false);
      notifyListeners();
    }
    final future = _fetchAndApplyQuote(body, signature, requestSeq);
    _quoteInFlight = future;
    return future;
  }

  Future<void> _fetchAndApplyQuote(
    Map<String, dynamic> body,
    String signature,
    int requestSeq,
  ) async {
    try {
      final response = await _quoteFetcher(body);
      final quote = RideQuote.fromJson(response);
      final options = rideOptionsFromQuote(response);
      if (options.isEmpty || options.any((option) => !option.hasServerPrice)) {
        throw const FormatException('Quote is missing usable tier prices');
      }
      if (_disposed ||
          requestSeq != _quoteSeq ||
          signature != _quoteSignature(_quoteBody() ?? const {})) {
        return;
      }
      final selectedId = _state.selectedOption?.id;
      RideOption? selected;
      for (final option in options) {
        if (option.id == selectedId) selected = option;
      }
      _pricingVersion = quote.pricingVersion;
      _state = _state.copyWith(
        quote: quote,
        quoteLoading: false,
        quoteFailed: false,
        rideOptions: options,
        selectedOption: selected,
      );
      notifyListeners();
      unawaited(_checkPricingRevision());
    } catch (e) {
      if (_disposed || requestSeq != _quoteSeq) return;
      debugPrint('[RiderTrip] quote fetch failed: $e');
      _state = _state.copyWith(quoteLoading: false, quoteFailed: true);
      notifyListeners();
    } finally {
      if (requestSeq == _quoteSeq) {
        _quoteInFlight = null;
        _syncQuotePolling();
      }
    }
  }

  Future<void> _checkPricingRevision() async {
    if (_disposed || _quoteFrozen) return;
    final requestSeq = ++_revisionSeq;
    try {
      final response = await _revisionFetcher();
      if (_disposed || requestSeq != _revisionSeq || _quoteFrozen) return;
      final version = (response['pricing_version'] as num?)?.toInt();
      final promotions = response['promotions_revision']?.toString() ?? '0';
      final pricingChanged = _state.quote != null &&
          _pricingVersion != null &&
          version != _pricingVersion;
      final promotionsChanged =
          _promotionsRevision != null && promotions != _promotionsRevision;
      _promotionsRevision = promotions;
      final expiring = _state.quote?.expiresWithin(
            const Duration(seconds: 60),
          ) ??
          false;
      if (_canAutoRefreshQuote &&
          (pricingChanged || promotionsChanged || expiring)) {
        _scheduleQuoteRefresh();
      }
    } catch (e) {
      if (!_disposed && requestSeq == _revisionSeq) {
        debugPrint('[RiderTrip] pricing revision failed: $e');
      }
    }
  }

  Future<bool> prepareQuoteForConfirmation() async {
    _quoteDebounce?.cancel();
    for (var attempt = 0; attempt < 2; attempt++) {
      final inFlight = _quoteInFlight;
      if (inFlight != null) await inFlight;
      final quote = _state.quote;
      final option = _state.selectedOption;
      final body = _quoteBody();
      if (quote != null &&
          option != null &&
          option.hasServerPrice &&
          !_state.quoteFailed &&
          body != null &&
          !quote.expiresWithin(const Duration(seconds: 60))) {
        _quoteFrozen = true;
        _frozenQuoteSignature = _quoteSignature(body);
        _quotePollTimer?.cancel();
        return true;
      }
      if (attempt == 0 && body != null) await _requestQuote();
    }
    return false;
  }

  void releaseQuoteConfirmation() {
    _quoteFrozen = false;
    _frozenQuoteSignature = null;
    _syncQuotePolling();
  }

  bool get hasFrozenQuoteForConfirmation {
    final body = _quoteBody();
    return _quoteFrozen &&
        body != null &&
        _frozenQuoteSignature == _quoteSignature(body) &&
        _state.quote != null &&
        !_state.quote!.expiresWithin(Duration.zero);
  }

  int _parseDurationMinutes(String text) {
    // "12 min" or "1 h 5 min"
    final parts = text.split(RegExp(r'\s+'));
    int total = 0;
    for (int i = 0; i < parts.length; i++) {
      final n = int.tryParse(parts[i]);
      if (n != null && i + 1 < parts.length) {
        if (parts[i + 1].startsWith('h')) {
          total += n * 60;
        } else {
          total += n;
        }
      }
    }
    return total > 0 ? total : 10;
  }

  // ─── Ride selection ─────────────────────────────────────────

  void showRideOptions() {
    _state = _state.copyWith(phase: RiderPhase.selectingRide);
    notifyListeners();
    _syncQuotePolling();
    if (_state.quote == null && !_state.quoteLoading) {
      _restartQuoteForInputs();
    }
  }

  void selectRideOption(RideOption option) {
    _state = _state.copyWith(selectedOption: option);
    notifyListeners();
  }

  // ─── Request ride ───────────────────────────────────────────

  String? _heldPaymentIntentId;
  void setHeldPaymentIntentId(String? id) => _heldPaymentIntentId = id;

  Future<void> requestRide() async {
    // Fix 2: prevent double-tap from spawning duplicate requests
    if (_isRequesting) return;
    _isRequesting = true;
    _driverMatched = false; // Reset for new ride request

    // Fix 4: validate GPS coords before sending to backend
    final pickup = _state.pickup;
    final dropoff = _state.dropoff;
    if (pickup == null || dropoff == null) {
      _isRequesting = false;
      notifyListeners();
      return;
    }
    if ((pickup.lat == 0.0 && pickup.lng == 0.0) ||
        (dropoff.lat == 0.0 && dropoff.lng == 0.0)) {
      _isRequesting = false;
      notifyListeners();
      return;
    }

    // Save pre-request state for rollback on error
    final previousPhase = _state.phase;
    final prepared = await prepareQuoteForConfirmation();
    if (!prepared || !hasFrozenQuoteForConfirmation) {
      _isRequesting = false;
      releaseQuoteConfirmation();
      _state = _state.copyWith(
        cancelReason:
            'Prices changed or are unavailable. Refresh them and try again.',
        cancelCode: RiderTripCancelCodes.clientQuoteRefreshRequired,
      );
      notifyListeners();
      return;
    }
    final previousOption = _state.selectedOption;

    _state = _state.copyWith(phase: RiderPhase.requesting);
    notifyListeners();

    // Transition to searching UI immediately — no artificial delay
    _state = _state.copyWith(phase: RiderPhase.searchingDriver);
    notifyListeners();

    // Call backend dispatch
    // _pollingStarted = true means _isRequesting stays true while polling runs;
    // finally resets it only when polling never started (any early-exit path).
    bool pollingStarted = false;
    try {
      // Parallel: connectivity + userId check
      final checks = await Future.wait([
        ApiService.isOnline(),
        ApiService.getCurrentUserId(),
      ]);
      final online = checks[0] as bool;
      final userId = checks[1] as int?;

      if (!online) {
        // Localised message is set by the UI layer via cancelCode in
        // _userFriendlyCancelReason. The cancelReason field carries a
        // canonical English fallback for callers that don't translate.
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason:
              'No internet connection. Check your network and try again.',
          cancelCode: RiderTripCancelCodes.clientNoInternet,
        );
        notifyListeners();
        return;
      }
      if (userId == null) {
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: 'Could not verify your session. Please try again.',
          cancelCode: RiderTripCancelCodes.clientNoSession,
        );
        notifyListeners();
        return;
      }

      // Resolve addresses — reverse geocode if label is missing or generic
      var pickupAddr = _state.pickupLabel;
      var dropoffAddr = _state.dropoffLabel;
      final places = PlacesService(ApiKeys.webServices);
      if (pickupAddr.isEmpty ||
          pickupAddr.toLowerCase() == 'current location') {
        try {
          final resolved =
              await places.reverseGeocode(lat: pickup.lat, lng: pickup.lng);
          if (resolved != null && resolved.isNotEmpty) pickupAddr = resolved;
        } catch (_) {}
      }
      if (dropoffAddr.isEmpty ||
          dropoffAddr.toLowerCase() == 'current location') {
        try {
          final resolved =
              await places.reverseGeocode(lat: dropoff.lat, lng: dropoff.lng);
          if (resolved != null && resolved.isNotEmpty) dropoffAddr = resolved;
        } catch (_) {}
      }

      final flight = _state.airportFlight?.trim();
      // Booking notes carry everything the driver must read: the optional
      // intermediate stop, the flight number, and the rider's pickup note.
      final noteLines = <String>[
        if ((_state.stopAddress ?? '').isNotEmpty)
          'Stop: ${_state.stopAddress}',
        if (flight != null && flight.isNotEmpty) 'Flight: $flight',
        if ((_state.pickupNote ?? '').isNotEmpty) _state.pickupNote!,
      ];
      final notes = noteLines.isEmpty ? null : noteLines.join('\n');

      final result = await ApiService.dispatchRideRequest(
        riderId: userId,
        pickupAddress: pickupAddr.isNotEmpty ? pickupAddr : 'current location',
        dropoffAddress:
            dropoffAddr.isNotEmpty ? dropoffAddr : 'current location',
        pickupLat: pickup.lat,
        pickupLng: pickup.lng,
        dropoffLat: dropoff.lat,
        dropoffLng: dropoff.lng,
        quoteId: _state.quote!.id,
        vehicleType: _state.selectedOption!.canonicalTier,
        isAirport: _state.isAirportTrip,
        meetInside: _state.meetInside,
        airportCode: _state.airportCode,
        terminal: _state.airportTerminal,
        pickupZone: _state.airportPickupZone,
        notes: notes,
        stripePaymentIntentId: _heldPaymentIntentId,
        stopLat: _state.stopLat,
        stopLng: _state.stopLng,
        stopAddress:
            (_state.stopAddress ?? '').isNotEmpty ? _state.stopAddress : null,
      );

      final tripId = result['trip_id'] as int?;
      if (tripId == null) {
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: 'Could not create the trip. Please try again.',
          cancelCode: RiderTripCancelCodes.clientCreateFailed,
        );
        notifyListeners();
        return;
      }

      _state = _state.copyWith(tripId: tripId);
      notifyListeners();
      
      // Save trip to cache immediately on creation
      await _saveTripStateToCache();

      // Poll dispatch status until a driver accepts
      _startDispatchPolling(tripId);
      pollingStarted = true; // guard: keep _isRequesting=true while polling
    } catch (e) {
      debugPrint('dispatchRideRequest failed: $e');
      // 402 = the backend rejected the hold (missing/failed PaymentIntent).
      // Surface it as a payment decline, not a generic connection error, so
      // the rider fixes their card instead of retrying a doomed request.
      final apiErr = e is ApiException ? e : null;
      final isPaymentDeclined = apiErr?.statusCode == 402;
      final requiresRequote = apiErr?.statusCode == 409;
      if (requiresRequote) {
        releaseQuoteConfirmation();
        final staleHold = _heldPaymentIntentId;
        _heldPaymentIntentId = null;
        if (staleHold != null) {
          unawaited(ApiService.cancelPaymentIntent(staleHold));
        }
        _state = _state.copyWith(
          phase: previousPhase,
          quote: null,
          quoteLoading: true,
          quoteFailed: false,
          cancelReason:
              'Prices changed or expired. Review the refreshed price and try again.',
          cancelCode: RiderTripCancelCodes.clientQuoteRefreshRequired,
        );
        notifyListeners();
        await refreshQuote();
        return;
      }
      // Rollback to previous state so rider can retry
      _state = _state.copyWith(
        phase: previousPhase,
        selectedOption: previousOption,
        cancelReason: isPaymentDeclined
            ? apiErr!.message
            : 'Connection error. Check your network and try again.',
        cancelCode: isPaymentDeclined
            ? RiderTripCancelCodes.clientPaymentDeclined
            : RiderTripCancelCodes.clientConnectionError,
      );
      notifyListeners();
    } finally {
      // Reset only if polling never started — polling callbacks own the flag
      if (!pollingStarted) _isRequesting = false;
    }
  }

  /// Returns true if transitioning from [from] status to [to] status is valid.
  /// Prevents invalid status regressions caused by stale Firestore updates.
  bool _isValidTransition(String? from, String to) {
    // Terminal states cannot transition to anything else
    if (from == 'completed' || from == 'cancelled' || from == 'canceled')
      return false;
    // Ordered status progression
    const order = [
      'searching',
      'accepted',
      'driver_en_route',
      'driver_arrived',
      'in_progress',
      'completed'
    ];
    final fromIdx = order.indexOf(from ?? '');
    final toIdx = order.indexOf(to);
    // If either status is unknown (e.g. 'cancelled'), allow — other guards handle it
    if (fromIdx == -1 || toIdx == -1) return true;
    return toIdx >= fromIdx;
  }

  void _startDispatchPolling(int tripId) {
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    _fsCancelDebounce?.cancel();
    _fsMatchSub?.cancel();

    // ── Firestore real-time listener: instant detection when driver accepts ──
    // Fires within ~100ms of driver writing to Firestore, bypassing HTTP latency.
    bool fsFirstEvent = true;
    _fsMatchSub = FirebaseFirestore.instance
        .collection('trips')
        .doc('sql_$tripId')
        .snapshots()
        .listen((snap) {
      if (_driverMatched) return;
      final data = snap.data();
      if (data == null) return;
      final status = (data['status']?.toString() ?? '').toLowerCase();

      // First snapshot guard: skip only pre-match baseline states.
      // Do NOT skip if the driver has already accepted (fast-accept race condition).
      if (fsFirstEvent) {
        fsFirstEvent = false;
        if (status == 'searching' ||
            status == 'pending' ||
            status == 'requested' ||
            status == 'cancelled' ||
            status == 'canceled' ||
            status.isEmpty) return;
        // status == 'accepted' or 'driver_en_route' on first event → fall through and process
      }
      // State machine: reject invalid status regressions (e.g. stale cancelled after match)
      if (!_isValidTransition(_currentStatus, status)) {
        debugPrint(
            '[RiderTrip] Firestore: ignoring invalid transition $_currentStatus → $status');
        return;
      }
      if (status == 'accepted' || status == 'driver_en_route') {
        debugPrint('🔴 Firestore trip doc: status=$status → driver matched!');
        _currentStatus = status;
        _fsMatchSub?.cancel();
        _pollTimer?.cancel();
        _timeoutTimer?.cancel();
        _isRequesting = false;
        try {
          _onDriverMatched(data, tripId);
        } catch (e) {
          debugPrint(
              '⚠️ _onDriverMatched from Firestore threw: $e — restarting poll');
          _driverMatched = false;
          _startDispatchPolling(tripId);
        }
      } else if (status == 'cancelled' || status == 'canceled') {
        // Guard A: ignore stale cancellation if driver was already matched
        if (_driverMatched) return;
        // Guard B: debounce 100ms to let a real 'driver_en_route' event win the race
        _fsCancelDebounce?.cancel();
        _fsCancelDebounce = Timer(const Duration(milliseconds: 100), () {
          // Re-check after debounce — driver may have arrived in the meantime
          if (_driverMatched) return;
          _currentStatus = status;
          _fsMatchSub?.cancel();
          _pollTimer?.cancel();
          _timeoutTimer?.cancel();
          _isRequesting = false;
          // Pull the real cancel_reason from the Firestore doc so the UI
          // can branch into the smooth-toast flow when it's an auto-cancel.
          // The snapshot data (`data`) is the raw Firestore map —
          // `_currentStatus` is just the status string, not the doc.
          final rawReason =
              (data['cancelReason'] ?? data['cancel_reason'])?.toString();
          _state = _state.copyWith(
            phase: RiderPhase.cancelled,
            cancelReason: _userFriendlyCancelReason(rawReason),
            cancelCode: rawReason,
          );
          notifyListeners();
          unawaited(CacheService.clearActiveTrip());
        });
      }
    }, onError: (e) {
      debugPrint('[RiderTrip] Firestore match listener error: $e');
    });

    // Safety-net timeout — 10 minutes max searching then show the
    // "no drivers available" smooth-toast flow. Matches the backend
    // auto-cancel that fires at the same deadline, so either path leads
    // the rider back to home gracefully.
    _timeoutTimer = Timer(const Duration(minutes: 10), () {
      _pollTimer?.cancel();
      _isRequesting = false;
      if (_state.phase == RiderPhase.searchingDriver ||
          _state.phase == RiderPhase.requesting) {
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: _userFriendlyCancelReason(
            RiderTripCancelCodes.autoNoDriver10Min,
          ),
          cancelCode: RiderTripCancelCodes.autoNoDriver10Min,
        );
        notifyListeners();
        unawaited(CacheService.clearActiveTrip());
      }
    });

    // ── Polling fallback — safety net behind Firestore real-time listener ──
    Future<void> checkStatus(Timer? timer) async {
      // If driver already matched (e.g. via Firestore), ignore stale poll responses
      if (_driverMatched) {
        timer?.cancel();
        return;
      }
      try {
        final status = await ApiService.getDispatchStatus(tripId);
        final tripStatus = status['status']?.toString() ?? '';

        if (tripStatus == 'accepted' || tripStatus == 'driver_en_route') {
          timer?.cancel();
          _timeoutTimer?.cancel();
          _isRequesting = false;
          try {
            _onDriverMatched(status, tripId);
          } catch (e) {
            debugPrint(
                '⚠️ _onDriverMatched from poll threw: $e — will retry next poll');
            _driverMatched = false;
            // Don't cancel timer — let next poll retry
          }
        } else if (tripStatus == 'cancelled' || tripStatus == 'canceled') {
          // Guard D: ignore stale poll result if driver was already matched
          if (_driverMatched) {
            timer?.cancel();
            return;
          }
          // Check if backend has assigned a driver despite the cancelled status
          // (data race: driver accepted but DB hasn't propagated yet)
          final tripData = status['trip'] as Map<String, dynamic>?;
          final hasDriverId = tripData?['driver_id'] != null &&
              tripData!['driver_id'].toString().isNotEmpty;
          if (hasDriverId) {
            // Driver is assigned — treat as match, let next poll confirm
            debugPrint(
                '[RiderTrip] Poll saw cancelled but driver_id present — ignoring stale cancel');
            return;
          }
          timer?.cancel();
          _timeoutTimer?.cancel();
          _fsCancelDebounce?.cancel();
          _isRequesting = false;
          final reason = tripData?['cancel_reason']?.toString();
          // Resolve the backend cancel code to a user-friendly message
          // up front — the UI consumes `cancelReason` for display and
          // `cancelCode` for branching (toast vs dialog).
          _state = _state.copyWith(
            phase: RiderPhase.cancelled,
            cancelReason: _userFriendlyCancelReason(reason),
            cancelCode: reason,
          );
          notifyListeners();
          await CacheService.clearActiveTrip();
        }
        // Otherwise keep polling (status is 'searching' or 'pending')
      } catch (e) {
        debugPrint('⚠️ dispatch poll error: $e');
      }
    }

    // Check immediately — backend is fast enough now (<100ms response)
    unawaited(checkStatus(null));

    _pollTimer = Timer.periodic(_dispatchPollInterval, (timer) async {
      await checkStatus(timer);
    });
  }

  void _onDriverMatched(Map<String, dynamic> data, int tripId) {
    // Prevent duplicate processing from in-flight polls after SSE match
    if (_driverMatched) return;

    // Helper: read field supporting both snake_case (SSE/polling) and camelCase (Firestore)
    String? field(String snake, String camel) =>
        data[snake]?.toString() ?? data[camel]?.toString();

    // Validate driver_id exists before creating MatchedDriver.
    final driverId = field('driver_id', 'driverId');
    if (driverId == null || driverId.isEmpty) {
      debugPrint(
          '⚠️ Driver matched but driver_id is null/empty — will retry on next poll');
      _startDispatchPolling(tripId);
      return;
    }
    _driverMatched = true;

    // Extract photo URL — try flat field first, then nested driver object
    final photoUrl = field('driver_photo_url', 'driverPhotoUrl') ??
        (data['driver'] is Map
            ? (data['driver'] as Map)['photo_url']?.toString()
            : null) ??
        '';

    final driver = MatchedDriver(
      id: driverId,
      name: field('driver_name', 'driverName') ?? 'Driver',
      rating:
          (data['driver_rating'] ?? data['driverRating'] as num?)?.toDouble() ??
              4.9,
      totalTrips:
          (data['driver_trips'] ?? data['driverTrips'] as num?)?.toInt() ?? 0,
      vehicleMake: field('vehicle_make', 'vehicleMake') ?? '',
      vehicleModel: field('vehicle_model', 'vehicleModel') ?? '',
      vehicleColor: field('vehicle_color', 'vehicleColor') ?? '',
      vehiclePlate: field('vehicle_plate', 'vehiclePlate') ?? '',
      vehicleYear: field('vehicle_year', 'vehicleYear') ?? '',
      photoUrl: photoUrl.isNotEmpty ? photoUrl : null,
      phone: field('driver_phone', 'driverPhone') ?? '',
    );

    _state = _state.copyWith(
      phase: RiderPhase.driverAssigned,
      driver: driver,
      tripId: tripId,
      firestoreTripId: 'sql_$tripId',
      etaMinutes: _state.selectedOption?.etaMinutes ?? 5,
    );
    notifyListeners();
    
    // Save driver info and trip to cache (fire-and-forget)
    unawaited(CacheService.saveDriver({
      'id': driver.id,
      'name': driver.name,
      'rating': driver.rating,
      'photoUrl': driver.photoUrl,
      'vehicleMake': driver.vehicleMake,
      'vehicleModel': driver.vehicleModel,
      'vehicleColor': driver.vehicleColor,
    }));
    unawaited(_saveTripStateToCache());
  }

  /// Force the phase (used when SearchingDriverScreen pops and we need to
  /// replay the Driver Found overlay from driverAssigned).
  void forcePhase(RiderPhase phase) {
    _state = _state.copyWith(phase: phase);
    notifyListeners();
  }

  /// The assigned driver handed the trip back to dispatch (release).
  /// Same trip id — the backend already set it to `requested` and is
  /// re-cascading. Reset the match so the poll + Firestore listener can
  /// deliver the NEXT acceptance, and put the phase back to searching so
  /// the request screen re-enters its "Looking for your driver" state.
  void resumeSearchingAfterDriverRelease() {
    _driverMatched = false;
    _isRequesting = false;
    _state = _state.copyWith(phase: RiderPhase.searchingDriver);
    notifyListeners();
    final tid = _state.tripId;
    // _startDispatchPolling cancels its previous timer/listeners first —
    // safe to re-arm even if one survived the tracking screen.
    if (tid != null) _startDispatchPolling(tid);
  }

  /// Called by the UI after the "Driver Found" overlay finishes.
  void transitionToArriving() {
    if (_state.phase == RiderPhase.driverAssigned) {
      _state = _state.copyWith(phase: RiderPhase.driverArriving);
      notifyListeners();
      // Save transition to cache
      unawaited(_saveTripStateToCache());
    }
  }

  double _calcBearing(LatLng from, LatLng to) {
    final dLon = (to.longitude - from.longitude) * math.pi / 180;
    final lat1 = from.latitude * math.pi / 180;
    final lat2 = to.latitude * math.pi / 180;
    final y = math.sin(dLon) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  // ─── Cancel ─────────────────────────────────────────────────

  /// Cancel before a driver is matched.
  ///
  /// Awaitable on purpose. The backend call used to sit inside an unawaited
  /// `Future.delayed`, so the local phase flipped to cancelled while the
  /// request was still in flight — and the caller reset the controller
  /// immediately after, wiping `_state.tripId`. If that request then failed,
  /// the fallback had no id left to escalate with and the cancel was simply
  /// lost: the trip stayed `requested` on the server, and the next time the
  /// rider opened the app the active-trip restore put them straight back
  /// into "matching you with a ride" for a ride they had cancelled.
  Future<void> cancelRide({String? reason}) async {
    // Cancel policy (2026-04-11): the rider may only directly cancel
    // a trip BEFORE a driver has been assigned. If a driver is already
    // matched, the rider must request cancellation through dispatch
    // (an ActionRequest gets created and a dispatcher decides).
    //
    // This guard catches both the explicit-match case (`_driverMatched`)
    // and the in-state-driver case (state.tripId may have a driver_id
    // even if the local match flag hasn't propagated yet).
    if (_driverMatched) {
      debugPrint(
          '[RiderTrip] cancelRide() routed to request-cancel — driver already matched');
      _routeCancelToDispatch('rider_cancel_after_match');
      return;
    }

    _searchTimer?.cancel();
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    _fsCancelDebounce?.cancel();
    _fsMatchSub?.cancel();
    _isRequesting = false;
    _currentStatus = null;

    // Cancel on backend if we have a trip ID
    final tripId = _state.tripId;

    // Local phase first so the UI closes instantly — the rider tapped cancel
    // and should not watch a spinner while the network decides.
    _state = _state.copyWith(phase: RiderPhase.cancelled);
    notifyListeners();
    unawaited(CacheService.clearActiveTrip());

    if (tripId == null) return;

    // Awaited from here down. The caller resets this controller as soon as we
    // return, so anything left in flight loses the id it needs.
    //
    // Check once more before cancelling — Firestore might have written a
    // driver match in the last 100ms.
    await Future.delayed(const Duration(milliseconds: 100));
    if (_driverMatched) {
      debugPrint('[RiderTrip] cancelRide() driver matched during the grace '
          'window — routing to request-cancel');
      _routeCancelToDispatch('rider_cancel_after_match_grace', tripId: tripId);
      return;
    }
    try {
      await ApiService.cancelTrip(tripId, cancelReason: reason);
      debugPrint('[RiderTrip] trip $tripId cancelled on the backend');
    } catch (e) {
      debugPrint('[RiderTrip] cancelTrip failed: $e');
      // Backend rejected the cancel because a driver was assigned in
      // the same instant — fall through to the dispatch escalation
      // path so the cancel intent isn't lost.
      _routeCancelToDispatch('rider_cancel_backend_409', tripId: tripId);
    }
  }

  /// Escalation helper: when the rider taps Cancel after a driver has
  /// been assigned, we cannot mutate the trip directly anymore. We
  /// create a backend ActionRequest so dispatch sees the request, and
  /// keep the local phase active so the rider stays on the tracking
  /// flow until dispatch confirms or rejects.
  /// [tripId] is passed explicitly by callers that may have already had the
  /// controller reset underneath them — reading `_state.tripId` here was how
  /// a failed cancel lost the very trip it was escalating.
  void _routeCancelToDispatch(String reason, {int? tripId}) {
    // Copied into a final local: a mutable parameter does not type-promote
    // inside the closure below, and the closure is what actually sends it.
    final int? id = tripId ?? _state.tripId;
    if (id == null) {
      _state = _state.copyWith(phase: RiderPhase.cancelled);
      notifyListeners();
      return;
    }
    unawaited(() async {
      try {
        await ApiService.requestTripCancel(
          tripId: id,
          reason: reason,
          urgency: 'normal',
        );
        debugPrint('[RiderTrip] request-cancel posted for trip $id');
      } catch (e) {
        debugPrint('[RiderTrip] request-cancel failed: $e');
      }
    }());
    // Do NOT flip phase to cancelled — the trip is still active server-side
    // until dispatch decides. The UI will react when the real cancel
    // arrives via the poll/Firestore listener.
  }

  void reset() {
    _searchTimer?.cancel();
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    _fsCancelDebounce?.cancel();
    _fsMatchSub?.cancel();
    _quoteDebounce?.cancel();
    _quotePollTimer?.cancel();
    _routeSeq++;
    _quoteSeq++;
    _revisionSeq++;
    _quoteInFlight = null;
    _quoteFrozen = false;
    _frozenQuoteSignature = null;
    _pricingVersion = null;
    _promotionsRevision = null;
    _isRequesting = false;
    _driverMatched = false;
    _currentStatus = null;
    _state = const RiderTripState();
    notifyListeners();
    
    // Clear trip from cache
    unawaited(CacheService.clearActiveTrip());
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance
        .removeObserver(this); // M3: unregister lifecycle observer
    _searchTimer?.cancel();
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    _fsCancelDebounce?.cancel();
    _fsMatchSub?.cancel();
    _quoteDebounce?.cancel();
    _quotePollTimer?.cancel();
    _routeSeq++;
    _quoteSeq++;
    _revisionSeq++;
    _quoteInFlight = null;
    _pricingSub?.cancel();
    super.dispose();
  }

  /// Translate a backend `cancel_reason` code into a user-friendly string.
  /// The UI also receives the raw code via `state.cancelCode` so it can
  /// choose a different visual treatment (toast vs dialog).
  String _userFriendlyCancelReason(String? raw) {
    if (raw == null || raw.isEmpty) return 'Your trip was cancelled.';
    switch (raw) {
      case RiderTripCancelCodes.autoNoDriver10Min:
        return "We couldn't find a driver in time. Please try again.";
      case RiderTripCancelCodes.autoScheduledNoDriver30Min:
        return 'No driver was available for your scheduled ride. Please book again.';
      case RiderTripCancelCodes.autoGuardianGhost:
        return 'Your trip was stopped by the system. Please contact support.';
      default:
        // Pass through cancel reasons written by dispatch or the old
        // scheduler paths so operators can still communicate context.
        if (raw.toLowerCase().contains('no driver')) {
          return "We couldn't find a driver. Please try again.";
        }
        return raw;
    }
  }
}
