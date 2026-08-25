import '../utils/app_platform.dart';
import 'dart:math';
import 'package:flutter/material.dart';
import '../services/haptic_service.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../widgets/dismiss_keyboard.dart';
import '../widgets/neu_style.dart';
import '../services/sms_service.dart';
import '../services/analytics_service.dart';
import '../services/google_auth_service.dart';
import '../services/apple_auth_service.dart';
import '../services/user_session.dart';
import '../l10n/app_localizations.dart';
import 'login_verify_screen.dart';
import 'forgot_password_screen.dart';
import 'home_screen.dart';

/// Screen for users who already have an account — enter email/phone + password.
class LoginPasswordScreen extends StatefulWidget {
  final String? prefillEmail;
  const LoginPasswordScreen({super.key, this.prefillEmail});

  @override
  State<LoginPasswordScreen> createState() => _LoginPasswordScreenState();
}

class _LoginPasswordScreenState extends State<LoginPasswordScreen> {
  static const _gold = Color(0xFFE8C547);

  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _emailFocus = FocusNode();
  final _passFocus = FocusNode();
  bool _obscure = true;
  bool _canLogin = false;
  bool _loading = false;
  bool _socialLoading = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    final prefill = widget.prefillEmail;
    if (prefill != null && prefill.isNotEmpty) {
      _emailCtrl.text = prefill;
    }
    _emailCtrl.addListener(_validate);
    _passCtrl.addListener(_validate);
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _passCtrl.dispose();
    _emailFocus.dispose();
    _passFocus.dispose();
    super.dispose();
  }

  /// Navigate to home after successful social auth.
  void _goHome() {
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      smoothFadeRoute(const HomeScreen(), durationMs: 600),
      (route) => false,
    );
  }

  /// Sign in with Google OAuth (login only — won't create new accounts).
  Future<void> _signInWithGoogle() async {
    if (_socialLoading || _loading) return;
    setState(() { _socialLoading = true; _errorText = null; });
    try {
      final ok = await GoogleAuthService.instance.signIn(
        role: 'rider',
        loginOnly: true,
      );
      if (!mounted) return;
      if (ok) {
        _goHome();
      } else {
        // FIX: Show an error when Apple Sign-In returns false (e.g. user
        // object missing from backend response, or account doesn't exist
        // when loginOnly=true). Previously the spinner just stopped with
        // no feedback, leaving users confused.
        setState(() {
          _socialLoading = false;
          _errorText = S.of(context).appleSignInFailed;
        });
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      setState(() {
        _socialLoading = false;
        _errorText = msg.contains('401') || msg.contains('Invalid credentials')
            ? S.of(context).invalidCredentialsNoAccount
            : S.of(context).googleSignInFailed;
      });
    }
  }

  /// Sign in with Apple OAuth (login only — won't create new accounts).
  Future<void> _signInWithApple() async {
    if (_socialLoading || _loading) return;
    setState(() { _socialLoading = true; _errorText = null; });
    try {
      final ok = await AppleAuthService.instance.signIn(
        role: 'rider',
        loginOnly: true,
      );
      if (!mounted) return;
      if (ok) {
        _goHome();
      } else {
        setState(() { _socialLoading = false; });
      }
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString();
      setState(() {
        _socialLoading = false;
        _errorText = msg.contains('401') || msg.contains('Invalid credentials')
            ? S.of(context).invalidCredentialsNoAccount
            : S.of(context).appleSignInFailed;
      });
    }
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

  static final _phoneCleanRe = RegExp(r'[\s\-\(\)]');

  /// Normalize phone to E.164 format (safety net)
  String _normalizePhone(String text) {
    var cleaned = text.replaceAll(_phoneCleanRe, '');
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
      // Send code via backend — single source of truth
      final result = await ApiService.sendOtp(email: contact);
      if (!mounted) return;
      setState(() => _loading = false);

      if (result['ok'] != true) {
        setState(() => _errorText = S.of(context).couldNotSendVerificationEmail);
        return;
      }

      Navigator.of(context).push(
        slideFromRightRoute(
          LoginVerifyScreen(
            loginToken: loginToken,
            contact: contact,
            useVerifyApi: false,
            expectedCode: '',
            useBackendVerify: true,
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
          decoration: const BoxDecoration(
            color: neuBase,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                S.of(context).whereToSendCode,
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
                title: S.of(context).textMessageSms,
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
                title: S.of(context).emailOption,
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

  static final _phoneCleanPlusRe = RegExp(r'[\s\-\(\)\+]');
  static final _digitsOnlyRe = RegExp(r'^\d+$');

  /// Check if identity looks like a phone number (digits, spaces, dashes, parens, +)
  bool _looksLikePhone(String text) {
    final cleaned = text.replaceAll(_phoneCleanPlusRe, '');
    return cleaned.length >= 7 && _digitsOnlyRe.hasMatch(cleaned);
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

      // Demo accounts return access_token directly (skip OTP)
      if (loginResult.containsKey('access_token')) {
        await ApiService.saveToken(loginResult['access_token'] as String);
        if (loginResult.containsKey('refresh_token')) {
          await ApiService.saveRefreshToken(loginResult['refresh_token'] as String);
        }
        final user = loginResult['user'] as Map<String, dynamic>?;
        if (user != null) {
          await UserSession.saveUser(
            firstName: user['first_name'] ?? '',
            lastName: user['last_name'] ?? '',
            email: user['email'] ?? '',
            phone: user['phone'] ?? '',
            photoUrl: user['photo_url'] as String?,
            userId: user['id'] as int?,
            role: 'rider',
          );
        }
        setState(() => _loading = false);
        _goHome();
        return;
      }

      final loginToken = loginResult['login_token'] as String;
      AnalyticsService.instance.logLogin('password');
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
          _errorText = S.of(context).noContactMethodAvailable;
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
          msg = S.of(context).deviceClockOutOfSync;
        } else {
          msg = S.of(context).invalidEmailPhoneOrPassword;
        }
      } else if (e.statusCode == 403) {
        final detail = e.message.toLowerCase();
        if (detail.contains('deleted')) {
          msg = S.of(context).accountNoLongerExists;
        } else if (detail.contains('blocked')) {
          msg = S.of(context).accountBlocked;
        } else if (detail.contains('deactivated')) {
          msg = S.of(context).accountDeactivated;
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
      HapticService.mediumImpact();
    } catch (e, st) {
      // Say what actually broke.
      //
      // Everything below turns any failure into one sentence — "Connection
      // error — is the server running?" — which is a guess, not a diagnosis.
      // It says the same thing for a refused socket, a rejected CORS
      // preflight, a plugin missing on the platform and a null field, and
      // that made the browser build impossible to debug from the outside.
      debugPrint('[Login] sign-in failed: $e\n$st');
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
        _errorText = S.of(context).connectionError;
      });
      HapticService.mediumImpact();
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: neuBase,
      body: DismissKeyboard(
        child: SafeArea(
          child: SingleChildScrollView(
            physics: const ClampingScrollPhysics(),
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
                  decoration: neuBox(radius: 14, pressed: true),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    color: c.textPrimary,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(height: 28),

              // ── Title ──
              Text(
                S.of(context).welcomeBack,
                style: GoogleFonts.poppins(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: c.textPrimary,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).signInSubtitle,
                style: GoogleFonts.inter(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Email/phone + Password fields (AutofillGroup) ──
              AutofillGroup(
                child: Column(
                  children: [
                    // ── Email/phone field ──
                    _buildField(
                      c,
                      controller: _emailCtrl,
                      focusNode: _emailFocus,
                      hint: S.of(context).emailOrPhone,
                      icon: Icons.person_outline_rounded,
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [
                        AutofillHints.email,
                        AutofillHints.username,
                      ],
                    ),
                    const SizedBox(height: 16),

                    // ── Password field ──
                    _buildField(
                      c,
                      controller: _passCtrl,
                      focusNode: _passFocus,
                      hint: S.of(context).password,
                      icon: Icons.lock_outline_rounded,
                      obscure: _obscure,
                      autofillHints: const [AutofillHints.password],
                      suffix: GestureDetector(
                        onTap: () => setState(() => _obscure = !_obscure),
                        child: Icon(
                          _obscure
                              ? Icons.visibility_off_outlined
                              : Icons.visibility_outlined,
                          color: c.textTertiary,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
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
                            const Icon(
                              Icons.error_outline_rounded,
                              color: Color(0xFFFF5252),
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _errorText!,
                                style: const TextStyle(
                                  color: Color(0xFFFF5252),
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
              GestureDetector(
                onTap: _canLogin && !_loading ? _login : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  width: double.infinity,
                  height: 56,
                  decoration: _canLogin
                      ? BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(16),
                        )
                      : neuBox(radius: 16, pressed: true),
                  alignment: Alignment.center,
                  child: _loading
                      ? const SizedBox(
                          width: 22,
                          height: 22,
                          child: CircularProgressIndicator(
                            color: Colors.black,
                            strokeWidth: 2.5,
                          ),
                        )
                      : Text(
                          S.of(context).signIn,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                            color: _canLogin ? Colors.black : c.textTertiary,
                          ),
                        ),
                ),
              ),

              const SizedBox(height: 16),

              // ── Social Sign-In ──
              Row(
                children: [
                  Expanded(child: Divider(color: c.divider, thickness: 1)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      S.of(context).orLower,
                      style: TextStyle(
                        color: c.textTertiary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  Expanded(child: Divider(color: c.divider, thickness: 1)),
                ],
              ),
              const SizedBox(height: 16),

              // ── Google Sign-In ──
              GestureDetector(
                onTap: _socialLoading ? null : _signInWithGoogle,
                child: Container(
                  width: double.infinity,
                  height: 54,
                  decoration: neuBox(radius: 16, pressed: true),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      if (_socialLoading)
                        const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            color: _gold,
                            strokeWidth: 2,
                          ),
                        )
                      else
                        SizedBox(
                          width: 22,
                          height: 22,
                          child: Image.asset(
                            'assets/images/google_logo.png',
                            fit: BoxFit.contain,
                          ),
                        ),
                      const SizedBox(width: 10),
                      Text(
                        S.of(context).signInWithGoogle,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
              ),

              // ── Apple Sign-In (iOS only) ──
              if (AppPlatform.isIOS) ...[
                const SizedBox(height: 12),
                GestureDetector(
                  onTap: _socialLoading ? null : _signInWithApple,
                  child: Container(
                    width: double.infinity,
                    height: 54,
                    decoration: neuBox(radius: 16, pressed: true),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.apple, color: _gold, size: 24),
                        const SizedBox(width: 10),
                        Text(
                          S.of(context).signInWithApple,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 8),

              // ── Quick Access removed (production) ──
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// Neumorphic pressed-well text field.
  Widget _buildField(
    AppColors c, {
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    FocusNode? focusNode,
    bool obscure = false,
    Widget? suffix,
    TextInputType keyboardType = TextInputType.text,
    Iterable<String>? autofillHints,
  }) {
    return Container(
      decoration: neuBox(radius: 16, pressed: true),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: c.textTertiary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              obscureText: obscure,
              keyboardType: keyboardType,
              autofillHints: autofillHints,
              style: TextStyle(color: c.textPrimary, fontSize: 16),
              cursorColor: _gold,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
              ),
            ),
          ),
          if (suffix != null) suffix,
        ],
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
        borderRadius: BorderRadius.circular(18),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: neuBox(radius: 18),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: neuBox(radius: 14, pressed: true),
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
                        fontWeight: FontWeight.w600,
                        color: colors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: colors.textTertiary,
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
