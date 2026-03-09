import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
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
    Future.delayed(const Duration(milliseconds: 250), () {
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
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            children: [
              const SizedBox(height: 8),

              // ── Back button ──
              Align(
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
              const SizedBox(height: 24),

              // ── Avatar illustration ──
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
                child: _photoPath != null
                    ? ClipOval(
                        child: kIsWeb
                            ? Image.network(
                                _photoPath!,
                                fit: BoxFit.cover,
                                width: 140,
                                height: 140,
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
                      )
                    : Icon(
                        Icons.person_rounded,
                        size: 70,
                        color: _gold.withValues(alpha: 0.6),
                      ),
              ),
              const SizedBox(height: 32),

              // ── Title ──
              Text(
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
              const SizedBox(height: 12),

              // ── Subtitle ──
              Text(
                S.of(context).addPhotoSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 8),
              Text(
                "Drivers can see your photo during rides, but\nnot after you're dropped off",
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  color: c.textTertiary,
                  height: 1.5,
                ),
              ),

              const Spacer(),

              // ── Choose photo button ──
              SizedBox(
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
              const SizedBox(height: 14),

              // ── Take photo ──
              SizedBox(
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

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
