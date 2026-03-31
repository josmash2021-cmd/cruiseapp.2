import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      appBar: AppBar(
        title: const Text('Privacy Policy'),
        backgroundColor: c.surface,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Privacy Policy',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: c.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              'Effective Date: December 2024',
              style: TextStyle(fontSize: 14, color: c.textSecondary),
            ),
            const SizedBox(height: 24),
            _sectionText(c, 'Introduction', 'Cruise is committed to protecting your privacy. This Privacy Policy explains how we collect, use, disclose, and safeguard your information when you use our mobile application and related services.'),
            _sectionText(c, '1. Information We Collect', 'We collect information you provide directly (name, email, phone, photos, payment info, location data) and information collected automatically (device info, usage data, location during trips, analytics).'),
            _sectionText(c, '2. How We Use Your Information', 'We use your information for service provision, safety & security, communication, analytics, legal compliance, marketing, push notifications, and location services.'),
            _sectionText(c, '3. Sharing Your Information', 'We share information with Drivers/Riders during trips, payment processors (Stripe), background check provider (Checkr), SMS provider (Twilio), email services, analytics, and support providers.'),
            _sectionText(c, '4. Data Security', 'We use encryption (AES-256 for SSN, bcrypt-12 for passwords), HTTPS/TLS 1.3, JWT tokens, rate limiting, IP blacklisting, and parameterized queries to prevent SQL injection.'),
            _sectionText(c, '5. Your Privacy Rights', 'You have rights to access, correct, and delete your data. You can opt-out of marketing emails and disable push notifications.'),
            _sectionText(c, '6. Retention of Data', 'We retain active account data for the duration of your account plus 2 years. Trip history is retained for 7 years for tax/legal purposes.'),
            _sectionText(c, '7. Children\'s Privacy', 'Our Service is not intended for users under 18 years. We do not knowingly collect personal information from children.'),
            _sectionText(c, '8. Contact Us', 'For privacy inquiries, contact us at privacy@cruiseride.com or through Settings > Support > Send Message.'),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _sectionText(AppColors c, String title, String content) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: c.textPrimary),
          ),
          const SizedBox(height: 8),
          Text(
            content,
            style: TextStyle(fontSize: 14, color: c.textSecondary, height: 1.5),
          ),
        ],
      ),
    );
  }
}
