import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the four owner requests of 2026-10-29 on the driver ONLINE
/// map screens:
///
///   1. the boot veil absorbs touches EXACTLY while it is visible;
///   2. online in a zone, the map outside the zone(s) dims a little;
///   3. the online sheet's left button is Help & Support (the menu's sheet)
///      and its right button pushes the scheduled-rides map on top through
///      the single-surface handoff;
///   4. the island / foreground notification exist only while online.
void main() {
  final widgets = File('lib/screens/driver/driver_online_widgets.dart')
      .readAsStringSync();
  final screen =
      File('lib/screens/driver/driver_online_screen.dart').readAsStringSync();
  final ctrl = File('lib/screens/driver/driver_online_controller.dart')
      .readAsStringSync();
  final map =
      File('lib/screens/driver/driver_online_map.dart').readAsStringSync();
  final offline = File('lib/screens/driver/driver_online_offline.dart')
      .readAsStringSync();
  final menu =
      File('lib/screens/driver/driver_menu_screen.dart').readAsStringSync();
  final bg = File('lib/services/background_service.dart').readAsStringSync();
  final session = File('lib/services/user_session.dart').readAsStringSync();
  final appDelegate = File('ios/Runner/AppDelegate.swift').readAsStringSync();

  group('1. boot veil vs gestures', () {
    test('the veil absorbs under the SAME condition as its opacity', () {
      final at = widgets.indexOf('absorbing: !(_mapStyleLoaded && _firstRenderDone)');
      expect(at, isNonNegative);
      final block = widgets.substring(
          widgets.lastIndexOf('Positioned.fill(', at),
          widgets.indexOf('// The marker, painted by Flutter', at));
      expect(block,
          contains('opacity: (_mapStyleLoaded && _firstRenderDone) ? 0.0 : 1.0'));
      expect(block, contains('AbsorbPointer('));
      expect(block, isNot(contains('ignoring: true')),
          reason: 'an always-on IgnorePointer let the finger pan the arrow');
      expect(block, contains('ignoring: _mapStyleLoaded && _firstRenderDone'),
          reason: 'the faded veil must also be hit-test transparent');
      expect(block, isNot(contains('_mapMounted')),
          reason: 'the old `!_mapMounted` absorb never released (c70b7407)');
    });
  });

  group('2. online zone dim', () {
    test('the dim follows the selected zone, else the home zone(s)', () {
      final fn = map.substring(
          map.indexOf('List<Sector> _zoneDimSectors('),
          map.indexOf('Future<void> _writeZoneDim('));
      expect(fn, contains('if (!visible || !online || _previewingOffer != null) return const [];'));
      expect(fn, contains('ZoneService.sectorById(sel)'));
      expect(fn, contains('ZoneService.sectorContaining(p)'));
      expect(fn, contains('ZoneService.sectorsForState(ZoneService.stateOfPoint(p))'));
    });

    test('"un poquito más oscuro, no mucho": black at 0.22, off when empty', () {
      expect(map, contains('static const double _kZoneDimOpacity = 0.22;'));
      expect(map, contains("'sec-dim', 'fill-opacity', holes.isEmpty ? 0.0 : _kZoneDimOpacity"));
      expect(map, contains('fillColor: 0xFF000000'));
      expect(map, isNot(contains("effectiveSec == null ? 0.0 : 0.25")));
    });

    test('the world ring with the zone(s) as holes sits below annotations', () {
      expect(map, contains('[-179.9, -85.0]'));
      expect(map, contains('_zoneAnnotationAnchor(map)'));
      expect(map, contains("id.toLowerCase().contains('annotation')"));
      expect(map, contains('mapbox.LayerPosition(below: dimBelowId)'));
    });

    test('the look signature carries the dim set so it repaints on change', () {
      expect(map, contains("'|dim:\$dim'"));
      expect('_zoneLookSig('.allMatches(map).length, greaterThanOrEqualTo(3),
          reason: 'both the sync and the live-swap path use the same sig');
      expect(map, isNot(contains("'\${visibleIds.join('|')}|offer:\${_previewingOffer != null}';")));
    });
  });

  group('3. online sheet buttons', () {
    test('the LEFT (health_and_safety) button opens the menu\'s Help & Support sheet',
        () {
      final at = widgets.indexOf('Icons.health_and_safety_outlined,');
      expect(at, isNonNegative);
      final block = widgets.substring(at, widgets.indexOf('_searchingLabel(textMuted)', at));
      expect(block, contains('showDriverHelpSheet(context)'));
      expect(block, contains('S.of(context).helpAndSupport'));
      expect(block, isNot(contains('SafetyScreen(')));
      // The online FAB column too — one destination for the same icon.
      final fab = screen.indexOf('Icons.health_and_safety_outlined,');
      expect(fab, isNonNegative);
      expect(screen.substring(fab, fab + 400), contains('showDriverHelpSheet(context)'));
      expect(screen, isNot(contains("import '../safety_screen.dart';")));
    });

    test('the menu and the sheet share ONE builder', () {
      expect(menu, contains('void showDriverHelpSheet(BuildContext context) {'));
      expect(menu, contains('void _showHelp(BuildContext context) => showDriverHelpSheet(context);'));
      expect('showModalBottomSheet('.allMatches(menu).length, 1);
    });

    test('the RIGHT (event_available) button pushes Scheduled Rides on top via the handoff',
        () {
      final at = widgets.indexOf('Icons.event_available_rounded,');
      expect(at, isNonNegative);
      expect(widgets.substring(at, at + 400), contains('onTap: _openScheduledRides'));
      final fn = offline.substring(
          offline.indexOf('void _openScheduledRides() {'),
          offline.indexOf('void _setRestUntil('));
      expect(fn, contains('Navigator.maybeOf(context)'),
          reason: 'outside build() only maybeOf (release-only null crash)');
      expect(fn, isNot(contains('Navigator.of(context)')));
      expect(fn, contains('slideFromRightRoute(const ScheduledRidesMapScreen())'));
      expect(fn, contains('_remountMapSurface();'),
          reason: 'the scheduled map takes the one surface; claim it back on pop');
      expect(fn, isNot(contains('_exitOnlineMode')),
          reason: 'the shift stays online while the page is open');
    });
  });

  group('4. island / notification pill only while online', () {
    test('the island is never raised or updated offline', () {
      final presence = ctrl.substring(
          ctrl.indexOf('void _showOnlinePresence() {'),
          ctrl.indexOf('LiveActivityService.startOnline();'));
      expect(presence, contains('if (!_driverOnline) return;'));
      final sync = ctrl.substring(
          ctrl.indexOf('void _syncOfferLiveActivity({bool force = false}) {'),
          ctrl.indexOf('LiveActivityService.updateStatus(next)'));
      expect(sync, contains('if (!_driverOnline) return;'));
    });

    test('going offline ends both — including while backgrounded', () {
      final exit = ctrl.substring(
          ctrl.indexOf('Future<void> _exitOnlineMode() async {'),
          ctrl.indexOf('_goOfflineBackend();', ctrl.indexOf('Future<void> _exitOnlineMode() async {')));
      expect(exit, contains('DriverBackgroundService().stop()'));
      final off = ctrl.substring(
          ctrl.indexOf('void _goOfflineBackend() {'),
          ctrl.indexOf('NotificationService.cancelDriverOnlineNotification();'));
      expect(off, contains('LiveActivityService.stop();'));
      expect(off, contains('_islandState = null;'));
      expect(off, contains('_presenceShown = false;'));
    });

    test('the foreground service starts only from the paused branch while online',
        () {
      final starts = 'DriverBackgroundService().start()'.allMatches(screen + ctrl + widgets + offline + map);
      expect(starts.length, 1);
      final at = screen.indexOf('DriverBackgroundService().start()');
      final branch = screen.substring(screen.lastIndexOf('if (_driverOnline) {', at), at);
      expect(branch, contains('_startBackgroundHeartbeat();'));
    });

    test('detached ends both indicators', () {
      final at = screen.indexOf('state == AppLifecycleState.detached');
      expect(at, isNonNegative);
      final branch = screen.substring(at, screen.indexOf('AppLifecycleState.resumed', at));
      expect(branch, contains('LiveActivityService.stop()'));
      expect(branch, contains('DriverBackgroundService().stop()'));
      expect(branch, contains('_stopBackgroundHeartbeat();'));
    });

    test('logout ends both on every path', () {
      final fn = session.substring(
          session.indexOf('static Future<void> logout() async {'),
          session.indexOf("await prefs.remove('driver_was_online');"));
      expect(fn, contains('LiveActivityService.stop()'));
      expect(fn, contains('DriverBackgroundService().stop()'));
    });

    test('the Android service never autostarts and ends itself without pings',
        () {
      expect(bg, contains('autoStartOnBoot: false'),
          reason: 'the plugin default (true) revived it after reboot/app update');
      expect(bg, contains('autoStart: false'));
      expect(bg, contains("service.on('heartbeat').listen((event) {"));
      expect(bg, contains('unawaited(service.stopSelf());'));
      expect(bg, contains('const Duration _kBgPingTimeout = Duration(seconds: 120);'));
      expect(bg, contains('void ping() {'));
      // The online heartbeat feeds the watchdog every 30 s.
      final hb = ctrl.substring(
          ctrl.indexOf('void _startBackgroundHeartbeat() {'),
          ctrl.indexOf('void _stopBackgroundHeartbeat() {'));
      expect(hb, contains('DriverBackgroundService().ping();'));
      expect(hb, contains('Duration(seconds: 30)'));
    });

    test('iOS ends the island when the app is terminated', () {
      expect(appDelegate, contains('override func applicationWillTerminate(_ application: UIApplication) {'));
      final at = appDelegate.indexOf('override func applicationWillTerminate');
      expect(appDelegate.substring(at, at + 300), contains('CruiseLiveActivityManager.shared.stop()'));
    });
  });
}
