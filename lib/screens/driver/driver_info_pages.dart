import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_localizations.dart';
import '../../config/page_transitions.dart';
import 'driver_profile_photo_screen.dart';

// ═══════════════════════════════════════════════════════════════
//  Reusable dark-themed info page shell
// ═══════════════════════════════════════════════════════════════

class _InfoPageShell extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final List<Widget> children;

  const _InfoPageShell({
    required this.title,
    required this.icon,
    this.iconColor = const Color(0xFFE8C547),
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            // Top bar — back arrow left, title centered
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                    title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            // Content
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: iconColor.withValues(alpha: 0.12),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(icon, color: iconColor, size: 32),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ...children,
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _card(String title, String body, {IconData? icon}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF1C1C1E),
      borderRadius: BorderRadius.circular(16),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, color: const Color(0xFFE8C547), size: 20),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
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
              const SizedBox(height: 4),
              Text(
                body,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

Widget _comingSoonCard(BuildContext context, String title, String body, {IconData? icon}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 12),
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: const Color(0xFF1C1C1E),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(
        color: const Color(0xFFE8C547).withValues(alpha: 0.15),
      ),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Icon(icon, color: const Color(0xFFE8C547).withValues(alpha: 0.4), size: 20),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.4),
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFFE8C547).withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      S.of(context).comingSoon,
                      style: const TextStyle(
                        color: Color(0xFFE8C547),
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Text(
                body,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.25),
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
          ),
        ),
      ],
    ),
  );
}

// ═══════════════════════════════════════════════════════════════
//  OPPORTUNITIES SCREEN
// ═══════════════════════════════════════════════════════════════

