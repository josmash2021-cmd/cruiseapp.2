import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/services/gps_service.dart';
import 'package:cruise_app/utils/smooth_motion.dart';
import 'package:cruise_app/widgets/gold_location_dot.dart';

/// Independent review 2026-10-30 of the arrow / nav / location work: each
/// test reproduces a confirmed defect and must stay green.
void main() {
  const lat0 = 33.32872, lng0 = -86.78781;
  double north(double m) => lat0 + m / 110540.0;

  late DateTime now;
  SmoothMotion engine() {
    now = DateTime(2026, 10, 30, 12);
    return SmoothMotion(clock: () => now)..snapTo(lat0, lng0, bearing: 0);
  }

  double metresOf(SmoothMotion m) => (m.lat! - lat0) * 110540.0;
  void run(SmoothMotion m, double seconds) {
    const dt = 1 / 60;
    for (var t = 0.0; t < seconds - 1e-9; t += dt) {
      now = now.add(const Duration(microseconds: 16667));
      m.tick(dt);
    }
  }

  void fix(SmoothMotion m, double atM, double speed, {bool stamped = true}) =>
      m.setTarget(north(atM), lng0,
          bearing: 0,
          accuracyM: 5,
          speedMps: speed,
          timestampMs: stamped ? now.millisecondsSinceEpoch.toDouble() : null);

  test('#1 an arrow far ahead of a crawling car comes back to it', () {
    final m = engine();
    var car = 0.0;
    for (var i = 0; i < 5; i++) {
      car += 15;
      fix(m, car, 15);
      run(m, 1);
    }
    run(m, 4); // fix gap: the arrow keeps rolling, the car brakes hard
    for (var i = 0; i < 15; i++) {
      car += 2; // crawling
      fix(m, car, 2);
      run(m, 1);
    }
    expect((metresOf(m) - car).abs(), lessThan(10),
        reason: 'unbounded "never go back" left it waiting tens of metres ahead');
  });

  test('#4 an untimed (tunnel) fix does not slow the next real one', () {
    final m = engine();
    var car = 0.0;
    for (var i = 0; i < 5; i++) {
      car += 15;
      fix(m, car, 15);
      run(m, 1);
    }
    for (var i = 0; i < 4; i++) {
      car += 7.5;
      fix(m, car, 15, stamped: false); // virtual fix every 0.5 s
      run(m, 0.5);
    }
    car += 15;
    fix(m, car, 15);
    run(m, 0.2);
    expect(m.speedMps, greaterThan(12), reason: 'was 6 m/s with the stale base');
  });

  test('#9 a parked ticker + ONE far fix glides, it does not snap', () {
    final m = engine();
    fix(m, 0, 0);
    run(m, 1);
    now = now.add(const Duration(seconds: 3)); // ticker parked, no fixes
    fix(m, 200, 0);
    run(m, 1 / 60);
    expect(metresOf(m), lessThan(5), reason: 'one bad reading must not throw it');
  });

  group('GpsService', () {
    final gps = GpsService();
    setUp(gps.debugResetReported);
    const mPerDegLng = 111320.0 * 0.8357;

    test('#5 city speed with 0.5 s fixes reports motion, not 0', () async {
      for (var i = 0; i < 5; i++) {
        gps.updatePosition(LatLng(lat0, lng0 + i * 4 / mPerDegLng), null, null,
            accuracyM: 15);
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
      expect(gps.reportedSpeed, greaterThan(5), reason: '8 m/s car');
      expect(gps.reportedHeading, closeTo(90, 3));
    });

    test('#3 a position with no accuracy does not block the fresh fix', () {
      gps.updatePosition(const LatLng(lat0, lng0), null, null);
      gps.updatePosition(LatLng(north(300), lng0), null, null, accuracyM: 60);
      expect(gps.reportedPos!.latitude, closeTo(north(300), 1e-9));
    });
  });

  test('#7 an immediate reset to full size always applies', () {
    GoldLocationDot.animateOfferMarkerScale(const TestVSync(), 1.0, durationMs: 0);
    GoldLocationDot.offerMarkerScale.value = 0.9; // grow-back stalled mid-way
    GoldLocationDot.animateOfferMarkerScale(const TestVSync(), 1.0, durationMs: 0);
    expect(GoldLocationDot.offerMarkerScale.value, 1.0);
  });
}
