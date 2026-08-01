import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../l10n/app_localizations.dart';
import '../../widgets/neu_style.dart';
import '../../services/api_service.dart';
import 'dart:math' as math;

/// Cruise Level – Bronze → Silver → Gold → Platinum → Diamond
class CruiseLevelScreen extends StatefulWidget {
  const CruiseLevelScreen({super.key});

  @override
  State<CruiseLevelScreen> createState() => _CruiseLevelScreenState();
}

class _CruiseLevelScreenState extends State<CruiseLevelScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);
  /// A requirement already met. Green because it is done, not
  /// because it is good — the tier colours already carry the mood.
  static const _green = Color(0xFF4CAF50);
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
  int _completedTrips = 0;

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
    WidgetsBinding.instance.addObserver(this);
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _celebrationCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      if (_showLevelUp) _celebrationCtrl.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _celebrationCtrl.dispose();
    super.dispose();
  }

  Future<SharedPreferences> _getPrefs() => SharedPreferences.getInstance();

  void _triggerLevelUp() {
    if (!mounted) return;
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

      final userId = await ApiService.getCurrentUserId().timeout(const Duration(seconds: 15));
      if (userId != null) {
        final stats = await ApiService.getDriverStats(userId).timeout(const Duration(seconds: 15));
        final completed = (stats['completed_trips'] as num?)?.toInt() ?? 0;
        final canceled = (stats['canceled_trips'] as num?)?.toInt() ?? 0;
        final total = (stats['total_trips'] as num?)?.toInt() ?? 0;
        // New drivers have no trips → no rating. Don't show fake 5.0 stars.
        final rawRating = stats['avg_rating'];
        final avgRating = rawRating == null ? 0.0 : (rawRating as num).toDouble();

        _completedTrips = completed;
        _avgRating = avgRating;
        _satisfactionRate = total > 0 ? (completed / total * 100) : 0;
        _cancellationRate = total > 0 ? (canceled / total * 100) : 0;
        _acceptanceRate = (stats['acceptance_rate'] as num?)?.toDouble() ?? 100;
        _onTimeRate = (stats['on_time_rate'] as num?)?.toDouble() ?? 95;

        // Use backend authoritative cruise_level if available,
        // otherwise fall back to client-side computation
        final backendLevel = stats['cruise_level'] as String?;
        if (backendLevel != null && backendLevel.isNotEmpty) {
          const tierMap = {'bronze': 0, 'silver': 1, 'gold': 2, 'platinum': 3, 'diamond': 4};
          _currentTierIndex = tierMap[backendLevel.toLowerCase()] ?? 0;
        } else {
          // Fallback: compute client-side
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
      backgroundColor: neuBase,
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

                // The tier band runs edge to edge, so it reads as the page's
                // own colour rather than a card that happens to be coloured.
                SliverToBoxAdapter(child: _buildTierBanner()),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),

                        _buildNextTierPitch(),
                        const SizedBox(height: 26),

                        // ── Progress requirements ──
                        _buildUnlockSection(),
                        const SizedBox(height: 26),
                        _buildMetricsSection(),
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



  Widget _metricRow(IconData icon, String label, String value) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.white.withValues(alpha: 0.3), size: 20),
          const SizedBox(width: 14),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 14,
              ),
            ),
          ),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }


  /// The tier the driver is in, as a full-bleed band of its own colour.
  ///
  /// The reference opens on the tier and nothing else: a wash of its colour,
  /// its emblem, its name, and one way in to what it earns you. The card
  /// this replaces held the same facts in a bordered box halfway down a
  /// scroll, where a status is something you look up rather than something
  /// you are told.
  ///
  /// Neumorphic surfaces do not work on a coloured ground — the shadows that
  /// define them are tuned to #14141A — so the band is flat by design and
  /// every raised card below it sits on the app's own base.
  Widget _buildTierBanner() {
    final tier = _buildTiers()[_currentTierIndex];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 6, 20, 28),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            tier.color.withValues(alpha: 0.55),
            tier.color.withValues(alpha: 0.10),
            neuBase,
          ],
          stops: const [0.0, 0.55, 1.0],
        ),
      ),
      child: Column(
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.28),
              borderRadius: BorderRadius.circular(24),
            ),
            child: Icon(tier.icon, color: tier.color, size: 40),
          ),
          const SizedBox(height: 16),
          Text(
            S.of(context).cruiseLevel,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            tier.name,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.6,
            ),
          ),
          const SizedBox(height: 16),
          // The rewards this tier already pays, one tap away. It is the
          // answer to "so what?", which a level with no reward attached
          // never gives.
          GestureDetector(
            onTap: () {
              HapticService.selectionClick();
              _showRewardsSheet(tier);
            },
            child: Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 11),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(22),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.card_giftcard_rounded,
                      color: tier.color, size: 17),
                  const SizedBox(width: 9),
                  Text(
                    S.of(context).cruiseYourRewards(tier.name),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 6),
                  const Icon(Icons.arrow_forward_rounded,
                      color: Colors.white, size: 15),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// What the next tier is worth, before what it costs.
  ///
  /// The order matters. A list of requirements with no reward at the top of
  /// it is a list of chores; the reference leads with the reward and puts
  /// the requirements under it, and that is the difference between a target
  /// and a rebuke.
  Widget _buildNextTierPitch() {
    final tiers = _buildTiers();
    if (_currentTierIndex >= tiers.length - 1) return const SizedBox.shrink();
    final next = tiers[_currentTierIndex + 1];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: neuBox(radius: 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(next.icon, color: next.color, size: 17),
              const SizedBox(width: 8),
              Text(
                next.name,
                style: TextStyle(
                  color: next.color,
                  fontSize: 13.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            S.of(context).cruiseEarnMore,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w700,
              letterSpacing: -0.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            next.rewards.isEmpty
                ? S.of(context).cruiseKeepDriving
                : next.rewards.first,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 13,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }

  /// Requirements for the next tier, each with where the driver stands.
  ///
  /// Every row carries its own goal, so the number beside it means
  /// something without a legend. A row that is already met says so in green
  /// and gets out of the way; the heading counts only the ones left, which
  /// is the number a driver actually wants.
  Widget _buildUnlockSection() {
    final tiers = _buildTiers();
    if (_currentTierIndex >= tiers.length - 1) return const SizedBox.shrink();
    final next = tiers[_currentTierIndex + 1];
    final s = S.of(context);

    final reqs = <_Requirement>[
      _Requirement(
        icon: Icons.local_taxi_rounded,
        label: s.completedTrips,
        value: '$_completedTrips',
        goal: '≥ ${next.minTrips}',
        met: _completedTrips >= next.minTrips,
      ),
      _Requirement(
        icon: Icons.star_rounded,
        label: s.cruiseAverageRating,
        value: _avgRating.toStringAsFixed(2),
        goal: '≥ ${next.minRating}',
        met: _avgRating >= next.minRating,
      ),
    ];
    final remaining = reqs.where((r) => !r.met).length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.cruiseUnlock(next.name),
          style: const TextStyle(
            color: Colors.white,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          remaining == 0
              ? s.cruiseAllRequirementsMet
              : s.cruiseFocusOn(remaining, reqs.length),
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 13,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: neuBox(radius: 20),
          child: Column(
            children: [
              for (var i = 0; i < reqs.length; i++) ...[
                if (i > 0)
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                _unlockRow(reqs[i]),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _unlockRow(_Requirement r) {
    final s = S.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 15),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 32,
            height: 32,
            alignment: Alignment.center,
            decoration: neuBox(radius: 11, pressed: true),
            child: Icon(
              r.icon,
              size: 15,
              color: r.met ? _green : Colors.white.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 5),
                // The goal under the name, not tucked beside the figure.
                // It is what the figure is being measured against, and a
                // number with nothing to compare it to says nothing.
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: (r.met ? _green : _gold).withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: Text(
                    r.met
                        ? s.cruiseGoalMet
                        : s.cruiseGoal(r.goal),
                    style: TextStyle(
                      color: r.met ? _green : _gold,
                      fontSize: 10.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            r.value,
            style: TextStyle(
              color: r.met ? _green : Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }

  /// The four rates, as a block of plain figures.
  ///
  /// Kept, and kept quiet. None of them gates a tier — only trips and rating
  /// do — so drawing them like requirements would say they count when they
  /// do not.
  Widget _buildMetricsSection() {
    final s = S.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          s.cruisePerformanceMetrics,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.45),
            fontSize: 12,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.6,
          ),
        ),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          decoration: neuBox(radius: 20),
          child: Column(
            children: [
              _metricRow(Icons.thumb_up_outlined, s.satisfactionRate,
                  '${_satisfactionRate.toStringAsFixed(0)}%'),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
              _metricRow(Icons.cancel_outlined, s.cancellationRate,
                  '${_cancellationRate.toStringAsFixed(0)}%'),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
              _metricRow(Icons.check_circle_outline, s.acceptanceRate,
                  '${_acceptanceRate.toStringAsFixed(0)}%'),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.05)),
              _metricRow(Icons.schedule_rounded, s.onTimeRate,
                  '${_onTimeRate.toStringAsFixed(0)}%'),
            ],
          ),
        ),
      ],
    );
  }

  /// What a tier pays, on request.
  void _showRewardsSheet(_Tier tier) {
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: EdgeInsets.fromLTRB(
          24,
          14,
          24,
          24 + MediaQuery.of(ctx).padding.bottom,
        ),
        decoration: const BoxDecoration(
          color: neuBase,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white12,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              children: [
                Icon(tier.icon, color: tier.color, size: 22),
                const SizedBox(width: 10),
                Text(
                  S.of(context).cruiseYourRewards(tier.name),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 19,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            for (final r in tier.rewards)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.check_rounded, color: tier.color, size: 17),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        r,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 14,
                          height: 1.4,
                        ),
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

  Widget _buildTierCard(int index, _Tier tier) {
    final isCurrent = index == _currentTierIndex;
    final isLocked = index > _currentTierIndex;

    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
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

/// One line of "here is where you stand against the next tier".
class _Requirement {
  const _Requirement({
    required this.icon,
    required this.label,
    required this.value,
    required this.goal,
    required this.met,
  });

  final IconData icon;
  final String label;

  /// Where the driver is, as they should read it.
  final String value;

  /// Where they need to be, already formatted with its comparator.
  final String goal;

  final bool met;
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
