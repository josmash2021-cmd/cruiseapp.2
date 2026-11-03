import 'dart:io';

import 'package:cruise_app/utils/name_helper.dart' as nh;
import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-03, the rider's trip screen: "que el nombre del conductor
/// no esté completo, debe de aparecer nombre y la inicial del apellido;
/// debe de aparecer completo la marca, modelo, color del carro y placa".
void main() {
  String read(String p) =>
      File(p).readAsStringSync().replaceAll('\r\n', '\n');

  test('the driver shows as first name + surname initial', () {
    // Two surnames: the first one's initial.
    expect(nh.shortName('Eduardo Jonas Ramirez Bocanegra'), 'Eduardo R.');
    expect(nh.shortName('Jhon Martinez'), 'Jhon M.');
    expect(nh.shortName('Maria Jose Tosta Perez'), 'Maria T.');
    expect(nh.shortName('Juan De La Cruz'), 'Juan D.');
    expect(nh.shortName('Ana De Leon'), 'Ana D.');
    expect(nh.shortName('Maria De Los Angeles Perez Gomez'), 'Maria P.');
    // Three words keep the last: a compound first name or a middle name.
    expect(nh.shortName('Maria Jose Tosta'), 'Maria T.');
    expect(nh.shortName('John Michael Smith'), 'John S.');
    final card = read('lib/widgets/tracking/driver_info_card.dart');
    expect(card, contains('nh.shortName(widget.driverName),'));
    expect(card, isNot(contains('nh.displayName(widget.driverName')));
    expect(read('lib/widgets/tracking/eta_display.dart'),
        isNot(contains('nh.displayName(widget.driverName')));
  });

  test('color, make, model and plate are never cut', () {
    final card = read('lib/widgets/tracking/driver_info_card.dart');
    expect(card, contains('Widget _sheetCarColumn() => VehicleIdentityColumn('));
    final shared = read('lib/widgets/tracking/vehicle_identity.dart');
    final at = shared.indexOf('class VehicleIdentityColumn');
    expect(at, isNonNegative);
    final label = shared.substring(at);
    expect(label, contains('maxLines: 2,'));
    expect(label, isNot(contains('TextOverflow.ellipsis')));
    // The color is a small square, not a word (owner 2026-11-03).
    expect(label, contains("key: const ValueKey('vehicle-color-swatch'),"));
    expect(label, contains('if (swatch == null) colorWord,'));
    expect(card, contains('maxWidth: Responsive.w(165),'));
    expect(label, contains('fit: BoxFit.scaleDown,'));
    expect(card, isNot(contains('width: Responsive.w(92),\n                child: Column(')));
  });

  // Owner 2026-11-03: the driver-arrived screen shows the plate, the color,
  // "Nombre I." and the car exactly like the sheet.
  test('the driver-arrived screen shows the driver and car like the sheet', () {
    final arrival = read('lib/screens/rider_confirm_pickup_screen.dart');
    expect(arrival, contains('child: _buildDriverCarRow(),'));
    expect(arrival, contains('nh.shortName(widget.driverName),'));
    expect(arrival, contains('VehicleIdentityColumn('));
    expect(arrival, contains('splitVehicleColor(widget.vehicleDesc)'));
    expect(arrival, isNot(contains('_buildSpecRow()')),
        reason: 'the LICENSE PLATE / VEHICLE blocks gave way to the sheet row');
  });

  // Owner 2026-11-03: "en el free wait time debe tener un contador alrededor
  // como círculo".
  test('the free wait time counts down inside a ring', () {
    final arrival = read('lib/screens/rider_confirm_pickup_screen.dart');
    expect(arrival, contains("key: const ValueKey('free-wait-ring'),"));
    expect(arrival, contains('fraction: _freeWaitSec <= 0 ? 0 : freeRemaining / _freeWaitSec,'));
    expect(arrival, contains('class _WaitRingPainter extends CustomPainter'));
    expect(arrival, contains('duration: const Duration(seconds: 1),'));
  });
}
