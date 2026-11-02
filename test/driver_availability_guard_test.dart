// "Recibiendo viajes" / "Último viaje" (owner 2026-11-02): the panel's
// switches reach the server for THIS trip, and after the last trip the
// driver lands on the home screen OFFLINE.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final trip =
      File('lib/screens/driver/driver_trip_accept_screen.dart').readAsStringSync();
  final online =
      File('lib/screens/driver/driver_online_controller.dart').readAsStringSync();
  final api = File('lib/services/api_service.dart').readAsStringSync();

  test('both switches are sent to the server for this trip', () {
    expect(api.contains("'\$_baseUrl/trips/\$tripId/driver-availability'"), isTrue);
    expect(trip.contains('onToggleReceiving: _toggleReceiving,'), isTrue);
    expect(trip.contains('onToggleLastTrip: _toggleLastTrip,'), isTrue);
    expect(trip.contains('ApiService.setDriverAvailability('), isTrue);
  });

  test('"Último viaje" also stops chained rides, and receiving clears it', () {
    expect(trip.contains('if (_lastTrip) _receivingRides = false;'), isTrue);
    expect(trip.contains('if (_receivingRides) _lastTrip = false;'), isTrue);
  });

  test('a reopened trip shows the switches as the driver left them', () {
    expect(trip.contains("t['driver_last_trip'] == true"), isTrue);
    expect(trip.contains("t['driver_receiving'] == false"), isTrue);
  });

  test('the landing after the last trip is OFFLINE, both ways back', () {
    // A fresh online screen (rate screen, cancel exit) does not go online.
    expect(
      online.contains(
          'if (widget.resuming && DriverOnlineScreen.takeOfflineAfterTrip()) {'),
      isTrue,
    );
    // The online screen that was underneath closes the shift.
    expect(online.contains('if (lastTripDone) unawaited(_exitOnlineMode());'),
        isTrue);
  });
}
