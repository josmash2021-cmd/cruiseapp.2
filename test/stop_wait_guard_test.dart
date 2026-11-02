// The rider's stop (owner design 2026-11-02, drawings 11-12): the leg ends
// at the stop, "Llegué" there starts the free 5-min wait, and "Desliza para
// ir al destino" redraws the route from the car to the destination.
import 'dart:io';

import 'package:cruise_app/utils/trip_stops.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final trip =
      File('lib/screens/driver/driver_trip_accept_screen.dart').readAsStringSync();
  final nav = File('lib/screens/driver/driver_nav_view.dart').readAsStringSync();

  test('the stop has its own stages before the destination', () {
    expect(trip.contains("if (_stopArrivedAt != null) return 'stop_waiting';"),
        isTrue);
    expect(trip.contains("return _nearStop ? 'stop_near' : 'stop_locked';"),
        isTrue);
  });

  test('the leg ends at the stop until the driver leaves it', () {
    expect(nav.contains('(_stopLeg ? widget.stopLatLng! : widget.dropoffLatLng)'),
        isTrue);
    expect(nav.contains('oldWidget.stopDone != widget.stopDone'), isTrue,
        reason: 'leaving the stop re-routes from the car');
    expect(nav.contains("stage == 'stop_waiting';"), isTrue,
        reason: 'the wait clock runs at the stop too');
    expect(nav.contains('_waitStartLocal = null;'), isTrue,
        reason: 'the stop does not inherit the pickup wait');
  });

  test('a reopened trip lands where the driver left the stop', () {
    expect(trip.contains('_applyStopWait(trip);'), isTrue);
    expect(trip.contains('_applyStopWait(t);'), isTrue);
  });

  test('the rider sees "te espera en la parada" with the wait', () {
    final ctrl = File('lib/controllers/rider_tracking_controller.dart')
        .readAsStringSync();
    final screen = File('lib/screens/rider_tracking_screen.dart').readAsStringSync();
    expect(ctrl.contains('_handleStopWait(data);'), isTrue);
    expect(ctrl.contains("data.containsKey('stopArrivedAt')"), isTrue,
        reason: 'the status poll carries no stop keys and must not clear it');
    expect(screen.contains('_stopWaitTicker?.cancel();'), isTrue);
    expect(screen.contains('child: _buildStopWaitBanner(),'), isTrue);
  });

  test('the stop wait parses off the trip payload', () {
    final w = parseTripStopWait({
      'stops':
          '[{"lat":25.7,"lng":-80.1,"label":"AutoZone","arrived_at":"2026-11-02T15:00:00+00:00"}]',
    });
    expect(w.arrivedAt, DateTime.utc(2026, 11, 2, 15));
    expect(w.departed, isFalse);
    final gone = parseTripStopWait({
      'stops': [
        {'lat': 25.7, 'lng': -80.1, 'arrived_at': 'x', 'departed_at': '2026-11-02T15:04:00Z'}
      ],
    });
    expect(gone.departed, isTrue);
    expect(parseTripStopWait({}).arrivedAt, isNull);
  });
}
