import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 2026-08-22 rider booking-flow rebuild:
///   1. The addresses page has a dynamic title (Schedule a ride /
///      Destination / Start), an X (not a back arrow), no "Change rider",
///      and the "+" add-stop affordance.
///   2. The choose-a-ride button says "Select {tier}".
///   3. iOS preselects Apple Pay when no default method is stored.
///   4. The legacy schedule flow files are gone and nothing imports them.
///   5. The pickup-note sheet has the 60-char counter and the quick chips.
///
/// Source-grep style, like schedule_hub_guard_test.dart.
void main() {
  final search =
      File('lib/screens/pickup_dropoff_search_screen.dart').readAsStringSync();
  final widgets =
      File('lib/screens/ride_request_widgets.dart').readAsStringSync();
  final screen =
      File('lib/screens/ride_request_screen.dart').readAsStringSync();
  final pin =
      File('lib/screens/set_pickup_location_screen.dart').readAsStringSync();

  group('addresses page', () {
    test('dynamic title: schedule / destination / start', () {
      expect(search, contains('s.schedDateTimeTitle'),
          reason: 'schedule chain → "Schedule a ride"');
      expect(search, contains('s.addressTitleDestination'));
      expect(search, contains('s.addressTitleStart'));
    });

    test('X closes, no back arrow, no Change rider', () {
      final titleRow = search.indexOf('Widget _buildTitleRow()');
      expect(titleRow, greaterThan(-1));
      final block = search.substring(titleRow, titleRow + 900);
      expect(block, contains('Icons.close_rounded'));
      expect(block, isNot(contains('arrow_back')));
      expect(search, isNot(contains('Change rider')));
      expect(search, isNot(contains('changeRider')));
    });

    test('the "+" adds a Stop field between Start and Destination', () {
      expect(search, contains('Icons.add_rounded'));
      expect(search, contains('stopFieldLabel'));
      expect(search, contains('_showStop'));
    });

    test('schedule chain: addresses → wheels → shared booking tail', () {
      expect(search, contains('_continueScheduleChain'));
      expect(search, contains('ScheduleDateTimeScreen('));
      expect(search, contains('continueScheduleToBooking('));
      expect(search, contains('estimatedMinutes'));
    });
  });

  group('choose a ride', () {
    test('the button reads "Select {tier}"', () {
      expect(widgets, contains('selectTierLabel('));
      expect(widgets, contains('_openPickupConfirm(c, option)'));
    });

    test('iOS preselects Apple Pay when nothing is stored', () {
      final start = screen.indexOf('Future<void> _restoreDefaultPaymentMethod()');
      expect(start, greaterThan(-1));
      final block = screen.substring(start, start + 1100);
      expect(block, contains('AppPlatform.isIOS'));
      expect(block, contains('isPlatformPaySupported'));
      expect(block, contains("= 'apple_pay'"));
    });

    test('Select opens the pickup-pin page and pays from its onConfirm', () {
      final controller =
          File('lib/screens/ride_request_controller.dart').readAsStringSync();
      final start = controller.indexOf('Future<void> _openPickupConfirm(');
      expect(start, greaterThan(-1));
      final block = controller.substring(start, start + 1400);
      expect(block, contains('SetPickupLocationScreen('));
      expect(block, contains('_ctrl.setPickupNote(note)'));
      // The pin page hands back to the SAME pipeline — hold untouched.
      expect(block, contains('_startRideDirectly(c, option)'));
    });
  });

  group('legacy schedule flow deleted', () {
    for (final f in [
      'lib/screens/schedule_picker_sheet.dart',
      'lib/screens/schedule_ride_flow.dart',
      'lib/screens/schedule_booking_screen.dart',
      'lib/screens/scheduled_rides_screen.dart',
    ]) {
      test('$f is gone', () {
        expect(File(f).existsSync(), isFalse);
      });
    }

    test('no imports of the deleted files remain', () {
      for (final f in [
        'lib/screens/home_screen.dart',
        'lib/screens/home_screen_controller.dart',
        'lib/screens/ride_request_screen.dart',
        'lib/screens/account_screen.dart',
        'lib/screens/schedule_hub_screen.dart',
      ]) {
        final src = File(f).readAsStringSync();
        expect(src, isNot(contains("import 'schedule_ride_flow.dart'")),
            reason: f);
        expect(src, isNot(contains("import 'schedule_booking_screen.dart'")),
            reason: f);
        expect(src, isNot(contains("import 'schedule_picker_sheet.dart'")),
            reason: f);
        expect(src, isNot(contains("import 'scheduled_rides_screen.dart'")),
            reason: f);
      }
    });
  });

  group('pickup-pin page', () {
    test('fixed pin over a moving map, drop bounce, snap + morph', () {
      expect(pin, contains('queryRenderedFeatures'),
          reason: 'suggested points come from the style road layers');
      expect(pin, contains('_snapMeters = 25.0'));
      expect(pin, contains('recommendedPin'));
      expect(pin, contains('Curves.bounceOut'),
          reason: 'the pin drop has the bounce');
    });

    test('note sheet: 60-char counter and the six quick chips', () {
      expect(pin, contains('_maxLen = 60'));
      for (final chip in [
        'noteChipGateCode',
        'noteChipWearing',
        'noteChipCorner',
        'noteChipInFront',
        'noteChipDoorNumber',
        'noteChipPickingUp',
      ]) {
        expect(pin, contains(chip), reason: 'missing chip $chip');
      }
    });

    test('Pay goes through the caller pipeline, never around the hold', () {
      expect(pin, contains('widget.onConfirm(_pin, _note)'));
      expect(pin, isNot(contains('createTrip(')),
          reason: 'the pin page must not book on its own — the existing '
              'hold → createTrip pipeline in ride_request owns that');
    });

    test('the map surface is claimed with a unique owner', () {
      expect(pin, contains("'SetPickupLoc-"));
      expect(pin, contains('MapSurfaceCoordinator.instance.acquire('));
    });
  });

  group('ride request map resilience', () {
    test('surface revoke clears _cinematicRunning so onMapCreated can redraw', () {
      // Returning from the pickup pin page left the map bare because a live
      // _cinematicRunning blocked every redraw path on the remount.
      final revoke = screen.indexOf('onRevoke:');
      expect(revoke, greaterThan(-1));
      final block = screen.substring(revoke, revoke + 1400);
      expect(block, contains('_cinematicRunning = false'),
          reason: 'without this, _drawRoute bails on _cinematicRunning and '
              'the recreated map shows no pins or route');
    });

    test('the tier sheet opens with a forced 4-second skeleton', () {
      // User spec 2026-08-29: the choose-a-ride sheet always reads as
      // skeleton rows for the first 4 seconds, even when fares are ready.
      expect(screen, contains('_skeletonForced = true'));
      expect(screen, contains('Duration(seconds: 4)'));
      expect(widgets, contains('_skeletonForced || !faresReady'),
          reason: 'the AnimatedSwitcher must honour the forced window');
    });
  });
}
