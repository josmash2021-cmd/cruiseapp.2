import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guard for dispatch terminal account actions: every old session must close
/// on web and app, while a fresh login after revocation remains possible.
void main() {
  test('server revokes by account and validates old vs new JWT timestamps', () {
    final s = File('backend/utils/security.py').readAsStringSync();
    expect(s, contains('revoke_account_sessions'));
    expect(s, contains('account_revocation_reason'));
    expect(s, contains('account_revoked'));
    expect(s, contains('account_deactivated'));
    expect(s, contains('int(issued_ts) < int(revoked_at.timestamp())'));
  });

  test('dispatch emits and revokes on status, bulk-status and delete', () {
    final s = File('backend/routers/admin.py').readAsStringSync();
    expect(s, contains('_terminate_account_session'));
    expect(s, contains('account_status_changed'));
    expect(s, contains('revoke_account_sessions'));
    expect(
        s, contains('await _terminate_account_session(db, user, "deleted")'));
  });

  test('app ApiService force-logs-out on every terminal/revoked code', () {
    final s = File('lib/services/api_service.dart').readAsStringSync();
    for (final code in [
      'account_blocked',
      'account_deleted',
      'account_deactivated',
      'account_revoked',
    ]) {
      expect(s, contains("d == '$code'"), reason: '$code missing');
    }
    expect(s, contains('onAccountTerminated?.call()'));
    expect(s, contains("if (detail == 'User not found') return 'deleted';"));
    expect(s, contains("detail.startsWith('account_')"));
  });

  test('a single global guard covers every screen and rearms on new login', () {
    final guard =
        File('lib/services/account_session_guard.dart').readAsStringSync();
    expect(guard, contains('SocketService.accountStatusStream.listen'));
    expect(guard, contains('Timer.periodic(const Duration(seconds: 60)'));
    expect(guard, contains('handleRevoked'));
    expect(guard, contains('UserSession.logout()'));
    expect(guard, contains('UserSession.isLoggedInLocal()'));

    final main = File('lib/main.dart').readAsStringSync();
    expect(main, contains('AccountSessionGuard.init()'));
    expect(main, contains('AccountSessionGuard.reset()'));
    expect(main, contains('AccountSessionGuard.check()'));
    expect(main, contains('pushAndRemoveUntil'));
  });

  test('home keeps only approval handling and no duplicate termination path',
      () {
    final s = File('lib/screens/home_screen.dart').readAsStringSync();
    expect(s, contains("status != 'approved'"));
    expect(s.contains('_accountStatusTimer'), isFalse);
    expect(s.contains('AccountDeactivatedScreen'), isFalse);
  });

  test('web guard closes within 5 seconds on every page without wiping drafts',
      () {
    final s = File('../cruisewebsite/assets/nav-role.js').readAsStringSync();
    expect(s, contains('setInterval(check, 5000)'));
    expect(s, contains('forceLogout'));
    expect(s, contains('pending_deletion'));
    expect(s, contains('account_revoked'));
    expect(s, contains('r.status === 404'));
    expect(s, contains("removeItem('vr_at')"));
    expect(s, contains("removeItem('vr_au')"));
    expect(s, contains('/en/auth'));
    expect(s.contains('vr_book_state'), isFalse);
  });

  test('driver-role eject still lands on role-select, never rider home', () {
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
      final i = s.indexOf('void _enforceDriverRole()');
      expect(i, isNonNegative, reason: '$f: the role guard exists');
      final block = s.substring(i, i + 600);
      expect(block, contains('fadeThroughRoute(const WelcomeScreen())'),
          reason: '$f: ejects to the role-select screen');
      expect(block.contains('HomeScreen()'), isFalse,
          reason: '$f: the eject must NEVER land on the rider home');
    }
  });
}
