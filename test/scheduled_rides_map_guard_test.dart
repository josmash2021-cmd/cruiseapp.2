import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the Lyft-structure / Cruise-visual scheduled-rides map
/// screen.
///
/// Pure source-grep (same style as driver_scheduled_neu_guard_test.dart):
/// the screen needs network, GPS and a native map, so what a unit test CAN
/// pin is that the load-bearing pieces are wired where they belong:
///   1. The map-surface owner id is unique per instance — a shared static
///      id makes the coordinator skip the revoke, the old surface stays
///      alive underneath, and two native MapWidgets crash iOS.
///   2. The Reserve button lives INSIDE the sheet flow, below the ride
///      card — the old floating pill over the map is gone for good.
///   3. The claim keeps the 403/409 error mapping (409 = another driver
///      took it) so the loser reads a sentence instead of a raw exception.
void main() {
  final screen = File('lib/screens/driver/scheduled_rides_map_screen.dart')
      .readAsStringSync();

  group('map surface ownership', () {
    test('owner id is unique per instance', () {
      expect(screen, contains('static int _nextMapSurfaceId'));
      expect(screen, contains("'ScheduledRidesMap-"));
      expect(screen, contains('++_nextMapSurfaceId'));
    });

    test('claims and releases the one surface via the coordinator', () {
      expect(screen, contains('MapSurfaceCoordinator.instance.acquire('));
      expect(screen, contains('MapSurfaceCoordinator.instance.release('));
      expect(screen, contains('surfaceRemoved()'));
    });
  });

  group('reserve button placement', () {
    // The card builder must not contain the Reserve button — it rides below
    // the card inside the detail sheet, never floating over the map.
    final cardStart = screen.indexOf('Widget _rideCard(');
    final cardEnd = screen.indexOf('Widget _offerMetric(');
    final cardBlock = cardStart >= 0 && cardEnd > cardStart
        ? screen.substring(cardStart, cardEnd)
        : '';

    test('the ride card does not contain the reserve button', () {
      expect(cardBlock, isNotEmpty,
          reason: '_rideCard builder not found — structure changed?');
      expect(cardBlock.contains('_buildReserveButton'), isFalse);
      expect(cardBlock.contains('schedMapReserve'), isFalse);
    });

    test('reserve sits below the card inside the detail sheet', () {
      final sheetStart = screen.indexOf('Widget _buildDetailSheet(');
      expect(sheetStart, greaterThan(-1));
      final sheetBlock = screen.substring(sheetStart, sheetStart + 1200);
      final cardIdx = sheetBlock.indexOf('_rideCard(trip)');
      final reserveIdx = sheetBlock.indexOf('_buildReserveButton(s, trip)');
      expect(cardIdx, greaterThan(-1));
      expect(reserveIdx, greaterThan(cardIdx),
          reason:
              'Reserve must build after the card inside _buildDetailSheet — in the sheet flow, below the card.');
    });

    test('no floating reserve pill survives in the root Stack', () {
      expect(screen.contains('_buildReservePill'), isFalse,
          reason:
              'The old floating RESERVE pill over the map was removed — do not bring it back.');
    });
  });

  group('claim error mapping', () {
    final claimStart = screen.indexOf('Future<void> _claimTrip');
    final claimBlock = claimStart >= 0
        ? screen.substring(claimStart, claimStart + 2000)
        : '';

    test('403 maps to the out-of-state sentence', () {
      expect(claimBlock, contains('e.statusCode == 403'));
      expect(claimBlock, contains('scheduledOutOfState'));
    });

    test('409 maps to scheduledRideTaken', () {
      expect(claimBlock, contains('e.statusCode == 409'));
      final idx = claimBlock.indexOf('e.statusCode == 409');
      expect(
          claimBlock.substring(idx, idx + 200), contains('scheduledRideTaken'));
    });

    test('success haptic + list refresh on claim', () {
      expect(claimBlock, contains('HapticService.mediumImpact()'));
      expect(claimBlock, contains('_loadAvailable(force: true)'));
    });
  });

  group('push deep-link into the ride detail (user spec 2026-09-27)', () {
    test('the screen takes initialTripId and selects it once data + map are up',
        () {
      expect(screen, contains('final int? initialTripId'));
      expect(screen, contains('_pendingSelectTripId = widget.initialTripId'));
      expect(screen, contains('void _tryConsumePendingSelect()'),
          reason: 'the selection waits for BOTH the fresh list and the live '
              'map — drawing the route pre-map leaves a detail with no line');
      expect(screen, contains('_selectTrip(hit)'));
    });

    test('a trip gone from the fresh list gets an honest toast', () {
      expect(screen, contains('scheduledRideNoLongerAvailable'),
          reason: 'claimed by another driver / filtered out must never be a '
              'silent no-op');
    });

    test('main.dart routes the scheduled_ride tap to this screen', () {
      final main = File('lib/main.dart').readAsStringSync();
      expect(main.contains("if (type == 'scheduled_ride')"), isTrue,
          reason: 'before this there was NO handler — the tap did nothing');
      expect(
          main.contains('ScheduledRidesMapScreen(initialTripId: tripId)'),
          isTrue);
      expect(main.contains("if (mode != 'driver') return;"), isTrue,
          reason: 'the marketplace is drivers-only — role gate on the tap');
    });

    test('the backend fan-out replaced the country-wide topic broadcast', () {
      final trips = File('backend/routers/trips.py').readAsStringSync();
      final payments = File('backend/routers/payments.py').readAsStringSync();
      final broadcast =
          File('backend/services/scheduled_broadcast.py').readAsStringSync();
      expect(trips.contains('notify_new_scheduled_ride(trip.id)'), isTrue);
      expect(payments.contains('notify_new_scheduled_ride(trip.id)'), isTrue);
      expect(trips.contains('topic="drivers_available"'), isFalse,
          reason: 'the state-less broadcast is what spammed every driver in '
              'the country — it must not come back');
      expect(broadcast.contains('_state_for'), isTrue,
          reason: 'the state filter is the headline ask');
      expect(broadcast.contains('"Open to accept the ride"'), isTrue,
          reason: 'bare body — no price, no addresses');
    });
  });
}
