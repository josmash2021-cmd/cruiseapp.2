import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/services/zone_service.dart';

/// Guardian for the municipal city zones (2026-10-11, user spec: the
/// Florida map divided by real city boundaries like the photo — "si el
/// driver está dentro del cuadro podrá conectarse").
void main() {
  final zonesJson =
      File('backend/static/fl_zones.json').readAsStringSync();

  test('the baked data parses into real zones', () {
    ZoneService.parse(zonesJson);
    expect(ZoneService.ready, isTrue);
    expect(ZoneService.zones.length, greaterThanOrEqualTo(35));
    final names = ZoneService.zones.map((z) => z.name).toSet();
    for (final expected in ['Hialeah', 'Miami', 'Miami Beach', 'Doral']) {
      expect(names, contains(expected));
    }
  });

  test('ray-casting matches the real boundaries', () {
    ZoneService.parse(zonesJson);
    // Hialeah's baked centroid is inside its polygon.
    final hialeah = ZoneService.zoneContaining(
        const LatLng(25.866939, -80.31336));
    expect(hialeah?.name, 'Hialeah');
    // The Atlantic and Birmingham are outside every zone.
    expect(ZoneService.zoneContaining(const LatLng(25.70, -79.90)), isNull);
    expect(
        ZoneService.zoneContaining(const LatLng(33.5186, -86.8104)), isNull);
  });

  test('the map draws the spec look: gold fills offline, gray 3D lines', () {
    final s =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    for (final id in [
      'zones-src',
      'zones-hl-src',
      'zones-fill',
      'zones-line',
      'zones-hl-fill',
      'zones-shadow',
    ]) {
      expect(s, contains(id), reason: 'layer/source $id missing');
    }
    // 2026-10-11 spec: fills are GOLD semi-transparent (never red), the
    // boundary is a thick GRAY line, and online keeps ONLY the boundary with
    // its shadow under it (the 3D read).
    expect(s, contains('0xFFE8C547'), reason: 'gold fills');
    expect(s, isNot(contains('0xFF7A2020')), reason: 'red died');
    expect(s, contains('0xFF9AA3B8'), reason: 'gray thick boundary');
    expect(s, contains('lineTranslate'), reason: 'the 3D shadow under it');
    expect(s.contains('_zoneLookOnline'), isTrue,
        reason: 'the look flips with the mode');
    // The "FL: <city>" label is a FLUTTER OVERLAY, never a native text
    // layer (2026-10-11 black-map incident), and it hides while online.
    expect(s, isNot(contains('SymbolLayer')),
        reason: 'no native text layer — the label is a Flutter overlay');
    expect(s, contains('Widget _zoneLabelOverlay()'));
    expect(s, contains('if (_driverOnline) return const SizedBox.shrink();'),
        reason: 'online keeps only the gray line');
    expect(s, contains("'FL: \$name'"), reason: 'the photo label');
    expect(s, contains('_phase == _Phase.searching'),
        reason: 'zones live on the flat searching map only — never on top '
            'of an active trip route');
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains('_zoneLayersReady = false'),
        reason: 'style reloads must recreate the custom sources');
    expect(w, contains('_zoneLabelOverlay()'),
        reason: 'the label rides the map stack');
  });

  test('the GO tap gates the connect client-side, fail-open', () {
    final s = File('lib/screens/driver/driver_online_offline.dart')
        .readAsStringSync();
    expect(s, contains('ZoneService.insideCoverageArea(_pos!)'),
        reason: 'out-of-state drivers are never gated by a Florida file — '
            'drivers are state-separated');
    expect(s, contains('ZoneService.zoneContaining(_pos!) == null'));
    expect(s, contains('_showZoneOutsideDialog()'),
        reason: 'outside a zone the tap explains instead of connecting');
    expect(s, contains('ZoneService.ready'),
        reason: 'no data = no gate (fail-open)');
  });

  test('the server enforces the same gate', () {
    final s = File('backend/routers/drivers.py').readAsStringSync();
    expect(s, contains('zone_containing(body.lat, body.lng)'));
    expect(s, contains('"outside_service_area"'));
  });

  test('zone drawing has a remote kill switch + the veil a watchdog', () {
    // 2026-10-11 black-map report: the zone layers ride behind
    // zones_map_enabled (default OFF until verified on a real device), and
    // the snapshot veil lifts itself after 6 s no matter what.
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('FeatureFlags.zonesMapEnabled'));
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains('veil watchdog fired'));
    expect(w, contains('FeatureFlags.load()'));
    final flags =
        File('lib/services/feature_flags.dart').readAsStringSync();
    expect(flags, contains('/feature-flags'));
    final sys = File('backend/routers/system.py').readAsStringSync();
    expect(sys, contains('zones_map_enabled'));
  });

  test('zone data rides the proven write path, not inline addSource', () {
    // 2026-10-11 (user report: only the highlighted zone painted — no other
    // city, no gray boundary): the source built with all 42 geometries
    // inline never materialized on iOS, while the highlight — born empty
    // and fed via setStyleSourceProperty — drew fine. ALL data now enters
    // through that same proven path, and a failed write keeps the latch
    // open (retry on the next sync) and reports to the server log.
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(
      map.contains(
          "addSource(mapbox.GeoJsonSource(id: 'zones-src', data: emptyFc))"),
      isTrue,
      reason: 'the base source must be born EMPTY — inline data never drew',
    );
    expect(
      map.contains("setStyleSourceProperty('zones-src', 'data', allFc)"),
      isTrue,
    );
    expect(map.contains('zones_src_write_failed'), isTrue,
        reason: 'a silent catch here is what hid the missing divisions');
    expect(map.contains('rethrow;'), isTrue,
        reason: 'the latch must stay open so the next sync retries');
  });

  test('the camera is born at the region view offline and glides on flips',
      () {
    // 2026-10-11 (user report: the app opens zoomed-in instead of the
    // region view, and mode flips jump instead of gliding). The entry ease
    // only runs while the ticker ticks, and the ticker parks for a parked
    // offline driver — so offline the camera is BORN at 10.8, and the flips
    // carry an explicit ease/flight.
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains('zoom: (!_driverOnline && FeatureFlags.zonesMapEnabled)'),
        reason: 'offline + zones: the map is born at the region view');
    expect(w, contains('_zoomEaseDone = true;'),
        reason: 'a camera born at the target must not ease back to 16');
    final ctrl = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    expect(ctrl, contains('_zoomEaseFrom'),
        reason: 'the entry ease origin is the live camera zoom, not a '
            'hardcoded 16 — mode flips glide instead of jumping');
    expect(
        ctrl, contains('zoom = _zoomEaseFrom - (_zoomEaseFrom - zoomTarget) * e;'));
    final scr = File('lib/screens/driver/driver_online_screen.dart')
        .readAsStringSync();
    expect(scr, contains('double _zoomEaseFrom = 16.0;'));
  });

  test('the offline recenter proves it landed — or writes the camera dry',
      () {
    // 2026-10-11: prod breadcrumb showed recenter_fired=true with the camera
    // never moving. One beat after the flight, the actual camera state is
    // compared; a miss writes the camera directly and both outcomes land in
    // the server log.
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('recenter_settle'));
    expect(map, contains('lastPan.isAfter(tapAt)'),
        reason: 'a fresh grab must abort the settle — never fight the finger');
    expect(map, contains('.setCamera(mapbox.CameraOptions('),
        reason: 'the dry write is the guaranteed landing');
  });

  test('user-facing strings exist in ES and EN', () {
    final l10n =
        File('lib/l10n/app_localizations.dart').readAsStringSync();
    expect(l10n, contains('zoneOutsideTitle'));
    expect(l10n, contains('zoneOutsideBody'));
    expect(l10n, contains('Fuera del área de servicio'));
    expect(l10n, contains('Outside the service area'));
    expect(l10n, contains('zoneSelectHint'));
    expect(l10n, contains('Selecciona tu zona en el mapa para conectarte'));
    expect(l10n, contains('Select your zone on the map to go online'));
  });

  test('tap-to-select ignites the GO; without a zone the GO stays dim', () {
    // 2026-10-11 spec: offline the driver taps their zone on the map — the
    // GO ignites with an elastic pop; with no selection the GO is dimmed
    // and the tap explains instead of connecting.
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains('onTapListener: _onZoneMapTap'),
        reason: 'map taps feed the zone picker');
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('void _onZoneMapTap('));
    expect(map, contains('coords.lat.toDouble()'),
        reason: 'the tap point feeds the ray-casting lookup');
    expect(map, contains('_goIgniteCtrl?.forward(from: 0.0)'),
        reason: 'selecting a zone ignites the GO with the elastic pop');
    expect(map, contains('Zone? get _zoneForHighlight'),
        reason: 'the picked zone wins the highlight over the physical one');
    final scr = File('lib/screens/driver/driver_online_screen.dart')
        .readAsStringSync();
    expect(scr, contains('String? _selectedZoneName;'));
    expect(scr, contains('_goIgniteCtrl?.dispose()'));
    final off = File('lib/screens/driver/driver_online_offline.dart')
        .readAsStringSync();
    expect(off, contains('S.of(context).zoneSelectHint'),
        reason: 'a dim GO explains itself instead of connecting');
    expect(off, contains('scale: igniteScale'));
    final ctrl = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    expect(ctrl, contains('_selectedZoneName = null;'),
        reason: 'the pick is consumed on connect — the next session starts '
            'fresh');
  });
}
