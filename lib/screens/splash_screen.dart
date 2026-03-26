import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
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

  static const _letters = ['C', 'R', 'U', 'I', 'S', 'E'];

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
  late List<Animation<double>> _letterExitFade;
  late Animation<double> _taglineExitFade;
  late Animation<double> _decoExitFade;

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
      duration: const Duration(milliseconds: 800),
    );
    _exitFade = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(
      parent: _exitCtrl,
      curve: const Interval(0.5, 1.0, curve: Curves.easeInQuart),
    ));
    _exitScale = Tween<double>(
      begin: 1.0,
      end: 1.2,
    ).animate(CurvedAnimation(parent: _exitCtrl, curve: Curves.easeIn));

    // Staggered per-letter fade-out: C fades first, E fades last
    _letterExitFade = List.generate(_letters.length, (i) {
      final start = (i * 0.10).clamp(0.0, 1.0);
      final end = (start + 0.35).clamp(0.0, 1.0);
      return Tween<double>(begin: 1.0, end: 0.0).animate(
        CurvedAnimation(
          parent: _exitCtrl,
          curve: Interval(start, end, curve: Curves.easeIn),
        ),
      );
    });
    // Tagline fades out early (before letters finish)
    _taglineExitFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _exitCtrl,
        curve: const Interval(0.0, 0.35, curve: Curves.easeIn),
      ),
    );
    // Decorative lines fade out alongside tagline
    _decoExitFade = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(
        parent: _exitCtrl,
        curve: const Interval(0.0, 0.30, curve: Curves.easeIn),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════
  //  SEQUENCE
  // ═══════════════════════════════════════════════════════

  Future<void> _runSequence() async {
    if (_disposed) return;

    // Start heavy init in parallel with the splash animation
    final initFuture = heavyInit().timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        debugPrint('[SplashScreen] heavyInit timeout - continuing anyway');
      },
    ).catchError((e) {
      debugPrint('[SplashScreen] heavyInit error: $e');
    });

    // ── Start destination computation IMMEDIATELY at the very beginning ──
    // This gives it the full animation duration (~3.7 s) to resolve instead
    // of only the 800 ms exit animation, eliminating the black-screen gap.
    final destinationFuture = _computeDestination(initFuture).catchError((e) {
      debugPrint('[SplashScreen] destination error: $e');
      return const WelcomeScreen() as Widget;
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

    // ── Wait for destination to be ready BEFORE starting exit animation ──
    // This guarantees zero black-screen gap: destination is pre-resolved,
    // so the navigator push is instant.
    final destination = await destinationFuture;
    if (_disposed || !mounted) return;

    // Phase 3 — scale up + fade out
    _exitCtrl.forward().orCancel.catchError((_) {});

    // Navigate almost immediately — the incoming screen fades IN while
    // the splash fades OUT, overlapping perfectly with no black gap.
    await Future.delayed(const Duration(milliseconds: 50));
    if (_disposed || !mounted) return;

    Navigator.of(context).pushReplacement(
      PageRouteBuilder(
        pageBuilder: (_, __, ___) => destination,
        transitionDuration: const Duration(milliseconds: 600),
        reverseTransitionDuration: Duration.zero,
        transitionsBuilder: (_, anim, __, child) => FadeTransition(
          opacity: CurvedAnimation(parent: anim, curve: Curves.easeIn),
          child: child,
        ),
      ),
    );
  }

  /// Computes which screen to navigate to. Runs in parallel with the full
  /// splash animation (started at the very beginning) so there is no
  /// black-screen gap after the splash fades out.
  ///
  /// Uses fast local-only auth check (no network calls) for instant routing.
  /// Network-dependent checks (account status, driver approval, profile sync)
  /// happen in the background after navigation.
  Future<Widget> _computeDestination(Future<void> initFuture) async {
    // Start the initFuture but don't block on it for local auth check
    unawaited(initFuture);

    // ── Fast path: check local session (no network) ──
    final loggedIn = await UserSession.isLoggedInLocal();
    if (!loggedIn) {
      // No local session — wait for init then show welcome
      await initFuture;
      return const WelcomeScreen();
    }

    // ── User has local session — route by cached role immediately ──
    final mode = await UserSession.getMode();

    if (mode == 'driver') {
      await UserSession.initPhotoNotifier();

      // ── Read approval status from local cache first (instant) ──
      final cachedStatus = await LocalDataService.getDriverApprovalStatus();

      if (cachedStatus == 'approved') {
        // Verified → go straight to DriverHomeScreen
        unawaited(_backgroundProfileSync());
        return const DriverHomeScreen();
      }

      if (cachedStatus == 'pending' || cachedStatus == 'rejected') {
        // Quick Firestore check: driver may have been approved while app was closed
        if (cachedStatus == 'pending') {
          final liveStatus = await _quickFirestoreDriverCheck();
          if (liveStatus == 'approved') {
            await LocalDataService.setDriverApprovalStatus('approved');
            unawaited(_backgroundProfileSync());
            return const DriverHomeScreen();
          }
        }
        return const DriverPendingReviewScreen();
      }

      // ── No cached status ('none') → fetch from backend (one time only) ──
      await initFuture;
      try {
        final approvalResult = await ApiService.getDriverApprovalStatus()
            .timeout(const Duration(seconds: 3));
        final status =
            approvalResult['approval_status'] as String? ??
            approvalResult['status'] as String? ??
            'pending';

        // Save to local cache for next time
        await LocalDataService.setDriverApprovalStatus(status);

        if (status == 'approved') {
          unawaited(_backgroundProfileSync());
          return const DriverHomeScreen();
        } else {
          return const DriverPendingReviewScreen();
        }
      } catch (e) {
        debugPrint('[SplashScreen] Driver approval check failed: $e');
        // Network error — default to pending for safety
        return const DriverPendingReviewScreen();
      }
    } else {
      await UserSession.initPhotoNotifier();

      // Fire background profile sync + account status check (no await)
      unawaited(_backgroundProfileSync());

      return const HomeScreen();
    }
  }

  /// Checks Firestore directly (one-time .get()) to see if this driver has
  /// already been approved by dispatch — e.g. while the app was closed.
  /// Returns 'approved', 'rejected', or 'pending'.
  Future<String> _quickFirestoreDriverCheck() async {
    try {
      // Ensure Firebase Auth is active (Firestore rules require auth)
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuth.instance.signInAnonymously();
      }
      final user = await UserSession.getUser();
      final userIdStr = user?['userId'];
      if (userIdStr == null || userIdStr.isEmpty) return 'pending';
      final userIdInt = int.tryParse(userIdStr) ?? 0;
      if (userIdInt <= 0) return 'pending';

      final docId = 'sql_$userIdInt';

      // Check drivers collection first (most reliable — dispatch writes here)
      final driversDoc = await FirebaseFirestore.instance
          .collection('drivers')
          .doc(docId)
          .get()
          .timeout(const Duration(seconds: 4));
      if (driversDoc.exists) {
        final d = driversDoc.data() ?? {};
        if (_isApprovedData(d)) return 'approved';
        if (_isRejectedData(d)) return 'rejected';
      }

      // Fall back to verifications doc
      final verDoc = await FirebaseFirestore.instance
          .collection('verifications')
          .doc(docId)
          .get()
          .timeout(const Duration(seconds: 4));
      if (verDoc.exists) {
        final d = verDoc.data() ?? {};
        if (_isApprovedData(d)) return 'approved';
        if (_isRejectedData(d)) return 'rejected';
      }
    } catch (e) {
      debugPrint('[SplashScreen] Firestore driver check failed: $e');
    }
    return 'pending';
  }

  bool _isApprovedData(Map<String, dynamic> d) =>
      d['driver_status'] == 'approved' ||
      d['status'] == 'approved' ||
      d['status'] == 'active' ||
      d['isVerified'] == true ||
      d['isApproved'] == true ||
      d['verificationStatus'] == 'approved' ||
      d['approvalStatus'] == 'approved';

  bool _isRejectedData(Map<String, dynamic> d) =>
      d['driver_status'] == 'rejected' ||
      d['status'] == 'rejected' ||
      d['approvalStatus'] == 'rejected';

  /// Syncs profile and checks account status in background after navigation.
  /// If account is blocked/deactivated, the home screens' own periodic
  /// status checks (every 30s) will handle the redirect.
  Future<void> _backgroundProfileSync() async {
    try {
      await UserSession.isLoggedIn(); // full sync with backend
    } catch (_) {}
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
          final glow = _glowCtrl.value;
          return Opacity(
            opacity: _exitFade.value,
            child: Transform.scale(
              scale: _exitScale.value,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  // ── Background radial glow ──
                  Container(
                    decoration: BoxDecoration(
                      gradient: RadialGradient(
                        center: Alignment.center,
                        radius: 0.75,
                        colors: [
                          Color.lerp(
                            const Color(0xFF1A1500),
                            const Color(0xFF0A0900),
                            1 - glow * 0.6,
                          )!,
                          _bg,
                        ],
                        stops: const [0.0, 1.0],
                      ),
                    ),
                  ),
                  // ── Center content ──
                  Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Decorative top line
                        Opacity(
                          opacity: glow * _decoExitFade.value,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildDecoLine(60),
                              const SizedBox(width: 10),
                              _buildDiamond(),
                              const SizedBox(width: 10),
                              _buildDecoLine(60),
                            ],
                          ),
                        ),
                        const SizedBox(height: 14),
                        // CRUISE letters
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: List.generate(_letters.length, (i) {
                            return Transform.translate(
                              offset: Offset(0, _letterSlide[i].value),
                              child: Transform.scale(
                                scale: _letterScale[i].value,
                                child: Opacity(
                                  opacity: _letterFade[i].value *
                                      _letterExitFade[i].value,
                                  child: _buildLetter(_letters[i], i),
                                ),
                              ),
                            );
                          }),
                        ),
                        const SizedBox(height: 8),
                        // IN RIDE tagline
                        Opacity(
                          opacity: ((glow * 1.5).clamp(0.0, 1.0)) * _taglineExitFade.value,
                          child: Text(
                            'PREMIUM  RIDE  EXPERIENCE',
                            style: GoogleFonts.cinzel(
                              fontSize: 11,
                              fontWeight: FontWeight.w400,
                              color: _gold.withValues(alpha: 0.7),
                              letterSpacing: 6,
                            ),
                          ),
                        ),
                        const SizedBox(height: 14),
                        // Decorative bottom line
                        Opacity(
                          opacity: glow * _decoExitFade.value,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              _buildDecoLine(60),
                              const SizedBox(width: 10),
                              _buildDiamond(),
                              const SizedBox(width: 10),
                              _buildDecoLine(60),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildDecoLine(double width) {
    return Container(
      width: width,
      height: 0.8,
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            Colors.transparent,
            _gold.withValues(alpha: 0.7),
            Colors.transparent,
          ],
        ),
      ),
    );
  }

  Widget _buildDiamond() {
    return Transform.rotate(
      angle: 0.785398,
      child: Container(
        width: 5,
        height: 5,
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.8),
        ),
      ),
    );
  }

  Widget _buildLetter(String letter, int index) {
    final glowIntensity = _glowCtrl.value;
    final glowColor = Color.lerp(_gold, _goldBright, glowIntensity)!;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      child: ShaderMask(
        shaderCallback: (bounds) {
          return LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              _goldBright,
              glowColor,
              _gold,
            ],
            stops: const [0.0, 0.4, 1.0],
          ).createShader(bounds);
        },
        child: Text(
          letter,
          style: GoogleFonts.cinzel(
            fontSize: 46,
            fontWeight: FontWeight.w900,
            color: Colors.white,
            letterSpacing: 6,
            shadows: [
              Shadow(
                color: _gold.withValues(alpha: 0.5 + glowIntensity * 0.5),
                blurRadius: 20 + glowIntensity * 40,
              ),
              Shadow(
                color: _goldBright.withValues(alpha: glowIntensity * 0.4),
                blurRadius: 50,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
