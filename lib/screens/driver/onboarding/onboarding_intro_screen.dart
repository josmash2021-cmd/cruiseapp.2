import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../config/page_transitions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import 'background_consent_screen.dart';
import 'doc_capture_screen.dart';
import 'license_capture_screen.dart';
import 'onboarding_items.dart';
import 'onboarding_widgets.dart';
import 'plate_capture_screen.dart';
import 'profile_photo_capture_screen.dart';
import 'ssn_capture_screen.dart';
import 'vehicle_capture_screen.dart';

/// Generic Lyft-style intro for every onboarding item: hero image, big
/// title, subtitle, gold CTA + "Skip for now" (back to the hub).
///
/// Two modes:
/// - pending/rejected → intro; CTA pushes the item's capture screen.
/// - submitted/approved → read-only summary of what was sent, with a
///   Resubmit action that calls the resubmit endpoint and then opens the
///   capture flow again.
class OnboardingIntroScreen extends StatelessWidget {
  const OnboardingIntroScreen({super.key, required this.entry});

  final OnboardingItemEntry entry;

  Widget _captureScreenFor(OnboardingItem item) {
    switch (item) {
      case OnboardingItem.plate:
        return const PlateCaptureScreen();
      case OnboardingItem.ssn:
        return const SsnCaptureScreen();
      case OnboardingItem.vehicle:
        return const VehicleCaptureScreen();
      case OnboardingItem.license:
        return const LicenseCaptureScreen();
      case OnboardingItem.photo:
        return const ProfilePhotoCaptureScreen();
      case OnboardingItem.background:
        return const BackgroundConsentScreen();
      case OnboardingItem.registration:
      case OnboardingItem.insurance:
      case OnboardingItem.inspection:
        return DocCaptureScreen(entry: entry);
    }
  }

  Future<void> _openCapture(BuildContext context) async {
    final submitted = await Navigator.of(
      context,
    ).push(onboardingFadeSlideRoute<bool>(_captureScreenFor(entry.item)));
    // A successful capture means the whole item flow is done — pop the
    // intro too so the hub (which refreshes on pop) is next.
    if (submitted == true && context.mounted) {
      Navigator.of(context).pop(true);
    }
  }

  Future<void> _resubmit(BuildContext context) async {
    try {
      await ApiService.resubmitOnboardingItem(entry.item.key);
    } catch (_) {
      // Non-blocking — even if the flag call fails, let the driver
      // re-capture; the fresh submit overwrites the old data.
    }
    if (context.mounted) await _openCapture(context);
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final s = S.of(context);
    final copy = OnboardingIntroCopy.of(s, entry.item);
    final readOnly = entry.isCompleted;

    return Scaffold(
      backgroundColor: kOnboardingNavy,
      body: Column(
        children: [
          Padding(
            padding: EdgeInsets.only(top: pad.top + 8, left: 8),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── Hero image ──
                  ClipRRect(
                    borderRadius: BorderRadius.circular(20),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 24),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(20),
                        child: Image.asset(
                          entry.item.asset,
                          width: double.infinity,
                          height: 220,
                          fit: BoxFit.cover,
                          errorBuilder: (_, __, ___) => Container(
                            height: 220,
                            decoration: BoxDecoration(
                              color: kOnboardingGold.withValues(alpha: 0.10),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: Icon(
                              onboardingItemIcon(entry.item),
                              color: kOnboardingGold,
                              size: 64,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 28),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          copy.title,
                          style: GoogleFonts.poppins(
                            fontSize: 28,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.4,
                            color: Colors.white,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 12),
                        Text(
                          copy.subtitle,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            height: 1.5,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                        if (readOnly) ...[
                          const SizedBox(height: 20),
                          Container(
                            width: double.infinity,
                            padding: const EdgeInsets.all(14),
                            decoration: BoxDecoration(
                              color: kOnboardingGold.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: kOnboardingGold.withValues(alpha: 0.3),
                              ),
                            ),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.check_circle_rounded,
                                  color: kOnboardingGold,
                                  size: 22,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    s.obSubmittedReadOnly,
                                    style: GoogleFonts.inter(
                                      fontSize: 13.5,
                                      height: 1.4,
                                      color: Colors.white.withValues(
                                        alpha: 0.85,
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // ── CTA ──
          Padding(
            padding: EdgeInsets.fromLTRB(28, 8, 28, pad.bottom + 8),
            child: Column(
              children: [
                if (readOnly) ...[
                  OnboardingGoldButton(
                    label: s.obResubmit,
                    onTap: () => _resubmit(context),
                  ),
                  OnboardingTextButton(
                    label: s.back,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ] else ...[
                  OnboardingGoldButton(
                    label: copy.button,
                    onTap: () => _openCapture(context),
                  ),
                  OnboardingTextButton(
                    label: s.obSkipForNow,
                    onTap: () => Navigator.of(context).pop(),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
