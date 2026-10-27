import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the dispatch GO switch (owner spec 2026-10-23: "un botón
/// para desactivar y activar el botón de go online de cada driver y que
/// funcione instantaneo"). A paused driver sees a grey GO whose tap only
/// explains; the socket event applies it live (kicking an online driver
/// offline); the backend blocks with can_go_online reason + terminal 403.
void main() {
  final offline = File('lib/screens/driver/driver_online_offline.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final screen = File('lib/screens/driver/driver_online_screen.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final controller = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final socket = File('lib/services/socket_service.dart')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();
  final backendAdmin = File('backend/routers/admin.py')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');
  final backendDrivers = File('backend/routers/drivers.py')
      .readAsStringSync()
      .replaceAll('\r\n', '\n');

  test('backend: endpoint, socket event, blocking reason, terminal 403', () {
    expect(
        backendAdmin,
        contains(
            '@router.post("/admin/users/{user_id}/go-online-gate"'));
    expect(backendAdmin, contains('"go_online_gate_changed"'));
    expect(backendAdmin, contains('user.go_online_disabled = disabled'));
    expect(backendDrivers, contains('reasons.append("go_online_disabled")'));
    expect(backendDrivers, contains('"go_online_disabled": go_disabled'));
    expect(backendDrivers, contains('raise HTTPException(403, "go_online_disabled")'));
  });

  test('state field + canGoOnline read', () {
    expect(screen, contains('bool _goOnlineDisabled = false;'));
    expect(offline, contains("result['go_online_disabled'] == true"));
    expect(offline, contains('_goOnlineDisabled = goDisabled;'));
  });

  test('a paused GO only explains — it never flips', () {
    // Early gate inside _onGoTap.
    expect(
        offline,
        contains('if (_goOnlineDisabled) {\n'
            '      HapticService.mediumImpact();\n'
            '      _showGoOnlineDisabledDialog();\n'
            '      return;\n'
            '    }'));
    final compactOffline = offline.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      compactOffline,
      contains(
        'onTap: resting ? () => _showRestRemaining(restRemaining) '
        ': _goOnlineDisabled ? _showGoOnlineDisabledDialog',
      ),
    );
    expect(offline, contains('void _showGoOnlineDisabledDialog()'));
  });

  test('the paused GO paints dead grey, outranking the face gate', () {
    final compactOffline = offline.replaceAll(RegExp(r'\s+'), ' ');
    expect(
      compactOffline,
      contains(
        'final topPaint = resting ? const Color(0xFF6B6B70) '
        ': _goOnlineDisabled ? const Color(0xFF6B6B70)',
      ),
    );
    expect(
      compactOffline,
      contains(
        'final botPaint = resting ? const Color(0xFF4A4A4F) '
        ': _goOnlineDisabled ? const Color(0xFF4A4A4F)',
      ),
    );
  });

  test('socket: stream + live subscription + dispose cancel', () {
    expect(socket, contains("on('go_online_gate_changed'"));
    expect(socket, contains('get goOnlineGateStream'));
    expect(screen, contains('SocketService.goOnlineGateStream.listen'));
    expect(screen, contains('_goOnlineGateSub?.cancel();'));
    // Paused while online → the shift ends on the spot.
    expect(screen, contains('if (_driverOnline) unawaited(_exitOnlineMode());'));
  });

  test('the flip 403 is terminal (never retried)', () {
    expect(
        controller,
        contains("if (e is ApiException && e.message == 'go_online_disabled')"));
    expect(controller, contains('_setState(() => _goOnlineDisabled = true);'));
  });

  test('l10n strings ES/EN', () {
    for (final g in [
      'String get goOnlineDisabledTitle =>',
      'String get goOnlineDisabledBody =>',
      'String get goOnlineEnabledBody =>',
    ]) {
      expect(l10n, contains(g));
    }
    expect(l10n, contains("'No puedes conectarte'"),
        reason: 'owner spec 2026-10-24: no "Account paused" and no dispatch '
            'mention — neutral accurate copy');
    expect(l10n, contains('go online'));
    expect(l10n, contains('No puedes conectarte en este momento'));
    expect(l10n, contains('go online right now'));
  });
}
