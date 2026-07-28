import 'package:flutter/material.dart';
import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../widgets/dismiss_keyboard.dart';
import 'notifications_screen.dart';

class EmailCollectScreen extends StatefulWidget {
  final String firstName;
  final String lastName;
  final String registeredWith; // email or phone used to register
  final bool registeredWithEmail; // true = already has email, ask phone

  /// Contacts collected on the create-account page. When both are present
  /// this screen auto-advances — there is nothing left to ask.
  final String? contactEmail;
  final String? contactPhone;

  const EmailCollectScreen({
    super.key,
    required this.firstName,
    required this.lastName,
    required this.registeredWith,
    required this.registeredWithEmail,
    this.contactEmail,
    this.contactPhone,
  });

  @override
  State<EmailCollectScreen> createState() => _EmailCollectScreenState();
}

class _EmailCollectScreenState extends State<EmailCollectScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _inputCtrl = TextEditingController();
  bool _canContinue = false;

  /// true when user registered with email → this screen asks for phone
  bool get _askingPhone => widget.registeredWithEmail;

  @override
  void initState() {
    super.initState();
    _inputCtrl.addListener(_onChanged);

    // Page-1 signup already collected both contacts — skip this screen and
    // continue straight to notifications with the complete profile.
    if (widget.contactEmail != null && widget.contactPhone != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        Navigator.of(context).pushReplacement(
          slideFromRightRoute(
            NotificationsScreen(
              firstName: widget.firstName,
              lastName: widget.lastName,
              email: widget.contactEmail!,
              phone: widget.contactPhone!,
            ),
          ),
        );
      });
    }
  }

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  void _onChanged() {
    final ok = _inputCtrl.text.trim().isNotEmpty;
    if (ok != _canContinue) setState(() => _canContinue = ok);
  }

  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
  static final _phoneCleanRe = RegExp(r'[\s\-\(\)]');
  static final _phoneDigitsRe = RegExp(r'^\+?\d{7,15}$');

  bool _isValidEmail(String text) {
    return _emailRe.hasMatch(text.trim());
  }

  bool _isValidPhone(String text) {
    final cleaned = text.replaceAll(_phoneCleanRe, '');
    return _phoneDigitsRe.hasMatch(cleaned);
  }

  /// Normalize phone to E.164 format
  String _normalizePhone(String text) {
    var cleaned = text.replaceAll(_phoneCleanRe, '');
    if (!cleaned.startsWith('+')) {
      cleaned = '+1$cleaned'; // Default to US
    }
    return cleaned;
  }

  void _next() {
    final input = _inputCtrl.text.trim();
    if (input.isEmpty) return;

    if (_askingPhone) {
      // Validate phone number
      if (!_isValidPhone(input)) {
        _showSnack(S.of(context).invalidPhoneError);
        return;
      }
      // email came from registration, phone collected here
      final normalizedPhone = _normalizePhone(input);
      Navigator.of(context).push(
        slideFromRightRoute(
          NotificationsScreen(
            firstName: widget.firstName,
            lastName: widget.lastName,
            email: widget.registeredWith,
            phone: normalizedPhone,
          ),
        ),
      );
    } else {
      // Validate email
      if (!_isValidEmail(input)) {
        _showSnack(S.of(context).invalidEmailError);
        return;
      }
      // phone came from registration, email collected here
      Navigator.of(context).push(
        slideFromRightRoute(
          NotificationsScreen(
            firstName: widget.firstName,
            lastName: widget.lastName,
            email: input,
            phone: widget.registeredWith,
          ),
        ),
      );
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        backgroundColor: Colors.redAccent,
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
      body: DismissKeyboard(
        child: SafeArea(
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
                _askingPhone
                    ? S.of(context).greetSharePhone(widget.firstName)
                    : S.of(context).greetShareEmail(widget.firstName),
                style: TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  height: 1.25,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                _askingPhone
                    ? S.of(context).needPhoneSubtitle
                    : S.of(context).needEmailSubtitle,
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
              const SizedBox(height: 28),

              // ── Input field ──
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
                child: TextField(
                  controller: _inputCtrl,
                  keyboardType: _askingPhone
                      ? TextInputType.phone
                      : TextInputType.emailAddress,
                  style: TextStyle(color: c.textPrimary, fontSize: 16),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: _askingPhone
                        ? S.of(context).phoneNumber
                        : S.of(context).email,
                    hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
                  ),
                ),
              ),

              const Spacer(),

              // ── Next button ──
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
                      onPressed: _canContinue ? _next : null,
                      child: Text(
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
      ),
    );
  }
}
