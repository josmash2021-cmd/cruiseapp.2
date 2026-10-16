import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the puzzle-piece zones in the dispatch zone editor (user
/// spec 2026-10-15: "colócame las piezas de rompecabezas para yo solo
/// ponerlas en el mapa y unirlas... y cambia esas piezas que eso no son
/// piezas de rompecabezas").
///
/// The editor ships a piece PALETTE (▸ ◂ ▴ ▾ — knob on that side, hole on
/// the opposite): one click drops a ready-made jigsaw piece at the map's
/// current center, sized to the view, previewed live, named through the
/// same modal as freehand polygons, and draggable/editable after like any
/// sector. The octagon tool's edges are real rounded jigsaw bumps
/// (knob/hole alternate per edge) — the square crenellation died.
///
/// The panel is a compiled bundle whose React source lives outside this
/// repo — the guard-pin comment is what the next rebuild must re-apply.
void main() {
  final chunk = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere(
          (s) => s.contains('guard-pin panel_octagon_zones_guard_test'),
          orElse: () => '');

  test('the zones editor carries the puzzle-piece palette and its pin', () {
    expect(chunk, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(chunk, contains('children:"Piezas:"'),
        reason: 'the palette row labels the piece buttons');
    expect(chunk, contains('onClick:()=>pieceDrop('),
        reason: 'piece buttons drop ready-made pieces');
    for (final dir in ['"R"', '"L"', '"T"', '"B"']) {
      expect(chunk, contains('onClick:()=>pieceDrop($dir)'),
          reason: 'piece variant $dir exists in the palette');
    }
    expect(chunk, contains('function _pieceFeature('),
        reason: 'the square jigsaw piece generator (knob one side, hole '
            'the other) exists');
    expect(chunk, contains('function _pieceBump('),
        reason: 'the rounded bump/hole builder exists');
    expect(chunk, contains('Math.sin(a)*r*mode*1.25'),
        reason: 'the bump is a real rounded jigsaw tab, not square teeth');
    expect(chunk.contains('const steps=Math.max(3,Math.round(R/300))'),
        isFalse,
        reason: 'the square-teeth staircase is dead — jigsaw bumps instead');
    expect(chunk, contains('map.getSource("zonas-oct-preview").setData'),
        reason: 'a dropped piece previews live behind the naming modal');
  });

  test('the Ciudad tool pulls real city boundaries (user spec: zonas con '
      'forma de ciudad como Sunrise/Davie)', () {
    expect(chunk, contains('guard-pin panel_city_zone_guard_test'),
        reason: 'the city tool carries its own pin for rebuilds');
    expect(chunk, contains('children:"Ciudad"'),
        reason: 'the Ciudad button lives in the piece palette');
    expect(chunk, contains('nominatim.openstreetmap.org/search'),
        reason: 'city boundaries come from OpenStreetMap Nominatim');
    expect(chunk, contains('polygon_geojson=1'),
        reason: 'the request asks for the boundary polygon, not a point');
    expect(chunk, contains('countrycodes=us'),
        reason: 'the operation is US — no worldwide fuzz');
    expect(chunk, contains('x.geojson.type==="Polygon"'),
        reason: 'only boundary polygons get through');
    expect(chunk, contains('X((hit.display_name||q).split(",")[0])'),
        reason: 'the city name pre-fills the sector name field');
  });
}
