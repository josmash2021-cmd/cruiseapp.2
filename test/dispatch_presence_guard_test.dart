import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Dispatch online/offline switch (owner spec 2026-10-29). The backend
/// latches a driver Dispatch took offline and answers 403 "dispatch_offline"
/// to every is_online=true write that is not the driver's own GO
/// (`explicit: true`). The app must: send `explicit` only from the GO path,
/// treat dispatch_offline as terminal everywhere, and react live to the
/// `dispatch_presence_set` socket event / push through the existing flows.
void main() {
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final socket = File('lib/services/socket_service.dart').readAsStringSync();
  final mainDart = File('lib/main.dart').readAsStringSync();
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final offline =
      File('lib/screens/driver/driver_online_offline.dart').readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  String body(String src, String signature, [int len = 2500]) {
    final i = src.indexOf(signature);
    expect(i, isNonNegative, reason: 'missing: $signature');
    return src.substring(i, (i + len).clamp(0, src.length));
  }

  test('api sends explicit only when asked', () {
    final fn = body(api, 'static Future<Map<String, dynamic>> updateDriverLocation(');
    expect(fn, contains('bool explicit = false,'));
    expect(fn, contains("if (explicit) 'explicit': true,"));
  });

  test('only the GO write carries explicit, armed by the GO tap', () {
    // Exactly one call site in the controller passes explicit.
    // Argument lines only (comments mention the word too).
    expect(RegExp(r'^\s+explicit:', multiLine: true).allMatches(ctrl).length,
        1);
    final go = body(ctrl, 'void _goOnlineBackend() {', 3000);
    expect(go, contains('_wentOffline = false;'));
    expect(go, contains('explicit: _explicitGoPending,'));
    // Armed by the GO tap right before the mode flip, never by a resume.
    final tap = body(offline, 'void _onGoTap() async {', 20000);
    final arm = tap.indexOf('_explicitGoPending = true;');
    expect(arm, isNonNegative);
    expect(tap.indexOf('await _enterOnlineMode(', arm), greaterThan(arm));
    // Disarmed on exit so a later boot-resume write cannot carry it.
    final exit = body(ctrl, 'Future<void> _exitOnlineMode() async {', 400);
    expect(exit, contains('_explicitGoPending = false;'));
    expect(screen, contains('bool _explicitGoPending = false;'));
  });

  test('dispatch_offline is terminal on every online write', () {
    // GO write, heartbeat, 5 s GPS stream, poll heartbeat.
    expect("e.message == 'dispatch_offline'".allMatches(ctrl).length, 4);
    final go = body(ctrl, 'void _goOnlineBackend() {', 9000);
    final i = go.indexOf("e.message == 'dispatch_offline'");
    expect(i, isNonNegative);
    final branch = go.substring(i, i + 200);
    expect(branch, contains('_onDispatchOfflineKick();'));
    expect(branch, contains('return;'));
    // Retry loop sits after the terminal branch, never before it.
    expect(go.indexOf('Retrying _goOnlineBackend'), greaterThan(i));
    final kick = body(ctrl, 'void _onDispatchOfflineKick() {', 500);
    expect(kick, contains('unawaited(_exitOnlineMode());'));
    expect(kick, isNot(contains('Dialog')));
    expect(kick, contains('_hasLiveTrip'));
  });

  test('socket event feeds the presence stream the screen listens to', () {
    expect(socket, contains("_socket!.on('dispatch_presence_set'"));
    expect(socket, contains('_dispatchPresenceController.add(map);'));
    expect(socket, contains('static void injectDispatchPresence(bool online)'));
    expect(screen,
        contains('SocketService.dispatchPresenceStream.listen(_onDispatchPresenceSet)'));
    expect(screen, contains('_dispatchPresenceSub?.cancel();'));
  });

  test('push type is forwarded on tap and in foreground', () {
    expect("type == 'dispatch_presence_set'".allMatches(mainDart).length, 2);
    expect("SocketService.injectDispatchPresence(".allMatches(mainDart).length, 2);
    expect(mainDart, contains("message.data['online']?.toString() == '1'"));
  });

  test('both directions run the existing flows', () {
    final h = body(ctrl, 'void _onDispatchPresenceSet(Map<String, dynamic> data) {', 2500);
    // online=true: same action as the GO button (all gates apply).
    expect(h, contains('_goTapAction()'));
    expect(offline, contains('onTap: _goTapAction(),'));
    final action = body(offline, 'VoidCallback? _goTapAction() {', 900);
    expect(action, contains('_showRestRemaining'));
    expect(action, contains('_showGoOnlineDisabledDialog'));
    expect(action, contains('_onFaceVerifyTap'));
    expect(action, contains('_onGoTap'));
    // online=false: pop to home + the normal offline exit, never mid-trip.
    expect(h, contains('_popToDriverHome();'));
    expect(h, contains('unawaited(_exitOnlineMode());'));
    final tripGuard = h.indexOf('if (_hasLiveTrip)');
    expect(tripGuard, isNonNegative);
    expect(h.indexOf('_popToDriverHome();'), greaterThan(tripGuard));
    expect(h, contains('_dispatchOfflinePending = true;'));
    // The deferred exit runs once the trip is over.
    expect(ctrl, contains('void _flushDeferredDispatchOffline() {'));
    expect('_flushDeferredDispatchOffline();'.allMatches(ctrl).length,
        greaterThanOrEqualTo(3));
    // Outside build: maybeOf only.
    final pop = body(ctrl, 'void _popToDriverHome() {', 600);
    expect(pop, contains('Navigator.maybeOf(context)'));
    final notice = body(ctrl, 'void _showDispatchPresenceNotice(', 700);
    expect(notice, contains('ScaffoldMessenger.maybeOf(context)'));
  });

  test('copy exists in both languages', () {
    for (final g in ['dispatchPresenceOffline', 'dispatchPresenceOnline']) {
      expect(l10n, contains('String get $g'));
      expect(ctrl, contains('s.$g'));
    }
    // Owner copy 2026-10-29 — never mentions Dispatch.
    expect(l10n, contains('Has sido desconectado'));
    expect(l10n, contains('No estás recibiendo viajes'));
    expect(l10n, contains('Estás conectado'));
    expect(l10n, contains('Disponible para recibir viajes'));
    expect(l10n, contains('You have been disconnected'));
    expect(l10n, contains('Available to receive rides'));
    expect(l10n, isNot(contains('Dispatch te desconectó')));
    expect(l10n, isNot(contains('Dispatch te conectó')));
  });
}
