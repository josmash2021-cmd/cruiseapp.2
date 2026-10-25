import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/map/driver_road_lock.dart';
import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/utils/route_splice.dart';

void main() {
  const a = LatLng(33.0, -86.0);
  const b = LatLng(33.001, -86.0);
  const c = LatLng(33.001, -85.999);
  const corner = <LatLng>[a, b, c];

  test('right-angle projection always stays on the route', () {
    final lock = DriverRoadLock();
    for (final raw in [
      const LatLng(33.0002, -85.9999),
      const LatLng(33.0007, -86.0001),
      const LatLng(33.0011, -85.9994),
    ]) {
      final fix = lock.project(corner, raw, speedMps: 8);
      expect(fix.trusted, isTrue);
      expect(
          RouteSplice.distanceToPolylineM(corner, fix.point!), lessThan(0.001));
      expect(fix.bearing, isNotNull);
    }
  });

  test('the road lock keeps its last point internally on an untrusted match', () {
    final lock = DriverRoadLock();
    final good = lock.project(corner, a, requireConfidence: true);
    expect(good.trusted, isTrue);
    final far = lock.project(
      corner,
      const LatLng(34.0, -85.0),
      requireConfidence: true,
    );
    expect(far.trusted, isFalse);
    expect(far.point!.latitude, good.point!.latitude);
    expect(far.point!.longitude, good.point!.longitude);
  });

  test('no trusted line and no previous point means no invented position', () {
    final lock = DriverRoadLock();
    final fix = lock.project(
      corner,
      const LatLng(34.0, -85.0),
      requireConfidence: true,
    );
    expect(fix.point, isNull);
    expect(fix.trusted, isFalse);
  });

  test('an active route constrains even a far display point', () {
    final lock = DriverRoadLock();
    final fix = lock.project(corner, const LatLng(34.0, -85.0));
    expect(fix.trusted, isTrue);
    expect(
        RouteSplice.distanceToPolylineM(corner, fix.point!), lessThan(0.001));
  });

  test('lane continuity wins over a tiny distance advantage', () {
    const parallel = <LatLng>[
      LatLng(33.0, -86.0),
      LatLng(33.0, -85.999),
      LatLng(33.00009, -85.999),
      LatLng(33.00009, -85.998),
    ];
    final lock = DriverRoadLock();
    lock.project(parallel, const LatLng(33.000001, -85.9995),
        requireConfidence: true);
    final fix = lock.project(
      parallel,
      const LatLng(33.00005, -85.9995),
      requireConfidence: true,
    );
    expect(fix.segmentIndex, 0);
    expect(fix.point!.latitude, closeTo(33.0, 1e-9));
  });

  test('a sharp bend does not turn the arrow before the corner', () {
    final lock = DriverRoadLock();
    final before = lock.project(
      corner,
      const LatLng(33.00098, -86.0),
      speedMps: 10,
    );
    expect(before.bearing, closeTo(0, 0.001));
    final after = lock.project(
      corner,
      const LatLng(33.001, -85.9999),
      speedMps: 10,
    );
    expect(after.bearing, closeTo(90, 0.001));
  });

  test('S-curves keep position and heading on the polyline', () {
    const curve = <LatLng>[
      LatLng(33.0, -86.0),
      LatLng(33.0004, -86.0002),
      LatLng(33.0008, -85.9998),
      LatLng(33.0012, -86.0002),
      LatLng(33.0016, -85.9998),
    ];
    final lock = DriverRoadLock();
    for (var i = 0; i < 20; i++) {
      final raw = LatLng(33.00008 * i, -86.0001);
      final fix = lock.project(curve, raw, speedMps: 12);
      expect(
          RouteSplice.distanceToPolylineM(curve, fix.point!), lessThan(0.001));
      expect(fix.bearing, isNotNull);
    }
  });

  test('route replacement re-syncs the cursor and reset clears it', () {
    final lock = DriverRoadLock();
    lock.project(corner, a);
    final oldRevision = lock.revision;
    const replacement = <LatLng>[
      LatLng(34.0, -85.0),
      LatLng(34.001, -85.0),
    ];
    final changed = lock.project(replacement, const LatLng(34.0005, -85.0));
    expect(lock.revision, greaterThan(oldRevision));
    expect(changed.point!.latitude, closeTo(34.0005, 1e-9));
    lock.reset();
    expect(lock.lastPoint, isNull);
    expect(lock.project(replacement, const LatLng(34.0005, -85.0)).segmentIndex,
        greaterThanOrEqualTo(0));
  });

  test('display falls back to real GPS instead of freezing without a match',
      () {
    final lock = DriverRoadLock();
    final good = lock.project(corner, a, requireConfidence: true);
    final trustedDisplay = driverDisplayPosition(good, a);
    expect(trustedDisplay.latitude, good.point!.latitude);
    expect(trustedDisplay.longitude, good.point!.longitude);

    const raw = LatLng(34.0, -85.0);
    final untrusted = lock.project(corner, raw, requireConfidence: true);
    expect(untrusted.trusted, isFalse);
    final fallback = driverDisplayPosition(untrusted, raw);
    expect(fallback.latitude, raw.latitude);
    expect(fallback.longitude, raw.longitude);

    final empty = lock.project(const <LatLng>[], raw, requireConfidence: true);
    expect(driverDisplayPosition(empty, raw).latitude, raw.latitude);
    expect(driverDisplayPosition(empty, raw).longitude, raw.longitude);
  });
}
