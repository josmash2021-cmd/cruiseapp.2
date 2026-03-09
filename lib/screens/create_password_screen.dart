import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/user_session.dart';
import 'name_screen.dart';

/// Screen shown during registration — after verifying the code.
/// User creates a password and confirms it.
class CreatePasswordScreen extends StatefulWidget {
  final String email; // email or phone used to register
  final bool registeredWithEmail; // true if user used email to sign up

  const CreatePasswordScreen({
    super.key,
    required this.email,
    this.registeredWithEmail = true,
  });

  @override
  State<CreatePasswordScreen> createState() => _CreatePasswordScreenState();
}

class _CreatePasswordScreenState extends State<CreatePasswordScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();
  bool _obscurePass = true;
  bool _obscureConfirm = true;
  bool _canContinue = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _passCtrl.addListener(_validate);
    _confirmCtrl.addListener(_validate);
  }

  @override
  void dispose() {
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _validate() {
    final pass = _passCtrl.text;
    final confirm = _confirmCtrl.text;
    final hasNumber = pass.contains(RegExp(r'[0-9]'));
    final hasUpper = pass.contains(RegExp(r'[A-Z]'));
    final hasSpecial = pass.contains(
      RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]'),
    );
    final ok =
        pass.length >= 8 &&
        hasNumber &&
        hasUpper &&
        hasSpecial &&
        confirm.isNotEmpty &&
        pass == confirm;
    if (ok != _canContinue || _errorText != null) {
      setState(() {
        _canContinue = ok;
        _errorText = null;
      });
    }
  }

  void _submit() async {
    final pass = _passCtrl.text;
    final confirm = _confirmCtrl.text;

    if (pass.length < 8) {
      setState(() => _errorText = 'Password must be at least 8 characters');
      return;
    }
    if (!pass.contains(RegExp(r'[0-9]'))) {
      setState(() => _errorText = 'Password must contain at least 1 number');
      return;
    }
    if (!pass.contains(RegExp(r'[A-Z]'))) {
      setState(
        () => _errorText = 'Password must contain at least 1 uppercase letter',
      );
      return;
    }
    if (!pass.contains(RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]'))) {
      setState(
        () => _errorText = 'Password must contain at least 1 special character',
      );
      return;
    }
    if (pass != confirm) {
      setState(() => _errorText = 'Passwords do not match');
      return;
    }

    // Save password for later use during profile save
    await UserSession.savePendingPassword(pass);

    if (!mounted) return;
    Navigator.of(context).push(
      slideFromRightRoute(
        NameScreen(
          registeredWith: widget.email,
          registeredWithEmail: widget.registeredWithEmail,
        ),
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
                S.of(context).createPassword,
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
                S.of(context).passwordRequirements,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Password field ──
              _buildPasswordField(
                c,
                controller: _passCtrl,
                hint: 'Password',
                obscure: _obscurePass,
                onToggle: () => setState(() => _obscurePass = !_obscurePass),
              ),
              const SizedBox(height: 16),

              // ── Confirm password field ──
              _buildPasswordField(
                c,
                controller: _confirmCtrl,
                hint: 'Confirm password',
                obscure: _obscureConfirm,
                onToggle: () =>
                    setState(() => _obscureConfirm = !_obscureConfirm),
              ),

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

              // ── Strength hints ──
              Padding(
                padding: const EdgeInsets.only(top: 16, left: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _strengthRow(
                      c,
                      S.of(context).atLeast8Chars,
                      _passCtrl.text.length >= 8,
                    ),
                    const SizedBox(height: 6),
                    _strengthRow(
                      c,
                      S.of(context).containsNumber,
                      _passCtrl.text.contains(RegExp(r'[0-9]')),
                    ),
                    const SizedBox(height: 6),
                    _strengthRow(
                      c,
                      S.of(context).anUppercase,
                      _passCtrl.text.contains(RegExp(r'[A-Z]')),
                    ),
                    const SizedBox(height: 6),
                    _strengthRow(
                      c,
                      S.of(context).aSpecialChar,
                      _passCtrl.text.contains(
                        RegExp(r'[!@#\$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]'),
                      ),
                    ),
                    const SizedBox(height: 6),
                    _strengthRow(
                      c,
                      S.of(context).passwordsMatch,
                      _passCtrl.text.isNotEmpty &&
                          _passCtrl.text == _confirmCtrl.text,
                    ),
                  ],
                ),
              ),

              const Spacer(),

              // ── Continue button ──
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: SizedBox(
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
                      onPressed: _canContinue ? _submit : null,
                      child: const Text(
                        'Continue',
                        style: TextStyle(
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

  Widget _buildPasswordField(
    AppColors c, {
    required TextEditingController controller,
    required String hint,
    required bool obscure,
    required VoidCallback onToggle,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: c.border),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        style: TextStyle(color: c.textPrimary, fontSize: 16),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
          prefixIcon: Icon(
            Icons.lock_outline_rounded,
            color: c.textTertiary,
            size: 20,
          ),
          prefixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 0,
          ),
          suffixIcon: GestureDetector(
            onTap: onToggle,
            child: Icon(
              obscure
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
              color: c.textTertiary,
              size: 20,
            ),
          ),
          suffixIconConstraints: const BoxConstraints(
            minWidth: 36,
            minHeight: 0,
          ),
        ),
      ),
    );
  }

  Widget _strengthRow(AppColors c, String label, bool met) {
    return Row(
      children: [
        Icon(
          met ? Icons.check_circle_rounded : Icons.circle_outlined,
          size: 16,
          color: met ? const Color(0xFFE8C547) : c.textTertiary,
        ),
        const SizedBox(width: 8),
        Text(
          label,
          style: TextStyle(
            fontSize: 13,
            color: met ? const Color(0xFFE8C547) : c.textTertiary,
            fontWeight: met ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ],
    );
  }
}
