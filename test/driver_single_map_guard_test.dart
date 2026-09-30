import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the single-map merge (user spec 2026-09-26: "quiero que sea
/// uno, como Lyft"): ONE permanent map for the driver; online/offline are
/// MODES of `DriverOnlineScreen`, not two routes.
///
///   * online mode = offers arrive (SSE + poll + heartbeat + background GPS
///     + Live Activity); offline mode = the same map, nothing listening.
///   * The flip is in-place: no push, no surface handoff, no snapshot gap.
void main() {
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();

  group('the old home screen is gone', () {
    test('DriverHomeScreen does not exist and nothing pushes it', () {
      expect(File('lib/screens/driver/driver_home_screen.dart').existsSync(),
          isFalse,
          reason: 'the two-screen split is the bug class this merge kills');
      for (final dir in ['lib/screens', 'lib']) {
        for (final entity in Directory(dir).listSync()) {
          if (entity is! File || !entity.path.endsWith('.dart')) continue;
          if (entity.path.endsWith('driver_online_offline.dart')) continue;
          final src = entity.readAsStringSync();
          expect(src.contains('DriverHomeScreen('), isFalse,
              reason: '${entity.path} still pushes the deleted home screen');
        }
      }
    });
  });

  group('the mode machine', () {
    test('enter/exit exist and own the channels and the backend', () {
      final enter = ctrl.indexOf('Future<void> _enterOnlineMode(');
      expect(enter, isNonNegative);
      final enterBody = ctrl.substring(enter, enter + 5000);
      expect(enterBody.contains('_goOnlineBackend()'), isTrue);
      expect(enterBody.contains('_connectSse()') ||
          enterBody.contains('_startPolling()'), isTrue,
          reason: 'entering online starts the offer channels');
      expect(enterBody.contains('_showOnlinePresence()'), isTrue);

      final exit = ctrl.indexOf('Future<void> _exitOnlineMode(');
      expect(exit, isNonNegative);
      final exitBody = ctrl.substring(exit, exit + 1800);
      expect(exitBody.contains('_goOfflineBackend()'), isTrue);
      expect(exitBody.contains('_offerSseSub?.cancel()'), isTrue);
      expect(exitBody.contains('_pollT?.cancel()'), isTrue);
      expect(exitBody.contains('_gpsService.stopTracking()'), isTrue,
          reason: 'offline silences the position uploads');
    });

    test('the flip never navigates — the map never hears about it', () {
      final enter = ctrl.indexOf('Future<void> _enterOnlineMode(');
      final body = ctrl.substring(enter, enter + 2600);
      expect(body.contains('Navigator.of(context).push'), isFalse,
          reason: 'a push on the flip is the two-screen split coming back');
      expect(body.contains('_suspendMap'), isFalse);
      final exit = ctrl.indexOf('Future<void> _exitOnlineMode(');
      final exitBody = ctrl.substring(exit, exit + 1800);
      expect(exitBody.contains('pushAndRemoveUntil'), isFalse,
          reason: 'the old _goOffline ended in a home push — dead now');
    });

    test('leaving offline ends the shift for real — GO never reads RESUME '
        'afterwards (user report 2026-09-27)', () {
      final exit = ctrl.indexOf('Future<void> _exitOnlineMode(');
      expect(exit, isNonNegative);
      final exitBody = ctrl.substring(exit, exit + 900);
      expect(exitBody.contains('_driverWasOnlineAtBoot = false'), isTrue,
          reason: 'the pref goes false below, but the boot-time snapshot '
              'survived and the GO button read RESUME forever');
    });

    test('the earnings pill hotspot is translucent — it must never absorb '
        'taps meant for the menu button (user report 2026-09-27: "el botón '
        'del menú no abre")', () {
      final hotspot = screen.indexOf('onLongPress: toggleMotionDiag');
      expect(hotspot, isNonNegative);
      final window = screen.substring(hotspot - 300, hotspot + 100);
      expect(window.contains('HitTestBehavior.translucent'), isTrue);
      expect(window.contains('HitTestBehavior.opaque'), isFalse,
          reason: 'a full-width OPAQUE detector over the top band absorbed '
              'every tap before it reached the menu button below it in the '
              'Stack — the bell survived only because it stacks ABOVE it');
    });

    test('the GPS background flag is bound to the mode and the stream '
        'is recreated on every flip', () {
      expect(ctrl.contains('background: _driverOnline'), isTrue,
          reason: 'regla 2026-08-22: offline = foreground-only GPS');
      final sync = ctrl.indexOf('void _syncPosStreamMode()');
      expect(sync, isNonNegative);
      final body = ctrl.substring(sync, sync + 500);
      expect(body.contains('_startPosStream()'), isTrue,
          reason: 'iOS only applies the background flag on a NEW request — '
              'the stream must be recreated, not just flagged');
    });

    test('offers and heartbeat only run while online', () {
      expect(ctrl.contains('if (!_driverOnline) return;'), isTrue,
          reason: '_applyOffers must not process offers offline');
      final pause = screen.indexOf('if (state == AppLifecycleState.paused)');
      expect(pause, isNonNegative);
      final body = screen.substring(pause, pause + 1200);
      expect(body.contains('if (_driverOnline)'), isTrue,
          reason: 'the background heartbeat / foreground service are '
              'online-only — offline there is no shift to keep alive');
    });

    test('the boot enters online only for real work entries', () {
      final boot = ctrl.indexOf('Future<void> _boot() async {');
      expect(boot, isNonNegative);
      final body = ctrl.substring(boot, boot + 4400);
      expect(body.contains('_enterOnlineMode(resuming: true)'), isTrue,
          reason: 'only real work entries auto-enter: trip resume, offer '
              'tap, chained handoff');
      expect(body.contains('wasOnline) {'), isFalse,
          reason: 'user report 2026-09-27: "cuando el driver inicia sesion '
              'automaticamente aparece online" — the was-online pref alone '
              'used to auto-enter online on login; now it only feeds the '
              'RESUME label, and an offer push is the way back without a tap');
    });
  });
}
