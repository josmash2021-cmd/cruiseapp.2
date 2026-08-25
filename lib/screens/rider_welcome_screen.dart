import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/apple_auth_service.dart';
import '../services/sms_service.dart';
import '../services/user_session.dart';
import '../utils/phone_format.dart';
import 'find_account_screen.dart';
import 'home_screen.dart';
import 'rider_name_screen.dart';
import 'verify_code_screen.dart';

/// Rider phone onboarding/login — step 1 ("Welcome to Cruise", Lyft-style).
///
/// US-only phone entry (+1 fixed prefix, live mask). `Continue with Phone`
/// sends the OTP via the backend and pushes the shared [VerifyCodeScreen];
/// verification there goes through `POST /auth/phone-login` with
/// `role: 'rider'` (see [_verifyAndLogin]), which both validates the code
/// and creates/logs the session in one call.
///
/// Routing: existing account → [HomeScreen] (the home boot already handles
/// the once-per-process permissions page, so nothing extra here); brand-new
/// account (`is_new_user`) → [RiderNameScreen] → email → home. Below the
/// divider, "Continue with Apple" reuses the existing social auth
/// (`AppleAuthService` → `POST /auth/social`) and routes the same way by
/// account state; "New number? Find your account." opens the email-based
/// recovery flow ([FindAccountScreen]); the legacy email+password login
/// stays reachable through the "Sign in with email" link at the bottom;
/// the KYC gate at trip request is untouched.
class RiderWelcomeScreen extends StatefulWidget {
  const RiderWelcomeScreen({super.key});

  @override
  State<RiderWelcomeScreen> createState() => _RiderWelcomeScreenState();
}

class _RiderWelcomeScreenState extends State<RiderWelcomeScreen> {
  static const _navy = Color(0xFF14141A);
  static const _gold = Color(0xFFE8C547);

  final _phoneCtrl = TextEditingController();
  final _phoneFocus = FocusNode();
  bool _canNext = false;
  bool _sending = false;
  bool _appleLoading = false;

  /// Result of the successful phone-login, captured by the customVerify
  /// closure so the success callback can route by `is_new_user`.
  Map<String, dynamic>? _loginResult;

  @override
  void initState() {
    super.initState();
    _phoneCtrl.addListener(_validate);
    _phoneFocus.addListener(() => setState(() {}));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _phoneFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _phoneCtrl.dispose();
    _phoneFocus.dispose();
    super.dispose();
  }

  void _validate() {
    final ok = usPhoneDigits(_phoneCtrl.text).length == 10;
    if (ok != _canNext) setState(() => _canNext = ok);
  }

  Future<void> _next() async {
    if (!_canNext || _sending) return;
    final e164 = usPhoneToE164(_phoneCtrl.text);
    if (e164.isEmpty) return;
    setState(() => _sending = true);

    final result = await SmsService.sendVerificationCode(toPhone: e164);
    if (!mounted) return;
    setState(() => _sending = false);

    if (!result.ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFB3261E),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          content: Text(
            S.of(context).failedToSendCode,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      );
      return;
    }

