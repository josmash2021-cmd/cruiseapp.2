import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:cruise_app/utils/smooth_motion.dart';

/// Guard for the angular glide (user report 2026-09-25, "la flecha no gira
/// fluido en las curvas / cuadro por cuadro"): a course staircase at the
/// ~1 Hz iOS fix cadence must render as CONTINUOUS rotation — the old
/// staircase target + low-pass closed each step in ~0.3 s and then parked
/// until the next sample.
void main() {
  group('turn-rate glide through curves', () {
    test('a 1 Hz course staircase through a 90° turn rotates continuously, '
        'never in bursts, and still settles', () async {
      final m = SmoothMotion();
      m.snapTo(25.8, -80.1, bearing: 0);

      final deltas = <double>[];
      double prev = m.bearing;
      final ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
        m.tick(0.016);
        deltas.add(m.bearing - prev);
        prev = m.bearing;
      });
      Future<void> wait(int ms) => Future.delayed(Duration(milliseconds: ms));

      await wait(500);
      final marks = <int>[];
      m.setBearing(30);
      marks.add(deltas.length);
      await wait(1000);
      m.setBearing(60);
      marks.add(deltas.length);
      await wait(1000);
      m.setBearing(90);
      marks.add(deltas.length);
      // The turn ends but the feed keeps talking — real course stream.
      await wait(1000);
      m.setBearing(90);
      await wait(1000);
      m.setBearing(90);
      await wait(1500);
      ticker.cancel();

      // Continuity: in each 1 Hz gap, the frames 0.3 s..0.9 s after the
      // sample — where the burst close used to park — must keep rotating.
      for (var k = 0; k < marks.length; k++) {
        final mark = marks[k];
        if (mark + 56 > deltas.length) continue;
        final window = deltas.sublist(mark + 18, mark + 56);
        final rotating = window.where((d) => d.abs() > 0.03).length;
        expect(rotating / window.length, greaterThan(0.6),
            reason: 'gap ${k + 1}: the arrow parked after the burst — the '
                'turn must glide the whole gap between 1 Hz samples');
      }

      // Settles once the course stops turning: within 3° of 90°.
      expect((m.bearing - 90).abs(), lessThan(3.0));
    });

    test('a bogus pair of samples cannot spin the arrow (120°/s cap)',
        () async {
      final m = SmoothMotion();
      m.snapTo(25.8, -80.1, bearing: 0);
      final deltas = <double>[];
      double prev = m.bearing;
      final ticker = Timer.periodic(const Duration(milliseconds: 16), (_) {
        m.tick(0.016);
        deltas.add(m.bearing - prev);
        prev = m.bearing;
      });
      Future<void> wait(int ms) => Future.delayed(Duration(milliseconds: ms));

      await wait(300);
      m.setBearing(0);
      await wait(1000);
      m.setBearing(150); // 150°/s measured — extrapolation capped at 120
      await wait(2500);
      ticker.cancel();

      // The aim never extrapolates past target + cap×lead: even with the
      // feed quiet after a wild 150° jump, the marker must stop at
      // 150 + 120×1.0 s, never run away spinning.
      expect(m.bearing, lessThan(150 + 120 * 1.0 + 5),
          reason: 'the extrapolated aim is bounded by the capped turn rate');
      // And it did chase the target — not freeze in place.
      expect(m.bearing, greaterThan(60));
    });
  });
}
