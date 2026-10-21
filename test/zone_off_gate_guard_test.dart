import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the zone OFF switch + the animated demand card (owner spec
/// 2026-10-17: "cuando este apagada la zona porque en el dispatch la
/// apague, no pueden prenderse los drivers" + "el cuadro very slow/busy/
/// very busy se cambie de forma animada y fluida").
void main() {
  final sysPy = File('backend/routers/system.py').readAsStringSync();
  final driversPy =
      File('backend/routers/drivers.py').readAsStringSync();
  final polygonsPy =
      File('backend/services/zone_polygons.py').readAsStringSync();
  final zoneSvc =
      File('lib/services/zone_service.dart').readAsStringSync();
  final offline =
      File('lib/screens/driver/driver_online_offline.dart').readAsStringSync();
  final ctrl =
      File('lib/screens/driver/driver_online_controller.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
  final panelChunk =
      File('backend/dispatch_panel/assets/index-BmdudzzQ.js')
          .readAsStringSync();

  test('backend: off survives the parse and gates the connect', () {
    expect(sysPy, contains('off: bool = False'),
        reason: 'ZoneDemandIn carries the off flag');
    expect(sysPy, contains('if cfg.get("off")'),
        reason: 'off survives level-0 in _parse_sector_demand');
    expect(sysPy, contains('async def sector_is_off('));
    expect(driversPy, contains('"zone_disabled"'),
        reason: 'the connect answers 403 zone_disabled');
    expect(polygonsPy, contains('async def sector_id_at('),
        reason: 'the point resolves to its sector id');
  });

  test('app: the off flag gates the connect and never loops a 403', () {
    expect(zoneSvc, contains('final bool off;'));
    expect(zoneSvc, contains('static bool sectorOff('));
    expect(offline, contains('ZoneService.sectorOff(_pos!)'),
        reason: 'client-side gate before even asking the backend');
    expect(offline, contains('_showZoneDisabledDialog()'));
    expect(ctrl, contains("e.message == 'zone_disabled'"),
        reason: 'a 403 zone_disabled never enters the 5 s retry loop');
    expect(l10n, contains('zoneDisabledTitle'));
    expect(l10n, contains('zoneDisabledBody'));
  });

  test('panel: the per-sector toggle posts off to /admin/zone-demand', () {
    expect(panelChunk, contains('panel_zone_off_guard_test'),
        reason: 'the guard-pin must survive a rebuild');
    expect(panelChunk, contains('async function arOff('),
        reason: 'the OFF poster exists beside the level poster');
    expect(panelChunk, contains('function jOff('),
        reason: 'the local-state toggle');
    expect(panelChunk, contains('"Apagada":"Activa"'),
        reason: 'the toggle button label');
    expect(panelChunk, contains('(e.off===!0)!==(a.off===!0)'),
        reason: 'the dirty detector sees off changes so Guardar saves them');
    expect(panelChunk, contains('{value:0,label:"Sin viajes"}'));
    expect(panelChunk, contains('{value:1,label:"Lento"}'));
    expect(panelChunk.contains('label:"Dorado"'), isFalse);
    expect(panelChunk, contains('«Apagada» pinta la zona de gris'),
        reason: 'the help text distinguishes manual off from no rides');
  });

  test('the demand card animates and distinguishes off from no rides', () {
    expect(
        'AnimatedSwitcher('.allMatches(offline).length >= 2, isTrue,
        reason: 'the demand label AND the hero headline both crossfade');
    expect(offline, contains('key: ValueKey(demandLabel)'));
    expect(offline, contains('key: ValueKey(headline)'));
    expect(offline, contains('const Duration(milliseconds: 350)'));
    expect(offline, contains('final off = d?.off ?? false;'));
    expect(offline, contains('s.offlineDemandZoneOff'));
    expect(offline, contains('s.offlineDemandSlow'));
    expect(offline, contains('s.offlineDemandNoRides'));
    expect(l10n, contains("_es ? 'Sin viajes' : 'No rides'"));
    expect(l10n, contains("_es ? 'Lento' : 'Slow'"));
    expect(l10n, contains("_es ? 'Zona apagada' : 'Zone off'"));
  });
}
