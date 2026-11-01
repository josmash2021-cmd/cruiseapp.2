import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the Lyft-style callouts on the driver's map (owner spec
/// 2026-11-01): unclaimed trips on their pickups and the airport markers,
/// as FLUTTER overlays (FlatMapProjection over _markerFrame) — never
/// Mapbox annotations, which cannot morph and leave native handles behind.
void main() {
  String read(String p) => File(p).readAsStringSync();
  final callouts = read('lib/screens/driver/driver_online_callouts.dart');
  final map = read('lib/screens/driver/driver_online_map.dart');
  final widgets = read('lib/screens/driver/driver_online_widgets.dart');
  final screen = read('lib/screens/driver/driver_online_screen.dart');
  final pure = read('lib/map/map_callout.dart');
  final bubble = read('lib/widgets/map/map_callout_bubble.dart');

  String fn(String src, String signature, [int span = 2600]) {
    final i = src.indexOf(signature);
    expect(i, isNonNegative, reason: '$signature missing');
    return src.substring(i, (i + span).clamp(0, src.length));
  }

  test('an overlay glued per camera frame — no annotation manager', () {
    final overlay = fn(callouts, 'Widget _tripCalloutOverlay()');
    expect(overlay, contains('listenable: _markerFrame'));
    expect(overlay, contains('FlatMapProjection.screenOffsetHeading'));
    expect(overlay, contains('MapCalloutBubble('));
    for (final banned in [
      'PointAnnotationManager',
      'createPointAnnotationManager',
      'PointAnnotationOptions',
      'mapbox.',
    ]) {
      expect(callouts.contains(banned), isFalse,
          reason: '$banned: the callouts hold no native handle');
    }
    expect(screen, contains("part 'driver_online_callouts.dart';"));
  });

  test('web guard (Mapbox has no web implementation, rule #23)', () {
    expect(fn(callouts, 'Widget _tripCalloutOverlay()'),
        contains('if (kIsWeb) return const SizedBox.shrink();'));
    expect(fn(callouts, 'bool get _tripCalloutsWanted'), contains('!kIsWeb'));
    expect(fn(map, 'Widget _airportPillOverlay()'),
        contains('if (kIsWeb) return const SizedBox.shrink();'));
  });

  test('searching-only: online, no offer, no preview, no trip / nav', () {
    final wanted = fn(callouts, 'bool get _tripCalloutsWanted', 420);
    for (final cond in [
      '_driverOnline',
      '_phase == _Phase.searching',
      '_pendingOffers.isEmpty',
      '_previewingOffer == null',
      '_acceptedOverlay == null',
      '_mapStyleLoaded',
      '_firstRenderDone',
    ]) {
      expect(wanted, contains(cond), reason: cond);
    }
    expect(fn(callouts, 'Widget _tripCalloutOverlay()'),
        contains('if (!_tripCalloutsWanted) return const SizedBox.shrink();'));
  });

  test('pickup coordinates read null-safe; items without them skipped', () {
    final pickup = fn(pure, 'tripCalloutPickup(Map<String, dynamic> item)', 600);
    expect(pickup, contains("calloutNum(item['pickup_lat'])"));
    expect(pickup, contains("calloutNum(item['pickup_lng'])"));
    expect(pickup.contains(' as num'), isFalse);
    expect(pickup.contains(' as double'), isFalse);
    expect(fn(pure, 'List<TripCallout> buildTripCallouts('),
        contains('if (at == null) continue;'));
  });

  test('an unchanged poll keeps the same list (no needless rebuilds)', () {
    final items = fn(callouts, 'List<TripCallout> _tripCalloutItems(S s)', 800);
    expect(items, contains('identical(st.tripSource, src)'));
    expect(items, contains('sameTripCallouts(st.trips, next)'));
    expect(fn(callouts, 'Widget _tripCalloutOverlay()'),
        contains("ValueKey('trip-callout-\$id')"));
  });

  test('tap opens the EXISTING claim card on that trip — no new claim path',
      () {
    final tap = fn(callouts, 'void _onTripCalloutTap(int tripId)', 600);
    expect(tap, contains('_marketplaceFocusTripId = tripId;'));
    expect(tap, contains('_marketplaceOpen = true;'));
    expect(callouts.contains('claimUnclaimedTrip'), isFalse);
    expect(callouts.contains('_claimTrip('), isFalse);
    expect(widgets, contains('for (final t in _marketplaceTripsOrdered.take(3))'));
    // Trips are tappable; airports stay visual only.
    expect(fn(callouts, 'Widget _tripCalloutOverlay()').contains('IgnorePointer'),
        isFalse);
    expect(fn(callouts, 'Widget _tripCalloutOverlay()'),
        contains('onTap: () => _onTripCalloutTap(id)'));
    final airport = fn(map, 'Widget _airportPillOverlay()', 3800);
    expect(airport, contains('IgnorePointer('));
    expect(airport.contains('onTap'), isFalse);
  });

  test('mounted under the driver marker, airports where the pills were', () {
    final trip = widgets.indexOf('Positioned.fill(child: _tripCalloutOverlay())');
    final marker = widgets.indexOf('if (!_dotOverlayOwnsMarker)');
    expect(trip, isNonNegative);
    expect(trip, lessThan(marker), reason: 'the arrow paints on top');
    expect(widgets, contains('Positioned.fill(child: _airportPillOverlay())'));
  });

  test('one 380 ms controller drives the whole morph', () {
    expect(pure, contains('Duration(milliseconds: 380)'));
    expect(pure, contains('Curves.easeInOutCubic'));
    expect(bubble, contains('SingleTickerProviderStateMixin'));
    expect(bubble, contains('duration: kCalloutMorphDuration'));
    expect('AnimationController('.allMatches(bubble).length, 1);
    expect(bubble.contains('AnimatedSize'), isFalse,
        reason: 'one controller — nothing finishes out of step');
  });

  test('state dies with the screen; the hour timer is cancelled', () {
    expect(screen, contains('_mapCallouts.dispose();'));
    final dispose = fn(callouts, 'void dispose()', 200);
    expect(dispose, contains('airportHourTimer?.cancel();'));
  });

  test('airport count: real, from the overlay, at most once per hour', () {
    final airport = fn(map, 'Widget _airportPillOverlay()', 3800);
    expect(airport, contains('_maybeFetchAirportCounts(drawn)'));
    expect(airport, contains('_mapCallouts.airportTick'));
    expect(callouts, contains('staleCodes('));
    expect(callouts, contains('calloutNextHour(now)'));
    expect(callouts.contains('Timer.periodic'), isFalse,
        reason: 'no 60 s poll — one fetch per local hour');
    expect(read('lib/services/api_service.dart'),
        contains("'\$_baseUrl/drivers/airport-presence'"));
    expect(read('backend/routers/drivers.py'),
        contains('@router.post("/drivers/airport-presence"'));
  });
}
