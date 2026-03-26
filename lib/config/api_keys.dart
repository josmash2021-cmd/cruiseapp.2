import 'dart:io' show Platform;
import 'env.dart';

class ApiKeys {
  /// Google key for Places Autocomplete, Place Details, Geocoding, Directions API.
  /// The visual map is Mapbox — this key is only for Google backend services.
  /// In Google Cloud Console → Credentials → this key should have:
  ///   - Application restriction: None (or Android/iOS app restrictions)
  ///   - API restriction: Places API, Geocoding API, Directions API, Distance Matrix API
  static const String webServices = Env.mapsServicesKey;

  /// Platform-specific Google Places API keys
  static const String _googlePlacesIOS = String.fromEnvironment(
    'GOOGLE_PLACES_IOS', defaultValue: '');
  static const String _googlePlacesAndroid = String.fromEnvironment(
    'GOOGLE_PLACES_ANDROID', defaultValue: '');
  static String get googlePlaces => Platform.isIOS ? _googlePlacesIOS : _googlePlacesAndroid;

  /// Stripe publishable key (pk_test_... or pk_live_...)
  /// Replace with your real key from https://dashboard.stripe.com/apikeys
  static const String stripePublishableKey = Env.stripePublishableKey;

  /// Stripe merchant identifier for Apple Pay / Google Pay
  static const String stripeMerchantId = Env.stripeMerchantId;
}
