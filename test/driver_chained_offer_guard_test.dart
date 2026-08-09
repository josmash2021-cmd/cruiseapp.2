import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the chained (next-ride) offer flow (session 2026-08-09).
///
/// The backend already flags offers `chained` for a driver with an active
/// trip, but the card used to live on DriverOnlineScreen — INVISIBLE under
/// DriverTripAcceptScreen, which is where the trip actually runs. And the
/// booking itself died with that screen at trip end (the rate screen's
/// pushAndRemoveUntil wipes the stack). The flow now lives on the trip
/// screen with a static store carrying the booking across navigations.
///
/// The card needs a live trip, so what a unit test CAN pin is the wiring,
/// the same way picker_camera_guard_test.dart does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final trip =
      File('lib/screens/driver/driver_trip_accept_screen.dart').readAsStringSync();
  final rate =
      File('lib/screens/driver/driver_rate_rider_screen.dart').readAsStringSync();
  final online =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final onlineCtrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();

  group('the trip screen surfaces chained offers', () {
    test('the listener keeps only chained offers', () {
      final start = trip.indexOf('void _onChainedOffers(');
      expect(start, isNonNegative, reason: '_onChainedOffers not found');
      final body = trip.substring(start, start + 900);
      expect(body.contains("o['chained'] != true"), isTrue,
          reason: 'mid-trip the stream carries offers for the online '
              'screen too — only chained ones belong on the trip page');
    });

    test('stream and poll are cancelled in dispose', () {
      final start = trip.indexOf('void dispose() {');
      expect(start, isNonNegative);
      final body = trip.substring(start, start + 500);
      for (final field in ['_chainedSseSub', '_chainedPollTimer']) {
        expect(body.contains('$field?.cancel()'), isTrue,
            reason: '$field leaks past the trip screen — a listener on a '
                'disposed screen re-shows offers that no longer exist');
      }
    });

    test('the card never touches camera or route', () {
      final start = trip.indexOf('Widget _buildChainedOfferCard(');
      expect(start, isNonNegative, reason: 'card builder not found');
      final body = trip.substring(start, start + 3500);
      for (final banned in ['flyTo', 'setCamera', '_fitBounds', 'Polyline']) {
        expect(body.contains(banned), isFalse,
            reason: '$banned in the chained card — the trip being driven '
                'owns the map, the camera and the route');
      }
    });
  });

  group('the booking survives the trip end', () {
    test('accept writes the store', () {
      final start = trip.indexOf('Future<void> _acceptChained(');
      expect(start, isNonNegative, reason: '_acceptChained not found');
      final body = trip.substring(start, start + 1100);
      expect(body.contains('ChainedRideStore.set(offer)'), isTrue,
          reason: 'without the store the booking dies with the online '
              'screen at the rate screen\'s pushAndRemoveUntil');
    });

    test('the rate screen starts the chained trip directly', () {
      expect(rate.contains('ChainedRideStore.hasRide'), isTrue);
      final start = rate.indexOf('Future<bool> _startChainedTrip(');
      expect(start, isNonNegative, reason: '_startChainedTrip not found');
      final body = rate.substring(start, start + 2600);
      expect(body.contains('DriverTripAcceptScreen('), isTrue,
          reason: 'an accepted chained ride must open its pickup page, '
              'not drop the driver on "Finding trips"');
      expect(body.contains('getTrip(tripId)'), isTrue,
          reason: 'liveness check — dispatch may have reassigned the ride '
              'while the rating screen was up');
    });
  });

  group('a cancelled trip hands the booking back', () {
    test('every cancel exit stashes the store', () {
      final exits = 'DriverOnlineScreen.chainedHandoffOffer = ChainedRideStore.take()'
          .allMatches(trip)
          .length;
      expect(exits, greaterThanOrEqualTo(3),
          reason: 'driver-cancel, remote-cancel pop and remote-cancel '
              'fallback must all hand the booking over — one missed exit '
              'loses a ride the driver already accepted');
    });

    test('the online screen consumes the handoff without re-locking', () {
      expect(online.contains('static Map<String, dynamic>? chainedHandoffOffer'),
          isTrue);
      final start = online.indexOf('final chainedHandoff = DriverOnlineScreen.chainedHandoffOffer;');
      expect(start, isNonNegative, reason: 'initState consumption not found');
      final body = online.substring(start, start + 500);
      expect(body.contains('alreadyAcceptedOnBackend: true'), isTrue,
          reason: 're-accepting on the backend would double-lock the ride');
      final ctrl = onlineCtrl.indexOf('void _handoffChainedOffer()');
      final ctrlBody = onlineCtrl.substring(ctrl, ctrl + 500);
      expect(ctrlBody.contains('DriverOnlineScreen.chainedHandoffOffer'),
          isTrue,
          reason: 'the pop-back path (remote cancel) reaches the online '
              'screen through _handoffChainedOffer — it must read the '
              'static half too');
    });
  });
}
