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
import '../widgets/neu_style.dart';
import '../services/sms_service.dart';
import '../services/google_auth_service.dart';
import '../services/apple_auth_service.dart';
import '../services/user_session.dart';
import 'login_password_screen.dart';
import 'verify_code_screen.dart';
import 'terms_conditions_screen.dart';
import 'privacy_policy_screen.dart';
import 'create_password_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> with SecureScreenMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  // ── Create-account form: everything is collected on this one page ──
  final _firstNameCtrl = TextEditingController();
  final _lastNameCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  bool _acceptTerms = false;
  bool _acceptPrivacy = false;
  bool _canContinue = false;
  bool _sending = false;

  @override
  void initState() {
    super.initState();
    _firstNameCtrl.addListener(_validateForm);
    _lastNameCtrl.addListener(_validateForm);
    _phoneCtrl.addListener(_validateForm);
    _emailCtrl.addListener(_validateForm);
  }

  @override
  void dispose() {
    _firstNameCtrl.dispose();
    _lastNameCtrl.dispose();
    _phoneCtrl.dispose();
    _emailCtrl.dispose();
    super.dispose();
  }

  void _validateForm() {
    final ok = _firstNameCtrl.text.trim().isNotEmpty &&
        _lastNameCtrl.text.trim().isNotEmpty &&
        _isValidPhone(_phoneCtrl.text) &&
        _isValidEmail(_emailCtrl.text) &&
        _acceptTerms &&
        _acceptPrivacy;
    if (ok != _canContinue) setState(() => _canContinue = ok);
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

  /// Single create-account flow: all fields were collected on this page,
  /// both consents are checked — verify the phone via SMS OTP and carry the
  /// rider's data through the rest of the onboarding chain.
  void _continue() async {
    if (_sending || !_canContinue) return;

    final firstName = _firstNameCtrl.text.trim();
    final lastName = _lastNameCtrl.text.trim();
    final email = _emailCtrl.text.trim();
    final normalizedPhone = _normalizePhone(_phoneCtrl.text);

    setState(() => _sending = true);

    // Neither the phone nor the email may belong to an existing account.
    var exists = await ApiService.checkExists(normalizedPhone, role: 'rider');
    if (!mounted) return;
    if (exists) {
      setState(() => _sending = false);
      _showAccountExistsDialog(normalizedPhone);
      return;
    }
    exists = await ApiService.checkExists(email, role: 'rider');
    if (!mounted) return;
    if (exists) {
      setState(() => _sending = false);
      _showAccountExistsDialog(email);
      return;
    }

    final result = await SmsService.sendVerificationCode(
      toPhone: normalizedPhone,
    );

    if (!mounted) return;
    setState(() => _sending = false);

    VerifyCodeScreen verifyScreen(String code, bool useApi) => VerifyCodeScreen(
          email: normalizedPhone,
          expectedCode: code,
          useVerifyApi: useApi,
          firstName: firstName,
          lastName: lastName,
          contactEmail: email,
          contactPhone: normalizedPhone,
        );

    if (result.ok) {
      if (result.code != null) {
        // Backend returned code directly (SMS unavailable) - show to user
        _showSnack('SMS unavailable. Use code: ${result.code}', const Color(0xFFE8C547));
        Navigator.of(context).push(
          slideFromRightRoute(verifyScreen(result.code!, false)),
        );
      } else {
        // Twilio sent the SMS successfully
        _showSnack('Code sent to $normalizedPhone', const Color(0xFFE8C547));
        Navigator.of(context).push(
          slideFromRightRoute(verifyScreen('', true)),
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
        slideFromRightRoute(verifyScreen(devCode, false)),
      );
    } else {
      // Backend OTP failed — generate local code and show it to user
      final fallbackCode = _generateCode();
      _showSnack(
        'SMS unavailable. Use code: $fallbackCode',
        const Color(0xFFE8C547),
      );
      Navigator.of(context).push(
        slideFromRightRoute(verifyScreen(fallbackCode, false)),
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
          S.of(context).accountAlreadyRegistered(identifier.contains('@') ? "email" : "phone number"),
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

              // ── Back button — pressed neumorphic well ──
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
                S.of(context).createAccountSubtitle,
                style: GoogleFonts.inter(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Form fields — pressed neumorphic wells ──
              _neuTextField(
                c,
                controller: _firstNameCtrl,
                hint: S.of(context).firstName,
                icon: Icons.person_outline_rounded,
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              _neuTextField(
                c,
                controller: _lastNameCtrl,
                hint: S.of(context).lastName,
                icon: Icons.person_outline_rounded,
                textCapitalization: TextCapitalization.words,
              ),
              const SizedBox(height: 12),
              _neuTextField(
                c,
                controller: _phoneCtrl,
                hint: S.of(context).phoneNumber,
                icon: Icons.phone_outlined,
                keyboardType: TextInputType.phone,
                inputFormatters: [UsPhoneInputFormatter()],
                prefix: '+1',
              ),
              const SizedBox(height: 12),
              _neuTextField(
                c,
                controller: _emailCtrl,
                hint: S.of(context).email,
                icon: Icons.email_outlined,
                keyboardType: TextInputType.emailAddress,
              ),
              const SizedBox(height: 22),

              // ── Consent checkboxes (both required) ──
              _consentRow(
                c,
                value: _acceptTerms,
                onChanged: (v) {
                  setState(() => _acceptTerms = v);
                  _validateForm();
                },
                text: S.of(context).acceptTermsDocuments,
                linkText: S.of(context).termsLink,
                onLinkTap: () => Navigator.of(context).push(
                  slideUpFadeRoute(const TermsConditionsScreen()),
                ),
              ),
              const SizedBox(height: 12),
              _consentRow(
                c,
                value: _acceptPrivacy,
                onChanged: (v) {
                  setState(() => _acceptPrivacy = v);
                  _validateForm();
                },
                text: S.of(context).acceptPrivacyData,
                linkText: S.of(context).privacyPolicyLink,
                onLinkTap: () => Navigator.of(context).push(
                  slideUpFadeRoute(const PrivacyPolicyScreen()),
                ),
              ),
              const SizedBox(height: 26),

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
                    color: _canContinue ? null : neuPressed,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      foregroundColor: _canContinue
                          ? const Color(0xFF1A1400)
                          : c.textTertiary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                    onPressed: _canContinue ? _continue : null,
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
                            S.of(context).continueBtn,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ),
              const SizedBox(height: 24),

              // ── OR divider (only when social buttons are shown) ──
              if (isAndroid || isIOS) ...[
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
              ],

              // ── Google Sign-In ──
              if (isAndroid || isIOS) ...[
                SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: GestureDetector(
                    onTap: _socialLoading ? null : _signUpWithGoogle,
                    child: Container(
                      decoration: neuBox(radius: 16, pressed: true),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
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
                            S.of(context).continueWithGoogle,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: c.textPrimary,
                            ),
                          ),
                        ],
                      ),
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
                  child: GestureDetector(
                    onTap: _socialLoading ? null : _signUpWithApple,
                    child: Container(
                      decoration: neuBox(radius: 16, pressed: true),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.apple, size: 24, color: c.textPrimary),
                          const SizedBox(width: 10),
                          Text(
                            S.of(context).continueWithApple,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: c.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],

              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
      ),
    );
  }

  /// Neumorphic pressed-well text field used by the create-account form.
  Widget _neuTextField(
    AppColors c, {
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    TextCapitalization textCapitalization = TextCapitalization.none,
    String? prefix,
  }) {
    return Container(
      decoration: neuBox(radius: 16, pressed: true),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: c.textTertiary, size: 20),
          const SizedBox(width: 10),
          if (prefix != null) ...[
            Text(
              prefix,
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
              color: c.divider,
            ),
          ],
          Expanded(
            child: TextField(
              controller: controller,
              keyboardType: keyboardType,
              inputFormatters: inputFormatters,
              textCapitalization: textCapitalization,
              style: TextStyle(color: c.textPrimary, fontSize: 16),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Required-consent row: neumorphic checkbox + rich text with a gold link.
  Widget _consentRow(
    AppColors c, {
    required bool value,
    required ValueChanged<bool> onChanged,
    required String text,
    required String linkText,
    required VoidCallback onLinkTap,
  }) {
    return GestureDetector(
      onTap: () => onChanged(!value),
      behavior: HitTestBehavior.opaque,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: 24,
            height: 24,
            margin: const EdgeInsets.only(top: 1),
            decoration: value
                ? BoxDecoration(
                    color: _gold,
                    borderRadius: BorderRadius.circular(8),
                  )
                : neuBox(radius: 8, pressed: true),
            child: value
                ? const Icon(Icons.check_rounded, size: 17, color: Colors.black)
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Wrap(
              children: [
                Text(
                  '$text ',
                  style: TextStyle(
                    fontSize: 13,
                    color: c.textSecondary,
                    height: 1.4,
                  ),
                ),
                GestureDetector(
                  onTap: onLinkTap,
                  child: Text(
                    linkText,
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
        ],
      ),
    );
  }
}

/// Formats US phone input as `(XXX) XXX-XXXX` while typing.
/// Digits are capped at 10; non-digit characters are ignored.
/// Validation/normalization elsewhere strips the punctuation, so
/// `_isValidPhone` / `_normalizePhone` keep working unchanged.
class UsPhoneInputFormatter extends TextInputFormatter {
  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final digits = newValue.text.replaceAll(RegExp(r'\D'), '');
    final capped = digits.length > 10 ? digits.substring(0, 10) : digits;

    final buf = StringBuffer();
    for (var i = 0; i < capped.length; i++) {
      if (i == 0) buf.write('(');
      if (i == 3) buf.write(') ');
      if (i == 6) buf.write('-');
      buf.write(capped[i]);
    }
    final formatted = buf.toString();
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: formatted.length),
    );
  }
}
