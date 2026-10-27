import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard-pin for the compiled Dispatch /mapa screen. The React source lives
/// outside this repo; a panel rebuild must re-apply the behavior pinned here.
void main() {
  final assets = Directory('backend/dispatch_panel/assets');
  final chunk = assets
      .listSync()
      .whereType<File>()
      .where((file) => file.path.endsWith('.js'))
      .map((file) => file.readAsStringSync().replaceAll('\r\n', '\n'))
      .firstWhere(
        (source) => RegExp(
          r'export\s*\{[^}]*\bas\s+MapaScreen\s*\}',
        ).hasMatch(source),
        orElse: () => '',
      );
  final compact = chunk.replaceAll(RegExp(r'\s+'), '');

  test('the MapaScreen chunk uses only Dispatch session endpoints', () {
    expect(chunk, isNotEmpty,
        reason:
            'find the chunk by its MapaScreen export, never by bundle hash');
    expect(chunk, contains('guard-pin panel_live_map_guard_test'));
    expect(chunk, contains('W as apiGet'),
        reason: 'W supplies the Dispatch cookie session, timeout and retries');
    for (final endpoint in [
      '/admin/drivers/online',
      '/admin/trips/active',
      '/admin/zones/sectors',
    ]) {
      expect(chunk, contains('"$endpoint"'));
    }
    expect(
        chunk,
        contains(
            '`/admin/drivers/\${encodeURIComponent(selectedDriverId)}/active-trip`'));
    expect(chunk, isNot(contains('useFleetDrivers')),
        reason: '/mapa must not read the Firestore fleet hook');
    expect(chunk, isNot(contains('vendor-firebase')));
    expect(chunk, isNot(contains('DISPATCH_API_KEY')));
    expect(chunk, isNot(contains('HMAC')));
  });

  test('live polling is visible-only, serialized, abortable and latest-wins',
      () {
    expect(chunk, contains('const POLL_INTERVAL_MS = 20000'));
    expect(chunk, contains('setTimeout(loadLive, POLL_INTERVAL_MS)'),
        reason:
            'schedule after completion, never overlapping setInterval polls');
    expect(chunk, isNot(contains('setInterval(')));
    expect(chunk, contains('document.visibilityState !== "visible"'));
    expect(
        chunk,
        contains(
            'document.addEventListener("visibilitychange", handleVisibilityChange)'));
    expect(
        chunk,
        contains(
            'document.removeEventListener("visibilitychange", handleVisibilityChange)'));
    expect(chunk, contains('new AbortController()'));
    expect(chunk, contains('sequence !== requestSequence'));
    expect(chunk, contains('liveController?.abort()'));
    expect(chunk, contains('clearTimeout(pollTimer)'));
    expect(chunk, contains('}, [refreshKey]);'),
        reason: 'the polling effect is not recreated by data renders');
    expect(chunk, contains('setRefreshKey((value) => value + 1)'),
        reason: 'the visible error state has a real retry action');
  });

  test('driver-only polling stays at 2s and does not refresh trip detail', () {
    expect(chunk, contains('const DRIVER_POLL_INTERVAL_MS = 2000'));
    expect(chunk, contains('setTimeout(loadDrivers, DRIVER_POLL_INTERVAL_MS)'));
    expect(chunk, contains('driverController?.abort()'));
    expect(chunk, contains('sequence !== driverSequence'));
    expect(chunk, contains('clearTimeout(driverPollTimer)'));
    final start = chunk.indexOf('async function loadDrivers()');
    final end = chunk.indexOf('async function loadLive()', start);
    final loader = chunk.substring(start, end);
    expect(loader, contains('setSnapshot((previous) => ({ ...previous, drivers }))'));
    expect(loader, isNot(contains('revision')),
        reason: 'a GPS refresh must not re-request the selected active trip');
    expect(chunk, isNot(contains('setInterval(')));
  });

  test('driver markers interpolate per frame and accept only fresh targets', () {
    for (final needle in [
      'function nextDriverMotion(',
      'function motionPosition(',
      'function isStaleDriverUpdate(',
      'existing.motion = nextDriverMotion(',
      'requestAnimationFrame(animate)',
      'cancelAnimationFrame(frameId)',
      'performance.now()',
      'document.addEventListener("visibilitychange", handleAnimationVisibility)',
      'document.removeEventListener("visibilitychange", handleAnimationVisibility)',
    ]) {
      expect(chunk, contains(needle), reason: '$needle missing');
    }
    expect(chunk, isNot(contains('existing.marker.setLngLat(driver.position)')),
        reason: 'existing markers move through their motion state, never teleport');
    final signature = chunk.substring(
      chunk.indexOf('const fitSignature = ['),
      chunk.indexOf('].join("|");', chunk.indexOf('const fitSignature = [')),
    );
    expect(signature, isNot(contains('selectedDriver.position')));
  });

  test('real motion helpers land exactly and never jerk or overshoot', () async {
    final helpers = chunk.substring(
      chunk.indexOf('function samePosition'),
      chunk.indexOf('function updateDriverElement'),
    );
    final result = await Process.run('node', ['-e', '''
const DRIVER_POLL_INTERVAL_MS = 2000;
function validCoordinatePair(value) {
  return Array.isArray(value) && value.length >= 2 &&
    Number.isFinite(value[0]) && Number.isFinite(value[1]);
}
$helpers
const assert = require('node:assert/strict');
function assertClose(actual, expected) {
  assert.equal(actual.length, expected.length);
  actual.forEach((value, index) => {
    assert.ok(Math.abs(value - expected[index]) < 1e-9);
  });
}
const idle = nextDriverMotion(null, [-80, 25], 0);
assert.deepEqual(motionPosition(idle, 0), [-80, 25]);
const moving = nextDriverMotion(idle, [-79.99, 25.01], 0);
assertClose(motionPosition(moving, 1000), [-79.995, 25.005]);
assert.deepEqual(motionPosition(moving, 2000), [-79.99, 25.01]);
assert.deepEqual(motionPosition(moving, 4000), [-79.99, 25.01]);
const middle = motionPosition(moving, 1000);
const retargeted = nextDriverMotion(moving, [-79.98, 25.02], 1000);
assert.deepEqual(retargeted.from, middle);
assert.deepEqual(motionPosition(retargeted, 1000), middle);
assert.equal(nextDriverMotion(retargeted, retargeted.target, 2000), retargeted);
assert.equal(isStaleDriverUpdate('2026-10-27T10:00:02Z', '2026-10-27T10:00:01Z'), true);
assert.equal(isStaleDriverUpdate('2026-10-27T10:00:01Z', '2026-10-27T10:00:02Z'), false);
console.log('motion helpers ok');
''']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect(result.stdout, contains('motion helpers ok'));
  });

  test('riders come only from active trips and markers stay at pickup', () {
    expect(chunk, contains('function normalizeTrips(payload)'));
    expect(chunk, contains('INACTIVE_TRIP_STATUSES'));
    for (final status in ['completed', 'cancelled', 'canceled', 'scheduled']) {
      expect(chunk, contains('"$status"'));
    }
    expect(chunk, isNot(contains('"scheduled_active"')),
        reason: 'scheduled_active is approach to pickup, not rider onboard');
    expect(chunk,
        contains('trips.filter((trip) => trip.pickup.position !== null)'),
        reason: 'null pickup coordinates produce no marker and do not crash');
    expect(chunk, contains('!trip.hasDriver'));
    expect(chunk, contains('Esperando conductor'));
    expect(chunk, contains('Asignado · en camino'));
    expect(chunk, contains('En viaje'));
    expect(chunk, isNot(contains('trip.driver.position')),
        reason: 'rider markers are pickup points, never live GPS relays');
    expect(chunk, contains('children: "Riders"'));
  });

  test('zones are a toggleable GeoJSON layer below routes and DOM markers', () {
    expect(chunk, contains('const ZONES_SOURCE = "mapa-zones"'));
    expect(chunk, contains('const ZONES_FILL_LAYER = "mapa-zones-fill"'));
    expect(chunk, contains('const ZONES_LINE_LAYER = "mapa-zones-line"'));
    expect(chunk, contains('map.addSource(ZONES_SOURCE'));
    expect(chunk, contains('source.setData(snapshot.zones)'));
    expect(chunk, contains('showZones ? "visible" : "none"'));
    expect(chunk, contains('children: "Zonas"'));
    expect(chunk, contains('beforeLabels'),
        reason:
            'zone polygons stay below map labels; DOM markers stay above canvas');
    expect(chunk.indexOf('map.addSource(ZONES_SOURCE'),
        lessThan(chunk.indexOf('map.addSource(ROUTE_SOURCE')),
        reason: 'zones are installed below the selected-trip route');
  });

  test('driver focus hides peers, keeps rider toggle and restores overview',
      () {
    expect(
        chunk,
        contains(
            'positionedDrivers.filter((driver) => driver.id === selectedDriverId)'),
        reason: 'a selected driver is the only driver marker left visible');
    expect(chunk,
        contains('const visibleTrips = showRiders ? positionedTrips : [];'),
        reason: 'driver focus must not change the independent Riders layer');
    expect(chunk, contains('closePopup();'));
    expect(chunk, contains('overviewCameraRef.current = {'));
    expect(chunk, contains('center: map.getCenter().toArray()'));
    expect(
        chunk, contains('mapRef.current.flyTo({ ...camera, duration: 700 })'),
        reason:
            'Mostrar todos restores the pre-focus camera, not a new data fit');
    expect(chunk, contains('children: "Mostrar todos"'));
    expect(chunk, contains('children: "Conductores"'));
  });

  test('active-trip detail is latest-wins and removes ended-trip ghosts', () {
    expect(chunk, contains('detailSequenceRef'));
    expect(chunk, contains('sequence !== detailSequenceRef.current'));
    expect(chunk, contains('return () => controller.abort()'));
    expect(chunk, contains('previousTripEnded'));
    expect(chunk, contains('route: previousTripEnded ? null : previous.route'));
    expect(chunk, contains('trip: previousTripEnded ? null : previous.trip'));
    expect(chunk, contains('Sin viaje activo'));
    expect(chunk, contains('Ruta no disponible'));
    expect(chunk, contains('route_unavailable'));
    expect(chunk, contains('setDetailRetry((value) => value + 1)'));
  });

  test('only real backend LineStrings are drawn, with phase-correct styling',
      () {
    expect(chunk, contains('function sanitizeRoute(route)'));
    expect(chunk, contains('route?.type !== "FeatureCollection"'));
    expect(chunk, contains('geometry?.type !== "LineString"'));
    expect(chunk, contains('coordinates.every(validCoordinatePair)'));
    expect(chunk, contains('const route = sanitizeRoute(payload.route)'),
        reason:
            'the route source is the active-trip payload, not fabricated geometry');
    expect(chunk, contains('route: routeAvailable ? route : null'));
    expect(chunk, contains('source.setData(route ?? emptyFeatureCollection())'),
        reason:
            'missing/failed route empties the layer; there is no straight-line fallback');
    expect(chunk, contains('filter: ["==", ["get", "leg"], "approach"]'));
    expect(chunk, contains('filter: ["==", ["get", "leg"], "trip"]'));
    expect(chunk, contains('inTrip ? "none" : "visible"'),
        reason: 'the approach leg disappears during the trip');
    expect(chunk, contains('inTrip ? 0.96 : 0.26'),
        reason:
            'trip is muted before pickup and gold/prominent during the trip');
    expect(chunk, contains('syncPinMarker(map, pickupPinRef'));
    expect(chunk, contains('dropoffPinRef'));
  });

  test('Florida/Alabama/Both start with combined bounds and explicit fits only',
      () {
    expect(compact, contains('both:[[-88.47,24.45],[-79.87,35.01],]'));
    expect(compact, contains('florida:[[-87.63,24.45],[-79.87,31],]'));
    expect(compact, contains('alabama:[[-88.47,30.22],[-84.89,35.01],]'));
    expect(chunk, contains('React.useState("both")'));
    expect(chunk, contains('fitStateBounds(map, stateModeRef.current, 0)'),
        reason: 'the initial camera fits FL+AL once on map load');
    expect(
        chunk,
        contains(
            'if (mapReady && mapRef.current) fitStateBounds(mapRef.current, mode);'),
        reason: 'state changes fit only on the explicit button action');
    expect(chunk, isNot(contains('33.5186')),
        reason: 'the old fixed Birmingham camera is gone');
    expect(chunk, isNot(matches(RegExp(r'zoom:\s*12'))));

    final start = chunk.indexOf('const fitSignature = [');
    final end = chunk.indexOf('].join("|");', start);
    expect(start, greaterThan(-1));
    expect(end, greaterThan(start));
    final signature = chunk.substring(start, end);
    expect(signature, contains('trip.id'));
    expect(signature, contains('trip.phase.key'));
    expect(signature, contains('routePresence'));
    expect(signature, isNot(contains('revision')),
        reason: 'a 20-second poll must never re-fit the selected route');
    expect(signature, isNot(contains('selectedDriver.position')),
        reason: 'GPS movement updates markers/route without moving the camera');
  });

  test('popups use safe DOM text and all resources have disposal paths', () {
    expect(chunk, contains('document.createElement("button")'),
        reason: 'markers are keyboard-accessible native buttons');
    expect(chunk, contains('line.textContent = text'));
    expect(chunk, contains('setDOMContent(buildRiderPopup(trip))'));
    expect(chunk, isNot(contains('innerHTML')));
    expect(chunk, isNot(contains('dangerouslySetInnerHTML')));
    expect(
        chunk,
        contains(
            'entry.element.removeEventListener("click", entry.clickHandler)'));
    expect(chunk, contains('removeMapSourcesAndLayers(map)'));
    expect(chunk, contains('map.off("load", handleLoad)'));
    expect(chunk, contains('resizeObserver?.disconnect()'));
    expect(chunk, contains('map.remove()'));
    expect(chunk, contains('"aria-pressed": active'));
    expect(chunk, contains('containerWidth < 768'));
    expect(chunk, contains('maxHeight: "48vh"'));
    expect(chunk, contains('width: 360'),
        reason: 'responsive card geometry is inline because the compiled CSS '
            'does not contain newly invented Tailwind selectors');
    expect(chunk, contains('Cargando mapa…'));
    expect(chunk, contains('Sin actividad en el mapa'));
    expect(chunk, contains('No se pudieron cargar los datos del mapa'));
  });
}
