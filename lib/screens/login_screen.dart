import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/email_service.dart';
import '../services/sms_service.dart';
import 'login_password_screen.dart';
import 'verify_code_screen.dart';
import 'terms_conditions_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
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

  bool _isValidEmail(String text) {
    return RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(text.trim());
  }

  bool _isValidPhone(String text) {
    // US only: exactly 10 digits (area code + number)
    final cleaned = text.replaceAll(RegExp(r'[\s\-\(\)]'), '');
    // Strip leading +1 or 1 if user typed it
    final digits = cleaned.replaceFirst(RegExp(r'^\+?1(?=\d{10})'), '');
    return RegExp(r'^\d{10}$').hasMatch(digits);
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
    final exists = await ApiService.checkExists(email);
    if (!mounted) return;
    if (exists) {
      setState(() => _sending = false);
      _showAccountExistsDialog(email);
      return;
    }

    final code = _generateCode();

    final sent = await EmailService.sendVerificationCode(
      toEmail: email,
      code: code,
    );

    if (!mounted) return;
    setState(() => _sending = false);

    if (sent) {
      _showSnack('Code sent to $email', const Color(0xFFE8C547));
    } else if (!EmailService.isConfigured) {
      _showSnack(
        'EmailJS not configured — check console for code',
        const Color(0xFFE8C547),
      );
    }

    Navigator.of(context).push(
      slideFromRightRoute(VerifyCodeScreen(email: email, expectedCode: code)),
    );
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
    final exists = await ApiService.checkExists(normalizedPhone);
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
    } else if (!SmsService.isConfigured) {
      _showSnack('Twilio not configured', const Color(0xFFE8C547));
    } else {
      _showSnack(
        'Failed to send code. Try again.',
        Colors.white.withValues(alpha: 0.6),
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
          'An account with this ${_usePhone ? "phone number" : "email"} is already registered. Would you like to log in instead?',
          style: TextStyle(color: c.textSecondary, fontSize: 15, height: 1.4),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              'Cancel',
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
            child: const Text(
              'Log In',
              style: TextStyle(fontWeight: FontWeight.w700),
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
                'Welcome to Cruise',
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _usePhone
                    ? 'Enter your US phone number to sign up or log in.'
                    : 'Enter your email to sign up or log in.',
                style: TextStyle(fontSize: 15, color: c.textSecondary),
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
                        style: TextStyle(color: c.textPrimary, fontSize: 16),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: _usePhone
                              ? '(000) 000-0000'
                              : 'Email address',
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
                                ? 'Continue with Phone'
                                : 'Continue with Email',
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
                      'OR',
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
              const SizedBox(height: 24),

              // ── Toggle Phone / Email button ──
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
                    _usePhone ? 'Continue with Email' : 'Continue with Phone',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),

              const Spacer(),

              // ── Terms & Conditions link ──
              Center(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  child: Text.rich(
                    TextSpan(
                      text: 'By continuing, you agree to our ',
                      style: TextStyle(fontSize: 13, color: c.textTertiary),
                      children: [
                        WidgetSpan(
                          child: GestureDetector(
                            onTap: () {
                              Navigator.of(context).push(
                                slideUpFadeRoute(const TermsConditionsScreen()),
                              );
                            },
                            child: const Text(
                              'Terms & Conditions',
                              style: TextStyle(
                                fontSize: 13,
                                color: _gold,
                                fontWeight: FontWeight.w600,
                                decoration: TextDecoration.underline,
                                decorationColor: _gold,
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }
}
