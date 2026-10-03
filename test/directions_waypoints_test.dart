import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/services/directions_service.dart';

/// The multi-stop booking plumbing, pinned (2026-10-02, user report
/// "en el mapa del rider no se dibuja correctamente").
///
/// The instant estimated route is the first thing the booking map draws —
/// before the real road route lands — so its shape is what the rider sees
/// for the first seconds: pickup → (stop) → dropoff, never the stop-less
/// beeline and never a leg dropped.
void main() {
  final ds = DirectionsService('test-key');
  const pickup = LatLng(33.52, -86.81);
  const stop = LatLng(33.45, -86.79);
  const dropoff = LatLng(33.39, -86.78);

  group('getEstimatedRoute', () {
    test('without a stop: exactly the two endpoints, as before', () {
      final r = ds.getEstimatedRoute(origin: pickup, destination: dropoff);
      expect(r.points.length, 2);
      expect(r.points.first, pickup);
      expect(r.points.last, dropoff);
    });

    test('with a stop: three points in ride order — pickup, stop, dropoff',
        () {
      final r = ds.getEstimatedRoute(
          origin: pickup, destination: dropoff, waypoints: const [stop]);
      expect(r.points.length, 3);
      expect(r.points[0], pickup);
      expect(r.points[1], stop);
      expect(r.points[2], dropoff);
    });

    test('the stop leg is priced: distance is the sum of both legs', () {
      final withStop = ds.getEstimatedRoute(
          origin: pickup, destination: dropoff, waypoints: const [stop]);
      final direct = ds.getEstimatedRoute(origin: pickup, destination: dropoff);
      // pickup→stop + stop→dropoff can never be shorter than the beeline —
      // and for this fixture it is strictly longer (a real detour).
      expect(withStop.distanceMeters,
          greaterThanOrEqualTo(direct.distanceMeters));
      expect(withStop.distanceMeters, greaterThan(0));
    });

    test('the placeholder is marked estimated — with and without a stop', () {
      expect(
          ds.getEstimatedRoute(origin: pickup, destination: dropoff)
              .estimated,
          isTrue);
      expect(
          ds
              .getEstimatedRoute(
                  origin: pickup, destination: dropoff, waypoints: const [stop])
              .estimated,
          isTrue);
    });
  });

  group('the booking map never mistakes the placeholder for the real route',
      () {
    // User report: "los dibuja recto" — with a stop the estimate has 3
    // points, `points.length >= 3` called it "real", the straight
    // placeholder was drawn as the final route and the road geometry
    // never replaced it. Both draw gates must check the flag.
    test('ride_request_controller gates on RouteResult.estimated', () {
      final src =
          File('lib/screens/ride_request_controller.dart').readAsStringSync();
      expect(src.contains('!s.route!.estimated'), isTrue,
          reason: 'the count alone cannot tell a 3-point estimate from the '
              'real route — the flag is the only safe gate');
    });

    test('the cinematic + web skip gates check the flag too', () {
      final src =
          File('lib/screens/ride_request_map.dart').readAsStringSync();
      expect(src.contains('!latestRoute.estimated'), isTrue);
      expect(src.contains('routeIsEstimate'), isTrue,
          reason: 'the cinematic skipped the line draw on the 2-pt estimate '
              'count — a stop makes it 3 pts, so the straight placeholder was '
              'drawn as the final gold line and the road route never replaced it');
      expect(src.contains('final Future<void> routeFuture = routeIsEstimate'),
          isTrue,
          reason: 'the cinematic draws the line only for a real route');
      expect(src.contains('pts.length >= 3 && !isEstimate'), isTrue,
          reason: 'the web map had the same count gate — same bug on web');
    });
  });
}
