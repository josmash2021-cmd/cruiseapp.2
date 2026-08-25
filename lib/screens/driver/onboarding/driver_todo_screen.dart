import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../config/page_transitions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../../services/socket_service.dart';
import '../../../services/user_session.dart';
import '../../../widgets/feathered_image.dart';
import '../../help_screen.dart';
import '../../splash_screen.dart';
import 'doc_capture_screen.dart';
import 'driver_approved_celebration_screen.dart';
import 'onboarding_intro_screen.dart';
import 'onboarding_items.dart';
import 'onboarding_widgets.dart';

/// Driver onboarding Phase 2 — "To-do" hub (Lyft style).
///
/// Lists the six onboarding items (plate, SSN, license, profile photo,
/// background consent, vehicle) with the status reported by
/// `GET /auth/onboarding-items`. Pending/rejected cards open the item
/// intro; submitted/approved cards open a read-only view with a Resubmit
/// option. Progress refreshes every time a pushed flow pops back.
class DriverTodoScreen extends StatefulWidget {
  const DriverTodoScreen({super.key});

  @override
  State<DriverTodoScreen> createState() => _DriverTodoScreenState();
}

class _DriverTodoScreenState extends State<DriverTodoScreen> {
  /// Canonical display order for the hub. `inspection` is only listed when
  /// the GET includes it (Alabama drivers).
  static const _order = [
    OnboardingItem.plate,
    OnboardingItem.ssn,
    OnboardingItem.license,
    OnboardingItem.photo,
    OnboardingItem.background,
    OnboardingItem.vehicle,
    OnboardingItem.registration,
    OnboardingItem.insurance,
    OnboardingItem.inspection,
  ];

  /// Items whose card opens the capture page directly (no intro step).
  static const _docItems = {
    OnboardingItem.registration,
    OnboardingItem.insurance,
    OnboardingItem.inspection,
  };

  List<OnboardingItemEntry> _entries = [
    for (final item in _order)
      if (item != OnboardingItem.inspection)
        OnboardingItemEntry(item: item, status: OnboardingItemStatus.pending),
  ];
  bool _loading = true;
  bool _completedExpanded = false;

  /// Live approval watch (2026-08-25): the hub no longer waits for the
  /// driver to kill and reopen the app. The socket push lands the instant
  /// dispatch decides; the 25 s poll is the fallback for a dead socket.
  StreamSubscription<Map<String, dynamic>>? _statusSub;
  Timer? _approvalPoll;

  @override
  void initState() {
    super.initState();
    _load();
    _statusSub = SocketService.accountStatusStream.listen(_onStatusPush);
    _approvalPoll = Timer.periodic(
      const Duration(seconds: 25),
      (_) => _checkApproval(),
    );
  }

  @override
  void dispose() {
    _statusSub?.cancel();
    _approvalPoll?.cancel();
    super.dispose();
  }

  /// Dispatch decision over the socket. The admin endpoint sends the raw
  /// action ("approve"/"reject"), the rider auto-verify sends "approved" —
  /// accept both spellings.
  void _onStatusPush(Map<String, dynamic> data) {
    final status = (data['status'] ?? '').toString().toLowerCase();
    if (status == 'approve' || status == 'approved') {
      _goApproved();
    } else if (status == 'reject' || status == 'rejected') {
      _load(); // re-list with the rejection reasons on the cards
    }
  }

  /// HTTP fallback: re-read the profile and route on the server truth.
  Future<void> _checkApproval() async {
    if (!mounted) return;
    try {
      final user = await ApiService.getMe();
      if (!mounted || user == null) return;
      final s = (user['verification_status'] as String? ?? '')
          .toLowerCase()
          .trim();
      final approved = user['is_verified'] == true ||
          user['isVerified'] == true ||
          {'approved', 'active', 'online', 'clear', 'verified'}.contains(s);
      if (approved) {
        _goApproved();
      } else if (s == 'rejected') {
        _load();
      }
    } catch (_) {}
  }

  bool _navigatedToApproved = false;

  /// Approved → celebration → first-trip guide → home, exactly once, with
  /// no way back to the hub (the same chain the push-tap path uses).
  void _goApproved() {
    if (_navigatedToApproved || !mounted) return;
    _navigatedToApproved = true;
    _approvalPoll?.cancel();
    Navigator.of(context).pushAndRemoveUntil(
      onboardingFadeSlideRoute(const DriverApprovedCelebrationScreen()),
      (_) => false,
    );
  }


