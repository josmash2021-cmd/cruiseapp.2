import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'welcome_screen.dart';
import 'home_screen.dart';
import 'driver/driver_home_screen.dart';
import 'driver/driver_pending_review_screen.dart';
import 'driver/onboarding/driver_todo_screen.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../services/user_session.dart';
import '../services/preload_service.dart';
import '../main.dart' show heavyInit;
import '../services/firebase_auth_recovery.dart';

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});

  @override
  State<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends State<SplashScreen>
    with TickerProviderStateMixin {
  static const _bg = Color(0xFF000000);
  static const _gold = Color(0xFFE8C547);

  static const _letters = ['C', 'R', 'U', 'I', 'S', 'E'];

  // ── Phase 1: Logo bloom, then staggered letter entrance (1400ms total) ──
  late AnimationController _entranceCtrl;
  late List<Animation<double>> _letterSlide; // Y offset: 60→0
  late List<Animation<double>> _letterFade; // opacity: 0→1
  late List<Animation<double>> _letterScale; // scale: 0.3→1
  // The car-in-circle logo blooms first; the letters cascade a beat after.
  late Animation<double> _logoFade;
  late Animation<double> _logoScale;

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
      duration: const Duration(milliseconds: 1400),
    );

    // Logo bloom: gentle fade + overshoot scale, the first thing you see.
    _logoFade = Tween<double>(begin: 0.0, end: 1.0).animate(CurvedAnimation(
      parent: _entranceCtrl,
      curve: const Interval(0.0, 0.30, curve: Curves.easeOut),
    ));
    _logoScale = Tween<double>(begin: 0.45, end: 1.0).animate(CurvedAnimation(
      parent: _entranceCtrl,
      curve: const Interval(0.0, 0.45, curve: Curves.easeOutBack),
    ));

    _letterSlide = [];
    _letterFade = [];
    _letterScale = [];

    for (int i = 0; i < _letters.length; i++) {
      // Each letter is staggered by ~140ms behind the logo, spans ~560ms
      final start = (0.12 + i * 0.10).clamp(0.0, 1.0);
      final end = (start + 0.40).clamp(0.0, 1.0);

      final curveInterval = Interval(start, end, curve: Curves.elasticOut);
      final fadeInterval = Interval(
        start,
        (start + 0.22).clamp(0.0, 1.0),
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

    // Capture context before any awaits (use_build_context_synchronously)
    final nav = Navigator.of(context);

    // First-run OS permissions, while the animation plays: precise location
    // and notifications. No-ops on later launches (already granted) and on
    // web. Not awaited — the dialogs float over the splash and the sequence
    // keeps its timing either way.
    unawaited(_requestFirstRunPermissions());

    // Start heavy init in parallel with the splash animation
    final initFuture = heavyInit().timeout(
      const Duration(seconds: 12),
      onTimeout: () {
        debugPrint('[SplashScreen] heavyInit timeout - continuing anyway');
      },
    ).catchError((e) {
      debugPrint('[SplashScreen] heavyInit error: $e');
    });

    // ── Fast login check: if already logged in, skip CRUISE animation ──
    // Never let this decide whether the app starts.
    //
    // It reads the token through flutter_secure_storage, which needs
    // window.crypto.subtle on web — absent unless the page is served from
    // localhost or https. Unguarded it threw before the entrance animation
    // had run, so _runSequence aborted and the splash stayed black with no
    // letters and no navigation.
    bool loggedIn = false;
    try {
      loggedIn = await UserSession.isLoggedInLocal();
    } catch (e) {
      debugPrint('[Splash] stored-session check failed: $e');
    }
    if (_disposed || !mounted) return;

    if (loggedIn) {
      // Pre-load in background while we resolve the destination.
      unawaited(PreloadService.preloadAll(context).catchError((_) {}));

      final destination = await _computeDestination(initFuture).catchError((e) {
        debugPrint('[SplashScreen] destination error: $e');
        return const WelcomeScreen() as Widget;
      });
      if (_disposed || !mounted) return;

      nav.pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => destination,
          transitionDuration: const Duration(milliseconds: 400),
          reverseTransitionDuration: Duration.zero,
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeIn),
            child: child,
          ),
        ),
      );
      return;
    }

    // ── Not logged in: show full CRUISE splash animation ──

    // Pre-load GPS, user data, map tiles, images — ALL in parallel
    final preloadFuture = PreloadService.preloadAll(context).timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        debugPrint('[SplashScreen] preload timeout - continuing anyway');
      },
    ).catchError((e) {
      debugPrint('[SplashScreen] preload error: $e');
    });

    // ── Start destination computation IMMEDIATELY at the very beginning ──
    // This gives it the full animation duration (~3.7 s) to resolve instead
    // of only the 800 ms exit animation, eliminating the black-screen gap.
    final destinationFuture = _computeDestination(initFuture).catchError((e) {
      debugPrint('[SplashScreen] destination error: $e');
      return const WelcomeScreen() as Widget;
    });

    // Phase 1 — letters bounce in (no artificial pre-delay)
    await _entranceCtrl.forward().orCancel.catchError((_) {});
    if (_disposed) return;

    // Phase 2 — shimmer glow pulse
    await _glowCtrl.forward().orCancel.catchError((_) {});
    if (_disposed) return;

    // ── Wait for destination + preload to be ready BEFORE starting exit ──
    // This guarantees zero black-screen gap: destination is pre-resolved
    // and all data is pre-loaded, so the next screen renders instantly.
    final results = await Future.wait([
      destinationFuture,
      preloadFuture,
    ]);
    final destination = results[0] as Widget;
    if (_disposed || !mounted) return;

    // Phase 3 — scale up + fade out
    _exitCtrl.forward().orCancel.catchError((_) {});

    // Navigate immediately — the incoming screen fades IN while
    // the splash fades OUT, overlapping perfectly with no black gap.
    if (_disposed || !mounted) return;

    nav.pushReplacement(
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

  /// Ask for the two permissions the whole app depends on, on first launch:
  /// location (precise — pickup pins and driver matching need it) and
  /// notifications. permission_handler skips the dialog when the permission
  /// was already decided, so later launches cost nothing.
  Future<void> _requestFirstRunPermissions() async {
    try {
      // Small beat so the splash is actually on screen before the first
      // system dialog lands on top of it.
      await Future.delayed(const Duration(milliseconds: 600));
      final loc = await Permission.locationWhenInUse.status;
      if (!loc.isGranted) {
        await Permission.locationWhenInUse.request();
      }
      final notif = await Permission.notification.status;
      if (!notif.isGranted) {
        await Permission.notification.request();
      }
    } catch (e) {
      debugPrint('[Splash] first-run permission request failed: $e');
    }
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

    // ── Validate token against backend — BUT DON'T BLOCK navigation ──
    // If backend is slow, user still gets in with cached session
    // Home screens will re-check in background
    await initFuture;
    unawaited(_validateTokenInBackground());

    // ── User has local session — route by cached role immediately ──
    final mode = await UserSession.getMode();

    if (mode == 'driver') {
      await UserSession.initPhotoNotifier();

      // ── CRITICAL FIX: Check if driver was EVER approved ──
      // If driver was approved before, NEVER send them back to pending review
      // even if backend is down or cache is stale.
      final wasEverApproved = await LocalDataService.wasDriverEverApproved();
      if (wasEverApproved) {
        debugPrint('[SplashScreen] Driver was previously approved — going to home');
        unawaited(_refreshApprovalStatusInBackground());
        return const DriverHomeScreen();
      }

      // ── Read approval status from local cache first (instant) ──
      final cachedStatus = await LocalDataService.getDriverApprovalStatus();

      if (_isApprovedStatus(cachedStatus)) {
        // Verified → go straight to DriverHomeScreen
        unawaited(_backgroundProfileSync());
        return const DriverHomeScreen();
      }

      if (cachedStatus == 'pending' || cachedStatus == 'rejected') {
        // ALWAYS hit the backend API — the cache may be stale if dispatch
        // approved the driver while the app was closed. Total budget for
        // the live re-check is ~4 s: a slow network must never leave the
        // unapproved driver staring at the splash; on timeout the cached
        // status decides (pending → to-do hub, rejected → pending review).
        final budget = Stopwatch()..start();
        await initFuture;
        try {
          final approvalResult = await ApiService.getDriverApprovalStatus()
              .timeout(const Duration(seconds: 4));
          final liveStatus =
              approvalResult['approval_status'] as String? ??
              approvalResult['status'] as String? ??
              cachedStatus;
          if (_isApprovedStatus(liveStatus)) {
            await LocalDataService.setDriverApprovalStatus('approved');
            unawaited(_backgroundProfileSync());
            return const DriverHomeScreen();
          } else if (liveStatus == 'rejected') {
            await LocalDataService.setDriverApprovalStatus('rejected');
            return const DriverPendingReviewScreen();
          }
        } catch (e) {
          debugPrint('[SplashScreen] Live approval check failed, using cache: $e');
        }
        // Fallback: also try Firestore (covers edge case where API is down
        // but Firestore has the approval) — only inside the ~4 s budget.
        if (cachedStatus == 'pending' && budget.elapsedMilliseconds < 4000) {
          final fsStatus = await _quickFirestoreDriverCheck().timeout(
            const Duration(seconds: 3),
            onTimeout: () => 'pending',
          );
          if (fsStatus == 'approved') {
            await LocalDataService.setDriverApprovalStatus('approved');
            unawaited(_backgroundProfileSync());
            return const DriverHomeScreen();
          }
        }
        // If API failed and we have no evidence of approval, the to-do hub
        // shows the "In review" state (no more pending-review prison).
        // But ONLY if cache actually says pending — never default unknown to pending.
        return const DriverTodoScreen();
      }

      // ── No cached status ('none') → check Firestore FIRST, then backend ──
      // This prevents approved drivers from being stuck in "Reviewing" after
      // app update when SharedPreferences are cleared but Firestore has the truth.
      await initFuture;

      // 1) Try Firestore first (fast, works offline, survives app updates)
      // — capped so a dead network can't hold the splash hostage.
      final fsStatus = await _quickFirestoreDriverCheck().timeout(
        const Duration(seconds: 4),
        onTimeout: () => 'pending',
      );
      if (fsStatus == 'approved') {
        await LocalDataService.setDriverApprovalStatus('approved');
        unawaited(_backgroundProfileSync());
        return const DriverHomeScreen();
      }
      if (fsStatus == 'rejected') {
        await LocalDataService.setDriverApprovalStatus('rejected');
        return const DriverPendingReviewScreen();
      }

      // 2) Firestore says pending → confirm with backend API
      try {
        final approvalResult = await ApiService.getDriverApprovalStatus()
            .timeout(const Duration(seconds: 3));
        final status =
            approvalResult['approval_status'] as String? ??
            approvalResult['status'] as String? ??
            'pending';

        // Save to local cache for next time
        await LocalDataService.setDriverApprovalStatus(status);

        if (_isApprovedStatus(status)) {
          unawaited(_backgroundProfileSync());
          return const DriverHomeScreen();
        } else {
          return const DriverTodoScreen();
        }
      } catch (e) {
        debugPrint('[SplashScreen] Driver approval check failed: $e');
        // ── CRITICAL: Network error — do NOT default to pending for approved drivers ──
        // Try getMe() as a last-resort fallback; if that also fails, be lenient
        // and let the driver into the app. The home screen will re-check.
        try {
          final me = await ApiService.getMe().timeout(const Duration(seconds: 3));
          if (me != null && _meIndicatesApproved(me)) {
            debugPrint('[SplashScreen] getMe fallback indicates approved — letting driver in');
            await LocalDataService.setDriverApprovalStatus('approved');
            unawaited(_backgroundProfileSync());
            return const DriverHomeScreen();
          }
        } catch (_) {}
        // If we truly cannot determine status, show the to-do hub (it
        // renders "In review") BUT log it.
        // This should only happen for genuinely new/unapproved drivers.
        debugPrint('[SplashScreen] WARNING: defaulting to to-do hub — all checks failed');
        return const DriverTodoScreen();
      }
    } else {
      await UserSession.initPhotoNotifier();

      // Fire background profile sync + account status check (no await)
      unawaited(_backgroundProfileSync());

      return const HomeScreen();
    }
  }

  /// Returns true for any status string that indicates an approved driver.
  /// The backend may return 'approved', 'active', 'online', 'clear', or 'verified'
  /// depending on the endpoint and database state.
  bool _isApprovedStatus(String? status) {
    if (status == null) return false;
    final s = status.toLowerCase().trim();
    return s == 'approved' ||
        s == 'active' ||
        s == 'online' ||
        s == 'clear' ||
        s == 'verified';
  }

  /// Returns true if the user object from getMe() indicates an approved driver.
  /// Checks both verification_status and is_verified fields.
  bool _meIndicatesApproved(Map<String, dynamic> me) {
    final vStatus = (me['verification_status'] as String? ?? '').toLowerCase().trim();
    if (_isApprovedStatus(vStatus)) return true;
    final isVerified = me['is_verified'] == true || me['isVerified'] == true;
    if (isVerified) return true;
    final accountStatus = (me['status'] as String? ?? '').toLowerCase().trim();
    return _isApprovedStatus(accountStatus);
  }

  /// Checks Firestore directly (one-time .get()) to see if this driver has
  /// already been approved by dispatch — e.g. while the app was closed.
  /// Returns 'approved', 'rejected', or 'pending'.
  Future<String> _quickFirestoreDriverCheck() async {
    try {
      // Ensure Firebase Auth is active (Firestore rules require auth)
      if (FirebaseAuth.instance.currentUser == null) {
        await FirebaseAuthRecovery.ensureSignedIn();
      }
      final user = await UserSession.getUser();
      final userIdStr = user?['userId'];
      if (userIdStr == null || userIdStr.isEmpty) return 'pending';
      final userIdInt = int.tryParse(userIdStr) ?? 0;
      if (userIdInt <= 0) return 'pending';

      final docId = 'sql_$userIdInt';

      // Check drivers collection first — cache-first for instant reads
      DocumentSnapshot<Map<String, dynamic>>? driversDoc;
      try {
        driversDoc = await FirebaseFirestore.instance
            .collection('drivers')
            .doc(docId)
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 1));
      } catch (_) {}
      driversDoc ??= await FirebaseFirestore.instance
          .collection('drivers')
          .doc(docId)
          .get()
          .timeout(const Duration(seconds: 4));
      if (driversDoc.exists) {
        final d = driversDoc.data() ?? {};
        if (_isApprovedData(d)) return 'approved';
        if (_isRejectedData(d)) return 'rejected';
      }

      // Fall back to verifications doc — cache-first
      DocumentSnapshot<Map<String, dynamic>>? verDoc;
      try {
        verDoc = await FirebaseFirestore.instance
            .collection('verifications')
            .doc(docId)
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 1));
      } catch (_) {}
      verDoc ??= await FirebaseFirestore.instance
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

  bool _isApprovedData(Map<String, dynamic> d) {
    final status = (d['status'] as String? ?? '').toLowerCase().trim();
    final driverStatus = (d['driver_status'] as String? ?? '').toLowerCase().trim();
    final verificationStatus = (d['verificationStatus'] as String? ?? '').toLowerCase().trim();
    final approvalStatus = (d['approvalStatus'] as String? ?? '').toLowerCase().trim();
    // Same rule as the pending-review gate: only markers written by the
    // dispatch decision (backend write_approval sets them atomically).
    // 'active'/'online'/'clear' are ACCOUNT states that routine driver
    // syncs write for people who were never reviewed — counting them let
    // unapproved drivers skip the pending screen straight into the app.
    return driverStatus == 'approved' ||
        status == 'approved' ||
        d['isApproved'] == true ||
        verificationStatus == 'approved' ||
        approvalStatus == 'approved';
  }

  bool _isRejectedData(Map<String, dynamic> d) =>
      d['driver_status'] == 'rejected' ||
      d['status'] == 'rejected' ||
      d['approvalStatus'] == 'rejected';

  /// Refresh approval status in background for already-approved drivers.
  /// Keeps the local cache fresh without blocking navigation.
  Future<void> _refreshApprovalStatusInBackground() async {
    try {
      final approvalResult = await ApiService.getDriverApprovalStatus()
          .timeout(const Duration(seconds: 5));
      final liveStatus =
          approvalResult['approval_status'] as String? ??
          approvalResult['status'] as String? ??
          'approved'; // default to approved if we can't tell
      await LocalDataService.setDriverApprovalStatus(liveStatus);
      debugPrint('[SplashScreen] Approval status refreshed: $liveStatus');
    } catch (e) {
      debugPrint('[SplashScreen] Approval refresh failed (keeping approved): $e');
    }
  }

  /// Validates token in background — if invalid, logs out user.
  /// Does NOT block navigation — user gets in with cached session.
  Future<void> _validateTokenInBackground() async {
    try {
      // Tri-state on purpose. The old check used getMe(), which returns
      // null for a rejected token AND for a 502 — so every Railway
      // redeploy signed everyone out mid-session. Only a definitive
      // rejection (false) may clear the session; `null` means the server
      // was unreachable or unhealthy and the session stays put.
      final valid = await ApiService.isTokenValid();
      if (valid == false) {
        debugPrint('[Splash] Token rejected by server — logging out in background');
        await ApiService.clearToken();
        await UserSession.logout();
        // Note: user is already on home screen, they'll be redirected on next app open
      } else if (valid == null) {
        debugPrint('[Splash] Token validation inconclusive — keeping session');
      }
    } catch (e) {
      debugPrint('[Splash] Token validation failed (network?): $e');
      // Network error — be lenient, let user in with cached session
    }
  }

  /// Syncs profile and preloads dashboard data in background.
  /// This makes the home screen load instantly because data is already cached.
  Future<void> _backgroundProfileSync() async {
    try {
      // Preload dashboard data while splash is still showing
      // This caches profile, earnings, stats, and active trip
      await ApiService.getDashboard().timeout(const Duration(seconds: 5));
      debugPrint('[Splash] Dashboard preloaded ✓');
    } catch (e) {
      debugPrint('[Splash] Dashboard preload failed (will load on home): $e');
    }
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
                        // Logo bloom — the car-in-circle badge opens the show
                        _buildLogo(),
                        const SizedBox(height: 22),
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
                        const SizedBox(height: 20),
                        // IN RIDE tagline — two centered lines, white over gold
                        Opacity(
                          opacity: ((glow * 1.5).clamp(0.0, 1.0)) * _taglineExitFade.value,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Text(
                                'IN  RIDE,',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.cinzel(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w400,
                                  color: Colors.white,
                                  letterSpacing: 6,
                                ),
                              ),
                              const SizedBox(height: 12),
                              Text(
                                'PREMIUM  EXPERIENCE',
                                textAlign: TextAlign.center,
                                style: GoogleFonts.cinzel(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w400,
                                  color: _gold.withValues(alpha: 0.7),
                                  letterSpacing: 6,
                                ),
                              ),
                            ],
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

  Widget _buildLogo() {
    final glow = _glowCtrl.value;
    return Opacity(
      opacity: _logoFade.value,
      child: Transform.scale(
        scale: _logoScale.value,
        child: SizedBox(
          width: 150,
          height: 150,
          child: Stack(
            alignment: Alignment.center,
            children: [
              // Halo behind the badge — swells with the shimmer phase.
              Container(
                width: 150,
                height: 150,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      _gold.withValues(alpha: 0.26 + glow * 0.26),
                      _gold.withValues(alpha: 0.09 + glow * 0.09),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.55, 1.0],
                  ),
                ),
              ),
              Image.asset(
                'assets/images/cruise_logo.png',
                width: 118,
                height: 118,
              ),
            ],
          ),
        ),
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

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 1.5),
      child: Text(
        letter,
        style: GoogleFonts.cinzel(
          fontSize: 46,
          fontWeight: FontWeight.w900,
          color: Colors.white,
          letterSpacing: 6,
          shadows: [
            Shadow(
              color: Colors.white.withValues(
                  alpha: 0.22 + glowIntensity * 0.38),
              blurRadius: 18 + glowIntensity * 34,
            ),
          ],
        ),
      ),
    );
  }
}
