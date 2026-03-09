import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';

/// Two-step forgot password flow:
/// Step 1 – Enter email/phone to receive a reset code.
/// Step 2 – Enter code + new password.
class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _identCtrl = TextEditingController();
  final _codeCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  bool _loading = false;
  bool _obscure = true;
  bool _obscureConfirm = true;
  String? _errorText;
  bool _step2 = false; // true = show code + new password form

  @override
  void dispose() {
    _identCtrl.dispose();
    _codeCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmitStep1 => _identCtrl.text.trim().isNotEmpty;
  bool get _canSubmitStep2 =>
      _codeCtrl.text.trim().isNotEmpty &&
      _passCtrl.text.length >= 8 &&
      _passCtrl.text.contains(RegExp(r'[0-9]')) &&
      _passCtrl.text.contains(RegExp(r'[A-Z]')) &&
      _passCtrl.text.contains(
        RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]'),
      ) &&
      _passCtrl.text == _confirmCtrl.text;

  Future<void> _requestCode() async {
    final identifier = _identCtrl.text.trim();
    if (identifier.isEmpty) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      await ApiService.forgotPassword(identifier);
      if (!mounted) return;
      setState(() {
        _step2 = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  Future<void> _resetPassword() async {
    final code = _codeCtrl.text.trim();
    final pass = _passCtrl.text;
    final confirm = _confirmCtrl.text;
    if (code.isEmpty || pass.isEmpty) return;
    if (pass != confirm) {
      setState(() => _errorText = S.of(context).passwordsMismatch);
      return;
    }
    if (pass.length < 8 ||
        !pass.contains(RegExp(r'[0-9]')) ||
        !pass.contains(RegExp(r'[A-Z]')) ||
        !pass.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]'))) {
      setState(() => _errorText = S.of(context).passwordRequirements);
      return;
    }
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      await ApiService.resetPassword(code: code, newPassword: pass);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).resetSuccess),
          backgroundColor: const Color(0xFF2E7D32),
        ),
      );
      Navigator.pop(context);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = e.toString().replaceFirst('Exception: ', '');
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
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
                onTap: () => Navigator.pop(context),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.arrow_back_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // ── Title ──
              Text(
                _step2
                    ? S.of(context).resetPassword
                    : S.of(context).forgotPasswordTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 28,
                  fontWeight: FontWeight.w900,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              AnimatedSwitcher(
                duration: const Duration(milliseconds: 300),
                child: Text(
                  _step2
                      ? S.of(context).resetCodeSubtitle
                      : S.of(context).forgotSubtitle,
                  key: ValueKey(_step2),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 15,
                    height: 1.4,
                  ),
                ),
              ),
              const SizedBox(height: 32),

              // ── Step 1: identifier ──
              if (!_step2) ...[
                _inputField(
                  controller: _identCtrl,
                  hint: S.of(context).emailOrPhone,
                  icon: Icons.alternate_email_rounded,
                  keyboardType: TextInputType.emailAddress,
                  c: c,
                ),
              ],

              // ── Step 2: code + passwords ──
              if (_step2) ...[
                _inputField(
                  controller: _codeCtrl,
                  hint: S.of(context).sixDigitCode,
                  icon: Icons.pin_rounded,
                  keyboardType: TextInputType.number,
                  c: c,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(6),
                  ],
                ),
                const SizedBox(height: 14),
                _inputField(
                  controller: _passCtrl,
                  hint: S.of(context).newPassword,
                  icon: Icons.lock_outline_rounded,
                  obscure: _obscure,
                  onToggleObscure: () => setState(() => _obscure = !_obscure),
                  c: c,
                ),
                const SizedBox(height: 14),
                _inputField(
                  controller: _confirmCtrl,
                  hint: S.of(context).confirmPassword,
                  icon: Icons.lock_outline_rounded,
                  obscure: _obscureConfirm,
                  onToggleObscure: () =>
                      setState(() => _obscureConfirm = !_obscureConfirm),
                  c: c,
                ),
              ],

              // ── Error text ──
              AnimatedSize(
                duration: const Duration(milliseconds: 200),
                child: _errorText != null
                    ? Padding(
                        padding: const EdgeInsets.only(top: 12, left: 4),
                        child: Row(
                          children: [
                            Icon(
                              Icons.error_outline_rounded,
                              color: Colors.white.withValues(alpha: 0.6),
                              size: 16,
                            ),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                _errorText!,
                                style: TextStyle(
                                  color: Colors.white.withValues(alpha: 0.6),
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
              const SizedBox(height: 28),

              // ── Submit button ──
              SizedBox(
                width: double.infinity,
                height: 56,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 250),
                  decoration: BoxDecoration(
                    gradient: (_step2 ? _canSubmitStep2 : _canSubmitStep1)
                        ? const LinearGradient(colors: [_gold, _goldLight])
                        : null,
                    color: (_step2 ? _canSubmitStep2 : _canSubmitStep1)
                        ? null
                        : c.surface,
                    borderRadius: BorderRadius.circular(28),
                  ),
                  child: ElevatedButton(
                    onPressed: _loading
                        ? null
                        : (_step2 ? _resetPassword : _requestCode),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.transparent,
                      shadowColor: Colors.transparent,
                      foregroundColor:
                          (_step2 ? _canSubmitStep2 : _canSubmitStep1)
                          ? const Color(0xFF1A1400)
                          : c.textTertiary,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(28),
                      ),
                    ),
                    child: _loading
                        ? const SizedBox(
                            width: 22,
                            height: 22,
                            child: CircularProgressIndicator(
                              color: _gold,
                              strokeWidth: 2.5,
                            ),
                          )
                        : Text(
                            _step2
                                ? S.of(context).resetPasswordBtn
                                : S.of(context).sendCode,
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ),

              if (_step2) ...[
                const SizedBox(height: 16),
                Center(
                  child: GestureDetector(
                    onTap: _loading ? null : _requestCode,
                    child: Text(
                      S.of(context).resendCode,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _inputField({
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    required AppColors c,
    TextInputType keyboardType = TextInputType.text,
    bool obscure = false,
    VoidCallback? onToggleObscure,
    List<TextInputFormatter>? inputFormatters,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: TextField(
        controller: controller,
        onChanged: (_) => setState(() {}),
        obscureText: obscure,
        keyboardType: keyboardType,
        inputFormatters: inputFormatters,
        style: const TextStyle(color: Colors.white, fontSize: 16),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
          prefixIcon: Icon(icon, color: c.textTertiary, size: 20),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 0,
          ),
          suffixIcon: onToggleObscure != null
              ? GestureDetector(
                  onTap: onToggleObscure,
                  child: Icon(
                    obscure
                        ? Icons.visibility_off_outlined
                        : Icons.visibility_outlined,
                    color: c.textTertiary,
                    size: 20,
                  ),
                )
              : null,
          suffixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 0,
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 16,
          ),
        ),
      ),
    );
  }
}
