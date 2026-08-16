import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/firebase_storage_service.dart';
import '../services/haptic_service.dart';
import '../services/photo_recovery_service.dart';
import '../services/user_session.dart';
import '../widgets/neu_style.dart';
import '../widgets/user_profile_photo.dart';
import '../utils/phone_format.dart';
import 'driver/driver_reset_password_screen.dart';

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
  String _photoUrl = '';
  String _gender = '';
  bool _loading = false;
  bool _saving = false;

  /// Digits only, without the US country code.
  static String _phoneDigits(String raw) {
    var d = raw.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('1') && d.length > 10) d = d.substring(1);
    if (d.length > 10) d = d.substring(d.length - 10);
    return d;
  }

  /// Display form lives in utils/phone_format.dart (shared with the
  /// forgot-password identifier field).

  /// Storage form: E.164 (+1XXXXXXXXXX) — what the backend holds.
  static String _phoneE164(String display) {
    final d = _phoneDigits(display);
    return d.isEmpty ? '' : '+1$d';
  }

  /// Original values loaded from the session — the Save button only appears
  /// when any editable field differs from these or a new photo was picked.
  String _origFirstName = '';
  String _origLastName = '';
  String _origEmail = '';
  String _origPhone = '';

  /// Temp path of a newly-picked photo that hasn't been saved yet.
  /// Null means no new photo was picked in this session.
  String? _pendingPhotoPath;

  bool get _hasChanges =>
      _pendingPhotoPath != null ||
      _firstNameCtrl.text.trim() != _origFirstName.trim() ||
      _lastNameCtrl.text.trim() != _origLastName.trim() ||
      _emailCtrl.text.trim() != _origEmail.trim() ||
      _phoneE164(_phoneCtrl.text) != _origPhone;

  void _onFieldChanged() => setState(() {});

  @override
  void initState() {
    super.initState();
    _firstNameCtrl.addListener(_onFieldChanged);
    _lastNameCtrl.addListener(_onFieldChanged);
    _emailCtrl.addListener(_onFieldChanged);
    _phoneCtrl.addListener(_onFieldChanged);
    _loadUser();
  }

  @override
  void dispose() {
    _firstNameCtrl.removeListener(_onFieldChanged);
    _lastNameCtrl.removeListener(_onFieldChanged);
    _emailCtrl.removeListener(_onFieldChanged);
    _phoneCtrl.removeListener(_onFieldChanged);
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
      // Stored as E.164 or bare digits; shown formatted.
      _phoneCtrl.text = formatUsPhone(_phoneDigits(user?['phone'] ?? ''));
      _origFirstName = _firstNameCtrl.text;
      _origLastName = _lastNameCtrl.text;
      _origEmail = _emailCtrl.text;
      _origPhone = _phoneE164(_phoneCtrl.text);
      _photoPath = user?['photoPath'] ?? '';
      _photoUrl = user?['photoUrl'] ?? UserSession.photoUrlNotifier.value;
      _gender = user?['gender'] ?? '';
      _loading = false;
    });
  }

  Future<void> _pickPhoto() async {
    final c = AppColors.of(context);
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: neuBase,
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
                S.of(context).takePhoto,
                () => Navigator.pop(ctx, ImageSource.camera),
              ),
              const SizedBox(height: 10),
              _photoOption(
                c,
                Icons.photo_library_rounded,
                S.of(context).chooseFromGallery,
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

    // Only store the temp path — don't save or upload until user presses Save
    setState(() => _pendingPhotoPath = xFile.path);
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
        decoration: neuBox(radius: 14),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: neuBox(radius: 12, pressed: true),
              child: Icon(icon, color: _gold, size: 18),
            ),
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
    if (last.isEmpty) {
      _showSnack('Last name is required');
      return;
    }

    setState(() => _saving = true);

    // ── If user picked a new photo, persist locally + upload in background ──
    if (_pendingPhotoPath != null) {
      final permanentPath =
          await UserSession.saveProfilePhoto(_pendingPhotoPath!);
      imageCache.clear();
      imageCache.clearLiveImages();
      _photoPath = permanentPath;

      // Clear stale remote URL so all widgets fall back to the fresh local file
      // until the Firebase upload completes and sets the new URL.
      await UserSession.updateField('photoUrl', '');
      UserSession.photoUrlNotifier.value = '';

      // Evict cached network image for this user so stale photo isn't served
      final uid = await ApiService.getCurrentUserId();
      if (uid != null) {
        UserProfilePhoto.evictCachedPhoto(uid.toString());
      }

      // Fire-and-forget: upload to backend + Firebase Storage
      // Don't await — let the screen pop immediately
      final uploadPath = permanentPath;
      Future<void>(() async {
        ApiService.uploadPhoto(uploadPath).catchError((e) {
          debugPrint('Photo upload failed (saved locally): $e');
          return '';
        });
        final userId = await ApiService.getCurrentUserId();
        if (userId == null) return;
        final user = await UserSession.getUser();
        final role = user?['role'] ?? 'rider';
        try {
          final firebaseUrl = await FirebaseStorageService.uploadProfilePhoto(
            uploadPath, userId, role,
          );
          await FirebaseStorageService.updateFirestorePhotoUrl(
              userId, firebaseUrl, role);
          await PhotoRecoveryService.savePhotoEveryWhere(
              userId.toString(), role, firebaseUrl);
          UserSession.photoUrlNotifier.value = firebaseUrl;
          await UserSession.updateField('photoUrl', firebaseUrl);
        } catch (e) {
          debugPrint('Firebase photo sync failed: $e');
        }
      });
    }

    // Save locally
    await UserSession.updateField('firstName', first);
    await UserSession.updateField('lastName', last);
    await UserSession.updateField('email', _emailCtrl.text.trim());
    await UserSession.updateField('phone', _phoneE164(_phoneCtrl.text));
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
        'phone': _phoneE164(_phoneCtrl.text),
        if (_gender.isNotEmpty) 'gender': _gender,
      });
    } catch (e) {
      debugPrint('Profile sync failed: $e');
    }

    if (!mounted) return;
    setState(() => _saving = false);
    _showSnack('Profile updated');
    Navigator.of(context).pop(true); // true = changed
  }

  /// Same emailed-code reset the driver app uses — the screen sends the
  /// code to the account's own address on open.
  Future<void> _openPasswordReset() async {
    HapticService.selectionClick();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const DriverResetPasswordScreen()),
    );
    if (changed == true && mounted) {
      _showSnack(S.of(context).passwordChanged);
    }
  }

  void _showSnack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        // Uses global snackBarTheme (gold, floating, swipe-to-dismiss)
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    if (_loading) {
      return Scaffold(
        backgroundColor: neuBase,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: neuBase,
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
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: neuBox(radius: 14, pressed: true),
                      child: Icon(
                        Icons.arrow_back_rounded,
                        color: c.textPrimary,
                        size: 20,
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
                  // Save only appears (animated) when there's a real change
                  // in email, phone, or the profile photo.
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    switchInCurve: Curves.easeOutBack,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, anim) => ScaleTransition(
                      scale: anim,
                      child: FadeTransition(opacity: anim, child: child),
                    ),
                    child: !_hasChanges
                        ? const SizedBox.shrink(key: ValueKey('save_hidden'))
                        : GestureDetector(
                            key: const ValueKey('save_visible'),
                            onTap: _saving ? null : _save,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 20,
                                vertical: 10,
                              ),
                              decoration: BoxDecoration(
                                color: _gold,
                                borderRadius: BorderRadius.circular(20),
                                boxShadow: [
                                  BoxShadow(
                                    color: _gold.withValues(alpha: 0.3),
                                    offset: const Offset(0, 4),
                                    blurRadius: 12,
                                  ),
                                ],
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
                          SizedBox(
                            width: 100,
                            height: 100,
                            child: Stack(
                              alignment: Alignment.center,
                              children: [
                                // Border ring — decoration only, no implicit padding
                                Container(
                                  width: 100,
                                  height: 100,
                                  decoration: neuBox(radius: 50).copyWith(
                                    border: Border.all(
                                      color: _gold.withValues(alpha: 0.4),
                                      width: 2,
                                    ),
                                  ),
                                ),
                                // Photo fills the circle (inset by border width)
                                SizedBox.square(
                                  dimension: 96,
                                  child: _pendingPhotoPath != null
                                      ? ClipOval(
                                          child: Image.file(
                                            File(_pendingPhotoPath!),
                                            width: 96,
                                            height: 96,
                                            fit: BoxFit.cover,
                                          ),
                                        )
                                      : UserProfilePhoto(
                                          photoUrl: _photoUrl,
                                          photoPath: _photoPath,
                                          radius: 48,
                                          fallbackName: '${_firstNameCtrl.text} ${_lastNameCtrl.text}',
                                          uid: UserSession.currentUid,
                                        ),
                                ),
                              ],
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
                                border: Border.all(color: neuBase, width: 2),
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
                    ),
                    const SizedBox(height: 14),
                    _field(
                      c,
                      S.of(context).lastName,
                      _lastNameCtrl,
                      Icons.person_outline_rounded,
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
                      inputFormatters: [const UsPhoneFormatter()],
                    ),
                    const SizedBox(height: 14),
                    // Password reset — a door, not an input. Same emailed-code
                    // flow the driver app uses.
                    GestureDetector(
                      onTap: _openPasswordReset,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 16,
                        ),
                        decoration: neuBox(radius: 14),
                        child: Row(
                          children: [
                            Container(
                              width: 38,
                              height: 38,
                              decoration: neuBox(radius: 12, pressed: true),
                              child: const Icon(
                                Icons.lock_outline_rounded,
                                color: _gold,
                                size: 19,
                              ),
                            ),
                            const SizedBox(width: 13),
                            Expanded(
                              child: Text(
                                S.of(context).forgotPassword,
                                style: TextStyle(
                                  color: c.textPrimary,
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: Colors.white.withValues(alpha: 0.3),
                              size: 22,
                            ),
                          ],
                        ),
                      ),
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
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Opacity(
      opacity: readOnly ? 0.5 : 1.0,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        decoration: neuBox(radius: 14, pressed: true),
        child: TextField(
          controller: ctrl,
          keyboardType: keyboardType,
          readOnly: readOnly,
          enabled: !readOnly,
          inputFormatters: inputFormatters,
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
