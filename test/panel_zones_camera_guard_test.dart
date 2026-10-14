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
}
