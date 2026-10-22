import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/data/us_airports_geo.dart';

/// Guard for the gold airport pills on the driver's map (2026-10-22 owner
/// spec): the big commercial airports of the driver's working state, visual
/// only, in BOTH searching views (offline zone map + online "Finding
/// trips"), hidden beyond zoom 8.5 and during navigation.
void main() {
  final data = File('lib/data/us_airports_geo.dart').readAsStringSync();
  final map =
      File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
  final widgets = File('lib/screens/driver/driver_online_widgets.dart')
      .readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final controller = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();

  test('dataset: the big airports of AL and FL with coordinates', () {
    for (final code in ['BHM', 'HSV', 'MOB', 'MGM']) {
      expect(data, contains("code: '$code'"), reason: '$code missing (AL)');
    }
    for (final code in ['MIA', 'FLL', 'MCO', 'TPA', 'JAX', 'RSW', 'PBI']) {
      expect(data, contains("code: '$code'"), reason: '$code missing (FL)');
    }
  });

  test('airportsForState filters by working state, case-insensitive', () {
    final al = airportsForState('al');
    expect(al.map((a) => a.code), containsAll(['BHM', 'HSV', 'MOB', 'MGM']));
    expect(al.every((a) => a.state == 'AL'), isTrue);
    final fl = airportsForState('FL');
    expect(fl.map((a) => a.code), contains('MIA'));
    expect(fl.every((a) => a.state == 'FL'), isTrue);
    expect(airportsForState(null), isEmpty);
    expect(airportsForState('TX'), isEmpty,
        reason: 'no hay dataset TX — sin aeropuertos, sin píldoras');
  });

  test('the overlay rides the zone-pill pipeline with the right gates', () {
    expect(map, contains('Widget _airportPillOverlay()'));
    expect(map, contains('FlatMapProjection.screenOffsetHeading'));
    expect(map, contains('cam.zoom < 8.5'),
        reason: 'hidden at far zoom — no clutter');
    expect(map, contains('_Phase.searching'),
        reason: 'only while searching — never during navigation');
    expect(map, contains('_mapStyleLoaded'),
        reason: 'never over the remount veil, like the zone labels');
  });

  test('visual only — no tap ever reaches the pill', () {
    final fn = map.indexOf('Widget _airportPillOverlay()');
    final region =
        map.substring(fn, (fn + 3800).clamp(0, map.length));
    expect(region, contains('IgnorePointer('));
    expect(region.contains('GestureDetector'), isFalse);
    expect(region.contains('onTap'), isFalse);
    expect(region, contains('Icons.flight_rounded'));
  });

  test('mounted in the map widget, state from the profile drive_state', () {
    expect(widgets, contains('Positioned.fill(child: _airportPillOverlay())'));
    expect(screen, contains('String? _driveStateCode'));
    expect(screen, contains("import '../../data/us_airports_geo.dart';"));
    expect(controller, contains('_ensureAirportState'));
    expect(controller, contains("me?['drive_state']"));
    expect(screen, contains('unawaited(_ensureAirportState())'));
  });
}
