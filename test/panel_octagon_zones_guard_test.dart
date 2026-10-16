import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the Octágono zone tool in the dispatch zone editor (user
/// spec 2026-10-15: "para armar las zonas me de figuras geométricas de
/// octágonos"). The editor gains an Octágono button: first map click sets
/// the center, second click fixes the radius, with a live preview, and the
/// generated regular 8-gon enters the same validation/naming pipeline as
/// freehand polygons. The panel is a compiled bundle whose React source
/// lives outside this repo — the guard-pin comment is what the next
/// rebuild must re-apply.
void main() {
  final chunk = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere(
          (s) => s.contains('guard-pin panel_octagon_zones_guard_test'),
          orElse: () => '');

  test('the zones editor carries the octagon tool and its pin', () {
    expect(chunk, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(chunk, contains('children:"Octágono"'),
        reason: 'the Octágono button sits next to Nuevo sector');
    expect(chunk, contains('function _octFeature('),
        reason: 'the regular 8-gon generator exists');
    expect(chunk, contains('22.5+45*k'),
        reason: 'eight vertices at 45° steps, flat-side up like the spec');
    // 2026-10-15 (user spec: "las esquinas como si fueran dientes pero
    // cuadrado" — la foto muestra bordes pixelados en escalera): las 4
    // aristas diagonales del octágono se vuelven escaleras de bloques
    // (horizontal-vertical alternado), los 4 lados rectos quedan rectos.
    expect(chunk, contains('const steps=Math.max(3,Math.round(R/300))'),
        reason: 'diagonal edges become block staircases (~300 m teeth)');
    expect(chunk, contains('ring.push([nx,py]);ring.push([nx,ny])'),
        reason: 'horizontal-then-vertical steps = the squared-teeth look');
    expect(chunk, contains('if(Math.abs(dx)<1e-12||Math.abs(dy)<1e-12)'),
        reason: 'axis-aligned edges stay straight');
    expect(chunk, contains('const ring=[V[0]]'),
        reason: 'the ring starts and ends at the same vertex — closed '
            'polygon, GeoJSON-valid');
    expect(chunk, contains('zonas-oct-preview'),
        reason: 'the live radius preview source/layers exist');
    expect(chunk, contains('!ot8.current&&b.changeMode("draw_polygon")'),
        reason: 'freehand drawing never hijacks an octagon click');
  });

  test('octagon refs are declared before use', () {
    const declaration = 'const ot8=c.useRef(!1),c8=c.useRef(null);';
    expect(chunk, contains(declaration),
        reason: 'module scope is strict — ot8 without const crashes Zonas');
    expect(chunk.indexOf('!ot8.current'), greaterThan(chunk.indexOf(declaration)));
  });
}
