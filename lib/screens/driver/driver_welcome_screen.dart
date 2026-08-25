import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/sms_service.dart';
import '../../services/user_session.dart';
import '../../utils/phone_format.dart';
import '../verify_code_screen.dart';
import 'driver_home_screen.dart';
import 'driver_name_screen.dart';
import 'driver_pending_review_screen.dart';
import 'onboarding/driver_todo_screen.dart';

/// Driver phone onboarding — step 1 ("Welcome aboard", Lyft-style).
///
/// US-only phone entry (+1 fixed prefix, live mask). `Next` sends the OTP
/// via the backend and pushes the shared [VerifyCodeScreen]; verification
/// there goes through `POST /auth/phone-login` (see [_verifyAndLogin]),
/// which both validates the code and creates/logs the session in one call.
class DriverWelcomeScreen extends StatefulWidget {
  const DriverWelcomeScreen({super.key});

  /// Routing by driver account state — shared by every driver sign-in path:
  /// approved → home; pending → the to-do hub (which already shows
  /// "In review" — no more pending-review prison); rejected → pending
  /// review (navigable legacy status screen); never-registered
  /// (`none`/anything else) → the Phase 2 to-do hub (the legacy
  /// DriverSignupScreen stays for legacy users).
  static Future<void> routeExistingDriver(
    BuildContext context,
    Map<String, dynamic> user,
  ) async {
    final vStatus = user['verification_status'] as String? ?? 'none';
    final isVerified = user['is_verified'] == true || user['isVerified'] == true;
    final accountStatus = (user['status'] as String? ?? '').toLowerCase().trim();
    final s = vStatus.toLowerCase().trim();
    final approved = isVerified ||
        {'approved', 'active', 'online', 'clear', 'verified'}.contains(s) ||
        {'approved', 'active', 'online', 'clear', 'verified'}
            .contains(accountStatus);

    if (approved) {
      await LocalDataService.setDriverApprovalStatus('approved');
    } else if (s == 'pending' || s == 'rejected') {
      await LocalDataService.setDriverApprovalStatus(s);
    }
    if (!context.mounted) return;

    if (approved) {
      Navigator.of(context).pushAndRemoveUntil(
        slideFromRightRoute(const DriverHomeScreen()),
        (_) => false,
      );
    } else if (s == 'pending') {
      Navigator.of(context).pushAndRemoveUntil(
        onboardingFadeSlideRoute(const DriverTodoScreen()),
        (_) => false,
      );
    } else if (s == 'rejected') {
      Navigator.of(context).pushAndRemoveUntil(
        slideFromRightRoute(const DriverPendingReviewScreen()),
        (_) => false,
      );
    } else {
      Navigator.of(context).pushAndRemoveUntil(
        onboardingFadeSlideRoute(const DriverTodoScreen()),
        (_) => false,
      );
    }
  }

  @override
  State<DriverWelcomeScreen> createState() => _DriverWelcomeScreenState();
}

class _DriverWelcomeScreenState extends State<DriverWelcomeScreen> {
  static const _navy = Color(0xFF14141A);
  static const _gold = Color(0xFFE8C547);

  final _phoneCtrl = TextEditingController();
  final _phoneFocus = FocusNode();
  bool _canNext = false;
  bool _sending = false;

  /// Result of the successful phone-login, captured by the customVerify
  /// closure so the success callback can route by `is_new_user` / status.
  Map<String, dynamic>? _loginResult;

  @override
  void initState() {
    super.initState();
    _phoneCtrl.addListener(_validate);
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
      _loginResult = await ApiService.phoneLogin(phone: phone, code: code);
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
  /// route by account state (same rules as the password login screen).
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
      role: 'driver',
    );
    await UserSession.saveMode('driver');
    await UserSession.initPhotoNotifier();
    if (!mounted) return;

    if (isNewUser) {
      Navigator.of(context).push(
        onboardingFadeSlideRoute(DriverNameScreen(user: user)),
      );
      return;
    }
    await DriverWelcomeScreen.routeExistingDriver(context, user);
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
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const SizedBox(height: 32),
                    Text(
                      S.of(context).welcomeAboard,
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
                          color: _canNext
                              ? _gold
                              : Colors.white.withValues(alpha: 0.14),
                          width: _canNext ? 1.6 : 1,
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
                  ],
                ),
              ),
            ),

            // ── Next — big gold, above the keyboard, safe area ──
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
                          S.of(context).next,
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
