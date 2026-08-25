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

  group('hero Where to? + Ride/Schedule switch', () {
    final start = widgets.indexOf('Widget _buildHeroCTA() {');
    final block = widgets.substring(start, start + 4000);

    test('the hero paints "Where to?" again and gates on the way out', () {
      expect(block, contains('_ensureVerified()'));
      expect(block, isNot(contains('verificationBlocked')));
      expect(block, isNot(contains('heroRideSchedule')),
          reason: 'the two-row card is gone — the original hero is back');
      // The headline itself renders in the content builder below the CTA.
      final content = widgets.indexOf('Widget _buildHeroWhereToContent(');
      expect(content, greaterThan(-1));
      expect(widgets.substring(content, content + 900),
          contains('whereToQuestion'));
    });

    test('the switch is Ride (bolt) / Schedule (calendar)', () {
      final sw = widgets.indexOf('Widget _buildRideScheduleSwitch()');
      expect(sw, greaterThan(-1));
      final swBlock = widgets.substring(sw, sw + 3400);
      expect(swBlock, contains('.rideLabel'));
      expect(swBlock, contains('Icons.bolt_rounded'));
      expect(swBlock, contains('.schedule,'));
      expect(swBlock, contains('Icons.calendar_month_rounded'));
      expect(swBlock, isNot(contains('nowLabel')),
          reason: 'Now/Later labels are gone');
    });

    test('both sides of the switch gate through _ensureVerified', () {
      final sw = widgets.indexOf('Widget _buildRideScheduleSwitch()');
      final swBlock = widgets.substring(sw, sw + 3400);
      final gates = RegExp('ensureVerified').allMatches(swBlock).length;
      expect(gates, greaterThanOrEqualTo(2),
          reason: 'Ride and Schedule must each gate');
      expect(swBlock, contains('_openScheduleSheet()'),
          reason: 'Schedule opens the hub via the single call site');
    });
  });

  group('fleet carousel ("More ways to ride")', () {
    final start = widgets.indexOf('Widget _buildFleetStack(');
    // Wide enough to reach the Continue label past the AspectRatio band
    // (the window was 5600 and the shared-frame box pushed it out; the
    // Meet-{tier} sheet wiring pushed it further — 7600 now).
    final block = widgets.substring(start, start + 7600);

    test('is a horizontal carousel with peek, not the quarter-width row', () {
      expect(block, contains('ListView.separated('));
      expect(block, contains('scrollDirection: Axis.horizontal'));
      expect(block, isNot(contains('return Row(')),
          reason: 'the four-across Row was replaced by the carousel');
    });

    test('four tiers in BLACK → PREMIUM → COMPACT → STANDARD order', () {
      final black = block.indexOf("'BLACK'");
      final premium = block.indexOf("'PREMIUM'");
      final compact = block.indexOf("'COMPACT'");
      final standard = block.indexOf("'STANDARD'");
      expect(black, greaterThan(-1));
      expect(black, lessThan(premium));
      expect(premium, lessThan(compact));
      expect(compact, lessThan(standard));
    });

    test('the approved one-liners ride the cards', () {
      for (final key in [
        'fleetBlackDesc',
        'fleetPremiumDesc',
        'fleetCompactDesc',
        'fleetStandardDesc',
      ]) {
        expect(block, contains(key), reason: 'missing $key');
      }
      final l10n =
          File('lib/l10n/app_localizations.dart').readAsStringSync();
      expect(l10n, contains('Seats for 7 with room for bags'));
      expect(l10n, contains('Everyday sedan rides at our lowest price'));
    });

    test('tap opens the Meet-tier sheet, whose Select runs the tier handler',
        () {
      expect(block, contains('TierDetailSheet.show('),
          reason: 'the carousel cards open the "Meet {tier}" detail sheet');
      expect(block, contains('_openSearchThenRide(rideId:'),
          reason: 'the sheet\'s Select must enter the flow through the same '
              'handler the row used');
      expect(block, contains('continueArrow'));
    });

    test('same car art as before, just bigger', () {
      for (final asset in [
        'cruisert1.png',
        'cruisert_suvxl.png',
        'cruisert_compact.png',
        'cruisert3.png',
      ]) {
        expect(block, contains(asset), reason: 'missing $asset');
      }
    });

    test('the card top fades so the car floats on the page', () {
      expect(block, contains('LinearGradient('));
      expect(block, contains('Colors.transparent'),
          reason: 'top of the card must fade to transparent');
      expect(block, contains('neuSurface'),
          reason: 'the text zone stays on the solid neu surface');
      expect(block, isNot(contains('boxShadow')),
          reason: 'a shadow would trace a frame around the faded top');
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
