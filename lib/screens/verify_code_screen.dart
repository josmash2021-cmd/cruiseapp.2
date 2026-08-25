import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/haptic_service.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/sms_service.dart';
import 'create_password_screen.dart';

class VerifyCodeScreen extends StatefulWidget {
  final String email;
  final String expectedCode;
  final bool useVerifyApi;
  final bool useBackendVerify;
  /// Optional callback invoked with `true` when the code is verified.
  /// When provided, the screen pops with `true` instead of navigating to
  /// CreatePasswordScreen — used by the social registration flow.
  final void Function(bool verified)? onVerified;

  /// Custom verification hook (e.g. driver phone-login, where "verify" also
  /// creates the session). Receives the entered code; return `null` on
  /// success or an error message to render inline (wrong code, rate limit).
  /// Takes precedence over the built-in verify paths. On success the screen
  /// does NOT navigate — [onCustomVerified] decides what comes next.
  final Future<String?> Function(String code)? customVerify;

  /// Called after [customVerify] succeeds.
  final void Function()? onCustomVerified;

  /// Rider data collected on the create-account page — forwarded through the
  /// onboarding chain (password → name → contacts) so nothing is re-asked.
  final String? firstName;
  final String? lastName;
  final String? contactEmail;
  final String? contactPhone;

  const VerifyCodeScreen({
    super.key,
    required this.email,
    required this.expectedCode,
    this.useVerifyApi = false,
    this.useBackendVerify = false,
    this.onVerified,
    this.customVerify,
    this.onCustomVerified,
    this.firstName,
    this.lastName,
    this.contactEmail,
    this.contactPhone,
  });

  @override
  State<VerifyCodeScreen> createState() => _VerifyCodeScreenState();
}

