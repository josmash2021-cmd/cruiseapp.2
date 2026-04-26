import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';

class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(S.of(context).termsOfService),
        backgroundColor: c.surface,
        elevation: 0,
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Terms of Service',
              style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold, color: c.textPrimary),
            ),
            const SizedBox(height: 8),
            Text(
              'Effective Date: April 2026',
              style: TextStyle(fontSize: 14, color: c.textSecondary),
            ),
            const SizedBox(height: 24),
            _sectionText(c, '1. Agreement to Terms', 'By using the Cruise app, you agree to be bound by these Terms of Service. We reserve the right to modify these terms at any time.'),
            _sectionText(c, '2. Eligibility', 'Riders must be at least 18 years old. Drivers must be at least 25 years old, hold a valid driver\'s license, and pass a background check. All users must have legal capacity to enter into this agreement and agree to use the Service only for lawful purposes.'),
            _sectionText(c, '3. Account Registration', 'You are responsible for providing accurate information, maintaining password confidentiality, and notifying us of unauthorized access.'),
            _sectionText(c, '4. Riders\' Terms', 'Riders request rides through the app. Cancellations within 2 minutes are free; after 2 minutes, cancellation fees apply. Payment is automatic via your default method.'),
            _sectionText(c, '5. Drivers\' Terms', 'Drivers must be at least 25 years old, pass background checks, and maintain vehicle insurance. Driver earnings vary by vehicle tier: Comfort (60%), Premium (65%), and VIP (70%) of the fare. Tips go 100% to the driver. Refunds to riders reduce driver earnings.'),
            _sectionText(c, '6. General Conduct', 'All users agree to treat each other with respect, not engage in harassment or violence, and not use the app for illegal purposes.'),
            _sectionText(c, '7. Liability & Disclaimers', 'We provide supplemental insurance during active trips. Drivers are responsible for vehicle maintenance and accidents. We investigate reported safety violations.'),
            _sectionText(c, '8. Dispute Resolution', 'Report issues through Settings > Support. Most disputes are resolved through our support team. Unresolved disputes go to binding arbitration.'),
            _sectionText(c, '9. Termination', 'We may terminate accounts for Terms violations, illegal activity, or safety concerns. You can terminate membership anytime through Settings.'),
            _sectionText(c, '10. Governing Law', 'These Terms are governed by applicable regional laws. For questions, contact legal@cruiseride.com.'),
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
