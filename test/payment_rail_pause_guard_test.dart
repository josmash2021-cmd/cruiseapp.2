import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final flags = File('lib/services/feature_flags.dart').readAsStringSync();
  final controller =
      File('lib/screens/ride_request_controller.dart').readAsStringSync();
  final methodScreen =
      File('lib/screens/ride_payment_method_screen.dart').readAsStringSync();
  final onboarding =
      File('lib/screens/payment_method_screen.dart').readAsStringSync();
  final backend = File('backend/routers/payments.py').readAsStringSync();

  test('paused payment rails are off and cannot be enabled remotely', () {
    expect(flags, contains('static bool paypalEnabled = false;'));
    expect(flags, contains('static bool tapToPayEnabled = false;'));
    expect(flags, isNot(contains("paypalEnabled = data['paypal_enabled']")));
    expect(flags, isNot(contains("tapToPayEnabled = data['tap_to_pay_enabled']")));
  });

  test('payment selectors and legacy picker hide both paused rails', () {
    expect(
        controller,
        contains('if (AppPlatform.isAndroid && FeatureFlags.tapToPayEnabled)'),
        reason: 'Android Tap to Pay must also honor the pause');
    expect(controller, contains('if (FeatureFlags.paypalEnabled) methods.add'));
    expect(controller,
        contains('if (FeatureFlags.tapToPayEnabled) (\'tap_to_pay\''));
    expect(controller, contains('if (FeatureFlags.paypalEnabled) (\'paypal\''));
    expect(methodScreen,
        contains('if (AppPlatform.isAndroid && FeatureFlags.tapToPayEnabled)'));
    expect(onboarding, contains('if (!FeatureFlags.paypalEnabled) return;'));
  });

  test('stale selections cannot reach either checkout', () {
    final paypal = controller.indexOf('Future<bool> _confirmPayPal');
    final tap = controller.indexOf('Future<bool> _confirmTapToPay');
    expect(paypal, greaterThan(-1));
    expect(tap, greaterThan(-1));
    expect(controller.substring(paypal, paypal + 160),
        contains('if (!FeatureFlags.paypalEnabled) return false;'));
    expect(controller.substring(tap, tap + 160),
        contains('if (!FeatureFlags.tapToPayEnabled) return false;'));
  });

  test('backend blocks new charges but preserves existing captures', () {
    expect(backend, contains('PAYPAL_RAIL_ENABLED = False'));
    expect(backend, contains('TAP_TO_PAY_RAIL_ENABLED = False'));
    expect(
      'if not PAYPAL_RAIL_ENABLED:'.allMatches(backend).length,
      greaterThanOrEqualTo(3),
      reason: 'both app aliases and the web order creator must be paused',
    );
    expect(
      'if not TAP_TO_PAY_RAIL_ENABLED:'.allMatches(backend).length,
      greaterThanOrEqualTo(2),
      reason: 'Terminal token and PaymentIntent creation must be paused',
    );
    for (final signature in [
      'async def paypal_capture_order',
      'async def capture_tap_to_pay_payment',
    ]) {
      final start = backend.indexOf(signature);
      expect(start, greaterThan(-1));
      expect(backend.substring(start, start + 450),
          isNot(contains('temporarily paused')));
    }
  });
}
