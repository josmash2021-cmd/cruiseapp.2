import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../models/lat_lng.dart';

import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/places_service.dart';
import '../services/cache_service.dart';
import '../config/api_keys.dart';

// ═══════════════════════════════════════════════════════════════════
//  Rider trip phases — mirrors Uber rider flow
// ═══════════════════════════════════════════════════════════════════
enum RiderPhase {
  idle, // Home screen — "Where to?"
  selectingLocations, // Typing pickup / dropoff
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
//  Ride type option
// ═══════════════════════════════════════════════════════════════════
class RideOption {
  final String id;
  final String name;
  final String description;
  final double priceEstimate; // USD
  final int etaMinutes;
  final String icon; // emoji or asset ref
  final int capacity;
  final double surgeMultiplier; // 1.0 = no surge

  const RideOption({
    required this.id,
    required this.name,
    required this.description,
    required this.priceEstimate,
    required this.etaMinutes,
    required this.icon,
    this.capacity = 4,
    this.surgeMultiplier = 1.0,
  });
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
class RiderTripState {
  final RiderPhase phase;

  // Locations
  final PlaceDetails? pickup;
  final PlaceDetails? dropoff;
  final String pickupLabel;
  final String dropoffLabel;

  // Route
  final RouteResult? route;

  // Ride options
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
    this.rideOptions = const [],
    this.selectedOption,
    this.driver,
    this.etaMinutes = 0,
    this.driverLocation,
    this.driverBearing = 0,
    this.scheduledAt,
    this.isAirportTrip = false,
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
    List<RideOption>? rideOptions,
    RideOption? selectedOption,
    MatchedDriver? driver,
    int? etaMinutes,
    LatLng? driverLocation,
    double? driverBearing,
    DateTime? scheduledAt,
    bool? isAirportTrip,
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
      rideOptions: rideOptions ?? this.rideOptions,
      selectedOption: selectedOption ?? this.selectedOption,
      driver: driver ?? this.driver,
      etaMinutes: etaMinutes ?? this.etaMinutes,
      driverLocation: driverLocation ?? this.driverLocation,
      driverBearing: driverBearing ?? this.driverBearing,
      scheduledAt: scheduledAt ?? this.scheduledAt,
      isAirportTrip: isAirportTrip ?? this.isAirportTrip,
      tripId: tripId ?? this.tripId,
      firestoreTripId: firestoreTripId ?? this.firestoreTripId,
      cancelReason: cancelReason ?? this.cancelReason,
      cancelCode: cancelCode ?? this.cancelCode,
      routeFetchFailed: routeFetchFailed ?? this.routeFetchFailed,
    );
  }
}

/// Canonical cancel code identifiers that the backend sends via
/// `cancel_reason`. The UI uses these to decide between a smooth
/// toast-and-transition flow vs the regular cancel dialog.
class RiderTripCancelCodes {
  static const autoNoDriver10Min = 'auto:no_driver_found_10min';
  static const autoScheduledNoDriver30Min = 'auto:scheduled_no_driver_30min';
  static const autoGuardianGhost = 'auto:guardian_ghost_stale';

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

  static const Duration _dispatchPollInterval = Duration(seconds: 2);

  final DirectionsService _directions = DirectionsService(ApiKeys.webServices);

  Timer? _searchTimer;
  Timer? _pollTimer;
  Timer? _timeoutTimer; // Fix 1: client-side search timeout
  Timer? _fsCancelDebounce; // Debounce timer for stale Firestore cancel events
  StreamSubscription<DocumentSnapshot>? _fsMatchSub; // Firestore trip doc watcher
  bool _isRequesting = false; // Fix 2: anti-double-tap guard
  bool _driverMatched = false; // true once driver match is confirmed — blocks stale polls
  double _surgeMultiplier = 1.0; // Surge pricing multiplier from backend
  String? _currentStatus; // Last confirmed backend status string for transition validation
  /// True while RiderTrackingScreen is on the navigation stack.
  /// Prevents _refreshActiveTripOnResume from falsely transitioning to cancelled.
  bool isOnTrackingScreen = false;

  RiderTripController() {
    WidgetsBinding.instance.addObserver(this); // M3: observe lifecycle
  }

