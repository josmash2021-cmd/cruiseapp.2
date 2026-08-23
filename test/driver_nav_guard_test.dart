import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the trip-accept screen's navigation behaviour.
///
/// Pure source-grep (same style as driver_scheduled_neu_guard_test.dart):
/// the feature needs GPS, a live trip and a native map, so what a unit test
/// CAN pin is that the load-bearing pieces are wired where they belong:
///   1. Web-booking bookkeeping lines never reach the driver as
///      "passenger instructions".
///   2. Start Trip (and the pickup-confirmed leg to the dropoff) opens an
///      EXTERNAL maps app — the in-app DriverNavView experiment is archived
///      (lib/screens/driver/driver_nav_view.dart is kept but unwired), and
///      nothing on this screen may import or mount it again.
///   3. The external launch respects the driver's Settings → Navigation
///      preference (MapLauncherService) before falling back to the
///      Apple/Google/Waze chain.
///   4. A rider with Location Sharing off (privacy_location == false)
///      publishes nothing.
void main() {
  final accept =
      File('lib/screens/driver/driver_trip_accept_screen.dart')
          .readAsStringSync();
  final riderMap =
      File('lib/widgets/tracking/tracking_map_view.dart').readAsStringSync();

  group('web booking filter', () {
    final start = accept.indexOf('String get _passengerInstructions');
    final block = start >= 0 ? accept.substring(start, start + 1200) : '';

    test('_passengerInstructions drops "Web booking" lines', () {
      expect(block, isNotEmpty,
          reason: '_passengerInstructions getter not found');
      expect(block, contains("startsWith('web booking')"));
    });

    test('the filter is case-insensitive', () {
      expect(block, contains('.toLowerCase()'));
    });

    test('real passenger instructions still pass', () {
      // The Wait started: filter predates this feature — both must stay.
      expect(block, contains("startsWith('Wait started:')"));
    });
  });

  group('external maps navigation', () {
    test('the in-app nav mode is gone from the trip-accept screen', () {
      expect(accept, isNot(contains('_enterNavMode')),
          reason: 'Start Trip must open external maps, not the in-app nav');
      expect(accept, isNot(contains('DriverNavView')));
      expect(accept, isNot(contains("import 'driver_nav_view.dart'")));
    });

    test('Start Trip opens external maps to the pickup', () {
      final start = accept.indexOf('Widget _buildSlideStartTrip()');
      final block =
          start >= 0 ? accept.substring(start, start + 1200) : '';
      expect(block, isNotEmpty, reason: '_buildSlideStartTrip not found');
      expect(block, contains('_openNativeMaps(widget.pickupLatLng)'));
    });

    test('the pickup-confirmed leg opens external maps to the dropoff', () {
      final start = accept.indexOf('void _startRideConfirmed()');
      final block =
          start >= 0 ? accept.substring(start, start + 900) : '';
      expect(block, isNotEmpty, reason: '_startRideConfirmed not found');
      expect(block, contains('_openNativeMaps(_dropoffLL)'));
    });

    test('the Settings → Navigation preference is consulted first', () {
      final start = accept.indexOf('Future<void> _openNativeMaps');
      final block =
          start >= 0 ? accept.substring(start, start + 1400) : '';
      expect(block, isNotEmpty, reason: '_openNativeMaps not found');
      expect(block, contains('MapLauncherService.navigate('));
    });

    test('iOS one-tap Apple Maps / Android chooser stay on the address cards',
        () {
      expect(accept, contains('_openAppleMaps(widget.pickupLatLng)'));
      expect(accept, contains('_showNavigationSheet(isPickup: true)'));
      expect(accept, contains('_openAppleMaps(_dropoffLL)'));
      expect(accept, contains('_showNavigationSheet(isPickup: false)'));
    });
  });

  group('rider publishing privacy', () {
    test('honors the privacy_location toggle', () {
      final start = riderMap.indexOf('_startRiderLocationSharing');
      final block =
          start >= 0 ? riderMap.substring(start, start + 1400) : '';
      expect(block, isNotEmpty,
          reason: '_startRiderLocationSharing not found');
      expect(block, contains("getBool('privacy_location')"));
    });

    test('publishes through the socket relay with the fix capture time', () {
      expect(riderMap, contains('SocketService.sendRiderLocation('));
      expect(riderMap, contains('capturedAtMs'));
    });

    test('stops publishing once the pickup window closes', () {
      expect(riderMap, contains('_stopRiderLocationSharing()'));
      expect(riderMap, contains('_TrackPhase.arriving'));
      expect(riderMap, contains('_TrackPhase.arrived'));
    });
  });
}
