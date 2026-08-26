import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the booking payment model (Lyft model, 2026-08-26).
///
/// Pins the wiring the plan depends on:
///   a. ApiService.createTrip accepts and sends stripe_payment_intent_id
///      (legacy builds that DID hold keep working).
///   b. A SCHEDULED booking places NO hold and opens no wallet sheet —
///      both pipelines skip _confirmNativePayment when scheduledAt is set;
///      the backend authorises the fare off-session at dispatch time.
///   c. A declined charge (client exception or backend 402) still aborts
///      the creation — the return happens before createTrip/requestRide.
///   d. The sandbox/test-mode/web bypasses survive.
///
/// Source-grep style, same as picker_camera_guard_test.dart: these paths
/// need a live Stripe SDK/backend, so what a unit test CAN pin is that the
/// guards are wired where the calls happen.
void main() {
  final apiSrc = File('lib/services/api_service.dart').readAsStringSync();
  // The scheduled-booking hold lived in schedule_booking_screen.dart until
  // the 2026-08-22 flow rebuild; that file is gone and the wiring moved to
  // ride_request_controller's scheduled path (hold → createTrip). The pins
  // below verify the same contract in its new home.
  final scheduleSrc =
      File('lib/screens/ride_request_controller.dart').readAsStringSync();
  final requestSrc =
      File('lib/screens/ride_request_controller.dart').readAsStringSync();
  final tripSrc =
      File('lib/state/rider_trip_controller.dart').readAsStringSync();

  group('(a) createTrip carries the hold PaymentIntent', () {
    test('accepts paymentIntentId and sends stripe_payment_intent_id', () {
      final start = apiSrc.indexOf('static Future<Map<String, dynamic>> createTrip(');
      expect(start, isNonNegative, reason: 'createTrip must exist');
      final body = apiSrc.substring(start, start + 1800);
      expect(body, contains('String? paymentIntentId'),
          reason: 'createTrip must accept the optional PaymentIntent id');
      expect(body, contains("'stripe_payment_intent_id': paymentIntentId"),
          reason: 'the hold id must travel in the POST body');
    });
  });

  group('(b) scheduled booking places NO hold (Lyft model)', () {
    test('the modal pipeline skips payment when scheduledAt is set', () {
      expect(scheduleSrc, contains('isScheduledBooking'),
          reason: 'the modal pipeline must branch on the scheduled flag');
      expect(
          scheduleSrc,
          contains(
              'if (!isScheduledBooking) {'),
          reason:
              '_confirmNativePayment must only run for immediate rides');
    });

    test('the direct pipeline gates the charge on scheduledAt == null', () {
      expect(
          scheduleSrc,
          contains(
              'if (!isTestMode && _ctrl.state.scheduledAt == null) {'),
          reason:
              'a scheduled booking opens no wallet sheet and places no hold');
    });

    test('createTrip still carries the param for legacy held bookings', () {
      final create = scheduleSrc.indexOf('ApiService.createTrip(');
      final block = scheduleSrc.substring(create, create + 1200);
      expect(block, contains('paymentIntentId: _heldPaymentIntentId'),
          reason: 'legacy builds that DID hold must keep sending it');
    });
  });

  group('(c) decline aborts the creation', () {
    test('schedule screen: hold failure returns before createTrip', () {
      final hold = scheduleSrc.indexOf('ApiService.createPaymentIntent(');
      final create = scheduleSrc.indexOf('ApiService.createTrip(');
      final between = scheduleSrc.substring(hold, create);
      expect(between, contains('return;'),
          reason: 'a failed hold must abort before createTrip');
      expect(between, contains('catch'),
          reason: 'the hold must be wrapped so a decline is caught');
    });

    test('schedule screen: backend 402 shows the decline path', () {
      final fn = scheduleSrc.indexOf('Future<void> _createScheduledTrip()');
      expect(fn, isNonNegative);
      final tail = scheduleSrc.substring(fn);
      final i = tail.indexOf('e.statusCode == 402');
      expect(i, isNonNegative,
          reason: 'a 402 from trip creation must get the decline path');
      final block = tail.substring(i, i + 700);
      expect(block, contains('_handlePaymentFailure'),
          reason: 'reuse the existing decline dialog');
    });

    test('ride_request scheduled path: 402 goes to _handlePaymentFailure', () {
      final fn = requestSrc.indexOf('Future<void> _createScheduledTrip()');
      final tail = requestSrc.substring(fn);
      final i = tail.indexOf('e.statusCode == 402');
      expect(i, isNonNegative,
          reason: 'a 402 creating the reservation must be handled as decline');
      final block = tail.substring(i, i + 700);
      expect(block, contains('_handlePaymentFailure'),
          reason: 'reuse the existing decline dialog');
      expect(block.indexOf('return;'), lessThan(block.indexOf('_showRetrySnackBar')),
          reason: 'the decline path must not fall through to the retry snackbar');
    });

    test('immediate flow: backend 402 maps to client:payment_declined', () {
      expect(tripSrc, contains("clientPaymentDeclined = 'client:payment_declined'"));
      final i = tripSrc.indexOf('apiErr?.statusCode == 402');
      expect(i, isNonNegative,
          reason: 'requestRide must detect the 402 from trip creation');
      final block = tripSrc.substring(i, i + 900);
      expect(block, contains('RiderTripCancelCodes.clientPaymentDeclined'),
          reason: 'the rider must see a payment decline, not a network error');
    });
  });

  group('(d) bypasses preserved', () {
    test('schedule screen skips the hold on web and in sandbox mode', () {
      expect(scheduleSrc, contains('AppConfig.sandboxPayments'),
          reason: 'web and sandbox keep the no-hold bypass');
      expect(scheduleSrc, contains("startsWith('mock_')"),
          reason: 'mock backend (testers) must not require a real hold');
    });

    test('test mode still skips the native payment in ride_request', () {
      expect(requestSrc, contains('_isTestModeActive()'),
          reason: 'the test-mode bypass must stay');
      final i = requestSrc.indexOf(
          'if (!isTestMode && _ctrl.state.scheduledAt == null) {');
      expect(i, isNonNegative,
          reason: 'the charge/hold must stay behind the test-mode gate');
    });
  });
}
