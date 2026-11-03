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
      File('lib/screens/driver/my_reservations_page.dart').readAsStringSync();
  final preview =
      File('lib/widgets/static_route_preview.dart').readAsStringSync();

  // Claiming moved to the reservations MAP (2026-11-03): the list page is
  // only the driver's own reservations, so there is no Requests tab to
  // move from.
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

  // The expanded card's live map, accordion and in-list cancel went with
  // the Lyft-style cards (owner-approved drawing 2026-11-03): the card is
  // shown whole, and cancelling lives on the reservation's own page
  // (reservation_detail_page.dart, the server's 1-hour gate).
}
