import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the Uber-style scheduled-rides map screen.
///
/// Pure source-grep (same style as driver_scheduled_neu_guard_test.dart):
/// the screen needs network, GPS and a native map, so what a unit test CAN
/// pin is that the load-bearing pieces are wired where they belong:
///   1. The map-surface owner id is unique per instance — a shared static
///      id makes the coordinator skip the revoke, the old surface stays
///      alive underneath, and two native MapWidgets crash iOS.
///   2. The Reserve pill floats over the map as a sibling of the sheet in
///      the root Stack — never a child of the ride card, with no dark box
///      behind it.
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

  group('reserve pill placement', () {
    // The card builder must not contain the Reserve pill — it lives in the
    // root Stack, positioned over the map above the detail sheet.
    final cardStart = screen.indexOf('Widget _rideCard(');
    final cardEnd = screen.indexOf('//  Shared card parts');
    final cardBlock = cardStart >= 0 && cardEnd > cardStart
        ? screen.substring(cardStart, cardEnd)
        : '';

    test('the ride card does not contain the reserve button', () {
      expect(cardBlock, isNotEmpty,
          reason: '_rideCard builder not found — structure changed?');
      expect(cardBlock.contains('_buildReservePill'), isFalse);
      expect(cardBlock.contains('schedMapReserve'), isFalse);
    });

    test('the reserve pill is a root-stack sibling, after the sheet', () {
      final stackIdx = screen.indexOf('body: Stack(');
      final sheetIdx = screen.indexOf('DraggableScrollableSheet(');
      final reserveIdx = screen.indexOf('_buildReservePill(s, _selected!)');
      expect(stackIdx, greaterThan(-1));
      expect(sheetIdx, greaterThan(stackIdx));
      expect(reserveIdx, greaterThan(sheetIdx),
          reason:
              'Reserve must build after the sheet in the root Stack so it floats over the map, outside the card.');
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
}
