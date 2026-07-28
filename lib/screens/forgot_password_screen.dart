import 'package:flutter/material.dart';
import '../services/haptic_service.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../widgets/neu_style.dart';

/// Forgot password — enter email, receive reset link by email.
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

  bool _loading = false;
  String? _errorText;
  bool _sent = false; // true = email sent successfully

  @override
  void dispose() {
    _identCtrl.dispose();
    super.dispose();
  }

  bool get _canSubmit => _identCtrl.text.trim().isNotEmpty;

  Future<void> _requestReset() async {
    final identifier = _identCtrl.text.trim();
    if (identifier.isEmpty) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });
    try {
      await ApiService.forgotPassword(identifier);
      if (!mounted) return;
      HapticService.mediumImpact();
      setState(() {
        _sent = true;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      final msg = e.toString().replaceFirst('Exception: ', '');
      setState(() {
        _loading = false;
        // Show localized "no account found" for 404
        if (msg.contains('No registered account found') ||
            msg.contains('404')) {
          _errorText = S.of(context).noAccountFound;
        } else {
          _errorText = msg;
        }
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
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
                onTap: () => Navigator.pop(context),
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
                S.of(context).forgotPasswordTitle,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 30,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).forgotSubtitle,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 15,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 32),

              if (!_sent) ...[
                // ── Email input ──
                _inputField(
                  controller: _identCtrl,
                  hint: S.of(context).emailOrPhone,
                  icon: Icons.alternate_email_rounded,
                  keyboardType: TextInputType.emailAddress,
                  c: c,
                ),

                // ── Error text ──
                AnimatedSize(
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
                ),
                const SizedBox(height: 28),

                // ── Submit button ──
                GestureDetector(
                  onTap: (_loading || !_canSubmit) ? null : _requestReset,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 250),
                    width: double.infinity,
                    height: 56,
                    decoration: BoxDecoration(
                      color: _canSubmit ? _gold : neuPressed,
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
                            S.of(context).sendResetLink,
                            style: TextStyle(
                              color: _canSubmit
                                  ? Colors.black
                                  : c.textTertiary,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                  ),
                ),
              ],

              // ── Success message ──
              if (_sent) ...[
                const SizedBox(height: 24),
                Container(
                  padding: const EdgeInsets.all(20),
                  decoration: neuBox(radius: 18),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.mark_email_read_rounded,
                        color: _successGreen,
                        size: 28,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Text(
                          S.of(context).resetLinkSent,
                          style: const TextStyle(
                            color: _successGreen,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),
                // ── Back to sign in (secondary) ──
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: double.infinity,
                    height: 54,
                    decoration: neuBox(radius: 16, pressed: true),
                    alignment: Alignment.center,
                    child: Text(
                      S.of(context).backToSignIn,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
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
  }) {
    return Container(
      decoration: neuBox(radius: 16, pressed: true),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
      child: Row(
        children: [
          Icon(icon, color: c.textTertiary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: TextField(
              controller: controller,
              onChanged: (_) => setState(() {}),
              keyboardType: keyboardType,
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
}
