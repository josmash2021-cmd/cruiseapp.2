import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-02: "minimizar los gastos al máximo". Every guard below is
/// a paid call that used to fire far more often than anything on screen
/// needed (audit of every Mapbox call site in lib/).
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('routes: Mapbox alone first; Google and OSRM only if it fails', () {
    final svc = read('lib/services/directions_service.dart');
    expect(svc, isNot(contains('Future.wait([googleFuture, osrmFuture, mapboxFuture])')),
        reason: 'the three-way race bought a Google traffic route that was '
            'thrown away whenever Mapbox answered');
    final at = svc.indexOf('var mapbox = await _requestMapboxRoute(');
    expect(at, isNonNegative);
    expect(svc.indexOf('if (mapbox == null) {', at), greaterThan(at));
  });

  test('the rider re-asks for the route less often', () {
    final rt = read('lib/controllers/rider_tracking_controller.dart');
    expect(rt, contains('Timer.periodic(const Duration(minutes: 3), (_) => _refreshTraffic());'));
    final cp = read('lib/screens/rider_confirm_pickup_screen.dart');
    expect(cp, contains('inSeconds < 45) return;'));
  });

  test('no dead offer still fetching two routes per offer card', () {
    final w = read('lib/screens/driver/driver_online_widgets.dart');
    expect(w, isNot(contains('_buildOfferMapUrl')));
    expect(read('lib/screens/driver/driver_online_screen.dart'),
        isNot(contains('_offerMapUrlCache')));
  });

  test('the rating backdrops are one still per screen, not per keyboard frame',
      () {
    for (final p in [
      'lib/screens/rider_rating_screen.dart',
      'lib/screens/driver/driver_rate_rider_screen.dart',
    ]) {
      expect(read(p), contains('height: MediaQuery.sizeOf(context).height,'),
          reason: p);
    }
    expect(read('lib/widgets/static_route_preview.dart'),
        contains('if (box.maxHeight < 24 || box.maxWidth < 24) {'),
        reason: 'a collapsed card buys no still');
  });
}
