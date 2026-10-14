import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch panel zone-editor camera (user report
/// 2026-10-14: the panel must let dispatch draw ALABAMA sectors, not only
/// Florida's). The editor's map was born locked on Miami (center
/// [-80.35,26.05], zoom 9.5) — drawing Alabama meant panning ~700 km by
/// hand. The initial camera now shows the whole two-state Southeast; the
/// load-fit still reframes to the sectors once they arrive.
///
/// The panel is a built React bundle served from backend/dispatch_panel;
/// the Zonas screen lives in a code-split chunk whose hash changes on every
/// rebuild, so this guard scans the assets for the chunk that carries the
/// editor. The React SOURCE lives outside this repo — a rebuild must
/// re-apply this change (see the guard-pin comment in the bundle).
void main() {
  final chunk = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('ZonasScreen'), orElse: () => '');

  test('the Zonas editor chunk exists in the built panel', () {
    expect(chunk, isNotEmpty,
        reason: 'no built chunk exports ZonasScreen — the panel was rebuilt '
            'and this guard needs its needle refreshed');
  });

  test('the editor camera opens on the two-state Southeast, not Miami', () {
    expect(chunk, contains('Pe=[-83.6,29.9]'),
        reason: 'the pre-load camera centres between Florida and Alabama');
    expect(chunk, contains('zoom:5.6'),
        reason: 'the pre-load zoom shows both states at once');
    expect(chunk.contains('Pe=[-80.35,26.05]'), isFalse,
        reason: 'the Miami-locked camera is dead');
    expect(chunk, contains('guard-pin panel_zones_camera_guard_test'),
        reason: 'the bundle edit carries its guard-pin so the next rebuild '
            'of the out-of-repo React source re-applies it');
  });

  test('the editor stays generic — draw, save and heat work for any state',
      () {
    // Nothing in the editor or the backend PUT restricts geography: Alabama
    // polygons save through the same path Florida's did.
    expect(chunk, contains('/admin/zones/sectors'),
        reason: 'the save path (PUT) is state-agnostic');
    final sys = File('backend/routers/system.py').readAsStringSync();
    expect(sys, contains('_live_sector_ids'),
        reason: 'demand-heat ids validate against the LIVE map — a '
            'panel-added sector accepted heat after a server restart too');
  });

  test('the demand screen lists the LIVE sectors, not a baked list', () {
    // User spec 2026-10-14: "las zonas que dibujo se tienen que actualizar
    // esto" — the heat screen's rows were a hardcoded copy of the 13 Florida
    // sectors (const ve=[{id:"broward_north",…}]), so panel-drawn sectors
    // (Alabama) could never get heat. The rows now come from /zones/sectors.
    final demandChunk = Directory('backend/dispatch_panel/assets')
        .listSync()
        .whereType<File>()
        .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
        .map((f) => f.readAsStringSync())
        .firstWhere((s) => s.contains('Sectores del mapa'),
            orElse: () => '');
    expect(demandChunk, isNotEmpty,
        reason: 'no built chunk carries the demand screen');
    expect(demandChunk, contains('liveSectorRows'),
        reason: 'the rows read the live sector list state');
    expect(demandChunk, contains('Ie("/zones/sectors")'),
        reason: 'the live list is fetched from the same endpoint the '
            'editor saves through');
    expect(demandChunk, contains('(liveSectorRows??ve).map('),
        reason: 'the baked list survives only as the offline fallback');
  });

  test('the state selector frames Florida or Alabama on demand', () {
    // User spec 2026-10-14: "en el dispatch debe salirme para seleccionar
    // florida y seleccionar alabama… que me muestre todo lo que ya he
    // dibujado". Two chips fly the editor map to the state's drawn sectors
    // (or the state frame when nothing is drawn there yet).
    expect(chunk, contains('const fitStateView='),
        reason: 'the state-fit helper exists in the editor component');
    expect(chunk, contains('children:"Florida"'));
    expect(chunk, contains('children:"Alabama"'));
    expect(chunk, contains('fitStateView([-87.63,24.45,-79.87,31])'),
        reason: 'Florida frame = the state bbox');
    expect(chunk, contains('fitStateView([-88.47,30.22,-84.89,35.01])'),
        reason: 'Alabama frame = the state bbox');
    expect(chunk, contains('G.current??[]'),
        reason: 'the fit prefers the sectors already drawn in the state');
    expect(chunk, contains('guard-pin panel_zones_camera_guard_test'),
        reason: 'the bundle edit carries its guard-pin so the next rebuild '
            'of the out-of-repo React source re-applies it');
  });
}
