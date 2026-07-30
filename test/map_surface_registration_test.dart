import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Two live Mapbox surfaces close the app on iOS. The rule that keeps that
/// from happening is: **a screen that mounts a MapWidget must claim
/// MapSurfaceCoordinator**, so the screen underneath is revoked and gone
/// before the new one mounts.
///
/// Nothing in the type system enforces that, and the cost of forgetting is
/// not a warning — it is the app closing when the driver opens a screen.
/// `DriverHomeScreen.didPushNext` deliberately keeps its map alive under
/// menus, and that is only safe while this holds. It was wrong once: the
/// scheduled-rides screens mounted maps without asking anyone, and every tap
/// that opened one crashed.
///
/// So it is checked here instead.
void main() {
  // Files that mount a MapWidget without claiming the surface themselves,
  // each with the reason it is safe. Adding to this list is a decision, not
  // a formality — say why.
  const allowed = <String, String>{
    // `part of` a screen that does claim it.
    'lib/screens/home_screen_widgets.dart': 'part of home_screen.dart',
    'lib/screens/ride_request_widgets.dart': 'part of ride_request_screen.dart',
    'lib/screens/driver/driver_online_widgets.dart':
        'part of driver_online_screen.dart',
    'lib/widgets/tracking/tracking_map_view.dart':
        'part of rider_tracking_screen.dart',

    // Terminal screens reached by pushReplacement/pushAndRemoveUntil, so the
    // screen they replace is torn down rather than stacked under them.
    'lib/screens/rider_rating_screen.dart': 'pushReplacement from tracking',
    'lib/screens/ride_booking_confirmed_screen.dart':
        'pushAndRemoveUntil from the booking flow',

    // Not reachable: no call sites.
    'lib/screens/waiting_for_driver_screen.dart': 'route helper has no callers',
    'lib/screens/rider_map_shell_screen.dart': 'referenced only in a doc comment',

    // Opened from the rider home, which claims the surface and hands it over.
    // Mounts nothing else with a map.
    'lib/screens/scheduled_rides_screen.dart': 'leaf screen, one map',
  };

  test('every screen with a MapWidget claims the map surface', () {
    final offenders = <String>[];

    for (final dir in ['lib/screens', 'lib/widgets']) {
      final root = Directory(dir);
      if (!root.existsSync()) continue;
      for (final entity in root.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        final rel = entity.path.replaceAll(r'\', '/');
        final src = entity.readAsStringSync();
        if (!src.contains('MapWidget(')) continue;
        if (src.contains('MapSurfaceCoordinator')) continue;
        if (allowed.containsKey(rel)) continue;
        offenders.add(rel);
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'These mount a Mapbox surface without claiming '
          'MapSurfaceCoordinator, so two can be alive at once — which closes '
          'the app on iOS. Either claim the surface (see map_picker_screen.dart '
          'for the pattern), use StaticRoutePreview if it is only a thumbnail, '
          'or add it to the allowlist in this test with the reason it is safe.',
    );
  });

  test('the allowlist has no stale entries', () {
    final stale = allowed.keys
        .where((p) => !File(p).existsSync() || !File(p).readAsStringSync().contains('MapWidget('))
        .toList();
    expect(
      stale,
      isEmpty,
      reason: 'These no longer mount a MapWidget — drop them from the '
          'allowlist so it keeps meaning something.',
    );
  });
}
