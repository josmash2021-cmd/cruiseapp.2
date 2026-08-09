import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the close/reopen crash-and-bounce fixes (session 2026-08-09,
/// audit tanda 1).
///
/// Three independent reopen-flow bugs:
///   1. RiderRatingScreen mounted a native MapWidget WITHOUT
///      MapSurfaceCoordinator — for the whole incoming transition it lived
///      next to the tracking screen's full-screen map: two native Mapbox
///      surfaces, which closes the app on iOS. At the end of EVERY ride.
///   2. Backing out of tracking landed on a FRESH HomeScreen whose
///      _didAutoResumeRide was instance-false, so home found the persisted
///      ride and pushed tracking straight back — the rider could never sit
///      on home mid-trip.
///   3. pushNamed('/home') was answered by _getPageForRoute with
///      SplashScreen for EVERY named route, re-running the whole boot
///      instead of just going home.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final rating =
      File('lib/screens/rider_rating_screen.dart').readAsStringSync();
  final home = File('lib/screens/home_screen.dart').readAsStringSync();
  final trackingCtrl = File('lib/controllers/rider_tracking_controller.dart')
      .readAsStringSync();
  final trackingScreen =
      File('lib/screens/rider_tracking_screen.dart').readAsStringSync();

  group('the rating screen never mounts a native map', () {
    test('no MapWidget / WebMapView remains', () {
      expect(rating.contains('mapbox.MapWidget'), isFalse,
          reason: 'a native map here lives next to the tracking map for '
              'the whole transition — two surfaces, iOS closes the app');
      expect(rating.contains('WebMapView'), isFalse,
          reason: 'the backdrop is a static image now, on every platform');
    });

    test('the backdrop is a StaticRoutePreview like the driver rating screen', () {
      expect(rating.contains('StaticRoutePreview('), isTrue,
          reason: 'driver_rate_rider_screen.dart solved this exact crash '
              'with a static backdrop — same fix belongs here');
    });
  });

  group('backing out of tracking never bounces back', () {
    test('the auto-resume latch is process-wide on the widget class', () {
      expect(home.contains('static bool autoResumeConsumed'), isTrue,
          reason: 'an instance latch resets with every fresh HomeScreen — '
              'the bounce comes straight back');
    });

    test('_navigateToHome latches BEFORE building home', () {
      final start = trackingCtrl.indexOf('void _navigateToHome()');
      expect(start, isNonNegative, reason: '_navigateToHome not found');
      final body = trackingCtrl.substring(start, start + 700);
      final latch = body.indexOf('HomeScreen.autoResumeConsumed = true');
      final push = body.indexOf('pushAndRemoveUntil');
      expect(latch, isNonNegative,
          reason: 'leaving tracking by choice must suppress the auto-resume '
              'or home pushes tracking straight back');
      expect(push, isNonNegative);
      expect(latch, lessThan(push),
          reason: 'the latch must be set before home is built');
    });

    test('the pickup-overlay cancel goes home directly, never via pushNamed', () {
      final start = trackingScreen.indexOf('onCancelled: () async {');
      expect(start, isNonNegative, reason: 'onCancelled not found');
      final body = trackingScreen.substring(start, start + 1200);
      expect(body.contains("pushNamedAndRemoveUntil('/home'"), isFalse,
          reason: '_getPageForRoute answers every named route with '
              'SplashScreen — the named call re-runs the whole boot');
      expect(body.contains('const HomeScreen()'), isTrue,
          reason: 'the cancel path must land on HomeScreen directly');
      expect(body.contains('HomeScreen.autoResumeConsumed = true'), isTrue,
          reason: 'a cancelled trip must never auto-resume');
    });
  });
}
