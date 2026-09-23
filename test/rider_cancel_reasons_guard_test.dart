import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the rider cancel-reasons sheet (user spec 2026-09-23): the
/// rider gets the SAME reference design the driver has (X close top-left,
/// big "Elige el motivo para cancelar" title, note, radio reasons, and a
/// "Siguiente" armed only once a reason is picked) with rider-specific
/// options. The picked machine string rides to the API as `cancel_reason`.
///
///   1. Shared sheet widget + riderCancelReasons: 7 reasons, exact order.
///   2. ApiService.cancelTrip posts the reason.
///   3. Every rider cancel entry shows the sheet first: tracking pre-pickup
///      (reason → fee confirm dialog → cancel), tracking on-trip, and the
///      home "searching driver" card (free-cancel note).
void main() {
  final sheet =
      File('lib/widgets/cancel_reason_sheet.dart').readAsStringSync();
  final api = File('lib/services/api_service.dart').readAsStringSync();
  final buttons = File('lib/widgets/tracking/trip_action_buttons.dart')
      .readAsStringSync();
  final card =
      File('lib/widgets/tracking/driver_info_card.dart').readAsStringSync();
  final homeW =
      File('lib/screens/home_screen_widgets.dart').readAsStringSync();
  final l10n = File('lib/l10n/app_localizations.dart').readAsStringSync();

  group('shared reference sheet', () {
    test('X close, radio circles, selection-gated Siguiente', () {
      expect(sheet.contains('Icons.close_rounded'), isTrue,
          reason: 'the reference has the X at top-left');
      expect(sheet.contains('BoxShape.circle'), isTrue,
          reason: 'the reference uses radio circles, not chevron rows');
      expect(sheet.contains('onPressed: selected < 0'), isTrue,
          reason: 'Siguiente stays disabled until a reason is picked');
    });

    test('exactly the 7 rider reasons with machine strings, in order', () {
      final start = sheet.indexOf('riderCancelReasons(S s)');
      expect(start, isNonNegative, reason: 'riderCancelReasons missing');
      final body = sheet.substring(start, start + 900);
      final reasons = [
        'no_longer_needed',
        'wait_too_long',
        'wrong_pickup',
        'wrong_dropoff',
        'booked_by_accident',
        'price_issue',
        'other',
      ];
      var pos = 0;
      for (final r in reasons) {
        final at = body.indexOf("'$r'", pos);
        expect(at, isNonNegative, reason: '$r missing from riderCancelReasons');
        expect(at, greaterThanOrEqualTo(pos),
            reason: 'rider reasons out of order at $r');
        pos = at;
      }
    });
  });

  group('API carries the reason', () {
    test('cancelTrip accepts and posts cancel_reason', () {
      final start = api.indexOf('cancelTrip(int tripId,');
      expect(start, isNonNegative,
          reason: 'cancelTrip did not grow the cancelReason param');
      final body = api.substring(start, start + 700);
      expect(body.contains('{String? cancelReason}'), isTrue);
      expect(body.contains("'cancel_reason': cancelReason"), isTrue,
          reason: 'the reason must reach the backend audit trail');
    });
  });

  group('every rider cancel entry shows the sheet', () {
    test('tracking pre-pickup: sheet → fee confirm dialog → cancel', () {
      final start = buttons.indexOf('void _showCancelDialog() {');
      expect(start, isNonNegative);
      final body = buttons.substring(start, start + 900);
      expect(body.contains('showCancelReasonSheet'), isTrue);
      expect(body.contains('riderCancelReasons(s)'), isTrue);
      expect(body.contains('_showCancelConfirmDialog(reason: reason)'), isTrue,
          reason: 'the picked reason threads into the confirm dialog');
    });

    test('reason reaches ApiService on both cancel paths', () {
      final instant = buttons.indexOf('_cancelTripInstantly({String? reason})');
      expect(instant, isNonNegative,
          reason: '_cancelTripInstantly must accept the reason');
      expect(
          buttons
              .substring(instant, instant + 700)
              .contains('cancelReason: reason'),
          isTrue);
      final exec =
          buttons.indexOf('_executeCancelAndTransition({String? reason})');
      expect(exec, isNonNegative);
      expect(buttons.substring(exec, exec + 500).contains('cancelReason: reason'),
          isTrue);
      expect(card.contains('_showCancelConfirmDialog({String? reason})'),
          isTrue,
          reason: 'the confirm dialog forwards the reason');
      expect(card.contains('_cancelTripInstantly(reason: reason)'), isTrue);
    });

    test('on-trip cancel passes through the sheet too', () {
      final start = buttons.indexOf('void _showCancelOnTripDialog() {');
      expect(start, isNonNegative);
      final body = buttons.substring(start, start + 3200);
      expect(body.contains('showCancelReasonSheet'), isTrue);
      expect(body.contains('_startCancelFlow(reason: reason)'), isTrue);
    });

    test('home searching card uses the sheet with the free-cancel note', () {
      expect(homeW.contains('showCancelReasonSheet'), isTrue);
      expect(homeW.contains('s.riderCancelFreeNote'), isTrue,
          reason: 'searching has no driver yet — no fee warning there');
      expect(homeW.contains('cancelReason: reason'), isTrue);
    });

    test('ride-request pipeline searching cancel passes through the sheet', () {
      final ctrl = File('lib/screens/ride_request_controller.dart')
          .readAsStringSync();
      final widgets = File('lib/screens/ride_request_widgets.dart')
          .readAsStringSync();
      final trip = File('lib/state/rider_trip_controller.dart')
          .readAsStringSync();
      expect(widgets.contains('onTap: _showRiderCancelSearchSheet'), isTrue,
          reason: 'the searching Cancel button must open the reason sheet');
      final start = ctrl.indexOf('void _showRiderCancelSearchSheet() {');
      expect(start, isNonNegative);
      final body = ctrl.substring(start, start + 700);
      expect(body.contains('showCancelReasonSheet'), isTrue);
      expect(body.contains('_confirmCancelSearching(reason: reason)'), isTrue);
      expect(ctrl.contains('_cancelSearching({String? reason})'), isTrue);
      expect(ctrl.contains('_cancelSearching(reason: reason)'), isTrue);
      expect(ctrl.contains('_ctrl.cancelRide(reason: reason)'), isTrue,
          reason: 'the reason must reach RiderTripController.cancelRide');
      expect(trip.contains('cancelRide({String? reason})'), isTrue);
      expect(trip.contains('cancelTrip(tripId, cancelReason: reason)'), isTrue,
          reason: 'the reason must reach the API from the pipeline too');
      expect(
          File('lib/screens/ride_request_screen.dart')
              .readAsStringSync()
              .contains("import '../widgets/cancel_reason_sheet.dart';"),
          isTrue,
          reason: 'ride_request_screen lost the cancel_reason_sheet import');
    });

    test('both screens import the shared sheet', () {
      for (final f in [
        'lib/screens/rider_tracking_screen.dart',
        'lib/screens/home_screen.dart',
      ]) {
        expect(
            File(f)
                .readAsStringSync()
                .contains("import '../widgets/cancel_reason_sheet.dart';"),
            isTrue,
            reason: '$f lost the cancel_reason_sheet import');
      }
    });
  });

  group('l10n keys exist', () {
    test('rider reason keys are defined', () {
      for (final key in [
        'riderCancelReasonNotNeeded',
        'riderCancelReasonWaitLong',
        'riderCancelReasonWrongDropoff',
        'riderCancelReasonByAccident',
        'riderCancelReasonPrice',
        'riderCancelFreeNote',
      ]) {
        expect(l10n.contains('String get $key'), isTrue,
            reason: '$key missing from app_localizations.dart');
      }
    });
  });
}
