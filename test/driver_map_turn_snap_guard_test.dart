import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guards for the owner report 2026-11-01 (driver app, driving):
///  1. "al hacer zoom la flecha queda fuera de las líneas; alejado se ve
///     bien" — a METRE error (it grows with zoom): on the online/offline map
///     the matched street line always ends behind a moving car, so the fix
///     was never snapped and the arrow showed the raw GPS error.
///  2. "cuando la cámara gira no gira fluido, gira por pasos" — on the
///     online map a stale course repeat killed the turn glide and the camera
///     copied the arrow's 1 Hz rhythm; on every route surface (navigation
///     included) the road lock froze on each vertex and its heading stepped
///     per segment.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');
  final ctrl = read('lib/screens/driver/driver_online_controller.dart');
  final map = read('lib/screens/driver/driver_online_map.dart');
  final lock = read('lib/map/driver_road_lock.dart');

  String bodyOf(String src, String signature, {int maxLen = 2000}) {
    final start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    return src.substring(start, (start + maxLen).clamp(0, src.length));
  }

  group('#1 the searching arrow rides the street', () {
    test('the fix-level snap extends the matched line past its end', () {
      final body = bodyOf(map, 'LatLng _snapToRoute(LatLng raw) {', maxLen: 2600);
      expect(body, contains('extendPastEnd: !onRoute,'),
          reason: 'past the trace end the fix rides the straight '
              'continuation — without it a moving car is never snapped');
      expect(body, contains('headingDeg: _motion.hasPosition ? _motion.bearing : null,'),
          reason: 'the continuation is believed only along the car\'s course');
      expect(body, contains('result.trusted && !result.extended ? result.bearing : null'),
          reason: 'past the line only the POSITION is corrected — a turn '
              'begun there must still turn the arrow');
    });

    test('the per-frame re-projection does not extend (no lateral jumps)', () {
      final body = bodyOf(map, 'LatLng _snapRenderedToLine(LatLng p) {', maxLen: 900);
      expect(body.contains('extendPastEnd'), isFalse,
          reason: 'SmoothMotion glides between the snapped targets; an '
              'instant per-frame snap would jump at engage/release');
    });

    test('the continuation is gated: corridor, reach and course', () {
      expect(lock, contains('static const double extensionEngageM = 15.0;'));
      expect(lock, contains('static const double extensionReleaseM = 20.0;'));
      expect(lock, contains('static const double extensionMaxHeadingDeg = 20.0;'));
      expect(lock, contains('math.max(120.0, 9.0 *'));
    });
  });

  group('#2 the map turns smoothly', () {
    test('the online fix never feeds the stale course into SmoothMotion', () {
      expect(ctrl.contains('_smoothMoveTo(snappedLL, _roadLockBearing ?? _smoothedBearing'),
          isFalse,
          reason: '_smoothedBearing is the PREVIOUS fix\'s course here (the '
              'heading stream is async); the repeat cut the turn glide');
      expect(ctrl, contains('_smoothMoveTo(snappedLL, _roadLockBearing,'));
      expect(ctrl, contains('void _smoothMoveTo(LatLng target, double? heading,'));
    });

    test('the searching chase writes a sprung bearing and lets it settle', () {
      final body = bodyOf(ctrl,
          'if (_phase == _Phase.searching && !offerActive && _cameraFollowing)',
          maxLen: 4000);
      expect(body, contains('final camBearing = _searchCamSpring.step(_heading, dtSec,'));
      expect(body, contains('seed: _onlineCamState?.bearing);'),
          reason: 'engaging the chase starts from the real camera');
      expect(ctrl, contains('!_searchCamSpring.isSettled(_heading));'),
          reason: 'a turn the car stops in must still finish (heat gate)');
      expect(ctrl, contains('_searchCamSpring.reset();'));
      final gesture = bodyOf(map, 'void _onCameraMoveStarted() {', maxLen: 2400);
      expect(gesture, contains('_searchCamSpring.reset();'),
          reason: 'after the finger, follow re-seeds from the real camera');
    });

    test('the overlay arrow still rotates by heading minus the REAL camera', () {
      final widgets = read('lib/screens/driver/driver_online_widgets.dart');
      expect(widgets, contains('final bearing = _heading - (_onlineCamState?.bearing ?? 0);'));
    });

    test('the road lock never parks on a vertex and steers by the chord', () {
      final closest = bodyOf(lock, '_closest(LatLng raw) {', maxLen: 2600);
      expect(closest, contains('if (_insideSegment(raw, previous, next)) {'),
          reason: 'the 8 m continuity slack held the projection on each end '
              'vertex for ~8 m — arrow, nav camera and heading in steps');
      final heading = bodyOf(lock, 'double? _headingAt(', maxLen: 1800);
      expect(heading, contains('return _chord(point, aim) ?? currentBearing;'),
          reason: 'the per-segment bearing jumped a whole vertex angle');
      expect(heading, contains('(speedMps * 0.8).clamp(6.0, 24.0)'));
    });

    test('navigation keeps its damped camera on the (now continuous) tangent',
        () {
      final nav = read('lib/screens/driver/driver_nav_view.dart');
      expect(nav, contains('bearing: _stepCamBearing(_dot.bearing, dt),'));
      expect(nav, contains('static const double _camBearingOmega = 4.5;'));
      expect(nav, contains('_dot.setBearing(_roadLockBearing!);'));
    });
  });
}
