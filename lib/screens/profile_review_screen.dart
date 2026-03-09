import 'dart:io' if (dart.library.html) 'dart:io';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import '../l10n/app_localizations.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import '../services/user_session.dart';
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

  final List<String> _genderOptions = const [
    'Men',
    'Women',
    'Nonbinary',
    'Prefer not to say',
  ];

  void _saveProfile() async {
    // Grab the password set during registration
    final pendingPass = await UserSession.getPendingPassword();
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
          backgroundColor: Colors.white.withValues(alpha: 0.6),
          content: Text(
            S.of(context).passwordNotFound,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
      return;
    }

    // ── Register on the backend ──
    int? userId;
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
      debugPrint('✅ Registered userId=$userId');
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
          debugPrint('✅ Auto-login successful userId=$userId');
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

    // Copy photo to permanent storage (temp picker path gets deleted)
    String? permanentPhotoPath = widget.photoPath;
    if (widget.photoPath != null && widget.photoPath!.isNotEmpty) {
      permanentPhotoPath = await UserSession.saveProfilePhoto(
        widget.photoPath!,
      );
    }

    // Upload photo to server so it persists across devices
    if (permanentPhotoPath != null && permanentPhotoPath.isNotEmpty) {
      try {
        final photoUrl = await ApiService.uploadPhoto(permanentPhotoPath);
        if (photoUrl.isNotEmpty) {
          await ApiService.updateMe({'photo_url': photoUrl});
        }
      } catch (e) {
        debugPrint('⚠️ Photo upload failed: $e');
      }
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
                                              ? Image.network(
                                                  widget.photoPath!,
                                                  fit: BoxFit.cover,
                                                  width: 90,
                                                  height: 90,
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
                                                        if (wasSynchronouslyLoaded)
                                                          return child;
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
                      onPressed: _saveProfile,
                      child: Text(
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
    );
  }
}
