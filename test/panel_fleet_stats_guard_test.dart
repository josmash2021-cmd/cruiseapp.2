import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the Drivers-page fleet stats (user spec 2026-10-15: "quiero
/// ver cuánto hay por categorías y cuántos ya han subido los documentos y
/// cuántos no han subido todos"). The people grid shows tier chips
/// (Standard/Compact/Electric Pro/Premium/VIP/sin vehículo) and the docs
/// buckets (completos/incompletos), fed by GET /admin/driver-fleet-stats.
/// The panel is a compiled bundle whose React source lives outside this
/// repo — the guard-pin comment is what the next rebuild must re-apply.
void main() {
  final assets = Directory('backend/dispatch_panel/assets');
  final chunk = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('index-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('guard-pin panel_fleet_stats_guard_test'),
          orElse: () => '');
  final usersModule = assets
      .listSync()
      .whereType<File>()
      .where((f) => f.path.contains('users-') && f.path.endsWith('.js'))
      .map((f) => f.readAsStringSync())
      .firstWhere((s) => s.contains('getFleetStats'), orElse: () => '');

  test('the people grid carries the fleet stats chips', () {
    expect(chunk, isNotEmpty,
        reason: 'a rebuild of the out-of-repo React source must re-apply '
            'this edit (the pin says how)');
    expect(chunk, contains('getFleetStats as gfs'),
        reason: 'the chunk imports the stats fetch');
    for (final label in [
      '"Standard"', '"Compact"', '"Electric Pro"', '"Premium"', '"VIP"',
      '"Sin vehículo"', '"Docs completos"', '"Docs incompletos"',
    ]) {
      expect(chunk.contains('chipBtn('), isTrue,
          reason: 'chips are filter buttons');
      expect(chunk.contains(label), isTrue,
          reason: 'chip $label present in the Drivers page stats row');
    }
    expect(chunk.contains('label:"Black"'), isFalse,
        reason: 'the top tier shows VIP, never Black (2026-10-15 rename)');
  });

  test('the chips are clickable filters wired to the grid by sqliteId', () {
    expect(chunk, contains('chipBtn('),
        reason: 'each stat chip is a toggle button, not a dead label');
    expect(chunk, contains('ids.has(d.sqliteId)'),
        reason: 'the grid filters the people list by SQL id against the '
            'fleet-stats rows');
    expect(chunk, contains('statF===k?null:k'),
        reason: 'tap again clears the filter');
    expect(chunk, contains('Limpiar filtro'),
        reason: 'a visible clear control appears while a filter is active');
  });

  test('the users module fetches the fleet stats endpoint', () {
    expect(usersModule, contains('"/admin/driver-fleet-stats"'));
    expect(usersModule, contains('getFleetStats as getFleetStats'),
        reason: 'exported for the people grid chunk');
  });
}
