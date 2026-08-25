import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../config/page_transitions.dart';
import '../../widgets/neu_style.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/user_session.dart';
import '../welcome_screen.dart';
import 'onboarding/driver_approved_celebration_screen.dart';
import 'onboarding/driver_todo_screen.dart';
import '../../l10n/app_localizations.dart';
import '../../services/firebase_auth_recovery.dart';

/// Shown after a driver submits their application.
/// Polls the backend every 2 seconds for dispatch approval.
///
/// NOT a prison (2026-08-24): the driver can leave with back, and the
/// app-open route for a pending driver now lands on the to-do hub
/// ([DriverTodoScreen], which already shows "In review"). This screen stays
/// as the live status/transitional view; approval detected here goes to the
/// new celebration flow.
class DriverPendingReviewScreen extends StatefulWidget {
  const DriverPendingReviewScreen({super.key});

  @override
  State<DriverPendingReviewScreen> createState() =>
      _DriverPendingReviewScreenState();
}

class _DriverPendingReviewScreenState extends State<DriverPendingReviewScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);
  static const _green = Color(0xFF4CAF50);

  Timer? _pollTimer;
  final List<StreamSubscription> _subscriptions = [];
  String _status = 'pending'; // pending | approved | rejected
  String? _rejectionReason;
  bool _navigating = false; // guard against double-navigation

  late AnimationController _pulseCtrl;
  late AnimationController _dotCtrl;
  late AnimationController _approvedCtrl;
  late Animation<double> _approvedScale;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat(reverse: true);

    _dotCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat();

    _approvedCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _approvedScale = CurvedAnimation(
      parent: _approvedCtrl,
      curve: Curves.elasticOut,
    );

    // Pre-seed status from local cache so rejected drivers don't flash pending UI
    LocalDataService.getDriverApprovalStatus().then((cached) {
      if (mounted && cached == 'rejected' && _status != 'rejected') {
        setState(() => _status = 'rejected');
      }
    });

    _checkImmediateAndPoll();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pollTimer?.cancel();
    } else if (state == AppLifecycleState.resumed) {
      _checkImmediateAndPoll();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _pollTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    _pulseCtrl.dispose();
    _dotCtrl.dispose();
    _approvedCtrl.dispose();
    super.dispose();
  }

  // ═══════════════════════════════════════════════════════════════════════
  //  APPROVAL DETECTION — NUCLEAR APPROACH
  //  Three parallel channels: Firestore listeners, one-shot .get(), API poll
  // ═══════════════════════════════════════════════════════════════════════

  Future<void> _checkImmediateAndPoll() async {
    // 1. Ensure Firebase Auth (Firestore rules require auth) — retry up to 3 times
    for (int attempt = 0; attempt < 3; attempt++) {
      try {
        if (FirebaseAuth.instance.currentUser == null) {
          await FirebaseAuthRecovery.ensureSignedIn();
          debugPrint('[PendingReview] Firebase Auth OK (attempt ${attempt + 1})');
        }
        break; // success
      } catch (e) {
        debugPrint('[PendingReview] Firebase Auth attempt ${attempt + 1} failed: $e');
        if (attempt < 2) await Future<void>.delayed(const Duration(seconds: 2));
      }
    }

    // 2. Get the user's SQL ID (used for doc IDs like "sql_42")
    final user = await UserSession.getUser();
    final userIdStr = user?['userId'] ?? '';
    final userIdInt = int.tryParse(userIdStr) ?? 0;

    debugPrint('[PendingReview] loading user data');

    // 3. Attach real-time listeners on ALL collections × doc ID formats
    if (userIdInt > 0) {
      _attachAllListeners(userIdInt);
      // 4. Also do immediate one-shot .get() on all docs
      unawaited(_immediateFirestoreCheck(userIdInt));
    }

    // 5. Check backend API immediately
    await _checkApiOnce();

    // 6. Start polling fallback (every 10s)
    _startPolling(userIdInt);
  }

  /// Attach real-time snapshot listeners on every collection/docId combination.
  void _attachAllListeners(int userIdInt) {
    final docId = 'sql_$userIdInt';
    final collections = ['verifications', 'drivers', 'users'];

    for (final col in collections) {
      // Listen by doc ID: e.g. drivers/sql_42
      final sub = FirebaseFirestore.instance
          .collection(col)
          .doc(docId)
          .snapshots()
          .listen((snap) {
        if (!mounted || _navigating) return;
        if (!snap.exists) return;
        final data = snap.data() ?? {};
        debugPrint('[PendingReview] LISTENER FIRED $col/$docId → $data');
        _processData(data);
      }, onError: (e) {
        debugPrint('[PendingReview] Listener error $col/$docId: $e');
      });
      _subscriptions.add(sub);
    }

    // Also a query-based listener on verifications by userId field
    // (catches docs regardless of ID format)
    final querySub = FirebaseFirestore.instance
        .collection('verifications')
        .where('userId', isEqualTo: userIdInt)
        .snapshots()
        .listen((snapshot) {
      if (!mounted || _navigating) return;
      for (final doc in snapshot.docs) {
        final data = doc.data();
        debugPrint('[PendingReview] QUERY LISTENER verifications/${doc.id} → $data');
        _processData(data);
        if (_navigating) return;
      }
    }, onError: (e) {
      debugPrint('[PendingReview] Verifications query listener error: $e');
    });
    _subscriptions.add(querySub);
  }

  /// One-shot .get() on all possible document locations.
  Future<void> _immediateFirestoreCheck(int userIdInt) async {
    final docId = 'sql_$userIdInt';
    final checks = [
      ['drivers', docId],
      ['verifications', docId],
      ['users', docId],
    ];
    for (final pair in checks) {
      if (_navigating || !mounted) return;
      try {
        final snap = await FirebaseFirestore.instance
            .collection(pair[0])
            .doc(pair[1])
            .get()
            .timeout(const Duration(seconds: 5));
        if (!mounted || _navigating) return;
        if (snap.exists) {
          final data = snap.data() ?? {};
          debugPrint('[PendingReview] GET ${pair[0]}/${pair[1]} → $data');
          _processData(data);
        }
      } catch (e) {
        debugPrint('[PendingReview] GET ${pair[0]}/${pair[1]} error: $e');
      }
    }
  }

  /// Central status detection from any Firestore document data map.
  void _processData(Map<String, dynamic> data) {
    if (_navigating || !mounted) return;

    final driverStatus = data['driver_status'] as String? ?? '';
    final status = data['status'] as String? ?? '';
    final verificationStatus = data['verificationStatus'] as String? ?? '';
    final approvalStatus = data['approvalStatus'] as String? ?? '';

    // Only the markers the dispatch decision itself writes may open this
    // gate: the backend's write_approval sets all of these atomically, and
    // nowhere else. `status == 'active'` used to count — but that is
    // ACCOUNT status, rewritten by sync_driver on every routine sync
    // (signup, location, profile), so a brand-new driver who was never
    // reviewed got walked straight into the "approved" cinematic.
    // `isVerified` is mirrored by those same routine syncs, so it goes too:
    // isApproved + the *Status fields cover every real approval.
    final isApproved = driverStatus == 'approved' ||
        status == 'approved' ||
        data['isApproved'] == true ||
        verificationStatus == 'approved' ||
        approvalStatus == 'approved';

    final isRejected = !isApproved &&
        (driverStatus == 'rejected' ||
            status == 'rejected' ||
            approvalStatus == 'rejected' ||
            verificationStatus == 'rejected');

    if (isApproved && _status != 'approved') {
      debugPrint('[PendingReview] ✅ APPROVED detected — navigating');
      _handleApproved();
    } else if (isRejected && _status != 'rejected') {
      final reason = data['reason'] as String? ??
          data['verificationReason'] as String? ??
          (mounted ? S.of(context).applicationNotApproved : 'Application not approved');
      debugPrint('[PendingReview] ❌ REJECTED detected — reason: $reason');
      _handleRejected(reason);
    }
  }

  void _handleApproved() {
    if (_navigating || !mounted) return;
    _navigating = true;
    _pollTimer?.cancel();
    LocalDataService.setDriverApprovalStatus('approved');
    _saveStatusToPrefs('approved');
    _goApproved();
  }

  void _handleRejected(String reason) {
    if (_navigating || !mounted) return;
    _pollTimer?.cancel();
    LocalDataService.setDriverApprovalStatus('rejected');
    _saveStatusToPrefs('rejected');
    if (mounted) {
      setState(() {
        _status = 'rejected';
        _rejectionReason = reason;
      });
    }
  }

  /// Check the backend REST API once.
  Future<void> _checkApiOnce() async {
    // Try primary endpoint
    try {
      final result = await ApiService.getDriverApprovalStatus();
      final status =
          result['approval_status'] as String? ??
          result['status'] as String? ??
          'pending';
      debugPrint('[PendingReview] API driver-approval-status=$status');
      if (!mounted || _navigating) return;
      if (status == 'approved') {
        _handleApproved();
        return;
      } else if (status == 'rejected') {
        final reason =
            result['rejection_reason'] as String? ??
            result['reason'] as String? ??
            S.of(context).applicationNotApproved;
        _handleRejected(reason);
        return;
      }
    } catch (e) {
      debugPrint('[PendingReview] API driver-approval-status error: $e');
    }
    // Fallback: try secondary endpoint
    if (_navigating || !mounted) return;
    try {
      final result2 = await ApiService.getVerificationStatus();
      final status2 =
          result2['approval_status'] as String? ??
          result2['verification_status'] as String? ??
          result2['status'] as String? ??
          'pending';
      debugPrint('[PendingReview] API verification-status=$status2');
      if (!mounted || _navigating) return;
      if (status2 == 'approved') {
        _handleApproved();
      } else if (status2 == 'rejected') {
        final reason =
            result2['rejection_reason'] as String? ??
            result2['verification_reason'] as String? ??
            result2['reason'] as String? ??
            S.of(context).applicationNotApproved;
        _handleRejected(reason);
      }
    } catch (e) {
      debugPrint('[PendingReview] API verification-status error: $e');
    }
  }

  /// Persists driver status to SharedPreferences for splash screen routing.
  Future<void> _saveStatusToPrefs(String status) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('driver_status', status);
    } catch (e) {
      debugPrint('[PendingReview] Failed to save driver_status to prefs: $e');
    }
  }

  /// Polling fallback — API call every 10s + Firestore re-check.
  void _startPolling(int userIdInt) {
    _pollTimer?.cancel();
    // Fallback poll at 2 s — fast enough that if the Firestore listener
    // misses the dispatch approval (cold start, network flap) the driver
    // still sees it within ~2 s. FCM push is primary, Firestore is
    // secondary, this poll is the safety net.
    _pollTimer = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || _navigating) {
        _pollTimer?.cancel();
        return;
      }
      // Try API first
      await _checkApiOnce();
      // Also re-check Firestore (in case listeners failed silently)
      if (userIdInt > 0 && !_navigating && mounted) {
        await _immediateFirestoreCheck(userIdInt);
      }
    });
  }

  Future<void> _enterApp() async {
    if (!mounted) return;
    // New post-approval flow: celebration → payout gate → first-trip guide.
    Navigator.of(context).pushAndRemoveUntil(
      onboardingFadeSlideRoute(const DriverApprovedCelebrationScreen()),
      (_) => false,
    );
  }

  /// Navigate to the new approved celebration screen.
  void _goApproved() async {
    if (!mounted) return;
    // _navigating is already true (set by _handleApproved) — do NOT re-check it here.
    _pollTimer?.cancel();
    for (final sub in _subscriptions) {
      sub.cancel();
    }
    _subscriptions.clear();
    // Brief delay to show success state before transitioning
    await Future<void>.delayed(const Duration(milliseconds: 1200));
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      onboardingFadeSlideRoute(const DriverApprovedCelebrationScreen()),
      (_) => false,
    );
  }

  /// Rejected: reset local status and send them to the to-do hub to fix
  /// the failed items (keeps the same account — no logout/re-register).
  Future<void> _tryAgain() async {
    await LocalDataService.setDriverApprovalStatus('none');
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      onboardingFadeSlideRoute(const DriverTodoScreen()),
      (_) => false,
    );
  }

  Future<void> _logout() async {
    await UserSession.logout();
    await ApiService.clearToken();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      smoothFadeRoute(const WelcomeScreen()),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    // No PopScope prison (2026-08-24): the driver can leave with back —
    // dispose() already stops the poll and the Firestore listeners.
    return Scaffold(
        backgroundColor: neuBase,
        body: SafeArea(
          child: _status == 'approved'
              ? _buildApproved()
              : _status == 'rejected'
              ? _buildRejected()
              : _buildPending(),
        ),
      );
  }

  // ── Pending ─────────────────────────────────────────────────────────────
  Widget _buildPending() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const Spacer(flex: 3),

          // Animated pulsing icon
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, child) => Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _gold.withValues(alpha: 0.08 + _pulseCtrl.value * 0.06),
                border: Border.all(
                  color: _gold.withValues(alpha: 0.3 + _pulseCtrl.value * 0.3),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(
                      alpha: 0.1 + _pulseCtrl.value * 0.15,
                    ),
                    blurRadius: 30 + _pulseCtrl.value * 20,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: const Icon(
                Icons.hourglass_top_rounded,
                color: _gold,
                size: 48,
              ),
            ),
          ),

          const SizedBox(height: 36),

          Text(
            S.of(context).applicationUnderReview,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),

          const SizedBox(height: 16),

          Text(
            S.of(context).reviewDescription,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 15,
              height: 1.5,
            ),
          ),

          const SizedBox(height: 40),

          // Status steps
          _statusRow(
            icon: Icons.check_circle_rounded,
            iconColor: _green,
            title: S.of(context).applicationSubmitted,
            subtitle: S.of(context).allDocsReceived,
            done: true,
          ),
          const SizedBox(height: 16),
          _statusRow(
            icon: Icons.shield_rounded,
            iconColor: _gold,
            title: S.of(context).backgroundCheck,
            subtitle: S.of(context).identityDocsVerified,
            done: false,
            active: true,
          ),
          const SizedBox(height: 16),
          _statusRow(
            icon: Icons.verified_rounded,
            iconColor: Colors.white24,
            title: S.of(context).finalReview,
            subtitle: S.of(context).dispatchApprovalPending,
            done: false,
          ),

          const Spacer(flex: 3),

          // Dot animation
          _buildDots(),
          const SizedBox(height: 12),
          Text(
            S.of(context).checkingForUpdates,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 12,
            ),
          ),

          const SizedBox(height: 32),

          // Logout button
          TextButton(
            onPressed: _logout,
            child: Text(
              S.of(context).logOut,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.4),
                fontSize: 14,
              ),
            ),
          ),

          const SizedBox(height: 16),
        ],
      ),
    );
  }

  Widget _buildDots() {
    return AnimatedBuilder(
      animation: _dotCtrl,
      builder: (_, dot) {
        return Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(3, (i) {
            final phase = ((_dotCtrl.value * 3) - i).clamp(0.0, 1.0);
            final opacity = (phase < 0.5 ? phase : 1.0 - phase) * 2;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 4),
              width: 7,
              height: 7,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _gold.withValues(alpha: opacity.clamp(0.2, 1.0)),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _statusRow({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required bool done,
    bool active = false,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: done
                ? _green.withValues(alpha: 0.15)
                : active
                ? _gold.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.05),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: TextStyle(
                  color: done || active ? Colors.white : Colors.white38,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
              Text(
                subtitle,
                style: TextStyle(
                  color: Colors.white.withValues(
                    alpha: done || active ? 0.5 : 0.25,
                  ),
                  fontSize: 12,
                ),
              ),
            ],
          ),
        ),
        if (active) ...[
          AnimatedBuilder(
            animation: _pulseCtrl,
            builder: (_, child) => Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _gold.withValues(alpha: 0.5 + _pulseCtrl.value * 0.5),
              ),
            ),
          ),
        ],
      ],
    );
  }

  // ── Approved ────────────────────────────────────────────────────────────
  Widget _buildApproved() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const SizedBox(height: 40),

          // Big check icon
          FadeTransition(
            opacity: _approvedScale,
            child: Container(
              width: 110,
              height: 110,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: _green.withValues(alpha: 0.15),
                border: Border.all(
                  color: _green.withValues(alpha: 0.45),
                  width: 2,
                ),
                boxShadow: [
                  BoxShadow(
                    color: _green.withValues(alpha: 0.25),
                    blurRadius: 30,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: const Icon(Icons.check_rounded, color: _green, size: 54),
            ),
          ),

          const SizedBox(height: 32),

          Text(
            S.of(context).youreApproved,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
            ),
          ),

          const SizedBox(height: 12),

          Text(
            S.of(context).welcomeDriverTeam,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 15,
              height: 1.5,
            ),
          ),

          const SizedBox(height: 36),

          // All steps checked
          _doneRow(
            Icons.check_circle_rounded,
            S.of(context).applicationSubmittedDone,
            S.of(context).allDocsReceivedDone,
          ),
          const SizedBox(height: 16),
          _doneRow(
            Icons.shield_rounded,
            S.of(context).backgroundCheckDone,
            S.of(context).identityVerifiedDone,
          ),
          const SizedBox(height: 16),
          _doneRow(
            Icons.verified_rounded,
            S.of(context).finalReviewDone,
            S.of(context).approvedByDispatch,
          ),

          const Spacer(),

          // Next button
          SizedBox(
            width: double.infinity,
            height: 56,
            child: ElevatedButton(
              onPressed: _enterApp,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                elevation: 4,
                shadowColor: _gold.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: Text(
                S.of(context).next,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),

          const SizedBox(height: 32),
        ],
      ),
    );
  }

  Widget _doneRow(IconData icon, String title, String subtitle) {
    return Row(
      children: [
        Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: _green.withValues(alpha: 0.15),
          ),
          child: Icon(icon, color: _green, size: 20),
        ),
        const SizedBox(width: 14),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            Text(
              subtitle,
              style: TextStyle(
                color: _green.withValues(alpha: 0.8),
                fontSize: 12,
              ),
            ),
          ],
        ),
      ],
    );
  }

  // ── Rejected ────────────────────────────────────────────────────────────
  Widget _buildRejected() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Column(
        children: [
          const Spacer(flex: 3),
          Container(
            width: 110,
            height: 110,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.red.withValues(alpha: 0.12),
              border: Border.all(
                color: Colors.red.withValues(alpha: 0.4),
                width: 2,
              ),
            ),
            child: const Icon(
              Icons.cancel_rounded,
              color: Colors.redAccent,
              size: 52,
            ),
          ),
          const SizedBox(height: 32),
          Text(
            S.of(context).applicationRejected,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 26,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            S.of(context).rejectionDescription,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 15,
              height: 1.5,
            ),
          ),
          if (_rejectionReason != null) ...[
            const SizedBox(height: 20),
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.red.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: Colors.red.withValues(alpha: 0.2)),
              ),
              child: Text(
                _rejectionReason!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.65),
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ),
          ],
          const Spacer(flex: 3),
          // Try again — clears data and goes to signup form
          SizedBox(
            width: double.infinity,
            height: 54,
            child: ElevatedButton(
              onPressed: _tryAgain,
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                elevation: 4,
                shadowColor: _gold.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                S.of(context).tryAgain,
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(height: 14),
          SizedBox(
            width: double.infinity,
            height: 48,
            child: OutlinedButton(
              onPressed: _logout,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white54,
                side: const BorderSide(color: Colors.white12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
              ),
              child: Text(
                S.of(context).backToWelcome,
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(height: 24),
        ],
      ),
    );
  }
}
