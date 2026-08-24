import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/user_session.dart';
import 'home_screen.dart';
import 'verify_code_screen.dart';

/// "Find your account" — account recovery for riders whose number changed.
///
/// Enter the email on the account → we confirm it exists (inline error
/// otherwise) → `/auth/send-otp` emails a code → [VerifyCodeScreen] redeems
/// it through `POST /auth/email-login` (valid code IS the credential — the
/// endpoint never creates accounts, unknown email is a 404) → session +
/// [HomeScreen] with a soft prompt to update the phone in the profile.
class FindAccountScreen extends StatefulWidget {
  const FindAccountScreen({super.key});

  @override
  State<FindAccountScreen> createState() => _FindAccountScreenState();
}

class _FindAccountScreenState extends State<FindAccountScreen> {
  static const _navy = Color(0xFF0A1128);
  static const _gold = Color(0xFFE8C547);

  final _emailCtrl = TextEditingController();
  final _emailFocus = FocusNode();
  bool _canNext = false;
  bool _sending = false;
  String? _errorText;

  /// Result of the successful email-login, captured by the customVerify
  /// closure so the success callback can persist the session.
  Map<String, dynamic>? _loginResult;

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_validate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _emailFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    _emailFocus.dispose();
    super.dispose();
  }

  void _validate() {
    final text = _emailCtrl.text.trim();
    final ok = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text);
    if (ok != _canNext || _errorText != null) {
      setState(() {
        _canNext = ok;
        _errorText = null; // clear error on typing
      });
    }
  }

  Future<void> _next() async {
    if (!_canNext || _sending) return;
    final email = _emailCtrl.text.trim().toLowerCase();
    setState(() => _sending = true);

    bool exists;
    try {
      exists = await ApiService.checkExists(email, role: 'rider');
    } catch (_) {
      exists = false;
      if (!mounted) return;
      setState(() {
        _sending = false;
        _errorText = S.of(context).connectionError;
      });
      return;
    }
    if (!mounted) return;

    if (!exists) {
      setState(() {
        _sending = false;
        _errorText = S.of(context).noAccountFoundWithEmail;
      });
      return;
    }

    try {
      final otpResult = await ApiService.sendOtp(email: email);
      if (!mounted) return;
      if (otpResult['ok'] != true) {
        setState(() => _sending = false);
        _showSnack(S.of(context).failedToSendCode);
        return;
      }
    } catch (_) {
      if (!mounted) return;
      setState(() => _sending = false);
      _showSnack(S.of(context).failedToSendCode);
      return;
    }

    setState(() => _sending = false);
    Navigator.of(context).push(
      onboardingFadeSlideRoute(
        VerifyCodeScreen(
          email: email,
          expectedCode: '',
          customVerify: (code) => _verifyAndLogin(email, code),
          onCustomVerified: _onLoggedIn,
        ),
      ),
    );
  }

  /// Custom verify hook for the code screen: the backend checks the OTP
  /// against the email-channel store and returns a full session in one
  /// shot. Returns null on success, or the error message to render.
  Future<String?> _verifyAndLogin(String email, String code) async {
    final s = S.of(context);
    try {
      _loginResult =
          await ApiService.emailLogin(email: email, code: code, role: 'rider');
      return null;
    } on ApiException catch (e) {
      if (e.statusCode == 401) return s.invalidCode;
      if (e.statusCode == 404) return s.noAccountFoundWithEmail;
      if (e.statusCode == 429) return s.tooManyAttempts;
      return e.message;
    } catch (_) {
      return s.connectionError;
    }
  }

  /// After a successful email-login: persist the session, go home, and
  /// softly suggest updating the phone number in the profile.
  Future<void> _onLoggedIn() async {
    final data = _loginResult;
    if (data == null) return;
    final user = data['user'] as Map<String, dynamic>? ?? const {};

    await UserSession.saveUser(
      firstName: user['first_name'] ?? '',
      lastName: user['last_name'] ?? '',
      email: user['email'] ?? '',
      phone: user['phone'] as String?,
      photoUrl: user['photo_url'] as String?,
      userId: (user['id'] is num)
          ? (user['id'] as num).toInt()
          : int.tryParse(user['id']?.toString() ?? ''),
      role: 'rider',
    );
    await UserSession.saveMode('rider');
    await UserSession.initPhotoNotifier();
    if (!mounted) return;

    Navigator.of(context).pushAndRemoveUntil(
      smoothFadeRoute(const HomeScreen(), durationMs: 600),
      (_) => false,
    );
    // Soft suggestion (not a gate) — the account works as-is.
    Future.delayed(const Duration(milliseconds: 700), () {
      if (!mounted) return;
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          duration: const Duration(seconds: 5),
          content: Text(
            S.of(context).updatePhoneInProfile,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
        ),
      );
    });
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: const Color(0xFFB3261E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        content: Text(
          message,
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final hasError = _errorText != null;

    return Scaffold(
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
                      S.of(context).findYourAccountTitle,
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
                      S.of(context).findYourAccountSubtitle,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ),
                    const SizedBox(height: 40),

                    // ── Email field ──
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: hasError
                              ? const Color(0xFFB3261E)
                              : _emailFocus.hasFocus
                                  ? _gold
                                  : Colors.white.withValues(alpha: 0.14),
                          width: (_emailFocus.hasFocus || hasError) ? 1.6 : 1,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.mail_outline_rounded,
                            color: Colors.white.withValues(alpha: 0.5),
                            size: 22,
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Focus(
                              onFocusChange: (_) => setState(() {}),
                              child: TextField(
                                controller: _emailCtrl,
                                focusNode: _emailFocus,
                                keyboardType: TextInputType.emailAddress,
                                autocorrect: false,
                                autofillHints: const [AutofillHints.email],
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 18,
                                  fontWeight: FontWeight.w600,
                                ),
                                cursorColor: _gold,
                                decoration: InputDecoration(
                                  border: InputBorder.none,
                                  hintText: S.of(context).emailAddressHint,
                                  hintStyle: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.3),
                                    fontSize: 18,
                                    fontWeight: FontWeight.w400,
                                  ),
                                ),
                              ),
                            ),
                          ),
                          if (_emailCtrl.text.isNotEmpty)
                            GestureDetector(
                              onTap: () => _emailCtrl.clear(),
                              child: Icon(
                                Icons.cancel_rounded,
                                color: Colors.white.withValues(alpha: 0.45),
                                size: 22,
                              ),
                            ),
                        ],
                      ),
                    ),
                    if (hasError)
                      Padding(
                        padding: const EdgeInsets.only(top: 10, left: 4),
                        child: Text(
                          _errorText!,
                          style: const TextStyle(
                            color: Color(0xFFFF8A80),
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
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
