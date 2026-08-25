import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Guardian for the 2026-08-25 phone-first onboarding payment step
/// (Lyft-style): email → Add payment method → Ready to ride → home.
///   1. RiderEmailScreen continues to RiderAddPaymentScreen (not straight
///      to HomeScreen anymore).
///   2. The payment page lists Apple Pay (iOS) / Google Pay (Android)
///      first, opens the card SCANNER first for cards, and has a discreet
///      "Not now" skip.
///   3. Riders with an existing method never see the step (backend +
///      locally linked wallets check → straight to ReadyToRideScreen).
///   4. Completing or skipping lands on ReadyToRideScreen, whose CTA
///      already navigates home.
///
/// Source-grep style, like rider_booking_flow_guard_test.dart.
void main() {
  final email =
      File('lib/screens/rider_email_screen.dart').readAsStringSync();
  final pay =
      File('lib/screens/rider_add_payment_screen.dart').readAsStringSync();
  final ready =
      File('lib/screens/ready_to_ride_screen.dart').readAsStringSync();

  group('email → payment step', () {
    test('email success reaches RiderAddPaymentScreen via the notifications '
        'page, not home', () {
      expect(email, contains("import 'rider_add_payment_screen.dart';"));
      // 2026-08-25: the notification-permission page sits between email and
      // payment — the payment screen now arrives as its nextScreen.
      expect(email, contains('DriverNotificationsScreen('));
      expect(email, contains('nextScreen: RiderAddPaymentScreen('));
      expect(email, isNot(contains('pushAndRemoveUntil')));
      expect(email, isNot(contains('HomeScreen()')));
    });
  });

  group('add payment page', () {
    test('wallet rows are platform-first', () {
      expect(pay, contains('AppPlatform.isIOS'));
      expect(pay, contains('AppPlatform.isAndroid'));
      expect(pay, contains('Apple Pay'));
      expect(pay, contains('Google Pay'));
      expect(pay, contains('PaymentService.isApplePayAvailable'));
      expect(pay, contains('PaymentService.isGooglePayAvailable'));
      // Wallets link through the shared sheet's methodId param.
      expect(pay, contains("methodId: 'apple_pay'"));
      expect(pay, contains("methodId: 'google_pay'"));
      expect(pay, contains('linkPaymentMethod(methodId)'));
    });

    test('card row opens the scanner first', () {
      expect(pay, contains('CardScanScreen('));
      expect(pay, contains("linkPaymentMethod('credit_card')"));
    });

    test('discreet Not now skip is present', () {
      expect(pay, contains('s.notNow'));
      expect(pay, contains('onPressed: _goNext'));
    });

    test('existing riders skip the step', () {
      expect(pay, contains('getMyPaymentMethods'));
      expect(pay, contains('getLinkedPaymentMethods'));
      expect(pay, contains('pushReplacement'));
    });

    test('completing or skipping lands on ReadyToRideScreen', () {
      expect(pay, contains('ReadyToRideScreen(firstName:'));
    });
  });

  group('ready to ride → home', () {
    test('the CTA still navigates home', () {
      expect(ready, contains('takeFirstRide'));
      expect(ready, contains('const HomeScreen()'));
    });
  });

  group('l10n', () {
    test('notNow exists ES/EN', () {
      final l10n =
          File('lib/l10n/app_localizations.dart').readAsStringSync();
      expect(l10n, contains("String get notNow => _es ? 'Ahora no' : 'Not now';"));
    });
  });
}
