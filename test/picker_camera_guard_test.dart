import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/state/rider_trip_controller.dart';

/// Guardian for the picker camera snap-back fix (commit 1199791b).
///
/// The bug had three heads, so the guard has three sections:
///   1. Phase discipline — pickingLocation is only exited via
///      finishPickingLocation(); _tryFetchRoute must never flip it.
///   2. Boot camera — a recreated MapWidget boots from the last live frame
///      (_lastCam*), never from the GPS fix or the handoff.
///   3. GPS gate — every GPS-driven camera write is behind
///      _gpsMayMoveCamera, which is closed while the picker is up.
///
/// Sections 2 and 3 read the source the same way the backend guardians do:
/// the camera paths need a live Mapbox surface, so what a unit test CAN pin
/// is that the guards are wired where the writes happen.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('phase discipline (pure state)', () {
    test('startPickingLocation enters the picker phase', () {
      final c = RiderTripController();
      c.startPickingLocation();
      expect(c.state.phase, RiderPhase.pickingLocation);
    });

    test('finishPickingLocation is the only exit, to previewRoute', () {
      final c = RiderTripController();
      c.startPickingLocation();
      c.finishPickingLocation();
      expect(c.state.phase, RiderPhase.previewRoute);
    });

    test('finishPickingLocation is a no-op outside the picker', () {
      final c = RiderTripController();
      expect(c.state.phase, RiderPhase.idle);
      c.finishPickingLocation();
      expect(c.state.phase, RiderPhase.idle,
          reason: 'must not invent a transition from idle');
    });
  });

  group('boot camera remembers the last live frame', () {
    final src =
        File('lib/screens/ride_request_screen.dart').readAsStringSync();

    test('cameraOptions prefers _lastCam* over the handoff', () {
      final boot = RegExp(r'cameraOptions:\s*mapbox\.CameraOptions\(');
      final start = boot.firstMatch(src)!.end;
      final block = src.substring(start, start + 900);
      final lastFrame = block.indexOf('_lastCamCenter?.longitude');
      final handoff = block.indexOf('widget.handoffLng');
      expect(lastFrame, isNonNegative,
          reason: 'the boot camera must read _lastCamCenter');
      expect(handoff, isNonNegative,
          reason: 'the handoff stays as the first-open fallback');
      expect(lastFrame, lessThan(handoff),
          reason: 'a recreated map boots where the rider left it, '
              'not at the handoff — this ordering IS the fix');
    });

    test('onCameraChangeListener feeds _lastCam*', () {
      final listener = RegExp(r'onCameraChangeListener:\s*\(cam\)\s*\{');
      final start = listener.firstMatch(src)!.end;
      final block = src.substring(start, start + 600);
      for (final field in [
        '_lastCamCenter',
        '_lastCamZoom',
        '_lastCamPitch',
        '_lastCamBearing',
      ]) {
        expect(block.contains(field), isTrue,
            reason: '$field must be tracked per camera frame or a recreated '
                'map boots stale');
      }
    });
  });

  group('GPS camera writes stay gated', () {
    final ctrl =
        File('lib/screens/ride_request_controller.dart').readAsStringSync();

    test('_gpsMayMoveCamera closes for picker, phase, route and user', () {
      final getter = RegExp(r'bool get _gpsMayMoveCamera \{');
      final start = getter.firstMatch(ctrl)!.end;
      final body = ctrl.substring(start, start + 500);
      for (final term in [
        'widget.pickerMode',
        'RiderPhase.pickingLocation',
        '_userTookCamera',
      ]) {
        expect(body.contains(term), isTrue,
            reason: '$term removed from the gate — the picker snap-back '
                'returns through exactly this hole');
      }
    });

    test('both GPS camera writes are inside the gate', () {
      for (final marker in [
        'GPS last-known setCamera',
        'GPS fresh-fix flyTo',
      ]) {
        final at = ctrl.indexOf(marker);
        expect(at, isNonNegative, reason: 'marker "$marker" not found');
        final window = ctrl.substring(at - 400, at);
        expect(window.contains('if (_gpsMayMoveCamera)'), isTrue,
            reason: '"$marker" moved outside _gpsMayMoveCamera — an '
                'unguarded GPS write is the picker snap-back');
      }
    });

    test('_gpsMayMoveCamera closes when the surface is not ours', () {
      final getter = RegExp(r'bool get _gpsMayMoveCamera \{');
      final start = getter.firstMatch(ctrl)!.end;
      final body = ctrl.substring(start, start + 500);
      expect(body.contains('_mapMounted'), isTrue,
          reason: 'a booking sheet covered by the picker has no live '
              'surface; without this term its late cold-start GPS fix '
              'flyTo (top-down, rider position) fires while the rider '
              'drags the picker — the fresh-login snap-back');
    });
  });

  group('the map surface owner is per-instance', () {
    final src =
        File('lib/screens/ride_request_screen.dart').readAsStringSync();

    test('no shared static owner id remains', () {
      expect(src.contains('static const String _mapSurfaceOwner'), isFalse,
          reason: 'the booking sheet and the picker are BOTH '
              'RideRequestScreen and the picker is pushed on top of the '
              'sheet — a shared owner id makes MapSurfaceCoordinator skip '
              'the revoke (_owner == owner), leaving the sheet map alive '
              'underneath with a live controller');
    });

    test('the owner id carries a per-instance suffix', () {
      expect(src.contains('_nextMapSurfaceId'), isTrue,
          reason: 'each instance needs its own owner id so the picker '
              'acquire revokes the sheet underneath for real');
      expect(src.contains("'RideRequest-\${++_nextMapSurfaceId}'"), isTrue,
          reason: 'the suffix must be unique per instance');
    });
  });

  group('_tryFetchRoute never leaves the picker', () {
    final state =
        File('lib/state/rider_trip_controller.dart').readAsStringSync();

    test('the phase flip keeps pickingLocation', () {
      expect(
        state.contains('phase: _state.phase == RiderPhase.pickingLocation\n'
            '          ? RiderPhase.pickingLocation'),
        isTrue,
        reason: '_tryFetchRoute flipping out of pickingLocation mid-drag '
            'was the original snap-back — the picker exits ONLY via '
            'finishPickingLocation()',
      );
    });
  });
}
