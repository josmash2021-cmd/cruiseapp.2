import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';

class TermsConditionsScreen extends StatelessWidget {
  const TermsConditionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: c.textPrimary,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    s.termsTitle,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary,
                    ),
                  ),
                ],
              ),
            ),
            Divider(color: c.divider, height: 1),

            // ── Content ──
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(24),
                physics: const BouncingScrollPhysics(),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _sectionTitle(c, s.termsLastUpdated),
                    _paragraph(c, s.termsLastUpdatedDate),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsAcceptanceTitle),
                    _paragraph(c, s.termsAcceptanceBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsEligibilityTitle),
                    _paragraph(c, s.termsEligibilityBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsAccountTitle),
                    _paragraph(c, s.termsAccountBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsServicesTitle),
                    _paragraph(c, s.termsServicesBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsBookingTitle),
                    _paragraph(c, s.termsBookingBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsPaymentsTitle),
                    _paragraph(c, s.termsPaymentsBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsPaymentMethodsTitle),
                    _paragraph(c, s.termsPaymentMethodsBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsUserConductTitle),
                    _paragraph(c, s.termsUserConductBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsSafetyTitle),
                    _paragraph(c, s.termsSafetyBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsPrivacyTitle),
                    _paragraph(c, s.termsPrivacyBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsIpTitle),
                    _paragraph(c, s.termsIpBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsLiabilityTitle),
                    _paragraph(c, s.termsLiabilityBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsIndemnificationTitle),
                    _paragraph(c, s.termsIndemnificationBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsTerminationTitle),
                    _paragraph(c, s.termsTerminationBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsDisputeTitle),
                    _paragraph(c, s.termsDisputeBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsModificationsTitle),
                    _paragraph(c, s.termsModificationsBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsGoverningLawTitle),
                    _paragraph(c, s.termsGoverningLawBody),
                    const SizedBox(height: 20),

                    _sectionTitle(c, s.termsContactTitle),
                    _paragraph(c, s.termsContactBody),
                    const SizedBox(height: 40),

                    // ── Acceptance notice ──
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: c.border),
                      ),
                      child: Text(
                        s.termsAcceptanceNotice,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: 13,
                          color: c.textSecondary,
                          fontStyle: FontStyle.italic,
                          height: 1.5,
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(AppColors c, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w700,
          color: c.textPrimary,
          letterSpacing: -0.3,
        ),
      ),
    );
  }

  Widget _paragraph(AppColors c, String text) {
    return Text(
      text,
      style: TextStyle(fontSize: 15, color: c.textSecondary, height: 1.6),
    );
  }
}
