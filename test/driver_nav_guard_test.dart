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
      expect(block, contains("startsWith('web booking')"));
    });

    test('the filter is case-insensitive', () {
      expect(block, contains('.toLowerCase()'));
    });

    test('real passenger instructions still pass', () {
      // The Wait started: filter predates this feature — both must stay.
      expect(block, contains("startsWith('Wait started:')"));
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
      expect(body, contains('_enterNavMode()'),
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
          bodyOf(accept, 'Future<void> _enterNavMode() async {', maxLen: 2200);
      final snapshot = body.indexOf('_captureMapSnapshot(_map)');
      final unmount = body.indexOf('_previewMapMounted = false');
      final release = body.indexOf(
          'MapSurfaceCoordinator.instance.release(_mapSurfaceOwner)');
      final mount = body.indexOf('_navMode = true');
      expect(snapshot, isNonNegative,
          reason: 'the morph needs the preview\'s last frame');
      expect(unmount, isNonNegative,
          reason: 'the preview MapWidget must leave the tree first');
      expect(release, isNonNegative,
          reason: 'the coordinator claim must be released before the nav '
              'view acquires it');
      expect(mount, isNonNegative);
      expect(snapshot, lessThan(unmount),
          reason: 'snapshot BEFORE unmount — a dead surface captures nothing');
      expect(unmount, lessThan(release));
      expect(release, lessThan(mount),
          reason: 'release-before-mount — two live MapWidgets crash iOS');
    });

    test('exit dissolves the nav map back into the mini-map card', () {
      final wrapper = bodyOf(accept, 'void _exitNavMode() {', maxLen: 300);
      expect(wrapper, contains('_collapseNavMode();'),
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
      expect(block, contains('if (_navMode)'));
      expect(block, contains('_exitNavMode();'));
    });

    test('Start Trip enters dropoff navigation in-app, only on backend success',
        () {
      final body =
          bodyOf(accept, 'void _startRideConfirmed() {', maxLen: 1300);
      expect(body, contains('await _updateTripInTrip()'),
          reason: 'dropoff navigation waits for the confirmed in_trip '
              'transition — navigation state never fakes trip state');
      expect(body, contains('_enterNavMode()'),
          reason: 'Start Trip success runs the same in-app nav entry as '
              'Continue / Directions');
      expect(body, isNot(contains('_openNativeMaps')),
          reason: 'the dropoff leg no longer leaves the app');
    });

    test('iOS one-tap Apple Maps / Android chooser stay on the address cards',
        () {
      expect(accept, contains('_openAppleMaps(widget.pickupLatLng)'));
      expect(accept, contains('_showNavigationSheet(isPickup: true)'));
      expect(accept, contains('_openAppleMaps(_dropoffLL)'));
      expect(accept, contains('_showNavigationSheet(isPickup: false)'));
    });

    test('the mount passes the prefetched route and every trip callback', () {
      expect(accept, contains("import 'driver_nav_view.dart'"));
      final start = accept.indexOf('child: DriverNavView(');
      expect(start, isNonNegative, reason: 'DriverNavView mount not found');
      final mount = accept.substring(start, start + 2200);
      expect(mount, contains('prefetchedRoutePoints: _routePoints'),
          reason: 'the mini map\'s already-drawn route must seed the nav '
              'view — no fetch, no blank map on open');
      expect(mount, contains('toPickup: !_rideStarted'));
      expect(mount, contains('stage: _actionStageKey()'));
      expect(mount, contains('waitStartedAt: _waitStartedAt'));
      expect(mount, contains('onExit: _exitNavMode'));
      expect(mount, contains('onArrived: _confirmArrival'));
      expect(mount, contains('onSlidePickUp: _startRideConfirmed'));
      expect(mount, contains('onSlideFinish: _finishTrip'));
      expect(mount, contains('onOpenChat: _openChat'));
      expect(mount, contains('onCall: _call'));
      expect(mount, contains('onSupport: _openSupportChat'));
      expect(mount, contains('onMapReady: _onNavMapReady'),
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
      expect(morph, contains('Image.memory('));
      expect(morph, contains('NavMorphDirection'));
      expect(morph, contains('revealRequested'),
          reason: 'enter holds until the live nav map is ready');
      expect(morph, contains('onFinished'));
      expect(morph, isNot(contains('MapWidget')),
          reason: 'two live MapWidgets are the iOS crash');
    });
  });

  group('nav view: off-route rerouting', () {
    test('40 m threshold held for 4 s of fixes, 25 m reset', () {
      expect(nav, contains('_offRouteM = 40.0'));
      expect(nav, contains('_offRouteResetM = 25.0'));
      expect(nav, contains('_offRouteHoldSecs = 4'));
      expect(nav, contains('RouteSplice.distanceToPolylineM(_routePts, pos)'));
    });

    test('one fetch in flight, 15 s cooldown, stale responses dropped by seq',
        () {
      expect(nav, contains('_rerouteCooldownSecs = 15'));
      expect(nav, contains('int _rerouteSeq = 0'));
      expect(nav, contains('if (_routeFetching) return;'),
          reason: 'never two route fetches at once');
      expect(nav, contains('seq != _rerouteSeq'),
          reason: 'a stale response must never replace a newer plan');
    });

    test('the old line is kept until the new one replaces it atomically', () {
      final body = bodyOf(nav, 'case _RouteFetchKind.reroute:', maxLen: 700);
      expect(body, contains('_routePts = result.points'));
      expect(body, contains('_navProgress = NavProgress(result.steps)'));
      expect(body, contains('await _drawRoute();'),
          reason: 'same-annotation update — never two lines on the map');
      expect(nav, contains('s.navRerouting'),
          reason: 'the gold Rerouting… pill rides the fetch');
    });
  });

  group('nav view: state machines', () {
    test('camera state machine: following / freeLook / recentering', () {
      expect(nav,
          contains('enum _CamState { following, freeLook, recentering }'));
      expect(nav, contains('_camState = _CamState.freeLook'));
      expect(nav, contains('_camState = _CamState.recentering'));
      expect(nav, contains('_camState = _CamState.following'));
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
        expect(body, contains(phase), reason: '_NavPhase.$phase missing');
      }
    });

    test('gestures unlatch to freeLook; the chase never writes there', () {
      expect(nav, contains('onScrollListener: (_) => _onUserGesture()'));
      expect(nav, contains('onZoomListener: (_) => _onUserGesture()'));
      expect(nav, contains('_camState != _CamState.following'),
          reason: 'the per-frame chase must be gated on the camera state');
    });

    test('dynamic chase zoom 17.5 / 17.0 / 18.0, lerped never stepped', () {
      expect(nav, contains('_chaseZoomDefault = 17.5'));
      expect(nav, contains('_chaseZoomFast = 17.0'));
      expect(nav, contains('_chaseZoomManeuver = 18.0'));
      expect(nav, contains('_zoomLerpPerSec = 0.5'));
    });
  });

  group('nav view: arrival + prefetch', () {
    test('approach at 200 m, arrival at 30 m with 25 m accuracy', () {
      expect(nav, contains('_approachRadiusM = 200.0'));
      expect(nav, contains('_arriveRadiusM = 30.0'));
      expect(nav, contains('_arriveAccuracyM = 25.0'));
      expect(nav, contains('s.navArrivedPickup'));
      expect(nav, contains('s.navArrivedDropoff'));
    });

    test('arrival fires no backend transition — sliders stay the authority',
        () {
      final body = bodyOf(
          nav, 'void _onSlideUpdate(double delta, double maxDrag) {',
          maxLen: 600);
      expect(body, contains('widget.onSlidePickUp();'));
      expect(body, contains('widget.onSlideFinish();'),
          reason: 'onSlidePickUp/onSlideFinish are only called from the '
              'stage controls');
    });

    test('arrival shows End Route under the stage control, never auto-closes',
        () {
      expect(nav, contains('_buildEndRouteButton(s)'),
          reason: 'the explicit close action lives at the bottom sheet, '
              'under the gold business action');
      expect(nav, contains('if (_phaseArrived)'),
          reason: 'it appears only in the arrival state');
      expect(nav, contains('_endRouteHeight + 10'),
          reason: 'the stage control rides up above it');
      final btn =
          bodyOf(nav, 'Widget _buildEndRouteButton(S s) {', maxLen: 900);
      expect(btn, contains('widget.onExit();'),
          reason: 'End Route closes navigation only — it never fires a '
              'trip-state transition');
      expect(btn, contains('s.navEndRoute'));
      final bar = bodyOf(nav, 'Widget _buildManeuverBar(S s) {', maxLen: 3400);
      expect(bar, contains('s.navExit'),
          reason: 'the top bar keeps the quiet X — End Route is below');
      expect(bar, isNot(contains('navEndRoute')));
    });

    test('the destination pin is the shared golden teardrop', () {
      final body =
          bodyOf(nav, 'Future<void> _drawDestPin() async {', maxLen: 1000);
      expect(body, contains('renderCircularPinBytes('),
          reason: 'the same pin the mini-map and every other map draws');
      expect(body, contains('CircularPinIcon.person'),
          reason: 'person pin on the pickup leg');
      expect(body, contains('CircularPinIcon.flag'),
          reason: 'flag pin on the dropoff leg');
      expect(body, contains('iconAnchor: mapbox.IconAnchor.BOTTOM'),
          reason: 'the teardrop tip lands on the coordinate');
      expect(body, isNot(contains("'★'")), reason: 'the star glyph is gone');
    });

    test('prefetched geometry draws at mount behind a 150 m destination gate',
        () {
      expect(nav, contains('prefetchedRoutePoints'));
      expect(nav, contains('_prefetchDestMaxM = 150.0'));
      expect(nav, contains('_seedPrefetchedRoute();'));
      expect(nav, contains('_RouteFetchKind.backgroundFill'),
          reason: 'geometry-only prefetch fetches steps in the background '
              'without wiping the drawn line');
    });
  });

  group('nav view: failure handling', () {
    test('gpsUnavailable: 6 s watchdog + settings/retry recovery card', () {
      expect(nav, contains('_gpsStaleSecs = 6'));
      expect(nav, contains('_gpsWatchdog'));
      expect(nav, contains('Geolocator.openLocationSettings()'));
      expect(nav, contains('s.navGpsUnavailableTitle'));
      expect(nav, contains('s.navGpsUnavailableBody'));
      expect(nav, contains('s.navOpenSettings'));
      expect(nav, contains('s.navRetry'));
    });

    test('network down: keep the drawn route (5/15/30 s backoff) or retry',
        () {
      expect(nav, contains('_offlineKeepRoute'));
      expect(nav, contains('s.navOfflineKeepRoute'));
      expect(nav, contains('Duration(seconds: 5)'));
      expect(nav, contains('Duration(seconds: 15)'));
      expect(nav, contains('Duration(seconds: 30)'));
      expect(nav, contains('_routeError'),
          reason: 'with nothing drawn there is no navigation — routeError '
              'card with a retry button');
    });
  });

  group('nav view: lifecycle', () {
    test('dispose cancels every timer/sub and releases the coordinator', () {
      final body = bodyOf(nav, 'void dispose() {', maxLen: 700);
      expect(
          body, contains('MapSurfaceCoordinator.instance.release(_mapSurfaceOwner)'));
      expect(body, contains('_gpsWatchdog?.cancel()'));
      expect(body, contains('_offlineRetryTimer?.cancel()'));
      expect(body, contains('_riderLocSub?.cancel()'));
      expect(body, contains('_riderStaleTimer?.cancel()'));
      expect(body, contains('_waitTicker?.cancel()'));
    });

    test('one native surface, claimed under a per-instance owner', () {
      expect(nav, contains("'DriverTripNav-"));
      expect(nav, contains('MapSurfaceCoordinator.instance.acquire('));
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
      ]) {
        expect(l10n, contains('String get $key'),
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
      expect(block, contains("getBool('privacy_location')"));
    });

    test('publishes through the socket relay with the fix capture time', () {
      expect(riderMap, contains('SocketService.sendRiderLocation('));
      expect(riderMap, contains('capturedAtMs'));
    });

    test('stops publishing once the pickup window closes', () {
      expect(riderMap, contains('_stopRiderLocationSharing()'));
      expect(riderMap, contains('_TrackPhase.arriving'));
      expect(riderMap, contains('_TrackPhase.arrived'));
    });
  });

  group('user spec 2026-09-16: chase opening, arrow always on, route bearing',
      () {
    test('the driver arrow is created eagerly at map ready', () {
      final body = bodyOf(nav, 'Future<void> _onMapCreated', maxLen: 1900);
      expect(body, contains('_updateDriverAnnotation()'),
          reason: 'the dot ticker only fires on movement — without the '
              'eager create a parked driver never sees the arrow');
    });

    test('opening and route updates snap to the chase pose, never top-down',
        () {
      final created = bodyOf(nav, 'Future<void> _onMapCreated', maxLen: 1900);
      expect(created, contains('_snapToChasePose();'));
      expect(created, isNot(contains('!_firstGpsFix || _overview')),
          reason: 'the top-down fit on open is gone — it belongs to the '
              'overview toggle only');
      final succeeded =
          bodyOf(nav, 'Future<void> _onRouteFetchSucceeded', maxLen: 2800);
      expect(succeeded, contains('_snapToChasePose();'));
    });

    test('the very first native frame is already tilted down-route', () {
      final body =
          bodyOf(nav, 'cameraOptions: mapbox.CameraOptions(', maxLen: 700);
      expect(body, contains('zoom: _chaseZoomDefault'));
      expect(body, contains('pitch: _chasePitch'));
      expect(body, contains('_routeHeadingFor(widget.initialDriverPos)'));
    });

    test('a parked/crawling driver aims by route tangent, not GPS noise', () {
      expect(nav, contains('double? _routeHeadingFor(LatLng pos)'));
      expect(nav, contains('_speedMps < 1.0'));
      expect(nav, contains('_dot.setBearing(h)'));
      expect(nav, contains('RouteSplice.closestSegmentIndex(pts, pos)'));
    });
  });
}
