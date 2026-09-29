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

  group('expanded card live map (user spec 2026-09-27)', () {
    test('the expanded card layers the live map over the still', () {
      expect(screen, contains('class _CardLiveMap extends StatefulWidget'));
      expect(screen, contains('if (widget.expanded && !kIsWeb)'),
          reason: 'the still stays the placeholder AND the whole preview on '
              'web — mapbox_maps_flutter does not run there');
    });

    test('the one-surface rule holds: accordion + coordinator', () {
      expect(screen, contains('int? _expandedTripId'),
          reason: 'one expanded card at a time — two live native surfaces '
              'is the iOS crash this redesign had once already');
      expect(screen, contains("'SchedRideCard-\${widget.tripId}'"));
      expect(screen, contains('MapSurfaceCoordinator.instance.acquire'));
      expect(screen, contains('MapSurfaceCoordinator.instance.release(owner)'),
          reason: 'collapse releases after the teardown window so a sibling '
              'card never mounts into a half-dead surface');
    });

    test('the app look: navy theme, circular pins, 50 tilt, gold round route',
        () {
      expect(screen, contains('MapTheme.applyNavyGold(m)'),
          reason: 'the navy/gold every live map wears — its absence is what '
              'made the still read as a different app');
      expect(screen, contains('CircularPinIcon.person'));
      expect(screen, contains('CircularPinIcon.flag'));
      expect(screen, contains('pitch: 50.0'),
          reason: 'the tilt animation the user asked for');
      expect(screen, contains('lineJoin: mapbox.LineJoin.ROUND'));
    });

    test('the preview stays non-interactive so the card tap still collapses',
        () {
      expect(screen, contains('child: IgnorePointer('));
      expect(screen, contains('scrollEnabled: false'));
    });

    test('the online map re-claims the surface when the screen pops', () {
      final offline =
          File('lib/screens/driver/driver_online_offline.dart')
              .readAsStringSync();
      final pushStart =
          offline.indexOf('const ScheduledRidesScreen(initialTab: 0)');
      final block = offline.substring(pushStart, pushStart + 800);
      expect(block, contains('_remountMapSurface()'),
          reason: 'the card map revokes the online map through the '
              'coordinator — on pop it must come back');
    });

    test('the 1-hour cancel window matches the server gate exactly', () {
      expect(screen, contains('> const Duration(hours: 1)'),
          reason: 'server rejects <= 60 min (scheduled.py '
              '_require_cancel_notice_window) — the UI must not offer what '
              'the server will refuse');
    });
  });
}
