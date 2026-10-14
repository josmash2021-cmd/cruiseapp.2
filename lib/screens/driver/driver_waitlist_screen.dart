import 'dart:async';

import 'package:flutter/material.dart';

import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/socket_service.dart';
import '../../services/user_session.dart';
import '../help_screen.dart';
import '../welcome_screen.dart';
import 'onboarding/driver_approved_celebration_screen.dart';
import 'onboarding/driver_todo_screen.dart';

/// Waitlist page (user spec 2026-10-13): dispatch moved the driver to the
/// waitlist (backend `verification_status == 'waitlist'`). Also owns the
/// REJECTED state — the old pending-review page was retired the same day
/// ("esa página de under review elimínala ya que es vieja").
///
/// Matches the "Navy and Gold Waitlist Verification Screen" mock: the real
/// mock illustration (gold hourglass + ID card over the dark-blue cloud)
/// rides above the text. Image chain (user spec 2026-10-13, "que por OTA
/// funcionen las fotos"): bundled `waitlist_hero.png` → backend-hosted
/// `/static/waitlist_hero.png` (OTA patches carry no new assets — the
/// maintenance_hero pattern) → the drawn widget art as the offline last
/// resort. The hero pops in with the exact entrance of the
/// update-required page (scale Interval(0, 0.55, easeOutBack) + fade
/// Interval(0, 0.4)).
///
/// Two variants via the constructor:
///  - [DriverWaitlistScreen.new] — waitlist (gold accent).
///  - [DriverWaitlistScreen.rejected] — application not approved: soft-red
///    accent, the dispatch reason when known, and support as the primary
///    action. The variant is STATE, seeded by the constructor: the 10 s
///    poll flips it in place (rejected ↔ waitlist) instead of stacking
///    routes.
///
/// NOT a prison (same rule as the retired pending review, 2026-08-24):
/// back works, and the X mirrors its explicit exit (logout → welcome). The
/// screen can be the ROOT route when the splash routes here, so a bare pop
/// is not a safe exit — that's why the X logs out instead.
///
/// Auto-exit: polls the approval status every 10 s — approved → the same
/// celebration chain the retired page used (pending→approved still lands on
/// DriverApprovedCelebrationScreen); rejected ↔ waitlist flips the variant.
class DriverWaitlistScreen extends StatefulWidget {
  /// Waitlist variant (gold).
  const DriverWaitlistScreen({super.key})
      : startsRejected = false,
        rejectedReason = null;

  /// Rejected variant (soft red): dispatch denied the application.
  /// [rejectedReason] is the dispatch note when the caller has it — the
  /// 10 s poll refreshes it from the API either way.
  const DriverWaitlistScreen.rejected({super.key, this.rejectedReason})
      : startsRejected = true;

  final bool startsRejected;
  final String? rejectedReason;

  @override
  State<DriverWaitlistScreen> createState() => _DriverWaitlistScreenState();
}

