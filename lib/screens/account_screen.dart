import 'dart:async';
import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:local_auth/local_auth.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../widgets/animated_biometric_icon.dart';
import '../widgets/neu_style.dart';
import '../widgets/user_profile_photo.dart';
import '../widgets/verified_avatar.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
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
import 'schedule_hub_screen.dart';

class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  static const _gold = Color(0xFFE8C547);

  Map<String, String>? _user;
  bool _loading = true;
  bool _isVerified = false;
  bool _emailVerified = false;

  /// What the drivers have scored this rider, and how many of them have.
  ///
  /// Null until /auth/me answers. A rider with no ratings yet is shown as new
  /// rather than as a perfect 5.0 — the column defaults to 5.0 in the
  /// database, so printing it unqualified would invent a reputation nobody
  /// earned.
  double? _rating;
  int _ratingsCount = 0;

  /// Whether /auth/me has answered. A null [_rating] means "nobody has rated
  /// you" once this is true, and "we have not asked yet" while it is false.
  bool _ratingLoaded = false;

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
    // Show cached data INSTANTLY (no waiting for backend)
    final user = await UserSession.getUser();
    final verified = await LocalDataService.isIdentityVerified();

    if (!mounted) return;
    setState(() {
      _user = user;
      _isVerified = verified;
      _loading = false;
    });
    
    // Refresh from backend in background (non-blocking)
    unawaited(_refreshFromBackend());
  }
  
  Future<void> _refreshFromBackend() async {
    try {
      final me = await ApiService.getMe().timeout(const Duration(seconds: 4));
      if (me != null && mounted) {
        setState(() {
          _emailVerified = me['email_verified'] == true;
          // Already in this response — /auth/me computes it alongside the
          // profile — and was being thrown away with the rest of the payload.
          _rating = (me['average_rating'] as num?)?.toDouble();
          _ratingsCount = (me['ratings_count'] as num?)?.toInt() ?? 0;
          _ratingLoaded = true;
        });
      }
    } catch (_) {
      // Silently ignore — cached data is still showing
    }
  }

  /// The score the drivers have given this rider, under their name.
  ///
  /// Three states, on purpose. Until /auth/me answers there is nothing to say,
  /// so the row holds its height rather than flashing a placeholder number
  /// that then changes — hence the separate _ratingLoaded flag: the backend
  /// returns a null score for "nobody has rated you", which is a different
  /// answer from "we have not asked yet" and must not render the same.
  ///
  /// With no ratings recorded it says "new rider". The database column
  /// defaults to 5.0, so printing the raw value would hand someone a perfect
  /// score they were never given. Only a real, counted average gets a star.
  Widget _buildRiderRating(AppColors c) {
    if (!_ratingLoaded) return const SizedBox(height: 18);
    final r = _rating;
    if (r == null || _ratingsCount <= 0) {
      return SizedBox(
        height: 18,
        child: Text(
          S.of(context).newRiderLabel,
          style: TextStyle(
            fontSize: 13.5,
            fontWeight: FontWeight.w600,
            color: c.textSecondary,
          ),
        ),
      );
    }
    return SizedBox(
      height: 18,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.star_rounded, size: 17, color: _gold),
          const SizedBox(width: 4),
          Text(
            // One decimal, because that is exactly what the backend sends:
            // _compute_user_rating already rounds to 1. Asking for two would
            // print a digit the server never computed.
            r.toStringAsFixed(1),
            style: TextStyle(
              fontSize: 14.5,
              fontWeight: FontWeight.w700,
              color: c.textPrimary,
            ),
          ),
        ],
      ),
    );
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
                                    final res = await ApiService.resendEmailVerification().timeout(const Duration(seconds: 15));
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
                                    final res = await ApiService.verifyEmail(codeCtrl.text.trim()).timeout(const Duration(seconds: 15));
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
                                    final res = await ApiService.resendEmailVerification().timeout(const Duration(seconds: 15));
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
    ).whenComplete(() => codeCtrl.dispose);
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
        backgroundColor: neuBase,
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

    return Scaffold(
      backgroundColor: neuBase,
      body: Stack(
        children: [
          // Same fine dot grid as home (user spec 2026-08-04).
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // ── Back button — pressed neumorphic circle ──
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: neuBox(radius: 14, pressed: true),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    color: c.textPrimary,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // ── Photo + Name row — avatar left, name centered beside it ──
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Profile photo with verified badge — fed live by the
                  // session notifiers (synchronous local state), so it
                  // paints on the first frame and updates the instant the
                  // photo changes, without a full _loadUser() round-trip.
                  ValueListenableBuilder<String>(
                    valueListenable: UserSession.photoNotifier,
                    builder: (context, localPath, _) {
                      return ValueListenableBuilder<String>(
                        valueListenable: UserSession.photoUrlNotifier,
                        builder: (context, remoteUrl, _) {
                          final path = localPath.isNotEmpty
                              ? localPath
                              : (_user?['photoPath'] ?? '');
                          final url = remoteUrl.isNotEmpty
                              ? remoteUrl
                              : (_user?['photoUrl'] ?? '');
                          // Local file wins when it exists (instant,
                          // gapless render); otherwise the remote URL
                          // renders from the shared photo cache.
                          final hasLocal = !kIsWeb &&
                              path.isNotEmpty &&
                              !path.startsWith('http') &&
                              File(path).existsSync();
                          return VerifiedAvatar(
                            photoUrl: hasLocal ? '' : url,
                            photoPath: path,
                            radius: 35,
                            fallbackName: fullName,
                            uid: _user?['userId'],
                            role: _user?['role'] ?? 'rider',
                            isVerified: _isVerified,
                            fadeInDuration: Duration.zero,
                          );
                        },
                      );
                    },
                  ),
                  const SizedBox(width: 18),
                  // Name — fills available width, auto-sizes for long names
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          fullName,
                          style: TextStyle(
                            fontSize: fullName.length > 18 ? 26 : 30,
                            fontWeight: FontWeight.w800,
                            color: c.textPrimary,
                            letterSpacing: -0.5,
                            height: 1.15,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 6),
                        _buildRiderRating(c),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 28),

              // ── Menu sections (grouped, neumorphic) ──
              _buildMenuSections(c),

              // ── Log Out — neumorphic surface, red accent ──
              GestureDetector(
                onTap: () => _confirmAndSignOut(context),
                child: Container(
                  width: double.infinity,
                  height: 56,
                  decoration: neuBox(radius: 18),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(
                        Icons.logout_rounded,
                        size: 22,
                        color: Color(0xFFFF5252),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        S.of(context).logOut,
                        style: const TextStyle(
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          color: Color(0xFFFF5252),
                        ),
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
    );
  }

  void _onMenuTap(String id) {
    switch (id) {
      case 'support':
        Navigator.of(context).push(
          slideFromRightRoute(const _SupportHubScreen()),
        );
        break;
      case 'wallet':
        Navigator.of(context).push(slideFromRightRoute(const WalletScreen()));
        break;
      case 'trips':
        Navigator.of(
          context,
        ).push(slideFromRightRoute(const RideHistoryScreen()));
        break;
      case 'scheduled':
        Navigator.of(
          context,
        ).push(slideFromRightRoute(const ScheduleHubScreen()));
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
      case 'inbox':
        Navigator.of(context).push(slideFromRightRoute(const InboxScreen()));
        break;
      case 'settings':
        _openSettings();
        break;
    }
  }

  Widget _buildMenuSections(AppColors c) {
    final s = S.of(context);
    final sections = [
      _MenuSection(s.accountSectionRides, [
        _MenuItem('trips', Icons.route_rounded, s.yourTrips),
        _MenuItem('scheduled', Icons.event_available_rounded, s.scheduledRides),
      ]),
      _MenuSection(s.accountSectionPayments, [
        _MenuItem('wallet', Icons.account_balance_wallet_rounded, s.wallet),
        _MenuItem('promos', Icons.percent_rounded, s.promoCodes),
        _MenuItem(
          'referral',
          Icons.person_add_alt_1_rounded,
          s.inviteFriendsTitle,
        ),
      ]),
      _MenuSection(s.accountSectionSupport, [
        _MenuItem('support', Icons.support_agent_rounded, s.helpAndSafety),
        _MenuItem('inbox', Icons.inbox_rounded, s.inbox),
      ]),
      _MenuSection(s.accountSectionAccount, [
        _MenuItem('settings', Icons.settings_rounded, s.settings),
      ]),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final section in sections) ...[
          // ── Section header ──
          Padding(
            padding: const EdgeInsets.only(left: 6, bottom: 10),
            child: Text(
              section.title.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2,
                color: c.textTertiary,
              ),
            ),
          ),
          // ── Raised neumorphic card holding the section rows ──
          Container(
            decoration: neuBox(radius: 20),
            child: Column(
              children: [
                for (var i = 0; i < section.items.length; i++) ...[
                  if (i > 0)
                    Divider(
                      height: 1,
                      indent: 68,
                      color: Colors.white.withValues(alpha: 0.05),
                    ),
                  _NeuMenuRow(
                    icon: section.items[i].icon,
                    label: section.items[i].label,
                    onTap: () => _onMenuTap(section.items[i].id),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 22),
        ],
      ],
    );
  }
}

/// Full-width neumorphic menu row: icon in a pressed well, label, chevron.
/// Shared by the account sections and the support hub.
class _NeuMenuRow extends StatelessWidget {
  static const _gold = Color(0xFFE8C547);

  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _NeuMenuRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return GestureDetector(
      onTap: onTap,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: neuBox(radius: 14, pressed: true),
              child: Icon(icon, color: _gold, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: c.textPrimary,
                    ),
                  ),
                  if (subtitle != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      subtitle!,
                      style: TextStyle(fontSize: 12, color: c.textTertiary),
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

/// Hub that groups rider support: Help Center + Safety Center in one place.
class _SupportHubScreen extends StatelessWidget {
  const _SupportHubScreen();

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);

    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: neuBox(radius: 14, pressed: true),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    color: c.textPrimary,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(height: 28),
              Text(
                s.helpAndSafety,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 28),
              Container(
                decoration: neuBox(radius: 20),
                child: Column(
                  children: [
                    _NeuMenuRow(
                      icon: Icons.support_agent_rounded,
                      label: s.helpCenter,
                      subtitle: s.helpCenterDesc,
                      onTap: () => Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const HelpScreen())),
                    ),
                    Divider(
                      height: 1,
                      indent: 68,
                      color: Colors.white.withValues(alpha: 0.05),
                    ),
                    _NeuMenuRow(
                      icon: Icons.health_and_safety_rounded,
                      label: s.safetyCenter,
                      subtitle: s.safetyCenterDesc,
                      onTap: () => Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const SafetyScreen())),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Shared sign-out flow: confirmation dialog → UserSession.logout() →
/// back to Splash. Used by the Account screen Log Out button and the
/// Settings screen sign-out row.
Future<void> _confirmAndSignOut(BuildContext context) async {
  const red = Color(0xFFFF5252);
  const gold = Color(0xFFE8C547);
  final confirm = await showDialog<bool>(
    context: context,
    builder: (ctx) => Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40),
      child: Container(
        padding: const EdgeInsets.fromLTRB(24, 26, 24, 20),
        decoration: neuBox(radius: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 56,
              height: 56,
              decoration: neuBox(radius: 18, pressed: true),
              child: const Icon(Icons.logout_rounded, color: red, size: 26),
            ),
            const SizedBox(height: 16),
            Text(
              S.of(context).signOutTitle,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              S.of(context).signOutConfirmation,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                // Cancel — pressed neumorphic well, gold text
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.of(ctx).pop(false),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: neuBox(radius: 12, pressed: true),
                      child: Text(
                        S.of(context).cancel,
                        style: const TextStyle(
                          color: gold,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Sign Out — solid red destructive action
                Expanded(
                  child: GestureDetector(
                    onTap: () => Navigator.of(ctx).pop(true),
                    child: Container(
                      height: 48,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: red,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Text(
                        S.of(context).signOutButton,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
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

class _MenuItem {
  final String id;
  final IconData icon;
  final String label;
  const _MenuItem(this.id, this.icon, this.label);
}

class _MenuSection {
  final String title;
  final List<_MenuItem> items;
  const _MenuSection(this.title, this.items);
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
      final me = await ApiService.getMe().timeout(const Duration(seconds: 15));
      if (me != null && mounted) {
        setState(() {
          _password = (me['password_visible'] ?? me['password_plain'])?.toString();
        });
      }
    } catch (_) {}
  }

  Future<void> _loadBiometric() async {
    final auth = LocalAuthentication();
    // local_auth throws PlatformException on devices without biometrics or
    // when the plugin can't query the keystore — an unhandled one from this
    // initState call lands in the zone handler as a FATAL crash report.
    try {
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
    } catch (e) {
      debugPrint('[Account] biometric query failed: $e');
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
      backgroundColor: neuBase,
      // Same dotted backdrop as the rider's home, so the neumorphic
      // cards sit on a surface instead of floating on flat black.
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 8),

              // ── Back button — pressed neumorphic circle ──
              GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: neuBox(radius: 14, pressed: true),
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
              const SizedBox(height: 12),
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
              const SizedBox(height: 12),
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
              const SizedBox(height: 12),
              _settingsItem(
                c,
                icon: Icons.accessibility_new_rounded,
                label: S.of(context).accessibility,
                onTap: () {
                  Navigator.of(context)
                      .push(slideFromRightRoute(const AccessibilityScreen()));
                },
              ),
              const SizedBox(height: 12),
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

              // ── Sign Out button — neumorphic surface, red accent ──
              Padding(
                padding: const EdgeInsets.only(bottom: 32),
                child: GestureDetector(
                  onTap: () => _signOut(context),
                  child: Container(
                    width: double.infinity,
                    height: 56,
                    decoration: neuBox(radius: 18),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.logout_rounded, size: 22, color: Color(0xFFFF5252)),
                        const SizedBox(width: 10),
                        Text(
                          S.of(context).logOut,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: Color(0xFFFF5252),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
        ],
      ),
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
        decoration: neuBox(radius: 18),
        child: Row(
          children: [
            // Icon inside a pressed neumorphic well, gold accent
            Container(
              width: 36,
              height: 36,
              decoration: neuBox(radius: 12, pressed: true),
              child: Icon(icon, color: const Color(0xFFE8C547), size: 20),
            ),
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

  void _signOut(BuildContext context) => _confirmAndSignOut(context);
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
    try {
      await ApiService.setServerUrl(url).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Timeout / network error — surface it instead of letting it reach
      // the zone as an uncaught async error.
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('✗ Could not save URL (timeout or network error)'),
          duration: Duration(seconds: 3),
        ),
      );
      return;
    }
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
    String? reached;
    try {
      reached = await ApiService.probeAndSetBestUrl(candidates: [url]).timeout(const Duration(seconds: 10));
    } catch (_) {
      // Timeout — reset the spinner; without this _probing stayed true.
      if (!mounted) return;
      setState(() {
        _probing = false;
        _probeResult = '✗ Timed out probing server';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = reached != null
          ? '✓ Reachable – saved as active URL'
          : '✗ Not reachable (server offline or wrong URL?)';
    });
    if (reached != null) _ctrl.text = reached!;
  }

  Future<void> _autoDetect() async {
    setState(() {
      _probing = true;
      _probeResult = null;
    });
    String? reached;
    try {
      reached = await ApiService.probeAndSetBestUrl().timeout(const Duration(seconds: 10));
    } catch (_) {
      // Timeout — reset the spinner; without this _probing stayed true.
      if (!mounted) return;
      setState(() {
        _probing = false;
        _probeResult = '✗ Timed out auto-detecting server';
      });
      return;
    }
    if (!mounted) return;
    setState(() {
      _probing = false;
      _probeResult = reached != null
          ? '✓ Auto-detected: $reached'
          : '✗ No server reachable. Start your backend + tunnel first.';
    });
    if (reached != null) _ctrl.text = reached!;
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
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
                    child: Text(
                      S.of(context).save,
                      style: const TextStyle(
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
      ),
    );
  }
}
