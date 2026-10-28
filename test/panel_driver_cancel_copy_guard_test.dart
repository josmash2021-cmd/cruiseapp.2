import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final source =
      File('backend/dispatch_panel/assets/trips-BkrykFxk.js').readAsStringSync();

  test('panel driver notification uses normal and airport passenger copy', () {
    expect(source, contains('guard-pin panel_driver_cancel_copy_guard_test'));
    expect(source, contains('body:d?'
        '"El pasajero tuvo un retraso en el aeropuerto y canceló su viaje."'
        ':"El pasajero canceló este viaje."'));
    expect(source, contains('typeof r.airportCode=="string"'));
    expect(source, contains('typeof r.airport_code=="string"'));
    expect(source, isNot(contains('body:"Un viaje asignado ha sido cancelado"')),
        reason: 'the old generic assigned-trip body is dead');
  });

  test('the edited trips bundle parses', () {
    final result = Process.runSync(
        'node', ['--check', 'backend/dispatch_panel/assets/trips-BkrykFxk.js']);
    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
  });
}
