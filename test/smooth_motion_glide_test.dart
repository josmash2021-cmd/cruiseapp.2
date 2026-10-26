import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/smooth_motion.dart';

/// The marker must GLIDE between fixes, not sprint to each fix and park on
/// it until the next one arrives.
///
/// The regression this pins: the correction used to aim at the raw target
/// and an overshoot clamp stopped the marker dead the moment it arrived.
/// With a 1 Hz feed the marker reached the stale fix in ~0.35 s and sat
/// parked for the remaining ~0.65 s — the "it steps once a second" the
/// rider and driver both saw. Simulation of the old math measured the
/// marker motionless in 33–73% of frames at a steady 8 m/s; aiming the
/// correction at the extrapolated target (target + velocity × fix age)
/// brings that to 0%.
///
/// SmoothMotion times its fixes off DateTime.now(), so the gaps here are
/// real — same approach as smooth_motion_bearing_test.dart.
void main() {
  const startLat = 33.32872, startLng = -86.78781;
  double north(double metres) => startLat + metres / 110540.0;

  test('a steady feed glides: no park-and-wait between fixes', () async {
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);

    // ~9 m/s due north, a fix every 150 ms (faster than production so the
    // test stays quick — the sprint-and-park shows at any cadence).
    final clock = Stopwatch()..start();
    var maxParkedFrames = 0;
    var parkedFrames = 0;
    double? prevLat;

    for (var fix = 1; fix <= 12; fix++) {
      // Advance the true car to "now" and publish it as the new fix.
      final elapsed = clock.elapsedMilliseconds / 1000.0;
      m.setTarget(north(9.0 * elapsed), startLng, accuracyM: 5);

      // Render the inter-fix window at 60 fps.
      for (var frame = 0; frame < 9; frame++) {
        await Future<void>.delayed(const Duration(milliseconds: 16));
        m.tick(1 / 60);
        final lat = m.lat!;
        // Warm-up excluded: the first fixes legitimately ramp the velocity
        // estimate from a stop (acceleration cap, standstill hold). What
        // must never park is the steady state the rider/driver actually
        // watches.
        if (fix <= 4) {
          prevLat = lat;
          continue;
        }
        if (prevLat != null && (lat - prevLat).abs() < 1e-10) {
          parkedFrames++;
          if (parkedFrames > maxParkedFrames) maxParkedFrames = parkedFrames;
        } else {
          parkedFrames = 0;
        }
        prevLat = lat;
      }
    }

    // The old math parked the marker for the bulk of EVERY inter-fix window
    // (6+ consecutive motionless frames here). A gliding marker never sits
    // still for more than a frame or two while the correction lands.
    expect(maxParkedFrames, lessThan(4),
        reason: 'the marker parked between fixes — the once-a-second step '
            'is back (worst run: $maxParkedFrames motionless frames)');
  });

  test('a dead feed still holds instead of gliding away forever', () async {
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);

    // Build up real speed: a run of moving fixes.
    for (var i = 1; i <= 6; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 120));
      m.setTarget(north(9.0 * i * 0.12), startLng, accuracyM: 5);
      for (var f = 0; f < 7; f++) {
        m.tick(1 / 60);
      }
    }

    // Feed dies. The marker may ride its extrapolated lead (capped at
    // _maxLeadSec of travel) and then must hold — never run off at the last
    // measured speed for the whole 5 s staleness window.
    final heldAt = m.lat!;
    for (var f = 0; f < 360; f++) {
      m.tick(1 / 60); // 6 s of frames, no fixes
    }
    final driftM = (m.lat! - heldAt).abs() * 110540.0;
    expect(driftM, lessThan(25),
        reason: 'with the feed dead the marker must hold near where the car '
            'was last seen, not glide on at speed (drifted ${driftM}m)');
  });

  for (final gapSeconds in [2, 5, 15]) {
    test('a $gapSeconds second GPS gap cannot produce a sprint on reacquire',
        () {
      var now = DateTime(2026, 1, 1);
      final m = SmoothMotion(clock: () => now)
        ..snapTo(startLat, startLng, bearing: 0);
      final steps = <double>[];
      var previous = m.lat!;
      void advance(double seconds) {
        final frames = (seconds * 60).round();
        for (var frame = 0; frame < frames; frame++) {
          now = now.add(const Duration(microseconds: 16667));
          m.tick(1 / 60);
          steps.add((m.lat! - previous).abs() * 110540.0);
          previous = m.lat!;
        }
      }

      for (var second = 1; second <= 6; second++) {
        m.setTarget(north(8.0 * second), startLng,
            accuracyM: 5,
            timestampMs: now.millisecondsSinceEpoch.toDouble(),
            speedMps: 8);
        advance(1);
      }
      advance(gapSeconds.toDouble());
      final reacquireAt = steps.length;
      m.setTarget(north(8.0 * (6 + gapSeconds)), startLng,
          accuracyM: 5,
          timestampMs: now.millisecondsSinceEpoch.toDouble(),
          speedMps: 8);
      advance(2);

      final recovery = steps.sublist(reacquireAt);
      final worst = recovery.fold<double>(0, (a, b) => a > b ? a : b);
      expect(worst, lessThan(1.0),
          reason: 'reacquiring after $gapSeconds s produced a $worst m frame: '
              'the marker must rejoin with bounded speed');
    });
  }

  test('an out-of-order fix cannot move or rotate the marker backwards', () {
    var now = DateTime(2026, 1, 1);
    final m = SmoothMotion(clock: () => now)
      ..snapTo(startLat, startLng, bearing: 0);
    void advance(double seconds) {
      for (var frame = 0; frame < (seconds * 60).round(); frame++) {
        now = now.add(const Duration(microseconds: 16667));
        m.tick(1 / 60);
      }
    }

    advance(1);
    m.setTarget(north(8), startLng,
        bearing: 0,
        timestampMs: now.millisecondsSinceEpoch.toDouble(),
        speedMps: 8);
    advance(1);
    m.setTarget(north(16), startLng,
        bearing: 0,
        timestampMs: now.millisecondsSinceEpoch.toDouble(),
        speedMps: 8);
    advance(0.2);
    final goodLat = m.lat!;
    m.setTarget(north(4), startLng,
        bearing: 180,
        timestampMs: (now.millisecondsSinceEpoch - 1000).toDouble(),
        speedMps: 8);
    advance(0.5);

    expect(m.lat!, greaterThanOrEqualTo(goodLat));
    expect(m.bearing, closeTo(0, 0.001));
  });

  test('a future timestamp cannot poison the next valid fix', () {
    var now = DateTime(2026, 1, 1);
    final m = SmoothMotion(clock: () => now)
      ..snapTo(startLat, startLng, bearing: 0);
    void advance(double seconds) {
      for (var frame = 0; frame < (seconds * 60).round(); frame++) {
        now = now.add(const Duration(microseconds: 16667));
        m.tick(1 / 60);
      }
    }

    advance(1);
    m.setTarget(north(8), startLng,
        timestampMs: now.millisecondsSinceEpoch.toDouble(), speedMps: 8);
    advance(1);
    m.setTarget(north(16), startLng,
        timestampMs: now.millisecondsSinceEpoch.toDouble(), speedMps: 8);
    advance(0.2);
    m.setTarget(north(24), startLng,
        timestampMs: (now.millisecondsSinceEpoch + 10000).toDouble(),
        speedMps: 8);
    advance(1);
    final beforeValid = m.lat!;
    m.setTarget(north(32), startLng,
        timestampMs: now.millisecondsSinceEpoch.toDouble(), speedMps: 8);
    advance(0.5);

    expect(m.lat!, greaterThan(beforeValid));
  });
}
