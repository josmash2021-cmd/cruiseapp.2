import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the drivers layer on the Zonas page (user spec 2026-10-18:
/// "en zonas ver dónde están ubicados cada uno seleccionando por ciudad o
/// varias ciudades", ambas vistas con toggle: GPS en vivo + ciudad de
/// trabajo; 2026-10-22 spec: the state/city chips move OFF the map into a
/// collapsible LEFT side panel with per-state submenus, and a 4th "Lista de
/// espera" view lists waitlisted drivers in that same panel). The panel is
/// a compiled bundle whose React source lives outside this repo — the
/// guard-pin comment is what the next rebuild must re-apply. Backend:
/// GET /admin/driver-locations (dispatch key), with the in-memory TTL
/// overlay winning over the throttled users.lat/lng columns.
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
    expect(adminPy, contains('zone_counts'),
        reason: 'per-sector driver counts feed the zone choropleth '
            '(2026-10-18 spec: "en qué zona hay más drivers")');
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
    expect(chunk, contains('drvZones'),
        reason: 'the zone choropleth reads the per-sector counts');
    expect(chunk, contains('setInterval'), reason: 'live refresh');
    expect(chunk, contains('document.visibilityState'),
        reason: 'the poll pauses on a hidden tab');
    for (final id in ['drv-pos', 'drv-dots', 'drv-cities', 'drv-bubbles']) {
      expect(chunk, contains(id), reason: 'map source/layer $id exists');
    }
  });

  test('the concentration view is the default and needs no GPS', () {
    expect(chunk, contains('useState("heat")'),
        reason: 'Concentración is the default view (2026-10-18 spec: "no '
            'quiero ver el punto verde — quiero ver dónde hay más")');
    expect(chunk, contains('Concentración'));
    expect(chunk, contains('"drv-heat-layer"'),
        reason: 'heatmap weighted by roster city counts — covers all 194 '
            'drivers via their work city, not only the 5 with GPS');
    expect(chunk, contains('"zonas-fill-heat"'),
        reason: 'zones fill by driver count (choropleth)');
    expect(chunk, contains('"zonas-count-labels"'),
        reason: 'each zone shows its driver count');
    expect(chunk, contains('"heatmap-color"'));
    expect(chunk, contains('serialize()'),
        reason: 'zone polygons are read back from the zonas-areas source');
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

  test('the state/city chips live in a collapsible LEFT side panel', () {
    expect(chunk, contains('[drvPanel,setDrvPanel]=c.useState(!0)'),
        reason: 'the side panel is collapsible (2026-10-22 spec: the chips '
            'cloud covered the whole map)');
    expect(chunk, contains('Ocultar'),
        reason: 'collapse button of the drivers side panel');
    expect(chunk, contains('[drvExpanded,setDrvExpanded]=c.useState(new Set)'),
        reason: 'each state header opens a submenu with its city chips');
    expect(chunk, contains('drvExpanded.has(g.sk)'),
        reason: 'the city chips render inside the expanded state submenu');
    expect(chunk, contains('Limpiar filtro'),
        reason: 'the panel can clear the multi-city selection');
    expect(chunk, isNot(contains('max-h-28')),
        reason: 'the chips overlay ON the map is gone — the map stays clear '
            'in all 4 views (2026-10-22 spec)');
    expect(chunk, isNot(contains('pointer-events-none absolute inset-x-3 bottom-3 flex flex-col items-start gap-2",children:[l.jsxs("div",{className:"pointer-events-auto flex max-h-28')),
        reason: 'no second overlay row under the view toggle');
  });

  test('the 4th view "Lista de espera" lists waitlisted drivers in the panel', () {
    expect(chunk, contains('setDrvView("waitlist")'),
        reason: 'the view toggle gains the 4th state');
    expect(chunk, contains('Lista de espera'));
    expect(chunk, contains('(d.verification_status??"")==="waitlist"'),
        reason: 'the list filters drivers by verification_status from '
            '/admin/driver-locations');
    expect(chunk,
        contains('String(b.created_at||"").localeCompare(String(a.created_at||""))'),
        reason: 'most recent signups first (created_at desc — ISO strings '
            'sort lexicographically)');
    expect(chunk, contains('drvWaitHtml'),
        reason: 'rows render photo/initial + name + phone + city,state + date');
    expect(chunk, contains('dangerouslySetInnerHTML'),
        reason: 'waitlist rows go through drvWaitHtml…');
    expect(chunk, contains('Registro: \${drvEsc(fh)}'),
        reason: '…and every user-controlled string passes drvEsc');
    expect(adminPy, contains('"verification_status": u.verification_status'),
        reason: 'the endpoint ships the field the waitlist view filters on');
    expect(adminPy, contains('"created_at": (u.created_at.isoformat()'),
        reason: 'the endpoint ships the registration date');
  });

  test('GPS dots carry a docs ring (green/red), popup line and legend', () {
    expect(chunk, contains('docs:d.docs_ok===true?1:d.docs_ok===false?0:-1'),
        reason: 'tri-state docs property on the GeoJSON features — only an '
            'EXPLICIT false paints red; a cached old backend without the '
            'field (undefined → -1) never turns the whole map red '
            '(2026-10-22 spec)');
    expect(chunk, contains('["==",["get","docs"],1],"#22C55E"'),
        reason: 'green ring = docs complete (data-driven ["get","docs"])');
    expect(chunk, contains('["==",["get","docs"],0],"#EF4444"'),
        reason: 'red ring = docs incomplete');
    expect(chunk, contains('"circle-stroke-width":2.5'),
        reason: 'the ring is visible at a glance over the online/offline '
            'fill (gold/gray kept)');
    expect(chunk, contains('Docs completos'));
    expect(chunk, contains('Faltan documentos'),
        reason: 'the dot popup states the docs status');
    expect(chunk, contains('Docs OK'));
    expect(chunk, contains('Faltan docs'),
        reason: 'small legend next to the view toggle');
    expect(adminPy, contains('"docs_ok": _docs_ok(u)'),
        reason: '/admin/driver-locations ships the per-driver docs flag '
            '(license + insurance + registration + AL inspection, any '
            'review state — same definition as fleet-stats)');
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
