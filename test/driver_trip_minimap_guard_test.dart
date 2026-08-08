import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver mini-map spec change (user spec 2026-08-08):
///
///   1. The bounds fold frames pickup + dropoff + route — `widget.driverPos`
///      is OUT of the fold (the route already covers both endpoints; framing
///      the driver's current fix pushed the zoom out). The NaN sentinel
///      guard and the rest of the fold stay untouched.
///   2. The zoom pull-back is −0.2 (was −1.2) with clamp [9.0, 15.5], in
///      BOTH the resume branch and the first-visit branch.
///   3. `_startMiniMapCar` draws the same PNG the rider tracking map uses
///      (`car_suv.png` / `car_sedan.png`, resized maxDim 240) at
///      iconSize 0.50 — no more `CarIconLoader.loadUberBytes`.
///   4. The web mirror `_setupWebPreview` drops driverPos from its
///      fitBounds too.
///
/// The map needs a live Mapbox surface, so this pins the source discipline.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final src = File('lib/screens/driver/driver_trip_accept_screen.dart')
      .readAsStringSync();

  /// Extracts the body of [signature] up to the next `///`-doc'd method or
  /// [maxLen] chars, whichever comes first.
  String bodyOf(String signature, {int maxLen = 4000}) {
    final start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    final end = src.indexOf(RegExp(r'\n  ///'), start + signature.length);
    return src.substring(
        start, end > start ? end : start + signature.length + maxLen);
  }

  group('bounds fold frames the trip, not the driver fix', () {
    test('allPoints has pickup + dropoff + route, no driverPos', () {
      final marker = src.indexOf('final allPoints = <LatLng>[');
      expect(marker, isNonNegative, reason: 'bounds fold not found');
      final end = src.indexOf('].where((p) =>', marker);
      final fold = src.substring(marker, end);
      expect(fold.contains('widget.pickupLatLng'), isTrue);
      expect(fold.contains('_dropoffLL'), isTrue);
      expect(fold.contains('_routePoints'), isTrue,
          reason: 'the route must stay in the bounds — it covers both endpoints');
      expect(fold.contains('driverPos'), isFalse,
          reason: 'framing the driver fix pushed the zoom out — this IS the '
              'bug the 2026-08-08 spec removed');
      // The sentinel guard after the fold is untouched.
      final guard = src.substring(end, end + 400);
      expect(guard.contains('isValidLatLng(p.latitude, p.longitude)'), isTrue,
          reason: 'the NaN guard of the fold must not be touched');
    });
  });

  group('zoom is the moderate −0.2 with clamp [9.0, 15.5]', () {
    test('both camera branches use the new spec', () {
      final matches = RegExp(r'- 0\.2\)\.clamp\(9\.0, 15\.5\)')
          .allMatches(src)
          .length;
      expect(matches, greaterThanOrEqualTo(2),
          reason: 'the −0.2 / [9.0, 15.5] zoom must appear in BOTH the '
              'resume branch and the first-visit branch');
      expect(src.contains('- 1.2).clamp(9.0, 14.0)'), isFalse,
          reason: 'the old −1.2 pull-back (map "breathes") is gone per the '
              'new user spec');
    });
  });

  group('_startMiniMapCar draws the tracking-map car PNG', () {
    test('no loadUberBytes, suv/sedan assets, iconSize 0.50', () {
      final body = bodyOf('Future<void> _startMiniMapCar() async {');
      expect(body.contains('loadUberBytes'), isFalse,
          reason: 'the Canvas-rendered black Uber car is gone — the mini '
              'map now uses the same PNG as the rider tracking map');
      expect(body.contains('assets/images/car_suv.png'), isTrue,
          reason: 'same asset mapping as tracking_map_car.dart');
      expect(body.contains('assets/images/car_sedan.png'), isTrue,
          reason: 'same asset mapping as tracking_map_car.dart');
      expect(body.contains('iconSize: 0.50'), isTrue,
          reason: 'user spec: iconSize up from 0.30 to 0.50');
      expect(body.contains('iconSize: 0.30'), isFalse);
      expect(body.contains('maxDim: 240'), isTrue,
          reason: 'the PNG is resized to maxDim 240 like the tracking map');
    });
  });

  group('web mirror', () {
    test('_setupWebPreview fitBounds drops driverPos too', () {
      final body = bodyOf('Future<void> _setupWebPreview(WebMapController c)');
      expect(body.contains('c.fitBounds(['), isTrue,
          reason: 'the web fitBounds mirror must exist');
      final fitStart = body.indexOf('c.fitBounds([');
      final fitEnd = body.indexOf('],', fitStart);
      final fit = body.substring(fitStart, fitEnd);
      expect(fit.contains('driverPos'), isFalse,
          reason: 'the web bounds mirror the native fold: pickup + dropoff + '
              'route, no driver fix');
      expect(fit.contains('widget.pickupLatLng'), isTrue);
      expect(fit.contains('_dropoffLL'), isTrue);
      expect(fit.contains('pts.map'), isTrue);
    });
  });
}
