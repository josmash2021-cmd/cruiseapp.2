import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:local_auth/local_auth.dart';
import 'welcome_screen.dart';
import 'account_deactivated_screen.dart';
import 'home_screen.dart';
import 'driver/driver_home_screen.dart';
import 'driver/driver_pending_review_screen.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/user_session.dart';
import '../main.dart' show heavyInit;

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  static const _bg = Color(0xFF000000);
  static const _gold = Color(0xFFE8C547);
  static const _goldBright = Color(0xFFFFF1C1);

  static const _letters = ['C', 'r', 'u', 'i', 's', 'e'];

  // ── Phase 1: Staggered letter entrance (1200ms total) ──
  late AnimationController _entranceCtrl;
  late List<Animation<double>> _letterSlide; // Y offset: 60→0
  late List<Animation<double>> _letterFade; // opacity: 0→1
  late List<Animation<double>> _letterScale; // scale: 0.3→1

  // ── Phase 2: Glow shimmer pulse after all letters land ──
  late AnimationController _glowCtrl;

  // ── Phase 3: Scale up slightly + fade out ──
  late AnimationController _exitCtrl;
  late Animation<double> _exitFade;
  late Animation<double> _exitScale;

  bool _disposed = false;

  @override
  void initState() {
    super.initState();

    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarColor: _bg,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );

    _setupEntranceAnimations();
    _setupGlowAnimation();
    _setupExitAnimation();
    _runSequence();
  }

  // ═══════════════════════════════════════════════════════
  //  ANIMATION SETUP
  // ═══════════════════════════════════════════════════════

  void _setupEntranceAnimations() {
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );

    _letterSlide = [];
    _letterFade = [];
    _letterScale = [];

    for (int i = 0; i < _letters.length; i++) {
      // Each letter is staggered by ~100ms, spans ~500ms
      final start = (i * 0.12).clamp(0.0, 1.0);
      final end = (start + 0.45).clamp(0.0, 1.0);

      final curveInterval = Interval(start, end, curve: Curves.elasticOut);
      final fadeInterval = Interval(
        start,
        (start + 0.25).clamp(0.0, 1.0),
        curve: Curves.easeOut,
      );

      _letterSlide.add(
        Tween<double>(
          begin: 60.0,
          end: 0.0,
        ).animate(CurvedAnimation(parent: _entranceCtrl, curve: curveInterval)),
      );

      _letterFade.add(
        Tween<double>(
          begin: 0.0,
          end: 1.0,
        ).animate(CurvedAnimation(parent: _entranceCtrl, curve: fadeInterval)),
      );

      _letterScale.add(
        Tween<double>(
          begin: 0.3,
          end: 1.0,
        ).animate(CurvedAnimation(parent: _entranceCtrl, curve: curveInterval)),
      );
    }
  }

  void _setupGlowAnimation() {
    _glowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  void _setupExitAnimation() {
    _exitCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _exitFade = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _exitCtrl, curve: Curves.easeInQuart));
    _exitScale = Tween<double>(
      begin: 1.0,
      end: 1.35,
    ).animate(CurvedAnimation(parent: _exitCtrl, curve: Curves.easeIn));
  }

  // ═══════════════════════════════════════════════════════
  //  SEQUENCE
  // ═══════════════════════════════════════════════════════

  Future<void> _runSequence() async {
    if (_disposed) return;

    // Start heavy init in parallel with the splash animation
    final initFuture = heavyInit().timeout(
      const Duration(seconds: 5),
      onTimeout: () {
        debugPrint('[SplashScreen] heavyInit timeout - continuing anyway');
      },
    ).catchError((e) {
      debugPrint('[SplashScreen] heavyInit error: $e');
    });

    // Small delay on launch
    await Future.delayed(const Duration(milliseconds: 300));
    if (_disposed) return;

    // Phase 1 — letters bounce in
    await _entranceCtrl.forward().orCancel.catchError((_) {});
    if (_disposed) return;

    // Phase 2 — shimmer glow pulse
    await _glowCtrl.forward().orCancel.catchError((_) {});
    if (_disposed) return;

    // Hold for a beat
    await Future.delayed(const Duration(milliseconds: 500));
    if (_disposed) return;

    // Ensure heavy init finished before navigating (with timeout)
    await initFuture;
    if (_disposed) return;

    // Phase 3 — scale up + fade out
    await _exitCtrl.forward().orCancel.catchError((_) {});
    if (_disposed) return;

    _navigate();
  }

  void _navigate() async {
    if (!mounted) return;
    final loggedIn = await UserSession.isLoggedIn();
    if (!mounted) return;

    Widget destination;
    if (loggedIn) {
      // ── Biometric gate ──
      final biometricOn = await LocalDataService.isBiometricLoginEnabled();
      if (biometricOn && mounted) {
        final auth = LocalAuthentication();
        final canCheck =
            await auth.canCheckBiometrics || await auth.isDeviceSupported();
        if (canCheck) {
          try {
            final ok = await auth.authenticate(
              localizedReason: 'Sign in to Cruise',
              options: const AuthenticationOptions(
                stickyAuth: true,
                biometricOnly: true,
              ),
            );
            if (!ok) {
              // Failed — sign out and go to welcome
              await UserSession.logout();
              if (!mounted) return;
              destination = const WelcomeScreen();
              Navigator.of(
                context,
              ).pushReplacement(smoothFadeRoute(destination, durationMs: 400));
              return;
            }
          } catch (_) {
            // Biometric error — fall through to normal login
          }
        }
      }
      if (!mounted) return;
      // ── Check if dispatch blocked/deleted/deactivated account ──
      try {
        final status = await ApiService.getAccountStatus().timeout(
          const Duration(seconds: 3),
          onTimeout: () => 'active',
        );
        if (status == 'blocked' || status == 'deleted') {
          await UserSession.logout();
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            smoothFadeRoute(const WelcomeScreen(), durationMs: 400),
          );
          return;
        }
        if (status == 'deactivated') {
          if (!mounted) return;
          Navigator.of(context).pushReplacement(
            smoothFadeRoute(const AccountDeactivatedScreen(), durationMs: 400),
          );
          return;
        }
      } catch (e) {
        debugPrint('[SplashScreen] Account status check failed: $e');
        // Backend unreachable — allow login from cache
      }
      if (!mounted) return;
      final mode = await UserSession.getMode();
      if (mode == 'driver') {
        // Check driver approval status + profile photo
        try {
          final approvalResult = await ApiService.getDriverApprovalStatus().timeout(
            const Duration(seconds: 3),
            onTimeout: () => {'status': 'approved'},
          );
          final vStatus =
              approvalResult['approval_status'] as String? ??
              approvalResult['status'] as String? ??
              'none';
          if (vStatus == 'approved') {
            destination = const DriverHomeScreen();
          } else {
            // pending, rejected, none → show review screen
            if (!mounted) return;
            Navigator.of(context).pushReplacement(
              smoothFadeRoute(
                const DriverPendingReviewScreen(),
                durationMs: 400,
              ),
            );
            return;
          }
        } catch (e) {
          debugPrint('[SplashScreen] Driver approval check failed: $e');
          // Backend unreachable — let them through
          destination = const DriverHomeScreen();
        }
      } else {
        destination = const HomeScreen();
      }
    } else {
      destination = const WelcomeScreen();
    }

    if (!mounted) return;
    Navigator.of(
      context,
    ).pushReplacement(smoothFadeRoute(destination, durationMs: 400));
  }

  @override
  void dispose() {
    _disposed = true;
    _entranceCtrl.dispose();
    _glowCtrl.dispose();
    _exitCtrl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: AnimatedBuilder(
        animation: Listenable.merge([_entranceCtrl, _glowCtrl, _exitCtrl]),
        builder: (context, _) {
          return Opacity(
            opacity: _exitFade.value,
            child: Transform.scale(
              scale: _exitScale.value,
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: List.generate(_letters.length, (i) {
                    return Transform.translate(
                      offset: Offset(0, _letterSlide[i].value),
                      child: Transform.scale(
                        scale: _letterScale[i].value,
                        child: Opacity(
                          opacity: _letterFade[i].value,
                          child: _buildLetter(_letters[i], i),
                        ),
                      ),
                    );
                  }),
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildLetter(String letter, int index) {
    final glowIntensity = _glowCtrl.value;
    final glowColor = Color.lerp(_gold, _goldBright, glowIntensity)!;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 2),
      child: ShaderMask(
        shaderCallback: (bounds) {
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              glowColor,
              _gold,
            ],
            stops: const [0.3, 1.0],
          ).createShader(bounds);
        },
        child: Text(
          letter,
          style: GoogleFonts.montserrat(
            fontSize: 56,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: -2,
            shadows: [
              Shadow(
                color: _gold.withOpacity(0.5 + glowIntensity * 0.5),
                blurRadius: 20 + glowIntensity * 30,
              ),
              Shadow(
                color: _goldBright.withOpacity(glowIntensity * 0.3),
                blurRadius: 40,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
