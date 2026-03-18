import '../models/lat_lng.dart';
import 'dart:math' as math;

/// Phases of a driver's trip lifecycle.
enum TripPhase {
  idle,
  toPickup,
  arrivedPickup,
  onTrip,
  arrivedDropoff,
  completed,
}

/// Simple state machine for driver navigation trip phases.
///
/// Tracks the current [TripPhase] and fires [onPhaseChanged] when it changes.
/// Also checks proximity to pickup/dropoff to auto-advance phases.
class NavStateMachine {
  NavStateMachine({this.onPhaseChanged});

  final void Function(TripPhase phase)? onPhaseChanged;

  TripPhase _phase = TripPhase.idle;
  TripPhase get phase => _phase;

  LatLng? _pickup;
  LatLng? _dropoff;
  String _tripId = '';

  /// Proximity threshold in meters to consider "arrived".
  static const double arrivalThresholdMeters = 50.0;

  /// Start a new trip — transitions to [TripPhase.toPickup].
  void startTrip({
    required String tripId,
    required LatLng pickup,
    required LatLng dropoff,
  }) {
    _tripId = tripId;
    _pickup = pickup;
    _dropoff = dropoff;
    _setPhase(TripPhase.toPickup);
  }

  /// Manually mark arrived at pickup.
  void arriveAtPickup() {
    if (_phase == TripPhase.toPickup) {
      _setPhase(TripPhase.arrivedPickup);
    }
  }

  /// Begin the trip (rider picked up).
  void beginTrip() {
    if (_phase == TripPhase.arrivedPickup) {
      _setPhase(TripPhase.onTrip);
    }
  }

  /// Manually mark arrived at dropoff.
  void arriveAtDropoff() {
    if (_phase == TripPhase.onTrip) {
      _setPhase(TripPhase.arrivedDropoff);
    }
  }

  /// Complete the trip.
  void completeTrip() {
    if (_phase == TripPhase.arrivedDropoff) {
      _setPhase(TripPhase.completed);
    }
  }

  /// Check if driver is close enough to pickup/dropoff to auto-advance.
  void checkProximity(LatLng driverPos) {
    if (_phase == TripPhase.toPickup && _pickup != null) {
      if (_haversineM(driverPos, _pickup!) < arrivalThresholdMeters) {
        _setPhase(TripPhase.arrivedPickup);
      }
    } else if (_phase == TripPhase.onTrip && _dropoff != null) {
      if (_haversineM(driverPos, _dropoff!) < arrivalThresholdMeters) {
        _setPhase(TripPhase.arrivedDropoff);
      }
    }
  }

  void reset() {
    _phase = TripPhase.idle;
    _pickup = null;
    _dropoff = null;
    _tripId = '';
  }

  void dispose() {
    // No resources to release currently.
  }

  void _setPhase(TripPhase newPhase) {
    if (_phase == newPhase) return;
    _phase = newPhase;
    onPhaseChanged?.call(newPhase);
  }

  static double _haversineM(LatLng a, LatLng b) {
    const R = 6371000.0;
    final dLat = _r(b.latitude - a.latitude);
    final dLng = _r(b.longitude - a.longitude);
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(_r(a.latitude)) *
            math.cos(_r(b.latitude)) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  static double _r(double d) => d * math.pi / 180;
}
