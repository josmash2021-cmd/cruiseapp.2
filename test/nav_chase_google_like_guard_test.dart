import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner request 2026-10-30: bigger nav arrow; chase camera from the first
/// frame; the map turns smoothly (damped, no overshoot) like Google's
/// navigation while the arrow shows quick turns at once.
void main() {
  final nav = File('lib/screens/driver/driver_nav_view.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('the nav arrow is 20% bigger, overlay and native alike', () {
    expect(nav, contains('static const double _kNavArrowScale = 1.2;'));
    expect(nav,
        contains('const sz = GoldLocationDot.driverOverlaySize * _kNavArrowScale;'));
    expect(nav,
        contains('scale: GoldLocationDot.driverIconSize * _kNavArrowScale,'));
  });

  test('the map bearing follows the arrow on a damped spring', () {
    expect(nav, contains('bearing: _stepCamBearing(_dot.bearing, dt),'));
    expect(nav, contains('2 * _camBearingOmega * _camBearingVel'),
        reason: 'critically damped: settles without overshoot');
    expect(nav, contains('valueListenable: _arrowScreenBearing,'),
        reason: 'the overlay arrow shows what the camera has not turned yet');
  });

  test('a turn the car stops in the middle of still finishes', () {
    expect(nav, contains('_ensureCamSettle();'));
    expect(nav, contains('_camSettleTicker?.dispose();'));
    expect(nav, contains('_camSettleTicker?.stop();'));
  });

  test('opening the nav snaps the chase pose, arrow straight up', () {
    final snap = nav.substring(nav.indexOf('  void _snapToChasePose() {'));
    expect(snap.substring(0, 900), contains('_snapCamBearing(_dot.bearing);'));
    expect(nav, contains('_CamState _camState = _CamState.following;'));
    expect(nav, contains('bool _overview = false;'));
  });

  test('the nav always opens the arrow at full size', () {
    expect(nav, contains(
        'GoldLocationDot.animateOfferMarkerScale(this, 1.0, durationMs: 0);'));
  });
}
