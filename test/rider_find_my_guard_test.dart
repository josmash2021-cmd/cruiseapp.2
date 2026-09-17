import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the rider Find-My pickup redesign (approved mockup
/// docs/mockups/find_my_pickup_mockup.html, spec 2026-09-12):
///
///   1. The 4-digit pickup PIN is read from `pickup_pin` on the Firestore
///      trip doc the screen already subscribes to, and the PIN block only
///      renders while the field is present.
///   2. FOUND is pure, reversible UI (user spec 2026-09-16): the proximity
///      radius adapts to each fix's GPS accuracy (2 m … 30 m cap), two
///      consecutive fixes inside flip to FOUND, two outside (radius + 5 m
///      buffer) flip back to FINDING. It writes NOTHING — the driver's PIN
///      entry is the only thing that unlocks Start Ride — and it NEVER
///      calls widget.onConfirmed: the screen closes only when the driver
///      starts the trip (green overlay + fade) or on cancel/wait-timeout.
///   3. No press-to-confirm remnant: `_onConfirmPressed` and the
///      `rideAutoStartWarning` line are gone.
///   4. The bottom row adds Support (headset) opening
///      CruiseSupportChatScreen, next to the existing Chat/Call.
///   5. The live mini map mounts through MapSurfaceCoordinator as owner
///      'RiderFindMyPickup' with a StaticRoutePreview stand-in, and the
///      tracking screen re-claims the surface when the overlay closes.
///   6. The rider dot IS the phone's exact fix (no smoother trailing a
///      walking rider); only the relayed car glides through SmoothMotion.
///   7. No route line on the mini map (gold dot + car only); the driving
///      route fetch exists only to snap the car onto the road, and the
///      dot/car annotations are created even when nothing moves (parked at
///      pickup).
///   8. Distance + bearing recompute on the map ticker, not only on rider
///      GPS fixes; the hero ring runs at 300 with its geometry at 44% of
///      the canvas; the vehicle color shows as a dot with the full name
///      wrapping to 2 lines.
///
/// The map needs a live Mapbox surface, so this pins the source discipline.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final src =
      File('lib/screens/rider_confirm_pickup_screen.dart').readAsStringSync();

  /// Extracts the body of [signature] up to the next `///`-doc'd method or
  /// [maxLen] chars, whichever comes first.
  String bodyOf(String signature, {int maxLen = 4000}) {
    final start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    final end = src.indexOf(RegExp(r'\n  ///'), start + signature.length);
    return src.substring(
        start, end > start ? end : start + signature.length + maxLen);
  }

  group('pickup PIN rides the existing trip-doc subscription', () {
    test('pickup_pin is read inside the trip-doc listener', () {
      final body = bodyOf('void _listenForTripStart() {');
      expect(body.contains("data['pickup_pin']"), isTrue,
          reason: 'the PIN comes from the pickup_pin field of trips/sql_<id>');
      expect(body.contains('_pickupPin = pin'), isTrue);
    });
    test('the PIN block only renders when the field is present', () {
      expect(src.contains('if (_pickupPin != null) ...['), isTrue,
          reason: 'no pickup_pin on the doc → the whole PIN block hides');
      expect(src.contains('S.of(context).pickupCodeTitle'), isTrue);
      expect(src.contains('S.of(context).pickupCodeTellDriver'), isTrue);
    });
  });

  group('proximity FOUND is pure, reversible UI (user spec 2026-09-16)', () {
    test('the radius adapts to GPS accuracy: 2 m base, 30 m cap', () {
      expect(src.contains('static const double _kDetectMeters = 2.0;'),
          isTrue,
          reason: 'spec: with a fine fix the bar stays "at the car" (2 m)');
      expect(src.contains('static const double _kDetectMaxMeters = 30.0;'),
          isTrue,
          reason: 'spec: never accept a fix beyond 30 m, however bad the GPS');
      final body = bodyOf('void _startProximityWatch() {');
      expect(body.contains('pos.accuracy'), isTrue,
          reason: 'GPS cannot resolve 2 m on a bad-signal day — the fix\'s '
              'own accuracy raises the bar or FOUND would never fire');
    });
    test('the latch writes NO remote flag and never calls onConfirmed', () {
      final body = bodyOf('void _latchFound() {');
      expect(body.contains('_writeRiderConfirmed'), isFalse,
          reason: 'the PIN is the only Start Ride unlock — proximity must '
              'not write the flag');
      expect(body.contains('onConfirmed'), isFalse,
          reason: 'FOUND must never close the screen by itself — only the '
              'driver starting the trip (or a cancel) closes it');
      expect(src.contains('_writeRiderConfirmed'), isFalse,
          reason: 'the proximity Firestore write is gone for good');
      expect(src.contains('rider_confirmed_pickup'), isFalse,
          reason: 'only the backend PIN-confirm writes that flag now');
    });
    test('FOUND is reversible with hysteresis: away → FINDING, back → FOUND',
        () {
      expect(src.contains('void _unlatchFound()'), isTrue,
          reason: 'walking away from the car must drop back to FINDING');
      expect(src.contains('_kExitBufferMeters'), isTrue,
          reason: 'exit needs radius + buffer so boundary jitter never flaps');
      final body = bodyOf('void _startProximityWatch() {');
      expect(body.contains('_unlatchFound()'), isTrue);
    });
    test('no press-to-confirm path remains', () {
      expect(src.contains('_onConfirmPressed'), isFalse,
          reason: 'the confirm press is gone — proximity flips FOUND and '
              'the driver starting the trip closes the page');
      expect(src.contains('rideAutoStartWarning'), isFalse,
          reason: 'spec: the auto-start warning line is removed');
    });
    test('widget.onConfirmed is invoked from exactly one place: driver start',
        () {
      final calls = RegExp(r'widget\.onConfirmed\(\)').allMatches(src).length;
      expect(calls, 1,
          reason: 'proximity must never call onConfirmed');
      final body = bodyOf('Future<void> _onDriverStartedTrip() async {');
      expect(body.contains('widget.onConfirmed()'), isTrue);
      expect(body.contains('_fadeOutCtrl.forward()'), isTrue,
          reason: 'the existing fade-out still follows the green beat');
    });
    test('driver start shows the green overlay with driverConfirmedStarting',
        () {
      expect(src.contains('S.of(context).driverConfirmedStarting'), isTrue);
      expect(src.contains('_buildDepartOverlay()'), isTrue);
    });
  });

  group('FOUND state is green end to end', () {
    test('state pill uses the found key and green', () {
      final body = bodyOf('Widget _buildStatePill(bool isFound) {');
      expect(body.contains('S.of(context).found'), isTrue);
      expect(body.contains('_green'), isTrue);
    });
    test('ring and glow transition gold→green', () {
      expect(src.contains('ColorTween(end: isFound ? _green : Colors.white)'),
          isTrue,
          reason: 'the particle ring fades white→green in FOUND');
      expect(src.contains('_HeroGlowPainter('), isTrue,
          reason: 'the hero glow chases the arrow and goes green in FOUND');
    });

    test('the FOUND check is a big FILLED disc, not a tiny outline '
        '(user spec 2026-09-17)', () {
      expect(src.contains('Icons.check_circle_rounded'), isTrue);
      expect(src.contains('size: 240'), isTrue,
          reason: 'the 156 outline read as "diminuto" — the check must be '
              'visible across the car');
      expect(src.contains('Icons.check_circle_outline_rounded'), isFalse);
      final dist = bodyOf('Widget _buildDistanceLine()');
      expect(dist.contains('duration: const Duration(milliseconds: 300)'),
          isTrue,
          reason: 'the ft readout trails reality at 600 ms — 300 keeps it '
              'on the live phone fixes');
    });

    test('boot camera events cannot park the strip on the (0,0) ocean', () {
      expect(src.contains('_bootFitted'), isTrue,
          reason: 'scroll/zoom events before the first real fit are the map '
              'initializing — latching _userTookCamera off them blocked '
              'every refit and the mini map showed blank navy forever '
              '(user report 2026-09-17)');
      expect(src.contains('if (_bootFitted) _userTookCamera = true;'),
          isTrue);
    });
  });

  group('bottom action row adds Support', () {
    test('headset button opens the support chat like other screens', () {
      expect(src.contains('Icons.support_agent_rounded'), isTrue);
      expect(src.contains('S.of(context).supportAction'), isTrue);
      final body = bodyOf('void _openSupport() {');
      expect(body.contains('CruiseSupportChatScreen('), isTrue);
      expect(body.contains('slideFromRightRoute('), isTrue,
          reason: 'same navigation the trip screen and inbox use');
    });
    test('chat and call stay', () {
      expect(src.contains('ChatScreen('), isTrue);
      // Call is a DIRECT dial to the driver's number now (user spec
      // 2026-09-13) — the masked Twilio callback must not come back.
      expect(src.contains("Uri.parse('tel:\$phone')"), isTrue);
      expect(src.contains('MaskedCallService'), isFalse,
          reason: 'rider-side calls dial the driver directly, no bridge');
    });
  });

  group('mini map honors the one-surface rule', () {
    test('acquires/releases through the coordinator with its own owner', () {
      expect(
          src.contains(
              "static const String _mapSurfaceOwner = 'RiderFindMyPickup';"),
          isTrue);
      expect(src.contains('MapSurfaceCoordinator.instance.acquire('), isTrue);
      expect(src.contains('surfaceRemoved()'), isTrue,
          reason: 'a revoke is honest only after the MapWidget left the tree');
      expect(
          src.contains('MapSurfaceCoordinator.instance.release(_mapSurfaceOwner)'),
          isTrue,
          reason: 'dispose must give the surface back to the tracking map');
    });
    test('StaticRoutePreview stands in until the surface is granted', () {
      expect(src.contains('_buildMiniMapStandIn'), isTrue);
      expect(src.contains('StaticRoutePreview('), isTrue);
    });
    test('the live map is top-down dark style, interactive pan/zoom (user spec 2026-09-15)', () {
      expect(src.contains('styleUri: MapboxConfig.styleDark'), isTrue);
      expect(src.contains('pitch: 0.0'), isTrue);
      final body = bodyOf('Future<void> _onMiniMapCreated(mapbox.MapboxMap ctrl) async {');
      expect(body.contains('scrollEnabled: true'), isTrue,
          reason: 'spec: the strip pans');
      expect(body.contains('pinchToZoomEnabled: true'), isTrue,
          reason: 'spec: the strip zooms');
      expect(body.contains('doubleTapToZoomInEnabled: true'), isTrue);
      expect(body.contains('quickZoomEnabled: true'), isTrue);
      expect(body.contains('rotateEnabled: false'), isTrue,
          reason: 'still top-down, north-up');
      expect(body.contains('pitchEnabled: false'), isTrue);
    });
    test('a user pan/zoom latches the camera so auto-fit never fights it', () {
      expect(src.contains('if (_bootFitted) _userTookCamera = true;'),
          isTrue,
          reason: 'the latch is gated on the first real fit — boot-time '
              'camera events are the map initializing, not the rider '
              '(2026-09-17)');
      final body = bodyOf('void _maybeRefitMiniMap({bool force = false}) {');
      expect(body.contains('_userTookCamera'), isTrue,
          reason: 'once the rider takes the camera the periodic refit must '
              'stop dragging it back');
    });
    test('the rider dot is the exact phone fix, only the car is smoothed',
        () {
      expect(src.contains('final _driverMotion = SmoothMotion();'), isTrue);
      expect(src.contains('LatLng? _riderRaw;'), isTrue,
          reason: 'user spec 2026-09-17: the rider dot is the phone\'s own '
              'exact fix — a smoother trailed a metre behind a walking rider');
      expect(src.contains('_riderMotion'), isFalse,
          reason: 'the rider side of the motor is gone from this screen');
      expect(src.contains('spd >= 0.6'), isTrue,
          reason: 'parked wander is held; the first walking step lands');
    });
    test('car marker is the tier PNG, ONLY the edges feather into the background', () {
      expect(src.contains('assets/images/car_suv.png'), isTrue);
      expect(src.contains('assets/images/car_sedan.png'), isTrue);
      final body = bodyOf('Widget _buildMiniMap() {', maxLen: 6000);
      expect(body.contains('IgnorePointer'), isTrue,
          reason: 'the feather gradients never intercept touches');
      expect(body.contains('LinearGradient'), isTrue,
          reason: 'the four borders fade into neuBase');
      expect(body.contains('RadialGradient'), isFalse,
          reason: 'user spec 2026-09-15: only the border feathers — the '
              'radial veil washed the whole map out and hid the car');
    });
    test('never on web (mapbox_maps_flutter does not run there)', () {
      expect(src.contains('if (!kIsWeb) {'), isTrue,
          reason: 'the surface acquire must stay behind the kIsWeb guard');
    });
  });

  group('snap route + live mini-map markers (refinements)', () {
    final directions =
        File('lib/services/directions_service.dart').readAsStringSync();

    test('getRoute takes an optional profile defaulting to driving', () {
      expect(directions.contains("String profile = 'driving'"), isTrue,
          reason: 'every existing caller keeps driving by default');
      expect(
          directions.contains('_cacheKey(origin, destination, profile)'),
          isTrue,
          reason: 'a walking route must never hit the driving cache');
      expect(directions.contains('directions/v5/mapbox/\$mbxProfile/'), isTrue);
      expect(
          directions
              .contains("profile == 'driving' ? 'driving-traffic' : profile"),
          isTrue,
          reason: 'user spec 2026-09-17: driving routes must carry '
              'traffic-aware durations — free-flow ETAs lie in real traffic');
    });
    test('no provider ever fabricates a straight origin→destination route',
        () {
      expect(directions.contains('return [origin, destination];'), isFalse,
          reason: 'user report 2026-09-17: an empty parse was "rescued" as '
              'a 2-point beeline that every screen drew as the REAL route');
      expect(directions.contains('mapbox.points.isEmpty'), isTrue,
          reason: 'an empty-geometry answer fails the provider instead of '
              'winning over a real route from the next one');
    });
    test('the snap route fetches driving and is NEVER drawn', () {
      expect(src.contains("profile: 'driving'"), isTrue,
          reason: 'user spec 2026-09-17: the route exists only to snap the '
              'car onto the road — driving geometry, not walking');
      expect(src.contains('_snapToRoad('), isTrue);
      expect(src.contains('RouteSplice.closestSegmentIndex(pts, p)'), isTrue);
      expect(src.contains('_drawWalkRoute'), isFalse,
          reason: 'no route line on this mini map — dot and car only');
      expect(src.contains('_walkAnnot'), isFalse);
      expect(src.contains('if (rMoved < 10 && dMoved < 10) return;'), isTrue,
          reason: 'refetch threshold stays at 10 m');
    });
    test('the rider dot is gold, never blue', () {
      expect(src.contains('_riderBlue'), isFalse,
          reason: 'user spec 2026-09-17: gold dot, blue is gone');
      expect(src.contains('circleColor: _gold.toARGB32(),'), isTrue);
      expect(
          src.contains('circleColor: _gold.withValues(alpha: 0.22).toARGB32(),'),
          isTrue,
          reason: 'the halo follows in the same gold at 0.22');
    });
    test('distance and bearing read the PHONE, not the snapped marker', () {
      final body = bodyOf('void _refreshDistanceBearing() {');
      expect(body.contains('_lastDriverPos?.latitude ?? _driverMotion.lat'),
          isTrue,
          reason: 'user spec 2026-09-17: "N ft" and the arrow measure to the '
              'driver\'s raw phone fix — never the snapped display point, '
              'never a marked-arrival spot');
    });
    test('markers are created even when nothing moves (parked at pickup)',
        () {
      final body = bodyOf('void _onMapTick(Duration elapsed) {');
      expect(body.contains('_riderDotAnnot == null'), isTrue);
      expect(body.contains('_carAnnot == null'), isTrue,
          reason: 'tick() reports false for two stationary targets — '
              'creation cannot wait for movement');
    });
  });

  group('bigger hero ring and needle', () {
    test('the ring constraint is 300', () {
      expect(src.contains('maxWidth: 300, maxHeight: 300'), isTrue);
    });

    test('the ring geometry uses 44% of the canvas', () {
      expect(src.contains('size.width * 0.44'), isTrue);
    });

    test('the needle is much bigger (user spec 2026-09-17)', () {
      expect(src.contains('size: 280'), isTrue,
          reason: 'the arrow grew 220 → 260 → 280 (~88% of the ring)');
    });
  });

  group('distance and bearing stay live on the map ticker', () {
    test('the tick recomputes both from the smoothed positions', () {
      final body = bodyOf('void _onMapTick(Duration elapsed) {');
      expect(body.contains('_refreshDistanceBearing()'), isTrue,
          reason: 'the GPS listener alone froze "N ft" when the rider\'s '
              'stream went quiet');
      final refresh = bodyOf('void _refreshDistanceBearing() {');
      expect(refresh.contains('_riderRaw?.latitude'), isTrue,
          reason: 'phone-to-phone: the rider side is the exact own fix');
      expect(refresh.contains('_driverMotion.lat'), isTrue,
          reason: 'the smoothed car position stays as the bootstrap '
              'fallback only');
    });

    test('the GPS handler also prefers the raw phone fix (single source)',
        () {
      expect(src.contains('final driver = _lastDriverPos ?? widget.driverPosOf!();'),
          isTrue,
          reason: 'user spec 2026-09-17: without this, the GPS handler wrote '
              'the smoothed pull position while the ticker wrote the raw fix '
              '— two sources tugging "N ft" back and forth');
      final handler = bodyOf(
          '_riderGpsSub = Geolocator.getPositionStream(', maxLen: 1800);
      expect(handler.contains('spd >= 0.6'), isTrue,
          reason: 'the rider dot IS the exact fix: held only while the fix '
              'reports ~no speed (parked wander), written the instant the '
              'rider walks — precision without lag');
      expect(handler.contains('_riderRaw = LatLng(pos.latitude, pos.longitude)'),
          isTrue);
    });
  });

  group('vehicle color becomes a dot', () {
    test('the leading color word is parsed off the description', () {
      expect(src.contains('_parseVehicleColor('), isTrue);
      expect(src.contains("'dark blue'"), isTrue);
      final body = bodyOf('Widget _buildSpecRow() {');
      expect(body.contains('_parseVehicleColor'), isTrue);
      expect(body.contains('maxLines: 2'), isTrue,
          reason: 'the full vehicle name wraps instead of ellipsizing');
    });
  });

  group('tracking screen side of the handoff', () {
    final tracking =
        File('lib/screens/rider_tracking_screen.dart').readAsStringSync();
    final controller =
        File('lib/controllers/rider_tracking_controller.dart').readAsStringSync();

    test('revoke nulls the controller so the guards stop map writes', () {
      final start = tracking.indexOf('Future<void> _acquireMapSurface() async {');
      expect(start, isNonNegative);
      final end = tracking.indexOf('await surfaceRemoved();', start);
      expect(end, greaterThan(start));
      final body = tracking.substring(start, end);
      expect(body.contains('onRevoke:'), isTrue);
      expect(body.contains('_map = null;'), isTrue,
          reason: 'nulling _map is what makes every `_map == null` guard '
              'across the screen effective while the overlay owns the surface');
    });
    test('both overlay-close paths re-claim the surface', () {
      // onConfirmed closure in the screen.
      final onConfirmed = tracking.indexOf('onConfirmed: () async {');
      expect(onConfirmed, isNonNegative);
      final closure = tracking.substring(
          onConfirmed, tracking.indexOf('_restartRouteAnimation();', onConfirmed));
      expect(closure.contains('unawaited(_acquireMapSurface());'), isTrue,
          reason: 'the tracking map must remount when the Find-My overlay '
              'leaves via the driver-started fade-out');
      // The controller's externalStartPulse close path (both branches).
      final pulse = controller
          .indexOf('RiderConfirmPickupScreen.externalStartPulse.value++;');
      expect(pulse, isNonNegative);
      final closeBlock = controller.substring(
          pulse, pulse + 1400);
      final reacquires = RegExp(r'unawaited\(_acquireMapSurface\(\)\);')
          .allMatches(closeBlock)
          .length;
      expect(reacquires, greaterThanOrEqualTo(2),
          reason: 'reverse().then and the immediate-hide branch both close '
              'the overlay — each must hand the surface back');
    });
  });

  group('the mini-map car feeds on the direct socket relay (2026-09-14)', () {
    test('the relay stream feeds the car, not only the 1 Hz sample', () {
      expect(src.contains('SocketService.driverLocationStream.listen'), isTrue,
          reason: 'the Find-My must hear every relay packet at the '
              'driver cadence, not a 1 Hz pull');
      expect(src.contains('_startDriverRelayWatch()'), isTrue);
      expect(src.contains("_driverLocSub?.cancel()"), isTrue,
          reason: 'the relay subscription must be disposed with the screen');
    });

    test('one dedup discipline covers both feeds', () {
      expect(src.contains('void _acceptDriverFix('), isTrue);
      final fn = src.indexOf('void _acceptDriverFix(');
      final body = src.substring(fn, fn + 2100);
      expect(body.contains('timestampMs < last'), isTrue,
          reason: 'out-of-order fixes are dropped');
      expect(body.contains('timestampMs == last'), isTrue,
          reason: 'the same fix re-sent carries no new information');
      expect(body.contains('_driverMotion.setTarget('), isTrue);
    });
  });
}
