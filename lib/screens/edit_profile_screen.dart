import 'dart:io';
import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/user_session.dart';

class EditProfileScreen extends StatefulWidget {
  const EditProfileScreen({super.key});

  @override
  State<EditProfileScreen> createState() => _EditProfileScreenState();
}

class _EditProfileScreenState extends State<EditProfileScreen> {
  static const _gold = Color(0xFFE8C547);

  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();

  String _photoPath = '';
  String _gender = '';
  bool _loading = true;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    final user = await UserSession.getUser();
    if (!mounted) return;
    setState(() {
      _firstNameCtrl.text = user?['firstName'] ?? '';
      _lastNameCtrl.text = user?['lastName'] ?? '';
      _emailCtrl.text = user?['email'] ?? '';
      _phoneCtrl.text = user?['phone'] ?? '';
      _photoPath = user?['photoPath'] ?? '';
      _gender = user?['gender'] ?? '';
      _loading = false;
    });
  }

  Future<void> _pickPhoto() async {
    final c = AppColors.of(context);
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: c.panel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (ctx) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: c.textTertiary,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Change Photo',
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 20),
              _photoOption(
                c,
                Icons.camera_alt_rounded,
                'Take Photo',
                () => Navigator.pop(ctx, ImageSource.camera),
              ),
              const SizedBox(height: 10),
              _photoOption(
                c,
                Icons.photo_library_rounded,
                'Choose from Gallery',
                () => Navigator.pop(ctx, ImageSource.gallery),
              ),
            ],
          ),
        ),
      ),
    );

    if (source == null) return;

    final picker = ImagePicker();
    final xFile = await picker.pickImage(
      source: source,
      maxWidth: 800,
      imageQuality: 85,
    );
    if (xFile == null || !mounted) return;

    // Copy to permanent storage so the photo survives app restarts
    final permanentPath = await UserSession.saveProfilePhoto(xFile.path);
    // Upload to server so it persists across devices
    try {
      await ApiService.uploadPhoto(permanentPath);
    } catch (e) {
      debugPrint('Photo upload failed (saved locally): $e');
    }
    // Clear cached image so new photo shows immediately
    imageCache.clear();
    imageCache.clearLiveImages();
    setState(() => _photoPath = permanentPath);
  }

  Widget _photoOption(
    AppColors c,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: c.isDark ? c.surface : const Color(0xFFF5F6FA),
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(icon, color: c.textPrimary, size: 22),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w600,
                color: c.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final first = _firstNameCtrl.text.trim();
    final last = _lastNameCtrl.text.trim();
    if (first.isEmpty) {
      _showSnack('First name is required');
      return;
    }

    setState(() => _saving = true);

    // Save locally
    await UserSession.updateField('firstName', first);
    await UserSession.updateField('lastName', last);
    await UserSession.updateField('email', _emailCtrl.text.trim());
    await UserSession.updateField('phone', _phoneCtrl.text.trim());
    // photoPath is already saved by saveProfilePhoto when photo was picked,
    // but update it again in case user didn't change the photo
    await UserSession.updateField('photoPath', _photoPath);
    if (_gender.isNotEmpty) {
      await UserSession.updateField('gender', _gender);
    }

    // Sync with backend
    try {
      await ApiService.updateMe({
        'first_name': first,
        'last_name': last,
        'email': _emailCtrl.text.trim(),
        'phone': _phoneCtrl.text.trim(),
        if (_gender.isNotEmpty) 'gender': _gender,
      });
    } catch (e) {
      debugPrint('⚠️ Profile sync failed: $e');
      // Saved locally — will sync later
    }

    if (!mounted) return;
    setState(() => _saving = false);
    _showSnack('Profile updated');
    Navigator.of(context).pop(true); // true = changed
  }

  void _showSnack(String msg) {
    final c = AppColors.of(context);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: c.isDark ? c.surface : Colors.black87,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    if (_loading) {
      return Scaffold(
        backgroundColor: c.bg,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Icon(
                        Icons.arrow_back_rounded,
                        color: c.textPrimary,
                        size: 24,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Text(
                    S.of(context).editProfile,
                    style: TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                      color: c.textPrimary,
                    ),
                  ),
                  const Spacer(),
                  GestureDetector(
                    onTap: _saving ? null : _save,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: _gold,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: _saving
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.black,
                              ),
                            )
                          : Text(
                              S.of(context).save,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Color(0xFF1A1400),
                              ),
                            ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 28),

            // ── Scrollable content ──
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  children: [
                    // ── Photo ──
                    GestureDetector(
                      onTap: _pickPhoto,
                      child: Stack(
                        children: [
                          Container(
                            width: 100,
                            height: 100,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: c.surface,
                              border: Border.all(
                                color: _gold.withValues(alpha: 0.4),
                                width: 2,
                              ),
                            ),
                            child: ClipOval(
                              child:
                                  _photoPath.isNotEmpty &&
                                      !kIsWeb &&
                                      File(_photoPath).existsSync()
                                  ? Image.file(
                                      File(_photoPath),
                                      fit: BoxFit.cover,
                                      width: 100,
                                      height: 100,
                                      gaplessPlayback: true,
                                      frameBuilder:
                                          (
                                            context,
                                            child,
                                            frame,
                                            wasSynchronouslyLoaded,
                                          ) {
                                            if (wasSynchronouslyLoaded) {
                                              return child;
                                            }
                                            return AnimatedOpacity(
                                              opacity: frame == null
                                                  ? 0.0
                                                  : 1.0,
                                              duration: const Duration(
                                                milliseconds: 300,
                                              ),
                                              curve: Curves.easeOutCubic,
                                              child: child,
                                            );
                                          },
                                    )
                                  : Icon(
                                      Icons.person_rounded,
                                      size: 50,
                                      color: c.textTertiary,
                                    ),
                            ),
                          ),
                          Positioned(
                            bottom: 0,
                            right: 0,
                            child: Container(
                              width: 32,
                              height: 32,
                              decoration: BoxDecoration(
                                color: _gold,
                                shape: BoxShape.circle,
                                border: Border.all(color: c.bg, width: 2),
                              ),
                              child: const Icon(
                                Icons.camera_alt_rounded,
                                size: 16,
                                color: Color(0xFF1A1400),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 28),

                    // ── Fields ──
                    _field(
                      c,
                      S.of(context).firstName,
                      _firstNameCtrl,
                      Icons.person_outline_rounded,
                      readOnly: true,
                    ),
                    const SizedBox(height: 14),
                    _field(
                      c,
                      S.of(context).lastName,
                      _lastNameCtrl,
                      Icons.person_outline_rounded,
                      readOnly: true,
                    ),
                    const SizedBox(height: 14),
                    _field(
                      c,
                      S.of(context).email,
                      _emailCtrl,
                      Icons.email_outlined,
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 14),
                    _field(
                      c,
                      'Phone',
                      _phoneCtrl,
                      Icons.phone_outlined,
                      keyboardType: TextInputType.phone,
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _field(
    AppColors c,
    String label,
    TextEditingController ctrl,
    IconData icon, {
    TextInputType keyboardType = TextInputType.text,
    bool readOnly = false,
  }) {
    return Opacity(
      opacity: readOnly ? 0.5 : 1.0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: c.isDark
              ? null
              : Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: TextField(
          controller: ctrl,
          keyboardType: keyboardType,
          readOnly: readOnly,
          enabled: !readOnly,
          style: TextStyle(fontSize: 16, color: c.textPrimary),
          decoration: InputDecoration(
            prefixIcon: Icon(
              icon,
              color: readOnly ? c.textTertiary : c.textSecondary,
              size: 20,
            ),
            labelText: label,
            labelStyle: TextStyle(fontSize: 14, color: c.textSecondary),
            border: InputBorder.none,
            suffixIcon: readOnly
                ? Icon(
                    Icons.lock_outline_rounded,
                    color: c.textTertiary,
                    size: 16,
                  )
                : null,
          ),
        ),
      ),
    );
  }
}
