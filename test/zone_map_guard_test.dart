import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/models/lat_lng.dart';
import 'package:cruise_app/services/zone_service.dart';

/// Guardian for the driver SECTORS (2026-10-12, user spec: the Florida map
/// divided by big sectors like the reference photo — "no de mini ciudad en
/// mini ciudad si no por sectores" — always visible in gray with thick
/// boundaries; dispatch turns a sector gold by demand level with a pill).
void main() {
  final sectorsJson =
      File('backend/static/fl_sectors.json').readAsStringSync();

  test('the state outlines resolve FL/AL points (the fit grouping)', () {
    // 2026-10-14 (user report: "estoy en alabama y la app abre mostrando las
    // zonas de florida"): the zone fit frames the driver's STATE, grouped by
    // the embedded Census outlines — no geocoder, no network.
    expect(ZoneService.stateOfPoint(const LatLng(25.7617, -80.1918)), 'FL',
        reason: 'Miami');
    expect(ZoneService.stateOfPoint(const LatLng(28.5383, -81.3792)), 'FL',
        reason: 'Orlando');
    expect(ZoneService.stateOfPoint(const LatLng(30.6944, -88.0430)), 'AL',
        reason: 'Mobile');
    expect(ZoneService.stateOfPoint(const LatLng(33.5186, -86.8104)), 'AL',
        reason: 'Birmingham');
    expect(ZoneService.stateOfPoint(const LatLng(33.7490, -84.3880)), isNull,
        reason: 'Atlanta is in no served state yet');
    expect(ZoneService.stateOfPoint(const LatLng(30.4213, -87.2169)), 'FL',
        reason: 'Pensacola — the panhandle is FL, not AL');
    // State-scoped fit: with the FL-only baked file, AL gets nothing and a
    // null state gets the union (the fail-open pre-grouping behaviour).
    ZoneService.parseSectors(sectorsJson);
    expect(
        ZoneService.sectorsForState('FL').length, ZoneService.sectors.length);
    expect(ZoneService.sectorsForState('AL'), isEmpty,
        reason: 'no Alabama sectors until dispatch draws them in the panel');
    expect(ZoneService.sectorsForState(null).length,
        ZoneService.sectors.length,
        reason: 'unknown driver state → union fit fallback');
  });

  test('a driver sees and selects only their own state sectors', () {
    // 2026-10-14 spec: "el driver no puede ver las zonas de florida a menos
    // que esté en florida, y viceversa". Fail-open: a state with no sectors
    // of its own (or no GPS fix) sees everything — Alabama keeps working
    // until its first sector is drawn in the panel.
    ZoneService.parseSectors(sectorsJson);
    expect(ZoneService.visibleSectorsFor('FL').length,
        ZoneService.sectors.length);
    expect(ZoneService.visibleSectorsFor('AL').length,
        ZoneService.sectors.length,
        reason: 'fail-open while Alabama has no drawn sectors');
    expect(ZoneService.visibleSectorsFor(null).length,
        ZoneService.sectors.length);

    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('_zoneVisibleIds()'),
        reason: 'per-sector visibility by driver state');
    expect(map, contains('visible && visibleIds.contains(s.id)'),
        reason: 'the other state paints at opacity 0 — no layer churn');
    expect(map, contains('_zoneLookVisibleSig'),
        reason: 'a border crossing repaints the look');
    expect(map, contains('ZoneService.visibleSectorsFor('),
        reason: 'tap selection and the label overlay share the filter');
    final off = File('lib/screens/driver/driver_online_offline.dart')
        .readAsStringSync();
    expect(off, contains('ZoneService.sectorById(_selectedZoneName!)'),
        reason: 'the GO tap clears a stale cross-state pick');
    final scr = File('lib/screens/driver/driver_online_screen.dart')
        .readAsStringSync();
    expect(scr, contains('_zoneLookVisibleSig'));
  });

  test('the baked sectors parse into the big regions', () {
    ZoneService.parseSectors(sectorsJson);
    expect(ZoneService.sectorsReady, isTrue);
    expect(ZoneService.sectors.length, greaterThanOrEqualTo(12));
    final ids = ZoneService.sectors.map((s) => s.id).toSet();
    for (final expected in [
      'sunrise_plantation',
      'ftl_davie',
      'miami_core',
      'kendall',
    ]) {
      expect(ids, contains(expected));
    }
  });

  test('sector ray-casting matches the dissolved boundaries', () {
    ZoneService.parseSectors(sectorsJson);
    // Davie city centre sits inside the Fort Lauderdale / Davie sector.
    final davie =
        ZoneService.sectorContaining(const LatLng(26.076, -80.277));
    expect(davie?.id, 'ftl_davie');
    // Hialeah → Miami Gardens / Hialeah sector.
    expect(
        ZoneService.sectorContaining(const LatLng(25.866939, -80.31336))
            ?.id,
        'miami_gardens');
    // The Atlantic and Birmingham are outside every sector.
    expect(ZoneService.sectorContaining(const LatLng(25.70, -79.90)),
        isNull);
    expect(ZoneService.sectorContaining(const LatLng(33.5186, -86.8104)),
        isNull);
  });

  test('the map draws one SMALL source per sector, gray base, gold heat',
      () {
    final s =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    // Per-sector sources/layers — the single 83 KB all-cities source never
    // materialized on iOS; ~5 KB sources draw (the highlight's size class).
    for (final id in [
      'sec-src-',
      'sec-fill-',
      'sec-line-',
      'sec-shadow-',
      'sec-hl-src',
      'sec-hl-fill',
    ]) {
      expect(s, contains(id), reason: 'sector layer/source $id missing');
    }
    expect(s, contains('ZoneService.sectors'),
        reason: 'layers iterate the baked sectors');
    expect(s, contains('0xFFE8C547'), reason: 'gold heat/selection');
    expect(s, contains('0xFF9AA3B8'), reason: 'gray thick boundary');
    expect(s, contains('lineTranslate'), reason: 'the 3D shadow online');
    expect(s.contains('_zoneLookOnline'), isTrue,
        reason: 'the look flips with the mode');
    // The demand level drives the fill, dispatch-side.
    expect(s, contains('ZoneService.demand[sid]?.level'));
    // Labels/pills are FLUTTER OVERLAYS, never a native text layer
    // (2026-10-11 black-map incident).
    expect(s, isNot(contains('SymbolLayer')),
        reason: 'no native text layer — labels and pills are Flutter');
    expect(s, contains('Widget _zoneLabelOverlay()'));
    expect(s, contains('if (_driverOnline) return const SizedBox.shrink();'),
        reason: 'online keeps only the gray boundary lines');
    expect(s, contains('_phase == _Phase.searching'),
        reason: 'sectors live on the flat searching map only — never on '
            'top of an active trip route');
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains('_zoneLayersReady = false'),
        reason: 'style reloads must recreate the custom sources');
    expect(w, contains('_zoneLabelOverlay()'),
        reason: 'the label/pill layer rides the map stack');
  });

  test('sector data enters through the proven per-sector write path', () {
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(
      map.contains(
          "mapbox.GeoJsonSource(id: 'sec-src-\$sid', data: emptyFc)"),
      isTrue,
      reason: 'each sector source is born EMPTY — inline data never drew',
    );
    expect(map.contains("'sec-src-\$sid'"), isTrue);
    expect(map.contains('zones_src_write_failed'), isTrue,
        reason: 'a silent catch here is what hid the divisions for a week');
    expect(map.contains('sectors_failed'), isTrue);
    expect(map.contains('rethrow') || map.contains('throw StateError'),
        isTrue,
        reason: 'the latch must stay open so the next sync retries');
  });

  test('zone style writes wait for the first render and run batched', () {
    // 2026-10-12 black-map report: ~120 serial awaited style mutations
    // fired during style load starved the render thread — the driver
    // stared at a black map for ~30 s at every boot. The work now waits
    // for the first real render and runs in parallel batches.
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('if (!_firstRenderDone) return;'),
        reason: 'zone sync must wait for the first rendered frame');
    expect(map, contains('Future.wait(['),
        reason: 'style writes batch in parallel, never a serial chain');
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    final idle = RegExp(r'onMapIdleListener: \(_\) \{(.*?)\},\n',
        dotAll: true);
    final block = idle.firstMatch(w)?.group(1) ?? '';
    expect(block, contains('_syncZoneLayers()'),
        reason: 'every idle beat re-triggers the deferred zone sync');
  });

  test('the GO tap gates the connect client-side, fail-open', () {
    final s = File('lib/screens/driver/driver_online_offline.dart')
        .readAsStringSync();
    // 2026-10-14 spec: the gate moved from the FL-only cities file to the
    // SECTORS (one live dataset — the one the panel edits, Florida AND
    // Alabama). The zones kill switch kills the gate with the drawing.
    expect(s, contains('FeatureFlags.zonesMapEnabled'),
        reason: 'the kill switch fails the gate open with the drawing off');
    expect(s, contains('ZoneService.insideSectorCoverage(_pos!)'),
        reason: 'out-of-coverage drivers are never gated — drivers are '
            'state-separated');
    expect(s, contains('ZoneService.sectorContaining(_pos!) == null'));
    expect(s, contains('_showZoneOutsideDialog()'),
        reason: 'outside the coverage the tap explains instead of '
            'connecting');
    expect(s, contains('ZoneService.sectorsReady'),
        reason: 'no data = no gate (fail-open)');
  });

  test('the server enforces the same gate', () {
    final s = File('backend/routers/drivers.py').readAsStringSync();
    expect(s, contains('sector_gate_blocks(db, body.lat, body.lng)'));
    expect(s, contains('"outside_service_area"'));
    // The gate reads the LIVE sector map (app_config), not just the baked
    // file — the panel's Alabama sectors gate from the moment they save.
    final zp = File('backend/services/zone_polygons.py').readAsStringSync();
    expect(zp, contains('fl_sectors_geojson'));
    expect(zp, contains('_TTL_S'), reason: 'the hot PATCH path is cached');
  });

  test('sector drawing has a remote kill switch + the veil a watchdog', () {
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('FeatureFlags.zonesMapEnabled'));
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains('map_veil_watchdog'));
    expect(w, contains('FeatureFlags.load()'));
    final flags =
        File('lib/services/feature_flags.dart').readAsStringSync();
    expect(flags, contains('/feature-flags'));
    final sys = File('backend/routers/system.py').readAsStringSync();
    expect(sys, contains('zones_map_enabled'));
  });

  test('demand heat: poll in the app, endpoints on the server', () {
    final zs = File('lib/services/zone_service.dart').readAsStringSync();
    expect(zs, contains('/zones/demand'));
    expect(zs, contains('class SectorDemand'));
    final scr = File('lib/screens/driver/driver_online_screen.dart')
        .readAsStringSync();
    expect(scr, contains('_zoneDemandTimer'),
        reason: 'the 60 s poll keeps the heat fresh while the map lives');
    expect(scr, contains('_zoneDemandTimer?.cancel()'));
    final sys = File('backend/routers/system.py').readAsStringSync();
    expect(sys, contains('/zones/demand'));
    expect(sys, contains('/admin/zone-demand'),
        reason: 'dispatch sets the heat from the panel');
    expect(sys, contains('_parse_sector_demand'),
        reason: 'malformed rows drop out one by one — never blank the '
            'whole layer');
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
    expect(l10n, contains('zoneBusy'));
    expect(l10n, contains('Ocupado'));
    expect(l10n, contains('zoneVeryBusy'));
    expect(l10n, contains('Muy ocupado'));
  });

  test('tap-to-select ignites the GO; without a zone the GO stays dim', () {
    // 2026-10-11/12 spec: offline the driver taps their sector on the map —
    // the GO ignites with an elastic pop; with no selection the GO is dimmed
    // and the tap explains instead of connecting.
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains('onTapListener: _onZoneMapTap'),
        reason: 'map taps feed the sector picker');
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('void _onZoneMapTap('));
    expect(map, contains('ZoneService.sectorContaining('),
        reason: 'the tap point feeds the sector ray-casting lookup');
    expect(map, contains('_goIgniteCtrl?.forward(from: 0.0)'),
        reason: 'selecting a sector ignites the GO with the elastic pop');
    expect(map, contains('Sector? get _sectorForHighlight'),
        reason: 'the picked sector wins the highlight over the physical one');
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
    expect(ctrl.contains("'_selectedZoneName = null;'"), isFalse,
        reason: '2026-10-12 spec: the pick PERSISTS on connect — it becomes '
            'the working zone the spotlight marks online. Only the offline '
            're-tap toggle clears it (_onZoneMapTap)');
  });

  test('online: heated sectors gold UNDER the roads, no dark spotlight', () {
    // User spec 2026-10-14: "cuando se conecte, ese dorado se colocará
    // debajo del mapa y las líneas estarán encima de ese dorado… todas las
    // zonas con calor" — online, EVERY heated sector keeps its gold fill,
    // the fills live BELOW the road network, and the 2026-10-12 dark
    // spotlight mask is dead.
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('addLayerAt'),
        reason: 'the fills insert at a position, not on top of the style');
    expect(map, contains('mapbox.LayerPosition(below: fillBelowId)'),
        reason: 'gold under the roads');
    expect(map, contains('_zoneRoadAnchor'),
        reason: 'the anchor is the style’s lowest road/tunnel layer');
    expect(map, contains('fill-opacity-transition'),
        reason: 'smooth native transitions on every repaint (same spec: '
            '"se transiciona de forma animada y fluida")');
    expect(map.contains('sec-dim'), isFalse,
        reason: 'the dark spotlight mask is dead');
    expect(map.contains('_writeZoneDim'), isFalse);
    // Heat online: the level no longer force-zeros when online.
    expect(map.contains('visible && !online ? (ZoneService.demand'), isFalse,
        reason: 'heat used to die online — now it paints under the roads');
    expect(map, contains(': 1.0;'),
        reason: 'Muy ocupado = dorado 100% sólido (spec 2026-10-12)');
    // Both mode flips rewrite the zone look immediately (a parked driver
    // gets no GPS fix for minutes).
    final ctrl = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    expect(ctrl, contains('unawaited(_syncZoneLayers());'),
        reason: 'the flip itself syncs — not the next GPS fix');
  });

  test('the working zone survives app restarts (prefs)', () {
    // User spec 2026-10-13: "la zona debe de mantenerse cuando se cierra y
    // se abre la app". The pick is written to prefs on tap and restored at
    // boot (never over a fresh tap of the current session).
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains("p.setString('driver_selected_zone', s.id)"),
        reason: 'the tap persists the pick');
    expect(map, contains("p.remove('driver_selected_zone')"),
        reason: 'the deselect clears it');
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains("prefs.getString('driver_selected_zone')"),
        reason: 'the boot restores the working zone');
    expect(w, contains('ZoneService.sectorById(saved) != null'),
        reason: 'a stale id (edited sectors) never restores garbage');
  });

  test('offline view = home-state zones, free camera, NO auto-recenter', () {
    // User specs 2026-10-13 + 2026-10-14 ("me abre mostrando las zonas de
    // florida estando en alabama — debe abrir donde está el driver"): the
    // camera frames the zones of the DRIVER'S STATE once, then stays free —
    // only the manual FAB recentres (online parity 15.5).
    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('_fitHomeZones('), reason: 'the home-state frame');
    expect(map, contains('_fitSectors(ZoneService.sectorsForState('),
        reason: 'state-scoped sector pick via the embedded outlines');
    expect(map, contains('_offlineZonesFitDone = true'),
        reason: 'one-shot the first time the offline zone view exists');
    expect(map, contains('_offlineZonesRefitPending'),
        reason: 'a boot fit with no fix re-runs state-scoped on the first '
            'real fix');
    final ctrl = File('lib/screens/driver/driver_online_controller.dart')
        .readAsStringSync();
    expect(ctrl, contains('unawaited(_fitHomeZones());'),
        reason: 'the offline flip glides out to the driver-state zones');
    expect(ctrl, contains('_fitHomeZones(at: newLL)'),
        reason: 'the first-fix refit uses the fix itself, not a stale _pos');
    // 2026-10-14 spec: the recenter FAB centres ON THE ARROW at the
    // zone-view zoom — the state-centroid frame died.
    expect(map, contains('_recenterArrowZoneZoom()'),
        reason: 'the FAB centres the arrow, not the state centroid');
    expect(map, contains('zoom: fitCam.zoom'),
        reason: 'the zoom is the state-fit zoom ("con ese zoom mostrando '
            'las zonas")');
    expect(map, contains('_sectorsBBox('),
        reason: 'the bbox union math is shared with the fit');
    expect(ctrl, contains('final zoomTarget = 15.5;'),
        reason: 'chase zoom = street parity everywhere — the home-state fit '
            'owns the offline resting view, the chase only follows at street '
            'zoom');
    const gate = '_driverOnline || !FeatureFlags.zonesMapEnabled';
    final hits = gate.allMatches(map).length + gate.allMatches(ctrl).length;
    expect(hits, greaterThanOrEqualTo(2),
        reason: 'BOTH auto-movers are gated OFF offline+zones: the 10 s '
            'auto-refollow (_autoRecenterEnabled) and the late-GPS-fix '
            'camera flight');
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

  test('the boot refresh never clobbers newer cached sectors', () {
    // 2026-10-13 (user report: "cierro la app y las zonas salen diferentes
    // al dispatch"): with a cache in hand, loadSectors() refreshed from the
    // STATIC file — the baked seed — and overwrote the newer panel-edited
    // sectors on every cold start. The versioned endpoint is now the only
    // refresh once a cache exists; the static file is just the first seed.
    final zs = File('lib/services/zone_service.dart').readAsStringSync();
    final load = RegExp(r'static Future<void> loadSectors\(\) async \{(.*?)\n  \}',
        dotAll: true);
    final body = load.firstMatch(zs)?.group(1) ?? '';
    expect(body, isNotEmpty);
    expect(body.indexOf('unawaited(refreshSectorsFromServer())'),
        lessThan(body.indexOf('_refreshSectorsFromNetwork()')),
        reason: 'cached path refreshes via /zones/sectors; the static file '
            'is only the first-ever seed');
    expect(zs, contains('_sectorVersionCacheKey'));
  });

  test('live boundary refresh: socket wake-up, REST truth, animated swap',
      () {
    // 2026-10-13, user spec: "instantáneo, que se dibuje de forma animada
    // trasladándose en el mapa, sin cerrar la app". The socket event is only
    // a wake-up — the truth re-downloads by REST, exactly like the
    // app-update gate.
    final sock =
        File('lib/services/socket_service.dart').readAsStringSync();
    expect(sock, contains("_socket!.on('zones_updated'"),
        reason: 'the socket wake-up is wired');
    expect(sock, contains('zonesUpdatedStream'));
    expect(sock, contains('_zonesUpdatedController'));

    final zs = File('lib/services/zone_service.dart').readAsStringSync();
    expect(zs, contains('static int sectorsVersion = 0;'));
    expect(zs, contains('ValueNotifier<int> sectorsChanged'),
        reason: 'the map reacts to a real sector change');
    expect(zs, contains('refreshSectorsFromServer()'));
    expect(zs, contains('/zones/sectors'),
        reason: 'the live truth comes from the REST endpoint');
    expect(zs, contains("data['sectors_version']"),
        reason: 'the demand poll is the fallback when the socket is dead');
    expect(zs, contains('watchZoneUpdates()'));
    expect(zs, contains('SocketService.zonesUpdatedStream.listen'),
        reason: 'the wake-up re-downloads — the payload is never trusted');
    expect(zs, contains('_sectorCacheKey'),
        reason: 'the refreshed body mirrors into the same cache key');

    final map =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    expect(map, contains('void _onSectorsChanged()'));
    expect(map, contains('Future<void> _animateZoneSwap()'));
    expect(map, contains('removeStyleLayer('),
        reason: 'sectors that no longer exist leave the style');
    expect(map, contains('removeStyleSource('));
    expect(map, contains('_zoneSectorIds'),
        reason: 'the swap reconciles against the ids on the style');
    expect(map, contains("_syncZoneLayers(forceHighlight: true)"),
        reason: 'no layers yet → the normal sync creates them, no '
            'animation');
    expect(map, contains('zones_swap'),
        reason: 'a failed reconciliation lands in the server log');
    final scr = File('lib/screens/driver/driver_online_screen.dart')
        .readAsStringSync();
    expect(scr, contains('ZoneService.sectorsChanged.addListener(_onSectorsChanged)'));
    expect(scr,
        contains('ZoneService.sectorsChanged.removeListener(_onSectorsChanged)'),
        reason: 'the listener dies with the screen');
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains('_zoneSectorIds = []'),
        reason: 'a style reload wipes the tracking list with the layers');
  });
}
