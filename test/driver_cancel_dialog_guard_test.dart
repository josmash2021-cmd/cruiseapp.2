import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Owner 2026-11-02: the driver's cancel confirmation "debe decir are you
/// sure you quieres cancelar el viaje?, y el color del cuadro debe ser
/// #141414".
void main() {
  test('the confirmation asks "are you sure", on a #141414 box', () {
    final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
    expect(l10n, contains("'¿Seguro que quieres cancelar el viaje?'"));
    expect(l10n, contains("'Are you sure you want to cancel the trip?'"));

    final trip = File('lib/screens/driver/driver_trip_accept_screen.dart')
        .readAsStringSync()
        .replaceAll('\r\n', '\n');
    final dialog = trip.substring(trip.indexOf('void _confirmDriverCancel('));
    final head = dialog.substring(0, 600);
    expect(head, contains('backgroundColor: const Color(0xFF141414),'));
    expect(head, contains('surfaceTintColor: Colors.transparent,'),
        reason: 'Material 3 would tint the box away from #141414');
  });
}
