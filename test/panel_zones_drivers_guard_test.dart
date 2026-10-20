import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the drivers layer on the Zonas page (user spec 2026-10-18:
/// "en zonas ver dónde están ubicados cada uno seleccionando por ciudad o
/// varias ciudades", ambas vistas con toggle: GPS en vivo + ciudad de
/// trabajo). The panel is a compiled bundle whose React source lives
/// outside this repo — the guard-pin comment is what the next rebuild must
/// re-apply. Backend: GET /admin/driver-locations (dispatch key), with the
/// in-memory TTL overlay winning over the throttled users.lat/lng columns.
void main() {
  final assets = Directory('backend/dispatch_panel/assets');
  final chunk = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('guard-pin panel_zones_drivers_guard_test'),
          orElse: () => '');
  final adminPy =
      File('backend/routers/admin.py').readAsStringSync();

  test('the endpoint exists behind the dispatch key', () {
    expect(adminPy, contains('"/admin/driver-locations"'));
    expect(adminPy, contains('_driver_locations.get(u.id)'),
        reason: 'the in-memory heartbeat overlay wins over the columns');
    expect(adminPy, contains('us_city_centers.json'),
        reason: 'city bubbles anchor to the GeoNames city coordinates — '
            'prod had GPS for only 5 of 194 drivers, position-only bubbles '
            'showed nothing (2026-10-18)');
    final centers = File('backend/geo/us_city_centers.json')
        .readAsStringSync();
    expect(centers, contains('"FL|Miami"'));
  });

  test('the Zonas chunk carries the drivers layer', () {
    expect(chunk, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(chunk, contains('"/admin/driver-locations"'),
        reason: 'the page polls the new endpoint');
    expect(chunk, contains('drvCenters'),
        reason: 'city bubbles prefer the GeoNames city center over the '
            'average of the few positioned drivers');
    expect(chunk, contains('setInterval'), reason: 'live refresh');
    expect(chunk, contains('document.visibilityState'),
        reason: 'the poll pauses on a hidden tab');
    for (final id in ['drv-pos', 'drv-dots', 'drv-cities', 'drv-bubbles']) {
      expect(chunk, contains(id), reason: 'map source/layer $id exists');
    }
  });

  test('toggle GPS / ciudad de trabajo and multi-city selection', () {
    expect(chunk, contains('GPS en vivo'));
    expect(chunk, contains('Ciudad de trabajo'));
    expect(chunk, contains('drvSel.has(k)'),
        reason: 'chips toggle membership in the selection Set');
    expect(chunk, contains('nx.add(k)'),
        reason: 'several cities can be active at once');
    expect(chunk, contains('drvSel.size===0?drvRows'),
        reason: 'an empty selection means every city');
    expect(chunk, contains('fitBounds'),
        reason: 'selecting cities zooms the map to them ("con exactitud")');
    expect(chunk, contains('maxZoom:14'));
  });

  test('popups escape user-controlled fields', () {
    expect(chunk, contains('drvEsc'),
        reason: 'driver name/photo/city go through the HTML escaper — '
            'names are user-controlled');
    expect(chunk, contains('En línea ahora'));
    expect(chunk, contains('Última posición'),
        reason: 'offline drivers are labelled as last known position, '
            'never as live');
  });
}
