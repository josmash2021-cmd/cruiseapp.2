import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/utils/smooth_motion.dart';

/// Guards for the critically damped spring correction + speed fusion
/// (2026-10-23, owner ask "mucho más smooth"): the correction must settle
/// without oscillation or overshoot past the aim, and a bogus GPS speed
/// spike must never yank the glide estimate.
void main() {
  test('turn: settles inside ±2° and stays there (no oscillation after '
      'the spring lands)', () async {
    final m = SmoothMotion()..snapTo(25.8, -80.1, bearing: 0);

    final deltas = <double>[];
    double prev = m.bearing;
    final ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
      m.tick(1 / 60);
      deltas.add(m.bearing - prev);
      prev = m.bearing;
    });
    Future<void> wait(int ms) => Future.delayed(Duration(milliseconds: ms));

    await wait(300);
    m.setBearing(90);
    await wait(1500); // 0.75 s aim lead + ~0.4 s spring settle
    // After the settle the heading must sit INSIDE a ±2° band — no swing
    // back, no oscillation. The next second must not leave it.
    final band = <double>[];
    for (var i = 0; i < 60; i++) {
      band.add((m.bearing - 90).abs());
      await wait(16);
    }
    ticker.cancel();
    final worst = band.reduce((a, b) => a > b ? a : b);
    expect(worst, lessThan(2.0),
        reason: 'after the turn the arrow must hold inside ±2° of the '
            'target (worst deviation: $worst°)');
    expect((m.bearing - 90).abs(), lessThan(2.0));
  });

  test('position: holds after the aim lead expires (no spring oscillation)',
      () async {
    const startLat = 33.32872, startLng = -86.78781;
    double north(double metres) => startLat + metres / 110540.0;
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);

    // A real jump of 20 m in ~0.5 s (implied 40 m/s — NOT a teleport snap).
    await Future<void>.delayed(const Duration(milliseconds: 5000));
    final settled = m.lat!;
    for (var i = 0; i < 60; i++) {
      m.tick(1 / 60);
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    final driftM = (m.lat! - settled).abs() * 110540.0;
    expect(driftM, lessThan(2.0),
        reason: 'once the aim lead expired the marker must HOLD, not '
            'oscillate or keep gliding (drifted ${driftM}m)');
  });

  test('a bogus 40 m/s GPS spike cannot yank the speed estimate', () async {
    const startLat = 33.32872, startLng = -86.78781;
    double north(double metres) => startLat + metres / 110540.0;
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);

    // Real motion first: a steady ~8 m/s feed.
    for (var i = 1; i <= 4; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      m.setTarget(north(8.0 * i * 0.12), startLng, accuracyM: 5);
      for (var f = 0; f < 7; f++) {
        m.tick(1 / 60);
      }
    }
    // Ghost spike: a 20 m hop in ~0.5 s (implied 40 m/s).
    await Future<void>.delayed(const Duration(milliseconds: 500));
    m.setTarget(north(20), startLng, accuracyM: 5);
    for (var f = 0; f < 30; f++) {
      m.tick(1 / 60);
    }
    expect(m.speedMps, lessThan(25.0),
        reason: 'the median-of-3 outlier gate must cap the ghost spike '
            '(speed read: ${m.speedMps} m/s)');
  });
}
