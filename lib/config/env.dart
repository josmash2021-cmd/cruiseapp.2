/// Environment variables for local development.
/// Codemagic overwrites this file at build time via generate_env step.
class Env {
  static const String apiKey = 'dev-api-key-change-in-production';
  static const String hmacSecret = 'dev-hmac-secret-change-in-production';
  static const String mapsServicesKey = 'AIzaSyDs8MIOA8qk0JwxOkxd8rGxtAmVTeB7CF0';
  static const String emailjsServiceId = 'service_kgjbuew';
  static const String emailjsTemplateId = 'template_oucb3n9';
  static const String emailjsPublicKey = '5R65y1qr1-lXDwGRb';
  static const String emailjsPrivateKey = 'xeR8WDCTgskv9g9ITzote';
  static const String stripePublishableKey = 'pk_live_51T4BXG4JZyaaA3VKQmdt1gQp3Mi4jGVSmYZ6aWl8ZEQ7k07gzzGzlOKde9n4zdLbhhmclJKysCdAVnNy5Uh8TeMf00YAldU9fo';
  static const String stripeMerchantId = 'merchant.com.cruise.app';
  static const String twilioAccountSid = '';
  static const String twilioAuthToken = '';
  static const String twilioServiceSid = '';
  static const bool paypalSandbox = false;
  static const String paypalClientId = '';
  static const String paypalSecret = '';
}
