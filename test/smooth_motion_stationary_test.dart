import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/smooth_motion.dart';

/// The stationary freeze: a fix whose OWN speed reading says ~0 must not
/// move the marker, no matter how far its position jumped.
///
/// The regression this pins (user report 2026-09-17): parked drivers
/// watched their arrow wander around the block — on the driver's nav page
/// and on the rider's tracking map ("se aleja, se acerca"). Bad-signal
/// fixes jump 20-60 m while the car is parked; the old path measured
/// 20-60 m/s of implied speed off each jump and glided after it, and the
/// hold's agreement rule force-accepted every 3rd wandering fix. The
/// platform's speed reading (~0 while parked) was never consulted.
///
/// Same timing discipline as smooth_motion_bearing_test.dart: the gaps
/// are real, 200 ms, so the velocity-and-hold block actually runs.
void main() {
  const startLat = 33.32872, startLng = -86.78781;
  double north(double metres) => startLat + metres / 110540.0;
  double movedM(SmoothMotion m) => (m.lat! - startLat) * 110540.0;

  Future<void> gap() =>
      Future<void>.delayed(const Duration(milliseconds: 200));

  /// Run [seconds] of ticks at 60 fps.
  void run(SmoothMotion m, double seconds) {
    const dt = 1 / 60;
    for (var t = 0.0; t < seconds; t += dt) {
      m.tick(dt);
    }
  }

  test('a parked car with wandering zero-speed fixes does not move',
      () async {
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);
    await gap();

    // Wander burst: fixes alternating ±40 m, each reporting speed ~0 —
    // exactly what a parked phone on bad signal delivers.
    for (var i = 0; i < 8; i++) {
      final jump = i.isEven ? 40.0 : -35.0;
      m.setTarget(north(jump), startLng, accuracyM: 25, speedMps: 0.0);
      await gap();
      run(m, 0.2);
    }

    expect(movedM(m).abs(), lessThan(1.0),
        reason: 'speed ~0 means parked: the marker must not chase the jump');
  });

  test('a fix reporting real movement releases the freeze', () async {
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);
    await gap();

    // Park first.
    m.setTarget(north(30), startLng, accuracyM: 25, speedMps: 0.0);
    await gap();
    run(m, 0.5);
    expect(movedM(m).abs(), lessThan(1.0));

    // Pull away: fixes reporting 2.5 m/s, moving steadily north.
    for (var i = 1; i <= 6; i++) {
      m.setTarget(north(2.5 * i), startLng, accuracyM: 5, speedMps: 2.5);
      await gap();
      run(m, 0.2);
    }
    expect(movedM(m), greaterThan(8),
        reason: 'the freeze must release the instant movement is real');
  });

  test('the first fix of a session lands even at speed 0', () {
    // The freeze needs an existing position to hold — without this guard a
    // parked first fix would leave the marker uninitialised forever.
    final m = SmoothMotion()..setTarget(startLat, startLng, speedMps: 0.0);
    expect(m.lat, closeTo(startLat, 1e-9));
    expect(m.lng, closeTo(startLng, 1e-9));
  });

  test('a fix WITHOUT a speed reading keeps the old path', () async {
    // speedMps == null opts out of the freeze: the accuracy-sized hold and
    // the velocity measurement decide, exactly as before.
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);
    await gap();
    m.setTarget(north(40), startLng, accuracyM: 5);
    run(m, 3);
    expect(movedM(m), greaterThan(20),
        reason: 'no speed reading, a precise fix 40 m away — the old '
            'behaviour must still follow it');
  });
}
