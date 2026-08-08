import 'dart:async';
import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:cached_network_image/cached_network_image.dart';
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import '../services/firebase_storage_service.dart';
import '../services/photo_recovery_service.dart';
import '../widgets/dismiss_keyboard.dart';
import '../services/user_session.dart';
import '../services/google_auth_service.dart';
import 'ready_to_ride_screen.dart';

class ProfileReviewScreen extends StatefulWidget {
  final String firstName;
  final String lastName;
  final String email;
  final String phone;
  final String paymentMethod;
  final String? photoPath;

  const ProfileReviewScreen({
    super.key,
    required this.firstName,
    required this.lastName,
    required this.email,
    this.phone = '',
    required this.paymentMethod,
    this.photoPath,
  });

  @override
  State<ProfileReviewScreen> createState() => _ProfileReviewScreenState();
}

class _ProfileReviewScreenState extends State<ProfileReviewScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  String? _selectedGender;
  bool _dropdownOpen = false;
  bool _saving = false;

  final List<String> _genderOptions = const [
    'Men',
    'Women',
    'Nonbinary',
    'Prefer not to say',
  ];

  void _saveProfile() async {
    // One tap, one save. Without the guard a double-tap ran two
    // registrations, and with no spinner the button looked dead while the
    // network worked.
    if (_saving) return;
    setState(() => _saving = true);
    try {
    // Check if this is a social auth flow (Google/Apple)
    final pendingSocial = await UserSession.getPendingSocialAuth();
    // Grab the password set during registration (null for social flow)
    final pendingPass = await UserSession.getPendingPassword();

    int? userId;

    if (pendingSocial != null) {
      // ── Social auth flow: complete registration via /auth/social ──
      debugPrint(
        '📋 Social register: ${widget.firstName} ${widget.lastName} | email=${widget.email} | phone=${widget.phone}',
      );
      try {
        // The pending token was captured at Google sign-in — possibly hours
        // or days ago, and Google ID tokens live about an hour. Refresh
        // silently right before the call; the stored one is the fallback,
        // not the default.
        var idToken = pendingSocial['idToken']!;
        if (pendingSocial['provider'] == 'google') {
          final fresh = await GoogleAuthService.instance.refreshIdToken();
          if (fresh != null && fresh.isNotEmpty) idToken = fresh;
        }
        final result = await ApiService.socialAuth(
          provider: pendingSocial['provider']!,
          idToken: idToken,
          firstName: widget.firstName,
          lastName: widget.lastName,
          loginOnly: false,
          role: 'rider',
        );
        final user = result['user'] as Map<String, dynamic>;
        userId = user['id'] as int?;
        debugPrint('✅ Social auth successful');

        // Update additional profile fields (phone, etc.)
        final updates = <String, dynamic>{};
        if (widget.phone.isNotEmpty) updates['phone'] = widget.phone;
        if (widget.firstName.isNotEmpty) updates['first_name'] = widget.firstName;
        if (widget.lastName.isNotEmpty) updates['last_name'] = widget.lastName;
        if (updates.isNotEmpty) {
          await ApiService.updateMe(updates);
        }

        // Clear pending social auth
        await UserSession.clearPendingSocialAuth();
      } catch (e) {
        debugPrint('❌ Social auth failed: $e');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(
              'Registration failed: $e',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        return;
      }
    } else {
      // ── Normal email/phone registration flow ──
      debugPrint(
        '🔐 pendingPass: "${pendingPass ?? "NULL"}" (len=${pendingPass?.length ?? 0})',
      );
      debugPrint(
        '📋 Register: ${widget.firstName} ${widget.lastName} | email=${widget.email} | phone=${widget.phone}',
      );

      if (pendingPass == null || pendingPass.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              S.of(context).passwordNotFound,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            // Uses global snackBarTheme
          ),
        );
        return;
      }

      // ── Register on the backend ──
      try {
        final result = await ApiService.register(
          firstName: widget.firstName,
          lastName: widget.lastName,
          email: widget.email.isNotEmpty ? widget.email : null,
          phone: widget.phone.isNotEmpty ? widget.phone : null,
          password: pendingPass,
        );
        final user = result['user'] as Map<String, dynamic>;
        userId = user['id'] as int?;
        debugPrint('✅ Registered successfully');
      } on ApiException catch (e) {
        // ── Handle duplicate email/phone (409) by logging in instead ──
        if (e.statusCode == 409) {
          debugPrint('⚠️ Account exists — attempting auto-login…');
          try {
            final identifier = widget.email.isNotEmpty
                ? widget.email
                : widget.phone;
            final loginResult = await ApiService.login(
              identifier: identifier,
              password: pendingPass,
            );
            // Complete login (get JWT)
            final loginToken = loginResult['login_token'] as String;
            final completeResult = await ApiService.completeLogin(
              loginToken: loginToken,
            );
            final user = completeResult['user'] as Map<String, dynamic>;
            userId = user['id'] as int?;
            debugPrint('✅ Auto-login successful');
          } catch (loginErr) {
            debugPrint('❌ Auto-login also failed: $loginErr');
            if (!mounted) return;
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: Colors.redAccent,
                content: Text(
                  S.of(context).accountExistsDiffCreds,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                duration: const Duration(seconds: 5),
              ),
            );
            return;
          }
        } else {
          debugPrint('❌ Registration failed: $e');
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: Colors.redAccent,
              content: Text(
                e.message,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              duration: const Duration(seconds: 5),
            ),
          );
          return;
        }
      } catch (e) {
        debugPrint('❌ Registration failed: $e');
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: Colors.redAccent,
            content: Text(
              'Registration failed: $e',
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            duration: const Duration(seconds: 5),
          ),
        );
        return;
      }
    }

    // Copy photo to permanent storage (temp picker path gets deleted).
    // Local file copy — fast, so it stays on the critical path; the UPLOAD
    // does not (see below).
    String? permanentPhotoPath = widget.photoPath;
    if (widget.photoPath != null && widget.photoPath!.isNotEmpty) {
      permanentPhotoPath = await UserSession.saveProfilePhoto(
        widget.photoPath!,
      );
    }

    // Save locally too (for offline/quick reads)
    await UserSession.saveUser(
      firstName: widget.firstName,
      lastName: widget.lastName,
      email: widget.email,
      phone: widget.phone,
      photoPath: permanentPhotoPath,
      gender: _selectedGender ?? '',
      paymentMethod: widget.paymentMethod,
      password: pendingPass,
      userId: userId,
    );

    // Consent logging and the photo upload used to be awaited here, between
    // the tap and the transition — two consent calls plus a Firebase upload
    // is why Save profile "did nothing" for seconds. None of them gate the
    // next screen, so they run after it is already up.
    final bgUserId = userId;
    final bgPhotoPath = permanentPhotoPath;
    unawaited(Future(() async {
      if (bgUserId != null) {
        // E-SIGN record (version, UTC timestamp, IP, user agent).
        try {
          await ApiService.recordConsent(
              consentType: 'terms', action: 'accepted', version: '1.0');
          await ApiService.recordConsent(
              consentType: 'privacy', action: 'accepted', version: '2.0');
        } catch (e) {
          debugPrint('⚠️ Consent logging failed (non-blocking): $e');
        }
      }
      if (bgPhotoPath != null && bgPhotoPath.isNotEmpty) {
        try {
          final photoUrl = await ApiService.uploadPhoto(bgPhotoPath);
          if (photoUrl.isNotEmpty) {
            UserSession.photoUrlNotifier.value = photoUrl;
          }
        } catch (e) {
          debugPrint('⚠️ Photo upload failed: $e');
        }
      }
    }));

    // A fresh signup has NOT verified yet — mark it so the home shows the
    // verify card from the very first frame instead of a live "Where to?"
    // that locks itself a second later. The KYC screen (auto-approving for
    // riders now) flips this to 'approved'.
    await UserSession.updateField('verificationStatus', 'pending');

    // Auto-enable biometric login so it appears on next sign-in
    await LocalDataService.setBiometricLogin(true);

    // Schedule welcome notification 10 minutes after registration
    final role = await UserSession.getMode();
    if (role != 'driver') {
      NotificationService.scheduleAt(
        id: 9999,
        title: 'Welcome to Cruise! \u{1F389}',
        body:
            'Thanks for joining! Enjoy 10% off your first ride with code WELCOME10 \u{1F697}',
        scheduledTime: DateTime.now().add(const Duration(minutes: 10)),
        payload: 'welcome_discount',
      );
    }

    if (!mounted) return;
    Navigator.of(context).push(
      smoothFadeRoute(
        ReadyToRideScreen(firstName: widget.firstName),
        durationMs: 500,
      ),
    );
    } finally {
      // The error paths above all return early; the spinner must come back
      // off on every one of them or the button stays dead after a failure.
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: DismissKeyboard(
        child: SafeArea(
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

              // ── Scrollable content area ──
              Expanded(
                child: SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(height: 28),

                      // ── Title ──
                      Text(
                        S.of(context).everythingLookGood,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: c.textPrimary,
                          height: 1.2,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        S.of(context).reviewInfoSubtitle,
                        style: TextStyle(
                          fontSize: 14,
                          color: c.textSecondary,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 32),

                      // ── Avatar + Name ──
                      Center(
                        child: Column(
                          children: [
                            Stack(
                              children: [
                                Container(
                                  width: 90,
                                  height: 90,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: c.surface,
                                  ),
                                  child: widget.photoPath != null
                                      ? ClipOval(
                                          child: kIsWeb
                                              ? CachedNetworkImage(
                                                  imageUrl: widget.photoPath!,
                                                  fit: BoxFit.cover,
                                                  width: 90,
                                                  height: 90,
                                                  fadeInDuration: const Duration(milliseconds: 200),
                                                )
                                              : Image.file(
                                                  File(widget.photoPath!),
                                                  fit: BoxFit.cover,
                                                  width: 90,
                                                  height: 90,
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
                                                          duration:
                                                              const Duration(
                                                                milliseconds:
                                                                    300,
                                                              ),
                                                          curve: Curves
                                                              .easeOutCubic,
                                                          child: child,
                                                        );
                                                      },
                                                ),
                                        )
                                      : Icon(
                                          Icons.person_rounded,
                                          size: 45,
                                          color: c.textTertiary,
                                        ),
                                ),
                                Positioned(
                                  bottom: 0,
                                  right: 0,
                                  child: Container(
                                    width: 30,
                                    height: 30,
                                    decoration: BoxDecoration(
                                      color: c.panel,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: c.border,
                                        width: 1.5,
                                      ),
                                    ),
                                    child: Icon(
                                      Icons.edit_rounded,
                                      size: 14,
                                      color: c.textSecondary,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '${widget.firstName} ${widget.lastName}',
                              style: TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: c.textPrimary,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),

                      // ── Gender selector ──
                      GestureDetector(
                        onTap: () {
                          setState(() => _dropdownOpen = !_dropdownOpen);
                        },
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 16,
                          ),
                          decoration: BoxDecoration(
                            color: c.surface,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(
                              color: _dropdownOpen
                                  ? _gold.withValues(alpha: 0.5)
                                  : c.border,
                            ),
                          ),
                          child: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  _selectedGender ??
                                      S.of(context).selectGenderHint,
                                  style: TextStyle(
                                    fontSize: 16,
                                    color: _selectedGender != null
                                        ? c.textPrimary
                                        : c.textTertiary,
                                  ),
                                ),
                              ),
                              AnimatedRotation(
                                turns: _dropdownOpen ? 0.5 : 0,
                                duration: const Duration(milliseconds: 200),
                                child: Icon(
                                  Icons.keyboard_arrow_down_rounded,
                                  color: _gold,
                                  size: 24,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // ── Dropdown items ──
                      AnimatedCrossFade(
                        duration: const Duration(milliseconds: 250),
                        crossFadeState: _dropdownOpen
                            ? CrossFadeState.showFirst
                            : CrossFadeState.showSecond,
                        firstChild: Container(
                          margin: const EdgeInsets.only(top: 4),
                          decoration: BoxDecoration(
                            color: c.panel,
                            borderRadius: BorderRadius.circular(16),
                            border: Border.all(color: c.border),
                            boxShadow: [
                              BoxShadow(
                                color: c.shadow,
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: Column(
                            children: _genderOptions.map((g) {
                              final selected = _selectedGender == g;
                              return GestureDetector(
                                onTap: () {
                                  setState(() {
                                    _selectedGender = g;
                                    _dropdownOpen = false;
                                  });
                                },
                                child: Container(
                                  width: double.infinity,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 16,
                                    vertical: 16,
                                  ),
                                  decoration: BoxDecoration(
                                    color: selected
                                        ? _gold.withValues(alpha: 0.06)
                                        : Colors.transparent,
                                    border: Border(
                                      bottom: g != _genderOptions.last
                                          ? BorderSide(color: c.divider)
                                          : BorderSide.none,
                                    ),
                                  ),
                                  child: Text(
                                    g,
                                    style: TextStyle(
                                      fontSize: 16,
                                      fontWeight: selected
                                          ? FontWeight.w600
                                          : FontWeight.w400,
                                      color: selected ? _gold : c.textPrimary,
                                    ),
                                  ),
                                ),
                              );
                            }).toList(),
                          ),
                        ),
                        secondChild: const SizedBox.shrink(),
                      ),

                      const SizedBox(height: 16),

                      // ── Privacy note ──
                      Text(
                        S.of(context).genderPrivacyNote,
                        style: TextStyle(
                          fontSize: 12,
                          color: c.textTertiary,
                          height: 1.5,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Save profile button ──
              Padding(
                padding: const EdgeInsets.only(bottom: 24, top: 16),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [_gold, _goldLight],
                      ),
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
                      onPressed: _saving ? null : _saveProfile,
                      child: _saving
                          ? const SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                strokeWidth: 2.5,
                                color: Color(0xFF1A1400),
                              ),
                            )
                          : Text(
                              S.of(context).saveProfile,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
