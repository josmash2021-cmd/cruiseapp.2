import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';
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
//  REFER FRIENDS SCREEN
// ═══════════════════════════════════════════════════════════════

class ReferFriendsScreen extends StatelessWidget {
  const ReferFriendsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return _InfoPageShell(
      title: S.of(context).referFriends,
      icon: Icons.person_add_rounded,
      iconColor: const Color(0xFF4CAF50),
      children: [
        // Coming Soon banner
        Container(
          margin: const EdgeInsets.only(bottom: 16),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            color: const Color(0xFFE8C547).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: const Color(0xFFE8C547).withValues(alpha: 0.4),
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(
                Icons.access_time_rounded,
                color: Color(0xFFE8C547),
                size: 18,
              ),
              const SizedBox(width: 8),
              Text(
                S.of(context).comingSoon,
                style: const TextStyle(
                  color: Color(0xFFE8C547),
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF1C1C1E), Color(0xFF2A2A2E)],
            ),
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              Text(
                S.of(context).referEarn200,
                style: const TextStyle(
                  color: Color(0xFFE8C547),
                  fontSize: 36,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                S.of(context).referFriendsSubtitle,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.6),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton.icon(
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    Share.share(S.of(context).referDriverShareText);
                  },
                  icon: const Icon(Icons.share_rounded),
                  label: Text(
                    S.of(context).shareInviteLinkBtn,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFE8C547),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _card(
          S.of(context).howItWorksTitle,
          S.of(context).howItWorksDesc,
          icon: Icons.info_outline_rounded,
        ),
        _card(
          S.of(context).noLimitTitle,
          S.of(context).noLimitDesc,
          icon: Icons.all_inclusive_rounded,
        ),
      ],
    );
  }
}

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
              colors: [Color(0xFF2D2D2D), Color(0xFF1A1A1A)],
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
                      HapticFeedback.selectionClick();
                      Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => _LearningTopicScreen(topic: topic),
                        ),
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
                              borderRadius: BorderRadius.circular(12),
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
//  3 swipeable pages + animated "Let's Go" button
// ═══════════════════════════════════════════════════════════════

class NewDriverInstructionsScreen extends StatefulWidget {
  const NewDriverInstructionsScreen({super.key});

  @override
  State<NewDriverInstructionsScreen> createState() =>
      _NewDriverInstructionsScreenState();
}

