import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/smooth_motion.dart';

/// The arrow has to keep turning while the car is parked.
///
/// That is one sentence and two separate things had to be true for it: a way
/// to change the bearing without a position, and an `isAtTarget` that does not
/// call a marker mid-turn "settled" just because it is not moving. The driver
/// screens park their ticker on `isAtTarget`, so getting the second one wrong
/// freezes the arrow again with nothing in the code looking obviously broken.
void main() {
  /// Run [seconds] of ticks at 60 fps, the rate the real ticker runs at.
  void run(SmoothMotion m, double seconds) {
    const dt = 1 / 60;
    for (var t = 0.0; t < seconds; t += dt) {
      m.tick(dt);
    }
  }

  group('SmoothMotion.setBearing', () {
    test('turns the marker with no position update at all', () {
      final m = SmoothMotion()..setTarget(33.328, -86.788, bearing: 0);
      expect(m.bearing, 0);

      m.setBearing(90);
      run(m, 3);

      expect(m.bearing, closeTo(90, 1),
          reason: 'a parked driver turning the phone must turn the arrow');
      expect(m.lat, closeTo(33.328, 1e-9), reason: 'and must not move it');
      expect(m.lng, closeTo(-86.788, 1e-9));
    });

    test('takes the short way round, not the long one', () {
      final m = SmoothMotion()..setTarget(33.328, -86.788, bearing: 350);

      // 350 -> 10 is twenty degrees clockwise, not 340 anticlockwise.
      m.setBearing(10);
      run(m, 0.25);

      final b = m.bearing;
      final wentForward = b >= 350 || b <= 10;
      expect(wentForward, isTrue,
          reason: 'passed through 0, rather than sweeping back through 180 '
              '(bearing was $b)');
    });

    test('ignores NaN and infinity instead of poisoning the marker', () {
      final m = SmoothMotion()..setTarget(33.328, -86.788, bearing: 45);
      m.setBearing(double.nan);
      m.setBearing(double.infinity);
      run(m, 1);
      expect(m.bearing, closeTo(45, 0.001));
    });

    test('normalises whatever the sensor hands over', () {
      final m = SmoothMotion()..setTarget(33.328, -86.788, bearing: 0);
      m.setBearing(-90); // some platforms report signed headings
      run(m, 3);
      expect(m.bearing, closeTo(270, 1));
    });
  });

  group('nothing non-finite leaves the smoother', () {
    // The regression this file was written to catch, found by accident.
    //
    // tick() computed its smoothing factor as `1 - pow(1 - rate, dt)`, which
    // is only defined while rate < 1. Both rates are above 1, so the base was
    // negative, and a negative base to a fractional power — which every frame
    // delta is — is NaN in Dart. Every tick, on every frame, since the rates
    // were last raised.
    //
    // It was invisible from inside: the overshoot clamps compare against NaN
    // and every comparison is false, so they let it straight through. It was
    // only visible on the phone, as an arrow that vanished and a dot that
    // would not move without a watchdog to nudge it — and as a Swift
    // precondition failure when a NaN reached the native map.

    test('a full second of ticks leaves a real position and bearing', () {
      final m = SmoothMotion()
        ..setTarget(33.328, -86.788, bearing: 0)
        ..setTarget(33.329, -86.787, bearing: 45);

      run(m, 1);

      expect(m.lat, isNotNull);
      expect(m.lat!.isFinite, isTrue, reason: 'latitude went NaN');
      expect(m.lng!.isFinite, isTrue, reason: 'longitude went NaN');
      expect(m.bearing.isFinite, isTrue, reason: 'bearing went NaN');
    });

    test('the marker actually converges on the target', () {
      final m = SmoothMotion()..snapTo(33.328, -86.788, bearing: 0);
      m.setTarget(33.3285, -86.7875);

      run(m, 4);

      expect(m.lat, closeTo(33.3285, 1e-5),
          reason: 'a NaN step never converges — it just stops being a number');
      expect(m.lng, closeTo(-86.7875, 1e-5));
    });

    test('survives a NaN fix from the platform', () {
      final m = SmoothMotion()..snapTo(33.328, -86.788, bearing: 0);
      m.snapTo(double.nan, double.nan);
      run(m, 0.5);
      expect(m.lat, closeTo(33.328, 1e-6),
          reason: 'iOS reports NaN briefly while the location manager starts');
      expect(m.lng, closeTo(-86.788, 1e-6));
    });
  });

  group('the standstill hold does not pin the marker', () {
    // SmoothMotion times its own fixes off DateTime.now(), so the gaps here
    // are real. They have to be: below 50 ms the whole velocity-and-hold
    // block is skipped as a duplicate fix, and a first draft of these tests
    // passed for exactly that reason — every fix sailed through a filter
    // that never ran.
    //
    // 200 ms is the window. Long enough to be a fix, short enough to stay
    // under the 60 m/s teleport guard for the distances used below.
    Future<void> gap() => Future<void>.delayed(const Duration(milliseconds: 200));

    const startLat = 33.32872, startLng = -86.78781;
    double north(double metres) => startLat + metres / 110540.0;
    double movedM(SmoothMotion m) => (m.lat! - startLat) * 110540.0;

    /// A parked marker, settled, with no velocity to speak of.
    Future<SmoothMotion> parked() async {
      final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);
      await gap();
      return m;
    }

    test('a fix good to 3 m, eight metres away, is a move', () async {
      // This is the bug. A flat 15 m ring swallowed it, so a driver standing
      // in the road was drawn on the pavement and stayed there.
      final m = await parked();
      m.setTarget(north(8), startLng, accuracyM: 3);
      run(m, 2);
      expect(movedM(m), greaterThan(6),
          reason: 'the fix knows itself to 3 m; eight metres is not wander');
    });

    test('a fix good only to 40 m, eight metres away, is not', () async {
      final m = await parked();
      m.setTarget(north(8), startLng, accuracyM: 40);
      run(m, 2);
      expect(movedM(m), lessThan(1),
          reason: 'eight metres is well inside what that fix admits to');
    });

    test('but a run of them gives way', () async {
      // Six fixes all saying the same new place. Noise does not agree with
      // itself six times.
      final m = await parked();
      for (var i = 0; i < 6; i++) {
        m.setTarget(north(8), startLng, accuracyM: 40);
        await gap();
      }
      run(m, 2);
      expect(movedM(m), greaterThan(6),
          reason: 'the marker must not be pinned indefinitely');
    });

    test('with no accuracy given, the old 15 m fallback still holds', () async {
      final m = await parked();
      m.setTarget(north(8), startLng); // no accuracyM
      run(m, 2);
      expect(movedM(m), lessThan(1));
    });

    test('a real drive is never held', () async {
      // Moving properly, the speed gate opens before the radius is consulted
      // at all.
      final m = SmoothMotion()..snapTo(startLat, startLng, bearing: 0);
      for (var i = 1; i <= 4; i++) {
        await gap();
        m.setTarget(north(6.0 * i), startLng, accuracyM: 40);
        run(m, 0.2);
      }
      expect(movedM(m), greaterThan(10),
          reason: 'a car at 30 m/s is not standing still');
    });
  });

  group('SmoothMotion.isAtTarget', () {
    test('is false while a turn is still in progress', () {
      final m = SmoothMotion()..setTarget(33.328, -86.788, bearing: 0);
      expect(m.isAtTarget, isTrue, reason: 'nothing to do yet');

      m.setBearing(180);
      expect(m.isAtTarget, isFalse,
          reason: 'the ticker must not park with the arrow half turned — '
              'that is the frozen-arrow bug');

      run(m, 0.5);
      expect(m.isAtTarget, isFalse, reason: 'still swinging round');
    });

    test('goes true once the turn has finished', () {
      final m = SmoothMotion()..setTarget(33.328, -86.788, bearing: 0);
      m.setBearing(180);
      run(m, 8);
      expect(m.isAtTarget, isTrue);
      expect(m.bearing, closeTo(180, 0.1));
    });

    test('still reports position, not only bearing', () {
      final m = SmoothMotion()..snapTo(33.328, -86.788, bearing: 0);
      expect(m.isAtTarget, isTrue);

      m.setTarget(33.428, -86.788, bearing: 0); // 11 km north
      expect(m.isAtTarget, isFalse);
    });
  });
}
