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
      expect(
          enterBody.contains('_connectSse()') ||
              enterBody.contains('_startPolling()'),
          isTrue,
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

    test(
        'leaving offline ends the shift for real — GO never reads RESUME '
        'afterwards (user report 2026-09-27)', () {
      final exit = ctrl.indexOf('Future<void> _exitOnlineMode(');
      expect(exit, isNonNegative);
      final exitBody = ctrl.substring(exit, exit + 900);
      expect(exitBody.contains('_driverWasOnlineAtBoot = false'), isTrue,
          reason: 'the pref goes false below, but the boot-time snapshot '
              'survived and the GO button read RESUME forever');
    });

    test(
        'the earnings pill hotspot is translucent — it must never absorb '
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

    test(
        'the GPS background flag is bound to the mode and the stream '
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

    test('returning to the screen always reclaims the map surface', () {
      // User report 2026-10-12: "después de ir a otra página y regresar al
      // home del driver el mapa se queda en negro". The handoff relied on
      // every push site remembering `_remountMapSurface()` in its `.then` —
      // one forgotten push left the surface revoked forever. Now the route
      // observer calls it on ANY return, and the style watchdog's retry is
      // per-mount again so a remount whose style never loads self-heals.
      final scr = File('lib/screens/driver/driver_online_screen.dart')
          .readAsStringSync();
      expect(
          scr.contains(
              'with TickerProviderStateMixin, WidgetsBindingObserver, RouteAware'),
          isTrue);
      expect(scr.contains('void didPopNext()'), isTrue);
      expect(scr.contains('mapRouteObserver.subscribe(this, route)'), isTrue);
      expect(scr.contains('mapRouteObserver.unsubscribe(this)'), isTrue);
      expect(scr.contains("logClientEvent('map_remount'"), isTrue);
      final w = File('lib/screens/driver/driver_online_widgets.dart')
          .readAsStringSync();
      expect(w, contains("logClientEvent('map_veil_watchdog'"),
          reason: 'the veil lifts itself and the server sees it');
      expect(w, contains("logClientEvent('map_style_watchdog_remount'"),
          reason: 'a mount whose style never loads remounts itself, once per '
              'mount');
    });
  });

  group('offline header — smooth alternating status + subtitle + wheel', () {
    // User spec 2026-10-14: the "You're offline" line alternates smoothly
    // with "No estás en línea", the subtitle "No recibirás ningún pedido de
    // viaje" sits under it (sheet open), and a steering-wheel badge rides to
    // the right of the open GO pill.
    final off = File('lib/screens/driver/driver_online_offline.dart')
        .readAsStringSync();
    final scr =
        File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
    final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

    test('the status clock flips in BOTH modes now', () {
      final i = scr.indexOf('_statusLineTimer = Timer.periodic(');
      expect(i, isNonNegative);
      final block = scr.substring(i, i + 700);
      expect(block.contains('!_driverOnline'), isFalse,
          reason: 'the tick used to be online-only — the offline header '
              'alternates on the same clock now');
      expect(block, contains('_statusLine = _statusLine == 0 ? 1 : 0'));
    });

    test('the header swaps smoothly and the subtitle gates on the open sheet',
        () {
      expect(off, contains('_SequentialSwapLabel('),
          reason: 'the header reuses the swap label');
      expect(off, contains('s.youreOffline : s.notOnline'),
          reason: 'the two phrasings alternate');
      expect(off, contains('s.offlineNoRideRequests'),
          reason: 'the subtitle under the status line');
      // 2026-10-16 spec: the description shows at the half-open rest — the
      // old 0.6 gate kept it hidden there; it still collapses with the
      // closed sheet (the strip keeps its 52 pt).
      expect(off, contains('panelFrac > 0.25'),
          reason: 'the subtitle is on at the half-open rest');
      expect(off, isNot(contains('panelFrac > 0.6')),
          reason: 'the 0.6 gate hid the subtitle at rest — dead');
      expect(l10n, contains('No estás en línea'));
      expect(l10n, contains('No recibirás ningún pedido de viaje'));
      expect(l10n, contains("You won't receive any ride requests"));
    });

    test('the status label crossfades — no cut, no empty beat (2026-10-16)',
        () {
      final w = File('lib/screens/driver/driver_online_widgets.dart')
          .readAsStringSync();
      expect(w, contains('child: AnimatedSwitcher('),
          reason: 'true crossfade: outgoing fades as incoming fades in');
      expect(w, contains('duration: const Duration(milliseconds: 400)'),
          reason: 'a smooth 400 ms both ways, not the old 180 ms blink');
      expect(w, contains('layoutBuilder:'),
          reason: 'the lines stack so the width glides instead of popping');
      expect(w, isNot(contains('_SequentialSwapLabelState')),
          reason: 'the sequential fade-out→gap→fade-in state machine died');
    });

    test('a calendar button rides right of the open GO pill (2026-10-16)', () {
      expect(off, contains('_GoScheduleButton('),
          reason: 'the calendar button is mounted beside the pill (replaces '
              'the decorative wheel)');
      expect(off, contains('Alignment.centerRight'),
          reason: 'it hugs the right edge of the GO row');
      expect(off, contains('Icons.calendar_month_rounded'),
          reason: 'calendar glyph, white on the dark disc with the gold rim');
      expect(off, contains('ignoring: t < 0.5'),
          reason: 'tappable only once the pill form is on — invisible must '
              'not eat map taps');
      expect(off, isNot(contains('_GoWheelBadge()')),
          reason: 'the decorative steering-wheel badge is gone');
    });

    test(
        'the calendar opens the scheduled-rides map and reclaims the '
        'surface on return', () {
      expect(
          off, contains('slideFromRightRoute(const ScheduledRidesMapScreen())'),
          reason: 'opens the scheduled map');
      final i = off.indexOf('void _openScheduledRides(');
      expect(i, isNonNegative);
      final block = off.substring(i, i + 700);
      expect(block, contains('_remountMapSurface()'),
          reason: 'the scheduled map takes the one native surface — claim it '
              'back on pop or the driver returns to a black map');
      expect(block, contains('_fetchScheduledCount()'),
          reason: 'the count badge refreshes too');
    });

    test(
        'the offline sheet crossfades hero (half-open) to the normal '
        'content (fully open)', () {
      expect(off, contains('_buildOfflineHero('),
          reason: 'the Dash-style hero face');
      expect(off, contains('(1 - (panelFrac - _kSheetRestFrac) / 0.3)'),
          reason: 'the hero owns the half-open rest and fades out on the way '
              'to fully open');
      expect(off, contains('((panelFrac - 0.55) / 0.3)'),
          reason: 'the normal list fades in as the sheet opens fully');
      // 2026-10-16 (foto 1 vs foto 2): the hero fills the sheet body and
      // distributes — no dead band between the card and the button row.
      expect(off, contains('Positioned.fill('),
          reason: 'the hero gets the full body height');
      expect(off, contains('mainAxisAlignment: MainAxisAlignment.spaceEvenly'),
          reason: 'headline and card spread across the sheet');
    });

    test('the hero demand card reads the live sector demand', () {
      expect(off, contains('ZoneService.sectorContaining('),
          reason: 'the driver position resolves its sector');
      expect(off, contains('ZoneService.demand['),
          reason: 'the card shows that sector demand level/bonus');
      expect(l10n, contains('Demanda en tu zona'));
      expect(l10n, contains('Demand in your area'));
      expect(l10n, contains('Tu zona está pidiendo drivers'));
      expect(l10n, contains('Ver viajes agendados'));
    });

    test('the menu is an in-screen left drawer (Dash style, 2026-10-16)', () {
      final scr = File('lib/screens/driver/driver_online_screen.dart')
          .readAsStringSync();
      final ctrl = File('lib/screens/driver/driver_online_controller.dart')
          .readAsStringSync();
      expect(off, contains('Widget _buildMenuDrawer()'),
          reason: 'the drawer overlay builder exists');
      expect(off, isNot(contains('const DriverMenuScreen()')),
          reason: 'the hamburger no longer pushes the full-screen menu — the '
              'drawer slides over the map (the page survives for the trip '
              'screen)');
      expect(scr, contains('if (_menuOpen) Positioned.fill(child: _buildMenuDrawer())'),
          reason: 'the drawer rides the root stack, topmost');
      expect(ctrl, contains('if (_menuOpen) {'),
          reason: 'back closes the drawer before flipping offline');
      expect(scr, contains('_menuCtrl?.dispose()'),
          reason: 'the controller dies with the screen');
    });

    test('the drawer carries the profile bubble and the existing options',
        () {
      expect(off, contains('_menuPhotoImage()'),
          reason: 'the photo bubble resolves url/local/server paths');
      expect(off, contains('_loadMenuIdentity'),
          reason: 'name + photo load cache-first from the session');
      for (final label in [
        's.earningsTitle',
        's.helpAndSafety',
        's.settingsTitle',
        's.cruiseLevelLabel',
        's.workHub',
        's.referFriends',
        's.scheduledTripsMenu',
        's.vehiclesLabel',
        's.documentsLabel',
        's.taxInfo',
        's.payoutMethodsLabel',
        's.learningCenter',
        's.bugReporter',
        's.aboutLabel',
        's.signOut',
      ]) {
        expect(off, contains(label), reason: 'menu option $label missing');
      }
      expect(off, contains('_menuScheduled'),
          reason: 'scheduled rides reuse the surface-reclaiming opener');
      expect(off, contains('UserSession.logout()'),
          reason: 'sign out keeps the offline-then-logout flow');
    });
  });
}
