import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/utils/bearing_spring.dart';
import 'package:cruise_app/utils/smooth_motion.dart';

/// Owner report 2026-11-01 (driver map, online/offline): "cuando la cámara
/// gira no gira fluido, gira por pasos; tiene que girar suave, como gira el
/// conductor manejando".
///
/// Two causes, both on the searching map's heading-up chase:
///  1. Every fix fed SmoothMotion the PREVIOUS fix's course right before the
///     new one (the heading stream delivers a microtask later), which read
///     as "the turn stopped" and cut the turn-rate glide to 10–30 %.
///  2. The camera copied the arrow frame by frame, so the arrow's
///     once-a-second rhythm (turn, rest, catch up) was the map's rhythm.
/// Fixed: the course is fed once per fix, and the camera follows the arrow
/// on a critically damped [BearingSpring].
void main() {
  group('BearingSpring', () {
    test('turns the short way across north', () {
      final s = BearingSpring(omega: 3.5)..snap(350);
      for (var i = 0; i < 30; i++) {
        s.step(10, 1 / 60);
      }
      // Heading from 350 toward 10 means growing through 360/0, never
      // sweeping back through 180.
      final v = s.value!;
      expect(v > 350 || v < 10, isTrue, reason: 'went the long way: $v');
      for (var i = 0; i < 300; i++) {
        s.step(10, 1 / 60);
      }
      expect(BearingSpring.shortestArc(s.value!, 10).abs(), lessThan(0.1));
      expect(s.isSettled(10), isTrue);
    });

    test('a step lands without overshoot (critically damped)', () {
      final s = BearingSpring(omega: 3.5)..snap(0);
      var maxSeen = 0.0;
      for (var i = 0; i < 600; i++) {
        final v = s.step(90, 1 / 60);
        if (v < 180) maxSeen = math.max(maxSeen, v);
      }
      expect(maxSeen, lessThanOrEqualTo(90.0001));
      expect((s.value! - 90).abs(), lessThan(0.1));
    });

    test('starts at the seed (the real camera), never jumps to the target',
        () {
      final s = BearingSpring(omega: 3.5);
      final first = s.step(90, 1 / 60, seed: 10);
      expect(first, closeTo(10, 0.5),
          reason: 'engaging the chase must not rotate the map in one frame');
      s.reset();
      expect(s.value, isNull);
      expect(s.isSettled(123), isTrue, reason: 'nothing to animate');
      expect(s.step(45, 1 / 60), 45, reason: 'no seed: start on the target');
    });
  });

  group('searching chase through a turn, 1 Hz iOS course', () {
    // A 30°/s turn from north to east between t=1 s and t=4 s, at 10 m/s,
    // one fix per second, rendered at 60 fps for 9 s.
    ({List<double> arrow, List<double> cam}) drive({
      required bool staleRepeat,
      required bool spring,
    }) {
      var now = DateTime(2026, 1, 1);
      final m = SmoothMotion(clock: () => now);
      var lat = 27.77, lng = -82.64;
      m.snapTo(lat, lng, bearing: 0);
      final cam = BearingSpring(omega: 3.5);
      double course = 0;
      final arrow = <double>[], camOut = <double>[];
      for (var k = 1; k <= 9; k++) {
        final prev = course;
        course = math.min(90.0, 30.0 * math.max(0, k - 1.0));
        final r = course * math.pi / 180;
        lat += 10 * math.cos(r) / 110540.0;
        lng += 10 * math.sin(r) / (111320.0 * math.cos(lat * math.pi / 180));
        // The online fix path: setTarget, then the heading stream's course.
        m.setTarget(lat, lng,
            bearing: staleRepeat ? prev : null,
            accuracyM: 5,
            timestampMs: now.millisecondsSinceEpoch.toDouble(),
            speedMps: 10);
        m.setBearing(course);
        for (var f = 0; f < 60; f++) {
          now = now.add(const Duration(microseconds: 16667));
          m.tick(1 / 60);
          arrow.add(m.bearing);
          camOut.add(spring ? cam.step(m.bearing, 1 / 60) : m.bearing);
        }
      }
      return (arrow: arrow, cam: camOut);
    }

    // Frames 1.5 s..5 s after the first fix: the middle of the turn.
    List<double> ratesMidTurn(List<double> b) => [
          for (var i = 91; i < 240; i++)
            BearingSpring.shortestArc(b[i - 1], b[i]) * 60,
        ];

    test('the old wiring turned the map in steps (documents the bug)', () {
      final old = drive(staleRepeat: true, spring: false);
      final rates = ratesMidTurn(old.cam);
      final stopped = rates.where((r) => r.abs() < 2).length / rates.length;
      expect(stopped, greaterThan(0.2),
          reason: 'the map stood still between fixes');
      expect(rates.reduce(math.max), greaterThan(90),
          reason: 'then lurched to catch up');
    });

    test('now the map never stops mid-turn and lands on the new street', () {
      final now = drive(staleRepeat: false, spring: true);
      final rates = ratesMidTurn(now.cam);
      expect(rates.reduce(math.min), greaterThan(15),
          reason: 'a 30°/s turn must keep the map turning every frame');
      expect(rates.reduce(math.max), lessThan(55));
      // Bounded swing past the end of an abrupt constant-rate turn (the
      // worst case), well inside SmoothMotion's own fishtail guard (< 38°).
      final over = now.cam.reduce(math.max) - 90;
      expect(over, lessThan(18));
      expect((now.cam.last - 90).abs(), lessThan(2.0),
          reason: 'settled on the new street');
    });
  });

  test('the screen wires the spring with ω 3.5', () {
    final scr = File('lib/screens/driver/driver_online_screen.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    expect(scr, contains('const double _kSearchCamBearingOmega = 3.5;'));
    expect(scr, contains('BearingSpring(omega: _kSearchCamBearingOmega)'));
  });
}
