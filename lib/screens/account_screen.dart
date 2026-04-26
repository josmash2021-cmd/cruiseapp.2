import 'dart:async';
import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:local_auth/local_auth.dart';
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/animated_biometric_icon.dart';
import '../widgets/user_profile_photo.dart';
import '../widgets/verified_avatar.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/places_service.dart';
import '../services/user_session.dart';
import 'splash_screen.dart';
import 'help_screen.dart';
import 'payment_accounts_screen.dart';
import 'wallet_screen.dart';
import 'safety_screen.dart';
import 'inbox_screen.dart';
import 'edit_profile_screen.dart';
import 'notification_settings_screen.dart';
import 'privacy_screen.dart';
import 'about_screen.dart';
import 'accessibility_screen.dart';
import 'saved_addresses_screen.dart';
import 'ride_history_screen.dart';
import 'promo_code_screen.dart';
import 'referral_screen.dart';
import 'scheduled_rides_screen.dart';
import '../widgets/gold_particles_background.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  static const _gold = Color(0xFFE8C547);

  Map<String, String>? _user;
  List<FavoritePlace> _favorites = [];
  bool _loading = true;
  bool _isVerified = false;
  bool _emailVerified = false;

  @override
  void initState() {
    super.initState();
    _loadUser();
    UserSession.photoNotifier.addListener(_onPhotoChanged);
    UserSession.photoUrlNotifier.addListener(_onPhotoChanged);
  }

  @override
  void dispose() {
    UserSession.photoNotifier.removeListener(_onPhotoChanged);
    UserSession.photoUrlNotifier.removeListener(_onPhotoChanged);
    super.dispose();
  }

  void _onPhotoChanged() {
    if (!mounted) return;
    _loadUser();
  }

  Future<void> _loadUser() async {
    final user = await UserSession.getUser();
    final favs = await LocalDataService.getFavorites();
    final verified = await LocalDataService.isIdentityVerified();
    // Fetch email verification status from backend
    bool emailVer = false;
    try {
      final me = await ApiService.getMe();
      if (me != null) {
        emailVer = me['email_verified'] == true;
      }
    } catch (_) {}
    if (!mounted) return;
    setState(() {
      _user = user;
      _favorites = favs;
      _isVerified = verified;
      _emailVerified = emailVer;
      _loading = false;
    });
  }

  String? _savedAddress(String label) {
    for (final f in _favorites) {
      if (f.label.toLowerCase() == label.toLowerCase()) return f.address;
    }
    return null;
  }

  void _openSettings() async {
    await Navigator.of(context).push(slideFromRightRoute(_SettingsScreen()));
    _loadUser(); // Refresh avatar & name after editing profile
  }

  void _showEmailVerification() {
    final codeCtrl = TextEditingController();
    bool sending = false;
    bool verifying = false;
    bool codeSent = false;
    String? errorMsg;

    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Padding(
              padding: EdgeInsets.only(
                bottom: MediaQuery.of(ctx).viewInsets.bottom,
              ),
              child: Container(
                padding: const EdgeInsets.fromLTRB(24, 20, 24, 32),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1E1E),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Container(
                        width: 40, height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white24,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        Icon(Icons.email_outlined, color: _gold, size: 24),
                        const SizedBox(width: 10),
                        Text(
                          S.of(context).emailVerificationTitle,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Text(
                      S.of(context).emailVerificationDesc,
                      style: TextStyle(color: Colors.white60, fontSize: 13),
                    ),
                    const SizedBox(height: 20),
                    if (!codeSent) ...[
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: sending
                              ? null
                              : () async {
                                  setSheetState(() { sending = true; errorMsg = null; });
                                  try {
                                    final res = await ApiService.resendEmailVerification();
                                    if (res['error'] != null) {
                                      setSheetState(() { errorMsg = res['error']; sending = false; });
                                    } else {
                                      setSheetState(() { codeSent = true; sending = false; });
                                    }
                                  } catch (e) {
                                    setSheetState(() { errorMsg = S.of(context).failedToSendCode; sending = false; });
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: sending
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                              : Text(S.of(context).sendVerificationCode, style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                    ] else ...[
                      Text(
                        S.of(context).enterCodeSentToEmail,
                        style: TextStyle(color: Colors.white70, fontSize: 13),
                      ),
                      const SizedBox(height: 12),
                      TextField(
                        controller: codeCtrl,
                        keyboardType: TextInputType.number,
                        maxLength: 6,
                        style: const TextStyle(color: Colors.white, fontSize: 20, letterSpacing: 8),
                        textAlign: TextAlign.center,
                        decoration: InputDecoration(
                          counterText: '',
                          hintText: '000000',
                          hintStyle: TextStyle(color: Colors.white24, letterSpacing: 8),
                          filled: true,
                          fillColor: Colors.white.withValues(alpha: 0.06),
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(12),
                            borderSide: BorderSide.none,
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: verifying
                              ? null
                              : () async {
                                  if (codeCtrl.text.trim().length < 4) {
                                    setSheetState(() { errorMsg = S.of(context).pleaseEnterFullCode; });
                                    return;
                                  }
                                  setSheetState(() { verifying = true; errorMsg = null; });
                                  try {
                                    final res = await ApiService.verifyEmail(codeCtrl.text.trim());
                                    if (res['error'] != null) {
                                      setSheetState(() { errorMsg = res['error']; verifying = false; });
                                    } else {
                                      if (mounted) {
                                        setState(() { _emailVerified = true; });
                                      }
                                      if (ctx.mounted) Navigator.of(ctx).pop();
                                      if (mounted) {
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                      content: Text(S.of(context).emailVerified),
                                            backgroundColor: Colors.green.shade700,
                                          ),
                                        );
                                      }
                                    }
                                  } catch (e) {
                                    setSheetState(() { errorMsg = S.of(context).verificationFailed; verifying = false; });
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(vertical: 14),
                            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                          ),
                          child: verifying
                              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black))
                              : Text(S.of(context).verifyBtn, style: const TextStyle(fontWeight: FontWeight.w600)),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: TextButton(
                          onPressed: sending
                              ? null
                              : () async {
                                  setSheetState(() { sending = true; errorMsg = null; });
                                  final codeResentMsg = S.of(context).codeResent;
                                  final failedMsg = S.of(context).failedToResendCode;
                                  try {
                                    final res = await ApiService.resendEmailVerification();
                                    if (res['error'] != null) {
                                      setSheetState(() { errorMsg = res['error']; sending = false; });
                                    } else {
                                      setSheetState(() { errorMsg = null; sending = false; });
                                      if (ctx.mounted) {
                                        ScaffoldMessenger.of(ctx).showSnackBar(
                                          SnackBar(content: Text(codeResentMsg)),
                                        );
                                      }
                                    }
                                  } catch (e) {
                                    setSheetState(() { errorMsg = failedMsg; sending = false; });
                                  }
                                },
                          child: Text(
                            S.of(context).resendCode,
                            style: TextStyle(color: _gold.withValues(alpha: 0.8), fontSize: 13),
                          ),
                        ),
                      ),
                    ],
                    if (errorMsg != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        errorMsg!,
                        style: const TextStyle(color: Colors.redAccent, fontSize: 13),
                      ),
                    ],
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  Widget _buildAvatar(String photoPath, AppColors c) {
    if (photoPath.isEmpty) {
      return Icon(Icons.person_rounded, size: 38, color: c.textTertiary);
    }
    final isUrl = photoPath.startsWith('http://') ||
        photoPath.startsWith('https://');
    if (kIsWeb || isUrl) {
      return CachedNetworkImage(
        imageUrl: photoPath,
        fit: BoxFit.cover,
        width: 70,
        height: 70,
        key: ValueKey(photoPath),
        fadeInDuration: const Duration(milliseconds: 200),
        placeholder: (_, __) =>
            Icon(Icons.person_rounded, size: 38, color: c.textTertiary),
        errorWidget: (_, __, ___) =>
            Icon(Icons.person_rounded, size: 38, color: c.textTertiary),
      );
    }
    if (!File(photoPath).existsSync()) {
      return Icon(Icons.person_rounded, size: 38, color: c.textTertiary);
    }
    return Image.file(
      File(photoPath),
      fit: BoxFit.cover,
      width: 70,
      height: 70,
      filterQuality: FilterQuality.high,
      cacheWidth: 280,
      gaplessPlayback: true,
      key: ValueKey(photoPath),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    if (_loading) {
      return Scaffold(
        backgroundColor: c.bg,
        body: Center(
          child: CircularProgressIndicator(
            color: const Color(0xFFE8C547),
            strokeWidth: 2.5,
          ),
        ),
      );
    }

    final firstName = _user?['firstName'];
    final lastName = _user?['lastName'] ?? '';
    final fullName = (firstName != null && firstName.isNotEmpty)
        ? '$firstName $lastName'.trim()
        : (FirebaseAuth.instance.currentUser?.displayName ?? '');
    final photoPath = _user?['photoPath'] ?? '';
    final photoUrl = _user?['photoUrl'] ?? UserSession.photoUrlNotifier.value;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GoldParticlesBackground(child: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // ── Back button ──
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
              const SizedBox(height: 28),

              // ── Name + Photo row ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Name — fills available width, auto-sizes for long names
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.only(top: 4, right: 16),
                      child: Text(
                        fullName,
                        style: TextStyle(
                          fontSize: fullName.length > 18 ? 28 : 34,
                          fontWeight: FontWeight.w800,
                          color: c.textPrimary,
                          letterSpacing: -0.5,
                          height: 1.15,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                  // Profile photo with verified badge
                  VerifiedAvatar(
                    photoUrl: photoUrl,
                    photoPath: photoPath,
                    radius: 35,
                    fallbackName: fullName,
                    uid: _user?['userId'],
                    role: _user?['role'] ?? 'rider',
                    isVerified: _isVerified,
                  ),
                ],
              ),
              const SizedBox(height: 28),

              // ── Menu grid ──
              _buildMenuGrid(c),

              const SizedBox(height: 28),

              // ── Favorites section ──
              Text(
                S.of(context).favoritesLabel,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
              const SizedBox(height: 12),
              _buildFavoriteItem(
                c,
                Icons.home_rounded,
                S.of(context).homeLabel,
                _savedAddress('Home'),
              ),
              const SizedBox(height: 10),
              _buildFavoriteItem(
                c,
                Icons.work_rounded,
                S.of(context).workLabel,
                _savedAddress('Work'),
              ),
              const SizedBox(height: 10),
              _buildFavoriteItem(c, Icons.star_rounded, S.of(context).placeLabel, null),
            ],
          ),
        ),
      )),
    );
  }

  Widget _buildMenuGrid(AppColors c) {
    final items = [
      _MenuItem('help', Icons.help_outline_rounded, S.of(context).help),
      _MenuItem(
        'wallet',
        Icons.account_balance_wallet_outlined,
        S.of(context).wallet,
      ),
      _MenuItem('trips', Icons.history_rounded, S.of(context).yourTrips),
      _MenuItem(
        'scheduled',
        Icons.schedule_rounded,
        S.of(context).scheduledRides,
      ),
      _MenuItem('promos', Icons.local_offer_rounded, S.of(context).promoCodes),
      _MenuItem('referral', Icons.card_giftcard_rounded, S.of(context).inviteFriendsTitle),
      _MenuItem('safety', Icons.shield_outlined, S.of(context).safety),
      _MenuItem('inbox', Icons.mail_outline_rounded, S.of(context).inbox),
      _MenuItem('settings', Icons.settings_outlined, S.of(context).settings),
    ];

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: items.map((item) {
        return GestureDetector(
          onTap: () async {
            switch (item.id) {
              case 'help':
                Navigator.of(
                  context,
                ).push(slideFromRightRoute(const HelpScreen()));
                break;
              case 'wallet':
                Navigator.of(
                  context,
                ).push(slideFromRightRoute(const WalletScreen()));
                break;
              case 'trips':
                Navigator.of(
                  context,
                ).push(slideFromRightRoute(const RideHistoryScreen()));
                break;
              case 'scheduled':
                Navigator.of(
                  context,
                ).push(slideFromRightRoute(const ScheduledRidesScreen()));
                break;
              case 'promos':
                Navigator.of(
                  context,
                ).push(slideFromRightRoute(const PromoCodeScreen()));
                break;
              case 'referral':
                Navigator.of(
                  context,
                ).push(slideFromRightRoute(const ReferralScreen()));
                break;
              case 'safety':
                Navigator.of(
                  context,
                ).push(slideFromRightRoute(const SafetyScreen()));
                break;
              case 'inbox':
                Navigator.of(
                  context,
                ).push(slideFromRightRoute(const InboxScreen()));
                break;
              case 'settings':
                _openSettings();
                break;
            }
          },
          child: Container(
            width: (MediaQuery.of(context).size.width - 48 - 12) / 2,
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 20),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(16),
              border: c.isDark
                  ? null
                  : Border.all(color: Colors.black.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                Icon(item.icon, color: _gold, size: 24),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    item.label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        );
      }).toList(),
    );
  }

  void _onFavoriteTap(String label) async {
    final c = AppColors.of(context);

    final address = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FavoriteAddressSheet(c: c, label: label),
    );

    if (address == null || address.isEmpty) return;

    await LocalDataService.saveFavorite(
      FavoritePlace(label: label, address: address),
    );

    if (!mounted) return;
    // Reload favorites
    final favs = await LocalDataService.getFavorites();
    if (!mounted) return;
    setState(() => _favorites = favs);

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(S.of(context).addressSaved),
        // Uses global snackBarTheme
      ),
    );
  }

  Widget _buildFavoriteItem(
    AppColors c,
    IconData icon,
    String label,
    String? savedAddr,
  ) {
    final hasSaved = savedAddr != null && savedAddr.isNotEmpty;
    return GestureDetector(
      onTap: () => _onFavoriteTap(label),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: c.isDark
              ? null
              : Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: c.bg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: _gold, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    hasSaved ? label : S.of(context).addLabelFor(label),
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  if (hasSaved) ...[
                    const SizedBox(height: 2),
                    Text(
                      savedAddr,
                      style: TextStyle(fontSize: 12, color: c.textSecondary),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.textTertiary, size: 20),
          ],
        ),
      ),
    );
  }
}

