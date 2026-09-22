import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the scheduled-rides neu redesign + claim auto-move.
///
/// Pure source-grep (same style as picker_camera_guard_test.dart): the
/// screen needs network and GPS, so what a unit test CAN pin is that the
/// redesign's load-bearing pieces are wired where they belong:
///   1. After a successful claim the driver lands on My Rides and both
///      lists refresh — the card leaves Requests instead of staying behind
///      as a persistent "Claimed" badge.
///   2. The screen wears the shared neu system (neuBase ground, neuBox
///      cards) rather than ad-hoc backgrounds and shadows.
///   3. The static route preview carries lettered pins (p/d) and the
///      lightened navy veil — at half strength the white dropoff pin came
///      out grey.
void main() {
  final screen =
      File('lib/screens/driver/scheduled_rides_screen.dart').readAsStringSync();
  final preview =
      File('lib/widgets/static_route_preview.dart').readAsStringSync();

  group('claim auto-move to My Rides', () {
    final claimStart = screen.indexOf('Future<void> _claimTrip');
    final claimBlock = screen.substring(claimStart, claimStart + 2200);

    test('animates to the My Rides tab', () {
      expect(claimBlock, contains('animateTo(1)'));
    });

    test('refreshes both lists so the card leaves Requests', () {
      expect(claimBlock, contains('_loadMyRides(force: true)'));
      expect(claimBlock, contains('_loadAvailable(force: true)'));
    });
  });

  group('neu system', () {
    test('the screen is built on neuBase', () {
      expect(screen, contains('neuBase'));
    });

    test('the cards use the shared neuBox decoration', () {
      expect(screen, contains('neuBox('));
    });
  });

  group('static route preview pins and veil', () {
    test('pickup pin is the lettered gold pin (small by default for chips)', () {
      expect(preview, contains("this.pinSize = 's'"),
          reason: 'the scheduled cards keep the small chip pin by default');
      expect(preview, contains('pin-\$pinSize-p+E8C547'));
    });

    test('dropoff pin is the lettered white pin', () {
      expect(preview, contains('pin-\$pinSize-d+FFFFFF'));
    });

    test('the navy veil is lightened so the white pin stays white', () {
      expect(preview, contains('alpha: 0.30'));
    });
  });
}
