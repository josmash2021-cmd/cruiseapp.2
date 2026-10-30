import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:cruise_app/services/heading_service.dart';
import 'package:cruise_app/utils/fix_kinematics.dart';
import 'package:cruise_app/utils/smooth_motion.dart';

/// Owner report 2026-10-29: the driver arrow "avanza, se detiene, avanza";
/// "no sigue la ubicación y no gira"; "con poca señal ni se mueve y aparece
/// más adelante cuando llega la señal". It must move like a normal map.
void main() {
  const lat0 = 33.32872, lng0 = -86.78781;
  double north(double m) => lat0 + m / 110540.0;
  double metresOf(SmoothMotion m) => (m.lat! - lat0) * 110540.0;

  late DateTime now;
  SmoothMotion engine() {
    now = DateTime(2026, 10, 29, 12);
    return SmoothMotion(clock: () => now)..snapTo(lat0, lng0, bearing: 0);
  }

  const dt = 1 / 60;
  // Advances the fake clock frame by frame; returns per-frame displacement.
  List<double> run(SmoothMotion m, double seconds) {
    final steps = <double>[];
    for (var t = 0.0; t < seconds - 1e-9; t += dt) {
      final before = metresOf(m);
      now = now.add(const Duration(microseconds: 16667));
      m.tick(dt);
      steps.add(metresOf(m) - before);
    }
    return steps;
  }

  int longestStall(List<double> steps) {
    var run = 0, best = 0;
    for (final s in steps) {
      run = s.abs() < 0.01 ? run + 1 : 0;
      if (run > best) best = run;
    }
    return best;
  }

  test('steady 12 m/s with noisy 1 Hz fixes never stops dead', () {
    final m = engine();
    const speed = 12.0;
    // Fix positions lag the car by GPS noise / delivery latency.
    const lagM = [0.0, 3.0, 1.0, 4.0, 0.5, 3.5, 1.5, 4.0, 0.0, 2.5];
    var carM = 0.0;
    final steps = <double>[];
    for (var i = 0; i < 20; i++) {
      carM += speed;
      m.setTarget(north(carM - lagM[i % lagM.length]), lng0,
          bearing: 0, accuracyM: 5, speedMps: speed,
          timestampMs: now.millisecondsSinceEpoch.toDouble());
      final s = run(m, 1.0);
      if (i >= 3) steps.addAll(s);
    }
    expect(longestStall(steps), lessThanOrEqualTo(3),
        reason: 'the arrow must not halt between fixes (>50 ms stall)');
    expect(steps.where((s) => s < -0.01), isEmpty,
        reason: 'and must never run backwards along the road');
  });

  test('weak signal: keeps rolling through a 4 s gap, no sprint after', () {
    final m = engine();
    const speed = 12.0;
    var carM = 0.0;
    for (var i = 0; i < 5; i++) {
      carM += speed;
      m.setTarget(north(carM), lng0,
          bearing: 0, accuracyM: 5, speedMps: speed,
          timestampMs: now.millisecondsSinceEpoch.toDouble());
      run(m, 1.0);
    }
    // 4 s with no fix at all (tunnel / weak signal).
    final gapSteps = run(m, 4.0);
    final at3s = gapSteps.sublist(170, 185).fold<double>(0, (a, b) => a + b);
    expect(at3s, greaterThan(0.5),
        reason: 'still rolling 3 s into the gap (old engine: stopped at 2 s)');
    carM += speed * 4;
    final behindAtResume = carM - metresOf(m);
    expect(behindAtResume, lessThan(15),
        reason: 'small backlog when the signal returns, not a 24 m+ jump');
    m.setTarget(north(carM), lng0,
        bearing: 0, accuracyM: 8, speedMps: speed,
        timestampMs: now.millisecondsSinceEpoch.toDouble());
    final after = run(m, 2.0);
    expect(after.reduce((a, b) => a > b ? a : b), lessThan(0.6),
        reason: 'catch-up stays a glide (<36 m/s), never a teleport');
  });

  test('decayed lead is continuous and eases to a stop', () {
    expect(SmoothMotion.decayedLeadSec(1.0), 1.0);
    expect(SmoothMotion.decayedLeadSec(2.0), 2.0);
    expect(SmoothMotion.decayedLeadSec(3.5),
        closeTo(2.0 + 1.5 - 1.5 * 1.5 / 6, 1e-9));
    expect(SmoothMotion.decayedLeadSec(5.0), closeTo(3.5, 1e-9));
    expect(SmoothMotion.decayedLeadSec(9.0), closeTo(3.5, 1e-9));
  });

  Position fix({
    required double lat,
    required double lng,
    required DateTime at,
    double speed = 0,
    double speedAcc = 0,
    double heading = 0,
    double headingAcc = 0,
  }) =>
      Position(
        latitude: lat,
        longitude: lng,
        timestamp: at,
        accuracy: 5,
        altitude: 0,
        altitudeAccuracy: 0,
        heading: heading,
        headingAccuracy: headingAcc,
        speed: speed,
        speedAccuracy: speedAcc,
      );

  test('Android 0 with no accuracy is "not measured", not parked/north', () {
    final at = DateTime(2026);
    expect(measuredSpeedMps(fix(lat: 0, lng: 0, at: at)), isNull);
    expect(measuredCourseDeg(fix(lat: 0, lng: 0, at: at)), isNull);
    expect(measuredSpeedMps(fix(lat: 0, lng: 0, at: at, speedAcc: 0.4)), 0);
    expect(measuredSpeedMps(fix(lat: 0, lng: 0, at: at, speed: 9, speedAcc: 0.4)), 9);
    expect(measuredCourseDeg(fix(lat: 0, lng: 0, at: at, heading: 90, headingAcc: 3)), 90);
  });

  test('driving east with Doppler-less fixes: arrow follows the road, '
      'not the in-car compass', () async {
    final compass = StreamController<double>();
    var clock = DateTime(2026, 10, 29, 12);
    final svc = HeadingService(compassReadings: compass.stream, now: () => clock);
    final seen = <double>[];
    final sub = svc.stream.listen(seen.add);
    svc.start();
    compass.add(200); // magnetometer fooled by the car
    await Future<void>.delayed(Duration.zero);
    const mPerDegLng = 111320.0 * 0.8357; // cos(33.33°)
    for (var i = 1; i <= 6; i++) {
      clock = clock.add(const Duration(seconds: 1));
      svc.onFix(fix(lat: lat0, lng: lng0 + i * 12 / mPerDegLng, at: clock));
      await Future<void>.delayed(Duration.zero);
    }
    expect(svc.usingCourse, isTrue);
    expect(seen.last, closeTo(90, 3));
    await sub.cancel();
    await compass.close();
    svc.dispose();
  });
}
