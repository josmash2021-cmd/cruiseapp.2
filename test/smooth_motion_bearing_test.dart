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
