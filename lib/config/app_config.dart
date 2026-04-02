import 'env.dart';

/// Global application configuration flags.
/// Values are driven by [Env] — Codemagic overwrites env.dart at build time.
class AppConfig {
  // SANDBOX PAYMENTS
  // ================
  // Controlled by Env.paypalSandbox which Codemagic injects at build time.
  // Set PAYPAL_SANDBOX=false in Codemagic env vars for production builds.
  //
  // Before switching to production:
  // 1. Set real Stripe publishable key in env vars (STRIPE_PK)
  // 2. Set real PayPal keys in env vars (PAYPAL_CLIENT_ID, PAYPAL_SECRET)
  // 3. Test with Stripe test keys first (pk_test_...)
  // 4. Set PAYPAL_SANDBOX=false in Codemagic
  // 5. Test a real payment end to end
  // 6. Change Google Pay environment from TEST to PRODUCTION in assets/pay/google_pay.yaml
  static bool get sandboxPayments => Env.paypalSandbox;
}
