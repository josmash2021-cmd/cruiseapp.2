import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/map/road_network.dart';
import 'package:cruise_app/models/lat_lng.dart';

/// The street line the online arrow rides, read from the map's tiles (owner
/// report 2026-11-02: "la flecha se sale de las vías y luego se pone bien…
/// que gire siguiendo las vías"). Geometry in metres east/north of Pelham.
void main() {
  const lat0 = 33.30, lng0 = -86.80;
  final kx = math.cos(lat0 * math.pi / 180) * 111320.0;
  LatLng m(double east, double north) =>
      LatLng(lat0 + north / 110540.0, lng0 + east / kx);
  (double, double) xy(LatLng p) =>
      ((p.longitude - lng0) * kx, (p.latitude - lat0) * 110540.0);
  double len(List<LatLng> l) {
    var s = 0.0;
    for (var i = 0; i < l.length - 1; i++) {
      final a = xy(l[i]), b = xy(l[i + 1]);
      s += math.sqrt(math.pow(b.$1 - a.$1, 2) + math.pow(b.$2 - a.$2, 2));
    }
    return s;
  }

  group('picks the street the car is on', () {
    test('a curve: the line ahead follows the curve, not a straight ray',
        () {
      // Quarter circle, radius 80 m, centred at (0, 80): from (0,0) heading
      // east, bending north.
      final arc = [
        for (var i = 0; i <= 18; i++)
          m(80 * math.sin(i * math.pi / 36), 80 - 80 * math.cos(i * math.pi / 36)),
      ];
      final net = RoadNetwork([arc]);
      final path = net.pathFor(m(10, 2), headingDeg: 90, speedMps: 12)!;
      // Every point of the line sits on the circle (radius 80 ± 1 m).
      for (final p in path) {
        final (x, y) = xy(p);
        final r = math.sqrt(x * x + (y - 80) * (y - 80));
        expect((r - 80).abs(), lessThan(1.0), reason: 'off the curve at $x,$y');
      }
      // …and it reaches the far end of the bend, well past the car.
      final (ex, ey) = xy(path.last);
      expect(ex, greaterThan(75));
      expect(ey, greaterThan(70));
    });

    test('carries on across a split way and across a tile overlap', () {
      final a = [m(0, 0), m(110, 0)];
      final b = [m(100, 0.4), m(250, 0.4)]; // tile overlap, 0.4 m apart
      final c = [m(250, 0.4), m(420, 0.4)]; // the way split at a crossing
      final net = RoadNetwork([a, b, c]);
      final path = net.pathFor(m(20, 3), headingDeg: 90, speedMps: 15)!;
      final (ex, _) = xy(path.last);
      expect(ex, closeTo(20 + RoadNetwork.aheadM, 2.0));
    });

    test('a corner is not taken for the car: the line stops there', () {
      final a = [m(0, 0), m(100, 0)];
      final side = [m(100, 0), m(100, 150)]; // 90° turn at the end
      final net = RoadNetwork([a, side]);
      final path = net.pathFor(m(30, 2), headingDeg: 90, speedMps: 10)!;
      final (ex, ey) = xy(path.last);
      expect(ex, closeTo(100, 0.5));
      expect(ey, closeTo(0, 0.5));
    });

    test('the line points the way the car drives', () {
      final net = RoadNetwork([
        [m(0, 0), m(300, 0)]
      ]);
      final west = net.pathFor(m(150, 2), headingDeg: 270, speedMps: 10)!;
      expect(xy(west.first).$1, greaterThan(xy(west.last).$1));
      final east = net.pathFor(m(150, 2), headingDeg: 90, speedMps: 10)!;
      expect(xy(east.first).$1, lessThan(xy(east.last).$1));
    });

    test('at a crossing the street along the course wins, not the cross one',
        () {
      final ew = [m(-200, 0), m(200, 0)];
      final ns = [m(3, -200), m(3, 200)]; // 3 m east of the fix
      final net = RoadNetwork([ew, ns]);
      final path = net.pathFor(m(0, 4), headingDeg: 90, speedMps: 12)!;
      for (final p in path) {
        expect(xy(p).$2.abs(), lessThan(0.5), reason: 'took the cross street');
      }
    });

    test('a parallel street never steals the arrow on noise alone', () {
      final a = [m(-200, 0), m(200, 0)];
      final b = [m(-200, 12), m(200, 12)];
      final net = RoadNetwork([a, b]);
      final first = net.pathFor(m(0, 2), headingDeg: 90, speedMps: 12)!;
      // Next fix drifts toward b (7 m from b, 5 m… now 7 from a).
      final next = net.pathFor(m(10, 7), headingDeg: 90, speedMps: 12,
          previousPath: first)!;
      for (final p in next) {
        expect(xy(p).$2.abs(), lessThan(0.5), reason: 'jumped to b');
      }
    });
  });

  group('says nothing when it cannot vouch', () {
    test('a parked car beside the road is not drawn on it', () {
      final net = RoadNetwork([
        [m(0, 0), m(300, 0)]
      ]);
      expect(net.pathFor(m(100, 14), headingDeg: 90, speedMps: 0), isNull);
      expect(net.pathFor(m(100, 6), headingDeg: 90, speedMps: 0), isNotNull);
    });

    test('far from every street: null, the caller keeps its fallback', () {
      final net = RoadNetwork([
        [m(0, 0), m(300, 0)]
      ]);
      expect(net.pathFor(m(100, 60), headingDeg: 90, speedMps: 10), isNull);
      expect(RoadNetwork(const []).pathFor(m(0, 0)), isNull);
    });
  });

  group('reads the rendered features', () {
    Map<String, Object?> feat(String cls, String type, Object coords) => {
          'properties': {'class': cls},
          'geometry': {'type': type, 'coordinates': coords},
        };

    test('drivable lines only, multi-lines split, junk skipped', () {
      final lines = RoadNetwork.parseFeatures([
        feat('street', 'LineString', [
          [-86.8, 33.3],
          [-86.79, 33.3]
        ]),
        feat('primary', 'MultiLineString', [
          [
            [-86.8, 33.31],
            [-86.79, 33.31]
          ],
          [
            [-86.8, 33.32],
            [-86.79, 33.32]
          ],
        ]),
        feat('path', 'LineString', [
          [-86.8, 33.33],
          [-86.79, 33.33]
        ]),
        feat('street', 'Point', [-86.8, 33.3]),
        {'properties': 'x'},
        null,
        feat('street', 'LineString', [
          ['a', 1]
        ]),
      ]);
      expect(lines.length, 3);
      expect(lines.first.first.latitude, 33.3);
      expect(lines.first.first.longitude, -86.8);
    });

    test('the same road from two style layers counts once', () {
      final line = [m(0, 0), m(100, 0), m(200, 0)];
      final net = RoadNetwork([line, List.of(line), line.reversed.toList()]);
      expect(net.lineCount, 1);
      // …so the line still runs its whole length past the car.
      final path = net.pathFor(m(20, 1), headingDeg: 90, speedMps: 10)!;
      expect(len(path), closeTo(180 + 20, 1.0));
    });
  });
}
