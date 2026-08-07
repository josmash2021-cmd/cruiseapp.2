import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/haptic_service.dart';
import 'doc_scan_illustration.dart';
import 'neu_style.dart';

/// "Guidelines for taking a photo of your document" — the page shown *before*
/// the camera opens, shared by the rider identity flow and driver signup.
///
/// The design lives here exactly once: illustration, title, bullets and the
/// gold Next button are all laid out by this widget; callers only pick the
/// document via [docType] and decide what Next (and the X) do.
class DocGuidelinesView extends StatelessWidget {
  const DocGuidelinesView({
    super.key,
    required this.docType,
    required this.onNext,
    this.onClose,
  });

  /// `'license'` | `'government_id'` | `'passport'` — picks the illustration,
  /// title and bullets. Anything else falls back to the license copy.
  final String docType;

  /// Gold Next button. The light haptic fires here before this is called.
  final VoidCallback onNext;

  /// Top-left X. Standalone screens leave this null and it pops the route;
  /// embedded flows pass their own "back a step" instead.
  final VoidCallback? onClose;

  static const _gold = Color(0xFFE8C547);
  static const _goldDark = Color(0xFFB8972E);

  String _title(S s) {
    switch (docType) {
      case 'passport':
        return s.guidelinesPassportTitle;
      case 'government_id':
        return s.guidelinesGovIdTitle;
      default:
        return s.guidelinesLicenseTitle;
    }
  }

  List<String> _bullets(S s) {
    switch (docType) {
      case 'passport':
        return [
          s.guidelinePassportValid,
          s.guidelinePassportPhysical,
          s.guidelinePassportCorners,
        ];
      case 'government_id':
        return [
          s.guidelineGovIdValid,
          s.guidelineGovIdPhysical,
          s.guidelineGovIdCorners,
        ];
      default:
        return [
          s.guidelineLicenseValid,
          s.guidelineLicensePhysical,
          s.guidelineLicenseCorners,
        ];
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: GestureDetector(
              // Back out, not straight into the camera — the whole point of
              // this step is that nothing opens until they tap Next.
              onTap: onClose ?? () => Navigator.of(context).pop(),
              child: Container(
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: neuBox(radius: 12),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white, size: 20),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              // Long copy on a small phone must scroll rather than overflow.
              physics: const BouncingScrollPhysics(),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 28),
                  Center(
                    child: DocScanIllustration(docType: docType, height: 190),
                  ),
                  const SizedBox(height: 30),
                  Text(
                    _title(s),
                    style: TextStyle(
                      fontSize: 23,
                      height: 1.25,
                      fontWeight: FontWeight.w800,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 22),
                  for (final bullet in _bullets(s))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            margin: const EdgeInsets.only(top: 9, right: 14),
                            decoration: const BoxDecoration(
                              color: _gold,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              bullet,
                              style: TextStyle(
                                fontSize: 15,
                                height: 1.45,
                                color: c.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
          ),
          GestureDetector(
            onTap: () {
              HapticService.lightImpact();
              onNext();
            },
            child: Container(
              height: 56,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [_gold, _goldDark]),
                borderRadius: BorderRadius.circular(28),
              ),
              child: Text(
                s.next,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: Colors.black,
                ),
              ),
            ),
          ),
          SizedBox(
            height: MediaQuery.of(context).viewInsets.bottom > 0
                ? 12
                : MediaQuery.of(context).padding.bottom + 24,
          ),
        ],
      ),
    );
  }
}
