import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/haptic_service.dart';
import '../../widgets/neu_style.dart';

/// Set a new password with a code mailed to the account's own address.
///
/// Two steps in one screen rather than two routes: the driver who mistypes
/// a digit should not have to navigate back to find out, and the code and
/// the new password belong to one decision. The step only advances once the
/// server has accepted the code, so the password fields never appear for a
/// code that was never going to work.
class DriverResetPasswordScreen extends StatefulWidget {
  const DriverResetPasswordScreen({super.key});

  @override
  State<DriverResetPasswordScreen> createState() =>
      _DriverResetPasswordScreenState();
}

enum _Step { code, password }

class _DriverResetPasswordScreenState extends State<DriverResetPasswordScreen> {
  static const _gold = Color(0xFFE8C547);

  final _codeCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  final _confirmCtrl = TextEditingController();

  _Step _step = _Step.code;
  bool _sending = false;
  bool _submitting = false;
  bool _obscure = true;
  String _maskedEmail = '';
  String? _error;

  /// Seconds until the driver may ask for another code. A resend button
  /// with no cooldown invites a driver who sees no mail to tap it five
  /// times, and every tap invalidates the code the previous one sent.
  int _resendIn = 0;
  Timer? _resendTimer;

  @override
  void initState() {
    super.initState();
    // The code is on its way before the screen finishes opening — the
    // driver got here by tapping "I forgot my password", which is the
    // request.
    WidgetsBinding.instance.addPostFrameCallback((_) => _sendCode());
  }

  @override
  void dispose() {
    _resendTimer?.cancel();
    _codeCtrl.dispose();
    _passCtrl.dispose();
    _confirmCtrl.dispose();
    super.dispose();
  }

