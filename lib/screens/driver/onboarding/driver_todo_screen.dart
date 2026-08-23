import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../../config/page_transitions.dart';
import '../../../l10n/app_localizations.dart';
import '../../../services/api_service.dart';
import '../../help_screen.dart';
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
  /// Canonical display order for the hub.
  static const _order = [
    OnboardingItem.plate,
    OnboardingItem.ssn,
    OnboardingItem.license,
    OnboardingItem.photo,
    OnboardingItem.background,
    OnboardingItem.vehicle,
  ];

  List<OnboardingItemEntry> _entries = [
    for (final item in _order)
      OnboardingItemEntry(item: item, status: OnboardingItemStatus.pending),
  ];
  bool _loading = true;
  bool _completedExpanded = false;

  @override
  void initState() {
    super.initState();
    _load();
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
    // Every push returns here → refresh progress from the backend.
    await Navigator.of(context).push(
      onboardingFadeSlideRoute(OnboardingIntroScreen(entry: entry)),
    );
    _load();
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
          // ── Header: X + "To-do" + count pill ──
          Padding(
            padding: EdgeInsets.only(top: pad.top + 8, left: 8, right: 20),
            child: Row(
              children: [
                IconButton(
                  onPressed: () => Navigator.of(context).pop(),
                  icon: const Icon(
                    Icons.close_rounded,
                    color: Colors.white,
                    size: 26,
                  ),
                ),
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
                const SizedBox(width: 40),
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

                        // ── Footer — support ──
                        Center(
                          child: Text(
                            s.obHereForYou,
                            style: GoogleFonts.inter(
                              fontSize: 14,
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
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
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: kOnboardingGold.withValues(alpha: 0.14),
                      borderRadius: BorderRadius.circular(12),
                    ),
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
