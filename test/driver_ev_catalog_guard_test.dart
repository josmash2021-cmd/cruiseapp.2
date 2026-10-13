import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the DRIVER side of Electric Pro (user spec 2026-10-13):
/// electric makes/models appear at registration (all three catalogs), and
/// the garage art for electric_pro vehicles.
void main() {
  final catalog = File('lib/data/vehicle_catalog.dart').readAsStringSync();
  final addVehicle =
      File('lib/screens/driver/add_vehicle_screen.dart').readAsStringSync();
  final signup =
      File('lib/screens/driver/driver_signup_screen.dart').readAsStringSync();
  final garage =
      File('lib/screens/driver/driver_vehicle_screen.dart').readAsStringSync();
  final tiersPy =
      File('backend/services/vehicle_tiers.py').readAsStringSync();

  const evMakes = ['Rivian', 'Lucid', 'Polestar'];
  const keyEvModels = [
    'Mustang Mach-E', 'F-150 Lightning', 'Ioniq 5', 'Ioniq 6', 'EV6', 'EV9',
    'Ariya', 'bZ4X', 'Solterra', 'EQB', 'EQE', 'i4', 'i7', 'iX', 'Q4 e-tron',
    'e-tron GT', 'R1S', 'R1T', 'Air', 'Polestar 2', 'Polestar 3', 'Taycan',
    'Cybertruck', 'Blazer EV', 'Equinox EV', 'Silverado EV', 'Bolt EUV',
    'ID. Buzz', 'Prologue', 'RZ', 'Lyriq',
  ];

  test('EV makes are in all three registration sources', () {
    for (final make in evMakes) {
      expect(catalog, contains("'$make'"), reason: 'vehicle_catalog: $make');
      expect(addVehicle, contains("'$make'"), reason: 'add_vehicle: $make');
      expect(signup, contains("'$make'"), reason: 'driver_signup: $make');
    }
  });

  test('key EV models are selectable at registration', () {
    for (final model in keyEvModels) {
      expect(catalog, contains("'$model'"),
          reason: 'vehicle_catalog missing $model');
    }
    // add_vehicle has its own models map — the big sellers must be there too
    for (final model in [
      'Mustang Mach-E', 'Ioniq 5', 'EV9', 'Ariya', 'bZ4X', 'R1S', 'R1T',
      'Air', 'Polestar 2', 'Cybertruck', 'Solterra', 'ID. Buzz',
    ]) {
      expect(addVehicle, contains("'$model'"),
          reason: 'add_vehicle missing $model');
    }
  });

  test('the registration EVs classify as electric_pro server-side', () {
    // The catalog and the backend classifier must agree on the flagship EVs.
    for (final model in [
      'mustang mach-e', 'ioniq 5', 'ev9', 'ariya', 'bz4x', 'r1s', 'r1t',
      'polestar 2', 'taycan', 'cybertruck', 'lightning', 'lucid air',
      'solterra', 'id. buzz', 'blazer ev', 'equinox ev', 'silverado ev',
    ]) {
      expect(tiersPy, contains(model),
          reason: '_ELECTRIC_MODELS in vehicle_tiers.py missing $model — a '
              'driver registering it would NOT be classified electric_pro');
    }
  });

  test('PHEVs stay OUT of the electric catalogs (BEV only)', () {
    expect(catalog, isNot(contains('Prius Prime')));
    expect(catalog, isNot(contains('RAV4 Prime')));
    expect(addVehicle, isNot(contains('Prius Prime')));
  });

  test('the garage shows the EV art for electric_pro vehicles', () {
    expect(garage, contains('case kTierElectricPro'),
        reason: 'the tier switch must know electric_pro');
    expect(garage, contains('assets/images/car_electric.png'),
        reason: 'the garage art for electric_pro is the EV side-profile');
    expect(
        File('assets/images/car_electric.png').existsSync(), isTrue,
        reason: 'the asset must exist');
    expect(garage, contains('errorBuilder'),
        reason: 'OTA fallback — patched phones without the asset yet must '
            'not render a broken image');
  });
}
