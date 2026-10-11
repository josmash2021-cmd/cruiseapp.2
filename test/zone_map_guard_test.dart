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

  test('the map draws shading + highlight exactly like the photo', () {
    final s =
        File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
    for (final id in [
      'zones-src',
      'zones-hl-src',
      'zones-fill',
      'zones-line',
      'zones-hl-fill',
      'zones-hl-label',
    ]) {
      expect(s, contains(id), reason: 'layer/source $id missing');
    }
    expect(s, contains('0xFF7A2020'), reason: 'dark red shading (photo)');
    expect(s, contains('0xFFB03030'), reason: 'brighter highlight (photo)');
    expect(s, contains("'FL: {name}'"), reason: 'the photo label');
    expect(s, contains('_phase == _Phase.searching'),
        reason: 'zones live on the flat searching map only — never on top '
            'of an active trip route');
    final w = File('lib/screens/driver/driver_online_widgets.dart')
        .readAsStringSync();
    expect(w, contains('_zoneLayersReady = false'),
        reason: 'style reloads must recreate the custom sources');
  });

  test('the GO tap gates the connect client-side, fail-open', () {
    final s = File('lib/screens/driver/driver_online_offline.dart')
        .readAsStringSync();
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

  test('user-facing strings exist in ES and EN', () {
    final l10n =
        File('lib/l10n/app_localizations.dart').readAsStringSync();
    expect(l10n, contains('zoneOutsideTitle'));
    expect(l10n, contains('zoneOutsideBody'));
    expect(l10n, contains('Fuera del área de servicio'));
    expect(l10n, contains('Outside the service area'));
  });
}
