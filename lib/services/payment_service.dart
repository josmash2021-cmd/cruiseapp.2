import 'dart:io';
import 'package:pay/pay.dart';

/// Central helper for Google Pay (Android) and Apple Pay (iOS).
class PaymentService {
  PaymentService._();

  static Pay? _client;

  static Future<Pay> _getClient() async {
    if (_client != null) return _client!;
    final configs = <PayProvider, PaymentConfiguration>{};
    if (Platform.isAndroid) {
      configs[PayProvider.google_pay] = await PaymentConfiguration.fromAsset(
        'google_pay.yaml',
      );
    }
    if (Platform.isIOS) {
      configs[PayProvider.apple_pay] = await PaymentConfiguration.fromAsset(
        'apple_pay.yaml',
      );
    }
    return _client = Pay(configs);
  }

  /// Returns true if the device supports Google Pay and has at least one card.
  static Future<bool> isGooglePayAvailable() async {
    if (!Platform.isAndroid) return false;
    try {
      final client = await _getClient();
      return await client.userCanPay(PayProvider.google_pay);
    } catch (_) {
      return false;
    }
  }

  /// Returns true if the device supports Apple Pay and has at least one card.
  static Future<bool> isApplePayAvailable() async {
    if (!Platform.isIOS) return false;
    try {
      final client = await _getClient();
      return await client.userCanPay(PayProvider.apple_pay);
    } catch (_) {
      return false;
    }
  }

  /// Loads the Google Pay PaymentConfiguration from assets.
  static Future<PaymentConfiguration> googlePayConfig() =>
      PaymentConfiguration.fromAsset('google_pay.yaml');

  /// Loads the Apple Pay PaymentConfiguration from assets.
  static Future<PaymentConfiguration> applePayConfig() =>
      PaymentConfiguration.fromAsset('apple_pay.yaml');

  /// Builds a PaymentItem list for a fare.
  static List<PaymentItem> fareItems(String label, double amountUsd) => [
    PaymentItem(
      label: label,
      amount: amountUsd.toStringAsFixed(2),
      status: PaymentItemStatus.final_price,
    ),
  ];
}
