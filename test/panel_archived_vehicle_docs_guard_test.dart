import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _pin = 'guard-pin panel_archived_vehicle_docs_guard_test';

void main() {
  final chunks = Directory('backend/dispatch_panel/assets')
      .listSync()
      .whereType<File>()
      .where((file) =>
          file.path.contains('index-') &&
          file.path.endsWith('.js') &&
          file.readAsStringSync().contains(_pin))
      .toList();
  final source = chunks.single.readAsStringSync();

  test('archived vehicles load separately and map their archive timestamp', () {
    expect(chunks, hasLength(1));
    for (final needle in [
      '[archivedVehicles,setArchivedVehicles]=m.useState([])',
      'setArchivedVehicles(Array.isArray(d.archived_vehicles)?d.archived_vehicles.map(ra):[])',
      'archivedAt:ne(t.archived_at)',
      'archivedVehicles.length===0&&!showSocial',
    ]) {
      expect(source, contains(needle), reason: needle);
    }
  });

  test('archived cards keep media and downloads but are read-only', () {
    for (final needle in [
      'Vehículos archivados (solo historial)',
      'const docCard=(d,readOnly=false)=>',
      'const vehicleCard=(d,readOnly=false)=>',
      '!readOnly&&(isSelfie?selfieBtns(d.id):reviewBtns("document",d.id,d.vehicleId,d.docType))',
      '!readOnly&&reviewBtns("vehicle",d.id)',
      'vdocs.map(g=>docCard(g,readOnly))',
      'archivedVehicles.map(d=>vehicleCard(d,!0))',
      '"aria-label":"Descargar documento"',
      'e.jsx(Ke,{status:d.approvalStatus})',
    ]) {
      expect(source, contains(needle), reason: needle);
    }
  });

  test('current vehicles and documents keep every active control', () {
    for (final needle in [
      'driverDocs.map(d=>docCard(d))',
      'vehicles.map(d=>vehicleCard(d))',
      'reviewBtns("document",d.id,d.vehicleId,d.docType)',
      'reviewBtns("vehicle",d.id)',
      'children:"Aprobar"',
      'children:"Rechazar"',
      'children:"Actualizar"',
    ]) {
      expect(source, contains(needle), reason: needle);
    }
    expect(source, isNot(contains('.map(docCard)')),
        reason: 'Array.map passes the index as the second argument');
    expect(source, isNot(contains('.map(vehicleCard)')),
        reason: 'current and archived vehicles need explicit readOnly arrows');
  });

  test('the edited archived-vehicle bundle parses', () {
    final result = Process.runSync('node', ['--check', chunks.single.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