class _DriverWaitlistScreenState extends State<DriverWaitlistScreen>
    with SingleTickerProviderStateMixin {
  static const _bg = Color(0xFF000000); // pure black — same surface as the update-required page (user spec 2026-10-13)
  static const _cloudDark = Color(0xFF1A2A44); // cloud base
  static const _cloudLight = Color(0xFF223753); // cloud bumps
  static const _cardNavy = Color(0xFF1D3050); // little ID card
  static const _gold = Color(0xFFE8C547);
  static const _red = Color(0xFFE57373); // soft red — rejected accent
  static const _pollEvery = Duration(seconds: 10);

  late final AnimationController _anim = AnimationController(
    vsync: this,
    // Same 700 ms controller as the update-required page (user spec
    // 2026-10-13: "animación como la de update required").
    duration: const Duration(milliseconds: 700),
  );

  Timer? _poll;
  // The socket wake-up (2026-10-14 user report: "cuando lo quito de lista
  // de espera la página no se quita como la de update required") — the
  // update-required page dismisses the instant the gate's socket ping lands;
  // this page must hear `account_status_changed` the same way instead of
  // waiting out the 10 s poll. The poll stays as the dead-socket fallback.
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  bool _navigating = false; // guard against double-navigation
  late bool _rejected;
  String? _reason;

  Color get _accent => _rejected ? _red : _gold;

  @override
  void initState() {
    super.initState();
    _rejected = widget.startsRejected;
    _reason = widget.rejectedReason;
    // The entrance starts on the FIRST PAINTED frame, not at field-init
    // (2026-10-14 user report: "de golpe aparece todo incluso el texto") —
    // fired from the lazy field initializer, the controller could consume
    // the animation while the route was still transitioning in.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _anim.forward();
    });
    _poll = Timer.periodic(_pollEvery, (_) => _recheck());
    _statusSub = SocketService.accountStatusStream.listen((_) => _recheck());
    // Rejected routes often arrive without the dispatch note (Firestore
    // branch, push tap) — grab it on the first tick, not 10 s in.
    if (_rejected && (_reason == null || _reason!.isEmpty)) {
      _recheck();
    }
  }

  @override
  void dispose() {
    _poll?.cancel();
    _statusSub?.cancel();
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
        '';
    if (status.isEmpty) return;

    if (status == 'approved') {
      // The approved→celebration chain the retired pending-review page
      // owned — pending/waitlist/rejected all land here on approval.
      _navigating = true;
      _poll?.cancel();
      await LocalDataService.setDriverApprovalStatus('approved');
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        onboardingFadeSlideRoute(const DriverApprovedCelebrationScreen()),
        (_) => false,
      );
      return;
    }

    if (status == 'pending') {
      // Dispatch pulled the account OUT of the waitlist (the panel's
      // un-waitlist button, 2026-10-13) — back to the to-do hub so the
      // driver can fix and re-upload a document.
      _navigating = true;
      _poll?.cancel();
      await LocalDataService.setDriverApprovalStatus('pending');
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        onboardingFadeSlideRoute(const DriverTodoScreen()),
        (_) => false,
      );
      return;
    }

    await LocalDataService.setDriverApprovalStatus(status);
    if (!mounted) return;

    if (status == 'rejected') {
      final reason = result['rejection_reason'] as String? ??
          result['verification_reason'] as String? ??
          result['reason'] as String?;
      if (!_rejected ||
          (reason != null && reason.isNotEmpty && reason != _reason)) {
        setState(() {
          _rejected = true;
          if (reason != null && reason.isNotEmpty) _reason = reason;
        });
      }
      return;
    }

    // waitlist / anything else → the waitlist variant owns it (pending
    // LEAVES the page — the un-waitlist exit above).
    if (_rejected) {
      setState(() {
        _rejected = false;
        _reason = null;
      });
    }
  }

  /// X (top right): the retired page's explicit exit — logout, back to the
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

  /// Support (top left, and the rejected variant's primary action): the
  /// existing dispatch support chat.
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
                  // Hero entrance — the EXACT intervals of the
                  // update-required page (user spec 2026-10-13).
                  ScaleTransition(
                    scale: CurvedAnimation(
                      parent: _anim,
                      curve: const Interval(0, 0.55, curve: Curves.easeOutBack),
                    ),
                    child: FadeTransition(
                      opacity: CurvedAnimation(
                        parent: _anim,
                        curve: const Interval(0, 0.4),
                      ),
                      child: _rejected ? _buildHeroArt() : _buildHeroImage(),
                    ),
                  ),
                  const SizedBox(height: 40),
                  _fadeSlide(
                    Text(
                      _rejected
                          ? S.of(context).waitlistRejectedTitle
                          : S.of(context).waitlistTitle,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    0.3,
                    0.75,
                  ),
                  const SizedBox(height: 14),
                  _fadeSlide(
                    Text(
                      _rejected
                          ? S.of(context).rejectionDescription
                          : S.of(context).waitlistBody,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: Color(0xFF9AA3B8),
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                    0.45,
                    0.9,
                  ),
                  // Dispatch note, when there is one (rejected variant).
                  if (_rejected &&
                      _reason != null &&
                      _reason!.isNotEmpty) ...[
                    const SizedBox(height: 18),
                    _fadeSlide(
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: _red.withValues(alpha: 0.08),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _red.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Text(
                          _reason!,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 13,
                            height: 1.45,
                          ),
                        ),
                      ),
                      0.5,
                      0.95,
                    ),
                  ],
                  const Spacer(flex: 4),
                  // Rejected variant: support is the PRIMARY action.
                  if (_rejected)
                    _fadeSlide(
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _openSupport,
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _gold,
                            foregroundColor: _bg,
                            padding: const EdgeInsets.symmetric(vertical: 15),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(14),
                            ),
                          ),
                          icon: const Icon(Icons.support_agent_rounded,
                              size: 20),
                          label: Text(
                            S.of(context).waitlistSupport,
                            style: const TextStyle(
                                fontSize: 16, fontWeight: FontWeight.w800),
                          ),
                        ),
                      ),
                      0.6,
                      1.0,
                    ),
                  if (_rejected) const SizedBox(height: 24),
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

  /// The mock illustration as the waitlist hero. Bundled asset first; on
  /// patched builds (OTA carries no new assets) the backend-hosted copy;
  /// if both are missing (offline, old bundle), the drawn widget art.
  /// A late frame FADES in over the drawn art — never pops (the
  /// update-required rule, user report 2026-10-10).
  Widget _buildHeroImage() {
    final heroWidth = MediaQuery.sizeOf(context).width * 0.72;
    Widget fadeIn(BuildContext _, Widget child, int? frame, bool wasSync) {
      if (wasSync) return child;
      if (frame == null) return _buildHeroArt();
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0, end: 1),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOut,
        builder: (_, v, c) => Opacity(opacity: v, child: c),
        child: child,
      );
    }

    return Image.asset(
      'assets/images/waitlist_hero.png',
      width: heroWidth,
      fit: BoxFit.contain,
      frameBuilder: fadeIn,
      errorBuilder: (_, __, ___) => Image.network(
        '${ApiService.currentBaseUrl}/static/waitlist_hero.png',
        width: heroWidth,
        fit: BoxFit.contain,
        frameBuilder: fadeIn,
        errorBuilder: (_, __, ___) => _buildHeroArt(),
      ),
    );
  }

  /// The mock's hero, widgets only: a dark-blue cloud (organic blob from
  /// overlapping circles — never the stock cloud glyph) with the big gold
  /// hourglass in front and the little ID card at its side. Rejected
  /// variant art (red accent) and offline fallback of the waitlist image.
  Widget _buildHeroArt() {
    return SizedBox(
      width: 260,
      height: 220,
      child: Stack(
        alignment: Alignment.center,
        children: [
          // Cloud — behind, lower half.
          Positioned(
            bottom: 6,
            child: SizedBox(
              width: 250,
              height: 130,
              child: Stack(
                alignment: Alignment.bottomCenter,
                children: [
                  Container(
                    width: 230,
                    height: 78,
                    decoration: BoxDecoration(
                      color: _cloudDark,
                      borderRadius: BorderRadius.circular(39),
                      boxShadow: [
                        BoxShadow(
                          color: _accent.withValues(alpha: 0.10),
                          blurRadius: 44,
                          spreadRadius: 4,
                        ),
                      ],
                    ),
                  ),
                  Positioned(left: 26, bottom: 34, child: _cloudPuff(84)),
                  Positioned(left: 92, bottom: 52, child: _cloudPuff(102)),
                  Positioned(right: 28, bottom: 36, child: _cloudPuff(76)),
                ],
              ),
            ),
          ),
          // Hourglass — front and centre.
          Positioned(
            top: 0,
            child: Icon(
              Icons.hourglass_top_rounded,
              color: _accent,
              size: 120,
            ),
          ),
          // Little ID card — at the cloud's right edge.
          Positioned(
            right: 4,
            bottom: 34,
            child: Container(
              width: 60,
              height: 46,
              decoration: BoxDecoration(
                color: _cardNavy,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _accent.withValues(alpha: 0.55),
                  width: 1.2,
                ),
              ),
              child: Icon(
                Icons.person_outline_rounded,
                color: _accent,
                size: 26,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _cloudPuff(double size) {
    return Container(
      width: size,
      height: size,
      decoration: const BoxDecoration(
        shape: BoxShape.circle,
        color: _cloudLight,
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
        backgroundColor: _cloudDark.withValues(alpha: 0.6),
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
