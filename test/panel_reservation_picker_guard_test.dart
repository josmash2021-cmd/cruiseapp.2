import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// "Cambiar conductor" on a reservation (trip 790, 2026-11-02) opened the
/// "No se pudo cargar" screen: the picker labels each driver with
/// tierLabel(r.vehicleType), the reservation list comes from /admin/users,
/// and that list never carried a vehicle type — null.trim() on every
/// driver. The bundle is hand-patched (CLAUDE.md #30), so pin the edits.
void main() {
  final html = File('backend/dispatch_panel/index.html')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final match =
      RegExp(r'src="/panel/assets/(index-[^"]+\.js)"').firstMatch(html);
  final entry = match == null
      ? ''
      : File('backend/dispatch_panel/assets/${match.group(1)}')
          .readAsStringSync();
  final tripsPage = File('backend/dispatch_panel/assets/index-B68rRA9U.js')
      .readAsStringSync();
  final adminPy = File('backend/routers/admin.py').readAsStringSync();

  test('the tier label survives a driver with no vehicle type', () {
    expect(entry, contains('panel_reservation_picker_guard_test'));
    expect(entry,
        contains('function ao(e){/*! guard-pin panel_reservation_picker_guard_test'));
    expect(entry, contains('if(typeof e!="string")return null;switch(e.trim()'));
    expect(tripsPage, contains('m as tierLabel'),
        reason: 'the picker imports the same helper under this name');
    expect(entry, contains(',ao as m,'),
        reason: 'export m is ao — the helper made null-safe above');
    expect(tripsPage, contains('tierLabel(r.vehicleType)'));
  });

  test('the reservation picker gets tier and plate from the backend', () {
    expect(entry,
        contains('vehicleType:u.vehicle_type||null,vehiclePlate:u.vehicle_plate||null,'));
    expect(adminPy, contains('row["vehicle_type"] = car[0]'));
    expect(adminPy, contains('row["vehicle_plate"] = car[1]'));
  });
}