class _VerifyCodeScreenState extends State<VerifyCodeScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _codeCtrl = TextEditingController();
  final _codeFocus = FocusNode();
  bool _canSubmit = false;
  String? _errorText;
  bool _verifying = false;
  bool _resending = false;
  int _resendSeconds = 0;

  late AnimationController _shakeCtrl;
  late Animation<double> _shakeAnim;

  @override
  void initState() {
    super.initState();
    _codeCtrl.addListener(_onCodeChanged);

    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnim = Tween<double>(
      begin: 0,
      end: 1,
    ).animate(CurvedAnimation(parent: _shakeCtrl, curve: Curves.elasticIn));

    // Auto-focus the code field
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _codeFocus.requestFocus();
    });
  }

  @override
  void dispose() {
    _codeCtrl.dispose();
    _codeFocus.dispose();
    _shakeCtrl.dispose();
    super.dispose();
  }

  void _onCodeChanged() {
    final text = _codeCtrl.text.trim();
    final ok = text.length == 6;
    if (ok != _canSubmit || _errorText != null) {
      setState(() {
        _canSubmit = ok;
        _errorText = null; // clear error on typing
      });
    }
  }

  Future<void> _verifyCode() async {
    if (_verifying) return;
    final code = _codeCtrl.text.trim();
    if (code.length != 6) return;

    setState(() => _verifying = true);

    bool isValid;
    String? customError;

    if (widget.customVerify != null) {
      // Custom flow (e.g. driver phone-login) — the callback verifies AND
      // authenticates; it returns the error message to show on failure.
      customError = await widget.customVerify!(code);
      isValid = customError == null;
    } else if (widget.useVerifyApi) {
      // Phone — verify via Twilio Verify API
      isValid = await SmsService.checkVerificationCode(
        toPhone: widget.email,
        code: code,
      );
    } else if (widget.useBackendVerify) {
      // Email — verify via backend OTP store
      isValid = await ApiService.verifyOtp(email: widget.email, code: code);
    } else {
      // Email — local code comparison
      isValid = code == widget.expectedCode;
    }

    if (!mounted) return;

    if (isValid) {
      if (widget.customVerify != null) {
        // Custom flow — the caller navigates (signup vs home routing).
        widget.onCustomVerified?.call();
      } else if (widget.onVerified != null) {
        // Social registration flow — pop back with verified=true
        widget.onVerified?.call(true);
        Navigator.of(context).pop(true);
      } else {
        // Normal registration flow — navigate to create-password screen
        Navigator.of(context).push(
          slideFromRightRoute(
            CreatePasswordScreen(
              email: widget.email,
              registeredWithEmail: widget.email.contains('@'),
              firstName: widget.firstName,
              lastName: widget.lastName,
              contactEmail: widget.contactEmail,
              contactPhone: widget.contactPhone,
            ),
          ),
        );
      }
    } else {
      // Wrong code — show error + shake
      setState(() {
        _errorText = customError ?? S.of(context).invalidCode;
        _verifying = false;
      });
      _shakeCtrl.forward(from: 0);
      HapticService.mediumImpact();
    }
  }

  Future<void> _resendCode() async {
    if (_resending || _resendSeconds > 0) return;
    setState(() => _resending = true);

    if (widget.useVerifyApi) {
      // Phone — resend via Twilio
      final result = await SmsService.sendVerificationCode(toPhone: widget.email);
      if (!mounted) return;
      if (result.ok) {
        _showSnack(S.of(context).codeResent, const Color(0xFFE8C547));
      } else {
        _showSnack(S.of(context).failedToResendCode, Colors.white.withValues(alpha: 0.6));
      }
    } else {
      // Email — resend via backend (generates new code + sends email)
      final otpResult = await ApiService.sendOtp(email: widget.email);
      if (!mounted) return;
      if (otpResult['ok'] == true) {
        _showSnack(S.of(context).codeResentTo(widget.email), const Color(0xFFE8C547));
      } else {
        _showSnack('Failed to resend email. Try again.', Colors.white.withValues(alpha: 0.6));
      }
    }

    if (!mounted) return;
    setState(() {
      _resending = false;
      _resendSeconds = 60;
    });
    _startResendTimer();
  }

  void _startResendTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _resendSeconds--);
      if (_resendSeconds > 0) _startResendTimer();
    });
  }

  /// Phone flow only: re-send the code via [channel] ('sms' or 'call'),
  /// from the "Problems receiving the code?" sheet. Respects the same
  /// resend cooldown as the plain resend button.
  Future<void> _sendViaChannel(String channel) async {
    if (_resending || _resendSeconds > 0) return;
    Navigator.of(context).pop(); // close the sheet first
    setState(() => _resending = true);

    final result = await SmsService.sendVerificationCode(
      toPhone: widget.email, // phone flow: `email` carries the phone number
      channel: channel,
    );
    if (!mounted) return;
    if (result.ok) {
      _showSnack(
        channel == 'call'
            ? S.of(context).wellCallYouWithCode
            : S.of(context).codeSentByText,
        const Color(0xFFE8C547),
      );
    } else {
      _showSnack(
        S.of(context).failedToResendCode,
        Colors.white.withValues(alpha: 0.6),
      );
    }

    setState(() {
      _resending = false;
      _resendSeconds = 60;
    });
    _startResendTimer();
  }

  /// "+1 (555) 123-4567" → "+1 ••• ••• 4567".
  String _maskTarget(String raw) {
    final digits = raw.replaceAll(RegExp(r'\D'), '');
    if (digits.length <= 4) return raw;
    final last4 = digits.substring(digits.length - 4);
    final cc = digits.length > 10
        ? '+${digits.substring(0, digits.length - 10)} '
        : '';
    return '$cc••• ••• $last4';
  }

  void _showProblemsSheet() {
    HapticService.lightImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => _ResendOptionsSheet(
        maskedTarget: _maskTarget(widget.email),
        cooldownSeconds: () => _resendSeconds,
        onTextMe: () => _sendViaChannel('sms'),
        onCallMe: () => _sendViaChannel('call'),
      ),
    );
  }

  void _showSnack(String msg, Color color) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: color,
        content: Text(msg, style: const TextStyle(fontWeight: FontWeight.w600)),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      // Fields stay put; only the CTA floats above the keyboard.
      resizeToAvoidBottomInset: false,
      backgroundColor: c.bg,
      body: SafeArea(
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
              const SizedBox(height: 28),

              // ── Title ──
              Text(
                widget.useVerifyApi
                    ? S.of(context).codeSentCheckPhone
                    : S.of(context).codeSentCheckEmail,
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  height: 1.2,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                widget.useVerifyApi
                    ? 'Enter the code sent to ${widget.email}.'
                    : 'Enter the code sent to ${widget.email}.',
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Code input ──
              ListenableBuilder(
                listenable: _shakeCtrl,
                builder: (context, child) {
                  final dx = _shakeCtrl.isAnimating
                      ? sin(_shakeAnim.value * 3 * pi) * 8
                      : 0.0;
                  return Transform.translate(
                    offset: Offset(dx, 0),
                    child: child,
                  );
                },
                child: Container(
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: _errorText != null
                          ? Colors.white.withValues(alpha: 0.6)
                          : _canSubmit
                          ? _gold
                          : c.border,
                      width: _errorText != null || _canSubmit ? 1.8 : 1,
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 4,
                  ),
                  child: TextField(
                    controller: _codeCtrl,
                    focusNode: _codeFocus,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 8,
                    ),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      counterText: '',
                      hintText: S.of(context).sixDigitCode,
                      hintStyle: TextStyle(
                        color: c.textTertiary,
                        fontSize: 16,
                        letterSpacing: 0,
                        fontWeight: FontWeight.w400,
                      ),
                    ),
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(6),
                    ],
                  ),
                ),
              ),

              // ── Error text ──
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: _errorText != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 10, left: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              color: Colors.white.withValues(alpha: 0.6),
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _errorText!,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.6),
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
              ),

              // ── Problems receiving the code? (phone flow only — a voice
              // call makes no sense for email OTPs, so the link is hidden
              // when this screen verifies an email) ──
              if (widget.useVerifyApi)
                Padding(
                  padding: const EdgeInsets.only(top: 18),
                  child: Center(
                    child: GestureDetector(
                      onTap: _showProblemsSheet,
                      child: Text(
                        S.of(context).problemsReceivingCode,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ),

              const Spacer(),

              // ── Resend code button ──
              Center(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextButton(
                      onPressed: (_resending || _resendSeconds > 0) ? null : _resendCode,
                      child: _resending
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2, color: _gold),
                            )
                          : Text(
                              _resendSeconds > 0
                                  ? 'Resend in ${_resendSeconds}s'
                                  : 'Resend code',
                              style: TextStyle(
                                color: _resendSeconds > 0
                                    ? Colors.white.withValues(alpha: 0.4)
                                    : _gold,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                    ),
                  ),
                ),

              // ── Next button ──
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    decoration: BoxDecoration(
                      gradient: _canSubmit
                          ? const LinearGradient(colors: [_gold, _goldLight])
                          : null,
                      color: _canSubmit ? null : c.surface,
                      borderRadius: BorderRadius.circular(28),
                    ),
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: _canSubmit
                            ? const Color(0xFF1A1400)
                            : c.textTertiary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      onPressed: _canSubmit ? _verifyCode : null,
                      child: _verifying
                          ? SizedBox(
                              width: 22,
                              height: 22,
                              child: CircularProgressIndicator(
                                color: _canSubmit
                                    ? const Color(0xFF1A1400)
                                    : c.textTertiary,
                                strokeWidth: 2.5,
                              ),
                            )
                          : Text(
                              S.of(context).next,
                              style: const TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

/// Lyft-style "Problems receiving the code?" bottom sheet (phone OTP flow).
/// Refreshes itself once a second so the resend cooldown stays live on the
/// buttons while the sheet is open.
class _ResendOptionsSheet extends StatefulWidget {
  final String maskedTarget;
  final int Function() cooldownSeconds;
  final VoidCallback onTextMe;
  final VoidCallback onCallMe;

  const _ResendOptionsSheet({
    required this.maskedTarget,
    required this.cooldownSeconds,
    required this.onTextMe,
    required this.onCallMe,
  });

  @override
  State<_ResendOptionsSheet> createState() => _ResendOptionsSheetState();
}

class _ResendOptionsSheetState extends State<_ResendOptionsSheet> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (widget.cooldownSeconds() > 0) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  Widget _bullet(String text, Color color) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Icon(Icons.circle, size: 6, color: _gold),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(fontSize: 14, color: color, height: 1.35),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);
    final cooldown = widget.cooldownSeconds();
    final onCooldown = cooldown > 0;

    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 14,
        bottom: 24 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: c.border,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Text(
              s.resendVerificationCode,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: c.textPrimary,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              s.resendCodeTo(widget.maskedTarget),
              style: TextStyle(fontSize: 14, color: c.textSecondary),
            ),
            const SizedBox(height: 20),
            _bullet(s.bulletPhoneCorrect, c.textSecondary),
            _bullet(s.bulletCheckInternet, c.textSecondary),
            _bullet(s.bulletRecentCode, c.textSecondary),
            const SizedBox(height: 12),

            // ── Text me (primary, gold) ──
            SizedBox(
              width: double.infinity,
              height: 52,
              child: Container(
                decoration: BoxDecoration(
                  gradient: onCooldown
                      ? null
                      : const LinearGradient(colors: [_gold, _goldLight]),
                  color: onCooldown ? c.bg : null,
                  borderRadius: BorderRadius.circular(26),
                ),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    disabledBackgroundColor: Colors.transparent,
                    foregroundColor: const Color(0xFF1A1400),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(26),
                    ),
                  ),
                  onPressed: onCooldown ? null : widget.onTextMe,
                  child: Text(
                    onCooldown ? '${s.textMe} (${cooldown}s)' : s.textMe,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: onCooldown ? c.textTertiary : const Color(0xFF1A1400),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 12),

            // ── Call me (secondary, outlined) ──
            SizedBox(
              width: double.infinity,
              height: 52,
              child: OutlinedButton(
                style: OutlinedButton.styleFrom(
                  side: BorderSide(
                    color: onCooldown ? c.border : _gold,
                    width: 1.4,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(26),
                  ),
                ),
                onPressed: onCooldown ? null : widget.onCallMe,
                child: Text(
                  onCooldown ? '${s.callMe} (${cooldown}s)' : s.callMe,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: onCooldown ? c.textTertiary : _gold,
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
