import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-02: the Mapbox wordmark and the "i" for the credits are on
/// for every map, at the map's bottom edge — under each screen's sheet, and
/// in navigation in the strip under the floating panel. They used to be
/// switched off on every map, and pushed 100 pt off-screen on two of them.
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

  test('the marks sit under the sheets; in navigation, under the floating panel',
      () {
    // Owner 2026-11-02: "colócalo debajo del sheet" — no per-screen lift
    // above the panels any more.
    for (final f in dartFiles('lib')) {
      final src = read(f.path);
      expect(src, isNot(contains('showAbovePanel(')), reason: f.path);
      expect(src, isNot(contains('_syncMapBrand')), reason: f.path);
    }
    final nav = read('lib/screens/driver/driver_nav_view.dart');
    // The panel's margin and the marks' strip are the same number: half
    // the home indicator on iPhone, the whole nav bar on Android (it is
    // real, touch-blocking chrome there — 2026-11-09).
    expect(nav,
        contains('final strip = 8 + (AppPlatform.isAndroid ? inset : inset * 0.5);'));
    expect(nav, contains('bottom: math.max(0.0, (strip - 21) / 2).roundToDouble());'));
    final panel = read('lib/screens/driver/nav_trip_panel.dart');
    expect(panel,
        contains('final dockInset = AppPlatform.isAndroid ? bottomPad : bottomPad * 0.5;'));
    expect(panel,
        contains('EdgeInsets.fromLTRB(8 * k, 0, 8 * k, (8 + dockInset) * k),'),
        reason: 'the strip the marks sit in is this margin');
  });

  test('web maps keep the wordmark and the credits', () {
    final web = read('lib/map/web_map_view_web.dart');
    expect(web, contains('options.attributionControl = true;'));
    expect(web, isNot(contains('mapboxgl-ctrl-logo{display:none')));
  });
}
