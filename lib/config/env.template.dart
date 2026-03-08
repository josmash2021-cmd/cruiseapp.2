// ┌─────────────────────────────────────────────────────────────┐
// │  env.template.dart — TEMPLATE for env.dart                  │
// │  Copy this file to env.dart and fill in your real values.   │
// │  env.dart is gitignored and will NOT be committed.          │
// └─────────────────────────────────────────────────────────────┘

class Env {
  // ── Backend API authentication ──
  static const String apiKey = 'YOUR_API_KEY';
  static const String hmacSecret = 'YOUR_HMAC_SECRET';

  // ── Google Maps & Services ──
  static const String googleMapsKey = 'YOUR_GOOGLE_MAPS_KEY';

  // ── EmailJS ──
  static const String emailjsServiceId = 'YOUR_EMAILJS_SERVICE_ID';
  static const String emailjsTemplateId = 'YOUR_EMAILJS_TEMPLATE_ID';
  static const String emailjsPublicKey = 'YOUR_EMAILJS_PUBLIC_KEY';
  static const String emailjsPrivateKey = 'YOUR_EMAILJS_PRIVATE_KEY';

  // ── Stripe ──
  static const String stripePublishableKey = 'YOUR_STRIPE_PUBLISHABLE_KEY';
  static const String stripeMerchantId = 'merchant.com.cruise.app';

  // ── Twilio Verify ──
  static const String twilioAccountSid = 'YOUR_TWILIO_ACCOUNT_SID';
  static const String twilioAuthToken = 'YOUR_TWILIO_AUTH_TOKEN';
  static const String twilioServiceSid = 'YOUR_TWILIO_SERVICE_SID';

  // ── PayPal ──
  static const bool paypalSandbox = true;
  static const String paypalClientId = 'YOUR_PAYPAL_CLIENT_ID';
  static const String paypalSecret = 'YOUR_PAYPAL_SECRET';
}
