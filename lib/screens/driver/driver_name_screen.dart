import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import '../../utils/date_of_birth.dart';
import 'driver_email_screen.dart';

/// Driver phone onboarding — step 3, only for brand-new accounts
/// (`is_new_user` from /auth/phone-login). Collects first/last name,
/// persists them via `PATCH /auth/me`, then continues to the dedicated
/// email step: [DriverEmailScreen].
class DriverNameScreen extends StatefulWidget {
  /// The user map returned by phone-login (id, phone, …) — used to refresh
  /// the local session after the profile update.
  final Map<String, dynamic> user;

  const DriverNameScreen({super.key, required this.user});

  @override
  State<DriverNameScreen> createState() => _DriverNameScreenState();
}

class _DriverNameScreenState extends State<DriverNameScreen> {
  static const _navy = Color(0xFF14141A);
  static const _gold = Color(0xFFE8C547);

  final _firstCtrl = TextEditingController();
  final _lastCtrl = TextEditingController();
  bool _canContinue = false;
  bool _saving = false;
  String? _errorText;

  /// Date of birth — required, drivers must be at least 25 (user spec
  /// 2026-09-27; the server re-gates every write at PATCH /auth/me).
  static const int _minAge = 25;
  DateTime? _dob;

  String get _dobIso {
    final d = _dob!;
    return '${d.year.toString().padLeft(4, '0')}-'
        '${d.month.toString().padLeft(2, '0')}-'
        '${d.day.toString().padLeft(2, '0')}';
  }

  @override
  void initState() {
    super.initState();
    // Pre-fill what the account already has — same rule as the rider screen.
    final first = (widget.user['first_name'] ?? '').toString().trim();
    final last = (widget.user['last_name'] ?? '').toString().trim();
    if (first.isNotEmpty && first != 'User') _firstCtrl.text = first;
    if (last.isNotEmpty) _lastCtrl.text = last;
    _firstCtrl.addListener(_validate);
    _lastCtrl.addListener(_validate);
    WidgetsBinding.instance.addPostFrameCallback((_) => _validate());
  }

  @override
  void dispose() {
    _firstCtrl.dispose();
    _lastCtrl.dispose();
    super.dispose();
  }

  void _validate() {
    final ok = _firstCtrl.text.trim().isNotEmpty &&
        _lastCtrl.text.trim().isNotEmpty &&
        _dob != null;
    if (ok != _canContinue || _errorText != null) {
      setState(() {
        _canContinue = ok;
        _errorText = null;
      });
    }
  }

  Future<void> _pickDob() async {
    final picked = await pickDateOfBirth(context, minAge: _minAge, initial: _dob);
    if (picked == null || !mounted) return;
    setState(() => _dob = picked);
    _validate();
  }

  Future<void> _continue() async {
    if (!_canContinue || _saving) return;
    setState(() {
      _saving = true;
      _errorText = null;
    });

    final first = _firstCtrl.text.trim();
    final last = _lastCtrl.text.trim();

    // Age belt (the server re-gates): any past date is pickable — a driver
    // under 25 reads why instead of hitting a bare 400.
    final dob = _dob;
    if (dob == null || computeAge(dob) < _minAge) {
      setState(() {
        _saving = false;
        _errorText = S.of(context).dobMinAge(_minAge);
      });
      return;
    }

    try {
      await ApiService.updateMe({
        'first_name': first,
        'last_name': last,
        'date_of_birth': _dobIso,
      });
      await UserSession.saveUser(
        firstName: first,
        lastName: last,
        email: widget.user['email'] ?? '',
        phone: widget.user['phone'] ?? '',
        photoUrl: widget.user['photo_url'] as String?,
        userId: (widget.user['id'] is num)
            ? (widget.user['id'] as num).toInt()
            : int.tryParse(widget.user['id']?.toString() ?? ''),
        role: 'driver',
      );
      if (!mounted) return;
      Navigator.of(context).push(
        onboardingFadeSlideRoute(DriverEmailScreen(firstName: first)),
      );
      setState(() => _saving = false);
    } on ApiException catch (e) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = e.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _errorText = S.of(context).connectionError;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;

    return Scaffold(
      backgroundColor: _navy,
      // Keep the fields pinned in place: only the CTA floats above the
      // keyboard (viewInsets padding below), instead of the body resizing
      // and scrolling the fields off the top.
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
                      S.of(context).whatsYourName,
                      style: GoogleFonts.poppins(
                        fontSize: 32,
                        fontWeight: FontWeight.w700,
                        letterSpacing: -0.5,
                        color: Colors.white,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Text(
                      S.of(context).nameAsRidersSeeIt,
                      style: GoogleFonts.inter(
                        fontSize: 15,
                        color: Colors.white.withValues(alpha: 0.65),
                      ),
                    ),
                    const SizedBox(height: 40),
                    _field(_firstCtrl, S.of(context).firstNameLabel,
                        textCapitalization: TextCapitalization.words),
                    const SizedBox(height: 16),
                    _field(_lastCtrl, S.of(context).lastNameLabel,
                        textCapitalization: TextCapitalization.words),
                    const SizedBox(height: 16),
                    // Date of birth — required; drivers 25+ (user spec
                    // 2026-09-27).
                    GestureDetector(
                      onTap: _pickDob,
                      child: Container(
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.07),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                              color: _dob != null
                                  ? _gold
                                  : Colors.white.withValues(alpha: 0.14)),
                        ),
                        padding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 18),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                _dob == null
                                    ? S.of(context).dateOfBirth
                                    : DateFormat('MM/dd/yyyy').format(_dob!),
                                style: TextStyle(
                                  color: _dob == null
                                      ? Colors.white.withValues(alpha: 0.3)
                                      : Colors.white,
                                  fontSize: 17,
                                  fontWeight: _dob == null
                                      ? FontWeight.w400
                                      : FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.calendar_month_rounded,
                              color: Colors.white.withValues(alpha: 0.45),
                              size: 22,
                            ),
                          ],
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
                onTap: _canContinue && !_saving ? _continue : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  height: 58,
                  decoration: BoxDecoration(
                    color: _canContinue
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
                            color: _canContinue
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

  Widget _field(
    TextEditingController controller,
    String hint, {
    TextInputType keyboardType = TextInputType.text,
    TextCapitalization textCapitalization = TextCapitalization.none,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.07),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.14)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: TextField(
        controller: controller,
        keyboardType: keyboardType,
        textCapitalization: textCapitalization,
        style: const TextStyle(color: Colors.white, fontSize: 17),
        cursorColor: _gold,
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: TextStyle(
            color: Colors.white.withValues(alpha: 0.3),
            fontSize: 17,
          ),
        ),
      ),
    );
  }
}
