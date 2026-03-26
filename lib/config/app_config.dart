/// Global application configuration flags.
class AppConfig {
  // SANDBOX PAYMENTS
  // ================
  // Set to TRUE for testing — payments are simulated, no real charges.
  //
  // Set to FALSE for production — payments go through Stripe/PayPal for real.
  //
  // Before switching to production:
  // 1. Set real Stripe publishable key in env vars (STRIPE_PK)
  // 2. Set real PayPal keys in env vars (PAYPAL_CLIENT_ID, PAYPAL_SECRET)
  // 3. Test with Stripe test keys first (pk_test_...)
  // 4. Change sandboxPayments to false
  // 5. Test a real payment end to end
  // 6. Change Google Pay environment from TEST to PRODUCTION in assets/pay/google_pay.yaml
  static const bool sandboxPayments = true;
}
