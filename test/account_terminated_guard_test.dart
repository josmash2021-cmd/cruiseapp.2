import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the terminated-account gate (user report 2026-10-06): a
/// driver whose account was blocked/deleted WHILE LOGGED IN kept opening
/// the app as normal, because the server's 403 carried prose
/// ("Account blocked") and every screen's catch swallowed it. Now the
/// detail is machine-readable and ApiService._parse ends the session on
/// ANY answer carrying it.
void main() {
  test('server: the 403 detail is a machine-readable code', () {
    final s = File('backend/utils/security.py').readAsStringSync();
    expect(s, contains('raise HTTPException(403, f"account_{user.status}")'));
    expect(s.contains('raise HTTPException(403, f"Account {user.status}")'),
        isFalse,
        reason: 'prose detail is back — the app cannot parse prose');
  });

  test('app: _parse force-logs-out on account_blocked/account_deleted', () {
    final s = File('lib/services/api_service.dart').readAsStringSync();
    expect(s, contains('onAccountTerminated'));
    expect(s, contains("d == 'account_blocked'"));
    expect(s, contains("d == 'account_deleted'"));
    // The callback fires BEFORE the generic throw, like the
    // session_expired_new_device path above it.
    final iParse = s.indexOf("d == 'account_blocked'");
    final iCall = s.indexOf('onAccountTerminated?.call()');
    expect(iCall > iParse, isTrue);
  });

  test('main.dart wires the callback to leave the app', () {
    final s = File('lib/main.dart').readAsStringSync();
    expect(s, contains('ApiService.onAccountTerminated = ()'));
    expect(s, contains('pushAndRemoveUntil'));
  });

  test('the per-screen status check keeps deactivated working', () {
    // deactivated is NOT a 403 — the account still talks to the API so the
    // deactivated screen's support chat works. Pin both halves.
    final screen = File('lib/screens/driver/driver_online_offline.dart')
        .readAsStringSync();
    expect(screen, contains("status == 'deactivated'"));
    final sec = File('backend/utils/security.py').readAsStringSync();
    expect(sec, contains('in ("deleted", "blocked")'));
  });

  test('the driver-role eject lands on the role-select, never the rider home',
      () {
    // User report 2026-10-14: "cuando un driver se elimina desde el dispatch,
    // la pantalla se pasa a las páginas del rider — debe llevarlo al screen
    // de inicio donde seleccionan pasajero o conductor". Every driver screen
    // carries _enforceDriverRole; once the session/mode is gone the eject
    // must land on WelcomeScreen (Pasajero/Conductor), not the rider Home.
    for (final f in [
      'lib/screens/driver/driver_online_screen.dart',
      'lib/screens/driver/driver_menu_screen.dart',
      'lib/screens/driver/driver_profile_screen.dart',
      'lib/screens/driver/driver_settings_screen.dart',
      'lib/screens/driver/driver_inbox_screen.dart',
      'lib/screens/driver/driver_vehicle_screen.dart',
      'lib/screens/driver/driver_analytics_screen.dart',
      'lib/screens/driver/driver_trip_accept_screen.dart',
    ]) {
      final s = File(f).readAsStringSync();
      final i = s.indexOf('_enforceDriverRole()');
      expect(i, isNonNegative, reason: '$f: the role guard exists');
      final block = s.substring(i, i + 600);
      expect(block, contains('fadeThroughRoute(const WelcomeScreen())'),
          reason: '$f: ejects to the role-select screen');
      expect(block.contains('HomeScreen()'), isFalse,
          reason: '$f: the eject must NEVER land on the rider home');
    }
  });
}
