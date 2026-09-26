import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the trip-accept screen's navigation behaviour.
///
/// Pure source-grep (same style as driver_scheduled_neu_guard_test.dart):
/// the feature needs GPS, a live trip and a native map, so what a unit test
/// CAN pin is that the load-bearing pieces are wired where they belong:
///   1. Web-booking bookkeeping lines never reach the driver as
///      "passenger instructions".
///   2. Continue AND Directions (both legs) AND phase-1 Start Trip open the
///      in-app DriverNavView (`_enterNavMode`, user spec 2026-09-17); the
///      address cards stay on external maps. The surface handoff is
///      ordered: preview unmounts → coordinator release → nav mounts (two
///      live MapWidgets crash iOS).
///   3. The nav view is production-grade: off-route rerouting (40 m / 4 s /
///      15 s cooldown / stale-seq guard), _CamState + _NavPhase state
///      machines, internal arrival that never fires backend transitions,
///      GPS/network failure cards, prefetched route on open.
///   4. A rider with Location Sharing off (privacy_location == false)
///      publishes nothing.
void main() {
  final accept =
      File('lib/screens/driver/driver_trip_accept_screen.dart')
          .readAsStringSync();
  final nav =
      File('lib/screens/driver/driver_nav_view.dart').readAsStringSync();
  final riderMap =
      File('lib/widgets/tracking/tracking_map_view.dart').readAsStringSync();
  final l10n =
      File('lib/l10n/app_localizations.dart').readAsStringSync();

  /// Extracts [maxLen] chars of [src] starting at [signature].
  String bodyOf(String src, String signature, {int maxLen = 1600}) {
    final start = src.indexOf(signature);
    expect(start, isNonNegative, reason: '$signature not found');
    return src.substring(start, start + maxLen);
  }

  group('web booking filter', () {
    final start = accept.indexOf('String get _passengerInstructions');
    final block = start >= 0 ? accept.substring(start, start + 1200) : '';

    test('_passengerInstructions drops "Web booking" lines', () {
      expect(block, isNotEmpty,
          reason: '_passengerInstructions getter not found');
      expect(block.contains("startsWith('web booking')"), isTrue);
    });

    test('the filter is case-insensitive', () {
      expect(block.contains('.toLowerCase()'), isTrue);
    });

    test('real passenger instructions still pass', () {
      // The Wait started: filter predates this feature — both must stay.
      expect(block.contains("startsWith('Wait started:')"), isTrue);
    });
  });

  group('nav mode entry', () {
    test('Continue and Directions both enter nav mode on the pickup leg', () {
      final body =
          bodyOf(accept, 'Widget _buildContinueDirections() {', maxLen: 2400);
      expect('_enterNavMode'.allMatches(body).length, greaterThanOrEqualTo(2),
          reason: 'the gold Continue AND the outlined Directions must both '
              'call _enterNavMode()');
      expect(body, isNot(contains('_openNativeMaps')),
          reason: 'Continue/Directions no longer leave the app');
    });

    test('Continue and Directions both enter nav mode on the dropoff leg', () {
      final body = bodyOf(accept, 'Widget _buildContinueDirectionsDropoff() {',
          maxLen: 2400);
      expect('_enterNavMode'.allMatches(body).length, greaterThanOrEqualTo(2),
          reason: 'the gold Continue AND the outlined Directions must both '
              'call _enterNavMode()');
      expect(body, isNot(contains('_openNativeMaps')),
          reason: 'Continue/Directions no longer leave the app');
    });

    test('phase-1 Start Trip enters in-app nav with the morph', () {
      final body =
          bodyOf(accept, 'Widget _buildSlideStartTrip() {', maxLen: 1300);
      expect(body.contains('_enterNavMode()'), isTrue,
          reason: 'user spec 2026-09-17: Start Trip opens the in-app '
              'navigation through the mini-map morph, chase camera ready');
      expect(body, isNot(contains('_openNativeMaps')),
          reason: 'Start Trip no longer leaves the app for external maps');
    });

    test('the old _goNavigate launchers are gone', () {
      expect(accept, isNot(contains('_goNavigate(')));
      expect(accept, isNot(contains('_goNavigateDropoff(')));
    });

    test('_enterNavMode releases the preview surface before mounting', () {
      final body =
          bodyOf(accept, 'Future<void> _enterNavMode({bool? toPickup}) async {', maxLen: 2600);
      final snapshot = body.indexOf('_captureMapSnapshot(_map)');
      final sweep = body.indexOf('_sweepPreviewAnnotations()');
      final unmount = body.indexOf('_previewMapMounted = false');
      final release = body.indexOf(
          'MapSurfaceCoordinator.instance.release(_mapSurfaceOwner)');
      final mount = body.indexOf('_navMode = true');
      expect(snapshot, isNonNegative,
          reason: 'the morph needs the preview\'s last frame');
      expect(sweep, isNonNegative,
          reason: 'user report 2026-09-19 ("hay un carrito encima de la '
              'flecha"): the preview\'s car annotation + its GPS stream must '
              'die with the handoff, not follow the driver onto the nav map');
      expect(unmount, isNonNegative,
          reason: 'the preview MapWidget must leave the tree first');
      expect(release, isNonNegative,
          reason: 'the coordinator claim must be released before the nav '
              'view acquires it');
      expect(mount, isNonNegative);
      expect(snapshot, lessThan(unmount),
          reason: 'snapshot BEFORE unmount — a dead surface captures nothing');
      expect(sweep, greaterThan(snapshot),
          reason: 'sweep AFTER the snapshot — the morph keeps the last frame');
      expect(sweep, lessThan(unmount),
          reason: 'and BEFORE the unmount, while manager and surface live');
      expect(unmount, lessThan(release));
      expect(release, lessThan(mount),
          reason: 'release-before-mount — two live MapWidgets crash iOS');
      expect(accept.contains('_carGpsSub?.cancel()'), isTrue,
          reason: 'the preview car\'s own GPS stream is what kept it '
              'following the driver over the nav\'s arrow');
    });

    test('exit dissolves the nav map back into the mini-map card', () {
      final wrapper = bodyOf(accept, 'void _exitNavMode() {', maxLen: 300);
      expect(wrapper.contains('_collapseNavMode();'), isTrue,
          reason: 'exit routes through the reverse morph');
      final body =
          bodyOf(accept, 'Future<void> _collapseNavMode() async {', maxLen: 2000);
      final snapshot = body.indexOf('_captureMapSnapshot(');
      final drop = body.indexOf('_navMode = false');
      final reacquire = body.indexOf('_acquireMapSurface()');
      expect(snapshot, isNonNegative,
          reason: 'the nav map\'s last frame covers the surface swap');
      expect(drop, isNonNegative);
      expect(reacquire, isNonNegative,
          reason: 'the preview card claims the surface back on exit');
      expect(snapshot, lessThan(drop),
          reason: 'snapshot BEFORE the nav view unmounts');
      expect(drop, lessThan(reacquire));
    });

    test('back inside navigation leaves navigation, not the trip', () {
      final start = accept.indexOf('onPopInvokedWithResult: (didPop, _) {');
      expect(start, isNonNegative);
      final block = accept.substring(start, start + 400);
      expect(block.contains('if (_navMode)'), isTrue);
      expect(block.contains('_exitNavMode();'), isTrue);
    });

    test('Start Trip enters dropoff navigation in-app, only on backend success',
        () {
      final body =
          bodyOf(accept, 'void _startRideConfirmed() {', maxLen: 1300);
      expect(body.contains('await _updateTripInTrip()'), isTrue,
          reason: 'dropoff navigation waits for the confirmed in_trip '
              'transition — navigation state never fakes trip state');
      expect(body.contains('_enterNavMode()'), isTrue,
          reason: 'Start Trip success runs the same in-app nav entry as '
              'Continue / Directions');
      expect(body, isNot(contains('_openNativeMaps')),
          reason: 'the dropoff leg no longer leaves the app');
    });

    test('address cards: tap opens in-app nav (card leg), long-press the '
        'Cruise/Google/Apple chooser (user spec 2026-09-19)', () {
      expect(accept.contains('onTap: () => _enterNavMode(),'), isTrue,
          reason: 'pickup card tap opens the in-app turn-by-turn, no more '
              'straight-to-Apple-Maps');
      expect(accept.contains('_showNavigateChooser(isPickup: true)'), isTrue);
      expect(accept.contains('onTap: () => _enterNavMode(toPickup: false)'),
          isTrue,
          reason: 'dropoff card tap navigates to the DROPOFF leg even '
              'before the ride starts');
      expect(accept.contains('_showNavigateChooser(isPickup: false)'),
          isTrue);
      final chooser =
          bodyOf(accept, 'void _showNavigateChooser({required bool isPickup})',
              maxLen: 2800);
      expect(chooser.contains('s.navCruiseNav'), isTrue,
          reason: 'Cruise Navigation is the first option');
      expect(chooser.contains('_openGoogleMaps(coords)'), isTrue);
      expect(chooser.contains('_openAppleMaps(coords)'), isTrue);
      // Brand marks (user spec 2026-09-23): "Cruise Map" carries the Cruise
      // logo, Google/Apple their own map marks — the Material icons stay
      // only as the missing-asset fallback, never tinted.
      expect(chooser.contains('cruise_logo.png'), isTrue,
          reason: 'Cruise Map shows the Cruise logo');
      expect(chooser.contains('google_maps_logo.png'), isTrue);
      expect(chooser.contains('apple_maps_logo.png'), isTrue);
      expect(
          l10n.contains(
              "navCruiseNav => _es ? 'Cruise Maps' : 'Cruise Maps'"),
          isTrue,
          reason: '"Cruise Navigation" was renamed "Cruise Maps" (user spec '
              '2026-09-23)');
      expect(
          accept.contains(
              'toPickup: _navToPickupOverride ?? !_rideStarted'),
          isTrue,
          reason: 'the mount honors the card-leg override, natural leg '
              'otherwise');
    });

    test('the mount passes the prefetched route and every trip callback', () {
      expect(accept.contains("import 'driver_nav_view.dart'"), isTrue);
      final start = accept.indexOf('child: DriverNavView(');
      expect(start, isNonNegative, reason: 'DriverNavView mount not found');
      final mount = accept.substring(start, start + 2200);
      expect(mount.contains('prefetchedRoutePoints: _routePoints'), isTrue,
          reason: 'the mini map\'s already-drawn route must seed the nav '
              'view — no fetch, no blank map on open');
      expect(mount.contains('toPickup: _navToPickupOverride ?? !_rideStarted'),
          isTrue);
      expect(mount.contains('stage: _actionStageKey()'), isTrue);
      expect(mount.contains('waitStartedAt: _waitStartedAt'), isTrue);
      expect(mount.contains('onExit: _exitNavMode'), isTrue);
      expect(mount.contains('onArrived: _confirmArrival'), isTrue);
      expect(mount.contains('onSlidePickUp: _startRideConfirmed'), isTrue);
      expect(mount.contains('onSlideFinish: _finishTrip'), isTrue);
      expect(mount.contains('onOpenChat: _openChat'), isTrue);
      expect(mount.contains('onCall: _call'), isTrue);
      expect(mount.contains('onSupport: _openSupportChat'), isTrue);
      expect(mount.contains('onMapReady: _onNavMapReady'), isTrue,
          reason: 'the enter morph cross-fades its snapshot out on this '
              'signal');
    });

    test('the morph overlay sits above nav, below the chained card', () {
      final navMount = accept.indexOf('child: DriverNavView(');
      final morph = accept.indexOf('child: NavMorphOverlay(');
      final chained = accept.indexOf('child: _buildChainedOfferCard(');
      expect(navMount, isNonNegative);
      expect(morph, isNonNegative,
          reason: 'NavMorphOverlay covers the map-surface swap');
      expect(chained, isNonNegative);
      expect(navMount, lessThan(morph));
      expect(morph, lessThan(chained),
          reason: 'the chained offer keeps working over the morph');
    });

    test('the morph overlay animates a snapshot, never a second surface', () {
      final morph =
          File('lib/widgets/nav_morph_overlay.dart').readAsStringSync();
      expect(morph.contains('Image.memory('), isTrue);
      expect(morph.contains('NavMorphDirection'), isTrue);
      expect(morph.contains('revealRequested'), isTrue,
          reason: 'enter holds until the live nav map is ready');
      expect(morph.contains('onFinished'), isTrue);
      expect(morph, isNot(contains('MapWidget')),
          reason: 'two live MapWidgets are the iOS crash');
    });
  });

  group('nav view: off-route rerouting', () {
    test('30 m threshold held for 2 s of fixes, 20 m reset, 8 s cooldown '
        '(tightened 2026-09-19 under the 65 m fix gate)', () {
      expect(nav.contains('_offRouteM = 30.0'), isTrue,
          reason: 'user report 2026-09-19: "tarda mucho en redireccionar" — '
              '40 m / 4 s / 15 s was too slow to redirect');
      expect(nav.contains('_offRouteResetM = 20.0'), isTrue);
      expect(nav.contains('_offRouteHoldSecs = 2'), isTrue);
      expect(nav.contains('_rerouteCooldownSecs = 8'), isTrue);
      expect(nav.contains('RouteSplice.distanceToPolylineM(_routePts, pos)'),
          isTrue);
    });

    test('nav fixes pass the 65 m accuracy gate so 30 m cannot false-arm', () {
      final body = bodyOf(nav, 'void _onGpsFix(Position pos) {', maxLen: 500);
      expect(body.contains('pos.accuracy > 65'), isTrue,
          reason: 'without the gate, GPS noise at 30 m would fire false '
              'reroutes all day');
    });

    test('reroutes fetch on the fast lane (Mapbox alone, 5 s cap)', () {
      final svc = File('lib/services/directions_service.dart')
          .readAsStringSync();
      expect(svc.contains('bool fast = false'), isTrue);
      expect(
          nav.contains('fast: kind == _RouteFetchKind.reroute'), isTrue,
          reason: 'the normal race waits for all three providers (up to '
              '8 s) — a driver mid-turn cannot wait for that');
    });

    test('one fetch in flight, stale responses dropped by seq', () {
      expect(nav.contains('if (_routeFetching) return;'),
          reason: 'never two route fetches at once', isTrue);
      expect(nav.contains('int _rerouteSeq = 0'), isTrue);
      expect(nav.contains('seq != _rerouteSeq'), isTrue,
          reason: 'a stale response must never replace a newer plan');
    });

    test('the old line is kept until the new one replaces it atomically', () {
      final body = bodyOf(nav, 'case _RouteFetchKind.reroute:', maxLen: 700);
      expect(body.contains('_routePts = result.points'), isTrue);
      expect(body.contains('_navProgress = NavProgress(result.steps)'), isTrue);
      expect(body.contains('await _drawRoute();'), isTrue,
          reason: 'same-annotation update — never two lines on the map');
      expect(nav.contains('s.navRerouting'), isTrue,
          reason: 'the gold Rerouting… pill rides the fetch');
    });
  });

  group('nav view: state machines', () {
    test('camera state machine: following / freeLook / recentering', () {
      expect(nav.contains('enum _CamState { following, freeLook, recentering }'), isTrue);
      expect(nav.contains('_camState = _CamState.freeLook'), isTrue);
      expect(nav.contains('_camState = _CamState.recentering'), isTrue);
      expect(nav.contains('_camState = _CamState.following'), isTrue);
    });

    test('navigation state machine carries every phase', () {
      final start = nav.indexOf('enum _NavPhase {');
      expect(start, isNonNegative);
      final body = nav.substring(start, start + 300);
      for (final phase in [
        'initializing',
        'toPickup',
        'approachingPickup',
        'arrivedPickup',
        'toDropoff',
        'approachingDropoff',
        'arrivedDropoff',
        'rerouting',
        'gpsUnavailable',
        'routeError',
      ]) {
        expect(body.contains(phase), isTrue, reason: '_NavPhase.$phase missing');
      }
    });

    test('gestures unlatch to freeLook; the chase never writes there', () {
      expect(nav.contains('onScrollListener: (_) => _onUserGesture()'), isTrue);
      expect(nav.contains('onZoomListener: (_) => _onUserGesture()'), isTrue);
      expect(nav.contains('_camState != _CamState.following'), isTrue,
          reason: 'the per-frame chase must be gated on the camera state');
    });

    test('dynamic chase zoom 17.1 / 16.7 / 18.0, lerped never stepped '
        '(user spec 2026-09-19: more anticipation)', () {
      expect(nav.contains('_chaseZoomDefault = 17.1'), isTrue,
          reason: 'slight zoom-out — the next stop/intersection shows '
              'BEFORE it is on top of the car');
      expect(nav.contains('_chaseZoomFast = 16.7'), isTrue);
      expect(nav.contains('_chaseZoomManeuver = 18.0'), isTrue);
      expect(nav.contains('_zoomLerpPerSec = 0.5'), isTrue);
      final frame = bodyOf(nav, 'void _onDotFrame() {', maxLen: 1600);
      expect(frame.contains('+ 240'), isTrue,
          reason: 'the car rides at ~70% height — more road ahead on screen');
    });
  });

  group('nav view: arrival + prefetch', () {
    test('approach at 200 m, arrival at 30 m with 25 m accuracy', () {
      expect(nav.contains('_approachRadiusM = 200.0'), isTrue);
      expect(nav.contains('_arriveRadiusM = 30.0'), isTrue);
      expect(nav.contains('_arriveAccuracyM = 25.0'), isTrue);
      expect(nav.contains('s.navArrivedPickup'), isTrue);
      expect(nav.contains('s.navArrivedDropoff'), isTrue);
    });

    test('arrival fires no backend transition — the trip page rules the flow',
        () {
      // User spec 2026-09-17: the nav view is navigation-only. No Arrived
      // button, no slide to pick up / finish in here — those live on the
      // trip page (the accept screen's own controls), which stays the flow
      // authority exactly like before.
      expect(nav, isNot(contains('_buildStageControl')),
          reason: 'the arrived/start_ride/finish controls are gone from nav');
      expect(nav, isNot(contains('_buildSlideBar')),
          reason: 'no slide-to-finish inside navigation');
      expect(nav, isNot(contains('widget.onSlidePickUp();')));
      expect(nav, isNot(contains('widget.onSlideFinish();')));
      expect(nav, isNot(contains('widget.onArrived();')),
          reason: 'nav never fires a trip-state transition');
    });

    test('arrival shows End Route INSIDE the sheet, gold, swapped in', () {
      expect(nav.contains('_buildEndRouteButton(s)'), isTrue,
          reason: 'the explicit close action lives in the bottom sheet');
      expect(nav.contains("ValueKey('end-route')"), isTrue,
          reason: 'user spec 2026-09-17: on arrival the addresses swap out '
              'and the gold button fades in — inside the sheet');
      expect(nav.contains("ValueKey('trip-details')"), isTrue,
          reason: 'the swap is one AnimatedSwitcher slot');
      expect(nav.contains('child: _endRouteVisible'), isTrue);
      final btn =
          bodyOf(nav, 'Widget _buildEndRouteButton(S s) {', maxLen: 900);
      expect(btn.contains('widget.onExit();'), isTrue,
          reason: 'End Route closes navigation only — it never fires a '
              'trip-state transition');
      expect(btn.contains('s.navIArrived'), isTrue,
          reason: 'user spec 2026-09-19: the button reads "He llegado" — it '
              'only shows once the driver is AT the client\'s place');
      expect(btn.contains('backgroundColor: _gold'), isTrue,
          reason: 'gold FILLED — never the outlined navy floater again');
      expect(nav.contains('_endRouteRaised'), isTrue,
          reason: 'the sheet auto-raises once on arrival so the button is '
              'actually visible');
      final bar = bodyOf(nav, 'Widget _buildManeuverBar(S s) {', maxLen: 4400);
      expect(bar.contains('s.navExit'), isTrue,
          reason: 'the top bar keeps the quiet X — End Route is below');
      expect(bar, isNot(contains('navEndRoute')));
    });

    test('arrived: bar shows the CLIENT ADDRESS, arrow aims at the pin '
        '(user spec 2026-09-19)', () {
      final bar = bodyOf(nav, 'Widget _buildManeuverBar(S s) {', maxLen: 1200);
      expect(
          bar.contains('final title = _endRouteVisible\n'
              '        ? destName'),
          isTrue,
          reason: 'the big text is the client address once you are there — '
              'never "Follow the route" at 9 ft');
      expect(bar.contains('s.navArrivedPickup'), isTrue,
          reason: 'the "you\'ve arrived" note rides under the address');
      final arrival = bodyOf(nav, 'void _checkArrival(Position pos) {',
          maxLen: 1600);
      expect(arrival.contains('_dot.setBearing('), isTrue,
          reason: 'parked, iOS pauses GPS — without the explicit aim the '
              'arrow freezes at the last driving heading (the "carrito" '
              'pointing backwards)');
      expect(arrival.contains('_dest.latitude, _dest.longitude'), isTrue);
    });

    test('the destination pin is the shared golden teardrop', () {
      final body =
          bodyOf(nav, 'Future<void> _drawDestPin() async {', maxLen: 1000);
      expect(body.contains('renderCircularPinBytes('), isTrue,
          reason: 'the same pin the mini-map and every other map draws');
      expect(body.contains('CircularPinIcon.person'), isTrue,
          reason: 'person pin on the pickup leg');
      expect(body.contains('CircularPinIcon.flag'), isTrue,
          reason: 'flag pin on the dropoff leg');
      expect(body.contains('iconAnchor: mapbox.IconAnchor.BOTTOM'), isTrue,
          reason: 'the teardrop tip lands on the coordinate');
      expect(body, isNot(contains("'★'")), reason: 'the star glyph is gone');
    });

    test('prefetched geometry draws at mount behind a 150 m destination gate',
        () {
      expect(nav.contains('prefetchedRoutePoints'), isTrue);
      expect(nav.contains('_prefetchDestMaxM = 150.0'), isTrue);
      expect(nav.contains('_seedPrefetchedRoute();'), isTrue);
      expect(nav.contains('_RouteFetchKind.backgroundFill'), isTrue,
          reason: 'geometry-only prefetch fetches steps in the background '
              'without wiping the drawn line');
    });
  });

  group('nav view: failure handling', () {
    test('gpsUnavailable: 6 s watchdog + settings/retry recovery card', () {
      expect(nav.contains('_gpsStaleSecs = 6'), isTrue);
      expect(nav.contains('_gpsWatchdog'), isTrue);
      expect(nav.contains('Geolocator.openLocationSettings()'), isTrue);
      expect(nav.contains('s.navGpsUnavailableTitle'), isTrue);
      expect(nav.contains('s.navGpsUnavailableBody'), isTrue);
      expect(nav.contains('s.navOpenSettings'), isTrue);
      expect(nav.contains('s.navRetry'), isTrue);
    });

    test('a stall is not a cause: the card needs location genuinely off',
        () {
      expect(nav.contains('_diagnoseGpsStall'), isTrue);
      expect(nav.contains('Geolocator.isLocationServiceEnabled()'), isTrue);
      expect(nav.contains('Geolocator.checkPermission()'), isTrue,
          reason: 'user spec 2026-09-17: the No-GPS card is only for '
              'service off or permission revoked — a tunnel/parked-car '
              'silence with permission ON must not raise it');
    });

    test('network down: keep the drawn route (5/15/30 s backoff) or retry',
        () {
      expect(nav.contains('_offlineKeepRoute'), isTrue);
      expect(nav.contains('s.navOfflineKeepRoute'), isTrue);
      expect(nav.contains('Duration(seconds: 5)'), isTrue);
      expect(nav.contains('Duration(seconds: 15)'), isTrue);
      expect(nav.contains('Duration(seconds: 30)'), isTrue);
      expect(nav.contains('_routeError'), isTrue,
          reason: 'with nothing drawn there is no navigation — routeError '
              'card with a retry button');
    });
  });

  group('nav view: lifecycle', () {
    test('dispose cancels every timer/sub and releases the coordinator', () {
      final body = bodyOf(nav, 'void dispose() {', maxLen: 700);
      expect(
          body, contains('MapSurfaceCoordinator.instance.release(_mapSurfaceOwner)'));
      expect(body.contains('_gpsWatchdog?.cancel()'), isTrue);
      expect(body.contains('_offlineRetryTimer?.cancel()'), isTrue);
      expect(body.contains('_riderLocSub?.cancel()'), isTrue);
      expect(body.contains('_riderStaleTimer?.cancel()'), isTrue);
      expect(body.contains('_waitTicker?.cancel()'), isTrue);
    });

    test('one native surface, claimed under a per-instance owner', () {
      expect(nav.contains("'DriverTripNav-"), isTrue);
      expect(nav.contains('MapSurfaceCoordinator.instance.acquire('), isTrue);
    });
  });

  group('l10n', () {
    test('the new nav keys exist', () {
      for (final key in [
        'navRerouting',
        'navOfflineKeepRoute',
        'navRetry',
        'navGpsUnavailableTitle',
        'navGpsUnavailableBody',
        'navOpenSettings',
        'navArrivedPickup',
        'navArrivedDropoff',
        'navEndRoute',
        'navIArrived',
      ]) {
        expect(l10n.contains('String get $key'), isTrue,
            reason: '$key missing from app_localizations.dart');
      }
    });
  });

  group('rider publishing privacy', () {
    test('honors the privacy_location toggle', () {
      final start = riderMap.indexOf('_startRiderLocationSharing');
      final block =
          start >= 0 ? riderMap.substring(start, start + 1400) : '';
      expect(block, isNotEmpty,
          reason: '_startRiderLocationSharing not found');
      expect(block.contains("getBool('privacy_location')"), isTrue);
    });

    test('publishes through the socket relay with the fix capture time', () {
      expect(riderMap.contains('SocketService.sendRiderLocation('), isTrue);
      expect(riderMap.contains('capturedAtMs'), isTrue);
    });

    test('stops publishing once the pickup window closes', () {
      expect(riderMap.contains('_stopRiderLocationSharing()'), isTrue);
      expect(riderMap.contains('_TrackPhase.arriving'), isTrue);
      expect(riderMap.contains('_TrackPhase.arrived'), isTrue);
    });
  });

  group('user spec 2026-09-19: tangent steering, route erase, imperial bar, '
      'road furniture', () {
    test('the route tangent steers the arrow at EVERY speed on-route', () {
      final body = bodyOf(nav, 'void _onGpsFix(Position pos) {', maxLen: 4200);
      expect(body.contains('bearing: onRoute ? null'), isTrue,
          reason: 'user report: GPS headings arrive once a second and the '
              'arrow turned in steps — on-route only the continuous route '
              'tangent speaks');
      expect(body.contains('_dot.setBearing(h)'), isTrue);
      expect(body.contains('_speedMps < 1.0'), isTrue,
          reason: 'the parked 20° anti-twitch deadband stays (2026-09-17)');
      expect(body.contains('RouteSplice.distanceToPolylineM(_routePts, fixLL)'),
          isTrue);
    });

    test('the line is eaten forward-only, off the dot glide, cursor reset '
        'with fresh geometry', () {
      expect(nav.contains('void _trimRouteTo(LatLng pos)'), isTrue);
      final body = bodyOf(nav, 'void _trimRouteTo(LatLng pos) {', maxLen: 1500);
      expect(body.contains('s < _trimS - 2'), isTrue,
          reason: 'monotonic forward — a jittery fix must never regrow the '
              'eaten line');
      expect(body.contains('inMilliseconds < 400'), isTrue,
          reason: 'native writes throttled (~2.5/s) — no per-frame churn');
      expect(body.contains('s - _trimS > 150'), isTrue,
          reason: 'self-crossing streets: the cursor never leaps hundreds of '
              'metres in one tick (2026-09-25 — far-ahead signs were eaten)');
      final tick = bodyOf(nav, 'void _onDotTick() {', maxLen: 500);
      expect(tick.contains('_trimRouteTo('), isTrue,
          reason: 'the erase rides the dot\'s animated position, not the '
              '1 Hz GPS fix — sin retrasos');
      final resets =
          RegExp(r'_trimS = 0;').allMatches(nav).length;
      expect(resets, greaterThanOrEqualTo(4),
          reason: 'prefetch / backgroundFill / reroute / initial+retry / '
              'leg-flip all restart the erase cursor');
    });

    test('maneuver distances are imperial ALWAYS (feet under 0.1 mi)', () {
      final body = bodyOf(nav, 'String _fmtDist(double meters, S s) {',
          maxLen: 400);
      expect(body.contains('isSpanish'), isFalse,
          reason: 'user spec 2026-09-19: "en vez de metros sean millas asi '
              'tal cual" — no metric branch anywhere');
      expect(body.contains('meters / 1609.34'), isTrue);
      expect(body.contains('meters * 3.28084'), isTrue);
    });

    test('street labels read at speed; style signal layers stay OFF', () {
      expect(nav.contains('_applyNavRoadFurniture('), isTrue);
      final body =
          bodyOf(nav, 'Future<void> _applyNavRoadFurniture(', maxLen: 1800);
      expect(body.contains("'text-size', 15.0"), isTrue,
          reason: 'street names big enough to read at a glance');
      expect(body.contains('getStyleLayers()'), isFalse,
          reason: 'the style\'s own signal layers render network-wide — the '
              'product rule is route-only signals (user report 2026-09-25), '
              'handled by the parsed furniture set');
      final style =
          bodyOf(nav, 'onStyleLoadedListener: (_) async {', maxLen: 400);
      expect(style.contains('_applyNavRoadFurniture(m)'), isTrue,
          reason: 'furniture applies on style-load, after the navy/gold '
              'theme — layer writes before that fail silently');
    });
    test('the display arrow snaps onto the route line (80 m), measurements '
        'stay raw (user report 2026-09-19)', () {
      expect(nav.contains('LatLng? _snapToNavRoute(LatLng p)'), isTrue);
      final body = bodyOf(nav, 'LatLng? _snapToNavRoute(LatLng p) {',
          maxLen: 500);
      expect(body.contains('<= 80'), isTrue,
          reason: 'the Find-My threshold — beyond it the fix is genuinely '
              'off-route and snapping would teleport the car');
      final fix = bodyOf(nav, 'void _onGpsFix(Position pos) {', maxLen: 2600);
      expect(fix.contains('_snapToNavRoute(fixLL) ?? fixLL'), isTrue,
          reason: 'a house driveway is genuinely off the road — the arrow '
              'rides the line, worst at nav start parked at the pickup');
      expect(fix.contains('RouteSplice.distanceToPolylineM(_routePts, fixLL)'),
          isTrue,
          reason: 'off-route detection must read the RAW fix, never the '
              'snapped display point');
      final seed = bodyOf(nav, 'if (_dot.lat == null) {', maxLen: 500);
      expect(seed.contains('_snapToNavRoute(widget.initialDriverPos)'),
          isTrue,
          reason: 'the nav opens with the arrow ON the line, not floating '
              'in the pickup\'s block');
    });
  });

  group('user spec 2026-09-19: traffic lights + stop signs from Mapbox '
      'intersections', () {
    test('the directions parser reads traffic_signal and stop_sign', () {
      final svc = File('lib/services/directions_service.dart')
          .readAsStringSync();
      expect(svc.contains("i['traffic_signal'] == true"), isTrue,
          reason: 'the flags ride the Directions response when steps=true — '
              'the same data the Navigation SDK uses for its icons');
      expect(svc.contains("i['stop_sign'] == true"), isTrue);
      expect(
          svc.contains('List<NavFurniture> _parseMapboxFurniture('), isTrue);
      expect(svc.contains('this.furniture = const []'), isTrue,
          reason: 'Google/OSRM routes carry none — default empty');
    });

    test('signs are drawn as upright icons and eaten with the route line', () {
      expect(
          nav.contains('void _setRouteFurniture(List<NavFurniture>'), isTrue);
      expect(nav.contains('_renderTrafficLightBytes('), isTrue);
      expect(nav.contains('_renderStopSignBytes('), isTrue);
      final trim = bodyOf(nav, 'void _trimRouteTo(LatLng pos) {', maxLen: 2200);
      expect(trim.contains('e.s < _trimS - 5'), isTrue,
          reason: 'a sign the driver passed disappears with the stretch of '
              'road behind him');
      final draw = bodyOf(nav, 'Future<void> _drawFurniture() async {',
          maxLen: 1400);
      expect(draw.contains('_pointMgr'), isTrue,
          reason: 'the shared pins manager — viewport-aligned, signs never '
              'lie down with the chase camera');
      expect(draw.contains('iconAnchor: mapbox.IconAnchor.CENTER'), isTrue);
      expect(draw.contains('iconSize: 1.35'), isTrue,
          reason: 'user spec 2026-09-19: semaforos un poquito mas grandes — '
              '0.9 read tiny at chase zoom');
    });

    test('furniture rides every route fill path', () {
      final succeeded =
          bodyOf(nav, 'Future<void> _onRouteFetchSucceeded', maxLen: 2400);
      expect(
          RegExp(r'_setRouteFurniture\(result\.furniture\)')
              .allMatches(succeeded)
              .length,
          greaterThanOrEqualTo(3),
          reason: 'backgroundFill / reroute / initial+retry all refresh the '
              'signs with the fresh geometry');
      // The backgroundFill one must be OUTSIDE the 5% geometry gate — the
      // dominant prefetched path never crosses it (user report: "me
      // quitaste los semaforos").
      final bgFill = succeeded.indexOf('case _RouteFetchKind.backgroundFill:');
      final reroute = succeeded.indexOf('case _RouteFetchKind.reroute:');
      expect(bgFill, isNonNegative);
      expect(reroute, greaterThan(bgFill));
      final gate = succeeded.indexOf('> _routeLenM * 0.05', bgFill);
      final setFurniture =
          succeeded.indexOf('_setRouteFurniture(result.furniture)', bgFill);
      expect(setFurniture, greaterThan(gate),
          reason: 'identical prefetched geometry must not skip the signs');
      final fill = bodyOf(nav, 'Future<void> _fillSteps(LatLng origin) async {',
          maxLen: 700);
      expect(fill.contains('_setRouteFurniture(res.furniture)'), isTrue,
          reason: 'the Mapbox steps fill carries the signs too');
    });

    test('signs snap onto the DRAWN line, never the raw intersection '
        '(2026-09-23, misplaced in chase AND top-down)', () {
      expect(nav.contains('_snapFurniture(NavFurniture f)'), isTrue,
          reason: 'Mapbox intersection coords sit visibly off the drawn line '
              'when the line is the prefetch or a Google/OSRM geometry — the '
              'icon must anchor at the projected point');
      final snap = bodyOf(nav, '_snapFurniture(NavFurniture f)', maxLen: 700);
      expect(snap.contains('RouteSplice.projectOnSegment'), isTrue);
      expect(snap.contains('RouteSplice.haversineM(proj, f.at) > 30'), isTrue,
          reason: 'past 30 m off the line the sign belongs to another path — '
              'dropped, not misdrawn (tightened 2026-09-25 from 60: corner '
              'signals of the crossing street bled onto the route)');
      expect(snap.contains('at: proj'), isTrue,
          reason: 'the annotation rides the projected point — exactly on the '
              'line the driver sees, in every camera view');
      final set = bodyOf(nav, 'void _setRouteFurniture(List<NavFurniture>',
          maxLen: 800);
      expect(set.contains('_snapFurniture(f)'), isTrue);
    });

    test('signs survive the map-surface lifecycle '
        '(2026-09-23, "no aparecen")', () {
      final revoke = bodyOf(nav, 'onRevoke: () async {', maxLen: 1200);
      expect(revoke.contains('for (final sign in _furniture)'), isTrue,
          reason: 'dead annotation handles must be nulled on revoke or the '
              'redraw skips every sign as "already drawn"');
      final created = bodyOf(nav, 'Future<void> _onMapCreated', maxLen: 2200);
      expect(created.contains('_drawFurniture()'), isTrue,
          reason: 'a surface rebirth — or a route fetch that won the race '
              'against setup — otherwise loses the signs for the session');
    });
  });

  group('user spec 2026-09-16: chase opening, arrow always on, route bearing',
      () {
    test('the driver arrow is created eagerly at map ready', () {
      final body = bodyOf(nav, 'Future<void> _onMapCreated', maxLen: 2600);
      expect(body.contains('_updateDriverAnnotation()'), isTrue,
          reason: 'the dot ticker only fires on movement — without the '
              'eager create a parked driver never sees the arrow');
    });

    test('opening and route updates snap to the chase pose, never top-down',
        () {
      final created = bodyOf(nav, 'Future<void> _onMapCreated', maxLen: 3000);
      expect(created.contains('_snapToChasePose();'), isTrue);
      expect(created, isNot(contains('!_firstGpsFix || _overview')),
          reason: 'the top-down fit on open is gone — it belongs to the '
              'overview toggle only');
      final succeeded =
          bodyOf(nav, 'Future<void> _onRouteFetchSucceeded', maxLen: 3400);
      expect(succeeded.contains('_snapToChasePose();'), isTrue);
    });

    test('the very first native frame is already tilted down-route', () {
      final body =
          bodyOf(nav, 'cameraOptions: mapbox.CameraOptions(', maxLen: 700);
      expect(body.contains('zoom: _chaseZoomDefault'), isTrue);
      expect(body.contains('pitch: _chasePitch'), isTrue);
      expect(body.contains('_routeHeadingFor(widget.initialDriverPos)'), isTrue);
    });

    test('a parked/crawling driver aims by route tangent, not GPS noise', () {
      expect(nav.contains('double? _routeHeadingFor(LatLng pos)'), isTrue);
      expect(nav.contains('_speedMps < 1.0'), isTrue);
      expect(nav.contains('_dot.setBearing(h)'), isTrue);
      expect(nav.contains('RouteSplice.closestSegmentIndex(pts, pos)'), isTrue);
    });
  });

  group('user spec 2026-09-17: flat 25° chase, gold call disc, true speed',
      () {
    test('the chase tilt is 35° (user spec 2026-09-19), never back at 55', () {
      expect(nav.contains('_chasePitch = 35.0'), isTrue,
          reason: 'user spec 2026-09-19: "un poquitico mas inclinado", the '
              'reference nav view');
      expect(nav, isNot(contains('_chasePitch = 25.0')));
      expect(nav, isNot(contains('_chasePitch = 55.0')));
    });

    test('the sheet call disc is the gold-filled one, chat stays dark', () {
      final call = nav.indexOf('_sheetCircleBtn(Icons.phone_rounded');
      expect(call, isNonNegative);
      expect(nav.substring(call, call + 140), contains('filled: true'));
      final body = bodyOf(nav, 'Widget _sheetCircleBtn(', maxLen: 1600);
      expect(body.contains('color: _gold,'), isTrue);
      expect(body.contains('filled ? neuBase : _gold'), isTrue,
          reason: 'the filled disc carries a dark icon on gold');
    });

    test('the speed box reads the fix, then the smoother, never a stale 0',
        () {
      final body = bodyOf(nav, 'void _onGpsFix(Position pos) {', maxLen: 3400);
      expect(body.contains('_dot.speedMps'), isTrue,
          reason: 'iOS reports speed -1 when it has none — the box falls '
              'back to the smoother’s measured glide speed');
      expect(body.contains('rawSpeed < 0.45'), isTrue,
          reason: 'the <1 mph deadband kills the 0↔1 parked flicker');
      final dot = File('lib/widgets/gold_location_dot.dart')
          .readAsStringSync();
      expect(dot.contains('double get speedMps => _motion.speedMps;'), isTrue);
    });

    test('the arrow lives in its own manager so pins never lie down', () {
      expect(nav.contains('mapbox.PointAnnotationManager? _carMgr'), isTrue);
      final arrow =
          bodyOf(nav, 'Future<void> _updateDriverAnnotation() async {', maxLen: 800);
      expect(arrow.contains('final mgr = _carMgr;'), isTrue,
          reason: 'icon-rotation-alignment map is set per manager — on the '
              'shared pins manager it laid the destination pin on its side '
              'every time the chase camera turned (user report 2026-09-17)');
      final pin = bodyOf(nav, 'Future<void> _drawDestPin() async {', maxLen: 400);
      expect(pin.contains('final mgr = _pointMgr'), isTrue,
          reason: 'the pins manager keeps the default viewport alignment — '
              'the teardrop stands upright at any camera bearing');
    });

    test('the rider live location is the blue puck, never an icon', () {
      expect(nav.contains('mapbox.CircleAnnotation? _riderHaloAnnot'), isTrue);
      expect(nav.contains('mapbox.CircleAnnotation? _riderDotAnnot'), isTrue);
      expect(nav.contains('_riderBlue = Color(0xFF3B82F6)'), isTrue,
          reason: 'the same blue the rider side draws for the live dot');
      expect(nav, isNot(contains('_renderRiderFigure')),
          reason: 'user spec 2026-09-17: the gold person icon is gone — the '
              'driver sees the rider as the blue location dot');
    });

    test('the bar always carries a real distance + big soft-swap icon', () {
      final svc = File('lib/services/directions_service.dart')
          .readAsStringSync();
      expect(
          svc.contains(
              'Future<({List<NavStep> steps, List<NavFurniture> furniture})?> getSteps('),
          isTrue,
          reason: 'a race won by Google/OSRM arrives with empty steps — '
              'the bar fell back to a bare "Follow the route" forever '
              '(user report 2026-09-17); Mapbox fills the maneuvers — and '
              'the traffic-light/stop furniture rides the same call');
      expect(nav.contains('unawaited(_fillSteps(origin))'), isTrue);
      expect(nav.contains('_destDistLabel(s)'), isTrue,
          reason: 'the steps-less fallback shows distance-to-destination, '
              'never the title twice');
      final bar = bodyOf(nav, 'Widget _buildManeuverBar(S s) {', maxLen: 3600);
      expect(bar.contains('size: 48'), isTrue,
          reason: 'the big reference card (user spec 2026-09-19)');
      expect(bar.contains('AnimatedSwitcher('), isTrue,
          reason: 'indications crossfade, never snap');
    });

    test('leaving overview hands the camera back the SMOOTH way', () {
      final body =
          bodyOf(nav, 'void _toggleOverview() {', maxLen: 950);
      expect(body.contains('unawaited(_recenter());'), isTrue,
          reason: 'user spec 2026-09-17: the arrow button restores the chase '
              'with the same flyTo the recenter button uses — not a state '
              'flip that lets the next chase frame snap');
    });

    test('the sheet face carries the rider name next to min/mi', () {
      final body = bodyOf(nav, 'Widget _buildSheet(S s, ScrollController scrollCtrl) {', maxLen: 1200);
      expect(body.contains('firstName'), isTrue);
      expect(body.contains(".join(' · ')"), isTrue,
          reason: '"2 min · 0.3 mi · Jhon" — miles, minutes AND the rider '
              'name in the collapsed face');
    });
  });
}