  /// Save trip state to persistent cache for instant recovery on app reopen.
  /// Triggered after every state change.
  Future<void> _saveTripStateToCache() async {
    // Save trip ID when trip is active
    final tripId = _state.tripId;
    if (tripId != null && (_state.phase == RiderPhase.driverAssigned ||
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
    // M3: when app returns to foreground with an active trip, re-sync state
    if (state == AppLifecycleState.resumed) {
      _refreshActiveTripOnResume();
    }
  }

  Future<void> _refreshActiveTripOnResume() async {
    final tripId = _state.tripId;
    if (tripId == null) { return; } // no trip
    // Skip if the tracking screen is active — it manages its own real-time listeners
    if (isOnTrackingScreen) { return; }
    final phase = _state.phase;
    // Only refresh when actively on-trip. Skip driverAssigned/driverArriving —
    // those phases already have a confirmed match and the UI is transitioning
    // to the tracking screen. Re-checking here causes false cancellations
    // (e.g. when an FCM push triggers a lifecycle resumed event).
    if (phase != RiderPhase.onTrip) { return; }
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
    _state = _state.copyWith(pickup: place, pickupLabel: label);
    notifyListeners();
    _tryFetchRoute();
  }

  void setDropoff(PlaceDetails place, String label) {
    _state = _state.copyWith(dropoff: place, dropoffLabel: label);
    notifyListeners();
    _tryFetchRoute();
  }

  /// Retry fetching the route after a failure.
  void retryFetchRoute() => _tryFetchRoute();

  /// Set a pre-fetched route directly without triggering a network request.
  void setPreloadedRoute({
    required PlaceDetails pickup,
    required String pickupLabel,
    required PlaceDetails dropoff,
    required String dropoffLabel,
    required RouteResult route,
  }) {
    final options = _generateRideOptions(route);
    _state = _state.copyWith(
      pickup: pickup,
      pickupLabel: pickupLabel,
      dropoff: dropoff,
      dropoffLabel: dropoffLabel,
      route: route,
      rideOptions: options,
      selectedOption: null,
      phase: RiderPhase.previewRoute,
    );
    notifyListeners();
  }

  void startLocationSelection() {
    _state = _state.copyWith(phase: RiderPhase.selectingLocations);
    notifyListeners();
  }

  void setSchedule(DateTime? dateTime) {
    _state = _state.copyWith(scheduledAt: dateTime);
    notifyListeners();
  }

  void setAirportTrip(bool isAirport) {
    _state = _state.copyWith(isAirportTrip: isAirport);
    notifyListeners();
  }

  // ─── Route preview ──────────────────────────────────────────

  Future<void> _tryFetchRoute() async {
    if (_state.pickup == null || _state.dropoff == null) return;

    final origin = LatLng(_state.pickup!.lat, _state.pickup!.lng);
    final dest = LatLng(_state.dropoff!.lat, _state.dropoff!.lng);

    // INSTANT: Show estimated route + estimated prices immediately.
    // Cards appear right away — no shimmer wait.
    final estimatedRoute = _directions.getEstimatedRoute(
      origin: origin,
      destination: dest,
    );
    final estimatedOptions = _generateRideOptions(estimatedRoute);
    _state = _state.copyWith(
      phase: RiderPhase.previewRoute,
      route: estimatedRoute,
      rideOptions: estimatedOptions,
      selectedOption: null,
      routeFetchFailed: false,
    );
    notifyListeners();

    // BACKGROUND: Fetch real route + surge and refine prices when ready.
    // Don't let slow surge block cards — fetch both in parallel,
    // update route+prices as soon as directions arrive.
    RouteResult? routeResult;
    try {
      // Fire surge request in parallel but don't block on it
      final surgeFuture = ApiService.getCurrentSurge(_state.pickup!.lat, _state.pickup!.lng)
          .timeout(const Duration(seconds: 5))
          .catchError((_) => <String, dynamic>{'surge_multiplier': 1.0});
      // Real route from Directions API
      routeResult = await _directions.getRoute(origin: origin, destination: dest);

      // Update with real route immediately (don't wait for surge)
      if (routeResult != null) {
        final options = _generateRideOptions(routeResult);
        _state = _state.copyWith(
          phase: RiderPhase.previewRoute,
          route: routeResult,
          rideOptions: options,
          selectedOption: null,
          routeFetchFailed: false,
        );
        notifyListeners();
      }

      // Apply surge multiplier when it arrives and recalculate
      try {
        final surgeData = await surgeFuture;
        final surge = (surgeData['surge_multiplier'] as num?)?.toDouble() ?? 1.0;
        if (surge != _surgeMultiplier) {
          _surgeMultiplier = surge;
          final refreshedOptions = _generateRideOptions(routeResult ?? estimatedRoute);
          _state = _state.copyWith(rideOptions: refreshedOptions);
          notifyListeners();
        }
      } catch (_) {
        _surgeMultiplier = 1.0;
      }
    } catch (_) {
      _surgeMultiplier = 1.0;
      if (routeResult == null) {
        // Route failed — keep estimated prices already shown
        _state = _state.copyWith(routeFetchFailed: true);
        notifyListeners();
      }
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

  List<RideOption> _generateRideOptions(RouteResult route) {
    // Prefer traffic-aware durationSeconds from the API; fall back to parsing durationText
    final mins = route.durationSeconds != null && route.durationSeconds! > 0
        ? (route.durationSeconds! / 60.0).ceil()
        : _parseDurationMinutes(route.durationText);
    final miles = route.distanceMeters / 1609.344;
    double baseFare = 2.50 + (miles * 1.50) + (mins * 0.25);

    // Airport surcharge: +$8 flat + 15% uplift
    final airportTrip =
        _isAirport(_state.pickupLabel) || _isAirport(_state.dropoffLabel);
    if (airportTrip) {
      baseFare = (baseFare + 8.0) * 1.15;
    }
    _state = _state.copyWith(isAirportTrip: airportTrip);

    // Apply surge multiplier (fetched async, default 1.0)
    final surge = _surgeMultiplier;
    final surgedBase = baseFare * surge;

    // Use real route duration from API (traffic-aware seconds) when available,
    // otherwise parse "12 min" or "1 h 5 min" text from durationText.
    // Add small category offsets (VIP vehicles take slightly longer to arrive).
    final baseDuration = mins.clamp(1, 120);

    return [
      RideOption(
        id: 'suburban',
        name: 'VIP',
        description: 'Spacious • Leather • Snacks & Drinks',
        priceEstimate: _round(surgedBase * 2.20),
        etaMinutes: baseDuration + 3,
        icon: '🚐',
        capacity: 7,
        surgeMultiplier: surge,
      ),
      RideOption(
        id: 'camry',
        name: 'Sedan',
        description: 'Comfort • Climate • Charger',
        priceEstimate: _round(surgedBase * 1.35),
        etaMinutes: baseDuration + 2,
        icon: '🚙',
        capacity: 4,
        surgeMultiplier: surge,
      ),
      RideOption(
        id: 'fusion',
        name: 'Comfort',
        description: 'Clean • Safe • Efficient',
        priceEstimate: _round(surgedBase),
        etaMinutes: baseDuration,
        icon: '🚗',
        capacity: 4,
        surgeMultiplier: surge,
      ),
    ];
  }

  double _round(double v) => (v * 100).roundToDouble() / 100;

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

    _state = _state.copyWith(phase: RiderPhase.requesting);
    notifyListeners();

    // Transition to searching UI
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 800), () {
      _state = _state.copyWith(phase: RiderPhase.searchingDriver);
      notifyListeners();
    });

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
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: 'No internet connection. Check your network and try again.',
        );
        notifyListeners();
        return;
      }
      if (userId == null) {
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: 'Could not verify your session. Please try again.',
        );
        notifyListeners();
        return;
      }

      // Resolve addresses — reverse geocode if label is missing or generic
      var pickupAddr = _state.pickupLabel;
      var dropoffAddr = _state.dropoffLabel;
      final places = PlacesService(ApiKeys.webServices);
      if (pickupAddr.isEmpty || pickupAddr.toLowerCase() == 'current location') {
        try {
          final resolved = await places.reverseGeocode(lat: pickup.lat, lng: pickup.lng);
          if (resolved != null && resolved.isNotEmpty) pickupAddr = resolved;
        } catch (_) {}
      }
      if (dropoffAddr.isEmpty || dropoffAddr.toLowerCase() == 'current location') {
        try {
          final resolved = await places.reverseGeocode(lat: dropoff.lat, lng: dropoff.lng);
          if (resolved != null && resolved.isNotEmpty) dropoffAddr = resolved;
        } catch (_) {}
      }

      final result = await ApiService.dispatchRideRequest(
        riderId: userId,
        pickupAddress: pickupAddr.isNotEmpty ? pickupAddr : 'current location',
        dropoffAddress: dropoffAddr.isNotEmpty ? dropoffAddr : 'current location',
        pickupLat: pickup.lat,
        pickupLng: pickup.lng,
        dropoffLat: dropoff.lat,
        dropoffLng: dropoff.lng,
        fare: _state.selectedOption?.priceEstimate,
        vehicleType: _state.selectedOption?.name,
        stripePaymentIntentId: _heldPaymentIntentId,
      );

      final tripId = result['trip_id'] as int?;
      if (tripId == null) {
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: 'Could not create the trip. Please try again.',
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
      _state = _state.copyWith(
        phase: RiderPhase.cancelled,
        cancelReason: 'Connection error. Check your network and try again.',
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
    if (from == 'completed' || from == 'cancelled' || from == 'canceled') return false;
    // Ordered status progression
    const order = ['searching', 'accepted', 'driver_en_route', 'driver_arrived', 'in_progress', 'completed'];
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
        if (status == 'searching' || status == 'pending' || status == 'requested' || status == 'cancelled' || status == 'canceled' || status.isEmpty) return;
        // status == 'accepted' or 'driver_en_route' on first event → fall through and process
      }
      // State machine: reject invalid status regressions (e.g. stale cancelled after match)
      if (!_isValidTransition(_currentStatus, status)) {
        debugPrint('[RiderTrip] Firestore: ignoring invalid transition $_currentStatus → $status');
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
          debugPrint('⚠️ _onDriverMatched from Firestore threw: $e — restarting poll');
          _driverMatched = false;
          _startDispatchPolling(tripId);
        }
      } else if (status == 'cancelled' || status == 'canceled') {
        // Guard A: ignore stale cancellation if driver was already matched
        if (_driverMatched) return;
        // Guard B: debounce 400ms to let a real 'driver_en_route' event win the race
        _fsCancelDebounce?.cancel();
        _fsCancelDebounce = Timer(const Duration(milliseconds: 400), () {
          // Re-check after debounce — driver may have arrived in the meantime
          if (_driverMatched) return;
          _currentStatus = status;
          _fsMatchSub?.cancel();
          _pollTimer?.cancel();
          _timeoutTimer?.cancel();
          _isRequesting = false;
          // Pull the real cancel_reason from the Firestore doc so the UI
          // can branch into the smooth-toast flow when it's an auto-cancel.
          final rawReason = (_currentStatus['cancelReason'] ??
                  _currentStatus['cancel_reason'])
              ?.toString();
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
      if (_driverMatched) { timer?.cancel(); return; }
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
            debugPrint('⚠️ _onDriverMatched from poll threw: $e — will retry next poll');
            _driverMatched = false;
            // Don't cancel timer — let next poll retry
          }
        } else if (tripStatus == 'cancelled' || tripStatus == 'canceled') {
          // Guard D: ignore stale poll result if driver was already matched
          if (_driverMatched) { timer?.cancel(); return; }
          // Check if backend has assigned a driver despite the cancelled status
          // (data race: driver accepted but DB hasn't propagated yet)
          final tripData = status['trip'] as Map<String, dynamic>?;
          final hasDriverId = tripData?['driver_id'] != null &&
              tripData!['driver_id'].toString().isNotEmpty;
          if (hasDriverId) {
            // Driver is assigned — treat as match, let next poll confirm
            debugPrint('[RiderTrip] Poll saw cancelled but driver_id present — ignoring stale cancel');
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

    // Delay first check to give backend DB write time to propagate.
    Future.delayed(const Duration(seconds: 2), () => checkStatus(null));

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
      debugPrint('⚠️ Driver matched but driver_id is null/empty — will retry on next poll');
      _startDispatchPolling(tripId);
      return;
    }
    _driverMatched = true;

    // Extract photo URL — try flat field first, then nested driver object
    final photoUrl = field('driver_photo_url', 'driverPhotoUrl') ??
        (data['driver'] is Map ? (data['driver'] as Map)['photo_url']?.toString() : null) ??
        '';

    final driver = MatchedDriver(
      id: driverId,
      name: field('driver_name', 'driverName') ?? 'Driver',
      rating: (data['driver_rating'] ?? data['driverRating'] as num?)?.toDouble() ?? 4.9,
      totalTrips: (data['driver_trips'] ?? data['driverTrips'] as num?)?.toInt() ?? 0,
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
    final x =
        math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLon);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  // ─── Cancel ─────────────────────────────────────────────────

  void cancelRide() {
    // Fix 6: Race condition guard — if a driver was already matched while the rider
    // was tapping cancel (e.g. network lag), do NOT cancel. Let the match win.
    if (_driverMatched) {
      debugPrint('[RiderTrip] cancelRide() ignored — driver already matched');
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
    if (tripId != null) {
      // Check one more time before actually cancelling — Firestore might have
      // just written a driver match in the last 300ms.
      Future.delayed(const Duration(milliseconds: 300), () async {
        if (_driverMatched) {
          debugPrint('[RiderTrip] cancelRide() backend call skipped — driver matched during delay');
          return;
        }
        try {
          await ApiService.cancelTrip(tripId);
        } catch (e) {
          debugPrint('[RiderTrip] cancelTrip failed: $e');
          // 409 = driver already assigned — rider still chose to cancel,
          // so keep phase as cancelled (do not revert to driverAssigned).
        }
      });
    }

    _state = _state.copyWith(phase: RiderPhase.cancelled);
    notifyListeners();

    // Clear trip from cache
    unawaited(CacheService.clearActiveTrip());
  }

  void reset() {
    _searchTimer?.cancel();
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    _fsCancelDebounce?.cancel();
    _fsMatchSub?.cancel();
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
    WidgetsBinding.instance.removeObserver(this); // M3: unregister lifecycle observer
    _searchTimer?.cancel();
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    _fsCancelDebounce?.cancel();
    _fsMatchSub?.cancel();
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
