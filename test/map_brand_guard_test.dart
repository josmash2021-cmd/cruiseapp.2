import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-02: the Mapbox wordmark and the "i" for the credits show on
/// every map, just above each screen's bottom panel (Mapbox's terms require
/// the wordmark and do not allow resizing it). They used to be switched off
/// on every map, and pushed 100 pt off-screen on two of them.
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  Iterable<File> dartFiles(String dir) => Directory(dir)
      .listSync(recursive: true)
      .whereType<File>()
      .where((f) => f.path.endsWith('.dart'));

  test('no map hides or pushes away the Mapbox wordmark or credits', () {
    final bad = RegExp(r'(LogoSettings|AttributionSettings)\(\s*enabled:\s*false'
        r'|marginLeft:\s*-\d|iconColor:\s*0x00');
    for (final f in dartFiles('lib')) {
      final src = read(f.path);
      expect(bad.hasMatch(src), isFalse, reason: f.path);
    }
  });

  test('the shared theme pass re-applies the marks instead of hiding them',
      () {
    final theme = read('lib/config/map_theme.dart');
    expect(theme, contains('await MapBrand.refresh(ctrl);'));
    expect(theme, contains('enabled: true,\n        position: mapbox.OrnamentPosition.BOTTOM_LEFT,'));
    expect(theme, contains('position: mapbox.OrnamentPosition.BOTTOM_RIGHT,'));
    expect(read('lib/map/unified_map_service.dart'),
        contains("('brand', () => MapBrand.refresh(ctrl)),"));
  });

  test('the marks ride above each screen panel, beside the map buttons', () {
    expect(read('lib/screens/driver/driver_nav_view.dart'),
        contains('bottom: _panelRestH.roundToDouble(), left: 16 + 64, right: 14 + 46);'));
    expect(read('lib/screens/driver/driver_online_screen.dart'),
        contains('bottom: bottom.roundToDouble(), left: 16 + 44, right: 16 + 44));'));
    expect(read('lib/screens/driver/scheduled_rides_map_screen.dart'),
        contains('MapBrand.show(ctrl, bottom: brandBottom, right: 14 + 44)'));
    expect(read('lib/screens/ride_request_map.dart'),
        contains('unawaited(MapBrand.show(brandMap, bottom: h));'));
    expect(read('lib/screens/rider_tracking_screen.dart'),
        contains('unawaited(MapBrand.show(m, bottom: h));'));
    for (final p in [
      'lib/screens/map_picker_screen.dart',
      'lib/screens/set_pickup_location_screen.dart',
      'lib/screens/waiting_for_driver_screen.dart',
    ]) {
      final src = read(p);
      expect(src, contains('key: _brandPanelKey,'), reason: p);
      expect(src, contains('MapBrand.showAbovePanel('), reason: p);
    }
  });

  test('web maps keep the wordmark and the credits', () {
    final web = read('lib/map/web_map_view_web.dart');
    expect(web, contains('options.attributionControl = true;'));
    expect(web, isNot(contains('mapboxgl-ctrl-logo{display:none')));
  });
}
