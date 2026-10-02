import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/smooth_motion.dart';

/// Guards for the 2026-10-02 driver-map fixes (user report: "la flecha se
/// sale de las líneas; avanza, se detiene y luego avanza cuando va lento;
/// al girar a veces gira mucho, como si se coleara"):
///
/// 1. Crawl-speed release honesty — after a frozen spell the release fix is
///    measured against the last SKIPPED fix, not the pre-freeze target, so
///    the marker resumes at the real speed instead of sprinting the backlog.
/// 2. A fix whose own speed reading declares movement (≥1.2 m/s) is never
///    swallowed by the standstill hold.
/// 3. The bearing aim no longer drags the arrow tens of degrees past a
///    completed turn (lead 0.75 s + adaptive tail decay).
void main() {
  const startLat = 33.32872, startLng = -86.78781;
  double north(double metres) => startLat + metres / 110540.0;
  double movedM(SmoothMotion m) => (m.lat! - startLat) * 110540.0;

  Future<void> gap() =>
      Future<void>.delayed(const Duration(milliseconds: 200));

  void run(SmoothMotion m, double seconds) {
    const dt = 1 / 60;
    for (var t = 0.0; t < seconds; t += dt) {
      m.tick(dt);
    }
  }

  test('crawl release resumes at real speed — no backlog sprint', () async {
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);
    await gap();

    // Car crawls north at a steady 1.5 m/s, but the platform's speed
    // reading flaps across the freeze band exactly as iOS delivers it in
    // slow traffic: 0.6 (freeze) then 1.5 (release), alternating.
    double pos = 0;
    for (var i = 0; i < 6; i++) {
      pos += 1.5 * 0.2; // 1.5 m/s over the 200 ms fix spacing
      m.setTarget(north(pos), startLng,
          accuracyM: 5, speedMps: i.isEven ? 0.6 : 1.5);
      await gap();
      run(m, 0.2);
    }
    // With the sprint bug, each release measured the whole frozen spell and
    // the marker overshot the car by metres per cycle. The rendered marker
    // must stay within 2 m of the car's true position.
    expect((movedM(m) - pos).abs(), lessThan(2.0),
        reason: 'the release must measure the honest one-gap step, not the '
            'whole frozen spell — no sprint at crawl speed');
  });

  test('a fix declaring motion is never held by the standstill hold',
      () async {
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);
    await gap();

    // Fixes stepping only 4 m (inside any accuracy-sized hold ring) while
    // declaring 2.0 m/s of movement — the old gate held two out of three of
    // these (stall-sprint at crawl); now none are held.
    for (var i = 1; i <= 5; i++) {
      m.setTarget(north(4.0 * i), startLng, accuracyM: 10, speedMps: 2.0);
      await gap();
      run(m, 0.2);
    }
    expect(movedM(m), greaterThan(12.0),
        reason: 'a fix that says "we are moving" must move the marker');
  });

  test('no big overshoot after a completed turn, and it still settles',
      () async {
    final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);
    double worst = 0;
    // 1 Hz staircase through a 90° turn, then the course stabilises.
    final seq = <double>[30, 60, 90, 90, 90, 90];
    for (final b in seq) {
      m.setBearing(b);
      for (var t = 0; t < 20; t++) {
        m.tick(0.05);
        // Only rotation PAST the target counts — the climb toward it is
        // smoothing, the swing beyond it is the fishtail.
        final over = m.bearing - 90;
        if (over > worst) worst = over;
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    // The old 1 s lead let the aim run vBrg×1 s past the turn end (~40° at
    // a real city turn rate). Lead 0.75 s + tail decay caps the swing well
    // under that.
    expect(worst, lessThan(38.0),
        reason: 'the arrow must not fishtail tens of degrees past a '
            'completed turn');
    // Let it settle, then it must sit on the true course.
    run(m, 2.0);
    expect((m.bearing - 90).abs(), lessThan(3.0));
  });
}
