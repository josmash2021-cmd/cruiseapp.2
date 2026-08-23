import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import '../../config/app_theme.dart';
import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/user_session.dart';
import '../../widgets/neu_style.dart';
import '../forgot_password_screen.dart';
import '../login_password_screen.dart';
import 'driver_welcome_screen.dart';
import 'driver_home_screen.dart';
import 'driver_pending_review_screen.dart';

/// Driver login screen — email + password for existing drivers.
class DriverLoginScreen extends StatefulWidget {
  const DriverLoginScreen({super.key});

  @override
  State<DriverLoginScreen> createState() => _DriverLoginScreenState();
}

class _DriverLoginScreenState extends State<DriverLoginScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
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
    WidgetsBinding.instance.addObserver(this);
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _entranceCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      if (!_entranceCtrl.isCompleted) _entranceCtrl.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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

      Map<String, dynamic> user;

      // Demo accounts return access_token directly (skip OTP)
      if (loginRes.containsKey('access_token')) {
        await ApiService.saveToken(loginRes['access_token'] as String);
        if (loginRes.containsKey('refresh_token')) {
          await ApiService.saveRefreshToken(loginRes['refresh_token'] as String);
        }
        user = loginRes['user'] as Map<String, dynamic>;
      } else {
        final loginToken = loginRes['login_token'] as String;
        // Step 2: Exchange login_token for full JWT (auto-saves token)
        final result = await ApiService.completeLogin(loginToken: loginToken);
        user = result['user'] as Map<String, dynamic>;
      }

      // Save user data locally
      await UserSession.saveUser(
        firstName: user['first_name'] ?? '',
        lastName: user['last_name'] ?? '',
        email: user['email'] ?? '',
        phone: user['phone'] ?? '',
        photoUrl: user['photo_url'] as String?,
        userId: (user['id'] is num) ? (user['id'] as num).toInt() : int.tryParse(user['id']?.toString() ?? ''),
        role: 'driver',
      );
      await UserSession.saveMode('driver');
      await UserSession.initPhotoNotifier();

      // Check driver approval status
      final vStatus = user['verification_status'] as String? ?? 'none';
      final isVerified = user['is_verified'] == true || user['isVerified'] == true;
      final accountStatus = (user['status'] as String? ?? '').toLowerCase().trim();
      final bool driverIsApproved = _isApprovedStatus(vStatus) ||
          _isApprovedStatus(accountStatus) ||
          isVerified;

      // Cache it locally so splash screen routes correctly on next restart
      if (driverIsApproved) {
        await LocalDataService.setDriverApprovalStatus('approved');
      } else if (vStatus == 'pending' || vStatus == 'rejected') {
        await LocalDataService.setDriverApprovalStatus(vStatus);
      }
      if (!mounted) return;
      setState(() => _loading = false);

      if (driverIsApproved) {
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
            photoUrl: user['photo_url'] as String?,
            userId: (user['id'] is num) ? (user['id'] as num).toInt() : int.tryParse(user['id']?.toString() ?? ''),
            role: 'driver',
          );
          await UserSession.saveMode('driver');
          await UserSession.initPhotoNotifier();
          final vStatus = user['verification_status'] as String? ?? 'none';
          final isVerified = user['is_verified'] == true || user['isVerified'] == true;
          final accountStatus = (user['status'] as String? ?? '').toLowerCase().trim();
          final bool driverIsApproved = _isApprovedStatus(vStatus) ||
              _isApprovedStatus(accountStatus) ||
              isVerified;
          if (!mounted) return;
          setState(() => _loading = false);
          if (driverIsApproved) {
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

  /// Returns true for any status string that indicates an approved driver.
  bool _isApprovedStatus(String? status) {
    if (status == null) return false;
    final s = status.toLowerCase().trim();
    return s == 'approved' ||
        s == 'active' ||
        s == 'online' ||
        s == 'clear' ||
        s == 'verified';
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: neuBase,
      body: GestureDetector(
        onTap: () => FocusScope.of(context).unfocus(),
        child: Column(
          children: [
            // ── Top bar ──
            Container(
              padding: EdgeInsets.only(top: pad.top + 8, left: 16, right: 16),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
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
                ],
              ),
            ),

            Expanded(
              child: FadeTransition(
                opacity: _fade,
                child: SingleChildScrollView(
                    padding: const EdgeInsets.symmetric(horizontal: 28),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 24),

                        // ── Heading ──
                        Text(
                          S.of(context).welcomeBackDriver,
                          style: GoogleFonts.poppins(
                            fontSize: 32,
                            fontWeight: FontWeight.w700,
                            letterSpacing: -0.5,
                            color: c.textPrimary,
                            height: 1.15,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          S.of(context).signInToEarn,
                          style: GoogleFonts.inter(
                            fontSize: 15,
                            color: c.textSecondary,
                          ),
                        ),
                        const SizedBox(height: 40),

                        // ── Email + Password fields (AutofillGroup) ──
                        AutofillGroup(
                          child: Column(
                            children: [
                              _buildField(
                                c,
                                controller: _emailCtrl,
                                hint: S.of(context).emailOrPhone,
                                icon: Icons.person_outline_rounded,
                                keyboardType: TextInputType.emailAddress,
                                autofillHints: const [AutofillHints.email, AutofillHints.username],
                              ),
                              const SizedBox(height: 18),
                              _buildField(
                                c,
                                controller: _passCtrl,
                                hint: S.of(context).passwordLabel,
                                icon: Icons.lock_outline_rounded,
                                obscure: _obscure,
                                autofillHints: const [AutofillHints.password],
                                suffix: IconButton(
                                  icon: Icon(
                                    _obscure
                                        ? Icons.visibility_off_outlined
                                        : Icons.visibility_outlined,
                                    color: c.textTertiary,
                                    size: 20,
                                  ),
                                  onPressed: () =>
                                      setState(() => _obscure = !_obscure),
                                ),
                              ),
                            ],
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
                        GestureDetector(
                          onTap: _canLogin && !_loading ? _handleLogin : null,
                          child: Container(
                            width: double.infinity,
                            height: 56,
                            decoration: _canLogin
                                ? BoxDecoration(
                                    color: _gold,
                                    borderRadius: BorderRadius.circular(16),
                                  )
                                : neuBox(radius: 16, pressed: true),
                            alignment: Alignment.center,
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
                                      color: _canLogin
                                          ? Colors.black
                                          : c.textTertiary,
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
                                color: c.divider,
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
                                  color: c.textTertiary,
                                  fontSize: 13,
                                ),
                              ),
                            ),
                            Expanded(
                              child: Divider(
                                color: c.divider,
                                thickness: 1,
                              ),
                            ),
                          ],
                        ),

                        const SizedBox(height: 32),

                        // ── Sign up to drive ──
                        GestureDetector(
                          onTap: () {
                            Navigator.of(context).push(
                              slideFromRightRoute(const DriverWelcomeScreen()),
                            );
                          },
                          child: Container(
                            width: double.infinity,
                            height: 54,
                            decoration: neuBox(radius: 16, pressed: true),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.person_add_alt_1_rounded,
                                  color: _gold,
                                  size: 20,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  S.of(context).signUpToDrive,
                                  style: const TextStyle(
                                    color: _gold,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        const SizedBox(height: 24),

                        // ── Back to rider ──
                        Center(
                          child: GestureDetector(
                            onTap: () => Navigator.of(context).pushReplacement(
                              slideFromRightRoute(const LoginPasswordScreen()),
                            ),
                            child: Text.rich(
                              TextSpan(
                                text: S.of(context).lookingToRide,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: c.textSecondary,
                                ),
                                children: [
                                  TextSpan(
                                    text: S.of(context).switchToRider,
                                    style: const TextStyle(
                                      color: _gold,
                                      fontWeight: FontWeight.w700,
                                      decoration: TextDecoration.underline,
                                      decorationColor: _gold,
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
          ],
        ),
      ),
    );
  }

  /// Neumorphic pressed-well text field (mirrors the rider create-account
  /// fields in `login_screen.dart`).
  Widget _buildField(
    AppColors c, {
    required TextEditingController controller,
    required String hint,
    required IconData icon,
    bool obscure = false,
    Widget? suffix,
    TextInputType keyboardType = TextInputType.text,
    Iterable<String>? autofillHints,
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
              obscureText: obscure,
              keyboardType: keyboardType,
              autofillHints: autofillHints,
              style: TextStyle(color: c.textPrimary, fontSize: 16),
              cursorColor: _gold,
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(color: c.textTertiary, fontSize: 16),
              ),
            ),
          ),
          if (suffix != null) suffix,
        ],
      ),
    );
  }
}
