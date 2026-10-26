import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for the 2026-10-23 owner report: "firmé los contratos y todo, y el
/// GO no me dejaba activarme sin cerrar la app". Two stale-state holes made
/// a driver who JUST fixed a requirement bounce anyway:
///  1. The GO gates trusted the boot snapshot (_contractsPending /
///     _vehicleDocsApproved) instead of re-checking fresh before bouncing.
///  2. A backend 403 (account_not_approved / zone gates) retried every 5 s
///     in silence AND left _driverOnline = true — the screen claimed
///     "searching" while the backend had the driver OFFLINE.
void main() {
  final offline =
      File('lib/screens/driver/driver_online_offline.dart').readAsStringSync().replaceAll('\r\n', '\n');
  final controller = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync().replaceAll('\r\n', '\n');

  test('the GO tap re-verifies fresh before bouncing on a stale snapshot', () {
    final fn = offline.indexOf('void _onGoTap()');
    expect(fn, greaterThan(-1));
    final region = offline.substring(fn, fn + 7000);
    final recheck = region.indexOf('''_contractsPending.isNotEmpty)) {
      await _checkVehicleDocStatus();''');
    final docsGate = region.indexOf(
        'if (_docStatusLoaded && (_hasExpiredDocs || !_vehicleDocsApproved))');
    expect(recheck, greaterThan(-1),
        reason: 'the fresh re-check with the combined condition exists');
    expect(docsGate, greaterThan(-1));
    expect(recheck, lessThan(docsGate),
        reason: 'the fresh re-check runs BEFORE the doc/contracts gates');
  });

  test('a refused online flip rolls the UI back offline — never a ghost', () {
    final fn = controller.indexOf('}).catchError((e) {');
    expect(fn, greaterThan(-1));
    final region = controller.substring(fn, fn + 3500);
    // Zone gates AND account_not_approved are terminal AND roll back.
    expect(region, contains("e.message == 'zone_disabled'"));
    expect(region, contains("e.message == 'outside_service_area'"));
    expect(region, contains("e.message == 'account_not_approved'"));
    expect(region, contains('_exitOnlineMode()'),
        reason: 'a 403 from the flip must never leave the UI online');
    expect(region, contains("_bounceToApprovalScreen('pending')"));
  });
}
