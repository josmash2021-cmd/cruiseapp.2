import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the nav-view arrow + camera audit fixes (2026-10-28,
/// findings D1-D10 approved by the owner).
///
/// Pure source-grep, same style as driver_nav_guard_test.dart: the feature
/// needs GPS and a native map, so what a unit test CAN pin is that the
/// load-bearing pieces stay where they belong:
///   1. D1 — every annotation pigeon call is bounded (1500 ms) and the
///      write latch is released on revoke, so a dead PlatformView can never
///      keep the arrow off the map for the life of the view.
///   2. D2 — a 2 s watchdog rebuilds a missing bitmap and recreates the
///      native arrow while the car is parked (the ticker only fires on
///      movement).
///   3. D7 — while the chase follows, the arrow is the Flutter vector
///      overlay at the camera focus; the native annotation is never written
///      in that state.
///   4. D6 — the chase pose is zoom 16.8 / pitch 45 (owner request
///      2026-11-02; was 17.5 / 55).
///   5. D8/D9 — SmoothMotion's per-tick cap is 3 m and the correction floor
///      is max(6, 1.5×speed), capped at 45.
///   6. D4/D5/D10 + extras — recenter is a blend (no flyTo race), overview
///      only flips with a route and a map, stationary aims at the real
///      target, chase dt comes from the ticker.
void main() {
  final nav = File('lib/screens/driver/driver_nav_view.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final motion = File('lib/utils/smooth_motion.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final dot = File('lib/widgets/gold_location_dot.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  String bodyOf(String src, String signature, {int maxLen = 2000}) {
    final start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    return src.substring(start, start + maxLen);
  }

  group('D1: bounded annotation IPC + latch release on revoke', () {
    test('the annotation timeout is 1500 ms and wraps create AND update', () {
      expect(
          nav.contains(
              'static const _annotIpcTimeout = Duration(milliseconds: 1500);'),
          isTrue,
          reason: 'a PlatformView torn down mid-call never answers — an '
              'unbounded await left _annotWriteBusy true forever');
      final body = bodyOf(nav, 'Future<void> _updateDriverAnnotation() async {',
          maxLen: 5200);
      expect(body.contains('.timeout(_annotIpcTimeout)'), isTrue);
      expect(body.contains('await mgr.update(_driverAnnot!).timeout('), isTrue,
          reason: 'the update path is bounded too, not only the create');
      expect(body.contains('await mgr.deleteAll().timeout('), isTrue,
          reason: 'house rule: deleteAll before create on the arrow manager');
      expect(body.contains("debugPrint('[Nav] arrow create/update failed: \$e')"),
          isTrue,
          reason: 'D3: a failed create/update must leave a trace');
      expect(body.contains('_annotWriteBusy = false;'), isTrue);
    });

    test('onRevoke releases the write latch with the handles', () {
      final revoke = bodyOf(nav, 'onRevoke: () async {', maxLen: 1800);
      expect(revoke.contains('_annotWriteBusy = false;'), isTrue,
          reason: 'the in-flight write died with the channel — a latch left '
              'true kept every later tick out of _updateDriverAnnotation');
      expect(revoke.contains('_driverAnnot = null;'), isTrue);
      expect(revoke.contains('_arrowWatchdog?.cancel();'), isTrue);
    });
  });

  group('D2: arrow watchdog', () {
    test('a 2 s watchdog rebuilds the bitmap and recreates the native arrow',
        () {
      final wd = bodyOf(nav, 'void _startArrowWatchdog() {', maxLen: 1300);
      expect(wd.contains('Timer.periodic(const Duration(seconds: 2)'), isTrue);
      expect(wd.contains('if (!_dot.isReady)'), isTrue,
          reason: 'a failed raster leaves currentBytes null forever unless '
              'build() runs again — nothing else calls it');
      expect(wd.contains('_dot.build(this, _onDotTick, onFrame: _onDotFrame)'),
          isTrue);
      expect(wd.contains('if (_driverAnnot == null)'), isTrue);
      expect(wd.contains('if (_arrowOverlayMode) return;'), isTrue,
          reason: 'while following the overlay owns the arrow — no native '
              'create from the watchdog');
    });

    test('the watchdog starts with the map and dies with it', () {
      final created = bodyOf(nav, 'Future<void> _onMapCreated', maxLen: 3200);
      expect(created.contains('_startArrowWatchdog();'), isTrue);
      final dispose = bodyOf(nav, 'void dispose() {', maxLen: 900);
      expect(dispose.contains('_arrowWatchdog?.cancel();'), isTrue);
      expect(dispose.contains('_camFlightTimer?.cancel();'), isTrue);
    });
  });

  group('D7: overlay arrow while following', () {
    test('overlay mode = following, not overview, map mounted, native only',
        () {
      final mode = bodyOf(nav, 'bool get _arrowOverlayMode =>', maxLen: 200);
      expect(mode.contains('!kIsWeb'), isTrue);
      expect(mode.contains('_mapMounted'), isTrue);
      expect(mode.contains('_camState == _CamState.following'), isTrue);
      expect(mode.contains('!_overview'), isTrue);
    });

    test('the native annotation is never written in overlay mode', () {
      final body = bodyOf(nav, 'Future<void> _updateDriverAnnotation() async {',
          maxLen: 500);
      expect(body.contains('if (_arrowOverlayMode) {'), isTrue,
          reason: 'the overlay IS the arrow while following — a native '
              'write there is channel traffic plus a two-channel jitter');
      expect(body.contains('_deleteNativeArrow();'), isTrue);
    });

    test('the overlay is drawn at the camera focus, heading-up', () {
      expect(nav.contains('if (_arrowOverlayVisible)'), isTrue);
      final build = bodyOf(nav, 'if (_arrowOverlayVisible)', maxLen: 2200);
      // 2026-10-30: the camera follows the arrow's bearing on a damped
      // spring; the overlay shows the not-yet-turned difference (0 when the
      // map has caught up — heading-up at rest).
      expect(build.contains('valueListenable: _arrowScreenBearing,'), isTrue);
      expect(build.contains('bearing: rel,'), isTrue,
          reason: 'the arrow rotates by what the camera has not turned yet');
      expect(build.contains('c.maxHeight / 2 + topPad / 2'), isTrue,
          reason: 'same focal point the chase camera writes (top padding '
              'pushes the car below centre)');
      expect(build.contains('+ 240'), isTrue);
    });

    test('leaving follow drops the overlay at once; the handle is nulled '
        'before the delete', () {
      final sync = bodyOf(nav, 'void _syncArrowOwner() {', maxLen: 1200);
      expect(sync.contains('_arrowHandoffPending = true;'), isFalse,
          reason: 'an overlay pinned to the screen centre would slide across '
              'the map as a second arrow while the camera moves away');
      expect(sync.contains('_arrowHandoffPending = false;'), isTrue);
      final fly = bodyOf(nav, 'Future<void> _flyToChasePose(int durationMs) async {',
          maxLen: 1600);
      expect(fly.contains('map.flyTo('), isFalse,
          reason: 'a native flyTo while following races the per-frame '
              'setCamera and the camera jumps');
      final del = bodyOf(nav, 'void _deleteNativeArrow() {', maxLen: 600);
      final nullIdx = del.indexOf('_driverAnnot = null;');
      final delIdx = del.indexOf('mgr.delete(annot)');
      expect(nullIdx, isNonNegative);
      expect(delIdx, greaterThan(nullIdx),
          reason: 'house rule: null the handle BEFORE the fire-and-forget '
              'delete');
    });
  });

  group('D4/D5: camera buttons', () {
    // Owner 2026-11-05 ("se mueve como relentizado… que se vea fluido y
    // smooth"), then option "B" of WdhPHWnrG7n6B8PtP64fkt: both ways are ONE
    // eased native animation through the map's viewport — zoom out, flatten
    // and turn north together, easeInOutCubic, 1.3 s. The per-frame blend
    // from Dart stuttered; a plain easeTo is ease-out only on iOS. The chase
    // stays out until the viewport reports the landing (audit D4).
    test('recenter is option B; the chase waits for the landing', () {
      final body = bodyOf(nav, 'Future<void> _recenter() async {', maxLen: 3200);
      expect(body.contains('_flyViewport('), isTrue);
      expect(body.contains('onLanded: land,'), isTrue);
      expect(body, isNot(contains('.getCameraState()')),
          reason: 'that read (up to 0.8 s) held every recenter back');
      expect(body.contains('_camState = _CamState.recentering;'), isTrue,
          reason: 'the per-frame chase writes nothing while recentering — '
              'nothing cuts the animation');
      expect(body.contains('!_cameraActionGate.isCurrent(seq)'), isTrue,
          reason: 'a gesture supersedes the sequence and the landing yields');
      expect(body.contains('Timer(const Duration(milliseconds: _camFlightMs + 500), land)'),
          isTrue, reason: 'no report from the viewport still lands it');
      expect(body.contains('_recenterAim('), isTrue,
          reason: 'a moving car is met where it will be at the landing');
      expect(nav.contains('static const _camFlightMs = 1300;'), isTrue);
      expect(nav.contains('curve: Curves.easeInOutCubic,'), isTrue);
      expect(nav.contains('mapbox.EasingViewportTransition('), isTrue);
      expect(nav, isNot(contains('_onRecenterTick')));
    });

    test('after a flight the viewport is idle: the chase owns the camera', () {
      final fly = bodyOf(nav, 'void _flyViewport(', maxLen: 700);
      expect(fly.contains('setStateWithViewportAnimation('), isTrue);
      expect(fly.contains('transition: _camFlight,'), isTrue);
      expect(fly.contains('_viewport = const mapbox.IdleViewportState()'), isTrue);
      expect(fly.contains('if (landed) onLanded?.call();'), isTrue);
      expect(nav.contains('viewport: _viewport,'), isTrue);
      expect(nav.contains('_viewport = null;'), isTrue,
          reason: 'a new map surface never opens on a half-flown camera');
    });

    test('overview only flips state with a route and a map', () {
      final body = bodyOf(nav, 'void _toggleOverview() {', maxLen: 1100);
      expect(body.contains('_routePts.length < 2'), isTrue);
      expect(body.contains('_map == null'), isTrue);
      expect(body.contains('unawaited(_recenter());'), isTrue);
    });

    test('INTO the overview: option B, the same as the way back', () {
      final body = bodyOf(nav, 'void _toggleOverview() {', maxLen: 1300);
      expect(body.contains('unawaited(_glideToOverview());'), isTrue);
      expect(body, isNot(contains('unawaited(_fitRouteOnce());')));
      final glide =
          bodyOf(nav, 'Future<void> _glideToOverview() async {', maxLen: 1800);
      expect(glide.contains('FlatMapProjection.fitFlat('), isTrue);
      expect(glide.contains('_flyViewport(mapbox.CameraViewportState('), isTrue);
      expect(glide.contains('padding: EdgeInsets.zero,'), isTrue);
      expect(glide.contains('_pendingCamWrite = null;'), isTrue,
          reason: 'a queued chase write landing after take-off would cut '
              'the animation');
      expect(nav, isNot(contains('_onOverviewTick')));
    });

    test('the remaining nav flights are 600 ms', () {
      expect(nav.contains('_flyToChasePose(600)'), isTrue);
      expect(nav, isNot(contains('_flyToChasePose(650)')));
      expect(nav, isNot(contains('duration: 1200')));
    });
  });

  group('D6: chase pose', () {
    test('zoom 16.8 / pitch 45 (owner request 2026-11-02)', () {
      expect(nav.contains('_chaseZoomDefault = 16.8'), isTrue);
      expect(nav.contains('_chasePitch = 45.0'), isTrue);
      expect(nav.contains('double _chaseZoom = 16.8;'), isTrue);
    });

    test('the nav opens with the arrow ON the line (owner report '
        '2026-11-02)', () {
      // The opening camera shares the chase inset (+240, the overlay
      // arrow's focus) and centres on the projected seed, never the raw fix.
      final build = nav.substring(nav.indexOf('cameraOptions: mapbox.CameraOptions('));
      final cam = build.substring(0, build.indexOf('onMapCreated:'));
      expect(cam.contains('_openCameraPos.latitude'), isTrue);
      expect(cam.contains('media.padding.top + 240'), isTrue);
      expect(cam, isNot(contains('+ 130')));
      // A dot that gets its position with the chase asleep (seed, first
      // fix, parked nudge) still re-aims the camera.
      final tick = bodyOf(nav, 'void _onDotTick() {', maxLen: 1600);
      expect(tick.contains('_snapToChasePose()'), isTrue);
      final gps = bodyOf(nav, 'void _startGps() {', maxLen: 3000);
      expect(gps.contains('_snapToChasePose()'), isTrue);
    });
  });

  group('D8/D9/D10: SmoothMotion constants', () {
    test('the per-tick cap is 3 m, not 1 m', () {
      expect(motion.contains('math.min(maxMps * dtSec, 3.0)'), isTrue,
          reason: 'a 1 m cap was a frame-rate-dependent speed limit (30 m/s '
              'at 30 fps) — the marker fell behind on the highway');
      expect(motion, isNot(contains('math.min(maxMps * dtSec, 1.0)')));
    });

    test('the correction floor is max(6, 1.5×speed), capped at 45', () {
      expect(motion.contains('math.min(45.0, math.max(6.0, speedMps * 1.5))'),
          isTrue);
      expect(motion, isNot(contains('clamp(30.0, 45.0)')),
          reason: 'a 30 m/s floor corrected any residual in under a second '
              'at a crawl — the short teleport the driver saw');
      expect(motion.contains('_posSpringOmega = 6.0'), isTrue);
      expect(motion.contains('_brgSpringOmega = 10.0'), isTrue,
          reason: 'the bearing spring is untouched — a turn must land');
    });

    test('stationary aims at the last real target, no lead, no stored lag',
        () {
      expect(motion.contains('if (_stationary) return (_targetLat!, _targetLng!);'),
          isTrue,
          reason: 'aiming at its own position froze the marker up to a lead '
              'behind the fix and paid it as a jump on restart');
    });
  });

  group('extras: ticker dt, not wall clock', () {
    test('GoldLocationDot caps its step at 50 ms and exposes it', () {
      expect(dot.contains('static const double maxTickDtSec = 0.05;'), isTrue);
      expect(dot.contains('lastFrameDtSec = dtSec;'), isTrue);
    });

    test('the chase zoom glide paces on the ticker dt', () {
      // The dot's frames feed the chase with the TICKER dt; the settle
      // ticker passes its own ticker dt. Wall clock only marks "a dot frame
      // just ran", never paces the glide.
      expect(nav.contains('void _onDotFrame() => _chaseFrame(_dot.lastFrameDtSec);'),
          isTrue);
      final frame = bodyOf(nav, 'void _chaseFrame(double dt) {', maxLen: 2400);
      expect(frame.contains('final maxStep = _zoomLerpPerSec * dt;'), isTrue);
    });
  });
}
