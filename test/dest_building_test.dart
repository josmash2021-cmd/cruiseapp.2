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

  group('the drawn line stays off buildings (owner 2026-11-04)', () {
    // A street going north, then the last 30 m turn east into a lot.
    const route = [
      LatLng(33.4480, -86.8000),
      LatLng(33.4500, -86.8000), // ~222 m north
      LatLng(33.4500, -86.79968), // ~30 m east
    ];
    List<LatLng> box(double s, double w, double n, double e) => [
          LatLng(s, w),
          LatLng(s, e),
          LatLng(n, e),
          LatLng(n, w),
          LatLng(s, w),
        ];

    test('the line ends where the route enters a building near its end', () {
      // Building over the last ~15 m of the lane.
      final cut = DestBuilding.tailCutS(
          route, [box(33.44995, -86.79984, 33.45005, -86.79960)])!;
      final total = DestBuilding.lengthM(route);
      expect(total - cut, closeTo(18, 2), reason: "2.5 m short of touching it");
      final drawn = DestBuilding.slice(route, 0, cut);
      expect(drawn.last.longitude, closeTo(-86.79987, 5e-6));
      expect(drawn.first, route.first);
    });

    test('a drive running along the wall stops before it touches it', () {
      // The real Country Club case: the drive hugs the clubhouse 1.5 m off
      // its wall and never crosses it — the line drew over the outline.
      // Wall from 10 m to 25 m before the end, 1.5 m north of the lane.
      const north = 1.5 / 111320;
      final cut = DestBuilding.tailCutS(route, [
        box(33.4500 + north, -86.79995, 33.4502, -86.79979),
      ])!;
      final total = DestBuilding.lengthM(route);
      // The wall starts 4.6 m into the 30 m lane, 1.5 m off it: the line
      // comes within 2.5 m of it sqrt(2.5² − 1.5²) = 2 m before that — 2.6 m
      // into the lane — and stops one 0.5 m step earlier.
      expect(total - cut, closeTo(30 - 2.6 + 0.5, 1.0));
    });

    test('a building it never touches, or one far back, cuts nothing', () {
      expect(
          DestBuilding.tailCutS(
              route, [box(33.4502, -86.79990, 33.4504, -86.79970)]),
          isNull);
      // Over the street 200+ m before the end: outside the tail window.
      expect(
          DestBuilding.tailCutS(
              route, [box(33.44802, -86.80005, 33.44806, -86.79995)]),
          isNull);
    });

    test('slice keeps the trimmed start and the cut end', () {
      final total = DestBuilding.lengthM(route);
      final part = DestBuilding.slice(route, 100, total - 10);
      expect(DestBuilding.lengthM(part), closeTo(total - 110, 0.5));
      expect(DestBuilding.slice(route, 50, 40), isEmpty,
          reason: 'the car passed the cut: no line');
      expect(DestBuilding.slice(route, 0, null), route);
      expect(DestBuilding.pointAt(route, 0), route.first);
      expect(DestBuilding.pointAt(route, 1e6), route.last);
    });
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
    // Every drawing of the line honours the cut; the route itself does not.
    expect(nav, contains('unawaited(_cutRouteTail());'));
    expect(nav, contains(': DestBuilding.slice(pts, s, end)));'));
    expect(nav, contains(
        'end == null ? _routePts : DestBuilding.slice(_routePts, 0, end));'));
    expect(nav, contains('identical(_tailCutFor, _routePts) ? _tailCutS : null;'),
        reason: 'a cut measured on an old line never trims a new one');
  });
}
