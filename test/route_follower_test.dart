import 'dart:math' as math;

import 'package:cruise_app/map/route_follower.dart';
import 'package:cruise_app/models/lat_lng.dart';
import 'package:flutter_test/flutter_test.dart';

/// The rider's car along the route (owner 2026-11-05, rule 63): on the
/// street, at the driver's pace, turning with the road, never backwards —
/// fed what the app really gets: one fix a second, phone GPS noise, a
/// network that delays each fix 0.15–0.7 s, and two phones whose clocks
/// disagree.
void main() {
  // An L: 300 m north, then 300 m east (local metres → lat/lng).
  const lat0 = 33.5, lng0 = -86.8;
  final kx = 111320.0 * math.cos(lat0 * math.pi / 180);
  LatLng ll(double x, double y) => LatLng(lat0 + y / 110540.0, lng0 + x / kx);
  (double, double) xy(LatLng p) =>
      ((p.longitude - lng0) * kx, (p.latitude - lat0) * 110540.0);
  final route = [ll(0, 0), ll(0, 300), ll(300, 300)];
  // The true car along the L at distance s.
  (double, double) along(double s) =>
      s <= 300 ? (0.0, s) : (math.min(300.0, s - 300), 300.0);
  double offLine((double, double) p) {
    final (x, y) = p;
    final d1 = y <= 300 && y >= 0 ? x.abs() : math.min(
        math.sqrt(x * x + y * y), math.sqrt(x * x + (y - 300) * (y - 300)));
    final d2 = x >= 0 && x <= 300 ? (y - 300).abs() : double.infinity;
    return math.min(d1, d2);
  }

  /// Drives [seconds] at [speed] (m/s, by time), fixes at 1 Hz; returns
  /// per-frame (drawn xy, true xy, bearing).
  List<((double, double), (double, double), double)> drive(
    double Function(double t) speed, {
    double seconds = 40,
    double noiseM = 2.5,
    Duration skew = Duration.zero,
    int seed = 3,
  }) {
    final rng = math.Random(seed);
    double gauss() {
      final u = 1 - rng.nextDouble(), v = rng.nextDouble();
      return math.sqrt(-2 * math.log(u)) * math.cos(2 * math.pi * v);
    }

    final epoch = DateTime.utc(2026, 11, 5, 18);
    var now = epoch;
    final f = RouteFollower(clock: () => now.add(skew))..setRoute(route);
    const dt = 1 / 60;
    var s = 0.0;
    final fixes = <(double, double, double, double, double)>[];
    final out = <((double, double), (double, double), double)>[];
    var next = 0.0;
    for (var t = 0.0; t <= seconds; t += dt) {
      now = epoch.add(Duration(microseconds: (t * 1e6).round()));
      if (t >= next) {
        final (x, y) = along(s);
        fixes.add((t + 0.15 + rng.nextDouble() * 0.55, x + gauss() * noiseM,
            y + gauss() * noiseM, speed(t) + gauss() * 0.3, t));
        next += 1;
      }
      fixes.sort((a, b) => a.$1.compareTo(b.$1));
      while (fixes.isNotEmpty && fixes.first.$1 <= t) {
        final fx = fixes.removeAt(0);
        final p = ll(fx.$2, fx.$3);
        f.onFix(p.latitude, p.longitude,
            speedMps: math.max(0, fx.$4),
            timestampMs: epoch.millisecondsSinceEpoch + fx.$5 * 1000);
      }
      f.tick(dt);
      s += speed(t) * dt;
      if (f.active) out.add((xy(f.position!), along(s), f.bearing));
    }
    return out;
  }

  double dist((double, double) a, (double, double) b) =>
      math.sqrt(math.pow(a.$1 - b.$1, 2) + math.pow(a.$2 - b.$2, 2));

  test('on the street, beside the driver, no jumps, never backwards', () {
    final frames = drive((t) => t < 3 ? 4 * t : 12, skew: const Duration(seconds: 5));
    expect(frames.length, greaterThan(1000));
    var worstOff = 0.0, worstStep = 0.0, sumGap = 0.0;
    var travelled = 0.0;
    for (var i = 1; i < frames.length; i++) {
      final (p, truth, _) = frames[i];
      worstOff = math.max(worstOff, offLine(p));
      final step = dist(p, frames[i - 1].$1);
      worstStep = math.max(worstStep, step);
      sumGap += dist(p, truth);
      // Never backwards: progress along the L only grows.
      final before = frames[i - 1].$1, now = p;
      final sBefore = before.$2 <= 299 ? before.$2 : 300 + before.$1;
      final sNow = now.$2 <= 299 ? now.$2 : 300 + now.$1;
      expect(sNow, greaterThanOrEqualTo(sBefore - 3.0),
          reason: 'the rounded corner trims a little — never a real step back');
      travelled += step;
    }
    expect(travelled, greaterThan(300));
    expect(worstOff, lessThan(3.0),
        reason: 'in the lane: only the rounded corner sits inside the bend');
    expect(worstStep, lessThan(0.5), reason: '12 m/s at 60 fps is 0.2 m');
    expect(sumGap / frames.length, lessThan(4.0),
        reason: 'at the driver, not a fix behind — even with clocks 5 s apart');
  });

  test('turns through the bend as the road does, no snap in heading', () {
    final frames = drive((t) => 10);
    var worstTurnPerFrame = 0.0;
    var sawNorth = false, sawEast = false;
    for (var i = 1; i < frames.length; i++) {
      var d = (frames[i].$3 - frames[i - 1].$3).abs() % 360;
      if (d > 180) d = 360 - d;
      worstTurnPerFrame = math.max(worstTurnPerFrame, d);
      final b = frames[i].$3;
      if (b < 5 || b > 355) sawNorth = true;
      if ((b - 90).abs() < 5) sawEast = true;
    }
    expect(sawNorth && sawEast, isTrue);
    expect(worstTurnPerFrame, lessThan(8),
        reason: 'a 90° corner over the rounded curve, never in one frame');
  });

  test('parked: GPS wander does not move the car', () {
    final frames = drive((t) => 0, seconds: 20, noiseM: 4);
    final first = frames.first.$1;
    for (final (p, _, _) in frames) {
      expect(dist(p, first), lessThan(1.0));
    }
  });

  test('off the route it steps aside; back on, it starts where the car is', () {
    final f = RouteFollower()..setRoute(route);
    final far = ll(60, 100);
    f.onFix(far.latitude, far.longitude, speedMps: 5);
    expect(f.active, isFalse);
    final on = ll(1, 100);
    final drawn = ll(0, 92);
    f.onFix(on.latitude, on.longitude, speedMps: 0, drawnNow: drawn);
    expect(f.active, isTrue);
    expect(dist(xy(f.position!), (0, 92)), lessThan(0.5),
        reason: 'no jump when the follower takes over');
  });
}
