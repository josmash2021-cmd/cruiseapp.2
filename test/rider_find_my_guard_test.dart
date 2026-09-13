import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the rider Find-My pickup redesign (approved mockup
/// docs/mockups/find_my_pickup_mockup.html, spec 2026-09-12):
///
///   1. The 4-digit pickup PIN is read from `pickup_pin` on the Firestore
///      trip doc the screen already subscribes to, and the PIN block only
///      renders while the field is present.
///   2. The proximity latch at 2 m writes `rider_confirmed_pickup` (the
///      exact write that unlocks the driver's Start Ride) but NEVER calls
///      widget.onConfirmed — the screen closes only when the driver starts
///      the trip (green overlay + fade) or on cancel/wait-timeout.
///   3. No press-to-confirm remnant: `_onConfirmPressed` and the
///      `rideAutoStartWarning` line are gone.
///   4. The bottom row adds Support (headset) opening
///      CruiseSupportChatScreen, next to the existing Chat/Call.
///   5. The live mini map mounts through MapSurfaceCoordinator as owner
///      'RiderFindMyPickup' with a StaticRoutePreview stand-in, and the
///      tracking screen re-claims the surface when the overlay closes.
///   6. The rider dot glides through SmoothMotion (no fix-to-fix hops).
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

  group('proximity latches FOUND but never confirms', () {
    test('the latch threshold is 2 m', () {
      expect(src.contains('static const double _kDetectMeters = 2.0;'),
          isTrue,
          reason: 'spec: FOUND latches at 2 m (was 2.5)');
    });
    test('the latch writes the confirm flag and never calls onConfirmed', () {
      final body = bodyOf('void _latchFound() {');
      expect(body.contains('_writeRiderConfirmed'), isTrue);
      expect(body.contains('onConfirmed'), isFalse,
          reason: 'FOUND must never close the screen by itself — only the '
              'driver starting the trip (or a cancel) closes it');
    });
    test('the exact Firestore write that unlocks Start Ride is kept', () {
      final body = bodyOf('Future<void> _writeRiderConfirmed() async {');
      expect(body.contains("'rider_confirmed_pickup': true"), isTrue);
      expect(body.contains('confirmed_at'), isTrue);
      expect(body.contains('FieldValue.serverTimestamp()'), isTrue);
    });
    test('no press-to-confirm path remains', () {
      expect(src.contains('_onConfirmPressed'), isFalse,
          reason: 'the confirm press is gone — proximity latches FOUND and '
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
      expect(src.contains('MaskedCallService.callCounterparty('), isTrue);
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
    test('the live map is top-down dark style with all gestures off', () {
      expect(src.contains('styleUri: MapboxConfig.styleDark'), isTrue);
      expect(src.contains('pitch: 0.0'), isTrue);
      final body = bodyOf('Future<void> _onMiniMapCreated(mapbox.MapboxMap ctrl) async {');
      expect(body.contains('scrollEnabled: false'), isTrue);
      expect(body.contains('pinchToZoomEnabled: false'), isTrue);
      expect(body.contains('rotateEnabled: false'), isTrue);
      expect(body.contains('pitchEnabled: false'), isTrue);
    });
    test('rider dot and driver car run through SmoothMotion', () {
      expect(src.contains('final _riderMotion = SmoothMotion();'), isTrue);
      expect(src.contains('final _driverMotion = SmoothMotion();'), isTrue);
      expect(src.contains('_riderMotion.setTarget('), isTrue,
          reason: 'the rider-GPS stream feeds the smoother — the dot glides');
    });
    test('car marker is the tier PNG, edges feather into the background', () {
      expect(src.contains('assets/images/car_suv.png'), isTrue);
      expect(src.contains('assets/images/car_sedan.png'), isTrue);
      final body = bodyOf('Widget _buildMiniMap() {', maxLen: 6000);
      expect(body.contains('IgnorePointer'), isTrue,
          reason: 'the feather gradients never intercept touches');
      expect(body.contains('LinearGradient'), isTrue,
          reason: 'mockup: all four map edges fade into neuBase');
    });
    test('never on web (mapbox_maps_flutter does not run there)', () {
      expect(src.contains('if (!kIsWeb) {'), isTrue,
          reason: 'the surface acquire must stay behind the kIsWeb guard');
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
}
