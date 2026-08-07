import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/haptic_service.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../utils/phone_format.dart';
import '../widgets/neu_style.dart';
import 'login_password_screen.dart';

/// Forgot password — one identifier field, a six-digit code by email or
/// SMS, then a new password. Three steps inside one screen, cross-faded.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _errorRed = Color(0xFFFF5252);
  static const _successGreen = Color(0xFF66BB6A);

  final _identCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  int _step = 0; // 0 = identifier, 1 = code, 2 = new password
  bool _loading = false;
  String? _errorText;

  /// What the server answered for step 0: "email", "sms" or "none".
  String _method = '';
  String _masked = '';

  /// Identifier exactly as resolved for the backend (E.164 for phones).
  String _identifier = '';

  @override
  void dispose() {
    _identCtrl.dispose();
    _codeCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  /// Phone mode as soon as the first character is a digit or '+' — before
  /// that (or for letters/'@') the field behaves as a plain email field.
  bool get _isPhone {
    final t = _identCtrl.text.trimLeft();
    if (t.isEmpty) return false;
    final first = t[0];
    return (first.codeUnitAt(0) >= 48 && first.codeUnitAt(0) <= 57) ||
        first == '+';
  }

  String get _phoneDigits {
    var d = _identCtrl.text.replaceAll(RegExp(r'\D'), '');
    if (d.startsWith('1') && d.length > 10) d = d.substring(1);
    return d;
  }

  bool get _canSubmitStep0 {
    if (_identCtrl.text.trim().isEmpty) return false;
    if (_isPhone) return _phoneDigits.length == 10;
    return _identCtrl.text.trim().contains('@');
  }

  bool get _canSubmitStep1 => _codeCtrl.text.trim().length == 6;

  // ── Password rules (same set the backend enforces) ──
  bool get _hasLen => _passCtrl.text.length >= 8;
  bool get _hasNumber => _passCtrl.text.contains(RegExp(r'[0-9]'));
  bool get _hasUpper => _passCtrl.text.contains(RegExp(r'[A-Z]'));
  bool get _hasSpecial =>
      _passCtrl.text.contains(RegExp(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]'));
  bool get _matches =>
      _passCtrl.text.isNotEmpty && _passCtrl.text == _confirmCtrl.text;
  bool get _canSubmitStep2 =>
      _hasLen && _hasNumber && _hasUpper && _hasSpecial && _matches;

  /// The sentence the server wrote, with nothing of ours around it.
  ///
  /// This used to be `toString().replaceFirst('Exception: ', '')`, which
  /// never matched an [ApiException] — its toString is
  /// `ApiException(400): …` — so people trying to reset their password were
  /// shown the words "ApiException(400)" above the button.
  String _errMsg(Object e) {
    if (e is ApiException) return e.message;
    return e.toString().replaceFirst(RegExp(r'^\w*Exception:?\s*'), '');
  }

  Future<void> _sendCode() async {
    final identifier =
        _isPhone ? '+1$_phoneDigits' : _identCtrl.text.trim();
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      final res = await ApiService.sendPasswordResetCodePublic(identifier);
      if (!mounted) return;
      final method = (res['method'] as String?) ?? 'none';
      // "none" is how the backend says it found no account for what was
      // typed — it answers with the same shape as a success so the endpoint
      // itself gives nothing away. Product call: tell the user plainly
      // instead of sending them to a code screen where no code will ever
      // arrive. Stay on this step and show it in red under the field.
      if (method == 'none') {
        HapticService.mediumImpact();
        setState(() {
          _loading = false;
          _errorText = S.of(context).identifierNotFound;
        });
        return;
      }
      HapticService.mediumImpact();
      setState(() {
        _loading = false;
        _identifier = identifier;
        _method = method;
        _masked = (res['masked'] as String?) ?? '';
        _step = 1;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = _errMsg(e);
      });
    }
  }

  /// Checks the code before letting them pick a password.
  ///
  /// This button used to just move to the next step; the code was only ever
  /// tested inside the confirm call, so "That code is not right" appeared
  /// under the new password field — two screens away from the thing that was
  /// wrong. Now the answer lands under the code.
  Future<void> _verifyCode() async {
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      await ApiService.verifyPasswordResetCodePublic(
        identifier: _identifier,
        code: _codeCtrl.text.trim(),
      );
      if (!mounted) return;
      HapticService.mediumImpact();
      setState(() {
        _loading = false;
        _step = 2;
      });
    } catch (e) {
      if (!mounted) return;
      HapticService.mediumImpact();
      setState(() {
        _loading = false;
        _errorText = _errMsg(e);
      });
    }
  }

  Future<void> _confirm() async {
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      await ApiService.confirmPasswordResetPublic(
        identifier: _identifier,
        code: _codeCtrl.text.trim(),
        newPassword: _passCtrl.text,
      );
      if (!mounted) return;
      HapticService.mediumImpact();
      final s = S.of(context);
      // The messenger lives above the navigator, so this snack survives the
      // route swap and lands on the login screen.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(s.resetSuccess),
          backgroundColor: const Color(0xFF2E7D32),
          behavior: SnackBarBehavior.floating,
        ),
      );
      // Home, not back: swap this route (and the login beneath it) for a
      // fresh login through a slow fade — no abrupt pop after success.
      Navigator.of(context).pushAndRemoveUntil(
        smoothFadeRoute(const LoginPasswordScreen(), durationMs: 600),
        (route) => route.isFirst,
      );
    } catch (e) {
      if (!mounted) return;
      final msg = _errMsg(e);
      setState(() {
        _loading = false;
        _errorText = msg;
        // The code is verified a step earlier now, so reaching here with a
        // code complaint means it expired or was burned in between. Send
        // them back to the field it is about rather than showing it under
        // the password, which is the whole point of the earlier check.
        if (_isCodeProblem(msg)) _step = 1;
      });
    }
  }

  /// Whether this server message is about the code rather than the password.
  ///
  /// Matched on the server's own sentences. Anything unrecognised stays on
  /// the password step, because moving someone away from a message they
  /// could have acted on is worse than leaving them where they are.
  bool _isCodeProblem(String msg) {
    final m = msg.toLowerCase();
    return m.contains('code');
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.symmetric(horizontal: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SizedBox(height: 12),
              // ── Back ──
              GestureDetector(
                onTap: () {
                  if (_step > 0) {
                    setState(() {
                      _step -= 1;
                      _errorText = null;
                    });
                  } else {
                    Navigator.pop(context);
                  }
                },
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

              // ── Title + subtitle per step ──
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 250),
                child: _step == 0
                    ? _heading(
                        key: 'h0',
                        title: s.forgotPasswordTitle,
                        subtitle: s.forgotSubtitle,
                        c: c,
                      )
                    : _step == 1
                        ? _heading(
                            key: 'h1',
                            title: s.verifyYourCode,
                            subtitle: _method == 'none'
                                ? s.resetCodeSentGeneric
                                : '${s.codeSentTo(_masked)} '
                                    '(${_method == 'sms' ? s.codeSentViaSms : s.codeSentViaEmail})',
                            c: c,
                          )
                        : _heading(
                            key: 'h2',
                            title: s.resetPassword,
                            subtitle: s.passwordRequirements,
                            c: c,
                          ),
              ),
              const SizedBox(height: 32),

              // ── Step body ──
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeInCubic,
                transitionBuilder: (child, anim) => FadeTransition(
                  opacity: anim,
                  child: SlideTransition(
                    position: Tween<Offset>(
                      begin: const Offset(0.06, 0),
                      end: Offset.zero,
                    ).animate(anim),
                    child: child,
                  ),
                ),
                child: _step == 0
                    ? _stepIdentifier(c, s)
                    : _step == 1
                        ? _stepCode(c, s)
                        : _stepPassword(c, s),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _heading({
    required String key,
    required String title,
    required String subtitle,
    required AppColors c,
  }) {
    return Column(
      key: ValueKey(key),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          subtitle,
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 15,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  // ── Step 0: identifier ──
  Widget _stepIdentifier(AppColors c, S s) {
    final phone = _isPhone;
    return Column(
      key: const ValueKey('step0'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: neuBox(radius: 16, pressed: true),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              Icon(
                phone
                    ? Icons.phone_iphone_rounded
                    : Icons.alternate_email_rounded,
                color: c.textTertiary,
                size: 20,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _identCtrl,
                  // Editing the identifier clears the "not found" line: it
                  // was about what used to be in the field, and leaving it
                  // up makes a fresh, valid address look rejected too.
                  onChanged: (_) => setState(() => _errorText = null),
                  keyboardType: phone
                      ? TextInputType.phone
                      : TextInputType.emailAddress,
                  inputFormatters: phone
                      ? [const UsPhoneFormatter()]
                      : const <TextInputFormatter>[],
                  style: TextStyle(color: c.textPrimary, fontSize: 16),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: s.emailOrPhone,
                    hintStyle:
                        TextStyle(color: c.textTertiary, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
        _error(),
        const SizedBox(height: 28),
        _primaryButton(
          label: s.sendCode,
          enabled: _canSubmitStep0,
          onTap: _sendCode,
          c: c,
        ),
      ],
    );
  }

  // ── Step 1: six-digit code ──
  Widget _stepCode(AppColors c, S s) {
    return Column(
      key: const ValueKey('step1'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: neuBox(radius: 16, pressed: true),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
          child: Row(
            children: [
              Icon(Icons.pin_outlined, color: c.textTertiary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _codeCtrl,
                  onChanged: (_) => setState(() {}),
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 20,
                    letterSpacing: 6,
                    fontWeight: FontWeight.w700,
                  ),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: s.sixDigitCode,
                    hintStyle: TextStyle(
                      color: c.textTertiary,
                      fontSize: 16,
                      letterSpacing: 0,
                      fontWeight: FontWeight.w400,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        _error(),
        const SizedBox(height: 28),
        _primaryButton(
          label: s.verify,
          enabled: _canSubmitStep1,
          onTap: _verifyCode,
          c: c,
        ),
        const SizedBox(height: 16),
        Center(
          child: GestureDetector(
            onTap: _loading ? null : _sendCode,
            child: Text(
              s.resendCode,
              style: const TextStyle(
                color: _gold,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }

  // ── Step 2: new password ──
  Widget _stepPassword(AppColors c, S s) {
    return Column(
      key: const ValueKey('step2'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _passwordField(c, s.newPassword, _passCtrl),
        const SizedBox(height: 14),
        _passwordField(c, s.confirmPassword, _confirmCtrl),
        const SizedBox(height: 18),
        _rule(_hasLen, s.atLeast8Chars, c),
        _rule(_hasNumber, s.containsNumber, c),
        _rule(_hasUpper, s.anUppercase, c),
        _rule(_hasSpecial, s.aSpecialChar, c),
        _rule(
          _matches,
          _matches ? s.passwordsMatch : s.passwordsDoNotMatch,
          c,
        ),
        _error(),
        const SizedBox(height: 24),
        _primaryButton(
          label: s.resetPasswordBtn,
          enabled: _canSubmitStep2,
          onTap: _confirm,
          c: c,
        ),
      ],
    );
  }

  Widget _rule(bool ok, String label, AppColors c) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6, left: 4),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_rounded : Icons.circle_outlined,
            size: 15,
            color: ok ? _successGreen : c.textTertiary,
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              color: ok ? _successGreen : c.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  Widget _passwordField(AppColors c, String hint, TextEditingController ctrl) {
    return Container(
      decoration: neuBox(radius: 16, pressed: true),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          Icon(Icons.lock_outline_rounded, color: c.textTertiary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: ctrl,
              onChanged: (_) => setState(() {}),
              obscureText: true,
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

  Widget _error() {
    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: _errorText != null
          ? Padding(
              padding: const EdgeInsets.only(top: 12, left: 4),
              child: Row(
                children: [
                  const Icon(
                    Icons.error_outline_rounded,
                    color: _errorRed,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _errorText!,
                      style: const TextStyle(
                        color: _errorRed,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ],
              ),
            )
          : const SizedBox.shrink(),
    );
  }

  Widget _primaryButton({
    required String label,
    required bool enabled,
    required VoidCallback onTap,
    required AppColors c,
  }) {
    return GestureDetector(
      onTap: (_loading || !enabled) ? null : onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 250),
        width: double.infinity,
        height: 56,
        decoration: BoxDecoration(
          color: enabled ? _gold : neuPressed,
          borderRadius: BorderRadius.circular(16),
        ),
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
                label,
                style: TextStyle(
                  color: enabled ? Colors.black : c.textTertiary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
      ),
    );
  }
}
