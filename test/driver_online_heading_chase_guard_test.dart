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
  final widgets =
      File('lib/screens/driver/driver_online_widgets.dart').readAsStringSync();
  final map =
      File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

  String bodyOf(String src, String signature, {int maxLen = 2000}) {
    final start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    return src.substring(start, start + maxLen);
  }

  group('searching chase rotates heading-up, top-down (spec 2026-09-19)', () {
    test(
        'the per-frame searching write carries the (possibly frozen) '
        'heading, never north-up', () {
      final body = bodyOf(ctrl,
          "if (_phase == _Phase.searching && !offerActive && _cameraFollowing)",
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

    test('online clears padding; offline zone fit pauses the chase', () {
      expect(ctrl, contains('_kZeroCamPadding'));
      final scr = File('lib/screens/driver/driver_online_screen.dart')
          .readAsStringSync();
      expect(scr, contains('final _kZeroCamPadding'));
      expect(ctrl, contains('padding: followPadding,'),
          reason: 'the chase writes the mode-appropriate padding every frame');
      expect(ctrl, contains('lastPadding.bottom == followPadding.bottom'),
          reason:
              'opening or closing the offline sheet must refresh the inset');
      final map =
          File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
      expect(map, contains('padding: _kZeroCamPadding'),
          reason: 'online recenter clears stale zone padding');
      expect(map, contains('_pauseFollowForZoneFit();'),
          reason: 'offline frames all zones without a competing chase');
    });

    test(
        'the camera mirrors the arrow directly at every speed — heading-up '
        'always (2026-10-16 noche, final spec)', () {
      final body = bodyOf(ctrl,
          "if (_phase == _Phase.searching && !offerActive && _cameraFollowing)",
          maxLen: 4000);
      expect(body.contains('final camBearing = _heading;'), isTrue,
          reason: 'ONE source while moving AND parked — the user wants the '
              'map to rotate with the phone (heading-up), the arrow centred '
              'by the zero-padding write; the parked camera freeze is dead');
      expect(body.contains('parkedCompass'), isFalse,
          reason: 'no parked freeze — tilting/moving the phone must rotate '
              'the camera, not lock it at a stale bearing');
      expect(body.contains('if (!unchanged) {'), isTrue,
          reason: 'identical parked cameras are still not re-written 60×/s');
    });

    test('every searching reset flies to the current heading, never north', () {
      final resets = RegExp(
              r'_animateToPosition\(_pos!,\s*zoom: 15\.5, bearing: _smoothedBearing, tilt: 0\)')
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
      final recenter = bodyOf(map, 'void _recenterCamera() {', maxLen: 3200);
      expect(recenter.contains('bearing: bearing'), isTrue,
          reason: 'manual recenter returns to the heading-up chase, '
              'not to north');
      expect(recenter.contains('_recenterWithFollow('), isTrue);
      expect(recenter.contains('zoom: isNav ? 17.5 : 15.5'), isTrue,
          reason: 'street zoom remains the online/navigation target');
      expect(recenter.contains('tilt: isNav ? 55 : 0'), isTrue);
      // Recenter by mode (2026-10-13/14 specs): OFFLINE = centre ON THE
      // ARROW at the zone-view zoom (the state-centroid frame died);
      // ONLINE = the ARROW — the zone frame moved to the LEFT compass FAB.
      expect(recenter.contains('_recenterArrowZoneZoom()'), isTrue,
          reason: 'offline recenter centres the arrow at the zone-fit zoom — '
              'never the state-centroid frame');
      expect(recenter.contains('_fitZone('), isFalse,
          reason: 'online recenter centres the ARROW — the zone frame is '
              'the compass button’s job, not the recenter FAB’s');
      expect(recenter.contains("recenter_fit"), isTrue);
      // The compass (LEFT FAB) frames the zone NORTH-UP (2026-10-13 spec:
      // "de forma recta, no de lado"); the zone view is never rotated.
      expect(map, contains('void _onZoneCompassTap()'));
      final fitZone = bodyOf(map, 'Future<void> _fitZone(', maxLen: 900);
      expect(fitZone.contains('bearing: 0'), isTrue,
          reason: 'the zone frame is always north-up');
      expect(fitZone.contains('bearing: _smoothedBearing'), isFalse);
      // …and the LEFT cluster carries it online with a chosen zone.
      final scr = File('lib/screens/driver/driver_online_screen.dart')
          .readAsStringSync();
      final leftCluster = scr.indexOf('_onZoneCompassTap');
      expect(leftCluster, isNonNegative);
      expect(scr, contains('Icons.explore_rounded'),
          reason: 'the left FAB is a compass');
      expect(recenter.contains('zoom:'), isTrue);
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

    test(
        'manual rotate unlatches via bearing divergence (no onRotateListener '
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

  group(
      'single-map parity (2026-09-26: DriverHomeScreen murió — offline es '
      'un MODO de la misma pantalla)', () {
    // Online y offline corren sobre el mismo mapa, la misma chase y el mismo
    // marcador: la paridad ya no se pinea entre dos archivos — se pinea que
    // NADA en el camino del marcador/cámara/gestos esté gateado por el modo.
    final map2 =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

    test('the heading-up chase runs in BOTH modes (no _driverOnline gate)', () {
      final body = bodyOf(ctrl,
          'if (_phase == _Phase.searching && !offerActive && _cameraFollowing)',
          maxLen: 4000);
      expect(body.contains('bearing: camBearing'), isTrue,
          reason: 'the chase rotates with the arrow online AND offline — '
              'same map, same arrow');
      // The mode may pick the resting ZOOM (2026-10-11: offline + zones =
      // region view) but must never gate the chase itself — pin the chase
      // CONDITION intact, not a body that may now mention the mode for zoom.
      expect(
          ctrl.contains(
              'if (_phase == _Phase.searching && !offerActive && _cameraFollowing) {'),
          isTrue,
          reason: 'gating the chase on the mode would freeze the arrow for '
              'an offline driver watching the map');
    });

    test('the gesture handling and marker ownership have no mode gate', () {
      final body = bodyOf(map2, 'void _onCameraMoveStarted() {', maxLen: 1200);
      expect(body.contains('_driverOnline'), isFalse);
      expect(body.contains('_markerFrame.value++;'), isTrue,
          reason: 'the overlay repaints synchronously on every gesture event');
      final owns = bodyOf(map2, 'bool get _dotOverlayOwnsMarker', maxLen: 2200);
      expect(owns.contains('_driverOnline'), isFalse,
          reason: 'who draws the arrow is identical in both modes');
    });

    test('the overlay arrow compensates the camera rotation', () {
      // The painter rotates from screen-up: with a rotating chase the raw
      // dot bearing draws the arrow off-vertical — subtract the camera
      // bearing so it keeps pointing straight UP while the world turns.
      final onlineDot = bodyOf(widgets,
          'if (!_dotOverlayOwnsMarker) return const SizedBox.shrink();',
          maxLen: 700);
      expect(onlineDot.contains('_onlineCamState?.bearing ?? 0'), isTrue,
          reason: 'the arrow stays up in the heading-up chase');
    });
  });

  group('no double arrow after pinch + recenter (user report 2026-09-19)', () {
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

    test(
        'one guarded recenter completion resumes follow and flushes the marker',
        () {
      final body =
          bodyOf(map, 'Future<void> _recenterWithFollow(', maxLen: 5000);
      expect(body.contains('_cameraFollowing = true'), isTrue);
      expect(body.contains('_updateDriverAnnotation();'), isTrue,
          reason: 'a parked driver needs an explicit marker flush on landing');
      expect(body.contains('_cameraActionGate.isCurrent(seq)'), isTrue,
          reason: 'a stale flight cannot complete over a newer camera action');
      expect(map.contains('_followResumeTimer'), isFalse,
          reason: 'there is no second timer that can recenter twice');
      expect(map, contains('void _maybeCompleteRecenter'));
      expect(map, contains('_recenterLanding = RecenterLandingGuard(seq, pos)'),
          reason: 'follow resumes only when the actual camera arrives');
    });

    test('the native arrow never accepts a drag gesture', () {
      expect('isDraggable: false'.allMatches(map).length, 2,
          reason: 'both native annotations are born non-draggable');
      expect('isDraggable = false'.allMatches(map).length, 2,
          reason: 'both existing annotations stay non-draggable on update');
    });

    test(
        'the online unlatch hands the marker to the annotation '
        'deterministically', () {
      final body = bodyOf(map, 'void _onCameraMoveStarted() {', maxLen: 2400);
      expect(body.contains('_cameraFollowing = false'), isTrue);
      expect(body.contains('_updateDriverAnnotation();'), isTrue,
          reason: 'no waiting for an indirect caller while parked');
    });

    test(
        'mid-gesture the overlay KEEPS the arrow — one arrow in every state '
        '(user report 2026-10-10)', () {
      // The old handoff to the native annotation mid-drag produced three
      // visible differences at once: size jump, wrong heading, double-arrow
      // flicker. The overlay now keeps the marker through the gesture,
      // projecting per frame from the camera state that arrives with each
      // rendered frame (onCameraChangeListener) — the same zero-IPC glue as
      // the ride-request pin labels.
      final body = bodyOf(map, 'void _onCameraMoveStarted() {', maxLen: 2400);
      expect(body.contains('_mapDragUntil'), isFalse,
          reason: 'the drag latch that handed the arrow to the annotation '
              'mid-gesture is gone');
      expect(body.contains('_dragSettleTimer'), isFalse,
          reason: 'no settle handback either — there is no handoff anymore');
      expect(body.contains('_markerFrame.value++;'), isTrue,
          reason: 'the overlay still repaints synchronously per event');
      final owns = bodyOf(map, 'bool get _dotOverlayOwnsMarker', maxLen: 2200);
      expect(owns.contains('_mapDragUntil'), isFalse,
          reason: 'no drag veto on ownership — the same arrow stays');
      expect(owns.contains('_dotScreenOffset != null'), isTrue,
          reason: 'not-following still projects the real pixel');
      // The projection must tolerate the heading-UP map (bearing = driver
      // heading ≠ 0): the flat-only variant returned null there, the overlay
      // refused to draw, and the native annotation took over mid-gesture —
      // the size/direction/flicker the driver reported (2026-10-10).
      expect(map.contains('FlatMapProjection.screenOffsetHeading('), isTrue,
          reason: 'the arrow projects on the rotated flat map too');
      expect(owns.contains('if (_isCardAnimating) return false;'), isTrue,
          reason: 'the annotation keeps exactly one job: the offer-preview '
              'programmatic flight, whose events trail the flyTo');
      // The per-frame camera feed that glues the overlay mid-gesture.
      expect(widgets.contains('onCameraChangeListener'), isTrue);
      final listener =
          bodyOf(widgets, 'onCameraChangeListener: (data) {', maxLen: 500);
      expect(listener.contains('_onlineCamState = data.cameraState'), isTrue);
      expect(listener.contains('_markerFrame.value++;'), isTrue);
      // The field itself is gone from the screen state.
      final screen = File('lib/screens/driver/driver_online_screen.dart')
          .readAsStringSync();
      expect(screen.contains('_mapDragUntil'), isFalse);
      expect(screen.contains('_dragSettleTimer'), isFalse);
    });
  });

  group(
      'GPS accuracy gate (user reports 2026-09-19 "flecha en el mar" and '
      '2026-09-25 "flecha fuera de la linea al hacer zoom")', () {
    test('a fix that declares itself worse than 25 m never moves the arrow',
        () {
      final body = bodyOf(ctrl, 'onPosition: (pos) {', maxLen: 3400);
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

  group(
      'zoom/drag arrow handoff (user report 2026-09-26: "al hacer zoom '
      'sale otra flecha / se queda en el medio")', () {
    final map2 =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

    test(
        'the overlay repaints the SAME frame on EVERY gesture event, not '
        'only on the follow→free transition', () {
      final body = bodyOf(map2, 'void _onCameraMoveStarted() {', maxLen: 2400);
      final bump = body.indexOf('_markerFrame.value++;');
      final flip = body.indexOf('_updateDriverAnnotation();');
      final followCheck = body.indexOf('if (!_cameraFollowing) return;');
      expect(bump, isNonNegative,
          reason: 'without the synchronous bump the overlay would only '
              'repaint when the lagging camera-change event arrived');
      expect(flip, isNonNegative);
      expect(bump, lessThan(followCheck),
          reason: 'the repaint must not wait for the follow transition');
      expect(flip, lessThan(followCheck));
      // El merged screen corre el MISMO handler en ambos modos — con el home
      // muerto ya no hay segundo archivo que pinear (lo cubre el grupo
      // single-map parity: nada de esto está gateado por _driverOnline).
    });

    test(
        'no centred arrow when the camera is not following — never a '
        'mid-screen guess', () {
      // The "annotation missing" escape draws only while following.
      final owns = bodyOf(map2, 'bool get _dotOverlayOwnsMarker', maxLen: 2200);
      expect(
          owns.contains('if (_goldDotAnnot == null) return _cameraFollowing;'),
          isTrue,
          reason: 'drawing centred with the camera panned away points at a '
              'street the driver is not on');
      // The builder: the Center fallback is gated on following.
      final onlineBuilder = bodyOf(widgets,
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
    test(
        'the tilted nav chase keeps 17.5/55 and now trails the arrow '
        '(2026-09-30)', () {
      final body =
          bodyOf(ctrl, 'else if (isNav && _cameraFollowing) {', maxLen: 700);
      expect(body.contains('zoom: 17.5'), isTrue);
      expect(body.contains('pitch: 55'), isTrue);
      expect(body.contains('bearing: _heading'), isTrue,
          reason: 'the tilted chase mirrors the arrow — the arrow IS the '
              'rotation channel, no second filter on top');
    });
  });

  group(
      'zoom clone: the trailing-edge flush (user report 2026-09-27 — '
      'pinch/double-tap duplicates the arrow)', () {
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();

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

  group(
      'camera rotation = mirror of the arrow (user reports '
      '2026-09-27/30)', () {
    test('NO chase layer survives in either driver map', () {
      final ctrlSrc = File('lib/screens/driver/driver_online_controller.dart')
          .readAsStringSync();
      final navSrc =
          File('lib/screens/driver/driver_nav_view.dart').readAsStringSync();
      final screenSrc = File('lib/screens/driver/driver_online_screen.dart')
          .readAsStringSync();
      for (final src in [ctrlSrc, navSrc, screenSrc]) {
        expect(src.contains('_chaseCamBearing'), isFalse,
            reason: 'the linear-rate chase read robotic — rotation belongs '
                'to the arrow alone, the camera only mirrors it');
        expect(src.contains('_camChaseBearingValue'), isFalse);
      }
      expect(navSrc.contains('bearing: _dot.bearing'), isTrue);
    });

    test('the turn-rate blend is adaptive — noise jumps earn less trust', () {
      final sm = File('lib/utils/smooth_motion.dart').readAsStringSync();
      expect(sm.contains('measured.abs() > 45.0 ? 0.25 : 0.7'), isTrue,
          reason: 'real city turns (≤45°/s) track fast; multipath bursts '
              'land as one calm average — the flat 0.8 blend pulsed the '
              'arrow through traffic');
      expect(sm.contains('d.abs() < 5.0 && _vBearing.abs() > 20.0'), isTrue,
          reason: 'a stable course with a big residual rate kills the tail '
              'this sample — the arrow must not fishtail past a completed '
              'turn (user report 2026-10-02, "se colea")');
    });
  });

  group(
      'compass EMA (user report 2026-09-27: the arrow turns in steps and '
      'wanders before settling)', () {
    final svc = File('lib/services/heading_service.dart').readAsStringSync();

    test('the compass branch is low-passed; the GPS course stays raw', () {
      expect(svc.contains('_compassAlpha = 0.08'), isTrue,
          reason: '~0.4 s at the sensor 20 Hz — steps arrive as a sweep');
      final onCompass =
          bodyOf(svc, 'void _onCompassHeading(double? h) {', maxLen: 1100);
      expect(onCompass.contains('_compassEma'), isTrue);
      expect(svc.contains('_compassDeadBandDeg = 0.02'), isTrue,
          reason: 'slow phone turns are not swallowed by the old 0.5° gate');
      expect(
          bodyOf(svc, 'if (usingCourse) {', maxLen: 300)
              .contains('_emit(_course!)'),
          isTrue,
          reason: 'the driving course stays RAW — pre-lagging it poisoned '
              'SmoothMotion turn-rate measurement (2026-09-25)');
    });
    test('the map build never bangs _pos (2026-10-11 black screen)', () {
      // Fresh install + a cold fix rejected for accuracy → _pos stayed null
      // → `_pos!` in the map builder threw → driver screen all black AND a
      // dead recenter. The anchor falls back to Miami downtown instead.
      final w = File('lib/screens/driver/driver_online_widgets.dart')
          .readAsStringSync();
      final mapW = bodyOf(w, 'Widget _mapW(bool isDark) {', maxLen: 2600);
      expect(mapW.contains('_pos!'), isFalse,
          reason: 'a missing fix must never crash the map build');
      expect(mapW.contains('_mapAnchor'), isTrue);
    });

    test('a viewport resize re-projects the arrow NOW (2026-10-16)', () {
      // User report: "cuando el telefono se gira la flecha se mueve del
      // sitio donde esta el driver" — a pure rotation emits no camera event,
      // so the overlay kept the pixel computed with the OLD viewport until
      // the next fix. The LayoutBuilder bumps the marker frame on a size
      // change (post-frame: a notify mid-build is setState-in-build).
      final w = File('lib/screens/driver/driver_online_widgets.dart')
          .readAsStringSync();
      expect(w,
          contains('if (_onlineMapSize != null && _onlineMapSize != newSize)'),
          reason: 'the size change is detected in the LayoutBuilder');
      expect(w, contains('addPostFrameCallback((_) {'),
          reason: 'the bump is post-frame, never mid-build');
      expect(w.contains('_markerFrame.value++'), isTrue,
          reason: 'the bump re-projects the overlay immediately');
    });
  });

  group('offline recenter FAB + button looks (2026-10-11)', () {
    final screen =
        File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    final offline = File('lib/screens/driver/driver_online_offline.dart')
        .readAsStringSync();
    final widgets = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();

    test('the offline FAB recentres through the shared glide', () {
      expect(screen.contains('!_cameraFollowing'), isTrue);
      // The offline FAB is the LAST _RecenterFab in the build — it comes
      // after the morphing GO button in the Stack (2026-10-13, "el botón de
      // recentrar no funciona cuando el sheet está cerrado": the GO's
      // invisible full-width box covered it and swallowed its taps).
      final fabIdx = screen.lastIndexOf('_RecenterFab(');
      expect(fabIdx, isNonNegative);
      final block = screen.substring(fabIdx - 900, fabIdx + 400);
      expect(block.contains('!_driverOnline'), isTrue,
          reason: 'the FAB is the OFFLINE one');
      expect(block.contains('_recenterCamera();'), isTrue);
      expect(block.contains('_panelFrac'), isTrue,
          reason: 'it floats above the sheet at its CURRENT height — the '
              'sheet now rests half-open (2026-10-13 spec)');
      final goIdx = screen.indexOf('_buildMorphingGoButton(');
      expect(goIdx, isNonNegative);
      expect(fabIdx, greaterThan(goIdx),
          reason: 'the offline recenter FAB paints ON TOP of the GO box or '
              'the collapsed sheet leaves it untappable');
    });

    test(
        'the pill GO: long + centred label (2026-10-16), Cruise logo, zone '
        'label', () {
      // User spec 2026-10-16 (Dash foto 3): the open pill is LONG — the row
      // minus the calendar disc (46) and a 12 gap — and the GO ONLINE label
      // reads CENTRED. The 2026-10-14 left/~62% spec is dead. With no zone
      // picked the label reads "Selecciona zona" — NEVER "Verify first" —
      // and picking a zone crossfades it into "GO ONLINE".
      expect(offline, contains('box.maxWidth - 58'),
          reason: 'the open pill is long: the full row minus the calendar '
              'disc (46) and its 12 pt of air');
      expect(offline, contains('Alignment.centerLeft'),
          reason: 'the pill still hugs the left so the calendar rides right');
      expect(offline.contains('verifyFirst'), isFalse,
          reason: '"VERIFY FIRST" is dead — no zone picked names the task');
      expect(offline, contains('AnimatedSwitcher'),
          reason: 'the fluid "Select zone" → "GO ONLINE" crossfade');
      expect(offline, contains('mainAxisAlignment: MainAxisAlignment.center'),
          reason: '2026-10-16 spec: the label is centred on the long pill');
      expect(offline, contains('alignment: Alignment.center'),
          reason: 'the two crossing labels centre too');
      expect(offline, contains('assets/images/cruise_logo.png'),
          reason: 'the Cruise logo beside the label');
      expect(offline, contains('BlendMode.srcIn'),
          reason: 'the logo is rendered in the button foreground so it '
              'reads on gold');
      // 2026-10-15 spec: heartbeat DEAD ("sin animación de latido o
      // respiración"); the shine sweep lives on the OPEN pill only.
      expect(offline, contains('const throb = 1.0'),
          reason: 'the heartbeat is dead — the button holds a fixed scale');
      expect(offline, contains('_goGlossCtrl!.value'),
          reason: 'the shine sweep drives off the gloss clock');
      expect(
          offline,
          contains('!dimmed &&\n                    morph > 0.5 &&'
              '\n                    faceState == 0'),
          reason: '2026-10-15 spec: the bright sweep paints ONLY on the open '
              'pill ("la animación brillante solo cuando el sheet esté '
              'abierto") — and 2026-10-23: NEVER on the grey face-gated or '
              'paused GO (the animation belongs to GO ONLINE)');
      expect(
          offline,
          contains('!dimmed &&\n                    morph <= 0.5 &&'
              '\n                    faceState == 0'),
          reason: 'the radar rings live on the closed disc only, same '
              'normal-state gate ("la animación que tenía antes")');
      expect(offline, contains('_GoRadarPainter('),
          reason: 'the radar painter is back on the disc');
      expect(offline, contains('Colors.white, BlendMode.srcIn'),
          reason: '"el carrito blanco" — the badge icon is white in its '
              'dark well');
      // 2026-10-17 (foto 2): SIN franja de pie — los botones van directos
      // sobre el sheet; el footer con fondo/hairline/sombra murió.
      expect(offline, isNot(contains('color: neuSurface.withValues(alpha: t)')),
          reason: 'no footer strip behind the GO pill + calendar row');
      expect(offline, contains('const goldTop1 = Color(0xFFC9981F)'),
          reason: 'ONE gold in every shape — the open pill wears the disc’s '
              'deep gold, no morph lerp');
      expect(offline.contains('goldBot = Color.lerp('), isFalse,
          reason: 'the gold morph lerp is dead');
      expect(offline, contains('S.of(context).zoneSelectAction'),
          reason: 'no zone picked → the label names the task');
      final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
      expect(l10n, contains('zoneSelectAction'));
      expect(l10n, contains('Selecciona zona'));
      expect(l10n, contains('Select zone'));
    });

    test('the offline sheet rests half-open with the pill GO, three snaps', () {
      // User spec 2026-10-13: "el sheet debe estar un poco más abierto y el
      // botón aparecerá abajo de forma píldora… si el driver desliza hacia
      // abajo, aparece el GO normal". Rest = half-open with the pill fully
      // formed at the sheet floor; swipe down = collapsed circle GO.
      expect(offline, contains('_kSheetRestFrac'),
          reason: 'the resting position constant');
      expect(offline, contains('_panelFrac / _kSheetRestFrac'),
          reason: 'the morph completes AT the resting position — a full '
              'pill, never a half-formed in-between');
      expect(widgets, contains('const snaps = [0.0, _kSheetRestFrac, 1.0];'),
          reason: 'collapsed / resting / open — three snap points');
      expect(
          screen,
          contains(
              'if (mounted && !_driverOnline) _animatePanelTo(_kSheetRestFrac);'),
          reason: 'the boot rests half-open when offline');
      final ctrl = File('lib/screens/driver/driver_online_controller.dart')
          .readAsStringSync();
      expect(ctrl, contains('_animatePanelTo(_kSheetRestFrac)'),
          reason: 'going offline rests the sheet half-open');
      expect(ctrl, contains('_animatePanelTo(0.0)'),
          reason: 'going online collapses it back to the searching pill');
      // The pill must paint ON TOP of the sheet (2026-10-13, "cuando el
      // sheet está abierto no aparece el botón de Go online"): painted
      // before it, the sheet covered the button at the floor.
      final goIdx = screen.indexOf('_buildMorphingGoButton(');
      final panelIdx = screen.indexOf('_floatingPanel(');
      expect(goIdx, isNonNegative);
      expect(panelIdx, isNonNegative);
      expect(goIdx, greaterThan(panelIdx),
          reason: 'the GO pill is the sheet footer — it must come AFTER the '
              'sheet in the Stack or the sheet covers it');
      // A real gesture releases follow; movement alone must not steal it back.
      expect(ctrl, isNot(contains('_motion.speedMps > 2.2')),
          reason: 'manual camera only resumes through an explicit recenter');
      // The sheet moves ONLY from its header strip (2026-10-13 spec: "el
      // sheet solamente se puede abrir o cerrar tocando o deslizando desde
      // donde dice You're offline/online").
      expect(widgets, contains('_kSheetHeaderStripH'),
          reason: 'the header strip height constant');
      expect(widgets, contains('_onSheetHeaderTap'),
          reason: 'the header tap toggle (resting ↔ open)');
      expect(screen, contains('_sheetDragStartDy'),
          reason: 'drags are gated on WHERE the finger started — the strip');
      expect(widgets, contains('onVerticalDragStart'),
          reason: 'the drag gate records the finger start position');
    });

    test('a failed flight never leaves the recenter dead', () {
      final body =
          bodyOf(map, 'Future<void> _recenterWithFollow(', maxLen: 5000);
      expect(body.contains('var issued = false'), isTrue);
      expect(body.contains('if (!landed &&'), isTrue,
          reason: 'a failed native flight gets one direct-write fallback');
      expect(body.contains('_cameraFollowing = true'), isTrue,
          reason: 'the per-frame chase remains the final safety net');
    });

    test('programmatic bearing writes never trip the manual-rotate unlatch',
        () {
      final flatten = widgets.indexOf('pitch: 0, bearing: _smoothedBearing');
      expect(flatten, isNonNegative,
          reason: 'the style-load flatten flyTo lives here');
      final around =
          widgets.substring(flatten - 800 > 0 ? flatten - 800 : 0, flatten);
      expect(around.contains('_camFlightUntil = DateTime.now()'), isTrue);
      expect(
          around.contains('_lastCamWriteBearing = _smoothedBearing'), isTrue);
      expect(map.contains('_cameraBearing = bearing;'), isTrue);
      expect(map.contains('.setCamera(options)'), isTrue);
      expect(map.contains('if (!landed &&'), isTrue);
      expect(
          map,
          contains(
              'if (!mounted || !_cameraActionGate.isCurrent(seq)) return;'),
          reason: 'a stale fallback cannot overwrite a newer camera action');
      expect(map, contains('guard.isLanding(_cameraActionGate, cameraPoint)'),
          reason: 'the handoff checks the actual camera, not a timer');
    });

    test('gesture listeners ignore phantom scrolls during programmatic flights',
        () {
      // Same user report (2026-10-12): taps landed=true yet the FAB never
      // left — during the recenter flyTo the plugin can emit scroll/zoom
      // callbacks with NO finger down (iOS), and each one unlatched follow
      // and cancelled the follow-resume: an infinite dead-FAB loop. The
      // gesture handler now ignores fingerless events inside flight windows
      // and the settle breadcrumb counts them (proof from prod).
      expect(screen.contains('int _mapPointers = 0;'), isTrue,
          reason: 'the map counts fingers — no finger, no gesture');
      expect(screen.contains('int _phantomGestureEvents = 0;'), isTrue);
      expect(widgets.contains('onPointerDown: (event) {'), isTrue,
          reason: 'the Listener wraps the MapWidget (nav-view pattern)');
      expect(
          widgets.contains(
              '_mapGestureGuard.pointerDown(event.position, _mapPointers)'),
          isTrue,
          reason: 'pointer-level drag/pinch releases follow before the chase');
      expect(widgets.contains('onPointerMove: (event) {'), isTrue,
          reason:
              'the map observes actual finger movement, not only callbacks');
      final handler = bodyOf(map, 'void _onCameraMoveStarted()', maxLen: 900);
      expect(handler.contains('_mapPointers == 0'), isTrue);
      expect(handler.contains('isBefore(_camFlightUntil)'), isTrue,
          reason: 'phantoms are only ignored during programmatic flights — '
              'a real finger mid-flight always wins');
      expect(map.contains('phantoms='), isTrue,
          reason: 'the settle breadcrumb carries the phantom count');
    });

    test('the GO button never paints disabled', () {
      final go = bodyOf(offline, 'Widget _buildGoButton(', maxLen: 2400);
      expect(go.contains('neuBox(radius: 16, pressed: true)'), isFalse,
          reason: 'no sunken grey well anymore — spec "siempre normal en '
              'amarillo"');
      // 2026-10-11 spec change: the ONLY dimmed GO is the deliberate
      // zone-selection state (zones flag on + offline + no pick) — never
      // an accidental disabled look.
      expect(offline.contains('dimmed ? Colors.white54 : Colors.white'), isTrue,
          reason: '2026-10-15 spec: WHITE lettering on gold — the lone '
              'exception is the deliberate zone-selection dim');
      expect(offline.contains('_selectedZoneName == null'), isTrue);
    });

    test('the go-offline disc is red with the GO radar waves, both doors', () {
      expect(offline.contains('Widget _offlineRadarDisc('), isTrue);
      expect(offline.contains('Color(0xFFE05555)'), isTrue, reason: 'red body');
      expect(offline.contains('_GoRadarPainter('), isTrue,
          reason: 'same waves as GO');
      expect('Icons.pan_tool_rounded'.allMatches(widgets).length, 0,
          reason: 'the old hand icon died');
      expect('_offlineRadarDisc()'.allMatches(widgets).length,
          greaterThanOrEqualTo(2),
          reason: 'the panel AND the sheet share the disc (sibling paths)');
    });

    test(
        'GO connects on the FIRST tap even before the flag lands '
        '(2026-10-16-noche)', () {
      // User report: "al boton de go online hay que darle dos veces para que
      // se conecte" — tap 1 ran _ensureVerified() (flips the flag) and NEVER
      // continued to the flip; only tap 2 connected. Now verification
      // chains INTO _onGoTap in the same tap.
      expect(offline, contains('if (await _ensureVerified()) _onGoTap();'),
          reason: 'a not-yet-verified tap verifies and CONNECTS, same tap');
    });

    test('ONE recenter FAB everywhere, blur-in/pop-out (photo style)', () {
      // User spec 2026-10-11: every recenter button is the photo's dark disc
      // with the white nav arrow, appearing with blur-in and leaving with
      // pop-out whenever the camera unlatches follow (finger drag/zoom or
      // any programmatic move).
      expect(widgets.contains('class _RecenterFab extends StatefulWidget'),
          isTrue);
      expect(widgets.contains('Icons.navigation_rounded'), isTrue);
      final body = bodyOf(widgets, 'class _RecenterFabState', maxLen: 1800);
      expect(body.contains('ImageFilter.blur('), isTrue, reason: 'blur-in');
      expect(body.contains('_ctrl.reverse()'), isTrue, reason: 'pop-out');
      // All three sites use it: offline FAB, searching cluster, nav phases.
      expect('_RecenterFab('.allMatches(screen).length, greaterThanOrEqualTo(3),
          reason: 'offline + searching + nav share the one FAB');
      expect(screen.contains('const Color(0xFF4285F4)'), isFalse,
          reason: 'the blue nav recenter died — one photo-style FAB');
    });
  });
}
