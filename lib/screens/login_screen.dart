import 'dart:math';
import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/screen_security_service.dart';
import '../widgets/dismiss_keyboard.dart';
import '../services/sms_service.dart';
import '../services/google_auth_service.dart';
import '../services/apple_auth_service.dart';
import '../services/user_session.dart';
import 'login_password_screen.dart';
import 'verify_code_screen.dart';
import 'terms_conditions_screen.dart';
import 'create_password_screen.dart';
import 'home_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SecureScreenMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _inputCtrl = TextEditingController();
  bool _canContinue = false;
  bool _sending = false;
  bool _usePhone = false; // false = email, true = phone

  @override
  void initState() {
    super.initState();
    _inputCtrl.addListener(_onInputChanged);
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  void _onInputChanged() {
    final ok = _inputCtrl.text.trim().isNotEmpty;
    if (ok != _canContinue) setState(() => _canContinue = ok);
  }

  void _toggleInputMode() {
    setState(() {
      _usePhone = !_usePhone;
      _inputCtrl.clear();
      _canContinue = false;
    });
  }

  bool _socialLoading = false;

  /// Google registration: get credential → check not exists → send OTP →
  /// verify OTP → create account via /auth/social.
  Future<void> _signUpWithGoogle() async {
    if (_socialLoading) return;
    setState(() => _socialLoading = true);
    try {
      final cred = await GoogleAuthService.instance.getCredential();
      if (!mounted) return;
      if (cred == null) {
        setState(() => _socialLoading = false);
        _showSnack(S.of(context).googleSignInCancelled, Colors.white.withValues(alpha: 0.6));
        return;
      }
      final email = cred['email'];
      if (email == null || email.isEmpty) {
        setState(() => _socialLoading = false);
        _showSnack(S.of(context).googleNoEmail, Colors.white.withValues(alpha: 0.6));
        return;
      }
      await _socialRegistrationFlow(
        email: email,
        provider: 'google',
        idToken: cred['idToken'],
        firstName: cred['firstName'],
        lastName: cred['lastName'],
        photoUrl: cred['photoUrl'],
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _socialLoading = false);
      _showSnack(S.of(context).googleSignInError(e.toString()), Colors.white.withValues(alpha: 0.6));
    }
  }

  /// Apple registration: get credential → check not exists → send OTP →
  /// verify OTP → create account via /auth/social.
  /// Apple only provides email on first-time auth; returning users get null.
  Future<void> _signUpWithApple() async {
    if (_socialLoading) return;
    setState(() => _socialLoading = true);
    try {
      final cred = await AppleAuthService.instance.getCredential();
      if (!mounted) return;
      if (cred == null) {
        setState(() => _socialLoading = false);
        _showSnack(S.of(context).appleSignInCancelled, Colors.white.withValues(alpha: 0.6));
        return;
      }
      final email = cred['email'];
      if (email == null || email.isEmpty) {
        // Apple doesn't re-send email after first auth — ask user to enter it.
        setState(() => _socialLoading = false);
        _showAppleEmailDialog(
          idToken: cred['idToken'],
          firstName: cred['firstName'],
          lastName: cred['lastName'],
        );
        return;
      }
      await _socialRegistrationFlow(
        email: email,
        provider: 'apple',
        idToken: cred['idToken'],
        firstName: cred['firstName'],
        lastName: cred['lastName'],
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _socialLoading = false);
      _showSnack(S.of(context).appleSignInError(e.toString()), Colors.white.withValues(alpha: 0.6));
    }
  }

  /// Shared social registration flow:
  ///   1. If account already exists → tell user to sign in instead.
  ///   2. Send OTP to email.
  ///   3. Show OTP verify screen.
  ///   4. After verification → go through the NORMAL onboarding flow
  ///      (password → name → phone → notifications → payment → photo → review).
  ///      Social auth data is saved as "pending" and completed at the end.
  Future<void> _socialRegistrationFlow({
    required String email,
    required String provider,
    String? idToken,
    String? firstName,
    String? lastName,
    String? photoUrl,
  }) async {
    // 1. Check if account already exists
    final exists = await ApiService.checkExists(email, role: 'rider');
    if (!mounted) return;

    if (exists) {
      setState(() => _socialLoading = false);
      _showAccountExistsDialog(email);
      return;
    }

    // 2. Send OTP to the email obtained from Google/Apple
    try {
      final otpResult = await ApiService.sendOtp(email: email);
      if (!mounted) return;
      if (otpResult['ok'] != true) {
        setState(() => _socialLoading = false);
        _showSnack(S.of(context).failedToSendVerificationCode, Colors.white.withValues(alpha: 0.6));
        return;
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _socialLoading = false);
      _showSnack(S.of(context).failedToSendVerificationCodeError(e.toString()), Colors.white.withValues(alpha: 0.6));
      return;
    }

    setState(() => _socialLoading = false);
    if (!mounted) return;

    // 3. Navigate to OTP verify screen — it calls back with verified=true
    bool? verified = false;
    await Navigator.of(context).push(
      slideFromRightRoute(
        VerifyCodeScreen(
          email: email,
          expectedCode: '',
          useBackendVerify: true,
          onVerified: (v) => verified = v,
        ),
      ),
    );

    if (verified != true || !mounted) return;

    // 4. OTP verified — save social data as pending and go through normal onboarding
    await UserSession.savePendingSocialAuth(
      provider: provider,
      idToken: idToken ?? '',
      firstName: firstName,
      lastName: lastName,
      photoUrl: photoUrl,
    );

    if (!mounted) return;
    Navigator.of(context).push(
      slideFromRightRoute(
        CreatePasswordScreen(
          email: email,
          registeredWithEmail: true,
        ),
      ),
    );
  }

  /// Shown when Apple doesn't return an email (returning Apple user).
  /// Prompts the user to type their email manually so we can send OTP.
  void _showAppleEmailDialog({
    String? idToken,
    String? firstName,
    String? lastName,
  }) {
    final c = AppColors.of(context);
    final ctrl = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          S.of(context).enterYourEmailTitle,
          style: TextStyle(color: c.textPrimary, fontSize: 18, fontWeight: FontWeight.w700),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              S.of(context).appleEmailExplanation,
              style: TextStyle(color: c.textSecondary, fontSize: 14, height: 1.4),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: ctrl,
              keyboardType: TextInputType.emailAddress,
              autofocus: true,
              style: TextStyle(color: c.textPrimary),
              decoration: InputDecoration(
                hintText: 'your@email.com',
                hintStyle: TextStyle(color: c.textTertiary),
                filled: true,
                fillColor: c.bg,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide(color: c.border),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(S.of(context).cancelBtn, style: TextStyle(color: c.textTertiary)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE8C547),
              foregroundColor: const Color(0xFF1A1400),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            ),
            onPressed: () {
              final email = ctrl.text.trim();
              if (email.isEmpty || !_isValidEmail(email)) return;
              Navigator.of(ctx).pop();
              _socialRegistrationFlow(
                email: email,
                provider: 'apple',
                idToken: idToken,
                firstName: firstName,
                lastName: lastName,
              );
            },
            child: Text(S.of(context).continueBtn, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    ).whenComplete(() => ctrl.dispose);
  }


  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final _phoneCleanRe = RegExp(r'[\s\-\(\)]');
  static final _phonePrefixRe = RegExp(r'^\+?1(?=\d{10})');
  static final _phoneDigitsRe = RegExp(r'^\d{10}$');

  bool _isValidEmail(String text) {
    return _emailRe.hasMatch(text.trim());
  }

  bool _isValidPhone(String text) {
    // US only: exactly 10 digits (area code + number)
    final cleaned = text.replaceAll(_phoneCleanRe, '');
    // Strip leading +1 or 1 if user typed it
    final digits = cleaned.replaceFirst(_phonePrefixRe, '');
    return _phoneDigitsRe.hasMatch(digits);
  }

  /// Normalize phone to E.164 format (+1XXXXXXXXXX)
  String _normalizePhone(String text) {
    var cleaned = text.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    // Strip leading +1 or 1 if present
    cleaned = cleaned.replaceFirst(RegExp(r'^\+?1(?=\d{10})'), '');
    return '+1$cleaned';
  }

  /// Generate a 6-digit code (demo — in production this would be server-side)
  String _generateCode() {
    final r = Random();
    return List.generate(6, (_) => r.nextInt(10)).join();
  }

  void _continueWithInput() async {
    final input = _inputCtrl.text.trim();
    if (input.isEmpty || _sending) return;

    if (_usePhone) {
      _continueWithPhone(input);
    } else {
      _continueWithEmail(input);
    }
  }

  void _continueWithEmail(String email) async {
    if (!_isValidEmail(email)) {
      _showSnack(
        S.of(context).invalidEmail,
        Colors.white.withValues(alpha: 0.6),
      );
      return;
    }

    setState(() => _sending = true);

    // Check if account already exists
    final exists = await ApiService.checkExists(email, role: 'rider');
    if (!mounted) return;
    if (exists) {
      setState(() => _sending = false);
      _showAccountExistsDialog(email);
      return;
    }

    // Backend generates ONE code, stores it, and sends the email
    final result = await ApiService.sendOtp(email: email);
    if (!mounted) return;
    setState(() => _sending = false);

    if (result['ok'] == true) {
      _showSnack('Code sent to $email', const Color(0xFFE8C547));
      Navigator.of(context).push(
        slideFromRightRoute(
          VerifyCodeScreen(
            email: email,
            expectedCode: '',
            useBackendVerify: true,
          ),
        ),
      );
    } else {
      _showSnack(
        S.of(context).failedToSendCodeLogin,
        Colors.white.withValues(alpha: 0.6),
      );
    }
  }

  void _continueWithPhone(String phone) async {
    if (!_isValidPhone(phone)) {
      _showSnack(
        S.of(context).invalidPhone,
        Colors.white.withValues(alpha: 0.6),
      );
      return;
    }

    final normalizedPhone = _normalizePhone(phone);
    setState(() => _sending = true);

    // Check if account already exists
    final exists = await ApiService.checkExists(normalizedPhone, role: 'rider');
    if (!mounted) return;
    if (exists) {
      setState(() => _sending = false);
      _showAccountExistsDialog(normalizedPhone);
      return;
    }

    final result = await SmsService.sendVerificationCode(
      toPhone: normalizedPhone,
    );

    if (!mounted) return;
    setState(() => _sending = false);

    if (result.ok) {
      if (result.code != null) {
        // Backend returned code directly (SMS unavailable) - show to user
        _showSnack('SMS unavailable. Use code: ${result.code}', const Color(0xFFE8C547));
        Navigator.of(context).push(
          slideFromRightRoute(
            VerifyCodeScreen(
              email: normalizedPhone,
              expectedCode: result.code!,
              useVerifyApi: false,
            ),
          ),
        );
      } else {
        // Twilio sent the SMS successfully
        _showSnack('Code sent to $normalizedPhone', const Color(0xFFE8C547));
        Navigator.of(context).push(
          slideFromRightRoute(
            VerifyCodeScreen(
              email: normalizedPhone,
              expectedCode: '',
              useVerifyApi: true,
            ),
          ),
        );
      }
    } else if (result.trialBlocked) {
      // Trial account can't send to this number — use local code for dev
      final devCode = _generateCode();
      debugPrint(
        '📱 DEV MODE — verification code for $normalizedPhone: $devCode',
      );
      _showSnack('Dev mode: check console for code', const Color(0xFFE8C547));
      Navigator.of(context).push(
        slideFromRightRoute(
          VerifyCodeScreen(
            email: normalizedPhone,
            expectedCode: devCode,
            useVerifyApi: false,
          ),
        ),
      );
    } else {
      // Backend OTP failed — generate local code and show it to user
      final fallbackCode = _generateCode();
      _showSnack(
        'SMS unavailable. Use code: $fallbackCode',
        const Color(0xFFE8C547),
      );
      Navigator.of(context).push(
        slideFromRightRoute(
          VerifyCodeScreen(
            email: normalizedPhone,
            expectedCode: fallbackCode,
            useVerifyApi: false,
          ),
        ),
      );
    }
  }

  void _showAccountExistsDialog(String identifier) {
    final c = AppColors.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Row(
          children: [
            const Icon(
              Icons.info_outline_rounded,
              color: Color(0xFFE8C547),
              size: 26,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                S.of(context).accountExists,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
        content: Text(
          S.of(context).accountAlreadyRegistered(_usePhone ? "phone number" : "email"),
          style: TextStyle(color: c.textSecondary, fontSize: 15, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              S.of(context).cancel,
              style: TextStyle(
                color: c.textTertiary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFE8C547),
              foregroundColor: const Color(0xFF1A1400),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
            ),
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pushReplacement(
                slideFromRightRoute(const LoginPasswordScreen()),
              );
            },
            child: Text(
              S.of(context).logInBtn,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _showSnack(String message, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: color,
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isAndroid = defaultTargetPlatform == TargetPlatform.android;
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;

    return Scaffold(
      backgroundColor: c.bg,
      body: DismissKeyboard(
        child: SafeArea(
          child: SingleChildScrollView(
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
              const SizedBox(height: 32),

              // ── Title ──
              Text(
                S.of(context).createAccountTitle,
                style: GoogleFonts.poppins(
                  fontSize: 32,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                  height: 1.15,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _usePhone
                    ? S.of(context).enterPhoneToSignUp
                    : S.of(context).enterEmailToSignUp,
                style: GoogleFonts.inter(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Input field (email or phone) ──
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
                child: Row(
                  children: [
                    if (_usePhone) ...[
                      Icon(
                        Icons.phone_outlined,
                        color: c.textTertiary,
                        size: 20,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        '+1',
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      Container(
                        width: 1,
                        height: 24,
                        margin: const EdgeInsets.symmetric(horizontal: 10),
                        color: c.border,
                      ),
                    ],
                    Expanded(
                      child: AutofillGroup(
                        child: TextField(
                          controller: _inputCtrl,
                          keyboardType: _usePhone
                              ? TextInputType.phone
                              : TextInputType.emailAddress,
                          inputFormatters: _usePhone
                              ? [
                                  FilteringTextInputFormatter.digitsOnly,
                                  LengthLimitingTextInputFormatter(10),
                                ]
                              : [],
                          autofillHints: _usePhone
                              ? const [AutofillHints.telephoneNumber]
                              : const [AutofillHints.email, AutofillHints.username],
                          style: TextStyle(color: c.textPrimary, fontSize: 16),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            hintText: _usePhone
                                ? '(000) 000-0000'
                                : S.of(context).emailAddressHint,
                            hintStyle: TextStyle(
                              color: c.textTertiary,
                              fontSize: 16,
                            ),
                            prefixIcon: _usePhone
                                ? null
                                : Icon(
                                    Icons.email_outlined,
                                    color: c.textTertiary,
                                    size: 20,
                                  ),
                            prefixIconConstraints: _usePhone
                                ? null
                                : const BoxConstraints(
                                    minWidth: 36,
                                    minHeight: 0,
                                  ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),

              // ── Continue button ──
              SizedBox(
                width: double.infinity,
                height: 56,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  decoration: BoxDecoration(
                    gradient: _canContinue
                        ? const LinearGradient(colors: [_gold, _goldLight])
                        : null,
                    color: _canContinue ? null : c.surface,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      foregroundColor: _canContinue
                          ? const Color(0xFF1A1400)
                          : c.textTertiary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: _canContinue ? _continueWithInput : null,
                    child: _sending
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: Color(0xFF1A1400),
                              strokeWidth: 2.5,
                            ),
                          )
                        : Text(
                            _usePhone
                                ? S.of(context).continueWithPhone
                                : S.of(context).continueWithEmail,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ── OR divider ──
              Row(
                children: [
                  Expanded(child: Divider(color: c.divider, thickness: 1)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      S.of(context).orDivider,
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
              const SizedBox(height: 20),

              // ── Toggle Phone / Email ──
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: c.textPrimary,
                    side: BorderSide(color: c.border, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  onPressed: _toggleInputMode,
                  icon: Icon(
                    _usePhone ? Icons.email_outlined : Icons.phone_outlined,
                    size: 22,
                    color: c.textPrimary,
                  ),
                  label: Text(
                    _usePhone ? S.of(context).continueWithEmail : S.of(context).continueWithPhone,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),

              // ── Google Sign-In ──
              if (isAndroid || isIOS) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.textPrimary,
                      side: BorderSide(color: c.border, width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: _socialLoading ? null : _signUpWithGoogle,
                    icon: SizedBox(
                      width: 22,
                      height: 22,
                      child: Image.asset(
                        'assets/images/google_logo.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                    label: Text(
                      S.of(context).continueWithGoogle,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],

              // ── Apple Sign-In (iOS only) ──
              if (isIOS) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: c.textPrimary,
                      side: BorderSide(color: c.border, width: 1.5),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    onPressed: _socialLoading ? null : _signUpWithApple,
                    icon: Icon(Icons.apple, size: 24, color: c.textPrimary),
                    label: Text(
                      S.of(context).continueWithApple,
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 28),

              // ── Sign in divider ──
              Row(
                children: [
                  Expanded(child: Divider(color: c.divider, thickness: 1)),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Text(
                      S.of(context).orDivider,
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
              const SizedBox(height: 20),

              // ── Sign in button ──
              SizedBox(
                width: double.infinity,
                height: 56,
                child: OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: _gold,
                    side: const BorderSide(color: _gold, width: 1.5),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                  onPressed: () => Navigator.of(context).push(
                    slideFromRightRoute(const LoginPasswordScreen()),
                  ),
                  child: Text(
                    S.of(context).signInBtn,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
              ),

              const SizedBox(height: 32),

              // ── Terms & Privacy ──
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Wrap(
                    alignment: WrapAlignment.center,
                    children: [
                      Text(
                        S.of(context).byContinuingAgree,
                        style: TextStyle(fontSize: 13, color: c.textTertiary),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          slideUpFadeRoute(const TermsConditionsScreen()),
                        ),
                        child: Text(
                          S.of(context).termsLink,
                          style: const TextStyle(
                            fontSize: 13,
                            color: _gold,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                            decorationColor: _gold,
                          ),
                        ),
                      ),
                      Text(
                        S.of(context).andConjunction,
                        style: TextStyle(fontSize: 13, color: c.textTertiary),
                      ),
                      GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          slideUpFadeRoute(const TermsConditionsScreen()),
                        ),
                        child: Text(
                          S.of(context).privacyPolicyLink,
                          style: const TextStyle(
                            fontSize: 13,
                            color: _gold,
                            fontWeight: FontWeight.w600,
                            decoration: TextDecoration.underline,
                            decorationColor: _gold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
      ),
    );
  }
}
