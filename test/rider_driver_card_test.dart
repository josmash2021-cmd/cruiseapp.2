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
    final at = card.indexOf('vehicleLabel,\n                        textAlign: TextAlign.right,');
    expect(at, isNonNegative);
    final label = card.substring(at, at + 300);
    expect(label, contains('maxLines: 2,'));
    expect(label, isNot(contains('TextOverflow.ellipsis')));
    expect(card, contains('maxWidth: Responsive.w(165),'));
    expect(card, contains('fit: BoxFit.scaleDown,'));
    expect(card, isNot(contains('width: Responsive.w(92),\n                child: Column(')));
  });
}
