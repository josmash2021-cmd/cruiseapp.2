import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the driver-online heading-up chase (user spec 2026-09-19):
///
///   1. Searching phase: the camera is a top-down CHASE that rotates WITH
///      the arrow — the per-frame write carries `_heading` (SmoothMotion's
///      lerped bearing), never a hard north-up 0 — and every "back to
///      searching" reset flies to the current heading, not to north.
///   2. The two-finger twist is enabled (rotateEnabled: true) and a manual
///      rotate unlatches follow even though the plugin has no
///      onRotateListener: the divergence between the camera's bearing and
///      the follow ticker's last write IS the manual gesture. Programmatic
///      flights are suppressed by _camFlightUntil.
///   3. Nav phases keep their tilted chase untouched.
void main() {
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final widgets = File('lib/screens/driver/driver_online_widgets.dart')
      .readAsStringSync();
  final map =
      File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

  String bodyOf(String src, String signature, {int maxLen = 2000}) {
    final start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    return src.substring(start, start + maxLen);
  }

  group('searching chase rotates heading-up, top-down (spec 2026-09-19)', () {
    test('the per-frame searching write carries _heading, not north-up', () {
      final body = bodyOf(
          ctrl, "if (_phase == _Phase.searching && !offerActive && _cameraFollowing)",
          maxLen: 1800);
      expect(body.contains('bearing: _heading'), isTrue,
          reason: 'the chase must rotate with the arrow — bearing 0 was the '
              'north-up map that never turned');
      expect(body.contains('pitch: 0'), isTrue,
          reason: 'top-down stays — the user asked rotation, not tilt');
      expect(body.contains('_cameraBearing = _heading'), isTrue,
          reason: 'the overlay sprite selection syncs to the same bearing');
      expect(body.contains('_lastCamWriteBearing = _heading'), isTrue,
          reason: 'the manual-rotate detector needs the last written value');
    });

    test('every searching reset flies to the current heading, never north',
        () {
      final resets = RegExp(
              r'_animateToPosition\(_pos!, zoom: 15\.5, bearing: _smoothedBearing, tilt: 0\)')
          .allMatches(ctrl)
          .length;
      expect(resets, greaterThanOrEqualTo(6),
          reason: 'expire/reject/accept/cancel/trip-end restores all keep '
              'the heading-up chase');
      expect(
          ctrl.contains(
              '_animateToPosition(_pos!, zoom: 15.5, bearing: 0, tilt: 0)'),
          isFalse,
          reason: 'a north-up reset is a rotation snap the next frame '
              'contradicts');
    });

    test('recenter + style-load keep the heading too', () {
      final recenter = bodyOf(map, 'void _recenterCamera() {', maxLen: 1400);
      expect(
          recenter.contains(
              '_animateToPosition(_pos!, zoom: 15.5, bearing: bearing, tilt: 0)'),
          isTrue,
          reason: 'the 10 s auto-refollow returns to the heading-up chase, '
              'not to north');
      expect(widgets.contains('bearing: _smoothedBearing'), isTrue,
          reason: 'the style-reload flatten must not snap the rotation to '
              'north either');
    });
  });

  group('two-finger rotate with a follow-safe unlatch', () {
    test('rotateEnabled is on, pitch stays off', () {
      final body =
          bodyOf(widgets, 'await ctrl.gestures.updateSettings(', maxLen: 600);
      expect(body.contains('rotateEnabled: true'), isTrue,
          reason: 'user spec: "el driver puede girar el mapa con los dedos"');
      expect(body.contains('pitchEnabled: false'), isTrue);
    });

    test('manual rotate unlatches via bearing divergence (no onRotateListener '
        'in the plugin), suppressed during programmatic flights', () {
      expect(map.contains('void _maybeUnlatchOnManualRotate('), isTrue);
      final body =
          bodyOf(map, 'void _maybeUnlatchOnManualRotate(', maxLen: 800);
      expect(body.contains('_camFlightUntil'), isTrue,
          reason: 'a flyTo\'s intermediate bearings are not a finger');
      expect(body.contains('_lastCamWriteBearing'), isTrue);
      expect(body.contains('_onCameraMoveStarted()'), isTrue,
          reason: 'the twist drops follow so the chase never fights it');
      expect(widgets.contains('onZoomListener: (_) {'), isTrue,
          reason: 'pinch unlatches too — same 60 fps fight otherwise');
    });
  });

  group('nav phases untouched', () {
    test('the tilted nav chase keeps 17.5/55 with the same bearing source', () {
      final body = bodyOf(ctrl, 'else if (isNav && _cameraFollowing) {',
          maxLen: 500);
      expect(body.contains('zoom: 17.5'), isTrue);
      expect(body.contains('pitch: 55'), isTrue);
      expect(body.contains('bearing: _heading'), isTrue);
    });
  });
}
