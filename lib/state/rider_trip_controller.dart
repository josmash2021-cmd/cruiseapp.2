import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/widgets.dart';
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

  // Cancel reason from dispatch
  final String? cancelReason;

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
      routeFetchFailed: routeFetchFailed ?? this.routeFetchFailed,
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Main controller
// ═══════════════════════════════════════════════════════════════════
class RiderTripController extends ChangeNotifier with WidgetsBindingObserver {
  RiderTripState _state = const RiderTripState();
  RiderTripState get state => _state;

  static const Duration _dispatchPollInterval = Duration(seconds: 3);

  final DirectionsService _directions = DirectionsService(ApiKeys.webServices);

  Timer? _searchTimer;
  Timer? _pollTimer;
  Timer? _timeoutTimer; // Fix 1: client-side search timeout
  StreamSubscription<Map<String, dynamic>>? _tripSseSub; // SSE stream sub
  bool _isRequesting = false; // Fix 2: anti-double-tap guard
  bool _sseConnected = false; // true when SSE stream is active
  bool _driverMatched = false; // true once driver match is confirmed — blocks stale polls
  double _surgeMultiplier = 1.0; // Surge pricing multiplier from backend
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
      } else if (tripStatus == 'cancelled' ||
          tripStatus == 'canceled' ||
          tripStatus == 'no_drivers') {
        _pollTimer?.cancel();
        _timeoutTimer?.cancel();
        _isRequesting = false;
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: 'El viaje fue cancelado mientras la app estaba en segundo plano.',
        );
        notifyListeners();
        // Clear cache on cancellation
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

    // INSTANT: Show estimated route (straight line) for map preview only.
    // Do NOT emit rideOptions yet — prices from straight-line distance are
    // inaccurate and cause a visible price change when the real route arrives.
    // The shimmer loading state stays visible until real prices are ready.
    final estimatedRoute = _directions.getEstimatedRoute(
      origin: origin,
      destination: dest,
    );
    _state = _state.copyWith(
      phase: RiderPhase.previewRoute,
      route: estimatedRoute,
      rideOptions: const [],
      selectedOption: null,
      routeFetchFailed: false,
    );
    notifyListeners();

    // BACKGROUND: Fetch real route + surge and update when ready
    late final RouteResult? routeResult;
    try {
      final results = await Future.wait([
        // Surge multiplier
        ApiService.getCurrentSurge(_state.pickup!.lat, _state.pickup!.lng)
            .timeout(const Duration(seconds: 5))
            .catchError((_) => <String, dynamic>{'surge_multiplier': 1.0}),
        // Real route from Directions API (with retry + cache)
        _directions.getRoute(origin: origin, destination: dest),
      ]);

      _surgeMultiplier = ((results[0] as Map<String, dynamic>)['surge_multiplier'] as num?)?.toDouble() ?? 1.0;
      routeResult = results[1] as RouteResult?;
    } catch (_) {
      _surgeMultiplier = 1.0;
      routeResult = null;
    }

    // Update with real route if we got one (smooth transition from estimated)
    if (routeResult != null) {
      final options = _generateRideOptions(routeResult);
      _state = _state.copyWith(
        phase: RiderPhase.previewRoute,
        route: routeResult,
        rideOptions: options,
        selectedOption: null,
        routeFetchFailed: false,
      );
    } else {
      // Route failed — fall back to estimated-route prices so user sees something
      final fallbackOptions = _generateRideOptions(estimatedRoute);
      _state = _state.copyWith(
        routeFetchFailed: true,
        rideOptions: fallbackOptions,
      );
    }
    notifyListeners();
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
    // Base: ~$1.50/mi + $0.25/min, with multiplier per type
    final miles = route.distanceMeters / 1609.344;
    final mins = _parseDurationMinutes(route.durationText);
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

    return [
      RideOption(
        id: 'suburban',
        name: 'VIP',
        description: 'Spacious • Leather • Snacks & Drinks',
        priceEstimate: _round(surgedBase * 2.20),
        etaMinutes: 5 + math.Random().nextInt(8),
        icon: '🚐',
        capacity: 7,
        surgeMultiplier: surge,
      ),
      RideOption(
        id: 'camry',
        name: 'Sedan',
        description: 'Comfort • Climate • Charger',
        priceEstimate: _round(surgedBase * 1.35),
        etaMinutes: 4 + math.Random().nextInt(6),
        icon: '🚙',
        capacity: 4,
        surgeMultiplier: surge,
      ),
      RideOption(
        id: 'fusion',
        name: 'Comfort',
        description: 'Clean • Safe • Efficient',
        priceEstimate: _round(surgedBase),
        etaMinutes: 3 + math.Random().nextInt(5),
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
      _state = _state.copyWith(
        phase: RiderPhase.cancelled,
        cancelReason: 'Selecciona una ubicación válida de recogida y destino.',
      );
      notifyListeners();
      return;
    }
    if ((pickup.lat == 0.0 && pickup.lng == 0.0) ||
        (dropoff.lat == 0.0 && dropoff.lng == 0.0)) {
      _isRequesting = false;
      _state = _state.copyWith(
        phase: RiderPhase.cancelled,
        cancelReason: 'GPS no disponible. Verifica tu ubicación e intenta de nuevo.',
      );
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
          cancelReason: 'Sin conexión a internet. Verifica tu red e intenta de nuevo.',
        );
        notifyListeners();
        return;
      }
      if (userId == null) {
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: 'No se pudo verificar tu sesión. Intenta de nuevo.',
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
          cancelReason: 'No se pudo crear el viaje. Intenta de nuevo.',
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
      debugPrint('❌ dispatchRideRequest failed: $e');
      _state = _state.copyWith(
        phase: RiderPhase.cancelled,
        cancelReason: 'Error de conexión. Verifica tu red e intenta de nuevo.',
      );
      notifyListeners();
    } finally {
      // Reset only if polling never started — polling callbacks own the flag
      if (!pollingStarted) _isRequesting = false;
    }
  }

  void _startDispatchPolling(int tripId) {
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    _tripSseSub?.cancel();
    _sseConnected = false;

    // Safety-net timeout — 10 minutes max searching (backend handles expiry at 5 min)
    _timeoutTimer = Timer(const Duration(minutes: 10), () {
      _pollTimer?.cancel();
      _tripSseSub?.cancel();
      _isRequesting = false;
      if (_state.phase == RiderPhase.searchingDriver ||
          _state.phase == RiderPhase.requesting) {
        _state = _state.copyWith(
          phase: RiderPhase.cancelled,
          cancelReason: 'No hay drivers disponibles cerca de tu zona en estos momentos. Intenta de nuevo.',
        );
        notifyListeners();
        // Clear trip cache
        unawaited(CacheService.clearActiveTrip());
      }
    });

    // ── SSE: real-time instant push from backend ──
    _tripSseSub = ApiService.streamTripStatus(tripId).listen(
      (event) {
        _sseConnected = true;
        final status = event['status']?.toString() ?? '';
        debugPrint('🔴 SSE trip_update: status=$status');

        if (status == 'driver_en_route' || status == 'accepted') {
          _pollTimer?.cancel();
          _tripSseSub?.cancel();
          _timeoutTimer?.cancel();
          _isRequesting = false;
          _onDriverMatched(event, tripId);
        } else if (status == 'cancelled' || status == 'no_drivers' || status == 'expired') {
          _pollTimer?.cancel();
          _tripSseSub?.cancel();
          _timeoutTimer?.cancel();
          _isRequesting = false;
          _state = _state.copyWith(
            phase: RiderPhase.cancelled,
            cancelReason: status == 'no_drivers'
                ? 'No hay drivers disponibles cerca de tu zona en estos momentos'
                : status == 'expired'
                    ? 'La solicitud expiró. Intenta de nuevo.'
                    : 'Tu viaje fue cancelado.',
          );
          notifyListeners();
          unawaited(CacheService.clearActiveTrip());
        }
      },
      onError: (e) {
        debugPrint('⚠️ SSE stream error, polling is active as fallback: $e');
        _sseConnected = false;
      },
      onDone: () {
        debugPrint('ℹ️ SSE stream ended, polling continues as fallback');
        _sseConnected = false;
      },
    );

    // ── Polling fallback (slower when SSE is active, never fully skipped) ──
    int pollTick = 0;
    Future<void> checkStatus(Timer? timer) async {
      // If driver already matched (e.g. via SSE), ignore stale poll responses
      if (_driverMatched) { timer?.cancel(); return; }
      pollTick++;
      // When SSE is delivering, poll every 3rd tick (~9s) as safety net
      if (_sseConnected && pollTick % 3 != 0) return;
      try {
        final status = await ApiService.getDispatchStatus(tripId);
        final tripStatus = status['status']?.toString() ?? '';

        if (tripStatus == 'accepted' || tripStatus == 'driver_en_route') {
          timer?.cancel();
          _tripSseSub?.cancel();
          _timeoutTimer?.cancel();
          _isRequesting = false;
          _onDriverMatched(status, tripId);
        } else if (tripStatus == 'cancelled' ||
            tripStatus == 'no_drivers' ||
            tripStatus == 'expired' ||
            tripStatus == 'canceled') {
          timer?.cancel();
          _tripSseSub?.cancel();
          _timeoutTimer?.cancel();
          _isRequesting = false;
          // Extract cancel reason from trip data
          final tripData = status['trip'] as Map<String, dynamic>?;
          final reason = tripData?['cancel_reason']?.toString();
          _state = _state.copyWith(
            phase: RiderPhase.cancelled,
            cancelReason:
                reason ??
                (tripStatus == 'no_drivers'
                    ? 'No hay drivers disponibles cerca de tu zona en estos momentos'
                    : null),
          );
          notifyListeners();
          // Clear trip cache
          await CacheService.clearActiveTrip();
        }
        // Otherwise keep polling (status is 'searching' or 'pending')
      } catch (e) {
        debugPrint('⚠️ dispatch poll error: $e');
      }
    }

    // Immediate first check to avoid waiting for SSE connection setup.
    checkStatus(null);

    _pollTimer = Timer.periodic(_dispatchPollInterval, (timer) async {
      await checkStatus(timer);
    });
  }

  void _onDriverMatched(Map<String, dynamic> data, int tripId) {
    // Prevent duplicate processing from in-flight polls after SSE match
    if (_driverMatched) return;

    // Validate driver_id exists before creating MatchedDriver.
    // Do NOT set _driverMatched=true until validation passes — otherwise a stale
    // poll response without driver_id permanently blocks the rider (timers already
    // cancelled, flag prevents future polls from re-triggering this method).
    final driverId = data['driver_id']?.toString();
    if (driverId == null || driverId.isEmpty) {
      debugPrint('⚠️ Driver matched but driver_id is null/empty — will retry on next poll');
      // Restart polling so we can try again with a fresh response
      _startDispatchPolling(tripId);
      return;
    }
    _driverMatched = true;

    // Extract photo URL — try flat field first, then nested driver object
    final photoUrl = data['driver_photo_url']?.toString() ??
        (data['driver'] is Map ? (data['driver'] as Map)['photo_url']?.toString() : null) ??
        '';

    final driver = MatchedDriver(
      id: driverId,
      name: data['driver_name']?.toString() ?? 'Driver',
      rating: (data['driver_rating'] as num?)?.toDouble() ?? 4.9,
      totalTrips: (data['driver_trips'] as num?)?.toInt() ?? 0,
      vehicleMake: data['vehicle_make']?.toString() ?? '',
      vehicleModel: data['vehicle_model']?.toString() ?? '',
      vehicleColor: data['vehicle_color']?.toString() ?? '',
      vehiclePlate: data['vehicle_plate']?.toString() ?? '',
      vehicleYear: data['vehicle_year']?.toString() ?? '',
      photoUrl: photoUrl.isNotEmpty ? photoUrl : null,
      phone: data['driver_phone']?.toString() ?? '',
    );

    _state = _state.copyWith(
      phase: RiderPhase.driverAssigned,
      driver: driver,
      tripId: tripId,
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
    _searchTimer?.cancel();
    _pollTimer?.cancel();
    _timeoutTimer?.cancel();
    _tripSseSub?.cancel();
    _sseConnected = false;
    _isRequesting = false;

    // Cancel on backend if we have a trip ID
    final tripId = _state.tripId;
    if (tripId != null) {
      ApiService.cancelTrip(tripId).catchError((e) {
        debugPrint('[RiderTrip] cancelTrip failed: $e');
        return <String, dynamic>{};
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
    _tripSseSub?.cancel();
    _isRequesting = false;
    _driverMatched = false;
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
    _tripSseSub?.cancel();
    super.dispose();
  }
}
