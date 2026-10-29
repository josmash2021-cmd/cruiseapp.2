import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Maintenance mode (owner spec 2026-10-29): while the kill page is on, the
/// backend answers 403 "maintenance" to is_online and to scheduled claims
/// and flags can-go-online. The app must treat it like the dispatch GO
/// switch (terminal, roll back offline) but say "mantenimiento".
void main() {
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final offline =
      File('lib/screens/driver/driver_online_offline.dart').readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final sched = File('lib/screens/driver/scheduled_rides_map_screen.dart')
      .readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  test('a 403 maintenance on the heartbeat rolls the driver offline', () {
    final i = ctrl.indexOf("e.message == 'maintenance'");
    expect(i, isNonNegative);
    final branch = ctrl.substring(i, i + 400);
    expect(branch, contains('_exitOnlineMode()'));
    expect(branch, contains('_goDisabledMaintenance = true;'));
    expect(branch, contains('_showGoOnlineDisabledDialog()'));
  });

  test('can-go-online maintenance flag drives the GO dialog copy', () {
    expect(screen, contains('bool _goDisabledMaintenance = false;'));
    expect(offline, contains("result['maintenance'] == true"));
    expect(offline, contains('_goDisabledMaintenance = maintenanceOn;'));
    expect(offline, contains('maintenanceGoTitle'));
    expect(offline, contains('maintenanceGoBody'));
  });

  test('a refused scheduled claim says maintenance, not out-of-state', () {
    final i = sched.indexOf("e.message == 'maintenance'");
    final j = sched.indexOf('scheduledOutOfState');
    expect(i, isNonNegative);
    expect(i, lessThan(j));
    expect(sched, contains('maintenanceClaimBlocked'));
  });

  test('copy exists in both languages', () {
    for (final g in ['maintenanceGoTitle', 'maintenanceGoBody', 'maintenanceClaimBlocked']) {
      expect(l10n, contains('String get $g'));
    }
    expect(l10n, contains('Cruise está en mantenimiento'));
    expect(l10n, contains('Cruise is under maintenance'));
  });
}
