import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../../config/page_transitions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../widgets/doc_guidelines_view.dart';
import 'onboarding_items.dart';
import 'onboarding_widgets.dart';

/// Document photo capture for the onboarding to-do flow (Lyft style) —
/// shared by Registration, Insurance and (Alabama-only) Inspection.
///
/// Big title, "Learn more" link to the shared [DocGuidelinesView], a large
/// upload area ("Upload photo" → camera or gallery), the picked image shown
/// full-bleed at its own aspect ratio, per-document requirement bullets and
/// a gold Save button. Saving uploads through the existing documents
/// mechanism (`/drivers/documents/upload`) and mirrors the URL onto the user
/// column via `POST /auth/onboarding-items/{item}/doc`, then pops `true`.
class DocCaptureScreen extends StatefulWidget {
  const DocCaptureScreen({super.key, required this.entry});

  final OnboardingItemEntry entry;

  @override
  State<DocCaptureScreen> createState() => _DocCaptureScreenState();
}

class _DocCaptureScreenState extends State<DocCaptureScreen> {
  String? _photoPath;
  bool _uploading = false;

  OnboardingItem get _item => widget.entry.item;

  /// doc_type of the legacy documents endpoint backing each item.
  String get _docType => switch (_item) {
    OnboardingItem.registration => 'registration',
    OnboardingItem.insurance => 'insurance',
    OnboardingItem.inspection => 'vehicle_inspection',
    _ => 'registration',
  };

  String _title(S s) => switch (_item) {
    OnboardingItem.registration => s.obItemRegistrationTitle,
    OnboardingItem.insurance => s.obItemInsuranceTitle,
    OnboardingItem.inspection => s.obItemInspectionTitle,
    _ => s.obItemRegistrationTitle,
  };

  List<String> _bullets(S s) => switch (_item) {
    OnboardingItem.insurance => [
        s.obDocBulletValid,
        s.obDocBulletNameOnPolicy,
        s.obDocBulletNotBlurry,
        s.obDocBulletCorners,
      ],
    OnboardingItem.inspection => [
        s.obDocBulletValid,
        s.obDocBulletNotBlurry,
        s.obDocBulletCorners,
      ],
    _ => [
        s.obDocBulletValid,
        s.obDocBulletMatch,
        s.obDocBulletNotBlurry,
        s.obDocBulletCorners,
      ],
  };

  Future<void> _pick(ImageSource source) async {
    try {
      final x = await ImagePicker().pickImage(
        source: source,
        maxWidth: 2200,
        imageQuality: 90,
      );
      if (x != null && mounted) setState(() => _photoPath = x.path);
    } catch (e) {
      debugPrint('⚠️ Doc pick failed: $e');
    }
  }

  void _showPickOptions() {
    final s = S.of(context);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: const Color(0xFF101736),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.photo_camera_outlined,
                color: kOnboardingGold,
              ),
              title: Text(
                s.takePhoto,
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _pick(ImageSource.camera);
              },
            ),
            ListTile(
              leading: const Icon(
                Icons.photo_library_outlined,
                color: kOnboardingGold,
              ),
              title: Text(
                s.chooseFromGallery,
                style: const TextStyle(color: Colors.white),
              ),
              onTap: () {
                Navigator.of(ctx).pop();
                _pick(ImageSource.gallery);
              },
            ),
          ],
        ),
      ),
    );
  }

  void _openGuidelines() {
    Navigator.of(context).push(
      onboardingFadeSlideRoute(
        Scaffold(
          backgroundColor: kOnboardingNavy,
          body: SafeArea(
            child: DocGuidelinesView(
              docType: 'government_id',
              onNext: () => Navigator.of(context).pop(),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    final path = _photoPath;
    if (path == null || _uploading) return;
    final s = S.of(context);
    setState(() => _uploading = true);
    try {
      final uploaded = await ApiService.uploadDocument(
        docType: _docType,
        filePath: path,
      );
      final url = uploaded['file_path'] as String?;
      if (url != null && url.isNotEmpty) {
        await ApiService.submitOnboardingDoc(item: _item.key, url: url);
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _uploading = false);
      showOnboardingError(context, e.message);
    } catch (_) {
      if (!mounted) return;
      setState(() => _uploading = false);
      showOnboardingError(context, s.connectionError);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final s = S.of(context);
    final alreadySaved = widget.entry.isCompleted && _photoPath == null;
    final title = _title(s);

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
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 8),
                  Text(
                    title,
                    style: GoogleFonts.poppins(
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.4,
                      color: Colors.white,
                      height: 1.15,
                    ),
                  ),
                  if (alreadySaved) ...[
                    const SizedBox(height: 12),
                    Text(
                      s.obDocSavedMsg(title.toLowerCase()),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        height: 1.45,
                        color: Colors.white.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: _openGuidelines,
                    child: Text(
                      s.obDocLearnMore(title.toLowerCase()),
                      style: GoogleFonts.inter(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: kOnboardingGold,
                        decoration: TextDecoration.underline,
                        decorationColor: kOnboardingGold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── Upload area / picked photo (full-bleed, own aspect) ──
                  if (_photoPath != null)
                    Image.file(
                      File(_photoPath!),
                      width: double.infinity,
                      fit: BoxFit.fitWidth,
                    )
                  else
                    GestureDetector(
                      onTap: _showPickOptions,
                      child: Container(
                        width: double.infinity,
                        height: 220,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(18),
                          border: Border.all(
                            color: kOnboardingGold.withValues(alpha: 0.45),
                          ),
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(
                              Icons.cloud_upload_outlined,
                              color: kOnboardingGold,
                              size: 44,
                            ),
                            const SizedBox(height: 14),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 22,
                                vertical: 11,
                              ),
                              decoration: BoxDecoration(
                                color: kOnboardingGold,
                                borderRadius: BorderRadius.circular(24),
                              ),
                              child: Text(
                                s.obUploadPhoto,
                                style: const TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.black,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),

                  const SizedBox(height: 24),

                  // ── Requirement bullets ──
                  for (final bullet in _bullets(s))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 5,
                            height: 5,
                            margin: const EdgeInsets.only(top: 8, right: 12),
                            decoration: const BoxDecoration(
                              color: kOnboardingGold,
                              shape: BoxShape.circle,
                            ),
                          ),
                          Expanded(
                            child: Text(
                              bullet,
                              style: GoogleFonts.inter(
                                fontSize: 14,
                                height: 1.45,
                                color: Colors.white.withValues(alpha: 0.7),
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

          // ── Save — gold, enabled once a photo is picked ──
          Padding(
            padding: EdgeInsets.fromLTRB(24, 8, 24, pad.bottom + 8),
            child: Column(
              children: [
                OnboardingGoldButton(
                  label: s.save,
                  loading: _uploading,
                  onTap: _photoPath != null ? _save : null,
                ),
                if (_photoPath != null)
                  OnboardingTextButton(
                    label: s.retake,
                    onTap: () => setState(() => _photoPath = null),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