    Navigator.of(context).push(
      onboardingFadeSlideRoute(
        VerifyCodeScreen(
          email: formatUsPhone(e164),
          expectedCode: '',
          useVerifyApi: true,
          customVerify: (code) => _verifyAndLogin(e164, code),
          onCustomVerified: _onLoggedIn,
        ),
      ),
    );
  }

  /// Custom verify hook for the code screen: the backend checks the OTP and
  /// returns a full session in one shot. Returns null on success, or the
  /// error message the code screen should render (401 bad code, 429 limit).
  Future<String?> _verifyAndLogin(String phone, String code) async {
    final s = S.of(context);
    try {
      _loginResult =
          await ApiService.phoneLogin(phone: phone, code: code, role: 'rider');
      return null;
    } on ApiException catch (e) {
      if (e.statusCode == 401) return s.invalidCode;
      if (e.statusCode == 429) return s.tooManyAttempts;
      return e.message;
    } catch (_) {
      return s.connectionError;
    }
  }

  /// After a successful phone-login: persist the session locally, then
  /// route by account state — new rider collects name/email first, existing
  /// rider goes straight home.
  Future<void> _onLoggedIn() async {
    final data = _loginResult;
    if (data == null) return;
    final user = data['user'] as Map<String, dynamic>? ?? const {};
    final isNewUser = data['is_new_user'] == true;

    await UserSession.saveUser(
      firstName: user['first_name'] ?? '',
      lastName: user['last_name'] ?? '',
      email: user['email'] ?? '',
      phone: user['phone'] ?? '',
      photoUrl: user['photo_url'] as String?,
      userId: (user['id'] is num)
          ? (user['id'] as num).toInt()
          : int.tryParse(user['id']?.toString() ?? ''),
      role: 'rider',
    );
    await UserSession.saveMode('rider');
    await UserSession.initPhotoNotifier();
    if (!mounted) return;

    if (isNewUser) {
      Navigator.of(context).push(
        onboardingFadeSlideRoute(RiderNameScreen(user: user)),
      );
      return;
    }
    Navigator.of(context).pushAndRemoveUntil(
      smoothFadeRoute(const HomeScreen(), durationMs: 600),
      (_) => false,
    );
  }

  /// "Continue with Apple" — reuses the existing social auth mechanism
  /// (`SignInWithApple` → idToken → `POST /auth/social`). Brand-new Apple
  /// accounts (no phone yet) collect their name first; everyone else goes
  /// straight home. The session itself is persisted by [AppleAuthService].
  Future<void> _appleSignIn() async {
    if (_appleLoading) return;
    setState(() => _appleLoading = true);
    try {
      final data =
          await AppleAuthService.instance.signInWithResult(role: 'rider');
      if (!mounted) return;
      setState(() => _appleLoading = false);
      if (data == null) return; // cancelled

      final user = data['user'] as Map<String, dynamic>? ?? const {};
      await UserSession.saveMode('rider');
      if (!mounted) return;

      final hasPhone = (user['phone'] ?? '').toString().isNotEmpty;
      if (!hasPhone) {
        Navigator.of(context).push(
          onboardingFadeSlideRoute(RiderNameScreen(user: user)),
        );
        return;
      }
      Navigator.of(context).pushAndRemoveUntil(
        smoothFadeRoute(const HomeScreen(), durationMs: 600),
        (_) => false,
      );
    } catch (_) {
      if (!mounted) return;
      setState(() => _appleLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFB3261E),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          content: Text(
            S.of(context).appleSignInFailed,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;

    return Scaffold(
      // Fields stay put; only the CTA floats above the keyboard.
      resizeToAvoidBottomInset: false,
      backgroundColor: _navy,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            // ── Top bar — flat back arrow ──
            Padding(
              padding: EdgeInsets.only(top: pad.top + 8, left: 16, right: 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: const SizedBox(
                      width: 40,
                      height: 40,
                      child: Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                        size: 24,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                physics: const ClampingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 32),
                    Text(
                      S.of(context).welcomeToCruiseTitle,
                      style: GoogleFonts.poppins(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: Colors.white,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      S.of(context).enterNumberToSignUp,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ),
                    const SizedBox(height: 40),

                    // ── Big phone field: 🇺🇸 +1 | masked number | X ──
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: _phoneFocus.hasFocus
                              ? _gold
                              : Colors.white.withValues(alpha: 0.14),
                          width: _phoneFocus.hasFocus ? 1.6 : 1,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          const Text('🇺🇸', style: TextStyle(fontSize: 22)),
                          const SizedBox(width: 8),
                          const Text(
                            '+1',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          Container(
                            width: 1,
                            height: 26,
                            margin: const EdgeInsets.symmetric(horizontal: 12),
                            color: Colors.white.withValues(alpha: 0.18),
                          ),
                          Expanded(
                            child: TextField(
                              controller: _phoneCtrl,
                              focusNode: _phoneFocus,
                              keyboardType: TextInputType.phone,
                              autofillHints: const [
                                AutofillHints.telephoneNumberNational,
                              ],
                              inputFormatters: const [UsPhoneFormatter()],
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w600,
                                letterSpacing: 0.5,
                              ),
                              cursorColor: _gold,
                              decoration: InputDecoration(
                                border: InputBorder.none,
                                hintText: S.of(context).usPhoneHint,
                                hintStyle: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.3),
                                  fontSize: 20,
                                  fontWeight: FontWeight.w400,
                                ),
                              ),
                            ),
                          ),
                          if (_phoneCtrl.text.isNotEmpty)
                            GestureDetector(
                              onTap: () => _phoneCtrl.clear(),
                              child: Icon(
                                Icons.cancel_rounded,
                                color: Colors.white.withValues(alpha: 0.45),
                                size: 22,
                              ),
                            ),
                        ],
                      ),
                    ),

                    // ── OR divider + Apple + account recovery ──
                    if (AppleAuthService.instance.isAvailable) ...[
                      const SizedBox(height: 28),
                      Row(
                        children: [
                          Expanded(
                            child: Container(
                              height: 1,
                              color: Colors.white.withValues(alpha: 0.16),
                            ),
                          ),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 16),
                            child: Text(
                              S.of(context).orDivider,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.5,
                                color: Colors.white.withValues(alpha: 0.45),
                              ),
                            ),
                          ),
                          Expanded(
                            child: Container(
                              height: 1,
                              color: Colors.white.withValues(alpha: 0.16),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 28),
                      GestureDetector(
                        onTap: _appleLoading ? null : _appleSignIn,
                        child: Container(
                          width: double.infinity,
                          height: 58,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(18),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.35),
                              width: 1.4,
                            ),
                          ),
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              if (_appleLoading)
                                const SizedBox(
                                  width: 22,
                                  height: 22,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.white,
                                  ),
                                )
                              else ...[
                                const Icon(
                                  Icons.apple,
                                  size: 24,
                                  color: Colors.white,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  S.of(context).continueWithApple,
                                  style: const TextStyle(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: Colors.white,
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 28),
                    Center(
                      child: GestureDetector(
                        onTap: () => Navigator.of(context).push(
                          onboardingFadeSlideRoute(
                            const FindAccountScreen(),
                          ),
                        ),
                        behavior: HitTestBehavior.opaque,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(vertical: 8),
                          child: Text(
                            S.of(context).newNumberFindAccount,
                            style: const TextStyle(
                              fontSize: 15,
                              fontWeight: FontWeight.w700,
                              color: _gold,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),

            // ── Continue with Phone — big gold, above keyboard, safe area ──
            Padding(
              padding: EdgeInsets.fromLTRB(
                28,
                8,
                28,
                pad.bottom + MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: GestureDetector(
                onTap: _canNext && !_sending ? _next : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  height: 58,
                  decoration: BoxDecoration(
                    color: _canNext
                        ? _gold
                        : _gold.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.center,
                  child: _sending
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.black,
                          ),
                        )
                      : Text(
                          S.of(context).continueWithPhone,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: _canNext
                                ? Colors.black
                                : Colors.black.withValues(alpha: 0.45),
                          ),
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
