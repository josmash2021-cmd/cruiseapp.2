import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

/// Cruise Level (formerly Cruise Pro) – Green → Gold → Platinum → Diamond
class CruiseLevelScreen extends StatefulWidget {
  const CruiseLevelScreen({super.key});

  @override
  State<CruiseLevelScreen> createState() => _CruiseLevelScreenState();
}

class _CruiseLevelScreenState extends State<CruiseLevelScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);

  bool _loading = true;

  // Driver stats
  double _acceptanceRate = 0;
  double _cancellationRate = 0;
  double _satisfactionRate = 0;
  double _onTimeRate = 0;
  int _totalTrips = 0;
  int _points = 0;

  // Current tier
  int _currentTierIndex = 0; // 0=Green, 1=Gold, 2=Platinum, 3=Diamond

  List<_Tier> _buildTiers() {
    final s = S.of(context);
    return <_Tier>[
      _Tier(
        name: 'Green',
        color: const Color(0xFF4CAF50),
        icon: Icons.eco_rounded,
        minAcceptance: 0,
        maxCancellation: 100,
        minSatisfaction: 0,
        minOnTime: 0,
        pointsRequired: 0,
        rewards: [
          s.rewardBasicSupport,
          s.rewardStandardAccess,
          s.rewardFuelTips,
        ],
      ),
      _Tier(
        name: 'Gold',
        color: const Color(0xFFE8C547),
        icon: Icons.workspace_premium_rounded,
        minAcceptance: 30,
        maxCancellation: 8,
        minSatisfaction: 85,
        minOnTime: 70,
        pointsRequired: 500,
        rewards: [
          s.rewardPriorityAccess,
          s.rewardCashback3,
          s.rewardPremiumSupport,
          s.rewardTuitionDiscount,
        ],
      ),
      _Tier(
        name: 'Platinum',
        color: const Color(0xFFB0BEC5),
        icon: Icons.diamond_rounded,
        minAcceptance: 50,
        maxCancellation: 5,
        minSatisfaction: 90,
        minOnTime: 80,
        pointsRequired: 2000,
        rewards: [
          s.rewardAllGold,
          s.rewardCashback6,
          s.rewardMaintenanceDiscount,
          s.rewardAirportQueue,
          s.rewardExclusivePromos,
        ],
      ),
      _Tier(
        name: 'Diamond',
        color: const Color(0xFF90A4AE),
        icon: Icons.auto_awesome_rounded,
        minAcceptance: 85,
        maxCancellation: 2,
        minSatisfaction: 95,
        minOnTime: 90,
        pointsRequired: 5000,
        rewards: [
          s.rewardAllPlatinum,
          s.rewardCashback10,
          s.rewardFreeInspections,
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
    _loadData();
  }

  Future<void> _loadData() async {
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId != null) {
        final stats = await ApiService.getDriverStats(userId);
        final completed = (stats['completed_trips'] as num?)?.toInt() ?? 0;
        final canceled = (stats['canceled_trips'] as num?)?.toInt() ?? 0;
        final total = (stats['total_trips'] as num?)?.toInt() ?? 0;

        _totalTrips = total;
        _satisfactionRate = total > 0 ? (completed / total * 100) : 0;
        _cancellationRate = total > 0 ? (canceled / total * 100) : 0;
        _acceptanceRate = (stats['acceptance_rate'] as num?)?.toDouble() ?? 100;
        _onTimeRate = (stats['on_time_rate'] as num?)?.toDouble() ?? 95;
        _points = completed * 10;

        // Determine tier
        if (_satisfactionRate >= 95 &&
            _acceptanceRate >= 85 &&
            _cancellationRate <= 2 &&
            _onTimeRate >= 90 &&
            _points >= 5000) {
          _currentTierIndex = 3;
        } else if (_satisfactionRate >= 90 &&
            _acceptanceRate >= 50 &&
            _cancellationRate <= 5 &&
            _onTimeRate >= 80 &&
            _points >= 2000) {
          _currentTierIndex = 2;
        } else if (_satisfactionRate >= 85 &&
            _acceptanceRate >= 30 &&
            _cancellationRate <= 8 &&
            _onTimeRate >= 70 &&
            _points >= 500) {
          _currentTierIndex = 1;
        } else {
          _currentTierIndex = 0;
        }
      }
    } catch (_) {}
    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      body: _loading
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
    );
  }

  Widget _buildCurrentTierCard() {
    final tier = _buildTiers()[_currentTierIndex];
    final nextTier = _currentTierIndex < 3
        ? _buildTiers()[_currentTierIndex + 1]
        : null;
    final progress = nextTier != null && nextTier.pointsRequired > 0
        ? (_points / nextTier.pointsRequired).clamp(0.0, 1.0)
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

          // Points
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.star_rounded, color: _gold, size: 18),
              const SizedBox(width: 6),
              Text(
                S.of(context).pointsCount(_points),
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
                  S
                      .of(context)
                      .pointsToNextLevel(
                        nextTier.pointsRequired - _points,
                        nextTier.name,
                      ),
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
    final nextTier = _currentTierIndex < 3
        ? _buildTiers()[_currentTierIndex + 1]
        : _buildTiers()[3];

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
          S.of(context).acceptanceRate,
          '${_acceptanceRate.toStringAsFixed(0)}%',
          '≥ ${nextTier.minAcceptance}%',
          _acceptanceRate >= nextTier.minAcceptance,
        ),
        _requirementRow(
          S.of(context).cancellationRate,
          '${_cancellationRate.toStringAsFixed(0)}%',
          '≤ ${nextTier.maxCancellation}%',
          _cancellationRate <= nextTier.maxCancellation,
        ),
        _requirementRow(
          S.of(context).satisfactionRate,
          '${_satisfactionRate.toStringAsFixed(0)}%',
          '≥ ${nextTier.minSatisfaction}%',
          _satisfactionRate >= nextTier.minSatisfaction,
        ),
        _requirementRow(
          S.of(context).onTimeRate,
          '${_onTimeRate.toStringAsFixed(0)}%',
          '≥ ${nextTier.minOnTime}%',
          _onTimeRate >= nextTier.minOnTime,
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
                    S
                        .of(context)
                        .pointsAndRewards(
                          tier.pointsRequired,
                          tier.rewards.length,
                        ),
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
                    _reqLine(S.of(context).reqAcceptance(tier.minAcceptance)),
                    _reqLine(
                      S.of(context).reqCancellation(tier.maxCancellation),
                    ),
                    _reqLine(
                      S.of(context).reqSatisfaction(tier.minSatisfaction),
                    ),
                    _reqLine(S.of(context).reqOnTime(tier.minOnTime)),
                    _reqLine(S.of(context).pointsCount(tier.pointsRequired)),
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
  final int minAcceptance;
  final int maxCancellation;
  final int minSatisfaction;
  final int minOnTime;
  final int pointsRequired;
  final List<String> rewards;

  const _Tier({
    required this.name,
    required this.color,
    required this.icon,
    required this.minAcceptance,
    required this.maxCancellation,
    required this.minSatisfaction,
    required this.minOnTime,
    required this.pointsRequired,
    required this.rewards,
  });
}
