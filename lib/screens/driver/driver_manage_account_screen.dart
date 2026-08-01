import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../services/user_session.dart';
import '../../utils/phone_format.dart';
import '../../widgets/neu_style.dart';
import '../../widgets/user_profile_photo.dart';
import 'driver_reset_password_screen.dart';

/// Driver Manage Account page — edit photo, email, phone, password.
class DriverManageAccountScreen extends StatefulWidget {
  const DriverManageAccountScreen({super.key});

  @override
  State<DriverManageAccountScreen> createState() =>
      _DriverManageAccountScreenState();
}

class _DriverManageAccountScreenState extends State<DriverManageAccountScreen> {
  static const _gold = Color(0xFFE8C547);

  Map<String, dynamic>? _user;
  bool _loading = true;
  bool _saving = false;
  String? _photoUrl;
  String? _localPhotoPath;

  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  int _emailChanges = 0;
  int _phoneChanges = 0;

  /// What was on the server when the screen opened. Save compares against
  /// these rather than against the controllers' initial text, so a field
  /// edited and then typed back to its original value stops counting as a
  /// change and does not burn one of the three allowed.
  String _savedEmail = '';
  String _savedPhone = '';

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
        _savedEmail = user?['email'] as String? ?? '';
        _savedPhone = user?['phone'] as String? ?? '';
        _emailCtrl.text = _savedEmail;
        _phoneCtrl.text = formatUsPhone(_savedPhone);
        _emailChanges = (user?['email_changes_count'] as int?) ?? 0;
        _phoneChanges = (user?['phone_changes_count'] as int?) ?? 0;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
    }
  }

  // ── What Save would send ────────────────────────────────────────────
  //
  // Both getters return null when there is nothing to do, which is also
  // what decides whether the Save bar is on screen at all.

  String? get _pendingEmail {
    final v = _emailCtrl.text.trim();
    if (v.isEmpty || v == _savedEmail) return null;
    return v;
  }

  String? get _pendingPhone {
    // The field holds "+1 (385) 461-2042"; the server wants "+13854612042".
    // An incomplete number converts to empty, which is the same as no
    // change — half a phone number must never be saved.
    final v = usPhoneToE164(_phoneCtrl.text);
    if (v.isEmpty || v == _savedPhone) return null;
    return v;
  }

  bool get _hasChanges => _pendingEmail != null || _pendingPhone != null;

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
      // ApiService.uploadPhoto already handles Firebase Storage + Firestore
      // sync, so just update local state — no need to re-upload.
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
      final freshUrl =
          url.contains('?') ? '$url&cb=$cacheBust' : '$url?cb=$cacheBust';
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

  /// Save both fields in whatever combination changed.
  ///
  /// They go one at a time because each has its own three-change budget
  /// and its own server-side rejection: an email already in use must not
  /// take the phone number down with it. Whatever succeeded is kept, and
  /// only the field that failed keeps its edit.
  Future<void> _save() async {
    final email = _pendingEmail;
    final phone = _pendingPhone;
    if (email == null && phone == null) return;

    if (email != null && _emailChanges >= 3) {
      _snack(S.of(context).maxChangesReached);
      return;
    }
    if (phone != null && _phoneChanges >= 3) {
      _snack(S.of(context).maxChangesReached);
      return;
    }

    HapticService.selectionClick();
    setState(() => _saving = true);
    final failures = <String>[];

    if (email != null) {
      try {
        await ApiService.updateMe({'email': email});
        if (!mounted) return;
        setState(() {
          _savedEmail = email;
          _emailChanges++;
        });
      } on ApiException catch (e) {
        failures.add(e.message);
      } catch (_) {
        if (!mounted) return;
        failures.add(S.of(context).errorOccurred);
      }
    }

    if (phone != null) {
      try {
        await ApiService.updateMe({'phone': phone});
        if (!mounted) return;
        setState(() {
          _savedPhone = phone;
          _phoneCtrl.text = formatUsPhone(phone);
          _phoneChanges++;
        });
      } on ApiException catch (e) {
        failures.add(e.message);
      } catch (_) {
        if (!mounted) return;
        failures.add(S.of(context).errorOccurred);
      }
    }

    if (!mounted) return;
    setState(() => _saving = false);
    _snack(failures.isEmpty ? S.of(context).changesSaved : failures.first);
  }

  Future<void> _openPasswordReset() async {
    HapticService.selectionClick();
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const DriverResetPasswordScreen()),
    );
    if (changed == true && mounted) _snack(S.of(context).passwordChanged);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final top = MediaQuery.of(context).padding.top;

    if (_loading) {
      return const Scaffold(
        backgroundColor: neuBase,
        body: Center(child: CircularProgressIndicator(color: _gold)),
      );
    }

    final firstName = _user?['first_name'] as String? ?? '';
    final lastName = _user?['last_name'] as String? ?? '';
    final fullName = '$firstName $lastName'.trim();

    return Scaffold(
      backgroundColor: neuBase,
      body: Column(
        children: [
          // ── Top bar ──
          Padding(
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
                    decoration: neuBox(radius: 20),
                    child: const Icon(
                      Icons.arrow_back_rounded,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
                const SizedBox(width: 14),
                Text(
                  s.manageAccount,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: ListView(
              physics: const BouncingScrollPhysics(),
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 24),
              children: [
                // ── Profile photo ──
                Center(
                  child: GestureDetector(
                    onTap: _saving ? null : _pickPhoto,
                    child: Stack(
                      children: [
                        UserProfilePhoto(
                          photoUrl:
                              _photoUrl != null && _photoUrl!.startsWith('http')
                                  ? _photoUrl
                                  : (_photoUrl != null && _photoUrl!.isNotEmpty
                                      ? '${ApiService.publicBaseUrl}$_photoUrl'
                                      : UserSession
                                              .photoUrlNotifier.value.isNotEmpty
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

                const SizedBox(height: 26),

                // ── Locked identity ──
                _fieldLabel(s.firstNameLabel, s.locked),
                const SizedBox(height: 8),
                _lockedField(Icons.person_outline_rounded, firstName),

                const SizedBox(height: 18),

                _fieldLabel(s.lastNameLabel, s.locked),
                const SizedBox(height: 8),
                _lockedField(Icons.person_outline_rounded, lastName),

                const SizedBox(height: 18),

                // ── Email ──
                _fieldLabel(
                  s.emailLabel,
                  '$_emailChanges/3 ${s.changesUsed}',
                ),
                const SizedBox(height: 8),
                _editableField(
                  icon: Icons.email_outlined,
                  controller: _emailCtrl,
                  enabled: _emailChanges < 3,
                  keyboardType: TextInputType.emailAddress,
                ),

                const SizedBox(height: 18),

                // ── Phone ──
                _fieldLabel(
                  s.phoneLabel,
                  '$_phoneChanges/3 ${s.changesUsed}',
                ),
                const SizedBox(height: 8),
                _editableField(
                  icon: Icons.phone_outlined,
                  controller: _phoneCtrl,
                  enabled: _phoneChanges < 3,
                  keyboardType: TextInputType.phone,
                  formatters: const [UsPhoneFormatter()],
                ),

                const SizedBox(height: 26),

                // ── Password ──
                // Not a field. There is nothing to show and nothing to
                // type here; the whole change happens behind an emailed
                // code, so this is a door, not an input.
                GestureDetector(
                  onTap: _saving ? null : _openPasswordReset,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 16,
                    ),
                    decoration: neuBox(radius: 16),
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
                            s.forgotPassword,
                            style: const TextStyle(
                              color: Colors.white,
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
              ],
            ),
          ),

          // ── Save ──
          // Only here once something differs from what the server holds,
          // so its presence is the answer to "did I change anything?"
          AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            child: _hasChanges
                ? _saveBar(s)
                : const SizedBox(width: double.infinity),
          ),
        ],
      ),
    );
  }

  Widget _saveBar(S s) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        20,
        14,
        20,
        14 + MediaQuery.of(context).padding.bottom,
      ),
      decoration: BoxDecoration(
        color: neuBase,
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      child: GestureDetector(
        onTap: _saving ? null : _save,
        child: Container(
          height: 54,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _gold,
            borderRadius: BorderRadius.circular(16),
            boxShadow: [
              BoxShadow(
                color: _gold.withValues(alpha: 0.22),
                blurRadius: 18,
                offset: const Offset(0, 6),
              ),
            ],
          ),
          child: _saving
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    strokeWidth: 2.2,
                    color: Colors.black,
                  ),
                )
              : Text(
                  s.save,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                  ),
                ),
        ),
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

  /// A field that cannot be edited, shown as a sunken well with the lock
  /// inside it — no separate lock button beside the row to explain it.
  Widget _lockedField(IconData icon, String value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      height: 54,
      decoration: neuBox(radius: 16, pressed: true),
      child: Row(
        children: [
          Icon(icon, color: _gold.withValues(alpha: 0.45), size: 19),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              value,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 15,
              ),
            ),
          ),
          Icon(
            Icons.lock_rounded,
            color: Colors.white.withValues(alpha: 0.22),
            size: 17,
          ),
        ],
      ),
    );
  }

  Widget _editableField({
    required IconData icon,
    required TextEditingController controller,
    required bool enabled,
    required TextInputType keyboardType,
    List<TextInputFormatter>? formatters,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: neuBox(radius: 16, pressed: true),
      child: Row(
        children: [
          Icon(
            icon,
            color: enabled ? _gold : _gold.withValues(alpha: 0.4),
            size: 19,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              enabled: enabled,
              keyboardType: keyboardType,
              inputFormatters: formatters,
              // The Save bar appears and disappears on what is typed, so
              // every keystroke has to reach build().
              onChanged: (_) => setState(() {}),
              style: TextStyle(
                color: enabled
                    ? Colors.white
                    : Colors.white.withValues(alpha: 0.4),
                fontSize: 15,
              ),
              cursorColor: _gold,
              decoration: const InputDecoration(
                border: InputBorder.none,
                contentPadding: EdgeInsets.symmetric(vertical: 17),
              ),
            ),
          ),
          if (!enabled)
            Icon(
              Icons.lock_rounded,
              color: Colors.white.withValues(alpha: 0.22),
              size: 17,
            ),
        ],
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
