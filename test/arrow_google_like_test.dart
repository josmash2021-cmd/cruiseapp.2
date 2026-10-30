import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:geolocator/geolocator.dart';

import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/services/heading_service.dart';
import 'package:cruise_app/utils/route_splice.dart';

/// Owner request 2026-10-29: the arrow should behave like Google's —
/// turn the moment the car turns, and keep going along the route through
/// a tunnel.
void main() {
  group('route walking (tunnel mode)', () {
    const a = LatLng(33.0, -86.0);
    const b = LatLng(33.001, -86.0); // ~110.5 m north
    const c = LatLng(33.001, -85.998); // then ~186 m east
    const route = [a, b, c];

    test('walks past a corner onto the next leg with its bearing', () {
      final r = RouteSplice.pointAlong(route, a, 150)!;
      expect(RouteSplice.haversineM(b, r.$1), closeTo(150 - 110.54, 1.0));
      expect(r.$2, closeTo(90, 1));
    });

    test('stays on the first leg before the corner, heading north', () {
      final r = RouteSplice.pointAlong(route, a, 50)!;
      expect(RouteSplice.haversineM(a, r.$1), closeTo(50, 0.5));
      expect(r.$2, closeTo(0, 1));
    });

    test('clamps at the destination', () {
      final r = RouteSplice.pointAlong(route, a, 5000)!;
      expect(RouteSplice.haversineM(c, r.$1), lessThan(0.01));
    });

    test('nav view drives the tunnel mode safely', () {
      final nav = File('lib/screens/driver/driver_nav_view.dart')
          .readAsStringSync()
          .replaceAll('\r\n', '\n');
      expect(nav, contains('_tunnelTimer?.cancel();'));
      expect(nav, contains('_tunnelAnchor = null; // a real fix ends tunnel mode'));
      expect(nav, contains('age > const Duration(seconds: 30)'));
      expect(nav, contains('speed < 3'));
      expect(nav, contains('RouteSplice.distanceToPolylineM(pts, here) > 40'));
    });
  });

  group('instant turns from the heading sensor', () {
    late StreamController<double> compass;
    late HeadingService svc;
    late DateTime clock;
    final seen = <double>[];

    Position fix(double course) => Position(
          latitude: 33,
          longitude: -86,
          timestamp: clock,
          accuracy: 5,
          altitude: 0,
          altitudeAccuracy: 0,
          heading: course,
          headingAccuracy: 2,
          speed: 12,
          speedAccuracy: 0.5,
        );

    Future<void> sensor(double h) async {
      clock = clock.add(const Duration(milliseconds: 100));
      compass.add(h);
      await Future<void>.delayed(Duration.zero);
    }

    setUp(() async {
      seen.clear();
      clock = DateTime(2026, 10, 29, 12);
      compass = StreamController<double>();
      svc = HeadingService(compassReadings: compass.stream, now: () => clock);
      svc.stream.listen(seen.add);
      svc.start();
      await sensor(200); // wrong absolute value inside the car
      clock = clock.add(const Duration(seconds: 1));
      svc.onFix(fix(10)); // driving, real course 10°
      await Future<void>.delayed(Duration.zero);
    });

    tearDown(() async {
      svc.dispose();
      await compass.close();
    });

    test('the arrow starts turning before the next GPS fix', () async {
      expect(svc.usingCourse, isTrue);
      expect(seen.last, closeTo(10, 0.01));
      for (var i = 0; i < 8; i++) {
        await sensor(215); // car turned 15 degrees right
      }
      expect(seen.last, greaterThan(20),
          reason: 'course + (smoothed) sensor change, not the absolute 215');
      expect(seen.last, lessThanOrEqualTo(25.01));
    });

    test('a phone spun in the hand is capped at 60 degrees', () async {
      for (var i = 0; i < 12; i++) {
        await sensor(320); // +120
      }
      expect(seen.last, closeTo(70, 0.01));
    });

    test('compass noise on a straight road never wobbles the arrow', () async {
      final before = seen.length;
      for (var i = 0; i < 12; i++) {
        await sensor(i.isEven ? 201.5 : 198.5); // +-1.5 jitter
      }
      expect(seen.length, before, reason: 'under the 3 degree gate: no emits');
    });

    test('jitter under 1° does nothing; stale window does nothing', () async {
      final before = seen.length;
      await sensor(200.5);
      expect(seen.length, before);
      clock = clock.add(const Duration(seconds: 2));
      await sensor(240);
      expect(seen.length, before, reason: 'only 1.6 s after a GPS course');
    });
  });

  // Owner decision 2026-10-30 (driver map): compass off.
  test('with the compass off, turning the phone never turns the arrow', () async {
    final compass = StreamController<double>();
    var clock = DateTime(2026, 10, 30, 12);
    final svc = HeadingService(
        compassReadings: compass.stream, now: () => clock, useCompass: false);
    final seen = <double>[];
    final sub = svc.stream.listen(seen.add);
    svc.start();
    compass.add(200);
    compass.add(90);
    await Future<void>.delayed(Duration.zero);
    expect(seen, isEmpty, reason: 'parked + phone turned: nothing moves');
    Position p(double lng) => Position(
          latitude: 33, longitude: lng, timestamp: clock, accuracy: 5,
          altitude: 0, altitudeAccuracy: 0, heading: 45, headingAccuracy: 2,
          speed: 10, speedAccuracy: 0.5);
    svc.onFix(p(-86));
    await Future<void>.delayed(Duration.zero);
    expect(seen.last, closeTo(45, 0.01), reason: 'driving: the real course');
    await sub.cancel();
    // Never listened (compass off), so close() would wait forever.
    unawaited(compass.close());
    svc.dispose();
  });
}