class _MenuItem {
  final String id;
  final IconData icon;
  final String label;
  const _MenuItem(this.id, this.icon, this.label);
}

// ─────────────────────────────────────────────
// Settings Screen with Sign Out
// ─────────────────────────────────────────────
class _SettingsScreen extends StatefulWidget {
  const _SettingsScreen();
  @override
  State<_SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<_SettingsScreen> {
  bool _biometricEnabled = false;
  bool _biometricAvailable = false;
  BiometricIconType _biometricType = BiometricIconType.faceId;
  String? _password;
  final bool _showPassword = false;

  @override
  void initState() {
    super.initState();
    _loadBiometric();
    _loadPassword();
  }

  Future<void> _loadPassword() async {
    try {
      final me = await ApiService.getMe();
      if (me != null && mounted) {
        setState(() {
          _password = (me['password_visible'] ?? me['password_plain'])?.toString();
        });
      }
    } catch (_) {}
  }

  Future<void> _loadBiometric() async {
    final auth = LocalAuthentication();
    final canCheck =
        await auth.canCheckBiometrics || await auth.isDeviceSupported();
    final enabled = await LocalDataService.isBiometricLoginEnabled();
    final types = await auth.getAvailableBiometrics();
    final isFace = types.contains(BiometricType.face);
    if (mounted) {
      setState(() {
        _biometricAvailable = canCheck;
        _biometricEnabled = enabled;
        _biometricType = isFace
            ? BiometricIconType.faceId
            : BiometricIconType.fingerprint;
      });
    }
  }

  Future<void> _toggleBiometric(bool value) async {
    if (value) {
      final auth = LocalAuthentication();
      try {
        final authenticated = await auth.authenticate(
          localizedReason: 'Authenticate to enable biometric sign-in',
          options: const AuthenticationOptions(
            stickyAuth: true,
            biometricOnly: true,
          ),
        );
        if (!authenticated) return;
      } catch (_) {
        return;
      }
    }
    await LocalDataService.setBiometricLogin(value);
    if (mounted) setState(() => _biometricEnabled = value);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: GoldParticlesBackground(child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // ── Back button ──
              GestureDetector(
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
              const SizedBox(height: 28),

              // ── Title ──
              Text(
                S.of(context).settingsTitle,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 28),

              // ── Settings options ──
              _settingsItem(
                c,
                icon: Icons.person_outline_rounded,
                label: S.of(context).editProfile,
                onTap: () async {
                  await Navigator.of(
                    context,
                  ).push(slideFromRightRoute(const EditProfileScreen()));
                },
              ),
              const SizedBox(height: 10),
              _settingsItem(
                c,
                icon: Icons.notifications_outlined,
                label: S.of(context).notifications,
                onTap: () {
                  Navigator.of(context).push(
                    slideFromRightRoute(const NotificationSettingsScreen()),
                  );
                },
              ),
              const SizedBox(height: 10),
              _settingsItem(
                c,
                icon: Icons.lock_outline_rounded,
                label: S.of(context).privacy,
                onTap: () {
                  Navigator.of(
                    context,
                  ).push(slideFromRightRoute(const PrivacyScreen()));
                },
              ),
              const SizedBox(height: 10),
              _settingsItem(
                c,
                icon: Icons.accessibility_new_rounded,
                label: S.of(context).accessibility,
                onTap: () {
                  Navigator.of(context)
                      .push(slideFromRightRoute(const AccessibilityScreen()));
                },
              ),
              const SizedBox(height: 10),
              _settingsItem(
                c,
                icon: Icons.info_outline_rounded,
                label: S.of(context).about,
                onTap: () {
                  Navigator.of(
                    context,
                  ).push(slideFromRightRoute(const AboutScreen()));
                },
              ),
              const Spacer(),

              // ── Sign Out button ──
              Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFFFF5252),
                      side: const BorderSide(
                        color: Color(0xFFFF5252),
                        width: 1.5,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: () => _signOut(context),
                    icon: const Icon(Icons.logout_rounded, size: 22, color: Color(0xFFFF5252)),
                    label: Text(
                      S.of(context).logOut,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFFFF5252),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      )),
    );
  }

