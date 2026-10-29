import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:cruise_app/config/page_transitions.dart';

/// Guardian for the single-map merge (user spec 2026-09-26: "quiero que sea
/// uno, como Lyft"): ONE permanent map for the driver; online/offline are
/// MODES of `DriverOnlineScreen`, not two routes.
///
///   * online mode = offers arrive (SSE + poll + heartbeat + background GPS
///     + Live Activity); offline mode = the same map, nothing listening.
///   * The flip is in-place: no push, no surface handoff, no snapshot gap.
void main() {
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync()
      // Fixed-size windows below are LF offsets; a CRLF checkout (Windows,
      // core.autocrlf) must not push a call out of them.
      .replaceAll('\r\n', '\n');
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
      final enterBody = ctrl.substring(enter, enter + 7000);
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
      // 2026-10-17 ("no quiero que se quede en negro al volver de Schedule"):
      // el handoff captura la foto REAL del mapa antes de soltarlo y el velo
      // la prefiere sobre el snapshot de red — cero negro en el remount.
      final ctrl = File('lib/screens/driver/driver_online_controller.dart')
          .readAsStringSync();
      expect(scr, contains('Uint8List? _surfaceStillBytes'),
          reason: 'the still field exists');
      expect(ctrl, contains('_captureSurfaceStill()'),
          reason: 'the handoff captures the real map before releasing');
      final w2 = File('lib/screens/driver/driver_online_widgets.dart')
          .readAsStringSync();
      expect(w2, contains('Image.memory('),
          reason: 'the veil prefers the captured still');
      expect(w2, contains('setSnapshotLegacyMode(true)'),
          reason: 'Android textureView vendor workaround for the snapshot');
      expect(ctrl, contains('m.snapshot().timeout(const Duration(seconds: 2))'),
          reason: 'the capture is bounded, never hangs the handoff');
      final w = File('lib/screens/driver/driver_online_widgets.dart')
          .readAsStringSync();
      expect(w, contains("logClientEvent('map_veil_watchdog'"),
          reason: 'the veil lifts itself and the server sees it');
      expect(w, contains("logClientEvent('map_style_watchdog_remount'"),
          reason: 'a mount whose style never loads remounts itself, once per '
              'mount');
    });

    test('the boot veil absorbs only while loading, released by its own flags',
        () {
      // 2026-10-29 (owner: "cuando el mapa está cargando, al tocarlo se
      // puede mover la flecha con los dedos"). History: an earlier
      // `AbsorbPointer(absorbing: !_mapMounted)` never released and killed
      // drags/zone taps (c70b7407 made it IgnorePointer). The rule now: the
      // veil absorbs EXACTLY while it is visible — same expression as its
      // opacity — so the moment it fades, gestures pass.
      final widgets = File('lib/screens/driver/driver_online_widgets.dart')
          .readAsStringSync();
      final start = widgets.indexOf(
          'absorbing: !(_mapStyleLoaded && _firstRenderDone)');
      expect(start, isNonNegative,
          reason: 'the veil absorbs under its own visibility condition');
      final veilStart = widgets.lastIndexOf('Positioned.fill(', start);
      final end = widgets.indexOf('// The marker, painted by Flutter', start);
      expect(end, greaterThan(start));
      final veil = widgets.substring(veilStart, end);
      expect(veil, contains('AbsorbPointer('));
      expect(
        veil,
        contains('opacity: (_mapStyleLoaded && _firstRenderDone) ? 0.0 : 1.0'),
        reason: 'the veil still fades after the first real render',
      );
      expect(veil, isNot(contains('ignoring: true')),
          reason: 'IgnorePointer let the finger pan the arrow under the veil');
      expect(veil, contains('ignoring: _mapStyleLoaded && _firstRenderDone'),
          reason: 'the faded veil is hit-test transparent: a painted child '
              'swallows taps inside a Stack even when nothing absorbs');
      expect(veil, isNot(contains('_mapMounted')),
          reason: 'the old flag never released — drags and zone taps died');
    });

    testWidgets('the veil blocks taps/drags while loading and passes them once '
        'its flags flip', (tester) async {
      var taps = 0;
      var drag = Offset.zero;
      Widget build({required bool styleLoaded, required bool firstRender}) {
        final ready = styleLoaded && firstRender;
        return MaterialApp(
          home: Stack(
            fit: StackFit.expand,
            children: [
              GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => taps++,
                onPanUpdate: (details) => drag += details.delta,
                child: const SizedBox.expand(),
              ),
              // Same shape as the real veil: painted child (the snapshot
              // fallback is one) — without the outer IgnorePointer it keeps
              // swallowing taps after the absorb releases.
              IgnorePointer(
                ignoring: ready,
                child: AbsorbPointer(
                  absorbing: !ready,
                  child: AnimatedOpacity(
                    opacity: ready ? 0.0 : 1.0,
                    duration: Duration.zero,
                    child: Container(color: const Color(0xFF0A1128)),
                  ),
                ),
              ),
            ],
          ),
        );
      }

      // Loading: veil visible → nothing reaches the map.
      await tester.pumpWidget(build(styleLoaded: false, firstRender: false));
      await tester.tapAt(const Offset(200, 300));
      await tester.dragFrom(const Offset(200, 300), const Offset(64, 32));
      expect(taps, 0);
      expect(drag, Offset.zero);

      // Style landed but no frame yet: still veiled, still blocked.
      await tester.pumpWidget(build(styleLoaded: true, firstRender: false));
      await tester.tapAt(const Offset(200, 300));
      expect(taps, 0);

      // Both flags true: veil gone, gestures pass.
      await tester.pumpWidget(build(styleLoaded: true, firstRender: true));
      await tester.tapAt(const Offset(200, 300));
      await tester.dragFrom(const Offset(200, 300), const Offset(64, 32));
      expect(taps, 1);
      expect(drag.dx, greaterThan(0));
      expect(drag.dy, greaterThan(0));
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

    test('the GO calendar wears the animated available-rides count', () {
      expect(off, contains('count: _scheduledAvailCount'));
      expect(off, contains('bounceAnimation: _scheduledBounceAnim'));
      expect(off, contains('if (count > 0)'));
      expect(off, contains('AnimatedSwitcher('));
      expect(off, contains("count > 99 ? '99+' : '\$count'"));
    });

    test('scheduled counts refresh by push in both modes and latest-wins', () {
      expect(screen, contains('.addListener(_onScheduledRidePush)'));
      expect(screen, contains('.removeListener(_onScheduledRidePush)'));
      expect(ctrl, contains('const Duration(seconds: 30)'));
      expect(ctrl, contains('radiusKm: 50'));
      expect(ctrl, contains('seq != _scheduledCountSeq'));
      final exitAt = ctrl.indexOf('Future<void> _exitOnlineMode(');
      expect(exitAt, isNonNegative);
      final exit = ctrl.substring(exitAt, exitAt + 1400);
      expect(exit, isNot(contains('_scheduledPollTimer?.cancel()')),
          reason: 'offline still needs the badge beside GO');
    });

    test('every Schedule entry uses the shared normal-map route', () {
      final widgets = File('lib/screens/driver/driver_online_widgets.dart')
          .readAsStringSync();
      expect(off, contains('onTap: _openScheduledRides'));
      expect(widgets, contains('onTap: _openScheduledRides'));
      expect(off, isNot(contains('ScheduledRidesScreen(initialTab: 0)')),
          reason: 'the reserved card must not open the alternate tabs page');
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
      // 2026-10-16 noche (foto 2 = Dash): contenido compacto ARRIBA y el
      // padding de abajo libra la fila de botones flotante — el spaceEvenly
      // dejaba el headline a media pantalla y la tarjeta cortada debajo del
      // botón GO (foto 1).
      expect(off, contains('Positioned.fill('),
          reason: 'the hero gets the full body height');
      // Acotado a la región del hero: el menú clásico tiene su propio
      // ListView; esta regla de acomodo es exclusiva del hero.
      final heroIdx = off.indexOf('Widget _buildOfflineHero(');
      expect(heroIdx, isNonNegative);
      final heroRegion = off.substring(heroIdx, heroIdx + 2200);
      expect(heroRegion, isNot(contains('MainAxisAlignment.spaceEvenly')),
          reason: 'spaceEvenly spread the hero wrong — compact top-down now');
      // 2026-10-17 (foto 2 bis, "un poquito mas cerrado"): el reposo del
      // sheet abraza el contenido — 0.42, no 0.5 con banda muerta debajo de
      // la tarjeta de demanda.
      expect(off, contains('const double _kSheetRestFrac = 0.42;'),
          reason: 'the sheet rests compact, hugging the content');
      expect(off, contains('_kGoPillH + 26 + pad.bottom'),
          reason: 'the hero clears the floating GO pill + calendar row');
    });

    test('the hero demand card follows the selected zone and first load', () {
      expect(off, contains('final selectedId = _selectedZoneName;'));
      final selectedIdx = off.indexOf('ZoneService.sectorById(selectedId)');
      final gpsIdx = off.indexOf('ZoneService.sectorContaining(', selectedIdx);
      expect(selectedIdx, isNonNegative);
      expect(gpsIdx, greaterThan(selectedIdx),
          reason: 'the selected zone wins; GPS is only the fallback');
      expect(off, contains('ZoneService.demand['),
          reason: 'the card shows that sector demand level/bonus');
      final widgets = File('lib/screens/driver/driver_online_widgets.dart')
          .readAsStringSync();
      expect(widgets, contains('ZoneService.loadDemand(force: true)'));
      expect(widgets, contains('if (!_driverOnline) _setState(() {});'),
          reason: 'the first demand response refreshes the hero immediately');
      expect(l10n, contains('Demanda en tu zona'));
      expect(l10n, contains('Demand in your area'));
      expect(l10n, contains('Tu zona está pidiendo drivers'));
      expect(l10n, contains('Ver viajes agendados'));
    });

    test('the menu opens the classic full screen with a smooth left route',
        () {
      final scr = File('lib/screens/driver/driver_online_screen.dart')
          .readAsStringSync();
      final ctrl = File('lib/screens/driver/driver_online_controller.dart')
          .readAsStringSync();
      final transitions = File('lib/config/page_transitions.dart')
          .readAsStringSync();
      final openStart = off.indexOf('Future<void> _openDriverMenu()');
      final openEnd = off.indexOf("/// The offline chrome's menu button.", openStart);
      expect(openStart, isNonNegative);
      expect(openEnd, greaterThan(openStart));
      final open = off.substring(openStart, openEnd);
      expect(open, contains('slideFromLeftRoute(const DriverMenuScreen())'),
          reason: 'the hamburger opens the classic full-screen menu');
      expect(open, contains('if (_menuRouteOpen) return;'),
          reason: 'a double tap cannot push two menu routes');
      expect(open, contains('finally {'),
          reason: 'the guard always resets, even if navigation fails');
      expect(open, contains('_remountMapSurface()'),
          reason: 'returning from a nested map reclaims the driver surface');
      expect(scr, contains("import 'driver_menu_screen.dart';"));
      expect(scr, isNot(contains('_menuOpen')));
      expect(ctrl, isNot(contains('_menuOpen')));
      for (final deadDrawer in [
        '_driverMenuRoute',
        '_buildMenuDrawerContent',
        '_loadMenuIdentity',
        '_menuSectionGroup',
        '_menuSignOut',
      ]) {
        expect(off, isNot(contains(deadDrawer)),
            reason: 'the parallel drawer implementation must stay removed');
      }

      final routeStart = transitions.indexOf('Route<T> slideFromLeftRoute');
      expect(routeStart, isNonNegative);
      final route = transitions.substring(routeStart, routeStart + 1200);
      expect(route, contains('PageRouteBuilder<T>('));
      expect(route, contains('opaque: true'),
          reason: 'this is a full page, not a transparent drawer');
      expect(route, contains('begin: const Offset(-1, 0)'),
          reason: 'the page enters from the left edge');
      expect(route, contains('Curves.easeOutCubic'));
      expect(route, contains('reverseCurve: Curves.easeInCubic'));
      expect(route, contains('SlideTransition'));
    });

    test('the classic menu keeps its profile, options and sign out', () {
      final menu = File('lib/screens/driver/driver_menu_screen.dart')
          .readAsStringSync();
      expect(menu, contains('Scaffold('));
      expect(menu, contains('_profileCard(context)'));
      expect(menu, contains('_quickActionsRow(context)'));
      for (final label in [
        'earningsTitle',
        'helpAndSafety',
        'settingsTitle',
        'cruiseLevelLabel',
        'workHub',
        'referFriends',
        'scheduledTripsMenu',
        'vehiclesLabel',
        'documentsLabel',
        'taxInfo',
        'payoutMethodsLabel',
        'learningCenter',
        'bugReporter',
        'aboutLabel',
        'signOut',
      ]) {
        expect(menu, contains(label), reason: 'menu option $label missing');
      }
      expect(menu, contains('UserSession.logout()'),
          reason: 'sign out keeps the offline-then-logout flow');
      expect(menu, contains('ListView('),
          reason: 'the classic page keeps its normal content scroll');
    });
  });

  testWidgets('the left route pushes and pops a full-size page', (tester) async {
    const menuKey = Key('classic-menu-page');
    late PageRouteBuilder<void> menuRoute;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: ElevatedButton(
                onPressed: () {
                  menuRoute = slideFromLeftRoute<void>(
                    const Scaffold(
                      key: menuKey,
                      body: SizedBox.expand(),
                    ),
                  ) as PageRouteBuilder<void>;
                  Navigator.of(context).push(menuRoute);
                },
                child: const Text('Open menu'),
              ),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open menu'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 16));
    expect(menuRoute.animation!.value, greaterThan(0));
    expect(menuRoute.animation!.value, lessThan(1));
    final startDx = tester.getTopLeft(find.byKey(menuKey, skipOffstage: false)).dx;
    expect(startDx, lessThan(0));

    await tester.pump(const Duration(milliseconds: 160));
    final middleDx = tester.getTopLeft(find.byKey(menuKey, skipOffstage: false)).dx;
    expect(middleDx, greaterThan(startDx));

    await tester.pumpAndSettle();
    expect(tester.getTopLeft(find.byKey(menuKey, skipOffstage: false)).dx, 0);
    final logicalSize =
        tester.view.physicalSize / tester.view.devicePixelRatio;
    expect(tester.getSize(find.byKey(menuKey, skipOffstage: false)), logicalSize);

    tester.state<NavigatorState>(find.byType(Navigator)).pop();
    await tester.pumpAndSettle();
    expect(find.byKey(menuKey, skipOffstage: false), findsNothing);
    expect(find.text('Open menu'), findsOneWidget);
  });
}
