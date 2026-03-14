import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';

// ═══════════════════════════════════════════════════════════════
//  CRUISE DRIVER — PROMOTIONS SCREEN
//  Full-featured: tabs, progress, countdown timers, detail sheets
// ═══════════════════════════════════════════════════════════════

class DriverPromosScreen extends StatefulWidget {
  const DriverPromosScreen({super.key});

  @override
  State<DriverPromosScreen> createState() => _DriverPromosScreenState();
}

class _DriverPromosScreenState extends State<DriverPromosScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFD4A843);
  static const _bg = Color(0xFF0A0A0A);

  late TabController _tabCtrl;
  Timer? _countdownTimer;

  // ── Promo data model ──
  late List<_Promo> _active;
  late List<_Promo> _upcoming;
  late List<_Promo> _history;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _buildPromoData();
    // Tick countdown every second for upcoming promos
    _countdownTimer = Timer.periodic(
      const Duration(seconds: 1),
      (_) {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _buildPromoData() {
    final now = DateTime.now();
    _active = [
      _Promo(
        id: 'surge',
        icon: Icons.local_fire_department_rounded,
        color: const Color(0xFFFF6B35),
        title: 'Surge Zone Active',
        desc: 'High demand in your area! Complete trips now for boosted fares.',
        badge: '1.5x',
        type: _PromoType.multiplier,
        progress: 0.0,
        currentCount: 0,
        targetCount: 0,
        expiresAt: now.add(const Duration(hours: 2, minutes: 34)),
        details:
            'Surge pricing is automatically applied to all trip fares in high-demand zones. '
            'The multiplier adjusts dynamically based on rider demand and driver supply. '
            'Stay in the highlighted zone on the map to maximize your earnings.',
        tips: [
          'Stay near busy intersections and popular pickup spots',
          'Surge zones shift every 15-30 minutes based on demand',
          'Complete trips quickly to get more surge-priced rides',
        ],
      ),
      _Promo(
        id: 'consecutive',
        icon: Icons.star_rounded,
        color: _gold,
        title: 'Consecutive Trip Bonus',
        desc: 'Complete 5 trips in a row without declining to earn \$5 extra.',
        badge: '+\$5',
        type: _PromoType.bonus,
        progress: 0.6,
        currentCount: 3,
        targetCount: 5,
        expiresAt: now.add(const Duration(hours: 4)),
        details:
            'Accept and complete 5 consecutive trip requests without declining or letting any expire. '
            'The bonus is added to your earnings after the 5th trip is completed. '
            'Canceling or declining a trip resets your progress.',
        tips: [
          'Stay in high-demand areas to get quick consecutive requests',
          'Keep your acceptance rate high for maximum bonuses',
          'Timer resets if you go offline between trips',
        ],
      ),
      _Promo(
        id: 'peak_hours',
        icon: Icons.schedule_rounded,
        color: const Color(0xFF26C6DA),
        title: 'Peak Hours Bonus',
        desc: 'Drive between 5PM–9PM for an extra \$1.50 per trip.',
        badge: '+\$1.50',
        type: _PromoType.bonus,
        progress: 0.4,
        currentCount: 2,
        targetCount: 5,
        expiresAt: now.add(const Duration(hours: 3, minutes: 15)),
        details:
            'Earn an extra \$1.50 for each completed trip during peak evening hours (5:00 PM – 9:00 PM). '
            'This bonus stacks with surge pricing and other active promotions.',
        tips: [
          'Position yourself near restaurants and entertainment venues',
          'Evening rush typically peaks between 5:30–7:30 PM',
          'Airport pickups during this window also qualify',
        ],
      ),
    ];

    _upcoming = [
      _Promo(
        id: 'night_owl',
        icon: Icons.nightlight_round,
        color: const Color(0xFF7B68EE),
        title: 'Night Owl Bonus',
        desc: 'Drive between 11PM–4AM and earn \$3 extra per trip.',
        badge: '+\$3',
        type: _PromoType.bonus,
        progress: 0.0,
        currentCount: 0,
        targetCount: 8,
        startsAt: now.add(const Duration(hours: 5, minutes: 22)),
        details:
            'Late-night drivers are in high demand! Earn an extra \$3.00 for every trip completed '
            'between 11:00 PM and 4:00 AM. This promotion runs every night this week.',
        tips: [
          'Bar and club areas are busiest between midnight–2 AM',
          'Keep your vehicle clean — late-night riders notice',
          'Stay safe: well-lit pickup/dropoff spots only',
        ],
      ),
      _Promo(
        id: 'weekend',
        icon: Icons.weekend_rounded,
        color: const Color(0xFF4CAF50),
        title: 'Weekend Warrior',
        desc: 'Complete 20 trips this weekend for a 10% earnings boost.',
        badge: '+10%',
        type: _PromoType.multiplier,
        progress: 0.0,
        currentCount: 0,
        targetCount: 20,
        startsAt: _nextWeekend(now),
        details:
            'Drive all weekend long! Complete 20 or more trips between Friday 6 PM and Sunday midnight '
            'to earn a 10% bonus on your total weekend earnings. The bonus is paid out on Monday.',
        tips: [
          'Start early Friday evening for a head start',
          'Saturday afternoon shopping areas are great for quick rides',
          'Sunday brunch spots generate consistent morning demand',
        ],
      ),
      _Promo(
        id: 'airport',
        icon: Icons.flight_rounded,
        color: const Color(0xFF42A5F5),
        title: 'Airport Pickup Bonus',
        desc: 'Earn \$2 extra on every airport pickup this week.',
        badge: '+\$2',
        type: _PromoType.bonus,
        progress: 0.0,
        currentCount: 0,
        targetCount: 0,
        startsAt: now.add(const Duration(days: 1, hours: 8)),
        details:
            'Every pickup from an airport terminal earns an extra \$2.00 flat bonus. '
            'Valid at all partnered airports in your metro area. No trip limit.',
        tips: [
          'Check flight arrival boards for busy landing windows',
          'Wait in the designated rideshare staging area',
          'International arrivals often have higher fares',
        ],
      ),
      _Promo(
        id: 'referral_blitz',
        icon: Icons.group_add_rounded,
        color: const Color(0xFFEC407A),
        title: 'Referral Blitz',
        desc: 'Refer a new driver and both earn \$50 after their 10th trip.',
        badge: '\$50',
        type: _PromoType.bonus,
        progress: 0.0,
        currentCount: 0,
        targetCount: 1,
        startsAt: now.add(const Duration(days: 2)),
        details:
            'Share your referral code with a friend. When they complete 10 trips, '
            'both of you receive a \$50 bonus credited to your earnings. No limit on referrals!',
        tips: [
          'Share your code on social media for wider reach',
          'Help your referral get started — show them the app',
          'Multiple referrals stack — no cap on bonuses',
        ],
      ),
    ];

    _history = [
      _Promo(
        id: 'h_surge_last',
        icon: Icons.local_fire_department_rounded,
        color: const Color(0xFFFF6B35),
        title: 'Surge Zone (Last Week)',
        desc: 'You earned 1.3x on 12 trips during peak surge.',
        badge: '1.3x',
        type: _PromoType.multiplier,
        progress: 1.0,
        currentCount: 12,
        targetCount: 12,
        completedEarnings: 18.60,
      ),
      _Promo(
        id: 'h_consec',
        icon: Icons.star_rounded,
        color: _gold,
        title: 'Consecutive Bonus (Mar 10)',
        desc: 'Completed 5 consecutive trips. Bonus earned!',
        badge: '+\$5',
        type: _PromoType.bonus,
        progress: 1.0,
        currentCount: 5,
        targetCount: 5,
        completedEarnings: 5.00,
      ),
      _Promo(
        id: 'h_weekend',
        icon: Icons.weekend_rounded,
        color: const Color(0xFF4CAF50),
        title: 'Weekend Warrior (Mar 7-9)',
        desc: 'Completed 24 trips over the weekend.',
        badge: '+10%',
        type: _PromoType.multiplier,
        progress: 1.0,
        currentCount: 24,
        targetCount: 20,
        completedEarnings: 32.40,
      ),
    ];
  }

  DateTime _nextWeekend(DateTime from) {
    int daysUntilFriday = (DateTime.friday - from.weekday) % 7;
    if (daysUntilFriday == 0 && from.hour >= 18) daysUntilFriday = 7;
    return DateTime(from.year, from.month, from.day + daysUntilFriday, 18);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _bg,
      body: SafeArea(
        child: Column(
          children: [
            // ── Top bar ──
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.pop(context),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.06),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.arrow_back_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    S.of(context).promotionsLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Spacer(),
                  // Total earned badge
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: _gold.withValues(alpha: 0.2)),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.emoji_events_rounded,
                          color: _gold,
                          size: 14,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '\$${_totalHistoryEarnings.toStringAsFixed(2)}',
                          style: TextStyle(
                            color: _gold,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Tab bar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Container(
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TabBar(
                  controller: _tabCtrl,
                  indicator: BoxDecoration(
                    color: _gold.withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: _gold.withValues(alpha: 0.3)),
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  labelColor: _gold,
                  unselectedLabelColor: Colors.white.withValues(alpha: 0.4),
                  labelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                  unselectedLabelStyle: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  tabs: [
                    Tab(text: 'Active (${_active.length})'),
                    Tab(text: 'Upcoming (${_upcoming.length})'),
                    Tab(text: 'History'),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),

            // ── Tab content ──
            Expanded(
              child: TabBarView(
                controller: _tabCtrl,
                children: [
                  _buildActiveTab(),
                  _buildUpcomingTab(),
                  _buildHistoryTab(),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  double get _totalHistoryEarnings =>
      _history.fold(0.0, (s, p) => s + (p.completedEarnings ?? 0));

  // ═══════════════════════════════════════════════════
  //  ACTIVE TAB
  // ═══════════════════════════════════════════════════
  Widget _buildActiveTab() {
    if (_active.isEmpty) {
      return _emptyState(
        Icons.celebration_rounded,
        'No active promotions',
        'Check back soon for new earning opportunities!',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _active.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _activePromoCard(_active[i]),
      ),
    );
  }

  Widget _activePromoCard(_Promo p) {
    final remaining = p.expiresAt?.difference(DateTime.now());
    final timeStr = remaining != null && !remaining.isNegative
        ? _formatDuration(remaining)
        : 'Expiring soon';

    return GestureDetector(
      onTap: () => _showPromoDetail(p),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: p.color.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: p.color.withValues(alpha: 0.15)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _iconBox(p.icon, p.color),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        p.desc,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.45),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                _badge(p.badge, p.color),
              ],
            ),
            if (p.targetCount > 0) ...[
              const SizedBox(height: 14),
              // Progress bar
              Row(
                children: [
                  Expanded(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: p.progress,
                        backgroundColor: Colors.white.withValues(alpha: 0.08),
                        valueColor: AlwaysStoppedAnimation(p.color),
                        minHeight: 6,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    '${p.currentCount}/${p.targetCount}',
                    style: TextStyle(
                      color: p.color,
                      fontSize: 13,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 10),
            // Timer row
            Row(
              children: [
                Icon(
                  Icons.timer_outlined,
                  color: Colors.white.withValues(alpha: 0.3),
                  size: 14,
                ),
                const SizedBox(width: 4),
                Text(
                  timeStr,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const Spacer(),
                Text(
                  'Tap for details →',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.2),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  UPCOMING TAB
  // ═══════════════════════════════════════════════════
  Widget _buildUpcomingTab() {
    if (_upcoming.isEmpty) {
      return _emptyState(
        Icons.event_note_rounded,
        'No upcoming promotions',
        'New promotions are added regularly!',
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _upcoming.length,
      itemBuilder: (_, i) => Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: _upcomingPromoCard(_upcoming[i]),
      ),
    );
  }

  Widget _upcomingPromoCard(_Promo p) {
    final startsIn = p.startsAt?.difference(DateTime.now());
    final countdownStr = startsIn != null && !startsIn.isNegative
        ? 'Starts in ${_formatDuration(startsIn)}'
        : 'Starting soon';

    return GestureDetector(
      onTap: () => _showPromoDetail(p),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _iconBox(p.icon, p.color.withValues(alpha: 0.6)),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        p.title,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.8),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        p.desc,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                _badge(p.badge, p.color.withValues(alpha: 0.6)),
              ],
            ),
            const SizedBox(height: 12),
            // Countdown
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: p.color.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.access_time_rounded, color: p.color, size: 14),
                  const SizedBox(width: 6),
                  Text(
                    countdownStr,
                    style: TextStyle(
                      color: p.color,
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  HISTORY TAB
  // ═══════════════════════════════════════════════════
  Widget _buildHistoryTab() {
    if (_history.isEmpty) {
      return _emptyState(
        Icons.history_rounded,
        'No promotion history',
        'Complete promotions to see them here.',
      );
    }
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        // Summary card
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                _gold.withValues(alpha: 0.12),
                _gold.withValues(alpha: 0.04),
              ],
            ),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(color: _gold.withValues(alpha: 0.15)),
          ),
          child: Row(
            children: [
              Expanded(
                child: _histStat(
                  'Total Earned',
                  '\$${_totalHistoryEarnings.toStringAsFixed(2)}',
                  _gold,
                ),
              ),
              Container(
                width: 1,
                height: 36,
                color: Colors.white.withValues(alpha: 0.06),
              ),
              Expanded(
                child: _histStat(
                  'Promos Completed',
                  '${_history.length}',
                  Colors.white,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ..._history.map(
          (p) => Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: _historyPromoCard(p),
          ),
        ),
      ],
    );
  }

  Widget _histStat(String label, String value, Color color) {
    return Column(
      children: [
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.4),
            fontSize: 11,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _historyPromoCard(_Promo p) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          _iconBox(p.icon, p.color.withValues(alpha: 0.5)),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  p.title,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.7),
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '${p.currentCount} trips completed',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '+\$${(p.completedEarnings ?? 0).toStringAsFixed(2)}',
                style: TextStyle(
                  color: const Color(0xFF4CAF50),
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 2),
              Icon(
                Icons.check_circle_rounded,
                color: const Color(0xFF4CAF50).withValues(alpha: 0.6),
                size: 16,
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  DETAIL BOTTOM SHEET
  // ═══════════════════════════════════════════════════
  void _showPromoDetail(_Promo p) {
    HapticFeedback.selectionClick();
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => _PromoDetailSheet(promo: p),
    );
  }

  // ═══════════════════════════════════════════════════
  //  SHARED WIDGETS
  // ═══════════════════════════════════════════════════
  Widget _iconBox(IconData icon, Color color) {
    return Container(
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Icon(icon, color: color, size: 22),
    );
  }

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: color,
          fontSize: 14,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _emptyState(IconData icon, String title, String subtitle) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white.withValues(alpha: 0.15), size: 56),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 13,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDuration(Duration d) {
    if (d.inDays > 0) return '${d.inDays}d ${d.inHours.remainder(24)}h';
    if (d.inHours > 0) {
      return '${d.inHours}h ${d.inMinutes.remainder(60)}m';
    }
    return '${d.inMinutes}m ${d.inSeconds.remainder(60)}s';
  }
}

// ═══════════════════════════════════════════════════════════════
//  PROMO DATA MODEL
// ═══════════════════════════════════════════════════════════════
enum _PromoType { bonus, multiplier }

class _Promo {
  final String id;
  final IconData icon;
  final Color color;
  final String title;
  final String desc;
  final String badge;
  final _PromoType type;
  final double progress;
  final int currentCount;
  final int targetCount;
  final DateTime? expiresAt;
  final DateTime? startsAt;
  final double? completedEarnings;
  final String? details;
  final List<String>? tips;

  const _Promo({
    required this.id,
    required this.icon,
    required this.color,
    required this.title,
    required this.desc,
    required this.badge,
    required this.type,
    required this.progress,
    required this.currentCount,
    required this.targetCount,
    this.expiresAt,
    this.startsAt,
    this.completedEarnings,
    this.details,
    this.tips,
  });
}

// ═══════════════════════════════════════════════════════════════
//  PROMO DETAIL BOTTOM SHEET
// ═══════════════════════════════════════════════════════════════
class _PromoDetailSheet extends StatelessWidget {
  final _Promo promo;
  const _PromoDetailSheet({required this.promo});

  static const _gold = Color(0xFFD4A843);

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.85,
      builder: (ctx, scrollCtrl) {
        return Container(
          decoration: const BoxDecoration(
            color: Color(0xFF141414),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: ListView(
            controller: scrollCtrl,
            padding: const EdgeInsets.all(20),
            children: [
              // Handle
              Center(
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Header
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: promo.color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(16),
                    ),
                    child: Icon(promo.icon, color: promo.color, size: 28),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          promo.title,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: promo.color.withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            promo.badge,
                            style: TextStyle(
                              color: promo.color,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 20),

              // Progress (if applicable)
              if (promo.targetCount > 0) ...[
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Progress',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Text(
                            '${promo.currentCount} of ${promo.targetCount} trips',
                            style: TextStyle(
                              color: promo.color,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(4),
                        child: LinearProgressIndicator(
                          value: promo.progress,
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          valueColor: AlwaysStoppedAnimation(promo.color),
                          minHeight: 8,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 16),
              ],

              // Description
              if (promo.details != null) ...[
                Text(
                  'How It Works',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  promo.details!,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 20),
              ],

              // Tips
              if (promo.tips != null && promo.tips!.isNotEmpty) ...[
                Text(
                  'Tips to Maximize',
                  style: TextStyle(
                    color: _gold.withValues(alpha: 0.8),
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(height: 10),
                ...promo.tips!.map(
                  (tip) => Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Padding(
                          padding: const EdgeInsets.only(top: 3),
                          child: Icon(
                            Icons.lightbulb_outline_rounded,
                            color: _gold.withValues(alpha: 0.5),
                            size: 16,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            tip,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}
