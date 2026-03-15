import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import '../forgot_password_screen.dart';
import 'driver_signup_screen.dart';
import 'driver_home_screen.dart';
import 'driver_pending_review_screen.dart';

/// Driver login screen — email + password for existing drivers.
class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);

  final _emailCtrl = TextEditingController();
  final _passCtrl = TextEditingController();
  bool _obscure = true;
  bool _canLogin = false;
  bool _loading = false;
  String? _errorText;

  late AnimationController _entranceCtrl;
  late Animation<double> _fade;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _emailCtrl.addListener(_validate);
    _passCtrl.addListener(_validate);

    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    )..forward();
    _fade = CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(
          CurvedAnimation(parent: _entranceCtrl, curve: Curves.easeOutCubic),
        );
  }

  @override
  void dispose() {
    _entranceCtrl.dispose();
    _emailCtrl.dispose();
    _passCtrl.dispose();
    super.dispose();
  }

  void _validate() {
    final ok = _emailCtrl.text.trim().isNotEmpty && _passCtrl.text.isNotEmpty;
    if (ok != _canLogin || _errorText != null) {
      setState(() {
        _canLogin = ok;
        _errorText = null;
      });
    }
  }

  Future<void> _handleLogin() async {
    if (!_canLogin) return;
    setState(() {
      _loading = true;
      _errorText = null;
    });

    try {
      // Step 1: Validate credentials → get login_token
      final loginRes = await ApiService.login(
        identifier: _emailCtrl.text.trim(),
        password: _passCtrl.text,
        role: 'driver',
      );
      final loginToken = loginRes['login_token'] as String;

      // Step 2: Exchange login_token for full JWT (auto-saves token)
      final result = await ApiService.completeLogin(loginToken: loginToken);
      final user = result['user'] as Map<String, dynamic>;

      // Save user data locally
      await UserSession.saveUser(
        firstName: user['first_name'] ?? '',
        lastName: user['last_name'] ?? '',
        email: user['email'] ?? '',
        phone: user['phone'] ?? '',
        userId: user['id'] as int?,
        role: 'driver',
      );
      await UserSession.saveMode('driver');

      // Check driver approval status
      final vStatus = user['verification_status'] as String? ?? 'none';
      if (!mounted) return;
      setState(() => _loading = false);

      if (vStatus == 'approved') {
        Navigator.of(context).pushAndRemoveUntil(
          slideFromRightRoute(const DriverHomeScreen()),
          (_) => false,
        );
        return;
      }
      // pending, rejected, none, or any other status → pending review screen
      // (DriverPendingReviewScreen fetches live status and handles all states)
      Navigator.of(context).pushAndRemoveUntil(
        slideFromRightRoute(const DriverPendingReviewScreen()),
        (_) => false,
      );
      return;
    } on ApiException catch (e) {
      if (!mounted) return;
      String msg;
      if (e.statusCode == 403) {
        final detail = e.message.toLowerCase();
        if (detail.contains('deleted')) {
          msg = S.of(context).accountDeleted;
        } else if (detail.contains('blocked')) {
          msg = S.of(context).accountBlocked;
        } else if (detail.contains('deactivated')) {
          msg = S.of(context).accountDeactivated2;
        } else {
          msg = e.message;
        }
      } else {
        msg = e.message;
      }
      setState(() {
        _loading = false;
        _errorText = msg;
      });
      return;
    } catch (e) {
      if (!mounted) return;
      // Auto re-probe for a working server URL and retry once
      final newUrl = await ApiService.probeAndSetBestUrl(
        timeout: const Duration(seconds: 6),
      );
      if (newUrl != null && mounted) {
        try {
          final loginRes = await ApiService.login(
            identifier: _emailCtrl.text.trim(),
            password: _passCtrl.text,
            role: 'driver',
          );
          final lt = loginRes['login_token'] as String;
          final result = await ApiService.completeLogin(loginToken: lt);
          final user = result['user'] as Map<String, dynamic>;
          await UserSession.saveUser(
            firstName: user['first_name'] ?? '',
            lastName: user['last_name'] ?? '',
            email: user['email'] ?? '',
            phone: user['phone'] ?? '',
            userId: user['id'] as int?,
            role: 'driver',
          );
          await UserSession.saveMode('driver');
          final vStatus = user['verification_status'] as String? ?? 'none';
          if (!mounted) return;
          setState(() => _loading = false);
          if (vStatus == 'approved') {
            Navigator.of(context).pushAndRemoveUntil(
              slideFromRightRoute(const DriverHomeScreen()),
              (_) => false,
            );
          } else {
            Navigator.of(context).pushAndRemoveUntil(
              slideFromRightRoute(const DriverPendingReviewScreen()),
              (_) => false,
            );
          }
          return;
        } catch (_) {
          // Retry also failed
        }
      }
      if (!mounted) return;
      setState(() {
        _loading = false;
        _errorText = S.of(context).connectionError;
      });
      return;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            // ── Top bar ──
            Container(
              padding: EdgeInsets.only(top: pad.top + 8, left: 4, right: 16),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.directions_car_filled_rounded,
                          color: _gold,
                          size: 16,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          S.of(context).driverBadge,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            Expanded(
              child: FadeTransition(
                opacity: _fade,
                child: SlideTransition(
                  position: _slide,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),

                        // ── Heading ──
                        ShaderMask(
                          shaderCallback: (r) => const LinearGradient(
                            colors: [_goldLight, _gold],
                          ).createShader(r),
                          child: Text(
                            S.of(context).welcomeBackDriver,
                            style: GoogleFonts.cinzel(
                              fontSize: 30,
                              fontWeight: FontWeight.w900,
                              color: Colors.white,
                              height: 1.2,
                              letterSpacing: 0.5,
                            ),
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          S.of(context).signInToEarn,
                          style: TextStyle(
                            fontSize: 15,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                        const SizedBox(height: 40),

                        // ── Email field ──
                        _buildField(
                          controller: _emailCtrl,
                          label: S.of(context).emailOrPhone,
                          icon: Icons.person_outline_rounded,
                          keyboardType: TextInputType.emailAddress,
                        ),
                        const SizedBox(height: 18),

                        // ── Password field ──
                        _buildField(
                          controller: _passCtrl,
                          label: S.of(context).passwordLabel,
                          icon: Icons.lock_outline_rounded,
                          obscure: _obscure,
                          suffix: IconButton(
                            icon: Icon(
                              _obscure
                                  ? Icons.visibility_off_outlined
                                  : Icons.visibility_outlined,
                              color: Colors.white38,
                              size: 20,
                            ),
                            onPressed: () =>
                                setState(() => _obscure = !_obscure),
                          ),
                        ),

                        if (_errorText != null) ...[
                          const SizedBox(height: 12),
                          Text(
                            _errorText!,
                            style: const TextStyle(
                              color: Colors.redAccent,
                              fontSize: 13,
                            ),
                          ),
                        ],

                        const SizedBox(height: 12),
                        Align(
                          alignment: Alignment.centerRight,
                          child: GestureDetector(
                            onTap: () {
                              Navigator.of(context).push(
                                slideFromRightRoute(
                                  const ForgotPasswordScreen(),
                                ),
                              );
                            },
                            child: Text(
                              S.of(context).forgotPassword,
                              style: TextStyle(
                                color: _gold,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 36),

                        // ── Login button ──
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: ElevatedButton(
                            onPressed: _canLogin && !_loading
                                ? _handleLogin
                                : null,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _canLogin
                                  ? _gold
                                  : Colors.white12,
                              foregroundColor: Colors.black,
                              disabledBackgroundColor: Colors.white12,
                              disabledForegroundColor: Colors.white24,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                              elevation: _canLogin ? 4 : 0,
                              shadowColor: _gold.withValues(alpha: 0.4),
                            ),
                            child: _loading
                                ? const SizedBox(
                                    width: 22,
                                    height: 22,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.black,
                                    ),
                                  )
                                : Text(
                                    S.of(context).signIn,
                                    style: TextStyle(
                                      fontSize: 17,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                          ),
                        ),

                        const SizedBox(height: 40),

                        // ── Divider ──
                        Row(
                          children: [
                            Expanded(
                              child: Divider(
                                color: Colors.white12,
                                thickness: 1,
                              ),
                            ),
                            Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: Text(
                                S.of(context).orDivider,
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(
                                color: Colors.white12,
                                thickness: 1,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 32),

                        // ── Sign up to drive ──
                        SizedBox(
                          width: double.infinity,
                          height: 54,
                          child: OutlinedButton.icon(
                            onPressed: () {
                              Navigator.of(context).push(
                                slideFromRightRoute(const DriverSignupScreen()),
                              );
                            },
                            icon: const Icon(
                              Icons.person_add_alt_1_rounded,
                              size: 20,
                            ),
                            label: Text(
                              S.of(context).signUpToDrive,
                              style: const TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              foregroundColor: _gold,
                              side: BorderSide(
                                color: _gold.withValues(alpha: 0.5),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(30),
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // ── Back to rider ──
                        Center(
                          child: GestureDetector(
                            onTap: () => Navigator.of(context).pop(),
                            child: Text.rich(
                              TextSpan(
                                text: S.of(context).lookingToRide,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white54,
                                ),
                                children: [
                                  TextSpan(
                                    text: S.of(context).switchToRider,
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w700,
                                      decoration: TextDecoration.underline,
                                      decorationColor: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        const SizedBox(height: 40),
                      ],
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

  Widget _buildField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return TextField(
      controller: controller,
      obscureText: obscure,
      keyboardType: keyboardType,
      style: const TextStyle(color: Colors.white, fontSize: 16),
      cursorColor: _gold,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white38, fontSize: 15),
        prefixIcon: Icon(icon, color: _gold, size: 20),
        suffixIcon: suffix,
        filled: true,
        fillColor: Colors.white.withValues(alpha: 0.06),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: Colors.white12),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(16),
          borderSide: BorderSide(color: _gold, width: 1.5),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 18,
        ),
      ),
    );
  }
}