  void _set(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  Future<void> _sendCode() async {
    if (_sending || _resendIn > 0) return;
    _set(() {
      _sending = true;
      _error = null;
    });
    try {
      final masked = await ApiService.sendPasswordResetCode();
      if (!mounted) return;
      _set(() {
        _maskedEmail = masked;
        _sending = false;
        _resendIn = 60;
      });
      _startResendCountdown();
    } on ApiException catch (e) {
      if (!mounted) return;
      _set(() {
        _sending = false;
        _error = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      _set(() {
        _sending = false;
        _error = S.of(context).errorOccurred;
      });
    }
  }

  void _startResendCountdown() {
    _resendTimer?.cancel();
    _resendTimer = Timer.periodic(const Duration(seconds: 1), (t) {
      if (!mounted) {
        t.cancel();
        return;
      }
      setState(() => _resendIn = _resendIn > 0 ? _resendIn - 1 : 0);
      if (_resendIn == 0) t.cancel();
    });
  }

  /// The code is only proved right by the server, and the server will not
  /// check it without a password to set. So this step just carries the
  /// six digits forward; a wrong code surfaces on the final submit.
  void _continueToPassword() {
    if (_codeCtrl.text.trim().length != 6) return;
    HapticService.selectionClick();
    _set(() {
      _error = null;
      _step = _Step.password;
    });
  }

  Future<void> _submit() async {
    final pass = _passCtrl.text;
    final confirm = _confirmCtrl.text;
    if (pass != confirm) {
      _set(() => _error = S.of(context).passwordsDoNotMatch);
      return;
    }
    _set(() {
      _submitting = true;
      _error = null;
    });
    try {
      await ApiService.confirmPasswordReset(
        code: _codeCtrl.text.trim(),
        newPassword: pass,
      );
      if (!mounted) return;
      HapticService.mediumImpact();
      Navigator.pop(context, true);
    } on ApiException catch (e) {
      if (!mounted) return;
      _set(() {
        _submitting = false;
        // A rejected code has to send them back a step; the digits they
        // typed are the thing that needs changing, and those fields are
        // no longer on screen.
        _error = e.message;
        if (e.message.toLowerCase().contains('code')) _step = _Step.code;
      });
    } catch (_) {
      if (!mounted) return;
      _set(() {
        _submitting = false;
        _error = S.of(context).errorOccurred;
      });
    }
  }

  /// Same rules the server enforces, checked here so the driver is not
  /// told about the missing capital letter by a round trip.
  bool get _passwordOk {
    final p = _passCtrl.text;
    return p.length >= 8 &&
        RegExp(r'[0-9]').hasMatch(p) &&
        RegExp(r'[A-Z]').hasMatch(p) &&
        RegExp(r'[!@#$%^&*(),.?":{}|<>_\-+=\[\]\\/~`]').hasMatch(p);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      appBar: AppBar(
        backgroundColor: neuBase,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_rounded, color: Colors.white),
          onPressed: () => Navigator.pop(context),
        ),
        title: Text(
          s.resetPasswordTitle,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 17,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      body: ListView(
        physics: const BouncingScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 40),
        children: [
          Center(
            child: Container(
              width: 72,
              height: 72,
              decoration: neuBox(radius: 36, pressed: true),
              child: Icon(
                _step == _Step.code
                    ? Icons.mark_email_read_rounded
                    : Icons.lock_reset_rounded,
                color: _gold,
                size: 32,
              ),
            ),
          ),
          const SizedBox(height: 22),
          Text(
            _step == _Step.code ? s.resetCodeSent : s.resetChooseNew,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _step == _Step.code
                ? (_maskedEmail.isEmpty
                    ? s.resetSending
                    : s.resetCodeSentTo(_maskedEmail))
                : s.resetPasswordRules,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 14,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 26),
          if (_step == _Step.code) ..._codeStep(s) else ..._passwordStep(s),
          if (_error != null) ...[
            const SizedBox(height: 16),
            _errorStrip(_error!),
          ],
        ],
      ),
    );
  }

  List<Widget> _codeStep(S s) {
    final ready = _codeCtrl.text.trim().length == 6;
    return [
      Container(
        decoration: neuBox(radius: 16, pressed: true),
        child: TextField(
          controller: _codeCtrl,
          keyboardType: TextInputType.number,
          textAlign: TextAlign.center,
          maxLength: 6,
          autofocus: true,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) => _continueToPassword(),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 30,
            fontWeight: FontWeight.w800,
            letterSpacing: 14,
          ),
          cursorColor: _gold,
          decoration: const InputDecoration(
            counterText: '',
            border: InputBorder.none,
            contentPadding: EdgeInsets.symmetric(vertical: 20),
          ),
        ),
      ),
      const SizedBox(height: 18),
      _primaryButton(
        label: s.continueLabel,
        enabled: ready,
        busy: false,
        onTap: _continueToPassword,
      ),
      const SizedBox(height: 14),
      Center(
        child: TextButton(
          onPressed: (_sending || _resendIn > 0) ? null : _sendCode,
          child: Text(
            _sending
                ? s.resetSending
                : (_resendIn > 0 ? s.resetResendIn(_resendIn) : s.resetResend),
            style: TextStyle(
              color: (_sending || _resendIn > 0)
                  ? Colors.white.withValues(alpha: 0.3)
                  : _gold,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ),
    ];
  }

  List<Widget> _passwordStep(S s) {
    final match =
        _passCtrl.text.isNotEmpty && _passCtrl.text == _confirmCtrl.text;
    return [
      _passwordField(
        controller: _passCtrl,
        hint: s.newPasswordLabel,
        autofocus: true,
      ),
      const SizedBox(height: 14),
      _passwordField(
        controller: _confirmCtrl,
        hint: s.confirmPasswordLabel,
        autofocus: false,
      ),
      const SizedBox(height: 20),
      _primaryButton(
        label: s.accept,
        enabled: _passwordOk && match && !_submitting,
        busy: _submitting,
        onTap: _submit,
      ),
    ];
  }

  Widget _passwordField({
    required TextEditingController controller,
    required String hint,
    required bool autofocus,
  }) {
    return Container(
      decoration: neuBox(radius: 16, pressed: true),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      child: Row(
        children: [
          Icon(
            Icons.lock_outline_rounded,
            color: _gold.withValues(alpha: 0.8),
            size: 19,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: TextField(
              controller: controller,
              obscureText: _obscure,
              autofocus: autofocus,
              onChanged: (_) => setState(() {}),
              style: const TextStyle(color: Colors.white, fontSize: 15),
              cursorColor: _gold,
              decoration: InputDecoration(
                hintText: hint,
                hintStyle: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 15,
                ),
                border: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 17),
              ),
            ),
          ),
          GestureDetector(
            onTap: () => setState(() => _obscure = !_obscure),
            child: Icon(
              _obscure
                  ? Icons.visibility_outlined
                  : Icons.visibility_off_outlined,
              color: Colors.white.withValues(alpha: 0.35),
              size: 19,
            ),
          ),
        ],
      ),
    );
  }

  Widget _primaryButton({
    required String label,
    required bool enabled,
    required bool busy,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: enabled && !busy ? onTap : null,
      child: Container(
        height: 54,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: enabled ? _gold : Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(16),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.22),
                    blurRadius: 18,
                    offset: const Offset(0, 6),
                  ),
                ]
              : null,
        ),
        child: busy
            ? const SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(
                  strokeWidth: 2.2,
                  color: Colors.black,
                ),
              )
            : Text(
                label,
                style: TextStyle(
                  color: enabled
                      ? Colors.black
                      : Colors.white.withValues(alpha: 0.3),
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
      ),
    );
  }

  Widget _errorStrip(String msg) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE57373).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFFE57373).withValues(alpha: 0.28),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.error_outline_rounded,
            color: Color(0xFFE57373),
            size: 18,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              msg,
              style: const TextStyle(
                color: Color(0xFFE57373),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
