import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/foundation.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';

import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/places_service.dart';
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

  const RideOption({
    required this.id,
    required this.name,
    required this.description,
    required this.priceEstimate,
    required this.etaMinutes,
    required this.icon,
    this.capacity = 4,
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
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Main controller
// ═══════════════════════════════════════════════════════════════════
class RiderTripController extends ChangeNotifier {
  RiderTripState _state = const RiderTripState();
  RiderTripState get state => _state;

  final DirectionsService _directions = DirectionsService(ApiKeys.webServices);

  Timer? _searchTimer;
  Timer? _pollTimer;

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

    final result = await _directions.getRoute(
      origin: origin,
      destination: dest,
    );

    if (result != null) {
      final options = _generateRideOptions(result);
      _state = _state.copyWith(
        phase: RiderPhase.previewRoute,
        route: result,
        rideOptions: options,
        selectedOption: options.isNotEmpty ? options.first : null,
      );
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

    return [
      RideOption(
        id: 'suburban',
        name: 'Suburban',
        description: 'Premium SUV experience',
        priceEstimate: _round(baseFare * 2.20),
        etaMinutes: 5 + math.Random().nextInt(8),
        icon: '🚐',
        capacity: 7,
      ),
      RideOption(
        id: 'camry',
        name: 'Camry',
        description: 'Comfortable sedan',
        priceEstimate: _round(baseFare * 1.35),
        etaMinutes: 4 + math.Random().nextInt(6),
        icon: '🚙',
        capacity: 4,
      ),
      RideOption(
        id: 'fusion',
        name: 'Fusion',
        description: 'Affordable rides',
        priceEstimate: _round(baseFare),
        etaMinutes: 3 + math.Random().nextInt(5),
        icon: '🚗',
        capacity: 4,
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

  Future<void> requestRide() async {
    _state = _state.copyWith(phase: RiderPhase.requesting);
    notifyListeners();

    // Transition to searching UI
    _searchTimer?.cancel();
    _searchTimer = Timer(const Duration(milliseconds: 800), () {
      _state = _state.copyWith(phase: RiderPhase.searchingDriver);
      notifyListeners();
    });

    // Call backend dispatch
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId == null) {
        _state = _state.copyWith(phase: RiderPhase.cancelled);
        notifyListeners();
        return;
      }

      final result = await ApiService.dispatchRideRequest(
        riderId: userId,
        pickupAddress: _state.pickupLabel,
        dropoffAddress: _state.dropoffLabel,
        pickupLat: _state.pickup!.lat,
        pickupLng: _state.pickup!.lng,
        dropoffLat: _state.dropoff!.lat,
        dropoffLng: _state.dropoff!.lng,
        fare: _state.selectedOption?.priceEstimate,
        vehicleType: _state.selectedOption?.name,
      );

      final tripId = result['trip_id'] as int?;
      if (tripId == null) {
        _state = _state.copyWith(phase: RiderPhase.cancelled);
        notifyListeners();
        return;
      }

      _state = _state.copyWith(tripId: tripId);
      notifyListeners();

      // Poll dispatch status until a driver accepts
      _startDispatchPolling(tripId);
    } catch (e) {
      debugPrint('❌ dispatchRideRequest failed: $e');
      _state = _state.copyWith(phase: RiderPhase.cancelled);
      notifyListeners();
    }
  }

  void _startDispatchPolling(int tripId) {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
      try {
        final status = await ApiService.getDispatchStatus(tripId);
        final tripStatus = status['status']?.toString() ?? '';

        if (tripStatus == 'accepted' || tripStatus == 'driver_en_route') {
          timer.cancel();
          _onDriverMatched(status, tripId);
        } else if (tripStatus == 'cancelled' ||
            tripStatus == 'no_drivers' ||
            tripStatus == 'expired' ||
            tripStatus == 'canceled') {
          timer.cancel();
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
        }
        // Otherwise keep polling (status is 'searching' or 'pending')
      } catch (e) {
        debugPrint('⚠️ dispatch poll error: $e');
      }
    });
  }

  void _onDriverMatched(Map<String, dynamic> data, int tripId) {
    // Validate driver_id exists before creating MatchedDriver
    final driverId = data['driver_id']?.toString();
    if (driverId == null || driverId.isEmpty) {
      debugPrint('⚠️ Driver matched but driver_id is null/empty');
      return;
    }

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
    );

    _state = _state.copyWith(
      phase: RiderPhase.driverAssigned,
      driver: driver,
      tripId: tripId,
      etaMinutes: _state.selectedOption?.etaMinutes ?? 5,
    );
    notifyListeners();

    // After a brief transition, move to arriving phase
    Timer(const Duration(milliseconds: 1500), () {
      _state = _state.copyWith(phase: RiderPhase.driverArriving);
      notifyListeners();
    });
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

    // Cancel on backend if we have a trip ID
    final tripId = _state.tripId;
    if (tripId != null) {
      ApiService.cancelTrip(tripId).catchError((_) => <String, dynamic>{});
    }

    _state = _state.copyWith(phase: RiderPhase.cancelled);
    notifyListeners();
  }

  void reset() {
    _searchTimer?.cancel();
    _pollTimer?.cancel();
    _state = const RiderTripState();
    notifyListeners();
  }

  /// Set a simulated driver for practice mode (bypasses backend dispatch)
  void setSimulatedDriver(MatchedDriver driver) {
    _searchTimer?.cancel();
    _pollTimer?.cancel();
    
    _state = _state.copyWith(
      phase: RiderPhase.driverAssigned,
      driver: driver,
      etaMinutes: _state.selectedOption?.etaMinutes ?? 5,
      tripId: 999999, // Simulated trip ID
    );
    notifyListeners();

    // After a brief transition, move to arriving phase
    Timer(const Duration(milliseconds: 1500), () {
      _state = _state.copyWith(phase: RiderPhase.driverArriving);
      notifyListeners();
    });
  }

  @override
  void dispose() {
    _searchTimer?.cancel();
    _pollTimer?.cancel();
    super.dispose();
  }
}
