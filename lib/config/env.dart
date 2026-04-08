/// Environment variables for local development.
/// Codemagic overwrites this file at build time via generate_env step.
///
/// IMPORTANT: This file is gitignored. Never commit real API keys here.
/// For local dev, use placeholder values — the backend proxies most
/// third-party calls so the app works without real keys on device.
class Env {
  // ── Backend API authentication ──
  static const String apiKey = String.fromEnvironment(
    'API_KEY', defaultValue: 'HWB88VurhLM-1GdVML2PT92iqNSbeJ52TU1VO37MBZS6RYlyWvfIpaTdD54GT_5u');
  static const String hmacSecret = String.fromEnvironment(
    'HMAC_SECRET', defaultValue: 'qUDmTNu1Dxxg_xo7kaUfRba4XiU_5H1ZhkUMDuVrD2dLQ2ImT8JXZ5FgUyXpSJ5h');

  // ── Google Services ──
  static const String mapsServicesKey = String.fromEnvironment(
    'GOOGLE_MAPS_KEY', defaultValue: '');

  // ── EmailJS ──
  static const String emailjsServiceId = String.fromEnvironment(
    'EMAILJS_SERVICE_ID', defaultValue: '');
  static const String emailjsTemplateId = String.fromEnvironment(
    'EMAILJS_TEMPLATE_ID', defaultValue: '');
  static const String emailjsPublicKey = String.fromEnvironment(
    'EMAILJS_PUBLIC_KEY', defaultValue: '');
  static const String emailjsPrivateKey = String.fromEnvironment(
    'EMAILJS_PRIVATE_KEY', defaultValue: '');

  // ── Stripe ──
  static const String stripePublishableKey = String.fromEnvironment(
    'STRIPE_PK', defaultValue: '');
  static const String stripeMerchantId = String.fromEnvironment(
    'STRIPE_MERCHANT', defaultValue: 'merchant.com.cruise.app');

  // ── Twilio Verify ──
  static const String twilioAccountSid = String.fromEnvironment(
    'TWILIO_SID', defaultValue: '');
  static const String twilioAuthToken = String.fromEnvironment(
    'TWILIO_TOKEN', defaultValue: '');
  static const String twilioServiceSid = String.fromEnvironment(
    'TWILIO_SERVICE', defaultValue: '');

  // ── PayPal ──
  static const bool paypalSandbox = bool.fromEnvironment(
    'PAYPAL_SANDBOX', defaultValue: false);
  static const String paypalClientId = String.fromEnvironment(
    'PAYPAL_CLIENT_ID', defaultValue: 'PLACEHOLDER_PAYPAL_CLIENT_ID');
  static const String paypalSecret = String.fromEnvironment(
    'PAYPAL_SECRET', defaultValue: 'PLACEHOLDER_PAYPAL_SECRET');
}