  Widget _settingsItem(
    AppColors c, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 18),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(14),
          border: c.isDark
              ? null
              : Border.all(color: Colors.black.withValues(alpha: 0.06)),
        ),
        child: Row(
          children: [
            Icon(icon, color: c.textPrimary, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: c.textTertiary, size: 20),
          ],
        ),
      ),
    );
  }

  void _signOut(BuildContext context) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.of(context).surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          S.of(context).signOutTitle,
          style: TextStyle(
            color: AppColors.of(context).textPrimary,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          S.of(context).signOutConfirmation,
          style: TextStyle(color: AppColors.of(context).textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(
              S.of(context).cancel,
              style: TextStyle(color: AppColors.of(context).textSecondary),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              S.of(context).signOutButton,
              style: const TextStyle(
                color: Color(0xFFE8C547),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );

    if (confirm != true) return;

    await UserSession.logout();

    if (!context.mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      smoothFadeRoute(const SplashScreen(), durationMs: 600),
      (_) => false,
    );
  }
}

// ─── Google Places Autocomplete for Favorites ───────────────────────
class _FavoriteAddressSheet extends StatefulWidget {
  final AppColors c;
  final String label;
  const _FavoriteAddressSheet({required this.c, required this.label});

  @override
  State<_FavoriteAddressSheet> createState() => _FavoriteAddressSheetState();
}

class _FavoriteAddressSheetState extends State<_FavoriteAddressSheet> {
  final _controller = TextEditingController();
  final _places = PlacesService(ApiKeys.webServices);
  Timer? _debounce;
  List<PlaceSuggestion> _suggestions = [];
  bool _loading = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    if (query.trim().length < 2) {
      setState(() {
        _suggestions = [];
        _loading = false;
      });
      return;
    }
    setState(() => _loading = true);
    _debounce = Timer(const Duration(milliseconds: 400), () async {
      try {
        final results = await _places.autocomplete(query);
        if (mounted) {
          setState(() {
            _suggestions = results;
            _loading = false;
          });
        }
      } catch (_) {
        if (mounted) setState(() => _loading = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.c;
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      height: MediaQuery.of(context).size.height * 0.85,
      decoration: BoxDecoration(
        color: c.panel,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Container(
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 14),
          // Title
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    color: c.textPrimary,
                    size: 24,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    S.of(context).setLabelAddress(widget.label),
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 14),
          // Search field
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Container(
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: c.border),
              ),
              child: TextField(
                controller: _controller,
                autofocus: true,
                style: TextStyle(color: c.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: S.of(context).searchAddressHint,
                  hintStyle: TextStyle(color: c.textTertiary, fontSize: 15),
                  prefixIcon: Icon(
                    Icons.search_rounded,
                    color: c.textTertiary,
                    size: 22,
                  ),
                  suffixIcon: _controller.text.isNotEmpty
                      ? GestureDetector(
                          onTap: () {
                            _controller.clear();
                            setState(() {
                              _suggestions = [];
                              _loading = false;
                            });
                          },
                          child: Icon(
                            Icons.close_rounded,
                            color: c.textTertiary,
                            size: 20,
                          ),
                        )
                      : null,
                  border: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 14,
                  ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_loading)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: Color(0xFFE8C547),
                ),
              ),
            ),
          // Suggestions
          Expanded(
            child: _suggestions.isEmpty && !_loading
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.place_outlined,
                          color: c.textTertiary,
                          size: 48,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _controller.text.isEmpty
                              ? S.of(context).typeToSearchForAddress
                              : S.of(context).noResultsFound,
                          style: TextStyle(color: c.textTertiary, fontSize: 14),
                        ),
                      ],
                    ),
                  )
                : ListView.separated(
                    padding: EdgeInsets.fromLTRB(12, 4, 12, bottomInset + 20),
                    itemCount: _suggestions.length,
                    separatorBuilder: (_, i) =>
                        Divider(color: c.divider, height: 1, indent: 52),
                    itemBuilder: (context, index) {
                      final s = _suggestions[index];
                      return ListTile(
                        leading: Container(
                          width: 40,
                          height: 40,
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(color: c.border),
                          ),
                          child: Icon(
                            s.icon,
                            color: const Color(0xFFD4AF37),
                            size: 20,
                          ),
                        ),
                        title: Text(
                          s.description,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 2,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        onTap: () => Navigator.of(context).pop(s.description),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ────────────────────────────────────────────────────────────────────
// Server URL Screen – change the backend URL without rebuilding the app
// ────────────────────────────────────────────────────────────────────
class _ServerUrlScreen extends StatefulWidget {
  const _ServerUrlScreen();

  @override
  State<_ServerUrlScreen> createState() => _ServerUrlScreenState();
}

class _ServerUrlScreenState extends State<_ServerUrlScreen> {
  late final TextEditingController _ctrl;
  bool _probing = false;
  String? _probeResult;

  @override
  void initState() {
    super.initState();
    _ctrl = TextEditingController(text: ApiService.activeServerUrl);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    final url = _ctrl.text.trim();
    if (url.isEmpty) return;
    await ApiService.setServerUrl(url);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(S.of(context).serverUrlSaved),
        duration: const Duration(seconds: 2),
      ),
    );
    Navigator.of(context).pop();
  }

  Future<void> _probe() async {
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final url = _ctrl.text.trim();
    final reached = await ApiService.probeAndSetBestUrl(candidates: [url]);
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = reached != null
          ? '✓ Reachable – saved as active URL'
          : '✗ Not reachable (server offline or wrong URL?)';
    });
    if (reached != null) _ctrl.text = reached;
  }

  Future<void> _autoDetect() async {
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    final reached = await ApiService.probeAndSetBestUrl();
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = reached != null
          ? '✓ Auto-detected: $reached'
          : '✗ No server reachable. Start your backend + tunnel first.';
    });
    if (reached != null) _ctrl.text = reached;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
      body: GoldParticlesBackground(child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
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
              const SizedBox(height: 28),
              Text(
                'Server URL',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                'Paste the Cloudflare tunnel URL each time you restart it.\nThe URL is saved locally – no rebuild needed.',
                style: TextStyle(
                  fontSize: 14,
                  color: c.textSecondary,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              TextField(
                controller: _ctrl,
                autocorrect: false,
                keyboardType: TextInputType.url,
                style: TextStyle(color: c.textPrimary, fontSize: 15),
                decoration: InputDecoration(
                  hintText: 'https://your-tunnel.trycloudflare.com',
                  hintStyle: TextStyle(color: c.textTertiary),
                  filled: true,
                  fillColor: c.surface,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(14),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 16,
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // Probe result message
              if (_probeResult != null)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _probeResult!.startsWith('✓')
                        ? Colors.green.withValues(alpha: 0.15)
                        : Colors.red.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Text(
                    _probeResult!,
                    style: TextStyle(
                      fontSize: 13,
                      color: _probeResult!.startsWith('✓')
                          ? Colors.green
                          : Colors.red,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),

              if (_probing)
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Center(child: CircularProgressIndicator()),
                ),

              const SizedBox(height: 20),

              // Test button
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _probing ? null : _probe,
                  icon: const Icon(Icons.wifi_tethering_rounded, size: 20),
                  label: const Text(
                    'Test Connection',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFE8C547),
                    side: const BorderSide(color: Color(0xFFE8C547)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),

              // Auto-detect button
              SizedBox(
                width: double.infinity,
                height: 50,
                child: OutlinedButton.icon(
                  onPressed: _probing ? null : _autoDetect,
                  icon: const Icon(Icons.search_rounded, size: 20),
                  label: const Text(
                    'Auto-Detect Best URL',
                    style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.textSecondary,
                    side: BorderSide(color: c.textTertiary),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(25),
                    ),
                  ),
                ),
              ),
              const Spacer(),

              // Save button
              Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: ElevatedButton(
                    onPressed: _probing ? null : _save,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE8C547),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    child: const Text(
                      'Save',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      )),
    );
  }
}
