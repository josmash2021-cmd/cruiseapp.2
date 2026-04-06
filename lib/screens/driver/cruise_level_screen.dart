import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import 'dart:math' as math;

/// Cruise Level – Bronze → Silver → Gold → Platinum → Diamond
class CruiseLevelScreen extends StatefulWidget {
  const CruiseLevelScreen({super.key});

  @override
  State<CruiseLevelScreen> createState() => _CruiseLevelScreenState();
}

class _CruiseLevelScreenState extends State<CruiseLevelScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);

  bool _loading = true;

  // Level-up celebration
  bool _showLevelUp = false;
  int _previousTierIndex = -1;
  late AnimationController _celebrationCtrl;
  late Animation<double> _celebrationAnim;
  final List<_Particle> _particles = [];

  // Driver stats
  double _acceptanceRate = 0;
  double _cancellationRate = 0;
  double _satisfactionRate = 0;
  double _onTimeRate = 0;
  int _totalTrips = 0;

  // Current tier
  // 0=Bronze, 1=Silver, 2=Gold, 3=Platinum, 4=Diamond
  int _currentTierIndex = 0;
  double _avgRating = 0;

  List<_Tier> _buildTiers() {
    final s = S.of(context);
    return <_Tier>[
      _Tier(
        name: 'Bronze',
        color: const Color(0xFFCD7F32),
        icon: Icons.emoji_events_rounded,
        minTrips: 0,
        minRating: 0.0,
        rewards: [
          s.rewardBasicSupport,
          s.rewardStandardAccess,
        ],
      ),
      _Tier(
        name: 'Silver',
        color: const Color(0xFFB0BEC5),
        icon: Icons.workspace_premium_rounded,
        minTrips: 50,
        minRating: 4.5,
        rewards: [
          s.rewardPriorityAccess,
          s.rewardPremiumSupport,
        ],
      ),
      _Tier(
        name: 'Gold',
        color: const Color(0xFFE8C547),
        icon: Icons.star_rounded,
        minTrips: 150,
        minRating: 4.7,
        rewards: [
          s.rewardAllGold,
          s.rewardAirportQueue,
          s.rewardExclusivePromos,
        ],
      ),
      _Tier(
        name: 'Platinum',
        color: const Color(0xFF90CAF9),
        icon: Icons.diamond_rounded,
        minTrips: 300,
        minRating: 4.8,
        rewards: [
          s.rewardAllPlatinum,
          s.rewardConcierge,
          s.rewardEarningsMultiplier,
        ],
      ),
      _Tier(
        name: 'Diamond',
        color: const Color(0xFF80DEEA),
        icon: Icons.auto_awesome_rounded,
        minTrips: 500,
        minRating: 4.9,
        rewards: [
          s.rewardAllPlatinum,
          s.rewardConcierge,
          s.rewardEarningsMultiplier,
          s.rewardDiamondEvents,
        ],
      ),
    ];
  }

  @override
  void initState() {
    super.initState();
    _celebrationCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _celebrationAnim = CurvedAnimation(
      parent: _celebrationCtrl,
      curve: Curves.easeOut,
    );
    _loadData();
  }

  @override
  void dispose() {
    _celebrationCtrl.dispose();
    super.dispose();
  }

  Future<SharedPreferences> _getPrefs() => SharedPreferences.getInstance();

  void _triggerLevelUp() {
    final rng = math.Random();
    _particles.clear();
    for (int i = 0; i < 60; i++) {
      _particles.add(_Particle(
        x: rng.nextDouble(),
        y: rng.nextDouble() * 0.5,
        vx: (rng.nextDouble() - 0.5) * 0.6,
        vy: rng.nextDouble() * 0.8 + 0.2,
        color: [
          const Color(0xFFE8C547),
          const Color(0xFFF5D990),
          const Color(0xFF4CAF50),
          Colors.white,
        ][rng.nextInt(4)],
        size: rng.nextDouble() * 8 + 4,
      ));
    }
    setState(() => _showLevelUp = true);
    _celebrationCtrl.forward(from: 0).then((_) {
      if (mounted) setState(() => _showLevelUp = false);
    });
  }

  Future<void> _loadData() async {
    try {
      // Load previously saved tier to detect level-up
      final prefs = await _getPrefs();
      _previousTierIndex = prefs.getInt('cruise_tier_index') ?? -1;

      final userId = await ApiService.getCurrentUserId();
      if (userId != null) {
        final stats = await ApiService.getDriverStats(userId);
        final completed = (stats['completed_trips'] as num?)?.toInt() ?? 0;
        final canceled = (stats['canceled_trips'] as num?)?.toInt() ?? 0;
        final total = (stats['total_trips'] as num?)?.toInt() ?? 0;
        final avgRating = (stats['avg_rating'] as num?)?.toDouble() ?? 5.0;

        _totalTrips = total;
        _avgRating = avgRating;
        _satisfactionRate = total > 0 ? (completed / total * 100) : 0;
        _cancellationRate = total > 0 ? (canceled / total * 100) : 0;
        _acceptanceRate = (stats['acceptance_rate'] as num?)?.toDouble() ?? 100;
        _onTimeRate = (stats['on_time_rate'] as num?)?.toDouble() ?? 95;
        // Determine driver level by completed trips + average rating
        // Diamond:  500+ trips AND rating >= 4.9
        // Platinum: 300-499 trips AND rating >= 4.8
        // Gold:     150-299 trips AND rating >= 4.7
        // Silver:   50-149 trips AND rating >= 4.5
        // Bronze:   0-49 trips (no rating requirement)
        if (completed >= 500 && avgRating >= 4.9) {
          _currentTierIndex = 4; // Diamond
        } else if (completed >= 300 && avgRating >= 4.8) {
          _currentTierIndex = 3; // Platinum
        } else if (completed >= 150 && avgRating >= 4.7) {
          _currentTierIndex = 2; // Gold
        } else if (completed >= 50 && avgRating >= 4.5) {
          _currentTierIndex = 1; // Silver
        } else {
          _currentTierIndex = 0; // Bronze
        }
        // Persist new tier index
        prefs.setInt('cruise_tier_index', _currentTierIndex);
      }
    } catch (_) {}
    if (mounted) {
      setState(() => _loading = false);
      // Trigger level-up animation if tier improved since last visit
      if (_previousTierIndex >= 0 && _currentTierIndex > _previousTierIndex) {
        Future.delayed(const Duration(milliseconds: 400), _triggerLevelUp);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          _loading
          ? const Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
            )
          : CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                SliverToBoxAdapter(
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: GestureDetector(
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
                          ),
                          Text(
                            S.of(context).cruiseLevel,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),
                        Text(
                          S.of(context).cruiseLevel,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          S.of(context).earnPointsUnlockRewards,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.5),
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 28),

                        // ── Current tier badge ──
                        _buildCurrentTierCard(),
                        const SizedBox(height: 24),

                        // ── Progress requirements ──
                        _buildProgressSection(),
                        const SizedBox(height: 28),

                        // ── All tiers ──
                        Text(
                          S.of(context).allLevels,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 14),
                        ..._buildTiers().asMap().entries.map(
                          (e) => _buildTierCard(e.key, e.value),
                        ),
                        const SizedBox(height: 40),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          // Level-up celebration overlay
          if (_showLevelUp) _buildCelebrationOverlay(),
        ],
      ),
    );
  }

  Widget _buildCelebrationOverlay() {
    final tier = _buildTiers()[_currentTierIndex];
    return AnimatedBuilder(
      animation: _celebrationAnim,
      builder: (context, _) {
        return IgnorePointer(
          child: Stack(
            children: [
              // Semi-transparent flash
              if (_celebrationAnim.value < 0.3)
                Positioned.fill(
                  child: Container(
                    color: tier.color.withValues(
                      alpha: (0.3 - _celebrationAnim.value) * 2,
                    ),
                  ),
                ),
              // Confetti particles
              ..._particles.map((p) {
                final progress = _celebrationAnim.value;
                final x = p.x + p.vx * progress;
                final y = p.y + p.vy * progress * 1.5;
                final opacity = (1.0 - progress).clamp(0.0, 1.0);
                return Positioned(
                  left: x * MediaQuery.of(context).size.width,
                  top: y * MediaQuery.of(context).size.height,
                  child: Opacity(
                    opacity: opacity,
                    child: Transform.rotate(
                      angle: progress * math.pi * 4,
                      child: Container(
                        width: p.size,
                        height: p.size,
                        decoration: BoxDecoration(
                          color: p.color,
                          borderRadius: BorderRadius.circular(p.size / 4),
                        ),
                      ),
                    ),
                  ),
                );
              }),
              // Level-up banner
              Positioned(
                top: MediaQuery.of(context).size.height * 0.3,
                left: 40,
                right: 40,
                child: Opacity(
                  opacity: (_celebrationAnim.value < 0.7
                      ? _celebrationAnim.value / 0.7
                      : (1.0 - _celebrationAnim.value) / 0.3),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 24,
                      horizontal: 32,
                    ),
                    decoration: BoxDecoration(
                      color: tier.color,
                      borderRadius: BorderRadius.circular(24),
                      boxShadow: [
                        BoxShadow(
                          color: tier.color.withValues(alpha: 0.5),
                          blurRadius: 40,
                          spreadRadius: 8,
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.auto_awesome_rounded,
                          color: Colors.black,
                          size: 36,
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Level Up!',
                          style: TextStyle(
                            color: Colors.black,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'You reached ${tier.name}!',
                          style: const TextStyle(
                            color: Colors.black87,
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildCurrentTierCard() {
    final tier = _buildTiers()[_currentTierIndex];
    final nextTier = _currentTierIndex < 4
        ? _buildTiers()[_currentTierIndex + 1]
        : null;
    final progress = nextTier != null && nextTier.minTrips > 0
        ? (_totalTrips / nextTier.minTrips).clamp(0.0, 1.0)
        : 1.0;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            tier.color.withValues(alpha: 0.25),
            tier.color.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(24),
        border: Border.all(color: tier.color.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: tier.color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Icon(tier.icon, color: tier.color, size: 40),
          ),
          const SizedBox(height: 14),
          Text(
            tier.name,
            style: TextStyle(
              color: tier.color,
              fontSize: 26,
              fontWeight: FontWeight.w900,
              letterSpacing: 1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            S.of(context).currentLevel,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 16),

          // Stats summary
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.directions_car_rounded, color: _gold, size: 18),
              const SizedBox(width: 6),
              Text(
                '$_totalTrips trips',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(width: 16),
              const Icon(Icons.star_rounded, color: _gold, size: 18),
              const SizedBox(width: 6),
              Text(
                _avgRating.toStringAsFixed(2),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),

          if (nextTier != null) ...[
            const SizedBox(height: 16),
            // Progress bar to next tier
            Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Text(
                      tier.name,
                      style: TextStyle(
                        color: tier.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      nextTier.name,
                      style: TextStyle(
                        color: nextTier.color,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: LinearProgressIndicator(
                    value: progress,
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    valueColor: AlwaysStoppedAnimation(tier.color),
                    minHeight: 8,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _totalTrips >= nextTier.minTrips
                      ? 'Trips requirement met — keep your rating up!'
                      : '${nextTier.minTrips - _totalTrips} more trips to ${nextTier.name}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildProgressSection() {
    final nextTier = _currentTierIndex < 4
        ? _buildTiers()[_currentTierIndex + 1]
        : _buildTiers()[4];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          S.of(context).requirementsForLevel(nextTier.name),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 14),
        _requirementRow(
          'Completed Trips',
          '$_totalTrips',
          '≥ ${nextTier.minTrips}',
          _totalTrips >= nextTier.minTrips,
        ),
        if (nextTier.minRating > 0)
          _requirementRow(
            'Average Rating',
            _avgRating.toStringAsFixed(2),
            '≥ ${nextTier.minRating.toStringAsFixed(1)}',
            _avgRating >= nextTier.minRating,
          ),
      ],
    );
  }

  Widget _requirementRow(
    String label,
    String current,
    String target,
    bool met,
  ) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: met
                  ? const Color(0xFF4CAF50).withValues(alpha: 0.15)
                  : Colors.white.withValues(alpha: 0.06),
              shape: BoxShape.circle,
            ),
            child: Icon(
              met ? Icons.check_rounded : Icons.remove_rounded,
              color: met
                  ? const Color(0xFF4CAF50)
                  : Colors.white.withValues(alpha: 0.3),
              size: 18,
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          Text(
            current,
            style: TextStyle(
              color: met ? const Color(0xFF4CAF50) : Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(width: 8),
          Text(
            target,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTierCard(int index, _Tier tier) {
    final isCurrent = index == _currentTierIndex;
    final isLocked = index > _currentTierIndex;

    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        _showTierDetail(tier, isCurrent, isLocked);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: isCurrent ? tier.color.withValues(alpha: 0.1) : _card,
          borderRadius: BorderRadius.circular(18),
          border: isCurrent
              ? Border.all(color: tier.color.withValues(alpha: 0.3))
              : null,
        ),
        child: Row(
          children: [
            Container(
              width: 50,
              height: 50,
              decoration: BoxDecoration(
                color: tier.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(
                tier.icon,
                color: isLocked
                    ? tier.color.withValues(alpha: 0.4)
                    : tier.color,
                size: 26,
              ),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        tier.name,
                        style: TextStyle(
                          color: isLocked
                              ? Colors.white.withValues(alpha: 0.4)
                              : Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(width: 8),
                      if (isCurrent)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 3,
                          ),
                          decoration: BoxDecoration(
                            color: tier.color.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            S.of(context).currentLabel,
                            style: TextStyle(
                              color: tier.color,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      if (isLocked)
                        Icon(
                          Icons.lock_rounded,
                          color: Colors.white.withValues(alpha: 0.2),
                          size: 14,
                        ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    tier.minTrips == 0
                        ? '${tier.rewards.length} rewards'
                        : tier.minRating > 0
                            ? '${tier.minTrips}+ trips · ★ ${tier.minRating.toStringAsFixed(1)}+'
                            : '${tier.minTrips}+ trips',
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.35),
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.2),
              size: 22,
            ),
          ],
        ),
      ),
    );
  }

  void _showTierDetail(_Tier tier, bool isCurrent, bool isLocked) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        constraints: BoxConstraints(
          maxHeight: MediaQuery.of(ctx).size.height * 0.7,
        ),
        padding: const EdgeInsets.all(28),
        decoration: const BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white12,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 24),
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: tier.color.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(18),
              ),
              child: Icon(tier.icon, color: tier.color, size: 32),
            ),
            const SizedBox(height: 14),
            Text(
              tier.name,
              style: TextStyle(
                color: tier.color,
                fontSize: 24,
                fontWeight: FontWeight.w900,
              ),
            ),
            if (isCurrent) ...[
              const SizedBox(height: 4),
              Text(
                S.of(context).yourCurrentLevel,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.4),
                  fontSize: 13,
                ),
              ),
            ],
            const SizedBox(height: 20),

            // Requirements
            if (!isCurrent) ...[
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(14),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of(context).requirements,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    _reqLine('${tier.minTrips}+ completed trips'),
                    if (tier.minRating > 0)
                      _reqLine('Average rating ≥ ${tier.minRating.toStringAsFixed(1)}'),
                  ],
                ),
              ),
              const SizedBox(height: 16),
            ],

            // Rewards
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        S.of(context).rewards,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 12),
                    ...tier.rewards.map(
                      (r) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Row(
                          children: [
                            Container(
                              width: 28,
                              height: 28,
                              decoration: BoxDecoration(
                                color: tier.color.withValues(alpha: 0.12),
                                shape: BoxShape.circle,
                              ),
                              child: Icon(
                                Icons.check_rounded,
                                color: tier.color,
                                size: 16,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                r,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 52,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: tier.color,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  isCurrent
                      ? S.of(context).gotIt
                      : (isLocked
                            ? S.of(context).keepGoing
                            : S.of(context).viewRewards),
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Widget _reqLine(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          Icon(
            Icons.circle,
            color: Colors.white.withValues(alpha: 0.2),
            size: 6,
          ),
          const SizedBox(width: 8),
          Text(
            text,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.6),
              fontSize: 13,
            ),
          ),
        ],
      ),
    );
  }
}

class _Tier {
  final String name;
  final Color color;
  final IconData icon;
  final int minTrips;
  final double minRating;
  final List<String> rewards;

  const _Tier({
    required this.name,
    required this.color,
    required this.icon,
    required this.minTrips,
    required this.minRating,
    required this.rewards,
  });
}

class _Particle {
  double x, y, vx, vy, size;
  Color color;
  _Particle({
    required this.x,
    required this.y,
    required this.vx,
    required this.vy,
    required this.color,
    required this.size,
  });
}
