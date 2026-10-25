import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final people = File('backend/dispatch_panel/assets/index-azyIyM-i.js');
  final users = File('backend/dispatch_panel/assets/users-DWu98l86.js');
  final source = people.readAsStringSync();
  final usersSource = users.readAsStringSync();

  test('every current vehicle is listed and independently editable', () {
    for (final needle in [
      'guard-pin panel_vehicle_management_guard_test',
      'function VehicleEditor(',
      'vehicles.map(vehicle=>',
      'onVehicleSaved:()=>f.reload()',
      'updateVehicle(t.id,{make:',
      'plate_state:plateState',
      'vehicle_type:tier',
      'children:"Editar"',
      'Estado de la placa',
      'Categoría',
    ]) {
      expect(source, contains(needle), reason: needle);
    }
    expect(source, contains('!v.archived_at'));
    expect(source, contains('VEHICLE_TIER_OPTIONS.map'));
    expect(source, contains('Object.entries(VEHICLE_STATES).map'));
    expect(usersSource, contains('async function updateVehicle(e,t)'));
    expect(usersSource, contains('/admin/vehicles/'));
    expect(usersSource, contains('getRiderPaymentMethods,updateVehicle'));
    expect(usersSource, contains('"vehicleType"in s&&(i.vehicle_type=s.vehicleType)'));
    expect(usersSource, contains('"vehiclePlate"in s&&(i.plate_number=s.vehiclePlate)'));
  });

  test('the plate state catalog has all 52 states and territories', () {
    final script = r'''
const fs=require('fs'),vm=require('vm');
const source=fs.readFileSync(process.argv[1],'utf8');
const match=source.match(/const VEHICLE_STATES=(\{[^;]+\});/);
if(!match)throw new Error('VEHICLE_STATES not found');
const sandbox={};
vm.runInNewContext(`result=${match[1]}`,sandbox);
const states=sandbox.result,codes=Object.keys(states);
if(codes.length!==52)throw new Error(`expected 52, got ${codes.length}`);
for(const code of ['AL','FL','CA','TX','NY','DC','PR'])if(!states[code])throw new Error(`missing ${code}`);
const tiers=source.match(/const VEHICLE_TIER_OPTIONS=(\[[^;]+\]);/);
if(!tiers)throw new Error('tier options missing');
vm.runInNewContext(`result=${tiers[1]}`,sandbox);
if(sandbox.result.length!==5)throw new Error('expected five categories');
if(JSON.stringify(sandbox.result.map(item=>item[0]))!==JSON.stringify(['standard','compact','electric_pro','premium','vip']))throw new Error('category mismatch');
console.log(JSON.stringify({states:codes.length,tiers:sandbox.result.length}));
''';
    final result = Process.runSync('node', ['-e', script, people.path]);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    expect('${result.stdout}', contains('"states":52'));
  });

  test('the edited vehicle bundles parse', () {
    for (final file in [people, users]) {
      final result = Process.runSync('node', ['--check', file.path]);
      expect(result.exitCode, 0, reason: '${file.path}\n${result.stderr}');
    }
  });
}
