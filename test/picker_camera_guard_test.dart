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

    test('cameraOptions prefers _lastCam* for EVERY mode, picker included', () {
      final boot = RegExp(r'cameraOptions:\s*mapbox\.CameraOptions\(');
      final start = boot.firstMatch(src)!.end;
      final block = src.substring(start, start + 900);
      // One chain for both modes:
      //   _lastCamCenter?.longitude ?? widget.handoffLng ?? _center!.longitude
      // initState seeds _lastCam* from the handoff, so the FIRST boot in
      // picker mode still lands on the selected prediction — but a
      // recreation mid-drag boots where the rider left the map.
      final lng = RegExp(r'_lastCamCenter\?\.longitude\s*\?\?\s*'
          r'widget\.handoffLng\s*\?\?\s*_center!\.longitude');
      expect(lng.hasMatch(block), isTrue,
          reason: 'longitude must prefer the last live frame, '
              'then handoff, then _center as final fallback');
      final lat = RegExp(r'_lastCamCenter\?\.latitude\s*\?\?\s*'
          r'widget\.handoffLat\s*\?\?\s*_center!\.latitude');
      expect(lat.hasMatch(block), isTrue,
          reason: 'latitude must prefer the last live frame, '
              'then handoff, then _center as final fallback');
    });

    test('picker mode must NOT bypass _lastCam* in the boot camera', () {
      // Build 575 special-cased picker mode to boot from the handoff seed.
      // That re-opened the cold-start snap-back: platform-view recreations
      // (common while covers/transitions settle right after app open) UNDID
      // the rider's drag and re-centered the pin on the seed — for "Choose
      // on map" the seed is the rider's own location. GPS cannot poison
      // _lastCam* anymore (initState seeds it from the handoff; in picker
      // mode GPS writes neither _center nor the camera), so the bypass
      // protects nothing and breaks recreations.
      final boot = RegExp(r'cameraOptions:\s*mapbox\.CameraOptions\(');
      final start = boot.firstMatch(src)!.end;
      final block = src.substring(start, start + 900);
      expect(block.contains('widget.pickerMode'), isFalse,
          reason: 'a pickerMode branch inside cameraOptions means the boot '
              'frame ignores _lastCam* — every recreation snaps the picker '
              'back to the seed and the drag is lost');
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

    test('_lastCam* is seeded from the boot frame in initState', () {
      // Build 573 report: the fields were null until the first camera event
      // (and null forever if iOS never fires it for gestures), so any
      // platform-view recreation booted at the handoff seed — the picker
      // snapped back to the seed address mid-drag.
      final start = src.indexOf('void initState() {');
      final body = src.substring(start, start + 8000);
      final handoffSeed = RegExp(r'handoffCenter\s*=\s*LatLng\('
          r'widget\.handoffLat!,\s*widget\.handoffLng!\)');
      expect(handoffSeed.hasMatch(body), isTrue,
          reason: 'the handoff coordinates must seed a LatLng before it is '
              'assigned to _lastCamCenter');
      expect(body.contains('_lastCamCenter = handoffCenter;'), isTrue,
          reason: 'without the seed, a recreation before the first camera '
              'event boots at the handoff/GPS seed — the snap the rider '
              'keeps reporting');
      expect(body.contains('_lastCamPitch = widget.handoffPitch ?? 45.0'), isTrue,
          reason: 'the boot uses the same fallbacks as cameraOptions');
    });

    test('initState seeds _center to the handoff in picker mode', () {
      final start = src.indexOf('void initState() {');
      final body = src.substring(start, start + 8000);
      final seedCenter = RegExp(r'if\s*\(\s*widget\.pickerMode\s*\)\s*'
          r'_center\s*=\s*handoffCenter;');
      expect(seedCenter.hasMatch(body), isTrue,
          reason: 'in picker mode _center must be the selected prediction, '
              'not the rider GPS, so every cameraOptions fallback stays on '
              'the chosen address');
      final guardCenter = RegExp(r'if\s*\(\s*!\s*widget\.pickerMode\s*\)\s*\{');
      expect(guardCenter.hasMatch(body), isTrue,
          reason: 'the normal _center = initialPickupDetails assignment must '
              'be skipped in picker mode');
    });
  });

  group('GPS camera writes stay gated', () {
    final ctrl =
        File('lib/screens/ride_request_controller.dart').readAsStringSync();

    test('_gpsMayMoveCamera hard-closes for picker mode before any other term', () {
      final getter = RegExp(r'bool get _gpsMayMoveCamera \{');
      final start = getter.firstMatch(ctrl)!.end;
      final body = ctrl.substring(start, start + 500);
      expect(body.contains('if (widget.pickerMode)'), isTrue,
          reason: 'picker mode must short-circuit the gate so a single '
              'miss in the boolean expression cannot allow a GPS move');
      final earlyReturn = body.indexOf('if (widget.pickerMode)');
      final allowed = body.indexOf('final allowed =');
      expect(earlyReturn, lessThan(allowed),
          reason: 'the picker short-circuit must come before the allowed '
              'computation, not after');
      for (final term in [
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
