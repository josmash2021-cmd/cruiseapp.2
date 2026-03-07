import 'env.dart';

class ApiKeys {
  /// Unrestricted key for Places Autocomplete, Place Details, Geocoding, Directions.
  /// This key must NOT have HTTP referrer restrictions (breaks mobile/server calls).
  /// In Google Cloud Console → Credentials → this key should have:
  ///   - Application restriction: None (or Android/iOS app restrictions)
  ///   - API restriction: Maps SDK, Places API, Geocoding API, Directions API
  static const String webServices = Env.googleMapsKey;

  /// Stripe publishable key (pk_test_... or pk_live_...)
  /// Replace with your real key from https://dashboard.stripe.com/apikeys
  static const String stripePublishableKey = Env.stripePublishableKey;

  /// Stripe merchant identifier for Apple Pay / Google Pay
  static const String stripeMerchantId = Env.stripeMerchantId;
}
