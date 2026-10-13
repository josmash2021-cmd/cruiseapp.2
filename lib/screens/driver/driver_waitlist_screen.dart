import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/user_session.dart';
import '../help_screen.dart';
import '../welcome_screen.dart';
import 'driver_pending_review_screen.dart';
import 'onboarding/driver_approved_celebration_screen.dart';

/// Waitlist page (user spec 2026-10-13): dispatch moved the driver to the
/// waitlist (backend `verification_status == 'waitlist'`).
///
/// Navy/gold kill-page family — same pop-up entrance as the maintenance
/// page. The art is composed from WIDGETS ONLY: Shorebird OTA patches don't
/// carry new assets (maintenance_hero lesson), so no bundled or network
/// images here — ever.
///
/// NOT a prison (same rule as pending review, 2026-08-24): back works, and
/// the X mirrors pending review's explicit exit (logout → welcome). The
/// screen can be the ROOT route when the splash routes here, so a bare pop
/// is not a safe exit — that's why the X logs out instead.
///
/// Auto-exit: polls the approval status every 10 s — approved → the same
/// celebration the pending-review poll lands on; anything else (rejected /
/// back to plain pending) → DriverPendingReviewScreen, which owns those
/// states and keeps its own watcher.
class DriverWaitlistScreen extends StatefulWidget {
  const DriverWaitlistScreen({super.key});

  @override
  State<DriverWaitlistScreen> createState() => _DriverWaitlistScreenState();
}

class _DriverWaitlistScreenState extends State<DriverWaitlistScreen>
    with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFF0A1322); // navy black, like the mock
  static const _navy = Color(0xFF16263F); // soft navy disc
  static const _gold = Color(0xFFE8C547);
  static const _pollEvery = Duration(seconds: 10);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 550),
  )..forward();

  Timer? _poll;
  bool _navigating = false; // guard against double-navigation

  @override
  void initState() {
    super.initState();
    _poll = Timer.periodic(_pollEvery, (_) => _recheck());
  }

  @override
  void dispose() {
    _poll?.cancel();
    _anim.dispose();
    super.dispose();
  }

  Future<void> _recheck() async {
    if (_navigating) return;
    Map<String, dynamic> result;
    try {
      result = await ApiService.getDriverApprovalStatus();
    } catch (e) {
      // Network flap — stay put; the next tick retries.
      debugPrint('[Waitlist] approval re-check failed: $e');
      return;
    }
    if (!mounted || _navigating) return;
    final status = result['approval_status'] as String? ??
        result['status'] as String? ??
        'waitlist';
    if (status == 'waitlist') return;
    _navigating = true;
    _poll?.cancel();
    await LocalDataService.setDriverApprovalStatus(status);
    if (!mounted) return;
    if (status == 'approved') {
      // Same landing the pending-review poll uses on approval.
      Navigator.of(context).pushAndRemoveUntil(
        onboardingFadeSlideRoute(const DriverApprovedCelebrationScreen()),
        (_) => false,
      );
    } else {
      // Rejected (or back to plain pending) — the live status screen owns it.
      Navigator.of(context).pushReplacement(
        onboardingFadeSlideRoute(const DriverPendingReviewScreen()),
      );
    }
  }

  /// X (top right): pending review's explicit exit — logout, back to the
  /// welcome flow. Never a bare pop (see class doc: can be the root route).
  Future<void> _exit() async {
    _poll?.cancel();
    await UserSession.logout();
    await ApiService.clearToken();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      smoothFadeRoute(const WelcomeScreen()),
      (_) => false,
    );
  }

  /// Support (top left): the existing dispatch support chat.
  void _openSupport() {
    Navigator.of(context).push(slideFromRightRoute(const HelpScreen()));
  }

  @override
  Widget build(BuildContext context) {
    // No PopScope prison: back leaves too — dispose() stops the poll.
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Column(
                children: [
                  const Spacer(flex: 3),
                  // Pop-up entrance: scale from the centre with a soft back
                  // ease, ahead of the text — same family as maintenance.
                  ScaleTransition(
                    scale: CurvedAnimation(
                      parent: _anim,
                      curve: const Interval(0, 0.6, curve: Curves.easeOutBack),
                    ),
                    child: FadeTransition(
                      opacity: CurvedAnimation(
                        parent: _anim,
                        curve: const Interval(0, 0.45),
                      ),
                      child: _buildArt(),
                    ),
                  ),
                  const SizedBox(height: 40),
                  _fadeSlide(
                    Text(
                      S.of(context).waitlistTitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    0.25,
                    0.7,
                  ),
                  const SizedBox(height: 14),
                  _fadeSlide(
                    Text(
                      S.of(context).waitlistBody,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF9AA3B8),
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    0.4,
                    0.85,
                  ),
                  const Spacer(flex: 4),
                ],
              ),
            ),
            // Support chat — top LEFT.
            Positioned(
              top: 8,
              left: 8,
              child: _cornerButton(
                icon: Icons.support_agent_rounded,
                tooltip: S.of(context).waitlistSupport,
                onPressed: _openSupport,
              ),
            ),
            // Exit — top RIGHT.
            Positioned(
              top: 8,
              right: 8,
              child: _cornerButton(
                icon: Icons.close_rounded,
                tooltip: S.of(context).waitlistExitHint,
                onPressed: _exit,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Hourglass over a soft navy disc with a little ID card — the "Navy and
  /// Gold Waitlist" mock, composed from widgets only (no assets, OTA-safe).
  Widget _buildArt() {
    return SizedBox(
      width: 220,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            width: 200,
            height: 200,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _navy,
              border: Border.all(
                color: _gold.withValues(alpha: 0.25),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: _gold.withValues(alpha: 0.12),
                  blurRadius: 48,
                  spreadRadius: 6,
                ),
              ],
            ),
          ),
          const Icon(
            Icons.hourglass_top_rounded,
            color: _gold,
            size: 110,
          ),
          Positioned(
            right: 8,
            bottom: 24,
            child: Container(
              width: 58,
              height: 44,
              decoration: BoxDecoration(
                color: const Color(0xFF1D3050),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _gold.withValues(alpha: 0.5),
                  width: 1.2,
                ),
              ),
              child: const Icon(
                Icons.badge_outlined,
                color: _gold,
                size: 26,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cornerButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      onPressed: onPressed,
      tooltip: tooltip,
      style: IconButton.styleFrom(
        backgroundColor: _navy.withValues(alpha: 0.6),
        foregroundColor: Colors.white.withValues(alpha: 0.75),
      ),
      icon: Icon(icon, size: 22),
    );
  }

  Widget _fadeSlide(Widget child, double begin, double end) {
    final curved = CurvedAnimation(
      parent: _anim,
      curve: Interval(begin, end, curve: Curves.easeOutCubic),
    );
    return FadeTransition(
      opacity: curved,
      child: SlideTransition(
        position: Tween<Offset>(
          begin: const Offset(0, 0.24),
          end: Offset.zero,
        ).animate(curved),
        child: child,
      ),
    );
  }
}
