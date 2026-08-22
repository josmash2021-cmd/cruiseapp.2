import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 2026-08-22 rider-home redesign (Lyft-style, navy/gold):
///   1. The dock is pinned OUTSIDE the scroll view (it can never scroll
///      away or miss the first paint) and the active tab carries no gold
///      pill — brightness only. Ride tab shows the Cruise mark.
///   2. The circular Priority / Schedule / 10%-off shortcut row is gone
///      (UI only — the promo data load stays for the request flow).
///   3. The hero is "Ride / Schedule" with two entries, and BOTH gate
///      through _ensureVerified (the standing rule from
///      rider_verification_guard_test.dart: always paint, gate on tap).
///   4. The cold-start permissions page exists and sends the rider to
///      system Settings.
///
/// Source-grep style, like driver_scheduled_neu_guard_test.dart.
void main() {
  final widgets =
      File('lib/screens/home_screen_widgets.dart').readAsStringSync();
  final home = File('lib/screens/home_screen.dart').readAsStringSync();

  group('dock', () {
    final sheetStart = widgets.indexOf('Widget _buildSheet(');
    final sheetBlock = widgets.substring(sheetStart, sheetStart + 8000);

    test('is pinned outside the scroll view, so it is always visible', () {
      // The dock call must live in the sheet's outer Stack AFTER the
      // CustomScrollView closes, not inside the sliver list.
      final scrollEnd = sheetBlock.lastIndexOf('CustomScrollView(');
      final dockCall = sheetBlock.indexOf('_buildDockNav(context, botPad)');
      final positioned = sheetBlock.indexOf('Positioned(');
      expect(dockCall, greaterThan(-1));
      expect(positioned, greaterThan(-1));
      // A Positioned sibling after the scroll view — never inside it.
      final dockPositioned = sheetBlock.lastIndexOf('Positioned(');
      expect(dockPositioned, greaterThan(scrollEnd));
    });

    test('the active tab has no gold pill — neutral like the rest', () {
      final start = widgets.indexOf('Widget _buildDockNav(');
      final block = widgets.substring(start, start + 2200);
      expect(block, isNot(contains('LinearGradient')),
          reason: 'the gold gradient pill on the active tab was removed');
      expect(block, isNot(contains('boxShadow')),
          reason: 'the active tab glow left with the pill');
      // The active state is brightness only.
      expect(block, contains('active ? Colors.white'));
    });

    test('the Ride tab carries the Cruise logo', () {
      final start = widgets.indexOf('Widget _buildDockNav(');
      final block = widgets.substring(start, start + 2200);
      expect(block, contains('assets/images/cruise_logo.png'));
      expect(block, isNot(contains('Icons.explore_rounded')),
          reason: 'the compass icon was replaced by the Cruise mark');
    });
  });

  group('removed chrome', () {
    test('the circular shortcut row is gone', () {
      expect(widgets, isNot(contains('_buildCircularActions(')),
          reason: 'the Priority / Schedule / 10%-off row must stay deleted');
    });

    test('the bell and gear left the top bar', () {
      final start = widgets.indexOf('Widget _buildTopBar(');
      final block = widgets.substring(start, start + 1500);
      expect(block, isNot(contains('Icons.notifications_none_rounded')));
      expect(block, isNot(contains('Icons.settings_rounded')));
    });

    test('the promo data load survives (logic, not UI)', () {
      // The monthly promo generation + inbox notification stay; only the
      // home chip and its dialogs left.
      expect(home, contains('LocalDataService.generateMonthlyPromoIfNeeded()'));
    });
  });

  group('hero Ride / Schedule', () {
    final start = widgets.indexOf('Widget _buildHeroCTA() {');
    final block = widgets.substring(start, start + 4000);

    test('keeps the verification gate on the way out', () {
      expect(block, contains('_ensureVerified()'));
      expect(block, isNot(contains('verificationBlocked')));
    });

    test('Ride entry gates and opens the search-then-ride flow', () {
      final ride = block.indexOf('Future<void> openRide()');
      expect(ride, greaterThan(-1));
      final rideBlock = block.substring(ride, ride + 320);
      expect(rideBlock, contains('_ensureVerified()'));
      expect(rideBlock, contains('_openSearchThenRide()'));
    });

    test('Schedule entry gates and calls the single schedule call site', () {
      final sched = block.indexOf('Future<void> openSchedule()');
      expect(sched, greaterThan(-1));
      final schedBlock = block.substring(sched, sched + 320);
      expect(schedBlock, contains('_ensureVerified()'));
      expect(schedBlock, contains('_openScheduleSheet()'));
    });
  });

  group('permissions', () {
    test('the cold-start permissions page exists and opens Settings', () {
      final perms =
          File('lib/screens/rider_permissions_screen.dart').readAsStringSync();
      expect(perms, contains('class RiderPermissionsScreen'));
      expect(perms, contains('openAppSettings()'));
      expect(perms, contains('NotificationService.isPermissionGranted()'));
      expect(perms, contains('Geolocator.checkPermission()'));
    });

    test('home runs location before notifications, once per install', () {
      final start = home.indexOf('Future<void> _runRiderPermissionFlow()');
      expect(start, greaterThan(-1));
      final block = home.substring(start, start + 1600);
      final loc = block.indexOf('Geolocator.requestPermission()');
      final notif = block.indexOf('NotificationService.requestPermission()');
      expect(loc, greaterThan(-1));
      expect(notif, greaterThan(loc),
          reason: 'notifications must be asked after location');
      expect(block, contains('rider_perms_prompted_v1'));
      expect(block, contains('RiderPermissionsScreen'));
    });
  });
}
