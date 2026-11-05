import 'dart:io';

import 'package:cruise_app/map/dest_building.dart';
import 'package:cruise_app/models/lat_lng.dart';
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-04 (Lyft photos): the building at the trip's address is
/// outlined in gold on the navigation map.
void main() {
  // ~1e-4 deg ≈ 11 m lat / ~9 m lng at 33.4°N (Birmingham).
  const dest = LatLng(33.4500, -86.8000);

  Map<String, Object?> square(Object? id, double lat, double lng, double h) => {
        'id': id,
        'geometry': {
          'type': 'Polygon',
          'coordinates': [
            [
              [lng - h, lat - h],
              [lng + h, lat - h],
              [lng + h, lat + h],
              [lng - h, lat + h],
              [lng - h, lat - h],
            ]
          ],
        },
      };

  test('the building containing the address wins', () {
    final rings = DestBuilding.pick([
      square(1, 33.4503, -86.8000, 0.0001), // next door
      square(2, 33.4500, -86.8000, 0.0002), // around the address
    ], dest)!;
    expect(rings, hasLength(1));
    expect(DestBuilding.contains(rings.single, dest), isTrue);
  });

  test('an address at the front of the lot takes the nearest building', () {
    final rings = DestBuilding.pick([
      square(7, 33.45025, -86.8000, 0.0001), // edge ~16 m north
      square(8, 33.4510, -86.8000, 0.0001), // far
    ], dest)!;
    expect(rings.single.first.latitude, closeTo(33.45015, 1e-9));
  });

  test('no building close enough draws nothing', () {
    expect(
        DestBuilding.pick([square(1, 33.4510, -86.8000, 0.0001)], dest), isNull);
    expect(DestBuilding.pick(const [], dest), isNull);
  });

  test('a footprint cut by a tile edge comes back whole, once', () {
    final west = square(5, 33.4500, -86.80005, 0.00005);
    final east = square(5, 33.4500, -86.79995, 0.00005);
    final rings = DestBuilding.pick([west, east, west, square(6, 33.452, -86.8, 0.0001)], dest)!;
    expect(rings, hasLength(2), reason: 'both pieces, the twin dropped');
  });

  test('MultiPolygon and open rings are read', () {
    final rings = DestBuilding.pick([
      {
        'id': 3,
        'geometry': {
          'type': 'MultiPolygon',
          'coordinates': [
            [
              [
                [-86.8002, 33.4498],
                [-86.7998, 33.4498],
                [-86.7998, 33.4502],
                [-86.8002, 33.4502],
              ]
            ]
          ],
        },
      }
    ], dest)!;
    expect(rings.single.first, rings.single.last, reason: 'closed for drawing');
  });

  test('the nav draws it under the route, from the map\'s own buildings', () {
    final nav = File('lib/screens/driver/driver_nav_view.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final created = nav.indexOf('_bldgFillMgr = await ctrl.annotations');
    final route = nav.indexOf(
        '_polyMgr = await ctrl.annotations.createPolylineAnnotationManager();');
    expect(created, greaterThan(-1));
    expect(created, lessThan(route), reason: 'the line and pins draw over it');
    expect(nav, contains("l.type == 'fill' && l.id.startsWith('building')"));
    expect(nav, contains('DestBuilding.pick('));
    expect(nav, contains('unawaited(_findDestBuilding());'));
    expect(nav, contains('_bldgFillMgr = null;'),
        reason: 'a dead surface drops its handles (rule: stale handles)');
  });
}