class OpportunitiesScreen extends StatelessWidget {
  const OpportunitiesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _InfoPageShell(
      title: S.of(context).opportunities,
      icon: Icons.trending_up_rounded,
      children: [
        _card(
          S.of(context).peakHoursBonusTitle,
          S.of(context).peakHoursBonusDesc,
          icon: Icons.access_time_filled_rounded,
        ),
        _card(
          S.of(context).weekendWarriorBonusTitle,
          S.of(context).weekendWarriorBonusDesc,
          icon: Icons.calendar_today_rounded,
        ),
        _comingSoonCard(
          context,
          S.of(context).airportRunsTitle,
          S.of(context).airportRunsDesc,
          icon: Icons.flight_takeoff_rounded,
        ),
        _comingSoonCard(
          context,
          S.of(context).eventSurgeTitle,
          S.of(context).eventSurgeDesc,
          icon: Icons.celebration_rounded,
        ),
        _comingSoonCard(
          context,
          S.of(context).consecutiveTripBonusTitle,
          S.of(context).consecutiveTripBonusDesc,
          icon: Icons.repeat_rounded,
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  WORK HUB SCREEN
// ═══════════════════════════════════════════════════════════════

class WorkHubScreen extends StatelessWidget {
  const WorkHubScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _InfoPageShell(
      title: S.of(context).workHub,
      icon: Icons.work_outline_rounded,
      iconColor: const Color(0xFF2196F3),
      children: [
        _card(
          S.of(context).rideServicesTitle,
          S.of(context).rideServicesDesc,
          icon: Icons.local_taxi_rounded,
        ),
        _comingSoonCard(
          context,
          S.of(context).packageDeliveryTitle,
          S.of(context).packageDeliveryDesc,
          icon: Icons.inventory_2_rounded,
        ),
        _comingSoonCard(
          context,
          S.of(context).groceryDeliveryTitle,
          S.of(context).groceryDeliveryDesc,
          icon: Icons.shopping_cart_rounded,
        ),
        _card(
          S.of(context).scheduledRidesWorkHubTitle,
          S.of(context).scheduledRidesWorkHubDesc,
          icon: Icons.schedule_rounded,
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  REFER FRIENDS SCREEN — moved to driver_referral_screen.dart and
//  upgraded to a live, end-to-end driver-to-driver referral flow
//  (see lib/screens/driver/driver_referral_screen.dart).
// ═══════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════
//  INSURANCE SCREEN
// ═══════════════════════════════════════════════════════════════

class DriverInsuranceScreen extends StatelessWidget {
  const DriverInsuranceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _InfoPageShell(
      title: S.of(context).insuranceLabel,
      icon: Icons.security_rounded,
      iconColor: const Color(0xFF00BCD4),
      children: [
        _card(
          S.of(context).cruiseDriverProtectionTitle,
          S.of(context).cruiseDriverProtectionDesc,
          icon: Icons.shield_rounded,
        ),
        _card(
          S.of(context).liabilityCoverageTitle,
          S.of(context).liabilityCoverageDesc,
          icon: Icons.verified_user_rounded,
        ),
        _card(
          S.of(context).collisionCoverageTitle,
          S.of(context).collisionCoverageDesc,
          icon: Icons.car_crash_rounded,
        ),
        _card(
          S.of(context).uninsuredMotoristTitle,
          S.of(context).uninsuredMotoristDesc,
          icon: Icons.warning_rounded,
        ),
        _card(
          S.of(context).personalInsuranceTitle,
          S.of(context).personalInsuranceDesc,
          icon: Icons.assignment_rounded,
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  TAX INFO SCREEN
// ═══════════════════════════════════════════════════════════════

class TaxInfoScreen extends StatelessWidget {
  const TaxInfoScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _InfoPageShell(
      title: S.of(context).taxInfo,
      icon: Icons.receipt_long_rounded,
      iconColor: const Color(0xFFFF9800),
      children: [
        _card(
          S.of(context).taxDocumentsTitle,
          S.of(context).taxDocumentsDesc,
          icon: Icons.description_rounded,
        ),
        _card(
          S.of(context).earningsSummaryTitle,
          S.of(context).earningsSummaryDesc,
          icon: Icons.summarize_rounded,
        ),
        _card(
          S.of(context).deductibleExpensesTitle,
          S.of(context).deductibleExpensesDesc,
          icon: Icons.calculate_rounded,
        ),
        _card(
          S.of(context).taxTipsTitle,
          S.of(context).taxTipsDesc,
          icon: Icons.lightbulb_outline_rounded,
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  PLUS CARD SCREEN
// ═══════════════════════════════════════════════════════════════

class PlusCardScreen extends StatelessWidget {
  const PlusCardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _InfoPageShell(
      title: S.of(context).plusCard,
      icon: Icons.credit_card_rounded,
      children: [
        Container(
          padding: const EdgeInsets.all(24),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF2D2D2D), Color(0xFF1A1A1F)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFE8C547).withValues(alpha: 0.3),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'CRUISE',
                    style: TextStyle(
                      color: Color(0xFFE8C547),
                      fontSize: 18,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 2,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.contactless_rounded,
                    color: Colors.white.withValues(alpha: 0.4),
                    size: 28,
                  ),
                ],
              ),
              const SizedBox(height: 30),
              Text(
                '•••• •••• •••• ••••',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 20,
                  letterSpacing: 3,
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'CRUISE PLUS',
                style: TextStyle(
                  color: Color(0xFFE8C547),
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.5,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          S.of(context).instantEarningsAccessTitle,
          S.of(context).instantEarningsAccessDesc,
          icon: Icons.flash_on_rounded,
        ),
        _card(
          S.of(context).cashBackRewardsTitle,
          S.of(context).cashBackRewardsDesc,
          icon: Icons.percent_rounded,
        ),
        _card(
          S.of(context).noAnnualFeeTitle,
          S.of(context).noAnnualFeeDesc,
          icon: Icons.money_off_rounded,
        ),
        const SizedBox(height: 16),
        Center(
          child: Text(
            S.of(context).comingSoon,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  LEARNING CENTER SCREEN
// ═══════════════════════════════════════════════════════════════

class LearningCenterScreen extends StatelessWidget {
  const LearningCenterScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final topics = [
      _LearningTopic(
        title: s.lcGettingStartedTitle,
        subtitle: s.lcGettingStartedSubtitle,
        icon: Icons.play_circle_outline_rounded,
        color: const Color(0xFF4CAF50),
        content: [
          s.lcGettingStarted1,
          s.lcGettingStarted2,
          s.lcGettingStarted3,
          s.lcGettingStarted4,
          s.lcGettingStarted5,
        ],
      ),
      _LearningTopic(
        title: s.lcNavTipsTitle,
        subtitle: s.lcNavTipsSubtitle,
        icon: Icons.navigation_rounded,
        color: const Color(0xFF2196F3),
        content: [
          s.lcNavTip1,
          s.lcNavTip2,
          s.lcNavTip3,
          s.lcNavTip4,
          s.lcNavTip5,
        ],
      ),
      _LearningTopic(
        title: s.lcRiderCommTitle,
        subtitle: s.lcRiderCommSubtitle,
        icon: Icons.chat_bubble_outline_rounded,
        color: const Color(0xFFFF9800),
        content: [
          s.lcRiderComm1,
          s.lcRiderComm2,
          s.lcRiderComm3,
          s.lcRiderComm4,
          s.lcRiderComm5,
        ],
      ),
      _LearningTopic(
        title: s.lcSafetyTitle,
        subtitle: s.lcSafetySubtitle,
        icon: Icons.health_and_safety_rounded,
        color: const Color(0xFFE53935),
        content: [
          s.lcSafety1,
          s.lcSafety2,
          s.lcSafety3,
          s.lcSafety4,
          s.lcSafety5,
        ],
      ),
      _LearningTopic(
        title: s.lcMaxEarningsTitle,
        subtitle: s.lcMaxEarningsSubtitle,
        icon: Icons.attach_money_rounded,
        color: const Color(0xFFE8C547),
        content: [
          s.lcMaxEarnings1,
          s.lcMaxEarnings2,
          s.lcMaxEarnings3,
          s.lcMaxEarnings4,
          s.lcMaxEarnings5,
        ],
      ),
      _LearningTopic(
        title: s.lcVehicleMaintenanceTitle,
        subtitle: s.lcVehicleMaintenanceSubtitle,
        icon: Icons.build_rounded,
        color: const Color(0xFF9C27B0),
        content: [
          s.lcVehicleMaintenance1,
          s.lcVehicleMaintenance2,
          s.lcVehicleMaintenance3,
          s.lcVehicleMaintenance4,
          s.lcVehicleMaintenance5,
        ],
      ),
    ];

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                    S.of(context).learningCenter,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView.builder(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
                itemCount: topics.length,
                itemBuilder: (context, i) {
                  final topic = topics[i];
                  return GestureDetector(
                    onTap: () {
                      HapticService.selectionClick();
                      Navigator.push(
                        context,
                        slideFromRightRoute(_LearningTopicScreen(topic: topic)),
                      );
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 44,
                            height: 44,
                            decoration: BoxDecoration(
                              color: topic.color.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Icon(topic.icon, color: topic.color, size: 22),
                          ),
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  topic.title,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  topic.subtitle,
                                  style: TextStyle(
                                    color: Colors.white.withValues(alpha: 0.5),
                                    fontSize: 13,
                                    height: 1.4,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          Icon(
                            Icons.chevron_right_rounded,
                            color: Colors.white.withValues(alpha: 0.2),
                            size: 20,
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LearningTopic {
  final String title;
  final String subtitle;
  final IconData icon;
  final Color color;
  final List<String> content;

  const _LearningTopic({
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.color,
    required this.content,
  });
}

class _LearningTopicScreen extends StatelessWidget {
  final _LearningTopic topic;
  const _LearningTopicScreen({required this.topic});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                    topic.title,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: BoxDecoration(
                        color: topic.color.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(topic.icon, color: topic.color, size: 32),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Center(
                    child: Text(
                      topic.title,
                      style: TextStyle(
                        color: topic.color,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Center(
                    child: Text(
                      topic.subtitle,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(height: 24),
                  ...topic.content.asMap().entries.map((e) {
                    return Container(
                      margin: const EdgeInsets.only(bottom: 12),
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 26,
                            height: 26,
                            decoration: BoxDecoration(
                              color: topic.color.withValues(alpha: 0.15),
                              shape: BoxShape.circle,
                            ),
                            child: Center(
                              child: Text(
                                '${e.key + 1}',
                                style: TextStyle(
                                  color: topic.color,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              e.value,
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.8),
                                fontSize: 14,
                                height: 1.5,
                              ),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  NEW DRIVER INSTRUCTIONS SCREEN (shown to newly approved drivers)
//  3 swipeable pages with animated scene illustrations
// ═══════════════════════════════════════════════════════════════

class NewDriverInstructionsScreen extends StatefulWidget {
  const NewDriverInstructionsScreen({super.key});

  @override
  State<NewDriverInstructionsScreen> createState() =>
      _NewDriverInstructionsScreenState();
}

class _NewDriverInstructionsScreenState
    extends State<NewDriverInstructionsScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);
  static const _bg = Color(0xFF0A0A0A);

  final _pageCtrl = PageController();
  int _currentPage = 0;
  bool _viewedAllPages = false;

  @override
  void dispose() {
    _pageCtrl.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    setState(() => _currentPage = page);
    if (page == 2 && !_viewedAllPages) {
      setState(() => _viewedAllPages = true);
    }
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
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: ClipOval(
                      child: Image.asset(
                        'assets/images/logoapp.png',
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Instructions',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            // ── Page indicator dots ──
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: List.generate(3, (i) {
                final isActive = i == _currentPage;
                return AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  margin: const EdgeInsets.symmetric(horizontal: 4),
                  width: isActive ? 28 : 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: isActive
                        ? _gold
                        : Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),

            // ── Swipeable pages (swipe only, no scroll) ──
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                onPageChanged: _onPageChanged,
                physics: const ClampingScrollPhysics(),
                children: [
                  _buildPage0(context),
                  _buildPage1(context),
                  _buildPage2(context),
                ],
              ),
            ),

            // ── "Let's Go" button (appears after viewing all pages, but NOT on page 2
            // because Page 2 has its own embedded button) ──
            if (_viewedAllPages && _currentPage != 2)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: SizedBox(
                  width: double.infinity,
                  height: 56,
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [_gold, _goldLight],
                      ),
                      borderRadius: BorderRadius.circular(28),
                      boxShadow: [
                        BoxShadow(
                          color: _gold.withValues(alpha: 0.4),
                          blurRadius: 20,
                          offset: const Offset(0, 6),
                        ),
                      ],
                    ),
                    child: ElevatedButton(
                      onPressed: () {
                        HapticService.mediumImpact();
                        Navigator.of(context).pushAndRemoveUntil(
                          slideFromRightRoute(
                              const DriverProfilePhotoScreen()),
                          (_) => false,
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.transparent,
                        shadowColor: Colors.transparent,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(28),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            S.of(context).letsGoBtn,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w900,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Icon(Icons.arrow_forward_rounded, size: 22),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // Swipe hint when button is not yet visible
            if (!_viewedAllPages)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.swipe_rounded,
                        color: Colors.white.withValues(alpha: 0.3), size: 18),
                    const SizedBox(width: 6),
                    Text(
                      'Swipe to continue',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
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

  Widget _buildPage0(BuildContext context) {
    return const _Page0();
  }

  Widget _buildPage1(BuildContext context) {
    return const _Page1();
  }

  Widget _buildPage2(BuildContext context) {
    return _Page2(
      onLetsGo: () {
        HapticService.mediumImpact();
        Navigator.of(context).pushAndRemoveUntil(
          slideFromRightRoute(const DriverProfilePhotoScreen()),
          (_) => false,
        );
      },
    );
  }

  Widget _buildPage({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required List<_InstructionItem> items,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Column(
        children: [
          const SizedBox(height: 4),
          // ── Static icon ──
          Container(
            width: 64,
            height: 64,
            decoration: BoxDecoration(
              color: iconColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: iconColor, size: 32),
          ),
          const SizedBox(height: 12),
          Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 16),
          // ── Cards fill remaining space ──
          Expanded(
            child: SingleChildScrollView(
              physics: const NeverScrollableScrollPhysics(),
              child: Column(
                children: items.map((item) => _buildInstructionCard(item)).toList(),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInstructionCard(_InstructionItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF161618),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: item.color.withValues(alpha: 0.10)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(item.icon, color: item.color, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  item.body,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  PAGE 0 — "Keep Your Vehicle Spotless" (full-bleed background redesign)
// ═══════════════════════════════════════════════════════════════

class _Page0 extends StatefulWidget {
  const _Page0();

  @override
  State<_Page0> createState() => _Page0State();
}

class _Page0State extends State<_Page0> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFD4AF37);
  late final AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _animCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      if (!_animCtrl.isCompleted) _animCtrl.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animCtrl.dispose();
    super.dispose();
  }

  Animation<double> _fade(double begin, double end) =>
      Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: _animCtrl,
          curve: Interval(begin, end, curve: Curves.easeOut),
        ),
      );

  Animation<Offset> _slideUp(double begin, double end) =>
      Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _animCtrl,
          curve: Interval(begin, end, curve: Curves.easeOut),
        ),
      );

  Widget _animatedCard({
    required double fadeBegin,
    required double fadeEnd,
    required double slideBegin,
    required double slideEnd,
    required IconData icon,
    required String title,
    required String description,
  }) {
    return FadeTransition(
      opacity: _fade(fadeBegin, fadeEnd),
      child: SlideTransition(
        position: _slideUp(slideBegin, slideEnd),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _gold.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: _gold, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.5,
                        height: 1.4,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Background image ──
        Image.asset(
          'assets/images/suburban_2023_interior_fullframe.png',
          fit: BoxFit.cover,
        ),
        // ── Dark gradient overlay ──
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.3),
                Colors.black.withValues(alpha: 0.85),
              ],
            ),
          ),
        ),
        // ── Content ──
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 20),
                // ── Header icon ──
                FadeTransition(
                  opacity: _fade(0.0, 0.2),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.8, end: 1.0).animate(
                      CurvedAnimation(
                        parent: _animCtrl,
                        curve: const Interval(0.0, 0.2, curve: Curves.easeOutBack),
                      ),
                    ),
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: _gold, width: 2),
                        color: Colors.black.withValues(alpha: 0.5),
                      ),
                      child: const Icon(
                        Icons.local_car_wash_rounded,
                        color: _gold,
                        size: 28,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // ── Title + Subtitle pill ──
                FadeTransition(
                  opacity: _fade(0.0, 0.3),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: _gold.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'KEEP YOUR VEHICLE SPOTLESS',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _gold,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2.0,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'FIRST IMPRESSIONS MATTER',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 3.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // ── Cards ──
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _animatedCard(
                        fadeBegin: 0.2, fadeEnd: 0.5,
                        slideBegin: 0.2, slideEnd: 0.5,
                        icon: Icons.auto_fix_high_rounded,
                        title: 'CLEAN INSIDE & OUT',
                        description: 'WASH YOUR CAR REGULARLY AND KEEP THE INTERIOR CLEAN',
                      ),
                      _animatedCard(
                        fadeBegin: 0.35, fadeEnd: 0.65,
                        slideBegin: 0.35, slideEnd: 0.65,
                        icon: Icons.ac_unit_rounded,
                        title: 'FRESH & COMFORTABLE',
                        description: 'KEEP THE CABIN FRESH WITH A PLEASANT SCENT',
                      ),
                      _animatedCard(
                        fadeBegin: 0.5, fadeEnd: 0.8,
                        slideBegin: 0.5, slideEnd: 0.8,
                        icon: Icons.phone_iphone_rounded,
                        title: 'PHONE MOUNT & CHARGER',
                        description: 'USE A SECURE PHONE MOUNT AND OFFER A CHARGER',
                      ),
                      _animatedCard(
                        fadeBegin: 0.65, fadeEnd: 0.95,
                        slideBegin: 0.65, slideEnd: 0.95,
                        icon: Icons.checkroom_rounded,
                        title: 'PROFESSIONAL APPEARANCE',
                        description: 'DRESS NEATLY AND PROFESSIONALLY',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // ── Dots + swipe hint ──
                FadeTransition(
                  opacity: _fade(0.8, 1.0),
                  child: Column(
                    children: [
                      // 3 dots
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _dot(active: true),
                          const SizedBox(width: 8),
                          _dot(active: false),
                          const SizedBox(width: 8),
                          _dot(active: false),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Bouncing swipe text
                      _BounceText(
                        text: 'SWIPE TO CONTINUE',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dot({required bool active}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: active ? 24 : 6,
      height: 6,
      decoration: BoxDecoration(
        color: active ? _gold : Colors.white.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

// ── Bouncing text widget ──
class _BounceText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _BounceText({required this.text, required this.style});

  @override
  State<_BounceText> createState() => _BounceTextState();
}

class _BounceTextState extends State<_BounceText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) {
        final y = 4 * math.sin(_ctrl.value * 2 * math.pi);
        return Transform.translate(
          offset: Offset(0, y),
          child: Text(widget.text, style: widget.style),
        );
      },
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  PAGE 1 — "Drive Safe, Always" (full-bleed background redesign)
// ═══════════════════════════════════════════════════════════════

class _Page1 extends StatefulWidget {
  const _Page1();

  @override
  State<_Page1> createState() => _Page1State();
}

class _Page1State extends State<_Page1> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFD4AF37);
  late final AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _animCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      if (!_animCtrl.isCompleted) _animCtrl.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animCtrl.dispose();
    super.dispose();
  }

  Animation<double> _fade(double begin, double end) =>
      Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: _animCtrl,
          curve: Interval(begin, end, curve: Curves.easeOut),
        ),
      );

  Animation<Offset> _slideUp(double begin, double end) =>
      Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _animCtrl,
          curve: Interval(begin, end, curve: Curves.easeOut),
        ),
      );

  Widget _animatedCard({
    required double fadeBegin,
    required double fadeEnd,
    required double slideBegin,
    required double slideEnd,
    required IconData icon,
    required String title,
    required String description,
  }) {
    return FadeTransition(
      opacity: _fade(fadeBegin, fadeEnd),
      child: SlideTransition(
        position: _slideUp(slideBegin, slideEnd),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _gold.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: _gold, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.5,
                        height: 1.4,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Background image ──
        Image.asset(
          'assets/images/safety_rules_suburban.png',
          fit: BoxFit.cover,
        ),
        // ── Dark gradient overlay ──
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.3),
                Colors.black.withValues(alpha: 0.85),
              ],
            ),
          ),
        ),
        // ── Content ──
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 20),
                // ── Header icon ──
                FadeTransition(
                  opacity: _fade(0.0, 0.2),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.8, end: 1.0).animate(
                      CurvedAnimation(
                        parent: _animCtrl,
                        curve: const Interval(0.0, 0.2, curve: Curves.easeOutBack),
                      ),
                    ),
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: _gold, width: 2),
                        color: Colors.black.withValues(alpha: 0.5),
                      ),
                      child: const Icon(
                        Icons.shield_rounded,
                        color: _gold,
                        size: 28,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // ── Title + Subtitle pill ──
                FadeTransition(
                  opacity: _fade(0.0, 0.3),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: _gold.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'DRIVE SAFE, ALWAYS',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _gold,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2.0,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'SAFETY IS YOUR #1 PRIORITY',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 3.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // ── Cards ──
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _animatedCard(
                        fadeBegin: 0.2, fadeEnd: 0.5,
                        slideBegin: 0.2, slideEnd: 0.5,
                        icon: Icons.speed_rounded,
                        title: 'OBEY TRAFFIC LAWS',
                        description: 'FOLLOW SPEED LIMIT AND TRAFFIC SIGNS',
                      ),
                      _animatedCard(
                        fadeBegin: 0.35, fadeEnd: 0.65,
                        slideBegin: 0.35, slideEnd: 0.65,
                        icon: Icons.no_drinks_rounded,
                        title: 'ZERO TOLERANCE POLICY',
                        description: 'NEVER DRIVE UNDER THE INFLUENCE OF ALCOHOL OR DRUGS',
                      ),
                      _animatedCard(
                        fadeBegin: 0.5, fadeEnd: 0.8,
                        slideBegin: 0.5, slideEnd: 0.8,
                        icon: Icons.visibility_rounded,
                        title: 'STAY FOCUSED',
                        description: 'NO TEXTING WHILE DRIVING',
                      ),
                      _animatedCard(
                        fadeBegin: 0.65, fadeEnd: 0.95,
                        slideBegin: 0.65, slideEnd: 0.95,
                        icon: Icons.health_and_safety_rounded,
                        title: 'SEATBELT REQUIRED',
                        description: 'ENSURE ALL PASSENGERS WEAR THEIR SEATBELT',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // ── Dots + swipe hint ──
                FadeTransition(
                  opacity: _fade(0.8, 1.0),
                  child: Column(
                    children: [
                      // 3 dots
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _dot(active: false),
                          const SizedBox(width: 8),
                          _dot(active: true),
                          const SizedBox(width: 8),
                          _dot(active: false),
                        ],
                      ),
                      const SizedBox(height: 12),
                      // Bouncing swipe text
                      _BounceText(
                        text: 'SWIPE TO CONTINUE',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 1.5,
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dot({required bool active}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: active ? 24 : 6,
      height: 6,
      decoration: BoxDecoration(
        color: active ? _gold : Colors.white.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  PAGE 2 — "Deliver 5-Star Service" (full-bleed background redesign)
// ═══════════════════════════════════════════════════════════════

class _Page2 extends StatefulWidget {
  final VoidCallback onLetsGo;
  const _Page2({required this.onLetsGo});

  @override
  State<_Page2> createState() => _Page2State();
}

class _Page2State extends State<_Page2> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFD4AF37);
  static const _goldDark = Color(0xFFB8960C);
  late final AnimationController _animCtrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _animCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..forward();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _animCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      if (!_animCtrl.isCompleted) _animCtrl.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _animCtrl.dispose();
    super.dispose();
  }

  Animation<double> _fade(double begin, double end) =>
      Tween<double>(begin: 0.0, end: 1.0).animate(
        CurvedAnimation(
          parent: _animCtrl,
          curve: Interval(begin, end, curve: Curves.easeOut),
        ),
      );

  Animation<Offset> _slideUp(double begin, double end) =>
      Tween<Offset>(begin: const Offset(0, 0.1), end: Offset.zero).animate(
        CurvedAnimation(
          parent: _animCtrl,
          curve: Interval(begin, end, curve: Curves.easeOut),
        ),
      );

  Widget _animatedCard({
    required double fadeBegin,
    required double fadeEnd,
    required double slideBegin,
    required double slideEnd,
    required IconData icon,
    required String title,
    required String description,
  }) {
    return FadeTransition(
      opacity: _fade(fadeBegin, fadeEnd),
      child: SlideTransition(
        position: _slideUp(slideBegin, slideEnd),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: _gold.withValues(alpha: 0.3),
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A1A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: _gold, size: 24),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      title,
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      description,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.85),
                        fontSize: 11,
                        fontWeight: FontWeight.w400,
                        letterSpacing: 0.5,
                        height: 1.4,
                      ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
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

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // ── Background image ──
        Image.asset(
          'assets/images/five_star_service.png',
          fit: BoxFit.cover,
        ),
        // ── Dark gradient overlay ──
        Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Colors.black.withValues(alpha: 0.3),
                Colors.black.withValues(alpha: 0.85),
              ],
            ),
          ),
        ),
        // ── Content ──
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Column(
              children: [
                const SizedBox(height: 20),
                // ── Header icon ──
                FadeTransition(
                  opacity: _fade(0.0, 0.2),
                  child: ScaleTransition(
                    scale: Tween<double>(begin: 0.8, end: 1.0).animate(
                      CurvedAnimation(
                        parent: _animCtrl,
                        curve: const Interval(0.0, 0.2, curve: Curves.easeOutBack),
                      ),
                    ),
                    child: Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: _gold, width: 2),
                        color: Colors.black.withValues(alpha: 0.5),
                      ),
                      child: const Icon(
                        Icons.star_rounded,
                        color: _gold,
                        size: 28,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                // ── Title + Subtitle pill ──
                FadeTransition(
                  opacity: _fade(0.0, 0.3),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.6),
                      borderRadius: BorderRadius.circular(30),
                      border: Border.all(
                        color: _gold.withValues(alpha: 0.3),
                        width: 1,
                      ),
                    ),
                    child: Column(
                      children: [
                        Text(
                          'DELIVER 5-STAR SERVICE',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: _gold,
                            fontSize: 20,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 2.0,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'MAKE EVERY RIDE MEMORABLE',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.8),
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            letterSpacing: 3.0,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                // ── Cards ──
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      _animatedCard(
                        fadeBegin: 0.2, fadeEnd: 0.5,
                        slideBegin: 0.2, slideEnd: 0.5,
                        icon: Icons.waving_hand_rounded,
                        title: 'GREET EVERY RIDER',
                        description: 'WELCOME RIDERS BY NAME',
                      ),
                      _animatedCard(
                        fadeBegin: 0.35, fadeEnd: 0.65,
                        slideBegin: 0.35, slideEnd: 0.65,
                        icon: Icons.location_on_rounded,
                        title: 'EFFICIENT ROUTES',
                        description: 'FOLLOW GPS NAVIGATION AND TAKE THE FASTEST ROUTE',
                      ),
                      _animatedCard(
                        fadeBegin: 0.5, fadeEnd: 0.8,
                        slideBegin: 0.5, slideEnd: 0.8,
                        icon: Icons.volume_up_rounded,
                        title: 'RESPECT PREFERENCES',
                        description: 'KEEP MUSIC LOW AND ASK FOR PREFERENCES',
                      ),
                      _animatedCard(
                        fadeBegin: 0.65, fadeEnd: 0.95,
                        slideBegin: 0.65, slideEnd: 0.95,
                        icon: Icons.star_rounded,
                        title: 'GO THE EXTRA MILE',
                        description: 'HELP WITH LUGGAGE AND OFFER A PREMIUM EXPERIENCE',
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                // ── Dots + Let's Go button ──
                FadeTransition(
                  opacity: _fade(0.8, 1.0),
                  child: Column(
                    children: [
                      // 3 dots
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          _dot(active: false),
                          const SizedBox(width: 8),
                          _dot(active: false),
                          const SizedBox(width: 8),
                          _dot(active: true),
                        ],
                      ),
                      const SizedBox(height: 16),
                      // Let's Go button
                      GestureDetector(
                        onTap: widget.onLetsGo,
                        child: Container(
                          width: double.infinity,
                          height: 56,
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [_gold, _goldDark],
                            ),
                            borderRadius: BorderRadius.circular(28),
                            boxShadow: [
                              BoxShadow(
                                color: _gold.withValues(alpha: 0.4),
                                blurRadius: 12,
                                offset: const Offset(0, 4),
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                "Let's Go!",
                                style: TextStyle(
                                  color: Color(0xFF0A0A0A),
                                  fontSize: 16,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.5,
                                ),
                              ),
                              SizedBox(width: 8),
                              Icon(
                                Icons.arrow_forward_rounded,
                                color: Color(0xFF0A0A0A),
                                size: 22,
                              ),
                            ],
                          ),
                        ),
                      ),
                      const SizedBox(height: 16),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _dot({required bool active}) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      width: active ? 24 : 6,
      height: 6,
      decoration: BoxDecoration(
        color: active ? _gold : Colors.white.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(3),
      ),
    );
  }
}

// ── Data class ──
class _InstructionItem {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  const _InstructionItem({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });
}



// ═══════════════════════════════════════════════════════════════
//  BUG REPORTER SCREEN
// ═══════════════════════════════════════════════════════════════

class BugReporterScreen extends StatefulWidget {
  const BugReporterScreen({super.key});

  @override
  State<BugReporterScreen> createState() => _BugReporterScreenState();
}

class _BugReporterScreenState extends State<BugReporterScreen> {
  static const _gold = Color(0xFFE8C547);
  final _controller = TextEditingController();
  String _category = 'App Crash';
  bool _submitted = false;

  final _categories = [
    'App Crash',
    'Map Issue',
    'Payment Problem',
    'Trip Error',
    'Navigation Bug',
    'UI Glitch',
    'Other',
  ];

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0A),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
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
                    S.of(context).bugReporter,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  if (_submitted) ...[
                    const SizedBox(height: 40),
                    const Center(
                      child: Icon(
                        Icons.check_circle_rounded,
                        color: Color(0xFF4CAF50),
                        size: 64,
                      ),
                    ),
                    const SizedBox(height: 16),
                    const Center(
                      child: Text(
                        'Report Submitted',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Center(
                      child: Text(
                        'Thank you! Our team will review your report.',
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ] else ...[
                    // Category selector
                    Text(
                      'Category',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _category,
                          isExpanded: true,
                          dropdownColor: const Color(0xFF2C2C2E),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                          ),
                          items: _categories
                              .map(
                                (c) =>
                                    DropdownMenuItem(value: c, child: Text(c)),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _category = v);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      'Description',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Container(
                      decoration: BoxDecoration(
                        color: const Color(0xFF1C1C1E),
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: TextField(
                        controller: _controller,
                        maxLines: 6,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                        ),
                        decoration: InputDecoration(
                          hintText: 'Describe the issue...',
                          hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.2),
                          ),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.all(16),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton(
                        onPressed: () {
                          if (_controller.text.trim().isEmpty) return;
                          HapticService.mediumImpact();
                          setState(() => _submitted = true);
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: Colors.black,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                        ),
                        child: const Text(
                          'Submit Report',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(height: 40),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  DRIVER SAFETY SCREEN
// ═══════════════════════════════════════════════════════════════

class DriverSafetyScreen extends StatelessWidget {
  const DriverSafetyScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _InfoPageShell(
      title: S.of(context).safetyLabel,
      icon: Icons.shield_rounded,
      iconColor: const Color(0xFF4CAF50),
      children: [
        _card(
          'Emergency SOS',
          'Tap the shield icon during any trip to alert emergency services and share your live location.',
          icon: Icons.emergency_rounded,
        ),
        _card(
          'Trip Sharing',
          'Share your live trip status with trusted contacts so they can follow your journey in real time.',
          icon: Icons.location_on_rounded,
        ),
        _card(
          'Rider Verification',
          'All riders are verified with phone number and payment method before they can request a ride.',
          icon: Icons.verified_user_rounded,
        ),
        _card(
          'Dash Cam Support',
          'Cruise supports in-app dash cam recording for your safety. Enable in Settings.',
          icon: Icons.videocam_rounded,
        ),
        _card(
          'Incident Reporting',
          'Report any safety concerns or incidents directly through the app for quick resolution.',
          icon: Icons.report_rounded,
        ),
        _card(
          'COVID-19 Safety',
          'Follow our health and safety guidelines to protect yourself and your riders.',
          icon: Icons.masks_rounded,
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () =>
              launchUrl(Uri.parse('https://cruiseinride.com/driver-safety')),
          child: Center(
            child: Text(
              'View Full Safety Guidelines →',
              style: TextStyle(
                color: const Color(0xFFE8C547),
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
