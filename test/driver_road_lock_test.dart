import 'dart:math' as math;

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

  // 2026-10-29 (owner: the arrow moves, stops, moves again online/offline).
  test('past the end of a confidence line the display follows the car', () {
    final lock = DriverRoadLock();
    const line = <LatLng>[a, b]; // map-matched trace, ends at the last fix
    expect(lock.project(line, a, requireConfidence: true).trusted, isTrue);
    double? prevLat;
    for (var k = 1; k <= 6; k++) {
      final raw = LatLng(33.001 + k * 0.00005, -86.0); // ~5.6 m steps north
      final fix = lock.project(line, raw, requireConfidence: true);
      expect(fix.trusted, isFalse, reason: 'must not pin on the end vertex');
      final shown = driverDisplayPosition(fix, raw);
      expect(shown.latitude, raw.latitude);
      if (prevLat != null) expect(shown.latitude, greaterThan(prevLat));
      prevLat = shown.latitude;
    }
  });

  test('a live route still clamps at its end (destination)', () {
    final lock = DriverRoadLock();
    const line = <LatLng>[a, b];
    final fix = lock.project(line, const LatLng(33.0012, -86.0));
    expect(fix.trusted, isTrue);
    expect(RouteSplice.haversineM(fix.point!, b), lessThan(0.01));
  });

  // ── Owner report 2026-11-01: "cuando la cámara gira no gira fluido, gira
  // por pasos" / "al hacer zoom la flecha queda fuera de las líneas". ──

  LatLng east(LatLng o, double eastM, double northM) => LatLng(
      o.latitude + northM / 110540.0,
      o.longitude +
          eastM / (111320.0 * math.cos(o.latitude * math.pi / 180)));

  test('driving on past a vertex never freezes the projection on it', () {
    // Straight street, a vertex every 10 m (Mapbox geometry on a curve is
    // 5–15 m apart). The old 8 m lane-continuity slack held the projection
    // on each END vertex for ~8–10 m, then jumped: the arrow and the nav
    // camera centre moved in steps, one per vertex.
    const o = LatLng(27.77, -82.64);
    final line = [for (var i = 0; i <= 10; i++) east(o, 0, i * 10.0)];
    final lock = DriverRoadLock();
    double? prev;
    for (var s = 0.5; s <= 80; s += 0.5) {
      final fix = lock.project(line, east(o, 2, s), speedMps: 12);
      final along = RouteSplice.haversineM(o, fix.point!);
      if (prev != null) {
        expect(along - prev, closeTo(0.5, 0.05),
            reason: 'at s=$s the projection stalled or jumped (moved '
                '${(along - prev).toStringAsFixed(2)} m for 0.5 m driven)');
      }
      prev = along;
    }
  });

  test('lane continuity still beats a parallel carriageway 3 m closer', () {
    // Two parallel carriageways 12 m apart, joined by a U-turn: a car on
    // the first, drifting 4.5 m toward the second, stays on the first.
    final o = east(const LatLng(27.77, -82.64), 0, 0);
    final line = <LatLng>[
      o,
      east(o, 0, 200),
      east(o, 12, 200),
      east(o, 12, 0),
    ];
    final lock = DriverRoadLock();
    lock.project(line, east(o, 0.5, 100), speedMps: 10);
    final fix = lock.project(line, east(o, 7.5, 104), speedMps: 10);
    expect(fix.segmentIndex, 0);
    expect(
        RouteSplice.haversineM(fix.point!, east(o, 0, 104)), lessThan(0.5));
  });

  test('through a curve the heading turns continuously, not per vertex', () {
    // 90° arc, R = 80 m, a vertex every 7.5° (~10.5 m). The old heading was
    // the bearing of the segment the look-ahead landed on: flat, then a
    // 7.5° jump at every vertex.
    const o = LatLng(27.77, -82.64);
    final c = east(o, 80, 0);
    final arc = [
      for (var k = 0; k <= 12; k++)
        east(c, -80 * math.cos(k * math.pi / 24), 80 * math.sin(k * math.pi / 24)),
    ];
    final lock = DriverRoadLock();
    double? prev;
    var worst = 0.0;
    for (var s = 2.0; s <= 100; s += 0.25) {
      final p = RouteSplice.pointAlong(arc, arc.first, s)!.$1;
      final fix = lock.project(arc, p, speedMps: 12);
      if (prev != null) {
        var d = (fix.bearing! - prev).abs() % 360;
        if (d > 180) d = 360 - d;
        if (d > worst) worst = d;
      }
      prev = fix.bearing;
    }
    // 0.25 m of arc at R 80 m turns the road 0.18°; the chord follows it.
    expect(worst, lessThan(1.0),
        reason: 'a ${worst.toStringAsFixed(1)}° step between two frames '
            '0.25 m apart is the per-vertex staircase');
  });

  group('straight continuation past a confidence line (extendPastEnd)', () {
    // The matched trace ends at the last fix; the car is always beyond it.
    const o = LatLng(27.77, -82.64);
    final trace = [for (var i = 0; i <= 6; i++) east(o, 0, i * 10.0)];

    test('a fix 8 m beside the road lands ON the road, and keeps advancing',
        () {
      final lock = DriverRoadLock();
      double? prev;
      for (var s = 65.0; s <= 140; s += 5) {
        final raw = east(o, 8, s); // GPS error: 8 m east of the street
        final fix = lock.project(trace, raw,
            requireConfidence: true,
            extendPastEnd: true,
            headingDeg: 2,
            speedMps: 12);
        expect(fix.trusted, isTrue, reason: 'at s=$s');
        expect(fix.extended, isTrue);
        final shown = driverDisplayPosition(fix, raw);
        // On the street's line (lng of the trace), at the car's progress.
        expect(RouteSplice.haversineM(shown, east(o, 0, s)), lessThan(0.5));
        if (prev != null) expect(shown.latitude, greaterThan(prev));
        prev = shown.latitude;
      }
    });

    test('without the option nothing changes (2026-10-29 semantics)', () {
      final lock = DriverRoadLock();
      final raw = east(o, 8, 80);
      final fix = lock.project(trace, raw, requireConfidence: true);
      expect(fix.trusted, isFalse);
      expect(driverDisplayPosition(fix, raw), raw);
    });

    test('a car off to the side, turning, or far past the end is NOT pulled',
        () {
      final lock = DriverRoadLock();
      // 25 m to the side — a parking lot, a parallel street.
      expect(
          lock
              .project(trace, east(o, 25, 80),
                  requireConfidence: true,
                  extendPastEnd: true,
                  headingDeg: 0,
                  speedMps: 10)
              .trusted,
          isFalse);
      // Course 45° off the line: a turn begun past the trace.
      expect(
          lock
              .project(trace, east(o, 3, 80),
                  requireConfidence: true,
                  extendPastEnd: true,
                  headingDeg: 45,
                  speedMps: 10)
              .trusted,
          isFalse);
      // 300 m past the end at city speed: the line says nothing that far.
      expect(
          lock
              .project(trace, east(o, 1, 360),
                  requireConfidence: true,
                  extendPastEnd: true,
                  headingDeg: 0,
                  speedMps: 10)
              .trusted,
          isFalse);
    });

    test('engages within 15 m, holds to 20 m (no flicker at the edge)', () {
      final lock = DriverRoadLock();
      RoadLockFix at(double eastM) => lock.project(trace, east(o, eastM, 80),
          requireConfidence: true,
          extendPastEnd: true,
          headingDeg: 0,
          speedMps: 10);
      expect(at(17).trusted, isFalse, reason: 'not engaged yet: 17 > 15');
      expect(at(12).trusted, isTrue);
      expect(at(17).trusted, isTrue, reason: 'held: 17 < 20');
      expect(at(22).trusted, isFalse);
      expect(at(17).trusted, isFalse, reason: 'released: 17 > 15 again');
    });
  });
}
