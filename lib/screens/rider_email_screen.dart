import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/user_session.dart';
import 'driver/onboarding/driver_notifications_screen.dart';
import 'rider_add_payment_screen.dart';

/// Rider phone onboarding — step 3, email collection (Lyft-style):
/// "Great to meet you, {name}. Mind sharing your email?"
///
/// The email is REQUIRED (receipts + account updates), inline-validated and
/// checked against the backend via `PATCH /auth/me`, which answers
/// `400 "Email already in use"` on a duplicate — rendered inline. On
/// success the session is refreshed and the rider continues to the
/// Add-payment step ([RiderAddPaymentScreen]), which skips itself when the
/// rider already has a method and lands on ReadyToRideScreen → home
/// (the home boot handles the once-per-process permissions page).
class RiderEmailScreen extends StatefulWidget {
  /// The user map from phone-login, with the name fields already updated by
  /// [RiderNameScreen] — used to greet and to refresh the local session.
  final Map<String, dynamic> user;

  const RiderEmailScreen({super.key, required this.user});

  @override
  State<RiderEmailScreen> createState() => _RiderEmailScreenState();
}

class _RiderEmailScreenState extends State<RiderEmailScreen> {
  static const _navy = Color(0xFF14141A);
  static const _gold = Color(0xFFE8C547);
  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');

  final _emailCtrl = TextEditingController();
  final _emailFocus = FocusNode();
  bool _touched = false;
  bool _saving = false;

  /// null = no error; otherwise an already-localized inline message.
  String? _errorText;

  bool get _emailValid => _emailRe.hasMatch(_emailCtrl.text.trim());

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
    if (_emailCtrl.text.trim().isNotEmpty) _touched = true;
    // Clear a stale error as soon as the input changes; the format error is
    // derived in build() so it always reflects the current text.
    if (_errorText != null) setState(() => _errorText = null);
    setState(() {});
  }

  Future<void> _continue() async {
    if (!_emailValid || _saving) return;
    setState(() {
      _saving = true;
      _errorText = null;
    });

    final email = _emailCtrl.text.trim();
    final s = S.of(context);

    try {
      await ApiService.updateMe({'email': email});
      await UserSession.saveUser(
        firstName: widget.user['first_name'] ?? '',
        lastName: widget.user['last_name'] ?? '',
        email: email,
        phone: widget.user['phone'] ?? '',
        photoUrl: widget.user['photo_url'] as String?,
        userId: (widget.user['id'] is num)
            ? (widget.user['id'] as num).toInt()
            : int.tryParse(widget.user['id']?.toString() ?? ''),
        role: 'rider',
      );
      if (!mounted) return;
      // Next: the notification-permission page (OS prompt fires there,
      // 2026-08-25), then Add payment method — which skips itself for
      // riders who already have a method on file and lands on
      // ReadyToRideScreen → home.
      Navigator.of(context).push(
        smoothFadeRoute(
          DriverNotificationsScreen(
            nextScreen: RiderAddPaymentScreen(
                user: {...widget.user, 'email': email}),
          ),
        ),
      );
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = e.statusCode == 400 &&
                e.message.toLowerCase().contains('already in use')
            ? s.emailAlreadyInUse
            : e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = s.connectionError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final firstName =
        (widget.user['first_name'] as String? ?? '').trim().split(' ').first;
    final showFormatError =
        _touched && _emailCtrl.text.trim().isNotEmpty && !_emailValid;

    return Scaffold(
      backgroundColor: _navy,
      resizeToAvoidBottomInset: false,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
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
                      S.of(context).greatToMeetYou(firstName),
                      style: GoogleFonts.poppins(
                        fontSize: 28,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: Colors.white,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      S.of(context).emailReceiptsSubtitle,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ),
                    const SizedBox(height: 40),
                    Container(
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.07),
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(
                          color: _emailValid
                              ? _gold
                              : Colors.white.withValues(alpha: 0.14),
                          width: _emailValid ? 1.6 : 1,
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: TextField(
                        controller: _emailCtrl,
                        focusNode: _emailFocus,
                        keyboardType: TextInputType.emailAddress,
                        autofillHints: const [AutofillHints.email],
                        style:
                            const TextStyle(color: Colors.white, fontSize: 17),
                        cursorColor: _gold,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: S.of(context).emailAddressLabel,
                          hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.3),
                            fontSize: 17,
                          ),
                        ),
                      ),
                    ),
                    if (showFormatError)
                      Padding(
                        padding: const EdgeInsets.only(top: 8, left: 4),
                        child: Text(
                          S.of(context).enterValidEmailAddress,
                          style: const TextStyle(
                            color: Color(0xFFE57373),
                            fontSize: 13,
                          ),
                        ),
                      ),
                    if (_errorText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 12, left: 4),
                        child: Text(
                          _errorText!,
                          style: const TextStyle(
                            color: Color(0xFFE57373),
                            fontSize: 13,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(
                28,
                8,
                28,
                pad.bottom + MediaQuery.of(context).viewInsets.bottom + 16,
              ),
              child: GestureDetector(
                onTap: _emailValid && !_saving ? _continue : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  height: 58,
                  decoration: BoxDecoration(
                    color: _emailValid
                        ? _gold
                        : _gold.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(18),
                  ),
                  alignment: Alignment.center,
                  child: _saving
                      ? const SizedBox(
                          width: 24,
                          height: 24,
                          child: CircularProgressIndicator(
                            strokeWidth: 2.5,
                            color: Colors.black,
                          ),
                        )
                      : Text(
                          S.of(context).continueLabel,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: _emailValid
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
