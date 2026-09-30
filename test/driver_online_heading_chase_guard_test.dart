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
    test('the per-frame searching write carries the (possibly frozen) '
        'heading, never north-up', () {
      final body = bodyOf(
          ctrl, "if (_phase == _Phase.searching && !offerActive && _cameraFollowing)",
          maxLen: 4000);
      expect(body.contains('bearing: camBearing'), isTrue,
          reason: 'the chase must rotate with the arrow — bearing 0 was the '
              'north-up map that never turned');
      expect(body.contains('pitch: 0'), isTrue,
          reason: 'top-down stays — the user asked rotation, not tilt');
      expect(body.contains('_cameraBearing = camBearing'), isTrue,
          reason: 'the overlay sprite selection syncs to the same bearing');
      expect(body.contains('_lastCamWriteBearing = camBearing'), isTrue,
          reason: 'the manual-rotate detector needs the last written value');
    });

    test('parked/crawling: the map rotation freezes under ~3 mph unless the '
        'turn is real (user report 2026-09-27)', () {
      final body = bodyOf(
          ctrl, "if (_phase == _Phase.searching && !offerActive && _cameraFollowing)",
          maxLen: 4000);
      expect(body.contains('_currentSpeedMph < 3'), isTrue,
          reason: 'the compass owns the arrow while parked — without the '
              'deadband, magnetometer drift swings the whole map');
      expect(body.contains('if (bDiff <= 12) camBearing = lastWrittenB;'),
          isTrue,
          reason: 'a real turn (>12°) still re-aims the map');
      expect(body.contains('if (!unchanged) {'), isTrue,
          reason: 'identical parked cameras are not re-written 60×/s — but '
              'only the write is skipped, never the marker repaint below');
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

  group('single-map parity (2026-09-26: DriverHomeScreen murió — offline es '
      'un MODO de la misma pantalla)', () {
    // Online y offline corren sobre el mismo mapa, la misma chase y el mismo
    // marcador: la paridad ya no se pinea entre dos archivos — se pinea que
    // NADA en el camino del marcador/cámara/gestos esté gateado por el modo.
    final map2 =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

    test('the heading-up chase runs in BOTH modes (no _driverOnline gate)', () {
      final body = bodyOf(
          ctrl,
          'if (_phase == _Phase.searching && !offerActive && _cameraFollowing)',
          maxLen: 4000);
      expect(body.contains('bearing: camBearing'), isTrue,
          reason: 'the chase rotates with the arrow online AND offline — '
              'same map, same arrow');
      expect(body.contains('_driverOnline'), isFalse,
          reason: 'gating the chase on the mode would freeze the arrow for '
              'an offline driver watching the map');
    });

    test('the gesture handoff and marker ownership have no mode gate', () {
      final body =
          bodyOf(map2, 'void _onCameraMoveStarted() {', maxLen: 2400);
      expect(body.contains('_driverOnline'), isFalse);
      expect(body.contains('_markerFrame.value++;'), isTrue,
          reason: 'the overlay hides the same frame on every gesture event');
      final owns = bodyOf(map2, 'bool get _dotOverlayOwnsMarker', maxLen: 2200);
      expect(owns.contains('_driverOnline'), isFalse,
          reason: 'who draws the arrow is identical in both modes');
    });

    test('the overlay arrow compensates the camera rotation', () {
      // The painter rotates from screen-up: with a rotating chase the raw
      // dot bearing draws the arrow off-vertical — subtract the camera
      // bearing so it keeps pointing straight UP while the world turns.
      final onlineDot = bodyOf(
          widgets,
          'if (!_dotOverlayOwnsMarker) return const SizedBox.shrink();',
          maxLen: 700);
      expect(onlineDot.contains('_onlineCamState?.bearing ?? 0'), isTrue,
          reason: 'the arrow stays up in the heading-up chase');
    });
  });

  group('no double arrow after pinch + recenter (user report 2026-09-19)',
      () {
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

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

    test('mid-drag the NATIVE annotation owns the arrow (user report '
        '2026-09-23)', () {
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
    });
  });

  group('GPS accuracy gate (user reports 2026-09-19 "flecha en el mar" and '
      '2026-09-25 "flecha fuera de la linea al hacer zoom")', () {
    test('a fix that declares itself worse than 25 m never moves the arrow',
        () {
      final body = bodyOf(ctrl, 'onPosition: (pos) {', maxLen: 2600);
      expect(body.contains('pos.accuracy <= 25'), isTrue,
          reason: '65 m killed catastrophic hops, but a ±30-65 m fix still '
              'floated the arrow over blocks at pinch-zoom — only the '
              'display target is gated, presence keeps flowing');
      expect(body.contains('fixUsable'), isTrue);
    });

    test('both getCurrentPosition seeds pass the same gate', () {
      final rejected = RegExp('seed rejected').allMatches(ctrl).length;
      expect(rejected, greaterThanOrEqualTo(2),
          reason: 'the web and native cold seeds must not plant the arrow '
              'somewhere wrong either');
    });
  });

  group('zoom/drag arrow handoff (user report 2026-09-26: "al hacer zoom '
      'sale otra flecha / se queda en el medio")', () {
    final map2 =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

    test('the overlay hides the SAME frame on EVERY gesture event, not only '
        'on the follow→free transition', () {
      final body = bodyOf(map2, 'void _onCameraMoveStarted() {', maxLen: 2400);
      final bump = body.indexOf('_markerFrame.value++;');
      final flip = body.indexOf('_updateDriverAnnotation();');
      final followCheck = body.indexOf('if (!_cameraFollowing) return;');
      expect(bump, isNonNegative,
          reason: 'without the synchronous bump the overlay hid only when '
              'the lagging camera-change event arrived — it painted at '
              'trailing pixels mid-gesture');
      expect(flip, isNonNegative);
      expect(bump, lessThan(followCheck),
          reason: 'the hide must not wait for the follow transition');
      expect(flip, lessThan(followCheck));
      // El merged screen corre el MISMO handler en ambos modos — con el home
      // muerto ya no hay segundo archivo que pinear (lo cubre el grupo
      // single-map parity: nada de esto está gateado por _driverOnline).
    });

    test('no centred arrow when the camera is not following — never a '
        'mid-screen guess', () {
      // The "annotation missing" escape draws only while following.
      final owns =
          bodyOf(map2, 'bool get _dotOverlayOwnsMarker', maxLen: 2200);
      expect(
          owns.contains(
              'if (_goldDotAnnot == null) return _cameraFollowing;'),
          isTrue,
          reason: 'drawing centred with the camera panned away points at a '
              'street the driver is not on');
      // The builder: the Center fallback is gated on following.
      final onlineBuilder = bodyOf(
          widgets,
          'if (!_dotOverlayOwnsMarker) return const SizedBox.shrink();',
          maxLen: 1400);
      expect(
          onlineBuilder.indexOf('_cameraFollowing') <
              onlineBuilder.indexOf('Center(child: dot)'),
          isTrue,
          reason: 'Center is by construction only while following');
    });
  });

  group('nav phases keep their tilt, with the same rate-limited chase', () {
    test('the tilted nav chase keeps 17.5/55 and now trails the arrow '
        '(2026-09-30)', () {
      final body = bodyOf(ctrl, 'else if (isNav && _cameraFollowing) {',
          maxLen: 700);
      expect(body.contains('zoom: 17.5'), isTrue);
      expect(body.contains('pitch: 55'), isTrue);
      expect(body.contains('bearing: camBearing'), isTrue);
      expect(body.contains('_chaseCamBearing(_heading, dtSec)'), isTrue,
          reason: 'same arrow source — the camera just trails it at 60°/s');
    });
  });

  group('zoom clone: the trailing-edge flush (user report 2026-09-27 — '
      'pinch/double-tap duplicates the arrow)', () {
    final map = File('lib/screens/driver/driver_online_map.dart')
        .readAsStringSync();

    test('a flush skipped on busy is re-fired when the channel drains', () {
      final pendingSets =
          RegExp(r'_annotFlushPending = true;').allMatches(map).length;
      expect(pendingSets, greaterThanOrEqualTo(2),
          reason: 'BOTH annotation paths (gold dot and nav car): a state '
              'written while the channel was busy must be re-flushed — a '
              'parked driver has no later caller, so the native side would '
              'keep stale opacity/geometry and the overlay + annotation '
              'draw two arrows');
      final consumes =
          RegExp(r'if \(_annotFlushPending\) \{').allMatches(map).length;
      expect(consumes, greaterThanOrEqualTo(2));
      final recalls = RegExp(r'Future\.microtask\(_updateDriverAnnotation\)')
          .allMatches(map)
          .length;
      expect(recalls, greaterThanOrEqualTo(2));
    });
  });

  group('camera rotation chase (user report 2026-09-30: "la camara gira '
      'paso a paso / cuadro por cuadro")', () {
    test('both driver maps trail the arrow at ≤60°/s with a deadband', () {
      final ctrlSrc = File('lib/screens/driver/driver_online_controller.dart')
          .readAsStringSync();
      final navSrc =
          File('lib/screens/driver/driver_nav_view.dart').readAsStringSync();
      for (final src in [ctrlSrc, navSrc]) {
        expect(src.contains('_chaseCamBearing('), isTrue,
            reason: 'the camera must trail the arrow — copying it per frame '
                'steps the view with 1 Hz course noise');
        expect(src.contains('const maxDps = 60.0'), isTrue);
        expect(src.contains('if (d.abs() <= 0.2)'), isTrue,
            reason: 'the deadband parks the camera on micro-jitter');
      }
      expect(ctrlSrc.contains('_chaseCamBearing(_heading, dtSec)'), isTrue);
      expect(navSrc.contains('_chaseCamBearing(_dot.bearing, dt)'), isTrue);
    });
  });

  group('compass EMA (user report 2026-09-27: the arrow turns in steps and '
      'wanders before settling)', () {
    final svc = File('lib/services/heading_service.dart').readAsStringSync();

    test('the compass branch is low-passed; the GPS course stays raw', () {
      expect(svc.contains('_compassAlpha = 0.08'), isTrue,
          reason: '~0.4 s at the sensor 20 Hz — steps arrive as a sweep');
      final onCompass =
          bodyOf(svc, 'void _onCompass(CompassEvent e) {', maxLen: 1100);
      expect(onCompass.contains('_compassEma'), isTrue);
      expect(
          bodyOf(svc, 'if (usingCourse) {', maxLen: 300)
              .contains('_emit(_course!)'),
          isTrue,
          reason: 'the driving course stays RAW — pre-lagging it poisoned '
              'SmoothMotion turn-rate measurement (2026-09-25)');
    });
  });
}
