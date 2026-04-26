import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/firebase_storage_service.dart';
import '../../services/photo_recovery_service.dart';
import '../../services/user_session.dart';
import '../../widgets/user_profile_photo.dart';

/// Driver Manage Account page — edit photo, email, phone.
class DriverManageAccountScreen extends StatefulWidget {
  const DriverManageAccountScreen({super.key});

  @override
  State<DriverManageAccountScreen> createState() =>
      _DriverManageAccountScreenState();
}

class _DriverManageAccountScreenState extends State<DriverManageAccountScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _bg = Color(0xFF0A0A0A);
  static const _surface = Color(0xFF252528);

  Map<String, dynamic>? _user;
  bool _loading = true;
  bool _saving = false;
  String? _photoUrl;
  String? _localPhotoPath;

  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  int _emailChanges = 0;
  int _phoneChanges = 0;

  @override
  void initState() {
    super.initState();
    _loadUser();
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadUser() async {
    try {
      final user = await ApiService.getMe();
      if (!mounted) return;
      setState(() {
        _user = user;
        _photoUrl = user?['photo_url'] as String?;
        // Always recover local photo path so avatar never disappears
        final savedPath = UserSession.photoNotifier.value;
        if (savedPath.isNotEmpty) _localPhotoPath = savedPath;
        if ((_photoUrl == null || _photoUrl!.isEmpty) &&
            UserSession.photoUrlNotifier.value.isNotEmpty) {
          _photoUrl = UserSession.photoUrlNotifier.value;
        }
        _emailCtrl.text = user?['email'] as String? ?? '';
        _phoneCtrl.text = user?['phone'] as String? ?? '';
        _emailChanges = (user?['email_changes_count'] as int?) ?? 0;
        _phoneChanges = (user?['phone_changes_count'] as int?) ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  Future<void> _pickPhoto() async {
    final picker = ImagePicker();
    final file = await picker.pickImage(
      source: ImageSource.gallery,
      maxWidth: 800,
      imageQuality: 85,
    );
    if (file == null) return;
    setState(() => _saving = true);
    try {
      final url = await ApiService.uploadPhoto(file.path);
      // Persist photo locally so it survives reinstall/update
      await UserSession.saveProfilePhoto(file.path);
      // ApiService.uploadPhoto already handles Firebase Storage + Firestore sync,
      // so just update local state — no need to re-upload.
      UserSession.photoUrlNotifier.value = url;
      if (!mounted) return;
      // Clear ALL image caches to force fresh photo display
      imageCache.clear();
      imageCache.clearLiveImages();
      // Evict user-specific cached photo so CachedNetworkImage re-fetches
      final uid = UserSession.currentUid;
      if (uid.isNotEmpty) UserProfilePhoto.evictCachedPhoto(uid);
      await UserProfilePhoto.clearCache();
      if (!mounted) return;
      // Add cache-bust param so CachedNetworkImage doesn't serve stale version
      final cacheBust = DateTime.now().millisecondsSinceEpoch;
      final freshUrl = url.contains('?') ? '$url&cb=$cacheBust' : '$url?cb=$cacheBust';
      setState(() {
        _photoUrl = freshUrl;
        _localPhotoPath = file.path;
        _saving = false;
      });
      _snack(S.of(context).photoUpdated);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(S.of(context).errorOccurred);
    }
  }

  Future<void> _saveEmail() async {
    final newEmail = _emailCtrl.text.trim();
    if (newEmail.isEmpty || newEmail == (_user?['email'] ?? '')) return;
    if (_emailChanges >= 3) {
      _snack(S.of(context).maxChangesReached);
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiService.updateMe({'email': newEmail});
      if (!mounted) return;
      setState(() {
        _emailChanges++;
        _saving = false;
      });
      _snack(S.of(context).emailUpdated);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(S.of(context).errorOccurred);
    }
  }

  Future<void> _savePhone() async {
    final newPhone = _phoneCtrl.text.trim();
    if (newPhone.isEmpty || newPhone == (_user?['phone'] ?? '')) return;
    if (_phoneChanges >= 3) {
      _snack(S.of(context).maxChangesReached);
      return;
    }
    setState(() => _saving = true);
    try {
      await ApiService.updateMe({'phone': newPhone});
      if (!mounted) return;
      setState(() {
        _phoneChanges++;
        _saving = false;
      });
      _snack(S.of(context).phoneUpdated);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(e.message);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      _snack(S.of(context).errorOccurred);
    }
  }



  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;

    if (_loading) {
      return Scaffold(
        backgroundColor: _bg,
        body: const Center(child: CircularProgressIndicator(color: _gold)),
      );
    }

    final firstName = _user?['first_name'] as String? ?? '';
    final lastName = _user?['last_name'] as String? ?? '';
    final fullName = '$firstName $lastName'.trim();

    return Scaffold(
      backgroundColor: _bg,
      body: Column(
        children: [
          // ── Top bar ──
          Container(
            color: _surface,
            padding: EdgeInsets.only(
              top: top + 8,
              bottom: 12,
              left: 16,
              right: 16,
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                      size: 22,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  S.of(context).manageAccount,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
              children: [
                // ── Profile photo ──
                Center(
                  child: GestureDetector(
                    onTap: _saving ? null : _pickPhoto,
                    child: Stack(
                      children: [
                        UserProfilePhoto(
                          photoUrl: _photoUrl != null && _photoUrl!.startsWith('http')
                              ? _photoUrl
                              : (_photoUrl != null && _photoUrl!.isNotEmpty
                                  ? '${ApiService.publicBaseUrl}$_photoUrl'
                                  : UserSession.photoUrlNotifier.value.isNotEmpty
                                      ? UserSession.photoUrlNotifier.value
                                      : null),
                          photoPath: _localPhotoPath,
                          radius: 54,
                          fallbackName: fullName,
                          uid: UserSession.currentUid,
                          role: 'driver',
                        ),
                        Positioned(
                          bottom: 0,
                          right: 0,
                          child: Container(
                            width: 32,
                            height: 32,
                            decoration: const BoxDecoration(
                              color: _gold,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.camera_alt_rounded,
                              color: Colors.black,
                              size: 16,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 24),

                // ── First Name field (locked) ──
                _fieldLabel(
                  S.of(context).firstNameLabel,
                  S.of(context).locked,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(text: firstName),
                        enabled: false,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 15,
                        ),
                        decoration: _inputDec(Icons.person_outline_rounded),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _lockIcon(),
                  ],
                ),

                const SizedBox(height: 20),

                // ── Last Name field (locked) ──
                _fieldLabel(
                  S.of(context).lastNameLabel,
                  S.of(context).locked,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: TextEditingController(text: lastName),
                        enabled: false,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 15,
                        ),
                        decoration: _inputDec(Icons.person_outline_rounded),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _lockIcon(),
                  ],
                ),

                const SizedBox(height: 20),

                // ── Email field ──
                _fieldLabel(
                  S.of(context).emailLabel,
                  '$_emailChanges/3 ${S.of(context).changesUsed}',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _emailCtrl,
                        enabled: _emailChanges < 3,
                        keyboardType: TextInputType.emailAddress,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                        cursorColor: _gold,
                        decoration: _inputDec(Icons.email_outlined),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _saveBtn(_emailChanges < 3 ? _saveEmail : null),
                  ],
                ),

                const SizedBox(height: 20),

                // ── Phone field ──
                _fieldLabel(
                  S.of(context).phoneLabel,
                  '$_phoneChanges/3 ${S.of(context).changesUsed}',
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _phoneCtrl,
                        enabled: _phoneChanges < 3,
                        keyboardType: TextInputType.phone,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                        cursorColor: _gold,
                        decoration: _inputDec(Icons.phone_outlined),
                      ),
                    ),
                    const SizedBox(width: 10),
                    _saveBtn(_phoneChanges < 3 ? _savePhone : null),
                  ],
                ),


              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _fieldLabel(String label, String counter) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        Text(
          counter,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 11,
          ),
        ),
      ],
    );
  }

  InputDecoration _inputDec(IconData icon) {
    return InputDecoration(
      prefixIcon: Icon(icon, color: _gold, size: 20),
      filled: true,
      fillColor: Colors.white.withValues(alpha: 0.06),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: const BorderSide(color: _gold, width: 1.2),
      ),
      disabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(14),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.04)),
      ),
      contentPadding: const EdgeInsets.symmetric(vertical: 14),
    );
  }

  Widget _lockIcon() {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(
        Icons.lock_rounded,
        color: Colors.white.withValues(alpha: 0.25),
        size: 20,
      ),
    );
  }

  Widget _saveBtn(VoidCallback? onTap) {
    return GestureDetector(
      onTap: _saving ? null : onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: onTap != null ? _gold : Colors.white12,
          borderRadius: BorderRadius.circular(12),
        ),
        child: _saving
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.black,
                ),
              )
            : Icon(
                Icons.check_rounded,
                color: onTap != null ? Colors.black : Colors.white24,
                size: 22,
              ),
      ),
    );
  }

  void _snack(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}
