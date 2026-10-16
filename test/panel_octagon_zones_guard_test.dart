import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the zone-editing tools in the dispatch zone editor (user
/// specs 2026-10-15, iterated): ready-made PLAIN pieces, not jigsaw.
///
/// - "Pieza": one click drops a plain SQUARE at the map's current center,
///   sized to the view — pieces join by plain adjacency (squares tile),
///   editable like any sector. ("pero no de rompecabezas" — the jigsaw
///   knobs/holes are dead.)
/// - "Ciudad": a city name pulls its REAL municipal boundary from
///   OpenStreetMap Nominatim and it becomes the zone (the Sunrise/Davie /
///   Hialeah figures are city limits).
/// - "Octágono" is back to a plain smooth octagon.
///
/// The panel is a compiled bundle whose React source lives outside this
/// repo — the guard-pin comments are what the next rebuild must re-apply.
void main() {
  final chunk = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere(
          (s) => s.contains('guard-pin panel_octagon_zones_guard_test'),
          orElse: () => '');

  test('plain square pieces + city tool, no jigsaw', () {
    expect(chunk, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(chunk, contains('children:"Piezas:"'),
        reason: 'the palette row labels the piece button');
    expect(chunk, contains('children:"Pieza"'),
        reason: 'one plain square piece button');
    expect(chunk, contains('onClick:()=>pieceDrop()'),
        reason: 'the piece drops plain — no knob direction anymore');
    expect(chunk, contains('function _pieceFeature(center,S){'),
        reason: 'the square piece generator exists');
    expect(chunk.contains('_pieceBump'), isFalse,
        reason: 'the jigsaw bump builder is dead ("pero no de rompecabezas")');
    expect(chunk.contains('Math.sin(a)*r*mode'), isFalse,
        reason: 'no rounded knobs/holes remain either');

    // Ciudad — the real city-boundary tool
    expect(chunk, contains('children:"Ciudad"'));
    expect(chunk, contains('nominatim.openstreetmap.org/search'));
    expect(chunk, contains('polygon_geojson=1'));
    expect(chunk, contains('countrycodes=us'));
  });

  test('the octagon is smooth again', () {
    expect(chunk, contains('function _octFeature(center,R){'),
        reason: 'the octagon generator exists');
    expect(chunk, contains('for(let k=0;k<8;k++)'),
        reason: 'eight plain vertices');
    expect(chunk, contains('ring.push(ring[0])'),
        reason: 'closed smooth ring — no teeth, no bumps');
  });
}
