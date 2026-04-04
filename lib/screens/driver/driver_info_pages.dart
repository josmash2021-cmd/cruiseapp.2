import 'dart:math' as math;
import 'dart:ui' as ui;
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
//  3 swipeable pages with animated scene illustrations
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

  // Scene animation — drives all animated illustrations
  late final AnimationController _sceneCtrl;

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

    _sceneCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    )..repeat();
  }

  @override
  void dispose() {
    _pageCtrl.dispose();
    _buttonCtrl.dispose();
    _sceneCtrl.dispose();
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

            // ── Swipeable pages ──
            Expanded(
              child: PageView(
                controller: _pageCtrl,
                onPageChanged: _onPageChanged,
                physics: const _SmoothPagePhysics(),
                children: [
                  _buildPage(
                    scene: _SceneType.vehicle,
                    title: 'Keep Your Vehicle Spotless',
                    subtitle: 'First impressions matter',
                    items: const [
                      _InstructionItem(
                        icon: Icons.local_car_wash_rounded,
                        color: Color(0xFF2196F3),
                        title: 'Clean Inside & Out',
                        body:
                            'Wash your car regularly. Vacuum seats and floor mats. A clean vehicle earns higher ratings.',
                      ),
                      _InstructionItem(
                        icon: Icons.ac_unit_rounded,
                        color: Color(0xFF00BCD4),
                        title: 'Fresh & Comfortable',
                        body:
                            'Keep the cabin fresh. Maintain a comfortable temperature. Offer water bottles for riders.',
                      ),
                      _InstructionItem(
                        icon: Icons.phone_android_rounded,
                        color: Color(0xFF9C27B0),
                        title: 'Phone Mount & Charger',
                        body:
                            'Use a secure phone mount for navigation. Offer a charging cable. Keep your phone charged.',
                      ),
                      _InstructionItem(
                        icon: Icons.dry_cleaning_rounded,
                        color: Color(0xFF4CAF50),
                        title: 'Professional Appearance',
                        body:
                            'Dress neatly and present yourself professionally. You represent Cruise with every ride.',
                      ),
                    ],
                  ),
                  _buildPage(
                    scene: _SceneType.safety,
                    title: 'Drive Safe, Always',
                    subtitle: 'Safety is your #1 priority',
                    items: const [
                      _InstructionItem(
                        icon: Icons.speed_rounded,
                        color: Color(0xFF4CAF50),
                        title: 'Obey Traffic Laws',
                        body:
                            'Follow speed limits, stop at red lights, use turn signals. No exceptions.',
                      ),
                      _InstructionItem(
                        icon: Icons.no_drinks_rounded,
                        color: Color(0xFFE53935),
                        title: 'Zero Tolerance Policy',
                        body:
                            'Never drive under the influence. If you feel drowsy or unwell, go offline immediately.',
                      ),
                      _InstructionItem(
                        icon: Icons.visibility_rounded,
                        color: Color(0xFFFF9800),
                        title: 'Stay Focused',
                        body:
                            'No texting while driving. Set navigation before starting. Eyes on the road at all times.',
                      ),
                      _InstructionItem(
                        icon: Icons.health_and_safety_rounded,
                        color: Color(0xFF2196F3),
                        title: 'Seatbelt Required',
                        body:
                            'Ensure all passengers have seatbelts fastened before starting. Safety first, every trip.',
                      ),
                    ],
                  ),
                  _buildPage(
                    scene: _SceneType.service,
                    title: 'Deliver 5-Star Service',
                    subtitle: 'Make every ride memorable',
                    items: const [
                      _InstructionItem(
                        icon: Icons.waving_hand_rounded,
                        color: Color(0xFFE8C547),
                        title: 'Greet Every Rider',
                        body:
                            'Welcome riders by name. A simple greeting goes a long way. Confirm their destination.',
                      ),
                      _InstructionItem(
                        icon: Icons.route_rounded,
                        color: Color(0xFF4CAF50),
                        title: 'Efficient Routes',
                        body:
                            'Follow GPS navigation. If you know a faster route, ask the rider first.',
                      ),
                      _InstructionItem(
                        icon: Icons.tune_rounded,
                        color: Color(0xFF9C27B0),
                        title: 'Respect Preferences',
                        body:
                            'Keep music low or ask the rider. Some prefer conversation, others quiet. Read the room.',
                      ),
                      _InstructionItem(
                        icon: Icons.star_rounded,
                        color: Color(0xFFFF9800),
                        title: 'Go the Extra Mile',
                        body:
                            'Help with luggage, open the door. Small gestures lead to 5-star ratings.',
                      ),
                    ],
                  ),
                ],
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

  Widget _buildPage({
    required _SceneType scene,
    required String title,
    required String subtitle,
    required List<_InstructionItem> items,
  }) {
    return ListView(
      physics: const BouncingScrollPhysics(),
      padding: const EdgeInsets.symmetric(horizontal: 20),
      children: [
        const SizedBox(height: 4),
        // ── Animated scene illustration ──
        SizedBox(
          height: 140,
          child: AnimatedBuilder(
            animation: _sceneCtrl,
            builder: (_, __) => CustomPaint(
              size: const Size(double.infinity, 140),
              painter: _InstructionScenePainter(
                scene: scene,
                progress: _sceneCtrl.value,
              ),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Center(
          child: Text(
            title,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w900,
              letterSpacing: -0.5,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Center(
          child: Text(
            subtitle,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
        ),
        const SizedBox(height: 16),
        ...items.map((item) => _buildInstructionCard(item)),
        const SizedBox(height: 8),
      ],
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

// ── Scene types ──
enum _SceneType { vehicle, safety, service }

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

// Smooth snappy page physics — no bounce, crisp deceleration
class _SmoothPagePhysics extends ScrollPhysics {
  const _SmoothPagePhysics({super.parent});
  @override
  _SmoothPagePhysics applyTo(ScrollPhysics? ancestor) =>
      _SmoothPagePhysics(parent: buildParent(ancestor));
  @override
  SpringDescription get spring => const SpringDescription(mass: 80, stiffness: 100, damping: 1);
}

// ═══════════════════════════════════════════════════════════════
//  Animated Scene Painter — premium 3D-style illustrations
//  with gradients, shadows, depth, and fluid motion
// ═══════════════════════════════════════════════════════════════

class _InstructionScenePainter extends CustomPainter {
  final _SceneType scene;
  final double progress; // 0.0 → 1.0, repeats

  static const _gold = Color(0xFFE8C547);
  static const _goldDim = Color(0xFFB08C35);
  static const _blue = Color(0xFF2196F3);
  static const _blueDark = Color(0xFF1565C0);
  static const _green = Color(0xFF4CAF50);
  static const _greenDark = Color(0xFF2E7D32);

  _InstructionScenePainter({required this.scene, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    switch (scene) {
      case _SceneType.vehicle:
        _paintVehicleScene(canvas, size);
      case _SceneType.safety:
        _paintSafetyScene(canvas, size);
      case _SceneType.service:
        _paintServiceScene(canvas, size);
    }
  }

  // ─────────────────────────────────────────
  //  Scene 1 — Vehicle Cleaning
  // ─────────────────────────────────────────
  void _paintVehicleScene(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.52;

    // Ground reflection
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 42), width: 180, height: 14),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(cx, cy + 42), 90,
          [Colors.white.withValues(alpha: 0.04), Colors.transparent],
        ),
    );

    // ── 3D Car ──
    _draw3DCar(canvas, cx, cy, _blue, scale: 1.3);

    // ── Person (right side) ──
    final pX = cx + 85;
    final pY = cy - 6;
    _draw3DPerson(canvas, pX, pY, _blue, armAngle: math.sin(progress * math.pi * 2) * 0.35);

    // ── Animated sponge on car ──
    final spongeX = cx + 12 + math.sin(progress * math.pi * 2) * 30;
    final spongeY = cy - 26;
    // Sponge shadow
    canvas.drawOval(
      Rect.fromCenter(center: Offset(spongeX, spongeY + 6), width: 16, height: 4),
      Paint()..color = Colors.black.withValues(alpha: 0.15),
    );
    // Sponge body with gradient
    final spongeRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset(spongeX, spongeY), width: 16, height: 11),
      const Radius.circular(4),
    );
    canvas.drawRRect(spongeRect, Paint()
      ..shader = ui.Gradient.linear(
        Offset(spongeX - 8, spongeY - 5),
        Offset(spongeX + 8, spongeY + 5),
        [_blue.withValues(alpha: 0.8), _blueDark.withValues(alpha: 0.6)],
      ));

    // ── Sparkle particles ──
    for (int i = 0; i < 6; i++) {
      final angle = progress * math.pi * 2 + i * 1.05;
      final r = 14.0 + i * 3.5;
      final sparkAlpha = (0.6 + 0.4 * math.sin(progress * math.pi * 4 + i)).clamp(0.0, 1.0);
      final sx = spongeX + math.cos(angle) * r;
      final sy = spongeY + math.sin(angle) * r * 0.6;
      // Glow
      canvas.drawCircle(Offset(sx, sy), 3,
        Paint()..color = _blue.withValues(alpha: 0.08 * sparkAlpha)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));
      // Dot
      canvas.drawCircle(Offset(sx, sy), 1.2,
        Paint()..color = Colors.white.withValues(alpha: 0.5 * sparkAlpha));
    }

    // ── Water bucket (left) ──
    final bx = cx - 72;
    final by = cy + 12;
    _drawBucket(canvas, bx, by, _blue);
  }

  // ─────────────────────────────────────────
  //  Scene 2 — Safety / Traffic
  // ─────────────────────────────────────────
  void _paintSafetyScene(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.52;

    // ── Road with perspective ──
    final roadGrad = Paint()
      ..shader = ui.Gradient.linear(
        Offset(0, cy + 16), Offset(0, cy + 46),
        [const Color(0xFF1E1E22), const Color(0xFF141417)],
      );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(20, cy + 16, size.width - 40, 30),
        const Radius.circular(3),
      ),
      roadGrad,
    );
    // Animated dashes
    final dashOffset = (progress * 30) % 30;
    final dashP = Paint()
      ..color = Colors.white.withValues(alpha: 0.18)
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    for (double x = 30 - dashOffset; x < size.width - 30; x += 30) {
      canvas.drawLine(Offset(x, cy + 31), Offset(x + 12, cy + 31), dashP);
    }

    // ── Car driving ──
    final carBob = math.sin(progress * math.pi * 4) * 1.5;
    _draw3DCar(canvas, cx - 15, cy + 6 + carBob, _green, scale: 1.0);

    // ── Shield (center-left, above car) ──
    final sx = cx - 10;
    final sy = cy - 42;
    final pulse = 0.96 + 0.04 * math.sin(progress * math.pi * 2);
    canvas.save();
    canvas.translate(sx, sy);
    canvas.scale(pulse);

    // Shield glow
    canvas.drawCircle(Offset.zero, 28, Paint()
      ..color = _green.withValues(alpha: 0.06)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12));

    // Shield body
    final shieldPath = Path()
      ..moveTo(0, -22)
      ..lineTo(18, -13)
      ..lineTo(18, 4)
      ..quadraticBezierTo(18, 18, 0, 25)
      ..quadraticBezierTo(-18, 18, -18, 4)
      ..lineTo(-18, -13)
      ..close();
    canvas.drawPath(shieldPath, Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, -22), const Offset(0, 25),
        [_green.withValues(alpha: 0.20), _greenDark.withValues(alpha: 0.08)],
      ));
    canvas.drawPath(shieldPath, Paint()
      ..color = _green.withValues(alpha: 0.6)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0
      ..strokeJoin = StrokeJoin.round);

    // Checkmark
    final checkP = Paint()
      ..color = _green
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.8
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    canvas.drawPath(Path()
      ..moveTo(-7, 2)..lineTo(-2, 8)..lineTo(9, -5), checkP);
    canvas.restore();

    // ── Traffic light (right) ──
    _drawTrafficLight(canvas, cx + 75, cy - 18, progress);

    // ── Pedestrian (far left) ──
    _draw3DPerson(canvas, cx - 82, cy + 4, _green, armAngle: 0.15, scale: 0.85);
  }

  // ─────────────────────────────────────────
  //  Scene 3 — 5-Star Service
  // ─────────────────────────────────────────
  void _paintServiceScene(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height * 0.52;

    // Ground glow
    canvas.drawOval(
      Rect.fromCenter(center: Offset(cx, cy + 42), width: 200, height: 14),
      Paint()
        ..shader = ui.Gradient.radial(
          Offset(cx, cy + 42), 100,
          [_gold.withValues(alpha: 0.04), Colors.transparent],
        ),
    );

    // ── Car ──
    _draw3DCar(canvas, cx, cy + 10, _gold, scale: 1.1);

    // ── Driver (left, waving) ──
    final wave = 0.3 + 0.5 * math.sin(progress * math.pi * 2);
    _draw3DPerson(canvas, cx - 58, cy - 2, _gold, armAngle: wave);

    // ── Rider (right, with luggage) ──
    _draw3DPerson(canvas, cx + 62, cy - 2, const Color(0xFF9C27B0), armAngle: -0.1);
    // Luggage
    final lugRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx + 74, cy + 16, 12, 18),
      const Radius.circular(3),
    );
    canvas.drawRRect(lugRect, Paint()
      ..shader = ui.Gradient.linear(
        Offset(cx + 74, cy + 16), Offset(cx + 86, cy + 34),
        [const Color(0xFF9C27B0).withValues(alpha: 0.35), const Color(0xFF7B1FA2).withValues(alpha: 0.2)],
      ));
    canvas.drawLine(Offset(cx + 78, cy + 16), Offset(cx + 78, cy + 11),
      Paint()..color = const Color(0xFF9C27B0).withValues(alpha: 0.45)..strokeWidth = 2..strokeCap = StrokeCap.round);

    // ── 5 Stars (cascading glow animation) ──
    for (int i = 0; i < 5; i++) {
      final delay = i * 0.12;
      final t = ((progress - delay) % 1.0).clamp(0.0, 1.0);
      final pulse = math.sin(t * math.pi);
      final starAlpha = (0.35 + 0.65 * pulse).clamp(0.0, 1.0);
      final starY = cy - 48 - pulse * 5;
      final starX = cx - 38 + i * 19.0;
      // Star glow
      canvas.drawCircle(Offset(starX, starY), 8,
        Paint()..color = _gold.withValues(alpha: 0.06 * pulse)
              ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      _drawStar(canvas, starX, starY, 7.0, _gold.withValues(alpha: starAlpha));
    }

    // ── Speech bubble ──
    final bAlpha = (0.5 + 0.5 * math.sin(progress * math.pi * 2)).clamp(0.0, 1.0);
    final bRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(cx - 88, cy - 40, 44, 20),
      const Radius.circular(10),
    );
    canvas.drawRRect(bRect, Paint()
      ..color = _gold.withValues(alpha: 0.10 * bAlpha));
    canvas.drawRRect(bRect, Paint()
      ..color = _gold.withValues(alpha: 0.25 * bAlpha)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1);
    // Tail
    canvas.drawPath(Path()
      ..moveTo(cx - 62, cy - 20)..lineTo(cx - 56, cy - 16)..lineTo(cx - 68, cy - 20)..close(),
      Paint()..color = _gold.withValues(alpha: 0.10 * bAlpha));

    final tp = TextPainter(
      text: TextSpan(
        text: 'Hello!',
        style: TextStyle(
          color: _gold.withValues(alpha: 0.7 * bAlpha),
          fontSize: 10,
          fontWeight: FontWeight.w800,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset(cx - 80, cy - 36));
  }

  // ═════════════════════════════════════════
  //  Premium helpers
  // ═════════════════════════════════════════

  /// 3D-style car with gradients, reflections, and depth
  void _draw3DCar(Canvas canvas, double x, double y, Color accent, {double scale = 1.0}) {
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(scale);

    // Shadow
    canvas.drawOval(
      Rect.fromCenter(center: const Offset(0, 24), width: 80, height: 10),
      Paint()..color = Colors.black.withValues(alpha: 0.20)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );

    // Body
    final bodyRect = RRect.fromRectAndRadius(
      Rect.fromCenter(center: Offset.zero, width: 76, height: 26),
      const Radius.circular(7),
    );
    canvas.drawRRect(bodyRect, Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, -13), const Offset(0, 13),
        [const Color(0xFF3A3A40), const Color(0xFF222226)],
      ));
    // Body highlight
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(center: const Offset(0, -6), width: 70, height: 6),
        const Radius.circular(3),
      ),
      Paint()..color = Colors.white.withValues(alpha: 0.04),
    );

    // Roof
    final roof = Path()
      ..moveTo(-20, -13)
      ..lineTo(-12, -28)
      ..lineTo(12, -28)
      ..lineTo(20, -13)
      ..close();
    canvas.drawPath(roof, Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, -28), const Offset(0, -13),
        [const Color(0xFF444448), const Color(0xFF2E2E32)],
      ));

    // Windshield
    final wsPath = Path()
      ..moveTo(-11, -27)..lineTo(-4, -14)..lineTo(4, -14)..lineTo(11, -27)..close();
    canvas.drawPath(wsPath, Paint()
      ..shader = ui.Gradient.linear(
        const Offset(0, -27), const Offset(0, -14),
        [accent.withValues(alpha: 0.18), accent.withValues(alpha: 0.06)],
      ));

    // Wheels
    for (final wx in [-22.0, 22.0]) {
      // Tire
      canvas.drawCircle(Offset(wx, 13), 8, Paint()
        ..shader = ui.Gradient.radial(
          Offset(wx - 2, 11), 8,
          [const Color(0xFF3A3A3E), const Color(0xFF1A1A1E)],
        ));
      // Hub
      canvas.drawCircle(Offset(wx, 13), 3.5, Paint()
        ..shader = ui.Gradient.radial(
          Offset(wx - 1, 12), 3.5,
          [const Color(0xFF666668), const Color(0xFF444446)],
        ));
    }

    // Headlights
    canvas.drawCircle(const Offset(36, -2), 3, Paint()
      ..color = accent.withValues(alpha: 0.5));
    canvas.drawCircle(const Offset(36, -2), 6, Paint()
      ..color = accent.withValues(alpha: 0.08)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4));
    // Taillights
    canvas.drawCircle(const Offset(-36, -2), 3, Paint()
      ..color = const Color(0xFFE53935).withValues(alpha: 0.4));
    canvas.drawCircle(const Offset(-36, -2), 5, Paint()
      ..color = const Color(0xFFE53935).withValues(alpha: 0.06)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3));

    canvas.restore();
  }

  /// 3D-style person with filled body, gradient head, and natural proportions
  void _draw3DPerson(Canvas canvas, double x, double y, Color color,
      {double armAngle = 0.0, double scale = 1.0}) {
    canvas.save();
    canvas.translate(x, y);
    canvas.scale(scale);

    final bodyP = Paint()
      ..color = color.withValues(alpha: 0.65)
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round
      ..style = PaintingStyle.stroke;

    // Head with gradient
    canvas.drawCircle(const Offset(0, -18), 8, Paint()
      ..shader = ui.Gradient.radial(
        const Offset(-2, -20), 8,
        [color.withValues(alpha: 0.6), color.withValues(alpha: 0.3)],
      ));
    // Head highlight
    canvas.drawCircle(const Offset(-2, -21), 3, Paint()
      ..color = Colors.white.withValues(alpha: 0.08));

    // Body
    canvas.drawLine(const Offset(0, -10), const Offset(0, 12), bodyP);
    // Left arm
    final la = Offset(-14 * math.cos(armAngle), -2 + 14 * math.sin(armAngle));
    canvas.drawLine(const Offset(0, -5), la, bodyP);
    // Right arm
    final ra = Offset(14 * math.cos(armAngle), -2 - 14 * math.sin(armAngle));
    canvas.drawLine(const Offset(0, -5), ra, bodyP);
    // Legs
    canvas.drawLine(const Offset(0, 12), const Offset(-9, 28), bodyP);
    canvas.drawLine(const Offset(0, 12), const Offset(9, 28), bodyP);

    canvas.restore();
  }

  /// Traffic light with glow effects
  void _drawTrafficLight(Canvas canvas, double x, double y, double t) {
    // Pole
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromLTWH(x - 2.5, y - 8, 5, 52),
        const Radius.circular(2),
      ),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(x - 2.5, y), Offset(x + 2.5, y),
          [const Color(0xFF444448), const Color(0xFF2A2A2E)],
        ),
    );
    // Housing
    final housing = RRect.fromRectAndRadius(
      Rect.fromLTWH(x - 12, y - 42, 24, 44),
      const Radius.circular(5),
    );
    canvas.drawRRect(housing, Paint()
      ..shader = ui.Gradient.linear(
        Offset(x - 12, y - 42), Offset(x + 12, y + 2),
        [const Color(0xFF333338), const Color(0xFF1E1E22)],
      ));
    canvas.drawRRect(housing, Paint()
      ..color = Colors.white.withValues(alpha: 0.06)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5);

    // Smooth phase transition (not abrupt)
    final phase = (t * 3) % 3;
    final colors = [
      const Color(0xFFE53935), const Color(0xFFFFB300), _green,
    ];
    final offColors = [
      const Color(0xFF3A1010), const Color(0xFF3A3010), const Color(0xFF103A10),
    ];
    final positions = [y - 30, y - 18, y - 6];

    for (int i = 0; i < 3; i++) {
      final isActive = phase.floor() == i;
      final c = isActive ? colors[i] : offColors[i];
      final cy = positions[i];
      // Glow behind active light
      if (isActive) {
        canvas.drawCircle(Offset(x, cy), 10, Paint()
          ..color = c.withValues(alpha: 0.15)
          ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6));
      }
      // Light
      canvas.drawCircle(Offset(x, cy), 5.5, Paint()
        ..shader = ui.Gradient.radial(
          Offset(x - 1, cy - 1), 5.5,
          [c, c.withValues(alpha: isActive ? 0.6 : 0.3)],
        ));
    }
  }

  /// Water bucket with 3D shading
  void _drawBucket(Canvas canvas, double x, double y, Color color) {
    final bucketPath = Path()
      ..moveTo(x - 12, y - 8)
      ..lineTo(x - 8, y + 10)
      ..lineTo(x + 8, y + 10)
      ..lineTo(x + 12, y - 8)
      ..close();
    canvas.drawPath(bucketPath, Paint()
      ..shader = ui.Gradient.linear(
        Offset(x - 12, y - 8), Offset(x + 12, y + 10),
        [color.withValues(alpha: 0.25), color.withValues(alpha: 0.10)],
      ));
    canvas.drawPath(bucketPath, Paint()
      ..color = color.withValues(alpha: 0.4)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeJoin = StrokeJoin.round);
    // Water surface
    canvas.drawLine(
      Offset(x - 10, y - 4), Offset(x + 10, y - 4),
      Paint()..color = color.withValues(alpha: 0.25)..strokeWidth = 1.5..strokeCap = StrokeCap.round,
    );
    // Handle
    final handlePath = Path()
      ..moveTo(x - 8, y - 8)
      ..quadraticBezierTo(x, y - 18, x + 8, y - 8);
    canvas.drawPath(handlePath, Paint()
      ..color = color.withValues(alpha: 0.35)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round);
  }

  /// 5-pointed star with proper inner/outer radii
  void _drawStar(Canvas canvas, double x, double y, double r, Color color) {
    final path = Path();
    final innerR = r * 0.4;
    for (int i = 0; i < 10; i++) {
      final angle = -math.pi / 2 + i * math.pi / 5;
      final radius = i.isEven ? r : innerR;
      final px = x + radius * math.cos(angle);
      final py = y + radius * math.sin(angle);
      if (i == 0) {
        path.moveTo(px, py);
      } else {
        path.lineTo(px, py);
      }
    }
    path.close();
    canvas.drawPath(path, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_InstructionScenePainter old) =>
      old.progress != progress || old.scene != scene;
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
