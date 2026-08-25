import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/user_session.dart';
import '../widgets/feathered_image.dart';
import 'driver/onboarding/driver_notifications_screen.dart';
import 'driver/onboarding/profile_photo_capture_screen.dart';
import 'rider_add_payment_screen.dart';

/// Rider registration — profile photo + gender page (user spec 2026-08-25).
///
/// Sits between the email step and the notification-permission page. No X:
/// the page is part of the required chain. The hero is feathered on every
/// edge ([FeatheredImage]). Gender is REQUIRED — all three actions stay
/// disabled until one is picked, and the choice is persisted
/// (`PATCH /auth/me` + local session) before leaving the page by any exit.
///
/// Photo actions: "Take a photo" opens the existing front-camera capture
/// ([ProfilePhotoCaptureScreen], which uploads on confirm); "Upload from
/// gallery" picks from the gallery and uploads through the same
/// `ApiService.uploadPhoto`; "Skip for now" skips only the photo — the
/// gender is still saved. Any exit continues to the notification page →
/// add payment, exactly like the email step used to.
class RiderPhotoGenderScreen extends StatefulWidget {
  /// The user map carried through the registration chain — forwarded
  /// untouched to [RiderAddPaymentScreen].
  final Map<String, dynamic> user;

  const RiderPhotoGenderScreen({super.key, required this.user});

  @override
  State<RiderPhotoGenderScreen> createState() => _RiderPhotoGenderScreenState();
}

class _RiderPhotoGenderScreenState extends State<RiderPhotoGenderScreen> {
  static const _navy = Color(0xFF14141A);
  static const _gold = Color(0xFFE8C547);

  /// Stable English key for the payload: 'male' | 'female' | 'other'.
  String? _gender;
  bool _busy = false;

  Future<void> _saveGender() async {
    final g = _gender;
    if (g == null) return;
    try {
      await ApiService.updateMe({'gender': g});
      await UserSession.updateField('gender', g);
    } catch (_) {
      // Non-fatal: the profile can be completed later from Edit Profile —
      // blocking the registration chain on this field helps nobody.
    }
  }

  void _continue() {
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      smoothFadeRoute(
        DriverNotificationsScreen(
          nextScreen: RiderAddPaymentScreen(user: widget.user),
        ),
      ),
    );
  }

  Future<void> _takePhoto() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final done = await Navigator.of(context).push<bool>(
        slideFromRightRoute(const ProfilePhotoCaptureScreen()),
      );
      if (done == true) {
        await _saveGender();
        _continue();
        return;
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _pickFromGallery() async {
    if (_busy) return;
    setState(() => _busy = true);
    final s = S.of(context);
    try {
      final x = await ImagePicker().pickImage(
        source: ImageSource.gallery,
        maxWidth: 1600,
      );
      if (x == null) return; // cancelled — stay on the page
      await ApiService.uploadPhoto(x.path);
      await _saveGender();
      _continue();
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(e.message), behavior: SnackBarBehavior.floating),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
            content: Text(s.connectionError),
            behavior: SnackBarBehavior.floating),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _skip() async {
    if (_busy) return;
    setState(() => _busy = true);
    await _saveGender();
    if (mounted) setState(() => _busy = false);
    _continue();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final pad = MediaQuery.of(context).padding;
    final ready = _gender != null && !_busy;

    return Scaffold(
      backgroundColor: _navy,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 16),
            // Feathered hero — the edges dissolve into the navy ground.
            const FeatheredImage(
              'assets/images/onboarding/profile_photo.jpg',
              width: double.infinity,
              height: 240,
            ),
            const SizedBox(height: 28),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      s.obIntroPhotoTitle,
                      style: GoogleFonts.poppins(
                        fontSize: 28,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        height: 1.2,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      s.riderPhotoSubDrivers,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: Colors.white.withValues(alpha: 0.6),
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 28),
                    Text(
                      s.genderSectionLabel,
                      style: GoogleFonts.inter(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                        height: 1.3,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _radioTile(
                      label: s.genderMale,
                      selected: _gender == 'male',
                      onTap: () => setState(() => _gender = 'male'),
                    ),
                    _radioTile(
                      label: s.genderFemale,
                      selected: _gender == 'female',
                      onTap: () => setState(() => _gender = 'female'),
                    ),
                    _radioTile(
                      label: s.genderOther,
                      selected: _gender == 'other',
                      onTap: () => setState(() => _gender = 'other'),
                    ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(28, 8, 28, pad.bottom + 8),
              child: Column(
                children: [
                  // Take a photo — primary gold.
                  GestureDetector(
                    onTap: ready ? _takePhoto : null,
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: double.infinity,
                      height: 58,
                      decoration: BoxDecoration(
                        color: ready ? _gold : _gold.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(18),
                      ),
                      alignment: Alignment.center,
                      child: _busy
                          ? const SizedBox(
                              width: 24,
                              height: 24,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Colors.black,
                              ),
                            )
                          : Text(
                              s.takePhotoButton,
                              style: TextStyle(
                                fontSize: 18,
                                fontWeight: FontWeight.w700,
                                color: ready
                                    ? Colors.black
                                    : Colors.black.withValues(alpha: 0.45),
                              ),
                            ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  // Upload from gallery — secondary outline.
                  GestureDetector(
                    onTap: ready ? _pickFromGallery : null,
                    child: Container(
                      width: double.infinity,
                      height: 58,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: ready
                              ? _gold
                              : Colors.white.withValues(alpha: 0.18),
                          width: 1.6,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        s.uploadFromGalleryButton,
                        style: TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: ready
                              ? _gold
                              : Colors.white.withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Skip for now — text link (gender is still required).
                  TextButton(
                    onPressed: ready ? _skip : null,
                    child: Text(
                      s.obSkipForNow,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: ready
                            ? Colors.white.withValues(alpha: 0.65)
                            : Colors.white.withValues(alpha: 0.30),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Round radio row — gold ring + dot when selected (same idiom as the
  /// "Tell us about yourself" survey).
  Widget _radioTile({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 9),
        child: Row(
          children: [
            AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 24,
              height: 24,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color:
                      selected ? _gold : Colors.white.withValues(alpha: 0.35),
                  width: 1.6,
                ),
              ),
              child: selected
                  ? Center(
                      child: Container(
                        width: 12,
                        height: 12,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          color: _gold,
                        ),
                      ),
                    )
                  : null,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: GoogleFonts.inter(
                  fontSize: 15,
                  color: Colors.white.withValues(alpha: 0.85),
                  height: 1.35,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
