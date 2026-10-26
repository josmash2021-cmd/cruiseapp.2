import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/map/driver_road_lock.dart';
import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/utils/route_splice.dart';
import 'package:cruise_app/utils/smooth_motion.dart';

void main() {
  test('walking keeps moving while no road match is available', () {
    var now = DateTime(2026, 1, 1);
    final motion = SmoothMotion(clock: () => now);
    final lock = DriverRoadLock();
    const start = LatLng(33.0, -86.0);
    final first = driverDisplayPosition(
      lock.project(const <LatLng>[], start, requireConfidence: true),
      start,
    );
    motion.setTarget(
      first.latitude,
      first.longitude,
      accuracyM: 5,
      timestampMs: now.millisecondsSinceEpoch.toDouble(),
      speedMps: 1.2,
    );
    final initial = motion.lat!;

    for (var fix = 1; fix <= 6; fix++) {
      now = now.add(const Duration(milliseconds: 1700));
      final raw = LatLng(start.latitude + fix * 2 / 110540.0, start.longitude);
      final target = driverDisplayPosition(
        lock.project(const <LatLng>[], raw, requireConfidence: true),
        raw,
      );
      motion.setTarget(
        target.latitude,
        target.longitude,
        accuracyM: 5,
        timestampMs: now.millisecondsSinceEpoch.toDouble(),
        speedMps: 1.2,
      );
      var previous = motion.lat!;
      for (var frame = 0; frame < 60; frame++) {
        now = now.add(const Duration(microseconds: 16667));
        motion.tick(1 / 60);
        final stepM = (motion.lat! - previous).abs() * 110540.0;
        expect(stepM, lessThan(1.0));
        previous = motion.lat!;
      }
    }
    expect(motion.lat!, greaterThan(initial + 4 / 110540.0));
  });

  test('rejoining a trusted route stays bounded and on the line', () {
    var now = DateTime(2026, 1, 1);
    final motion = SmoothMotion(clock: () => now);
    final lock = DriverRoadLock();
    const route = <LatLng>[LatLng(33.0, -86.0), LatLng(33.002, -86.0)];
    motion.setTarget(33.0, -86.0,
        accuracyM: 5,
        timestampMs: now.millisecondsSinceEpoch.toDouble(),
        speedMps: 1.2);

    var previous = LatLng(motion.lat!, motion.lng!);
    for (var fix = 1; fix <= 3; fix++) {
      now = now.add(const Duration(milliseconds: 1700));
      final raw = LatLng(33.0 + fix * 2 / 110540.0, -86.0 + 0.00005);
      final target = driverDisplayPosition(
        lock.project(route, raw, requireConfidence: true),
        raw,
      );
      motion.setTarget(
        target.latitude,
        target.longitude,
        accuracyM: 5,
        timestampMs: now.millisecondsSinceEpoch.toDouble(),
        speedMps: 1.2,
      );
      for (var frame = 0; frame < 60; frame++) {
        now = now.add(const Duration(microseconds: 16667));
        motion.tick(1 / 60);
        final current = LatLng(motion.lat!, motion.lng!);
        final displayed = driverDisplayPosition(
          lock.project(route, current, requireConfidence: true),
          current,
        );
        final stepM = RouteSplice.haversineM(previous, displayed);
        expect(stepM, lessThan(1.0));
        previous = displayed;
      }
    }
    expect(RouteSplice.distanceToPolylineM(route, previous), lessThan(0.001));
  });
}
