import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import 'profile_review_screen.dart';

class ProfilePhotoScreen extends StatefulWidget {
  final String firstName;
  final String lastName;
  final String email;
  final String phone;
  final String paymentMethod;

  const ProfilePhotoScreen({
    super.key,
    required this.firstName,
    required this.lastName,
    required this.email,
    this.phone = '',
    required this.paymentMethod,
  });

  @override
  State<ProfilePhotoScreen> createState() => _ProfilePhotoScreenState();
}

class _ProfilePhotoScreenState extends State<ProfilePhotoScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);
  static const _photoKey = 'pending_profile_photo';

  String? _photoPath;
  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _restorePhoto();
  }

  /// Restore previously picked photo path (survives back-navigation)
  Future<void> _restorePhoto() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString(_photoKey);
    if (saved != null && saved.isNotEmpty && mounted) {
      final exists = kIsWeb || await File(saved).exists();
      if (exists) {
        setState(() => _photoPath = saved);
      }
    }
  }

  /// Persist photo path so it survives back-navigation
  Future<void> _savePhotoPath(String path) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_photoKey, path);
  }

  Future<void> _choosePhoto() async {
    final xf = await _picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 600,
    );
    if (xf != null) {
      setState(() => _photoPath = xf.path);
      await _savePhotoPath(xf.path);
      _advance();
    }
  }

  Future<void> _takePhoto() async {
    final xf = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 600,
    );
    if (xf != null) {
      setState(() => _photoPath = xf.path);
      await _savePhotoPath(xf.path);
      _advance();
    }
  }

  void _advance() {
    if (!mounted) return;
    Navigator.of(context).push(
      slideFromRightRoute(
        ProfileReviewScreen(
          firstName: widget.firstName,
          lastName: widget.lastName,
          email: widget.email,
          phone: widget.phone,
          paymentMethod: widget.paymentMethod,
          photoPath: _photoPath,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            const SizedBox(height: 8),

            // ── Back button ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Align(
                alignment: Alignment.topLeft,
                child: GestureDetector(
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
              ),
            ),
            const SizedBox(height: 24),

              // ── Illustration: full-width image (circle preview once picked) ──
              if (_photoPath != null)
                Container(
                  width: 140,
                  height: 140,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: [
                        _gold.withValues(alpha: 0.3),
                        _gold.withValues(alpha: 0.1),
                      ],
                    ),
                  ),
                  child: ClipOval(
                    child: kIsWeb
                        ? CachedNetworkImage(
                            imageUrl: _photoPath!,
                            fit: BoxFit.cover,
                            width: 140,
                            height: 140,
                            fadeInDuration: const Duration(milliseconds: 200),
                          )
                        : Image.file(
                            File(_photoPath!),
                            fit: BoxFit.cover,
                            width: 140,
                            height: 140,
                            gaplessPlayback: true,
                            frameBuilder:
                                (
                                  context,
                                  child,
                                  frame,
                                  wasSynchronouslyLoaded,
                                ) {
                                  if (wasSynchronouslyLoaded) return child;
                                  return AnimatedOpacity(
                                    opacity: frame == null ? 0.0 : 1.0,
                                    duration: const Duration(
                                      milliseconds: 350,
                                    ),
                                    curve: Curves.easeOutCubic,
                                    child: child,
                                  );
                                },
                          ),
                  ),
                )
              else
                ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(28),
                    bottomRight: Radius.circular(28),
                  ),
                  child: Image.asset(
                    'assets/images/onboarding/profile_photo.jpg',
                    width: double.infinity,
                    height: 240,
                    fit: BoxFit.cover,
                  ),
                ),
            const SizedBox(height: 32),

            // ── Title ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                S.of(context).readyCloseUp,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── Subtitle ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                S.of(context).addPhotoSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
            ),
            const SizedBox(height: 8),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                "Drivers can see your photo during rides, but\nnot after you're dropped off",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: c.textTertiary,
                  height: 1.5,
                ),
              ),
            ),

            const Spacer(),

            // ── Choose photo button ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                height: 56,
                child: Container(
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [_gold, _goldLight]),
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      foregroundColor: const Color(0xFF1A1400),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: _choosePhoto,
                    child: Text(
                      S.of(context).chooseFromGallery,
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),

            // ── Take photo ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                height: 50,
                child: TextButton(
                  onPressed: _takePhoto,
                  child: Text(
                    S.of(context).takePhoto,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary,
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 4),

            // ── Skip ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: SizedBox(
                width: double.infinity,
                height: 44,
                child: TextButton(
                  onPressed: () {
                    // Profile photo is mandatory — block skip with a clear message.
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          'Please add a profile photo to continue. Drivers need to recognize you.',
                          style: TextStyle(color: c.textPrimary),
                        ),
                        backgroundColor: c.surface,
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        duration: const Duration(seconds: 3),
                      ),
                    );
                  },
                  child: Text(
                    S.of(context).skip,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                      color: c.textTertiary.withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ),
            ),

            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
