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
      expect(widgets.contains("'icon-rotation-alignment', 'map'"), isTrue,
          reason: 'the off-screen driver annotation must rotate WITH the '
              'map on a twisted view — viewport-locked iconRotate counts '
              'from screen-up and points wrong (2026-09-19)');
    });
  });

  group('offline home parity (user spec 2026-09-19: "si esta offline debe '
      'hacer lo mismo")', () {
    final home =
        File('lib/screens/driver/driver_home_screen.dart').readAsStringSync();

    test('the offline follow writes the dot bearing, never north-up', () {
      final body =
          bodyOf(home, 'void _followHomeCameraToDriver() {', maxLen: 1200);
      expect(body.contains('bearing: _goldDot.bearing'), isTrue,
          reason: 'the offline chase must rotate with the arrow exactly like '
              'the online one');
      expect(body.contains('pitch: 0.0'), isTrue);
      expect(body.contains('_lastHomeCamWriteBearing = _goldDot.bearing'),
          isTrue);
    });

    test('rotate gesture on, manual twist unlatches, flights suppressed', () {
      final gestures =
          bodyOf(home, 'await ctrl.gestures.updateSettings(', maxLen: 700);
      expect(gestures.contains('rotateEnabled: true'), isTrue);
      expect(gestures.contains('pitchEnabled: false'), isTrue);
      expect(home.contains('void _maybeUnlatchHomeOnManualRotate('), isTrue);
      final body = bodyOf(home, 'void _maybeUnlatchHomeOnManualRotate(',
          maxLen: 700);
      expect(body.contains('_homeCamFlightUntil'), isTrue);
      expect(body.contains('_onHomeMapPanned()'), isTrue);
      expect(home.contains('onZoomListener: (_) => _onHomeMapPanned()'),
          isTrue,
          reason: 'pinch unlatches too — same 60 fps fight otherwise');
      expect(home.contains("'icon-rotation-alignment', 'map'"), isTrue,
          reason: 'offline home: the off-screen dot annotation rotates WITH '
              'the map on a twisted view (2026-09-19)');
    });

    test('the overlay arrow compensates the camera rotation on BOTH screens',
        () {
      // The painter rotates from screen-up: with a rotating chase the raw
      // dot bearing draws the arrow off-vertical — subtract the camera
      // bearing so it keeps pointing straight UP while the world turns.
      final homeDot = bodyOf(
          home,
          'if (!_dotOverlayOwnsMarker) return const SizedBox.shrink();',
          maxLen: 700);
      expect(homeDot.contains('_homeCamState?.bearing ?? 0'), isTrue,
          reason: 'offline arrow must stay up in the heading-up chase');
      final onlineDot = bodyOf(
          widgets,
          'if (!_dotOverlayOwnsMarker) return const SizedBox.shrink();',
          maxLen: 700);
      expect(onlineDot.contains('_onlineCamState?.bearing ?? 0'), isTrue,
          reason: 'same compensation on the online screen');
    });
  });

  group('no double arrow after pinch + recenter (user report 2026-09-19)',
      () {
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    final home =
        File('lib/screens/driver/driver_home_screen.dart').readAsStringSync();

    test('the online resume timer flushes the annotation to opacity 0 NOW',
        () {
      final body = bodyOf(map, '_followResumeTimer = Timer(', maxLen: 700);
      expect(body.contains('_cameraFollowing = true'), isTrue);
      expect(body.contains('_updateDriverAnnotation();'), isTrue,
          reason: 'a parked driver produces no ticker frames — without the '
              'explicit flush the stale visible annotation and the overlay '
              'drew two arrows for as long as the car stood still');
    });

    test('the online unlatch hands the marker to the annotation '
        'deterministically', () {
      final body = bodyOf(map, 'void _onCameraMoveStarted() {', maxLen: 2400);
      expect(body.contains('_cameraFollowing = false'), isTrue);
      expect(body.contains('_updateDriverAnnotation();'), isTrue,
          reason: 'no waiting for an indirect caller while parked');
    });

    test('the offline home does the same on both flips', () {
      final body = bodyOf(home, 'void _onHomeMapPanned() {', maxLen: 1500);
      expect(
          RegExp(r'_updateMyLocAnnotation\(\);')
              .allMatches(body)
              .length,
          greaterThanOrEqualTo(2),
          reason: 'refollow hides the annotation, unlatch shows it — both '
              'deterministic, never via a stale opacity');
    });

    test('mid-drag the NATIVE annotation owns the arrow on BOTH screens '
        '(user report 2026-09-23)', () {
      final body = bodyOf(map, 'void _onCameraMoveStarted() {', maxLen: 2400);
      expect(body.contains('_mapDragUntil'), isTrue,
          reason: 'every scroll/zoom event renews the drag latch');
      expect(body.contains('_dragSettleTimer'), isTrue,
          reason: 'the settle timer hands the marker back to the overlay '
              'once the drag parks — a parked driver makes no ticker frames');
      final owns = bodyOf(map, 'bool get _dotOverlayOwnsMarker', maxLen: 2200);
      expect(owns.contains('DateTime.now().isBefore(_mapDragUntil)'), isTrue,
          reason: 'during the drag the overlay steps aside: its projected '
              'pixel trails the finger over the channel, the GL-rendered '
              'annotation never does — the arrow stays on the street');

      final homeBody = bodyOf(home, 'void _onHomeMapPanned() {', maxLen: 1500);
      expect(homeBody.contains('_homeDragUntil'), isTrue);
      expect(homeBody.contains('_homeDragSettleTimer'), isTrue);
      final homeOwns =
          bodyOf(home, 'bool get _dotOverlayOwnsMarker', maxLen: 1400);
      expect(homeOwns.contains('DateTime.now().isBefore(_homeDragUntil)'),
          isTrue,
          reason: 'the offline home map plays by the same mid-drag rule');
    });
  });

  group('GPS accuracy gate (user report 2026-09-19, "flecha en el mar")', () {
    test('a fix that declares itself worse than 65 m never moves the arrow',
        () {
      final body = bodyOf(ctrl, 'onPosition: (pos) {', maxLen: 2600);
      expect(body.contains('pos.accuracy <= 65'), isTrue,
          reason: 'beach multipath / cold-start hops carry a huge radius — '
              'only the display target is gated, presence keeps flowing');
      expect(body.contains('fixUsable'), isTrue);
    });

    test('both getCurrentPosition seeds pass the same gate', () {
      final rejected = RegExp('seed rejected').allMatches(ctrl).length;
      expect(rejected, greaterThanOrEqualTo(2),
          reason: 'the web and native cold seeds must not plant the arrow '
              'somewhere wrong either');
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
