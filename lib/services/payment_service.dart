import '../utils/app_platform.dart';
import 'package:flutter/services.dart';
import 'package:pay/pay.dart';

import '../config/env.dart';

/// Central helper for Google Pay (Android) and Apple Pay (iOS).
///
/// The Google Pay configuration is loaded from a JSON asset template and the
/// Stripe publishable key is injected at runtime from [Env.stripePublishableKey]
/// so the live key is never hardcoded in source control.
class PaymentService {
  PaymentService._();

  static Pay? _client;

  /// Loads the Google Pay configuration from the JSON asset template,
  /// injecting the Stripe publishable key from [Env].
  static Future<PaymentConfiguration> _loadGooglePayConfig() async {
    final template = await rootBundle.loadString(
      'assets/pay/default_google_pay_config.json',
    );
    final pk = Env.stripePublishableKey;
    if (pk.isEmpty || pk == 'YOUR_STRIPE_PUBLISHABLE_KEY') {
      throw StateError(
        'Env.stripePublishableKey is not configured. '
        'Copy lib/config/env.template.dart to lib/config/env.dart '
        'and fill in your Stripe publishable key.',
      );
    }
    final configString = template.replaceAll('__STRIPE_PK__', pk);
    return PaymentConfiguration.fromJsonString(configString);
  }

  static Future<Pay> _getClient() async {
    if (_client != null) return _client!;
    final configs = <PayProvider, PaymentConfiguration>{};
    if (AppPlatform.isAndroid) {
      configs[PayProvider.google_pay] = await _loadGooglePayConfig();
    }
    if (AppPlatform.isIOS) {
      // The default fromAsset loader resolves 'assets/<name>' and expects
      // JSON — 'apple_pay.yaml' (wrong dir, wrong format) always threw,
      // which surfaced as "Apple Pay not set up" on configured devices
      // (2026-08-25). The real config is the JSON under assets/pay/.
      configs[PayProvider.apple_pay] = await PaymentConfiguration.fromAsset(
        'pay/default_apple_pay_config.json',
      );
    }
    return _client = Pay(configs);
  }

  /// Returns true if the device supports Google Pay and has at least one card.
  static Future<bool> isGooglePayAvailable() async {
    if (!AppPlatform.isAndroid) return false;
    try {
      final client = await _getClient();
      return await client.userCanPay(PayProvider.google_pay);
    } catch (_) {
      return false;
    }
  }

  /// Returns true if the device supports Apple Pay and has at least one card.
  static Future<bool> isApplePayAvailable() async {
    if (!AppPlatform.isIOS) return false;
    try {
      final client = await _getClient();
      return await client.userCanPay(PayProvider.apple_pay);
    } catch (_) {
      return false;
    }
  }

  /// Loads the Google Pay PaymentConfiguration from the JSON asset template.
  static Future<PaymentConfiguration> googlePayConfig() =>
      _loadGooglePayConfig();

  /// Loads the Apple Pay PaymentConfiguration from assets.
  static Future<PaymentConfiguration> applePayConfig() =>
      PaymentConfiguration.fromAsset('pay/default_apple_pay_config.json');

  /// Builds a PaymentItem list for a fare.
  static List<PaymentItem> fareItems(String label, double amountUsd) => [
    PaymentItem(
      label: label,
      amount: amountUsd.toStringAsFixed(2),
      status: PaymentItemStatus.final_price,
    ),
  ];
}
