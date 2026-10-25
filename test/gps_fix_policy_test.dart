import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:cruise_app/utils/gps_fix_policy.dart';

Position fix(DateTime timestamp) => Position(
      latitude: 33.0,
      longitude: -86.0,
      timestamp: timestamp,
      accuracy: 5,
      altitude: 0,
      altitudeAccuracy: 0,
      heading: 0,
      headingAccuracy: 0,
      speed: 8,
      speedAccuracy: 0,
    );

void main() {
  test('duplicate and out-of-order fixes are rejected', () {
    final policy = GpsFixPolicy();
    final now = DateTime.now();
    expect(policy.accept(fix(now)), isTrue);
    expect(policy.accept(fix(now)), isFalse);
    expect(
      policy.accept(fix(now.subtract(const Duration(seconds: 1)))),
      isFalse,
    );
  });

  test('a future timestamp does not poison later valid fixes', () {
    final policy = GpsFixPolicy();
    final future = DateTime.now().add(const Duration(hours: 1));
    expect(policy.accept(fix(future)), isTrue);
    expect(policy.accept(fix(future)), isFalse);
    expect(policy.accept(fix(DateTime.now())), isTrue);
  });

  test('a future timestamp does not reopen an older valid sequence', () {
    final policy = GpsFixPolicy();
    final first = DateTime.now().subtract(const Duration(seconds: 2));
    final future = DateTime.now().add(const Duration(hours: 1));
    expect(policy.accept(fix(first)), isTrue);
    expect(policy.accept(fix(future)), isTrue);
    expect(
      policy.accept(fix(first.subtract(const Duration(seconds: 1)))),
      isFalse,
    );
    expect(policy.accept(fix(first.add(const Duration(seconds: 1)))), isTrue);
  });

  test('unknown timestamps pass and reset restores the gate', () {
    final policy = GpsFixPolicy();
    expect(policy.accept(fix(DateTime.fromMillisecondsSinceEpoch(0))), isTrue);
    policy.accept(fix(DateTime.now()));
    policy.reset();
    expect(policy.accept(fix(DateTime.now())), isTrue);
  });
}
