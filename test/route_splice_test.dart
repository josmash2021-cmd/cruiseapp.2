import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/utils/route_splice.dart';

/// The splice is what makes a re-route redraw ONLY the affected stretch of
/// the line: a wrong cut point either resurrects the old path the driver
/// abandoned or wipes road they have already driven back onto the screen.
/// Pure maths — pinned down here, not on a phone.
void main() {
  // East-west route along lat 33.0, points every 0.005° lng (~470 m).
  final oldRoute = [
    for (var i = 0; i <= 20; i++) LatLng(33.0, -87.0 + i * 0.005),
  ];

  group('distanceToPolylineM', () {
    test('perpendicular distance to the middle of a long segment', () {
      // 0.001° latitude ≈ 111 m.
      final d = RouteSplice.distanceToPolylineM(
        [const LatLng(33.0, -87.0), const LatLng(33.0, -86.0)],
        const LatLng(33.001, -86.5),
      );
      expect(d, closeTo(111, 8));
    });

    test('a point on the line measures ~0', () {
      final d = RouteSplice.distanceToPolylineM(oldRoute, const LatLng(33.0, -86.9625));
      expect(d, lessThan(1.0));
    });

    test('empty polyline is infinitely far', () {
      expect(RouteSplice.distanceToPolylineM(const [], const LatLng(1, 1)),
          double.infinity);
    });
  });

  group('closestSegmentIndex', () {
    test('finds the segment the driver left the route at', () {
      final idx = RouteSplice.closestSegmentIndex(
          oldRoute, const LatLng(33.002, -86.945));
      // -86.945 sits on segment 10 (-86.950 → -86.945) — the vertex shared
      // with segment 11, so either neighbour is a correct answer.
      expect(idx, anyOf(10, 11));
    });
  });

  group('splice', () {
    test('rejoins: keeps the driven head and the untouched tail', () {
      // Driver went off-route near lng -86.97 and the router brought them
      // back onto the old line at lng -86.94 (last point ~5 m off it).
      final newRoute = [
        const LatLng(33.002, -86.970),
        const LatLng(33.002, -86.960),
        const LatLng(33.001, -86.950),
        const LatLng(33.00005, -86.940),
      ];
      final spliced = RouteSplice.splice(
        oldRoute: oldRoute,
        newRoute: newRoute,
        driverPos: const LatLng(33.002, -86.970),
      );

      // Head and tail survive verbatim.
      expect(spliced.first, oldRoute.first);
      expect(spliced.last, oldRoute.last);
      // The detour path is in the middle.
      expect(spliced.contains(newRoute[1]), isTrue);
      expect(spliced.contains(newRoute[2]), isTrue);
      // The abandoned stretch of the old route is gone: nothing on the old
      // latitude between the deviation and the rejoin.
      final abandoned = spliced.where((p) =>
          p.latitude == 33.0 &&
          p.longitude > -86.965 &&
          p.longitude < -86.945);
      expect(abandoned, isEmpty);
      // The tail past the rejoin is the old route's own geometry.
      expect(spliced.contains(const LatLng(33.0, -86.935)), isTrue);
    });

    test('the tail past the rejoin survives point for point', () {
      // The whole point of splicing instead of replacing: everything the
      // driver has not deviated from must come out byte-identical, so the
      // map redraws only the affected stretch.
      final newRoute = [
        const LatLng(33.002, -86.970),
        const LatLng(33.002, -86.960),
        const LatLng(33.00005, -86.940), // rejoins ~5 m off vertex 12
      ];
      final spliced = RouteSplice.splice(
        oldRoute: oldRoute,
        newRoute: newRoute,
        driverPos: const LatLng(33.002, -86.970),
      );

      // Deviation lands on segment 5 (vertex -86.970), the rejoin on
      // segment 11 (vertex 12, -86.940): head 6 + detour 3 + tail 9.
      expect(spliced.length, 18);
      // Head: every old vertex before the deviation, in order, unchanged.
      expect(spliced.sublist(0, 6), oldRoute.sublist(0, 6));
      // Detour: the new geometry, whole.
      expect(spliced.sublist(6, 9), newRoute);
      // Tail: every old vertex from the rejoin onward, in order, unchanged.
      expect(spliced.sublist(9), oldRoute.sublist(12));
    });

    test('no rejoin within tolerance → full replacement', () {
      // A parallel road ~1.1 km north that never comes back near the old one.
      final newRoute = [
        for (var i = 0; i <= 10; i++) LatLng(33.01, -86.98 + i * 0.005),
      ];
      final spliced = RouteSplice.splice(
        oldRoute: oldRoute,
        newRoute: newRoute,
        driverPos: const LatLng(33.01, -86.98),
      );
      expect(spliced, newRoute);
    });

    test('rejoin at the destination still replaces only the tail', () {
      // New route ends exactly at the old destination: the rejoin is found
      // on the very last new point, so the splice is old head + new route.
      final newRoute = [
        const LatLng(33.002, -86.970),
        const LatLng(33.001, -86.930),
        oldRoute.last,
      ];
      final spliced = RouteSplice.splice(
        oldRoute: oldRoute,
        newRoute: newRoute,
        driverPos: const LatLng(33.002, -86.970),
      );
      expect(spliced.first, oldRoute.first);
      expect(spliced.last, oldRoute.last);
      expect(spliced.contains(newRoute[1]), isTrue);
    });

    test('driver far beyond maxHeadGap → wholesale, never a connector', () {
      // Driver 0.01° lat (~1.1 km) off the plan: keeping the old head
      // would paint a kilometre-long straight connector on legs with no
      // erase. The splice must hand back the fresh route untouched.
      final newRoute = [
        const LatLng(33.01, -86.970),
        const LatLng(33.005, -86.950),
        const LatLng(33.00005, -86.940), // ends ~5 m off the old line
      ];
      final spliced = RouteSplice.splice(
        oldRoute: oldRoute,
        newRoute: newRoute,
        driverPos: const LatLng(33.01, -86.970),
      );
      expect(spliced, newRoute);
    });

    test('degenerate inputs fall back to the usable route', () {
      final newRoute = [const LatLng(33.0, -86.9), const LatLng(33.0, -86.8)];
      expect(
        RouteSplice.splice(
          oldRoute: const [],
          newRoute: newRoute,
          driverPos: const LatLng(33.0, -86.9),
        ),
        newRoute,
      );
      // New route unusable → keep the old one.
      expect(
        RouteSplice.splice(
          oldRoute: oldRoute,
          newRoute: const [LatLng(33.0, -86.9)],
          driverPos: const LatLng(33.0, -86.95),
        ),
        oldRoute,
      );
    });
  });
}
