import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:cruise_app/utils/driver_location_settings.dart';

void main() {
  test('driver feed has no distance floor and keeps a fast Android interval',
      () {
    final settings = driverLocationSettings(
      notificationTitle: 'Test',
      notificationText: 'Test',
    );
    expect(settings.distanceFilter, 0);
    if (settings is AndroidSettings) {
      expect(settings.intervalDuration, const Duration(milliseconds: 500));
    }
  });

  test('driver online, trip and navigation all request continuous fixes', () {
    final controller = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    final trip = File('lib/screens/driver/driver_trip_accept_screen.dart')
        .readAsStringSync();
    final nav =
        File('lib/screens/driver/driver_nav_view.dart').readAsStringSync();
    expect(controller, contains('distanceFilter: 0'));
    expect(trip, contains('distanceFilter: 0'));
    expect(nav, contains('distanceFilter: 0'));
  });
}
