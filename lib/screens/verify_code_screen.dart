import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/sms_service.dart';
import 'create_password_screen.dart';

class VerifyCodeScreen extends StatefulWidget {
  final String email;
  final String expectedCode;
  final bool useVerifyApi;

  const VerifyCodeScreen({
    super.key,
    required this.email,
    required this.expectedCode,
    this.useVerifyApi = false,
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

    if (widget.useVerifyApi) {
      // Phone — verify via Twilio Verify API
      isValid = await SmsService.checkVerificationCode(
        toPhone: widget.email,
        code: code,
      );
    } else {
      // Email — local code comparison
      await Future.delayed(const Duration(milliseconds: 800));
      isValid = code == widget.expectedCode;
    }

    if (!mounted) return;

    if (isValid) {
      // Success — navigate to create-password screen
      Navigator.of(context).push(
        slideFromRightRoute(
          CreatePasswordScreen(
            email: widget.email,
            registeredWithEmail: !widget.useVerifyApi,
          ),
        ),
      );
    } else {
      // Wrong code — show error + shake
      setState(() {
        _errorText = S.of(context).invalidCode;
        _verifying = false;
      });
      _shakeCtrl.forward(from: 0);
      HapticFeedback.mediumImpact();
    }
  }

  Future<void> _resendCode() async {
    if (_resending || _resendSeconds > 0) return;
    setState(() => _resending = true);

    bool sent = false;
    if (widget.useVerifyApi) {
      final result = await SmsService.sendVerificationCode(toPhone: widget.email);
      sent = result.ok;
      if (result.trialBlocked || !sent) {
        // Dev mode fallback
        final devCode = _generateCode();
        debugPrint('📱 DEV MODE — new code for ${widget.email}: $devCode');
        _showSnack('Dev mode: check console', const Color(0xFFE8C547));
      }
    }

    if (!mounted) return;
    setState(() {
      _resending = false;
      _resendSeconds = 60;
    });
    _startResendTimer();

    if (sent) {
      _showSnack('Code resent!', const Color(0xFFE8C547));
    }
  }

  void _startResendTimer() {
    Future.delayed(const Duration(seconds: 1), () {
      if (!mounted) return;
      setState(() => _resendSeconds--);
      if (_resendSeconds > 0) _startResendTimer();
    });
  }

  String _generateCode() {
    final r = Random();
    return List.generate(6, (_) => r.nextInt(10)).join();
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

              const Spacer(),

              // ── Resend code button ──
              if (widget.useVerifyApi)
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
            ],
          ),
        ),
      ),
    );
  }
}
