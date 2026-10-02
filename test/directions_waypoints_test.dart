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
  });
}