  Future<void> _load() async {
    try {
      final data = await ApiService.getOnboardingItems();
      final raw = data['items'];
      if (!mounted) return;
      if (raw is Map) {
        setState(() {
          _entries = [
            for (final item in _order)
              // The GET omits inspection for non-AL drivers entirely.
              if (raw.containsKey(item.key))
                OnboardingItemEntry.parse(
                  item.key,
                  (raw[item.key] as Map?)?.cast<String, dynamic>(),
                ),
          ];
          _loading = false;
        });
      } else {
        setState(() => _loading = false);
      }
    } on ApiException {
      if (mounted) setState(() => _loading = false);
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _openItem(OnboardingItemEntry entry) async {
    // Document items have no intro — the card opens the capture page
    // directly; everything else goes through the generic intro.
    if (_docItems.contains(entry.item)) {
      await Navigator.of(
        context,
      ).push(onboardingFadeSlideRoute(DocCaptureScreen(entry: entry)));
      _load();
      return;
    }
    // Every push returns here → refresh progress from the backend.
    await Navigator.of(context).push(
      onboardingFadeSlideRoute(OnboardingIntroScreen(entry: entry)),
    );
    _load();
  }

  Future<void> _confirmLogout() async {
    final s = S.of(context);
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF101736),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
        title: Text(
          s.signOutTitle,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          s.signOutConfirmation,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.65)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: Text(s.cancel, style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              s.signOutButton,
              style: const TextStyle(
                color: kOnboardingGold,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;
    await UserSession.logout();
    if (!mounted) return;
    Navigator.of(context).pushAndRemoveUntil(
      smoothFadeRoute(const SplashScreen(), durationMs: 600),
      (_) => false,
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final s = S.of(context);

    final open = _entries.where((e) => !e.isCompleted).toList();
    final completed = _entries.where((e) => e.isCompleted).toList();

    return Scaffold(
      backgroundColor: kOnboardingNavy,
      body: Column(
        children: [
          // ── Header: "To-do" + count pill centered, logout top-right ──
          Padding(
            padding: EdgeInsets.only(top: pad.top + 8, left: 8, right: 8),
            child: Row(
              children: [
                const SizedBox(width: 48),
                const Spacer(),
                Text(
                  s.obTodoTitle,
                  style: GoogleFonts.poppins(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: kOnboardingGold.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: kOnboardingGold.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Text(
                    s.obTodoCount(open.length),
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: kOnboardingGold,
                    ),
                  ),
                ),
                const Spacer(),
                IconButton(
                  onPressed: _confirmLogout,
                  tooltip: s.logOut,
                  icon: const Icon(
                    Icons.logout_rounded,
                    color: Colors.white,
                    size: 24,
                  ),
                ),
              ],
            ),
          ),

          Expanded(
            child: _loading
                ? const Center(
                    child: CircularProgressIndicator(
                      color: kOnboardingGold,
                      strokeWidth: 2.5,
                    ),
                  )
                : RefreshIndicator(
                    onRefresh: _load,
                    color: kOnboardingGold,
                    backgroundColor: kOnboardingNavy,
                    child: ListView(
                      physics: const AlwaysScrollableScrollPhysics(),
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
                      children: [
                        // ── Everything submitted: PNG hero + In review ──
                        if (open.isEmpty) ...[
                          _allInReviewCard(),
                          const SizedBox(height: 8),
                        ],

                        // ── Featured next item (Lyft style) ──
                        if (open.isNotEmpty) ...[
                          _featuredCard(open.first),
                          const SizedBox(height: 4),
                        ],

                        for (final entry in open) _card(entry),

                        // ── Completed (N) — collapsible ──
                        if (completed.isNotEmpty) ...[
                          const SizedBox(height: 8),
                          GestureDetector(
                            onTap: () => setState(
                              () => _completedExpanded = !_completedExpanded,
                            ),
                            behavior: HitTestBehavior.opaque,
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                vertical: 10,
                                horizontal: 4,
                              ),
                              child: Row(
                                children: [
                                  Text(
                                    s.obCompletedSection(completed.length),
                                    style: GoogleFonts.inter(
                                      fontSize: 15,
                                      fontWeight: FontWeight.w700,
                                      color: Colors.white.withValues(
                                        alpha: 0.75,
                                      ),
                                    ),
                                  ),
                                  const Spacer(),
                                  Icon(
                                    _completedExpanded
                                        ? Icons.keyboard_arrow_up_rounded
                                        : Icons.keyboard_arrow_down_rounded,
                                    color: Colors.white.withValues(
                                      alpha: 0.6,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          AnimatedCrossFade(
                            duration: const Duration(milliseconds: 250),
                            crossFadeState: _completedExpanded
                                ? CrossFadeState.showSecond
                                : CrossFadeState.showFirst,
                            firstChild: const SizedBox.shrink(),
                            secondChild: Column(
                              children: [
                                for (final entry in completed) _card(entry),
                              ],
                            ),
                          ),
                        ],

                        const SizedBox(height: 20),
                      ],
                    ),
                  ),
          ),

          // ── Footer — pinned to the bottom, out of the scroll (2026-08-25)
          Container(
            decoration: BoxDecoration(
              color: kOnboardingNavy,
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.07)),
              ),
            ),
            padding: EdgeInsets.fromLTRB(20, 12, 20, pad.bottom + 14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  s.obHereForYou,
                  style: GoogleFonts.inter(
                    fontSize: 14,
                    color: Colors.white.withValues(alpha: 0.55),
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  children: [
                    Expanded(
                      child: _footerButton(
                        icon: Icons.chat_bubble_outline_rounded,
                        label: s.obContactUs,
                        onTap: () => Navigator.of(context).push(
                          onboardingFadeSlideRoute(
                            const CruiseSupportChatScreen(),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _footerButton(
                        icon: Icons.help_outline_rounded,
                        label: s.obHelpCenter,
                        onTap: () => Navigator.of(context).push(
                          onboardingFadeSlideRoute(const HelpScreen()),
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _footerButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 50,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: Colors.white.withValues(alpha: 0.22)),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(icon, size: 18, color: kOnboardingGold),
            const SizedBox(width: 8),
            Text(
              label,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Featured "up next" card — hero image + title + subtitle + gold
  /// Continue button that opens the same item intro as the list card.
  Widget _featuredCard(OnboardingItemEntry entry) {
    final s = S.of(context);
    final (title, subtitle) = onboardingCardCopy(s, entry.item);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101736),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kOnboardingGold.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Step icon instead of a photo (2026-08-25): the hero area shows
          // the gold icon of the step that's up next (inspection →
          // registration → insurance → …). The car PNG appears only once
          // everything is in — see _allInReviewCard.
          Container(
            width: double.infinity,
            height: 120,
            color: Colors.white.withValues(alpha: 0.03),
            child: Center(
              child: Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: kOnboardingGold.withValues(alpha: 0.12),
                  border: Border.all(
                    color: kOnboardingGold.withValues(alpha: 0.45),
                    width: 1.4,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: kOnboardingGold.withValues(alpha: 0.18),
                      blurRadius: 28,
                      spreadRadius: 2,
                    ),
                  ],
                ),
                child: Icon(
                  onboardingItemIcon(entry.item),
                  color: kOnboardingGold,
                  size: 34,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.inter(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  subtitle,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    height: 1.35,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 14),
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    onPressed: () => _openItem(entry),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: kOnboardingGold,
                      foregroundColor: const Color(0xFF1A1400),
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      s.continueButton,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Everything is in — the car PNG hero (feathered edges) and the
  /// "In review" state. No Continue button: the next move is dispatch's,
  /// and the socket/poll watch above routes to the celebration on its own.
  Widget _allInReviewCard() {
    final s = S.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF101736),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: kOnboardingGold.withValues(alpha: 0.55)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          const FeatheredImage(
            'assets/images/onboarding/ride_hero.png',
            width: double.infinity,
            height: 170,
            fit: BoxFit.contain,
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 18),
            child: Column(
              children: [
                Text(
                  s.obAllInReviewTitle,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  s.obAllInReviewSub,
                  textAlign: TextAlign.center,
                  style: GoogleFonts.inter(
                    fontSize: 13,
                    height: 1.35,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
                const SizedBox(height: 12),
                _pill(
                  icon: Icons.hourglass_top_rounded,
                  label: s.obInReview,
                  color: kOnboardingGold,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card(OnboardingItemEntry entry) {
    final s = S.of(context);
    final (title, subtitle) = onboardingCardCopy(s, entry.item);
    final rejected = entry.status == OnboardingItemStatus.rejected;

    return GestureDetector(
      onTap: () => _openItem(entry),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF101736),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: rejected
                ? const Color(0xFFE57373).withValues(alpha: 0.6)
                : entry.status == OnboardingItemStatus.pending
                ? kOnboardingGold.withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.10),
            width: entry.status == OnboardingItemStatus.pending ? 1.4 : 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 14,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(
                      onboardingItemIcon(entry.item),
                      color: kOnboardingGold,
                      size: 24,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: GoogleFonts.inter(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          subtitle,
                          style: GoogleFonts.inter(
                            fontSize: 13,
                            height: 1.35,
                            color: Colors.white.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 10),
                  _statusBadge(entry),
                ],
              ),
              if (rejected && entry.reason != null)
                Container(
                  width: double.infinity,
                  margin: const EdgeInsets.only(top: 12),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE57373).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.error_outline_rounded,
                        size: 18,
                        color: Color(0xFFE57373),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          entry.reason!,
                          style: const TextStyle(
                            fontSize: 12.5,
                            height: 1.35,
                            color: Color(0xFFE57373),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _statusBadge(OnboardingItemEntry entry) {
    final s = S.of(context);
    switch (entry.status) {
      case OnboardingItemStatus.pending:
        return Icon(
          Icons.chevron_right_rounded,
          color: Colors.white.withValues(alpha: 0.5),
        );
      case OnboardingItemStatus.submitted:
        return _pill(
          icon: Icons.check_circle_outline_rounded,
          label: s.obInReview,
          color: Colors.white.withValues(alpha: 0.55),
        );
      case OnboardingItemStatus.approved:
        return _pill(
          icon: Icons.check_circle_rounded,
          label: s.obApprovedStatus,
          color: kOnboardingGold,
        );
      case OnboardingItemStatus.rejected:
        return _pill(
          icon: Icons.cancel_outlined,
          label: s.obRejectedStatus,
          color: const Color(0xFFE57373),
        );
    }
  }

  Widget _pill({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 4),
        Text(
          label,
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w700,
            color: color,
          ),
        ),
      ],
    );
  }
}
