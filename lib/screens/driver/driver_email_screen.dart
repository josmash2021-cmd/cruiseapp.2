import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import 'driver_drive_city_screen.dart';

/// Driver phone onboarding — email step, right after [DriverNameScreen].
/// Required (no skip): collects the account email, validates the format
/// inline as the user types, checks on Next that it is not already tied to
/// another account (`/auth/check-exists`), persists it via `PATCH /auth/me`
/// and continues to [DriverDriveCityScreen].
class DriverEmailScreen extends StatefulWidget {
  /// First name collected on the previous step — used for the greeting.
  final String firstName;

  const DriverEmailScreen({super.key, required this.firstName});

  @override
  State<DriverEmailScreen> createState() => _DriverEmailScreenState();
}

class _DriverEmailScreenState extends State<DriverEmailScreen> {
  static const _navy = Color(0xFF0A1128);
  static const _gold = Color(0xFFE8C547);
  static final _emailRe = RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$');

  final _emailCtrl = TextEditingController();
  bool _canNext = false;
  bool _saving = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_validate);
  }

  @override
  void dispose() {
    _emailCtrl.dispose();
    super.dispose();
  }

  bool get _emailValid => _emailRe.hasMatch(_emailCtrl.text.trim());

  void _validate() {
    final ok = _emailValid;
    // Any edit clears the backend "already in use" error too.
    if (ok != _canNext || _errorText != null) {
      setState(() {
        _canNext = ok;
        _errorText = null;
      });
    } else {
      setState(() {}); // refresh inline format error
    }
  }

  Future<void> _next() async {
    if (!_canNext || _saving) return;
    setState(() {
      _saving = true;
      _errorText = null;
    });

    final email = _emailCtrl.text.trim();

    try {
      final exists = await ApiService.checkExists(email, role: 'driver');
      if (!mounted) return;
      if (exists) {
        setState(() {
          _saving = false;
          _errorText = S.of(context).emailAlreadyInUse;
        });
        return;
      }

      await ApiService.updateMe({'email': email});

      // Refresh the local session so the cached user carries the new email
      // (saveUser encrypts it the same way the name step does).
      final cached = await UserSession.getUser();
      if (cached != null) {
        await UserSession.saveUser(
          firstName: cached['firstName'] ?? widget.firstName,
          lastName: cached['lastName'] ?? '',
          email: email,
          phone: cached['phone'] ?? '',
          photoUrl:
              (cached['photoUrl'] ?? '').isEmpty ? null : cached['photoUrl'],
          userId: int.tryParse(cached['userId'] ?? ''),
          role: cached['role'] ?? 'driver',
        );
      }
      if (!mounted) return;
      Navigator.of(context).push(
        onboardingFadeSlideRoute(const DriverDriveCityScreen()),
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
      // Keep the field pinned in place: only the CTA floats above the
      // keyboard (viewInsets padding below), instead of the body resizing
      // and scrolling the field off the top.
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
                      S.of(context).greatToMeetYou(widget.firstName),
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
                          color: Colors.white.withValues(alpha: 0.14),
                        ),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      child: TextField(
                        controller: _emailCtrl,
                        keyboardType: TextInputType.emailAddress,
                        autocorrect: false,
                        inputFormatters: [
                          FilteringTextInputFormatter.deny(RegExp(r'\s')),
                        ],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 19,
                        ),
                        cursorColor: _gold,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: S.of(context).emailAddressLabel,
                          hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.3),
                            fontSize: 19,
                          ),
                        ),
                      ),
                    ),
                    if (_emailCtrl.text.trim().isNotEmpty && !_emailValid)
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
                onTap: _canNext && !_saving ? _next : null,
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: double.infinity,
                  height: 58,
                  decoration: BoxDecoration(
                    color:
                        _canNext ? _gold : _gold.withValues(alpha: 0.25),
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
                          S.of(context).next,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                            color: _canNext
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
