import 'package:flutter/material.dart';

import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import 'onboarding_widgets.dart';

/// Background check consent — renders the FCRA standalone disclosure and
/// authorization (mirrors docs/background_check_disclosure_authorization.md,
/// v1.0) with scroll, then a gold "I authorize" button that posts
/// `{accepted: true}` to `/auth/onboarding-items/background`.
class BackgroundConsentScreen extends StatefulWidget {
  const BackgroundConsentScreen({super.key});

  @override
  State<BackgroundConsentScreen> createState() =>
      _BackgroundConsentScreenState();
}

class _BackgroundConsentScreenState extends State<BackgroundConsentScreen> {
  bool _submitting = false;

  Future<void> _authorize() async {
    if (_submitting) return;
    final s = S.of(context);
    setState(() => _submitting = true);
    try {
      await ApiService.submitOnboardingBackground();
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showOnboardingError(context, e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _submitting = false);
      showOnboardingError(context, s.connectionError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final s = S.of(context);

    return Scaffold(
      backgroundColor: kOnboardingNavy,
      appBar: AppBar(
        backgroundColor: kOnboardingNavy,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded, color: Colors.white),
        ),
        title: Text(
          s.obBackgroundTitle,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        centerTitle: true,
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(18),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  s.obBackgroundLegal,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.8),
                    fontSize: 13.5,
                    height: 1.55,
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, pad.bottom + 16),
            child: OnboardingGoldButton(
              label: s.obIAuthorize,
              loading: _submitting,
              onTap: _authorize,
            ),
          ),
        ],
      ),
    );
  }
}
