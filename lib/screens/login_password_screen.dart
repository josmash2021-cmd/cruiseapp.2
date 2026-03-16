import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:local_auth/local_auth.dart';
import '../config/app_theme.dart';
import '../widgets/animated_biometric_icon.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/email_service.dart';
import '../services/local_data_service.dart';
import '../services/sms_service.dart';
import '../services/user_session.dart';
import '../l10n/app_localizations.dart';
import 'login_verify_screen.dart';
import 'forgot_password_screen.dart';
import 'map_screen.dart';

/// Screen for users who already have an account — enter email/phone + password.
class LoginPasswordScreen extends StatefulWidget {
  const LoginPasswordScreen({super.key});

  @override
  State<LoginPasswordScreen> createState() => _LoginPasswordScreenState();
}

class _LoginPasswordScreenState extends State<LoginPasswordScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _canLogin = false;
  bool _loading = false;
  String? _errorText;
  bool _biometricAvailable = false;
  BiometricIconType _biometricType = BiometricIconType.faceId;

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_validate);
    _passCtrl.addListener(_validate);
    _checkBiometric();
  }

  Future<void> _checkBiometric() async {
    final enabled = await LocalDataService.isBiometricLoginEnabled();
    if (!enabled) return;
    final auth = LocalAuthentication();
    final canCheck =
        await auth.canCheckBiometrics || await auth.isDeviceSupported();
    if (mounted && canCheck) {
      final types = await auth.getAvailableBiometrics();
      // Face ID on iOS only, Fingerprint on Android only
      if (Platform.isIOS && types.contains(BiometricType.face)) {
        setState(() {
          _biometricAvailable = true;
          _biometricType = BiometricIconType.faceId;
        });
      } else if (Platform.isAndroid &&
          types.contains(BiometricType.fingerprint)) {
        setState(() {
          _biometricAvailable = true;
          _biometricType = BiometricIconType.fingerprint;
        });
      }
    }
  }

  Future<void> _loginWithBiometric() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });

    try {
      final auth = LocalAuthentication();
      final ok = await auth.authenticate(
        localizedReason: 'Sign in to Cruise',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: true,
        ),
      );
      if (!ok) {
        if (mounted) {
          setState(() {
            _loading = false;
            _errorText = 'Biometric authentication failed';
          });
        }
        return;
      }
      // Biometric passed — check if user session still exists
      final loggedIn = await UserSession.isLoggedIn();
      if (loggedIn) {
        await UserSession.initPhotoNotifier();
        if (!mounted) return;
        setState(() => _loading = false);
        Navigator.of(context).pushAndRemoveUntil(
          slideFromRightRoute(const MapScreen()),
          (_) => false,
        );
        return;
      }
      // Session expired — need password
      if (mounted) {
        setState(() {
          _loading = false;
          _errorText = 'Session expired. Please sign in with your password.';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _loading = false;
          _errorText = 'Biometric error: $e';
        });
      }
    }
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _validate() {
    final ok = _emailCtrl.text.trim().isNotEmpty && _passCtrl.text.isNotEmpty;
    if (ok != _canLogin || _errorText != null) {
      setState(() {
        _canLogin = ok;
        _errorText = null;
      });
    }
  }

  String _generateCode() {
    final r = Random();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  /// Normalize phone to E.164 format (safety net)
  String _normalizePhone(String text) {
    var cleaned = text.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    if (!cleaned.startsWith('+')) {
      cleaned = '+1$cleaned'; // Default to US
    }
    return cleaned;
  }

  // ── Send code via chosen method and navigate ──
  Future<void> _sendCodeAndNavigate({
    required String loginToken,
    required String method, // "phone" or "email"
    required String contact,
    String? fallbackEmail,
  }) async {
    if (method == 'phone') {
      final normalizedPhone = _normalizePhone(contact);
      final result = await SmsService.sendVerificationCode(
        toPhone: normalizedPhone,
      );
      if (!mounted) return;
      setState(() => _loading = false);

      if (result.ok) {
        Navigator.of(context).push(
          slideFromRightRoute(
            LoginVerifyScreen(
              loginToken: loginToken,
              contact: normalizedPhone,
              useVerifyApi: true,
            ),
          ),
        );
      } else if (result.trialBlocked) {
        // Trial account fallback — use local code
        final devCode = _generateCode();
        debugPrint(
          '\ud83d\udcf1 DEV MODE — login code for $normalizedPhone: $devCode',
        );
        Navigator.of(context).push(
          slideFromRightRoute(
            LoginVerifyScreen(
              loginToken: loginToken,
              contact: normalizedPhone,
              useVerifyApi: false,
              expectedCode: devCode,
            ),
          ),
        );
      } else if (fallbackEmail != null && fallbackEmail.isNotEmpty) {
        // SMS failed — automatically fall back to email verification
        debugPrint('⚠️ SMS failed, falling back to email verification');
        setState(() => _loading = true);
        await _sendCodeAndNavigate(
          loginToken: loginToken,
          method: 'email',
          contact: fallbackEmail,
        );
        return;
      } else {
        // No email fallback available — use local dev code
        final devCode = _generateCode();
        debugPrint(
          '\ud83d\udcf1 DEV MODE — SMS unavailable, login code for $normalizedPhone: $devCode',
        );
        Navigator.of(context).push(
          slideFromRightRoute(
            LoginVerifyScreen(
              loginToken: loginToken,
              contact: normalizedPhone,
              useVerifyApi: false,
              expectedCode: devCode,
            ),
          ),
        );
      }
    } else {
      final code = _generateCode();
      await EmailService.sendVerificationCode(toEmail: contact, code: code);
      if (!mounted) return;
      setState(() => _loading = false);

      Navigator.of(context).push(
        slideFromRightRoute(
          LoginVerifyScreen(
            loginToken: loginToken,
            contact: contact,
            useVerifyApi: false,
            expectedCode: code,
          ),
        ),
      );
    }
  }

  // ── Bottom sheet to choose between phone and email ──
  void _showMethodPicker({
    required String loginToken,
    required String phone,
    required String email,
  }) {
    final c = AppColors.of(context);

    String maskPhone(String p) {
      if (p.length <= 4) return p;
      return '${'•' * (p.length - 4)}${p.substring(p.length - 4)}';
    }

    String maskEmail(String e) {
      final parts = e.split('@');
      if (parts.length != 2) return e;
      final name = parts[0];
      final domain = parts[1];
      if (name.length <= 2) return e;
      return '${name[0]}${'•' * (name.length - 2)}${name[name.length - 1]}@$domain';
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) {
        return Container(
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // ── Handle bar ──
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: c.textTertiary.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 20),

              Text(
                'Where should we send\nyour verification code?',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  height: 1.25,
                ),
              ),
              const SizedBox(height: 24),

              // ── Phone option ──
              _MethodTile(
                icon: Icons.sms_outlined,
                title: 'Text message (SMS)',
                subtitle: maskPhone(phone),
                gold: _gold,
                colors: c,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _sendCodeAndNavigate(
                    loginToken: loginToken,
                    method: 'phone',
                    contact: phone,
                    fallbackEmail: email,
                  );
                },
              ),
              const SizedBox(height: 12),

              // ── Email option ──
              _MethodTile(
                icon: Icons.email_outlined,
                title: 'Email',
                subtitle: maskEmail(email),
                gold: _gold,
                colors: c,
                onTap: () {
                  Navigator.of(ctx).pop();
                  _sendCodeAndNavigate(
                    loginToken: loginToken,
                    method: 'email',
                    contact: email,
                  );
                },
              ),
            ],
          ),
        );
      },
    );
  }

  /// Check if identity looks like a phone number (digits, spaces, dashes, parens, +)
  bool _looksLikePhone(String text) {
    final cleaned = text.replaceAll(RegExp(r'[\s\-\(\)\+]'), '');
    return cleaned.length >= 7 && RegExp(r'^\d+$').hasMatch(cleaned);
  }

  void _login() async {
    if (_loading) return;
    var identity = _emailCtrl.text.trim();
    final password = _passCtrl.text;

    if (identity.isEmpty || password.isEmpty) return;

    // Normalize phone numbers to E.164 format before sending to backend
    if (_looksLikePhone(identity)) {
      identity = _normalizePhone(identity);
    }

    setState(() {
      _loading = true;
      _errorText = null;
    });

    try {
      // 1. Validate credentials against server
      final loginResult = await ApiService.login(
        identifier: identity,
        password: password,
        role: 'rider',
      );

      if (!mounted) return;

      final loginToken = loginResult['login_token'] as String;
      final email = loginResult['email'] as String?;
      final phone = loginResult['phone'] as String?;

      final hasPhone = phone != null && phone.isNotEmpty;
      final hasEmail = email != null && email.isNotEmpty;

      // 2. If both methods available → let user choose
      if (hasPhone && hasEmail) {
        setState(() => _loading = false);
        _showMethodPicker(loginToken: loginToken, phone: phone, email: email);
        return;
      }

      // 3. Only one method available → send directly
      if (hasPhone) {
        await _sendCodeAndNavigate(
          loginToken: loginToken,
          method: 'phone',
          contact: phone,
          fallbackEmail: hasEmail ? email : null,
        );
      } else if (hasEmail) {
        await _sendCodeAndNavigate(
          loginToken: loginToken,
          method: 'email',
          contact: email,
        );
      } else {
        setState(() {
          _loading = false;
          _errorText = 'No contact method available';
        });
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      String msg;
      if (e.statusCode == 401) {
        final detail = e.message.toLowerCase();
        if (detail.contains('timestamp') ||
            detail.contains('clock') ||
            detail.contains('expired')) {
          msg =
              'Device clock out of sync. Go to Settings → Date & Time and enable "Set Automatically".';
        } else {
          msg = 'Invalid email/phone or password';
        }
      } else if (e.statusCode == 403) {
        final detail = e.message.toLowerCase();
        if (detail.contains('deleted')) {
          msg = 'This account no longer exists';
        } else if (detail.contains('blocked')) {
          msg = 'Your account has been blocked';
        } else if (detail.contains('deactivated')) {
          msg = 'Your account has been deactivated';
        } else {
          msg = e.message;
        }
      } else {
        msg = e.message;
      }
      setState(() {
        _loading = false;
        _errorText = msg;
      });
      HapticFeedback.mediumImpact();
    } catch (e) {
      if (!mounted) return;
      // Auto re-probe for a working server URL and retry once
      final newUrl = await ApiService.probeAndSetBestUrl(
        timeout: const Duration(seconds: 6),
      );
      if (newUrl != null && mounted) {
        try {
          final retryResult = await ApiService.login(
            identifier: identity,
            password: password,
            role: 'rider',
          );
          if (!mounted) return;
          final loginToken = retryResult['login_token'] as String;
          final email = retryResult['email'] as String?;
          final phone = retryResult['phone'] as String?;
          final hasPhone = phone != null && phone.isNotEmpty;
          final hasEmail = email != null && email.isNotEmpty;
          if (hasPhone && hasEmail) {
            setState(() => _loading = false);
            _showMethodPicker(loginToken: loginToken, phone: phone, email: email);
            return;
          }
          if (hasPhone) {
            await _sendCodeAndNavigate(
              loginToken: loginToken, method: 'phone', contact: phone,
              fallbackEmail: hasEmail ? email : null,
            );
          } else if (hasEmail) {
            await _sendCodeAndNavigate(
              loginToken: loginToken, method: 'email', contact: email,
            );
          }
          return;
        } catch (_) {
          // Retry also failed — show error
        }
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = 'Connection error — is the server running?';
      });
      HapticFeedback.mediumImpact();
    }
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
              const SizedBox(height: 28),

              // ── Title ──
              Text(
                S.of(context).welcomeBack,
                style: GoogleFonts.cinzel(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                  color: c.textPrimary,
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                S.of(context).signInSubtitle,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Email/phone field ──
              Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: c.border),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: TextField(
                  controller: _emailCtrl,
                  keyboardType: TextInputType.emailAddress,
                  style: TextStyle(color: c.textPrimary, fontSize: 16),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: S.of(context).emailOrPhone,
                    hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
                    prefixIcon: Icon(
                      Icons.person_outline_rounded,
                      color: c.textTertiary,
                      size: 20,
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 0,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 16),

              // ── Password field ──
              Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: c.border),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 4,
                ),
                child: TextField(
                  controller: _passCtrl,
                  obscureText: _obscure,
                  style: TextStyle(color: c.textPrimary, fontSize: 16),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: S.of(context).password,
                    hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
                    prefixIcon: Icon(
                      Icons.lock_outline_rounded,
                      color: c.textTertiary,
                      size: 20,
                    ),
                    prefixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 0,
                    ),
                    suffixIcon: GestureDetector(
                      onTap: () => setState(() => _obscure = !_obscure),
                      child: Icon(
                        _obscure
                            ? Icons.visibility_off_outlined
                            : Icons.visibility_outlined,
                        color: c.textTertiary,
                        size: 20,
                      ),
                    ),
                    suffixIconConstraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 0,
                    ),
                  ),
                ),
              ),

              // ── Error text ──
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: _errorText != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12, left: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              color: Colors.white.withValues(alpha: 0.6),
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _errorText!,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
                                  fontSize: 14,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () {
                    Navigator.of(
                      context,
                    ).push(slideFromRightRoute(const ForgotPasswordScreen()));
                  },
                  child: Text(
                    S.of(context).forgotPassword,
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // ── Sign in button ──
              SizedBox(
                width: double.infinity,
                height: 56,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  decoration: BoxDecoration(
                    gradient: _canLogin
                        ? const LinearGradient(colors: [_gold, _goldLight])
                        : null,
                    color: _canLogin ? null : c.surface,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      foregroundColor: _canLogin
                          ? const Color(0xFF1A1400)
                          : c.textTertiary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: _canLogin ? _login : null,
                    child: _loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Color(0xFF1A1400),
                              strokeWidth: 2.5,
                            ),
                          )
                        : Text(
                            S.of(context).signIn,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Face ID / Biometric Sign-In ──
              if (_biometricAvailable)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: SizedBox(
                    width: double.infinity,
                    height: 56,
                    child: OutlinedButton.icon(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _gold,
                        side: const BorderSide(color: _gold, width: 1.5),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      onPressed: _loading ? null : _loginWithBiometric,
                      icon: AnimatedBiometricIcon(
                        size: 24,
                        color: _gold,
                        type: _biometricType,
                      ),
                      label: Text(
                        _biometricType == BiometricIconType.faceId
                            ? 'Sign in with Face ID'
                            : 'Sign in with Fingerprint',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),

              // ── Quick Access removed (production) ──
              const Spacer(),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
//  Reusable tile for the method-picker bottom sheet
// ─────────────────────────────────────────────────────────
class _MethodTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final Color gold;
  final AppColors colors;
  final VoidCallback onTap;

  const _MethodTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.gold,
    required this.colors,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: colors.border),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: gold, size: 22),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 14,
                        color: colors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: colors.textTertiary,
                size: 22,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