class _NewDriverInstructionsScreenState
    extends State<NewDriverInstructionsScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);
  static const _bg = Color(0xFF0A0A0A);

  final _pageCtrl = PageController();
  int _currentPage = 0;
  bool _viewedAllPages = false;

  late final AnimationController _buttonCtrl;
  late final Animation<double> _buttonSlide;
  late final Animation<double> _buttonFade;

  late final AnimationController _iconPulseCtrl;

  @override
  void initState() {
    super.initState();

    _buttonCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _buttonSlide = Tween<double>(begin: 60, end: 0).animate(
      CurvedAnimation(parent: _buttonCtrl, curve: Curves.easeOutBack),
    );
    _buttonFade = Tween<double>(begin: 0, end: 1).animate(
      CurvedAnimation(parent: _buttonCtrl, curve: Curves.easeIn),
    );

    _iconPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _buttonCtrl.dispose();
    _iconPulseCtrl.dispose();
    super.dispose();
  }

  void _onPageChanged(int page) {
    setState(() => _currentPage = page);
    if (page == 2 && !_viewedAllPages) {
      _viewedAllPages = true;
      _buttonCtrl.forward();
    }
  }

  @override
  Widget build(BuildContext context) {
    final pages = _buildPages();

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
                  // App logo
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.12),
                      shape: BoxShape.circle,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Image.asset(
                        'assets/images/logoapp.png',
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  const Text(
                    'Welcome New Cruise Driver',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
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
                    color: isActive ? _gold : Colors.white.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                );
              }),
            ),
            const SizedBox(height: 16),

            // ── Swipeable pages ──
            Expanded(
              child: PageView.builder(
                controller: _pageCtrl,
                onPageChanged: _onPageChanged,
                itemCount: 3,
                physics: const BouncingScrollPhysics(),
                itemBuilder: (context, index) => pages[index],
              ),
            ),

            // ── Animated "Let's Go" button ──
            AnimatedBuilder(
              animation: _buttonCtrl,
              builder: (context, child) {
                return Transform.translate(
                  offset: Offset(0, _buttonSlide.value),
                  child: Opacity(
                    opacity: _buttonFade.value,
                    child: child,
                  ),
                );
              },
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
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
                      onPressed: _viewedAllPages
                          ? () {
                              HapticFeedback.mediumImpact();
                              Navigator.of(context).pushAndRemoveUntil(
                                slideFromRightRoute(
                                    const DriverProfilePhotoScreen()),
                                (_) => false,
                              );
                            }
                          : null,
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
            ),

            // Swipe hint when button is not yet visible
            if (!_viewedAllPages)
              Padding(
                padding: const EdgeInsets.only(bottom: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(
                      Icons.swipe_rounded,
                      color: Colors.white.withValues(alpha: 0.3),
                      size: 18,
                    ),
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

  List<Widget> _buildPages() {
    return [
      // ── Page 1: Vehicle & Presentation ──
      _buildPage(
        icon: Icons.auto_awesome_rounded,
        iconColor: const Color(0xFF2196F3),
        title: 'Keep Your Vehicle Spotless',
        subtitle: 'First impressions matter',
        items: [
          _InstructionItem(
            icon: Icons.cleaning_services_rounded,
            color: const Color(0xFF2196F3),
            title: 'Clean Inside & Out',
            body:
                'Wash your car regularly. Vacuum seats and floor mats. A clean vehicle earns higher ratings and better tips.',
          ),
          _InstructionItem(
            icon: Icons.air_rounded,
            color: const Color(0xFF00BCD4),
            title: 'Fresh & Comfortable',
            body:
                'Keep the cabin smelling fresh. Maintain a comfortable temperature. Have water bottles available for riders.',
          ),
          _InstructionItem(
            icon: Icons.phone_android_rounded,
            color: const Color(0xFF9C27B0),
            title: 'Phone Mount & Charger',
            body:
                'Use a secure phone mount for navigation. Offer a charging cable for riders. Keep your phone charged at all times.',
          ),
          _InstructionItem(
            icon: Icons.checkroom_rounded,
            color: const Color(0xFF4CAF50),
            title: 'Professional Appearance',
            body:
                'Dress neatly and present yourself professionally. You represent the Cruise brand with every ride.',
          ),
        ],
      ),

      // ── Page 2: Safe Driving ──
      _buildPage(
        icon: Icons.shield_rounded,
        iconColor: const Color(0xFF4CAF50),
        title: 'Drive Safe, Always',
        subtitle: 'Safety is your #1 priority',
        items: [
          _InstructionItem(
            icon: Icons.speed_rounded,
            color: const Color(0xFF4CAF50),
            title: 'Obey Traffic Laws',
            body:
                'Follow speed limits, stop at red lights, and use turn signals. No exceptions. A safe driver is a successful driver.',
          ),
          _InstructionItem(
            icon: Icons.no_drinks_rounded,
            color: const Color(0xFFE53935),
            title: 'Zero Tolerance Policy',
            body:
                'Never drive under the influence of alcohol or drugs. If you feel drowsy or unwell, go offline immediately.',
          ),
          _InstructionItem(
            icon: Icons.remove_red_eye_rounded,
            color: const Color(0xFFFF9800),
            title: 'Stay Focused',
            body:
                'No texting while driving. Set your navigation before starting the trip. Keep your eyes on the road at all times.',
          ),
          _InstructionItem(
            icon: Icons.airline_seat_recline_normal_rounded,
            color: const Color(0xFF2196F3),
            title: 'Seatbelt Required',
            body:
                'Ensure all passengers have their seatbelts fastened before starting the ride. Safety first, every trip.',
          ),
        ],
      ),

      // ── Page 3: Customer Service ──
      _buildPage(
        icon: Icons.favorite_rounded,
        iconColor: const Color(0xFFE8C547),
        title: 'Deliver 5-Star Service',
        subtitle: 'Make every ride memorable',
        items: [
          _InstructionItem(
            icon: Icons.emoji_people_rounded,
            color: const Color(0xFFE8C547),
            title: 'Greet Every Rider',
            body:
                'Welcome riders by name. A simple "Hello!" and a smile goes a long way. Confirm their destination before starting.',
          ),
          _InstructionItem(
            icon: Icons.route_rounded,
            color: const Color(0xFF4CAF50),
            title: 'Efficient Routes',
            body:
                'Follow the GPS navigation. If you know a faster route, ask the rider first. Respect their time and preferences.',
          ),
          _InstructionItem(
            icon: Icons.music_note_rounded,
            color: const Color(0xFF9C27B0),
            title: 'Respect Rider Preferences',
            body:
                'Keep music at a low volume or ask the rider. Some prefer conversation, others prefer quiet. Read the room.',
          ),
          _InstructionItem(
            icon: Icons.star_rounded,
            color: const Color(0xFFFF9800),
            title: 'Go the Extra Mile',
            body:
                'Help with luggage, open the door, offer a smooth ride. Small gestures lead to 5-star ratings and repeat riders.',
          ),
        ],
      ),
    ];
  }

  Widget _buildPage({
    required IconData icon,
    required Color iconColor,
    required String title,
    required String subtitle,
    required List<_InstructionItem> items,
  }) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        const SizedBox(height: 8),
        // Animated icon
        Center(
          child: AnimatedBuilder(
            animation: _iconPulseCtrl,
            builder: (_, child) {
              final scale = 1.0 + _iconPulseCtrl.value * 0.08;
              return Transform.scale(scale: scale, child: child);
            },
            child: Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                boxShadow: [
                  BoxShadow(
                    color: iconColor.withValues(alpha: 0.2),
                    blurRadius: 24,
                    spreadRadius: 2,
                  ),
                ],
              ),
              child: Icon(icon, color: iconColor, size: 40),
            ),
          ),
        ),
        const SizedBox(height: 20),
        Center(
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
        ),
        const SizedBox(height: 6),
        Center(
          child: Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 14,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(height: 24),
        ...items.map((item) => _buildInstructionCard(item)),
        const SizedBox(height: 16),
      ],
    );
  }

  Widget _buildInstructionCard(_InstructionItem item) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF1C1C1E),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: item.color.withValues(alpha: 0.12),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: item.color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Icon(item.icon, color: item.color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  item.body,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: 13,
                    height: 1.45,
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
                          HapticFeedback.mediumImpact();
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
              launchUrl(Uri.parse('https://cruiseride.com/driver-safety')),
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
