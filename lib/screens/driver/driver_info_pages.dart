import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../l10n/app_localizations.dart';
import '../../config/page_transitions.dart';
import '../../widgets/neu_style.dart';

// ═══════════════════════════════════════════════════════════════
//  Reusable dark-themed info page shell
// ═══════════════════════════════════════════════════════════════

class _InfoPageShell extends StatelessWidget {
  final String title;
  final IconData icon;
  final Color iconColor;
  final List<Widget> children;
  final String? heroImage;

  const _InfoPageShell({
    required this.title,
    required this.icon,
    this.iconColor = const Color(0xFFE8C547),
    this.heroImage,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: neuBase,
      // Same dotted backdrop as the driver menu these pages open from —
      // on a flat neuBase the cards float on nothing.
      body: Stack(
        children: [
          const Positioned.fill(child: NeuDotsBackdrop()),
          SafeArea(
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
                        decoration: neuBox(radius: 20),
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
                  // The page's icon sits in a sunken well rather than a
                  // tinted disc — the same treatment icons get everywhere
                  // else in the neu system.
                  Center(
                    child: Container(
                      width: 64,
                      height: 64,
                      decoration: neuBox(radius: 32, pressed: true),
                      child: Icon(icon, color: iconColor, size: 30),
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (heroImage != null) ...[
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Image.asset(
                        heroImage!,
                        width: double.infinity,
                        height: 180,
                        fit: BoxFit.cover,
                        errorBuilder: (context, error, stackTrace) => const SizedBox.shrink(),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                  ...children,
                  const SizedBox(height: 40),
                ],
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

Widget _card(String title, String body, {IconData? icon}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(16),
    decoration: neuBox(radius: 18),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Container(
            width: 38,
            height: 38,
            decoration: neuBox(radius: 12, pressed: true),
            child: Icon(icon, color: const Color(0xFFE8C547), size: 19),
          ),
          const SizedBox(width: 13),
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

Widget _comingSoonCard(BuildContext context, String title, String body,
    {IconData? icon}) {
  return Container(
    margin: const EdgeInsets.only(bottom: 14),
    padding: const EdgeInsets.all(16),
    // Same card, one step quieter: a card that is not tappable yet should
    // not sit as proud as the ones that are.
    decoration: neuBox(
      radius: 18,
      borderColor: const Color(0xFFE8C547).withValues(alpha: 0.15),
    ),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (icon != null) ...[
          Container(
            width: 38,
            height: 38,
            decoration: neuBox(radius: 12, pressed: true),
            child: Icon(
              icon,
              color: const Color(0xFFE8C547).withValues(alpha: 0.4),
              size: 19,
            ),
          ),
          const SizedBox(width: 13),
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
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
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
        // What a driver can do today first, what is still coming after.
        // The two live services were split by the two placeholders, so the
        // list read as if half of it were unavailable.
        _card(
          S.of(context).rideServicesTitle,
          S.of(context).rideServicesDesc,
          icon: Icons.local_taxi_rounded,
        ),
        _card(
          S.of(context).scheduledRidesWorkHubTitle,
          S.of(context).scheduledRidesWorkHubDesc,
          icon: Icons.schedule_rounded,
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
      heroImage: 'assets/images/tax_hero.png',
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
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
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
                            child:
                                Icon(topic.icon, color: topic.color, size: 22),
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
