import 'dart:async';
import 'dart:math';
import '../services/ai_support_service.dart';
import '../config/agent_prompts.dart';
import '../widgets/typing_indicator.dart';
import '../widgets/queue_status_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/user_session.dart';
import '../widgets/gold_particles_background.dart';

/// Fully functional Help & Support screen with topic detail pages,
/// search, FAQs, and contact options.
class HelpScreen extends StatefulWidget {
  const HelpScreen({super.key});

  @override
  State<HelpScreen> createState() => _HelpScreenState();
}

class _HelpScreenState extends State<HelpScreen> {
  static const _gold = Color(0xFFE8C547);

  final _searchCtrl = TextEditingController();
  String _query = '';

  List<_HelpCategory> _categories() => [
    _HelpCategory(
      title: 'Trips & Fare',
      icon: Icons.directions_car_rounded,
      items: [
        _HelpTopic(
          icon: Icons.receipt_long_rounded,
          title: 'I was charged incorrectly',
          answer:
              'If you believe your fare was incorrect, please review the trip receipt in your ride history. Common reasons for fare differences include route changes, tolls, surge pricing, or wait-time charges.\n\n'
              'Steps to dispute:\n'
              '1. Go to Account → Trips\n'
              '2. Select the trip in question\n'
              '3. Review the fare breakdown\n\n'
              'If the charge still seems wrong, contact our support team using the button below and include your trip date and the amount charged.',
        ),
        _HelpTopic(
          icon: Icons.search_rounded,
          title: 'I lost an item',
          answer:
              'If you left something in your ride, don\'t worry — we can help.\n\n'
              '1. Check your trip history to find the ride details\n'
              '2. Note the driver\'s name, date, and time\n'
              '3. Contact support with these details\n\n'
              'We\'ll reach out to the driver on your behalf. Most items are recovered within 24 hours. A small return fee may apply for item delivery.',
        ),
        _HelpTopic(
          icon: Icons.cancel_outlined,
          title: 'Dispute a cancellation fee',
          answer:
              'Cancellation fees are charged when a ride is cancelled after the driver has already started heading to the pickup location, or if the driver waited at the pickup for more than 5 minutes.\n\n'
              'You may qualify for a refund if:\n'
              '• The driver cancelled, not you\n'
              '• The driver was significantly delayed\n'
              '• There was a safety concern\n\n'
              'Contact support with your trip details for a review.',
        ),
        _HelpTopic(
          icon: Icons.access_time_rounded,
          title: 'My trip didn\'t happen',
          answer: S.of(context).tripDidntHappenAnswer,
        ),
      ],
    ),
    _HelpCategory(
      title: 'Account & Payment',
      icon: Icons.account_balance_wallet_rounded,
      items: [
        _HelpTopic(
          icon: Icons.credit_card_rounded,
          title: 'Change payment method',
          answer:
              'To change your payment method:\n\n'
              '1. Go to Account → Wallet\n'
              '2. Tap on "Manage payment methods"\n'
              '3. Add a new card or select an existing one\n'
              '4. Set your preferred method as default\n\n'
              'You can use credit cards, debit cards, PayPal, Google Pay, or Cruise Cash.',
        ),
        _HelpTopic(
          icon: Icons.lock_outline_rounded,
          title: 'I can\'t access my account',
          answer:
              'If you\'re having trouble logging in:\n\n'
              '• Make sure you\'re using the correct email or phone number\n'
              '• Check that your password is correct (passwords are case-sensitive)\n'
              '• Try resetting your password using the "Forgot Password" option\n'
              '• If you used social login, make sure you\'re using the same method\n\n'
              'If none of these work, contact support for account recovery assistance.',
        ),
        _HelpTopic(
          icon: Icons.email_outlined,
          title: 'Update my email or phone',
          answer:
              'To update your contact information:\n\n'
              '1. Go to Account → Settings → Edit Profile\n'
              '2. Tap on the email or phone field\n'
              '3. Enter your new information\n'
              '4. Tap Save\n\n'
              'A verification code will be sent to your new email/phone to confirm the change.',
        ),
        _HelpTopic(
          icon: Icons.delete_outline_rounded,
          title: 'Delete my account',
          answer:
              'We\'re sorry to see you go. To delete your account:\n\n'
              '1. Go to Account → Settings → Privacy\n'
              '2. Scroll to the bottom\n'
              '3. Tap "Delete Account"\n'
              '4. Confirm your decision\n\n'
              '⚠️ This action is permanent and cannot be undone. All your data, trip history, and payment information will be permanently removed.',
        ),
      ],
    ),
    _HelpCategory(
      title: 'Safety',
      icon: Icons.shield_rounded,
      items: [
        _HelpTopic(
          icon: Icons.warning_amber_rounded,
          title: 'Report a safety issue',
          answer:
              'Your safety is our top priority. If you experienced a safety issue during a ride:\n\n'
              '1. If you\'re in immediate danger, call 911 first\n'
              '2. Report the issue through the app as soon as possible\n'
              '3. Provide as much detail as you can\n\n'
              'Our safety team reviews all reports within 1 hour and will follow up with you directly.',
        ),
        _HelpTopic(
          icon: Icons.local_hospital_outlined,
          title: 'I was in an accident',
          answer:
              'If you were in an accident during a Cruise ride:\n\n'
              '1. Ensure everyone is safe — call 911 if there are injuries\n'
              '2. File a police report\n'
              '3. Contact Cruise support immediately\n\n'
              'We have insurance coverage for all rides. Our team will guide you through the claims process and ensure you receive proper support.',
        ),
        _HelpTopic(
          icon: Icons.person_off_rounded,
          title: 'My driver made me feel unsafe',
          answer:
              'We take all safety concerns seriously. If a driver made you feel uncomfortable or unsafe:\n\n'
              '• Report the driver through the app\n'
              '• The driver will be flagged for review\n'
              '• We may temporarily suspend the driver pending investigation\n\n'
              'Your report helps keep the Cruise community safe for everyone.',
        ),
      ],
    ),
    _HelpCategory(
      title: 'Using the App',
      icon: Icons.phone_iphone_rounded,
      items: [
        _HelpTopic(
          icon: Icons.gps_fixed_rounded,
          title: S.of(context).gpsLocationIssues,
          answer:
              'If the app isn\'t detecting your location correctly:\n\n'
              '1. Make sure location services are enabled for Cruise\n'
              '2. Enable "High Accuracy" mode in your device settings\n'
              '3. Restart the app\n'
              '4. Check that you have a stable internet connection\n\n'
              'If issues persist, try clearing the app cache or reinstalling.',
        ),
        _HelpTopic(
          icon: Icons.notifications_off_outlined,
          title: 'Not receiving notifications',
          answer:
              'To fix notification issues:\n\n'
              '1. Check that notifications are enabled in your device settings\n'
              '2. Go to Account → Settings → Notifications and ensure they\'re turned on\n'
              '3. Make sure "Do Not Disturb" mode is off\n'
              '4. Restart your device\n\n'
              'On Android, also check that Cruise isn\'t being restricted by battery optimization.',
        ),
        _HelpTopic(
          icon: Icons.map_outlined,
          title: 'Map not loading',
          answer:
              'If the map isn\'t showing properly:\n\n'
              '1. Check your internet connection\n'
              '2. Make sure Google Play Services is up to date\n'
              '3. Clear the app cache\n'
              '4. Restart the app\n\n'
              'This usually resolves the issue. If not, try reinstalling the app.',
        ),
      ],
    ),
  ];

  List<_HelpTopic> get _filteredTopics {
    if (_query.isEmpty) return [];
    final q = _query.toLowerCase();
    final results = <_HelpTopic>[];
    for (final cat in _categories()) {
      for (final item in cat.items) {
        if (item.title.toLowerCase().contains(q) ||
            item.answer.toLowerCase().contains(q)) {
          results.add(item);
        }
      }
    }
    return results;
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final searchResults = _filteredTopics;

    return Scaffold(
      backgroundColor: Colors.black,
      body: GoldParticlesBackground(child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 8),

            // ── Back button ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: GestureDetector(
                onTap: () => Navigator.of(context).pop(),
                child: Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.surface,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: c.textPrimary,
                    size: 18,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // ── Title ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'Help & Support',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'How can we help you today?',
                style: TextStyle(fontSize: 15, color: c.textSecondary),
              ),
            ),
            const SizedBox(height: 20),

            // ── Search bar ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Container(
                decoration: BoxDecoration(
                  color: c.surface,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: _query.isNotEmpty
                        ? _gold.withValues(alpha: 0.4)
                        : Colors.transparent,
                  ),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 2,
                ),
                child: TextField(
                  controller: _searchCtrl,
                  style: TextStyle(color: c.textPrimary, fontSize: 15),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: S.of(context).searchHelpTopics,
                    hintStyle: TextStyle(color: c.textTertiary, fontSize: 15),
                    icon: Icon(
                      Icons.search_rounded,
                      color: c.textTertiary,
                      size: 22,
                    ),
                    suffixIcon: _query.isNotEmpty
                        ? GestureDetector(
                            onTap: () {
                              _searchCtrl.clear();
                              setState(() => _query = '');
                            },
                            child: Icon(
                              Icons.close_rounded,
                              color: c.textTertiary,
                              size: 20,
                            ),
                          )
                        : null,
                  ),
                  onChanged: (v) => setState(() => _query = v.trim()),
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── Content ──
            Expanded(
              child: _query.isNotEmpty
                  ? _buildSearchResults(c, searchResults)
                  : _buildCategoryList(c),
            ),
          ],
        ),
      )),
    );
  }

  Widget _buildSearchResults(AppColors c, List<_HelpTopic> results) {
    if (results.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.search_off_rounded, color: c.textTertiary, size: 48),
            const SizedBox(height: 12),
            Text(
              S.of(context).noResultsFound,
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.w700,
                color: c.textPrimary,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              S.of(context).tryDifferentSearch,
              style: TextStyle(fontSize: 14, color: c.textSecondary),
            ),
            const SizedBox(height: 24),
            _contactSupportButton(c),
          ],
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      itemCount: results.length + 1,
      itemBuilder: (ctx, i) {
        if (i == results.length) {
          return Padding(
            padding: const EdgeInsets.only(top: 16, bottom: 32),
            child: _contactSupportCard(c),
          );
        }
        return _topicTile(c, results[i]);
      },
    );
  }

  Widget _buildCategoryList(AppColors c) {
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      children: [
        _quickFaqSection(c),
        const SizedBox(height: 24),
        ..._categories().map(
          (cat) => Padding(
            padding: const EdgeInsets.only(bottom: 20),
            child: _categorySection(c, cat),
          ),
        ),
        _contactSupportCard(c),
        const SizedBox(height: 32),
      ],
    );
  }

  Widget _quickFaqSection(AppColors c) {
    final faqs = [
      'How to pay?',
      'Cancel ride',
      'Lost item',
      'Safety',
      'Refund',
    ];
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: faqs.map((faq) {
        return GestureDetector(
          onTap: () {
            _searchCtrl.text = faq;
            setState(() => _query = faq);
          },
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: _gold.withValues(alpha: 0.2)),
            ),
            child: Text(
              faq,
              style: const TextStyle(
                color: _gold,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        );
      }).toList(),
    );
  }

  Widget _categorySection(AppColors c, _HelpCategory cat) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(9),
              ),
              child: Icon(cat.icon, color: _gold, size: 18),
            ),
            const SizedBox(width: 10),
            Text(
              cat.title,
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: c.textPrimary,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        ...cat.items.map((item) => _topicTile(c, item)),
      ],
    );
  }

  Widget _topicTile(AppColors c, _HelpTopic topic) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: () => _openTopicDetail(topic),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: c.surface,
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                Icon(topic.icon, color: c.textSecondary, size: 22),
                const SizedBox(width: 14),
                Expanded(
                  child: Text(
                    topic.title,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                      color: c.textPrimary,
                    ),
                  ),
                ),
                Icon(
                  Icons.chevron_right_rounded,
                  color: c.textTertiary,
                  size: 20,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  void _openTopicDetail(_HelpTopic topic) {
    Navigator.of(
      context,
    ).push(slideFromRightRoute(_HelpTopicDetailScreen(topic: topic)));
  }

  Widget _contactSupportCard(AppColors c) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            _gold.withValues(alpha: 0.08),
            _gold.withValues(alpha: 0.03),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _gold.withValues(alpha: 0.15)),
      ),
      child: Column(
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(16),
            ),
            child: const Icon(
              Icons.headset_mic_rounded,
              color: _gold,
              size: 28,
            ),
          ),
          const SizedBox(height: 14),
          Text(
            S.of(context).stillNeedHelp,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            S.of(context).supportAvailable247,
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: c.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              Expanded(
                child: _contactBtn(
                  c,
                  icon: Icons.email_outlined,
                  label: S.of(context).emailSupport,
                  onTap: () => _launchEmail(context),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: _contactBtn(
                  c,
                  icon: Icons.chat_bubble_outline_rounded,
                  label: S.of(context).liveChat,
                  onTap: () => _openLiveChat(context, c),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _contactBtn(
    AppColors c, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: c.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, color: _gold, size: 18),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: c.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _contactSupportButton(AppColors c) {
    return SizedBox(
      width: 200,
      height: 48,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: const Color(0xFF1A1400),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
          elevation: 0,
        ),
        onPressed: () => _launchEmail(context),
        child: Text(
          S.of(context).contactSupport,
          style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Future<void> _launchEmail(BuildContext context) async {
    final uri = Uri.parse(
      'mailto:support@cruiseride.com?subject=Help%20Request',
    );
    if (await canLaunchUrl(uri)) await launchUrl(uri);
  }

  void _openLiveChat(BuildContext context, AppColors c) {
    Navigator.of(
      context,
    ).push(slideFromRightRoute(const CruiseSupportChatScreen()));
  }
}

// ─────────────────────────────────────────────────────────
//  Help Topic Detail Screen
// ─────────────────────────────────────────────────────────
class _HelpTopicDetailScreen extends StatefulWidget {
  final _HelpTopic topic;
  const _HelpTopicDetailScreen({required this.topic});
  @override
  State<_HelpTopicDetailScreen> createState() => _HelpTopicDetailScreenState();
}

class _HelpTopicDetailScreenState extends State<_HelpTopicDetailScreen> {
  static const _gold = Color(0xFFE8C547);
  bool _helpful = false;
  bool _voted = false;

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: GoldParticlesBackground(child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 8, 24, 0),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: c.textPrimary,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Text(
                      'Help',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      width: 56,
                      height: 56,
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Icon(widget.topic.icon, color: _gold, size: 28),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      widget.topic.title,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: c.textPrimary,
                        letterSpacing: -0.3,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 20),
                    Text(
                      widget.topic.answer,
                      style: TextStyle(
                        fontSize: 15,
                        color: c.textSecondary,
                        height: 1.6,
                      ),
                    ),
                    const SizedBox(height: 32),
                    // Was this helpful?
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          Text(
                            _voted
                                ? 'Thanks for your feedback!'
                                : 'Was this helpful?',
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: c.textPrimary,
                            ),
                          ),
                          const SizedBox(height: 14),
                          if (!_voted)
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                _feedbackBtn(
                                  c,
                                  Icons.thumb_up_rounded,
                                  'Yes',
                                  true,
                                ),
                                const SizedBox(width: 12),
                                _feedbackBtn(
                                  c,
                                  Icons.thumb_down_rounded,
                                  'No',
                                  false,
                                ),
                              ],
                            )
                          else
                            Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  _helpful
                                      ? Icons.check_circle_rounded
                                      : Icons.support_agent_rounded,
                                  color: _helpful ? const Color(0xFFE8C547) : _gold,
                                  size: 28,
                                ),
                                const SizedBox(width: 10),
                                Text(
                                  _helpful ? 'Glad it helped!' : 'We\'ll connect you with our team.',
                                  style: TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                    color: c.textSecondary,
                                  ),
                                ),
                              ],
                            ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 20),
                    SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: const Color(0xFF1A1400),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        onPressed: () async {
                          final uri = Uri.parse(
                            'mailto:support@cruiseride.com?subject=${Uri.encodeComponent(widget.topic.title)}',
                          );
                          if (await canLaunchUrl(uri)) await launchUrl(uri);
                        },
                        icon: const Icon(Icons.headset_mic_rounded, size: 20),
                        label: const Text(
                          'Contact Support',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
            ),
          ],
        ),
      )),
    );
  }

  Widget _feedbackBtn(
    AppColors c,
    IconData icon,
    String label,
    bool isPositive,
  ) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          HapticFeedback.lightImpact();
          setState(() {
            _voted = true;
            _helpful = isPositive;
          });
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          decoration: BoxDecoration(
            color: c.bg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: c.textTertiary.withValues(alpha: 0.2)),
          ),
          child: Row(
            children: [
              Icon(icon, color: c.textSecondary, size: 20),
              const SizedBox(width: 8),
              Text(
                label,
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: c.textPrimary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
//  Live Support Chat — 3-phase AI agent experience
//  Phase 1: Bot intake (greeting + quick actions)
//  Phase 2: Simulated queue (3-4 min timer)
//  Phase 3: Agent chat (human-like AI responses)
// ─────────────────────────────────────────────────────────
class CruiseSupportChatScreen extends StatefulWidget {
  const CruiseSupportChatScreen({super.key});
  @override
  State<CruiseSupportChatScreen> createState() =>
      _CruiseSupportChatScreenState();
}

enum _ChatPhase { bot, queue, agent }

class _CruiseSupportChatScreenState extends State<CruiseSupportChatScreen> {
  static const _gold = Color(0xFFE8C547);

  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode();
  final List<_ChatMsg> _messages = [];
  final List<_ChatMsg> _bufferedMessages = [];

  int? _chatId;
  String? _agentName;
  String _subtitle = '';
  bool _loading = true;
  bool _sending = false;
  bool _chatClosed = false;
  bool _isAgentTyping = false;
  bool _showQuickActions = true;
  Timer? _pollTimer;
  Timer? _typingDebounce;
  bool _isUserTyping = false;
  String _userRole = 'rider';
  int _pollFailures = 0;
  int _initAttemptCount = 0;

  _ChatPhase _phase = _ChatPhase.bot;
  int _queueDuration = 180;

  // Track how many messages were shown before queue started
  int _preQueueMsgCount = 0;

  bool get _isSpanish {
    try {
      return Localizations.localeOf(context).languageCode.startsWith('es');
    } catch (_) {
      return false;
    }
  }

  @override
  void initState() {
    super.initState();
    _queueDuration = AiSupportService.randomQueueWait();
    WidgetsBinding.instance.addPostFrameCallback((_) => _initChat());
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _typingDebounce?.cancel();
    if (_isUserTyping && _chatId != null) {
      ApiService.setSupportTypingStatus(_chatId!, false);
    }
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  // ── Initialization ──────────────────────────────────────────────────

  Future<void> _initChat() async {
    _initAttemptCount++;
    if (_initAttemptCount > 3) {
      _initAttemptCount = 0;
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      final locale = Localizations.localeOf(context).languageCode;

      // Determine user role
      final mode = await UserSession.getMode();
      _userRole = mode.isNotEmpty ? mode : 'rider';

      await ApiService.probeAndSetBestUrl(timeout: const Duration(seconds: 4));
      final chat = await ApiService.createSupportChat(
        subject: 'Soporte general',
        locale: locale,
      );
      _chatId = chat['id'] as int?;
      _agentName = chat['agent_name'] as String?;
      final status = chat['status'] as String? ?? 'open';
      final botPhase = chat['bot_phase'] as String? ?? 'welcome';
      if (status == 'closed') _chatClosed = true;

      if (_chatId != null) {
        await _loadMessages();

        // If the loaded chat was already ended, auto-restart with a fresh one
        if (_chatClosed) {
          ApiService.closeSupportChat(_chatId!).catchError((_) {});
          _chatId = null;
          _chatClosed = false;
          _messages.clear();
          _agentName = null;
          _phase = _ChatPhase.bot;
          _showQuickActions = true;
          await Future.delayed(const Duration(milliseconds: 600));
          if (mounted) await _initChat();
          return;
        }

        _initAttemptCount = 0; // successful init
        _pollTimer = Timer.periodic(
          const Duration(seconds: 3),
          (_) => _loadMessages(),
        );
      }

      // If resuming a chat that's already in agent phase, skip to agent
      if (botPhase == 'agent_active' || botPhase == 'escalated' || botPhase == 'dispatch_takeover') {
        _phase = _ChatPhase.agent;
        _showQuickActions = false;
        if (_agentName != null) {
          _subtitle = '${_agentName!} · ${_isSpanish ? 'En línea' : 'Online'}';
        }
      } else {
        _subtitle = _isSpanish ? 'Soporte Cruise' : 'Cruise Support';
      }
    } catch (e) {
      debugPrint('[SupportChat] init error: $e');
      // _withRetry already tried 3 times — re-probe with longer timeout and try once more
      if (_chatId == null) {
        try {
          await ApiService.probeAndSetBestUrl(timeout: const Duration(seconds: 8));
          final chat = await ApiService.createSupportChat(
            subject: 'Soporte general',
            locale: 'en',
          );
          _chatId = chat['id'] as int?;
          _agentName = chat['agent_name'] as String?;
          if (_chatId != null) {
            await _loadMessages();
            _pollTimer = Timer.periodic(
              const Duration(seconds: 3),
              (_) => _loadMessages(),
            );
          }
        } catch (e2) {
          debugPrint('[SupportChat] init retry also failed: $e2');
          // Show error to user — don't fail silently
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(_isSpanish
                    ? 'No se pudo conectar al soporte. Intenta de nuevo.'
                    : 'Could not connect to support. Please try again.'),
                backgroundColor: Colors.red,
                action: SnackBarAction(
                  label: _isSpanish ? 'Reintentar' : 'Retry',
                  textColor: Colors.white,
                  onPressed: () {
                    setState(() => _loading = true);
                    _initChat();
                  },
                ),
              ),
            );
          }
        }
      }
    }
    if (mounted) setState(() => _loading = false);
  }

  // ── Message loading & polling ───────────────────────────────────────

  Future<void> _loadMessages() async {
    if (_chatId == null) return;
    try {
      final msgs = await ApiService.getSupportMessages(_chatId!);
      if (!mounted) return;
      _pollFailures = 0;

      final newMessages = msgs.map((m) {
        final role = m['sender_role'] ?? '';
        return _ChatMsg(
          text: m['message'] ?? '',
          role: role,
          time: DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now(),
          senderName: m['sender_name'] ?? '',
        );
      }).toList();

      if (newMessages.length == _messages.length + _bufferedMessages.length) return;

      // Extract agent name from bot messages
      for (final m in newMessages) {
        if (m.role == 'bot' && m.senderName.isNotEmpty &&
            m.senderName != 'Asistente Cruise' &&
            m.senderName != 'Cruise Assistant') {
          _agentName = m.senderName;
        }
      }

      // Check for chat closure
      final lastBot = newMessages.where((m) => m.role == 'bot').lastOrNull;
      if (lastBot != null &&
          (lastBot.text.contains('cerraré este chat') ||
              lastBot.text.contains('closing this session'))) {
        _chatClosed = true;
        _pollTimer?.cancel();
      }

      if (_phase == _ChatPhase.queue) {
        // Buffer messages during queue — they'll be revealed after queue completes
        _bufferedMessages.clear();
        _bufferedMessages.addAll(newMessages.skip(_preQueueMsgCount));
        return;
      }

      // Check if any new message triggers transition to queue
      if (_phase == _ChatPhase.bot) {
        for (final m in newMessages) {
          if ((m.role == 'bot' || m.role == 'system') &&
              AiSupportService.isConnectingMessage(m.text)) {
            // Show the connecting message, then start queue
            setState(() {
              _messages.clear();
              _messages.addAll(newMessages);
              _showQuickActions = false;
              _preQueueMsgCount = newMessages.length;
            });
            _scrollToBottom();
            // Short delay then transition to queue
            await Future.delayed(const Duration(seconds: 2));
            if (mounted) {
              setState(() {
                _phase = _ChatPhase.queue;
                _subtitle = _isSpanish
                    ? 'Conectando con un agente...'
                    : 'Connecting to an agent...';
              });
            }
            return;
          }
        }
      }

      // Check for agent joined (if we somehow skipped queue)
      if (_phase == _ChatPhase.bot) {
        for (final m in newMessages) {
          if (m.role == 'system' && AiSupportService.isAgentJoinedMessage(m.text)) {
            _phase = _ChatPhase.agent;
            _showQuickActions = false;
          }
        }
      }

      // Deliver new messages with typing indicator for agent phase
      if (_phase == _ChatPhase.agent && newMessages.length > _messages.length) {
        final newOnes = newMessages.skip(_messages.length).toList();
        final agentMessages = newOnes.where((m) => m.role == 'bot').toList();

        if (agentMessages.isNotEmpty) {
          // Show typing indicator then reveal
          setState(() => _isAgentTyping = true);
          _scrollToBottom();

          // Wait for realistic typing duration
          final typingMs = AiSupportService.typingDuration(
            agentMessages.first.text,
          );
          await Future.delayed(Duration(milliseconds: typingMs.clamp(2000, 8000)));

          if (!mounted) return;
          setState(() {
            _isAgentTyping = false;
            _messages.clear();
            _messages.addAll(newMessages);
            if (_chatClosed) {
              _subtitle = S.of(context).chatClosed;
            } else if (_agentName != null) {
              _subtitle = '${_agentName!} · ${_isSpanish ? 'En línea' : 'Online'}';
            }
          });
          _scrollToBottom();
          return;
        }
      }

      // Default: just update messages
      setState(() {
        _messages.clear();
        _messages.addAll(newMessages);
        _sending = false;
        if (_chatClosed) {
          _subtitle = S.of(context).chatClosed;
        } else if (_phase == _ChatPhase.agent && _agentName != null) {
          _subtitle = '${_agentName!} · ${_isSpanish ? 'En línea' : 'Online'}';
        }
      });
      _scrollToBottom();
    } catch (e) {
      debugPrint('[SupportChat] poll error: $e');
      _pollFailures++;
      // After 3 consecutive failures, re-probe and notify user
      if (_pollFailures >= 3 && mounted) {
        _pollFailures = 0;
        ApiService.probeAndSetBestUrl(timeout: const Duration(seconds: 6)).catchError((_) => null);
      }
    }
  }

  // ── Queue completed ─────────────────────────────────────────────────

  void _onQueueComplete() async {
    if (!mounted) return;

    // Transition to agent phase
    setState(() {
      _phase = _ChatPhase.agent;
      _showQuickActions = false;
    });

    // Show typing indicator briefly
    setState(() => _isAgentTyping = true);
    await Future.delayed(const Duration(seconds: 3));
    if (!mounted) return;

    // Reveal buffered messages one at a time with typing delays
    final toReveal = List<_ChatMsg>.from(_bufferedMessages);
    _bufferedMessages.clear();

    for (final msg in toReveal) {
      if (!mounted) return;

      if (msg.role == 'system') {
        // System messages appear instantly
        setState(() {
          _isAgentTyping = false;
          _messages.add(msg);
        });
        _scrollToBottom();
        await Future.delayed(const Duration(milliseconds: 800));
        continue;
      }

      if (msg.role == 'bot') {
        setState(() => _isAgentTyping = true);
        _scrollToBottom();
        final delay = AiSupportService.typingDuration(msg.text).clamp(3000, 10000);
        await Future.delayed(Duration(milliseconds: delay));
        if (!mounted) return;
        setState(() {
          _isAgentTyping = false;
          _messages.add(msg);
        });
        _scrollToBottom();
        await Future.delayed(const Duration(milliseconds: 600));
      } else {
        setState(() {
          _isAgentTyping = false;
          _messages.add(msg);
        });
        _scrollToBottom();
      }
    }

    if (mounted) {
      setState(() {
        _isAgentTyping = false;
        if (_agentName != null) {
          _subtitle = '${_agentName!} · ${_isSpanish ? 'En línea' : 'Online'}';
        } else {
          _subtitle = _isSpanish ? 'Soporte Cruise' : 'Cruise Support';
        }
      });
    }

    // Make sure we have the latest messages
    await _loadMessages();
  }

  // ── Typing detection ─────────────────────────────────────────────────

  void _onTypingChanged(String value) {
    if (mounted) setState(() {});
    if (_chatId == null) return;
    if (!_isUserTyping && value.isNotEmpty) {
      _isUserTyping = true;
      ApiService.setSupportTypingStatus(_chatId!, true);
    }
    _typingDebounce?.cancel();
    _typingDebounce = Timer(const Duration(seconds: 3), () {
      if (_isUserTyping) {
        _isUserTyping = false;
        ApiService.setSupportTypingStatus(_chatId!, false);
      }
    });
  }

  // ── Send message ────────────────────────────────────────────────────

  Future<void> _sendMessage([String? prefilledText]) async {
    final text = prefilledText ?? _msgCtrl.text.trim();
    if (text.isEmpty || _sending) return;

    // If this chat session was closed, start a fresh one instead
    if (_chatClosed) {
      _startNewChat();
      return;
    }

    if (prefilledText == null) _msgCtrl.clear();
    // Clear typing status on send
    _typingDebounce?.cancel();
    if (_isUserTyping && _chatId != null) {
      _isUserTyping = false;
      ApiService.setSupportTypingStatus(_chatId!, false);
    }

    // Hide quick actions after first message
    if (_showQuickActions) {
      setState(() => _showQuickActions = false);
    }

    // During queue, show a note that message was received
    if (_phase == _ChatPhase.queue) {
      setState(() {
        _messages.add(_ChatMsg(
          text: text,
          role: _userRole,
          time: DateTime.now(),
        ));
      });
      _scrollToBottom();
      // Send to backend silently
      if (_chatId != null) {
        try {
          await ApiService.sendSupportMessage(_chatId!, text);
        } catch (_) {}
      }
      // Show "message received" note
      await Future.delayed(const Duration(seconds: 1));
      if (mounted) {
        setState(() {
          _messages.add(_ChatMsg(
            text: _isSpanish
                ? 'Tu mensaje fue recibido. El agente lo verá cuando se conecte.'
                : 'Your message was received. The agent will see it when they connect.',
            role: 'system',
            time: DateTime.now(),
          ));
        });
        _scrollToBottom();
      }
      return;
    }

    if (_chatId == null) {
      setState(() => _loading = true);
      await _initChat();
      if (_chatId == null) {
        if (mounted) {
          setState(() => _loading = false);
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(_isSpanish
                  ? 'No se pudo conectar al soporte. Intenta de nuevo.'
                  : 'Could not connect to support. Please try again.'),
              backgroundColor: Colors.red,
              action: SnackBarAction(
                label: _isSpanish ? 'Reintentar' : 'Retry',
                textColor: Colors.white,
                onPressed: () {
                  setState(() => _loading = true);
                  _initChat();
                },
              ),
            ),
          );
        }
        return;
      }
    }

    setState(() {
      _sending = true;
      _messages.add(_ChatMsg(text: text, role: _userRole, time: DateTime.now()));
    });
    _scrollToBottom();

    try {
      await ApiService.sendSupportMessage(_chatId!, text);
      // Show typing indicator while waiting for bot/agent response
      if (mounted && _phase == _ChatPhase.agent) {
        setState(() => _isAgentTyping = true);
        _scrollToBottom();
      }
      // Immediately poll for reply
      await Future.delayed(const Duration(seconds: 2));
      await _loadMessages();
    } catch (e) {
      debugPrint('[SupportChat] send error: $e');
      if (mounted) {
        final failedText = text;
        setState(() {
          if (_messages.isNotEmpty && _messages.last.role == _userRole) {
            _messages.removeLast();
          }
        });
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(_isSpanish
                ? 'No se pudo enviar el mensaje. Intenta de nuevo.'
                : 'Message could not be sent. Please try again.'),
            backgroundColor: Colors.red,
            action: SnackBarAction(
              label: _isSpanish ? 'Reintentar' : 'Retry',
              textColor: Colors.white,
              onPressed: () => _sendMessage(failedText),
            ),
          ),
        );
      }
    }
    if (mounted) setState(() => _sending = false);
  }

  // ── Scroll ──────────────────────────────────────────────────────────

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent + 80,
          duration: const Duration(milliseconds: 250),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Voice call ──────────────────────────────────────────────────────

  Future<void> _startVoiceCall() async {
    try {
      final phone = await ApiService.getSupportPhoneNumber();
      if (phone == null || phone.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(S.of(context).supportLineUnavailable),
              backgroundColor: Colors.red,
            ),
          );
        }
        return;
      }
      final uri = Uri(scheme: 'tel', path: phone);
      if (await canLaunchUrl(uri)) await launchUrl(uri);
    } catch (_) {}
  }

  // ── End / new chat ──────────────────────────────────────────────────

  Future<void> _endChat() async {
    if (_chatId == null || _chatClosed) return;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          S.of(context).endChat,
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w700),
        ),
        content: Text(
          S.of(context).endChatConfirm,
          style: TextStyle(color: Colors.grey[400]),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.of(context).cancel, style: const TextStyle(color: Colors.grey)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(S.of(context).endChat, style: const TextStyle(color: _gold)),
          ),
        ],
      ),
    );
    if (confirm != true) return;
    try {
      await ApiService.closeSupportChat(_chatId!);
      _pollTimer?.cancel();
      if (mounted) {
        setState(() {
          _chatClosed = true;
          _subtitle = S.of(context).chatClosed;
        });
      }
    } catch (_) {}
  }

  void _startNewChat() {
    _pollTimer?.cancel();
    _pollTimer = null;
    setState(() {
      _chatId = null;
      _messages.clear();
      _bufferedMessages.clear();
      _chatClosed = false;
      _loading = true;
      _agentName = null;
      _subtitle = '';
      _sending = false;
      _phase = _ChatPhase.bot;
      _showQuickActions = true;
      _isAgentTyping = false;
      _queueDuration = AiSupportService.randomQueueWait();
      _initAttemptCount = 0;
    });
    _initChat();
  }

  // ── BUILD ───────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0D0F),
      resizeToAvoidBottomInset: true,
      appBar: _buildAppBar(),
      body: Column(
        children: [
          Expanded(
            child: _loading ? _buildLoadingState() : _buildBody(),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  // ── App Bar ──────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar() {
    final String chatTitle = _phase == _ChatPhase.agent && _agentName != null
        ? _agentName!
        : (_isSpanish ? 'Soporte Cruise' : 'Cruise Support');

    final String statusLabel;
    final Color statusColor;
    if (_chatClosed) {
      statusLabel = S.of(context).chatClosed;
      statusColor = Colors.white.withValues(alpha: 0.3);
    } else if (_isAgentTyping || _sending) {
      statusLabel = _isSpanish ? 'Escribiendo...' : 'Typing...';
      statusColor = Colors.amber;
    } else if (_phase == _ChatPhase.queue) {
      statusLabel = _isSpanish ? 'Buscando agente...' : 'Finding an agent...';
      statusColor = Colors.orange;
    } else if (_phase == _ChatPhase.agent) {
      statusLabel = _isSpanish ? 'En línea' : 'Online';
      statusColor = const Color(0xFF4CAF50);
    } else {
      statusLabel = _isSpanish ? 'Sistema automatizado' : 'Automated system';
      statusColor = const Color(0xFF4CAF50);
    }

    return AppBar(
      backgroundColor: const Color(0xFF0D0D0F),
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_new_rounded, color: Colors.white, size: 18),
        onPressed: () => Navigator.of(context).pop(),
      ),
      title: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFE8C547), Color(0xFFB8921A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.22),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Center(
              child: _phase == _ChatPhase.agent && _agentName != null
                  ? Text(
                      _agentName![0].toUpperCase(),
                      style: const TextStyle(
                        color: Color(0xFF0A0800),
                        fontSize: 17,
                        fontWeight: FontWeight.w800,
                      ),
                    )
                  : const Icon(Icons.support_agent_rounded, color: Color(0xFF0A0800), size: 22),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  chatTitle,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: -0.2,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                Row(
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        statusLabel,
                        style: TextStyle(
                          fontSize: 11,
                          color: statusColor,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
      actions: [
        if (!_chatClosed && _chatId != null)
          IconButton(
            icon: Icon(Icons.close_rounded, color: Colors.white.withValues(alpha: 0.3), size: 20),
            tooltip: _isSpanish ? 'Cerrar chat' : 'End chat',
            onPressed: _endChat,
          ),
        IconButton(
          icon: const Icon(Icons.phone_rounded, color: _gold, size: 22),
          tooltip: _isSpanish ? 'Llamar a soporte' : 'Call support',
          onPressed: _startVoiceCall,
        ),
      ],
      bottom: PreferredSize(
        preferredSize: const Size.fromHeight(1),
        child: Container(
          height: 0.5,
          color: Colors.white.withValues(alpha: 0.07),
        ),
      ),
    );
  }

  // ── Loading state ─────────────────────────────────────────────────

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 68,
            height: 68,
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFFE8C547), Color(0xFFB8921A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              shape: BoxShape.circle,
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.28),
                  blurRadius: 24,
                  spreadRadius: 4,
                ),
              ],
            ),
            child: const Icon(
              Icons.support_agent_rounded,
              color: Color(0xFF0A0800),
              size: 34,
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            'Cruise Support',
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.5,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isSpanish
                ? 'Preparando tu sesión de soporte...'
                : 'Preparing your support session...',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 28),
          const SizedBox(
            width: 28,
            height: 28,
            child: CircularProgressIndicator(strokeWidth: 2.5, color: _gold),
          ),
        ],
      ),
    );
  }

  // ── Chat body ───────────────────────────────────────────────────────

  Widget _buildBody() {
    final items = <Widget>[];

    // Welcome greeting — fallback when backend hasn't loaded messages yet
    if (_phase == _ChatPhase.bot && _messages.isEmpty) {
      items.add(_buildWelcomeHeader());
    }

    // Message bubbles
    for (final msg in _messages) {
      items.add(_buildBubble(msg));
    }

    // Quick action chips — only when chat is active
    if (_showQuickActions && !_chatClosed) {
      items.add(_buildQuickActions());
    }

    // Queue wait widget
    if (_phase == _ChatPhase.queue) {
      items.add(QueueStatusWidget(
        totalDuration: _queueDuration,
        onComplete: _onQueueComplete,
        isSpanish: _isSpanish,
      ));
    }

    // Typing indicator
    if (_isAgentTyping) {
      items.add(Padding(
        padding: const EdgeInsets.only(top: 4, bottom: 8),
        child: TypingBubble(agentName: _agentName),
      ));
    }

    items.add(const SizedBox(height: 20));

    return ListView(
      controller: _scrollCtrl,
      padding: const EdgeInsets.fromLTRB(14, 16, 14, 0),
      children: items,
    );
  }

  // ── Welcome greeting ─────────────────────────────────────────────

  Widget _buildWelcomeHeader() {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: const Color(0xFF13141A),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: const Color(0xFFE8C547).withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFE8C547), Color(0xFFB8921A)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFE8C547).withValues(alpha: 0.2),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: const Icon(Icons.support_agent_rounded, color: Color(0xFF0A0800), size: 22),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _isSpanish ? 'Asistente Cruise' : 'Cruise Assistant',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  Row(
                    children: [
                      const Icon(Icons.circle, color: Color(0xFF4CAF50), size: 7),
                      const SizedBox(width: 4),
                      Text(
                        _isSpanish ? 'Sistema automatizado' : 'Automated system',
                        style: const TextStyle(
                          color: Color(0xFF4CAF50),
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            _isSpanish
                ? '¡Hola! Soy el Asistente de soporte de Cruise.\n\nEstoy aquí para ayudarte en lo que necesites — viajes, pagos, cuenta o cualquier otro tema.\n\n¿En qué puedo ayudarte hoy?'
                : 'Hello! I\'m the Cruise Support Assistant.\n\nI\'m here to help with anything — trips, payments, your account, or anything else.\n\nWhat can I help you with?',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.85),
              fontSize: 14.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }

  // ── Quick action chips ──────────────────────────────────────────────

  Widget _buildQuickActions() {
    final actions = _userRole == 'driver'
        ? AgentPrompts.driverQuickActions(_isSpanish)
        : AgentPrompts.riderQuickActions(_isSpanish);

    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: List.generate(actions.length, (i) {
          final action = actions[i];
          return GestureDetector(
            onTap: () => _sendMessage(action['message']),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF16171B),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.2),
                ),
              ),
              child: Text(
                action['label']!,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          );
        }),
      ),
    );
  }

  // ── Message bubble ──────────────────────────────────────────────────

  Widget _buildBubble(_ChatMsg msg) {
    if (msg.role == 'system') {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.055),
              borderRadius: BorderRadius.circular(20),
            ),
            child: Text(
              msg.text,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                color: Colors.white.withValues(alpha: 0.45),
                fontWeight: FontWeight.w500,
                height: 1.4,
              ),
            ),
          ),
        ),
      );
    }

    final isUser = msg.role == 'rider' || msg.role == 'driver';
    final isDispatch = msg.role == 'dispatch';

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        mainAxisAlignment: isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          if (!isUser) ...[
            Container(
              width: 28,
              height: 28,
              margin: const EdgeInsets.only(right: 6, bottom: 2),
              decoration: BoxDecoration(
                gradient: isDispatch
                    ? const LinearGradient(
                        colors: [Color(0xFF6A5ACD), Color(0xFF483D8B)],
                      )
                    : const LinearGradient(
                        colors: [Color(0xFFE8C547), Color(0xFFB8921A)],
                      ),
                shape: BoxShape.circle,
              ),
              child: Center(
                child: Text(
                  (msg.senderName.isNotEmpty && msg.senderName != 'Unknown')
                      ? msg.senderName[0].toUpperCase()
                      : (isDispatch ? 'S' : (_agentName != null ? _agentName![0].toUpperCase() : 'C')),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ),
          ],
          Flexible(
            child: Container(
              constraints: BoxConstraints(
                maxWidth: MediaQuery.of(context).size.width * 0.72,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 10),
              decoration: BoxDecoration(
                gradient: isUser
                    ? const LinearGradient(
                        colors: [Color(0xFFE8C547), Color(0xFFD4A012)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      )
                    : null,
                color: isUser
                    ? null
                    : isDispatch
                        ? const Color(0xFF1E1A2E)
                        : const Color(0xFF1C1D22),
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(16),
                  topRight: const Radius.circular(16),
                  bottomLeft: Radius.circular(isUser ? 16 : 3),
                  bottomRight: Radius.circular(isUser ? 3 : 16),
                ),
                border: isDispatch
                    ? Border.all(color: const Color(0xFF6A5ACD).withValues(alpha: 0.4))
                    : null,
                boxShadow: [
                  BoxShadow(
                    color: isUser
                        ? const Color(0xFFE8C547).withValues(alpha: 0.12)
                        : isDispatch
                            ? const Color(0xFF6A5ACD).withValues(alpha: 0.1)
                            : Colors.black.withValues(alpha: 0.18),
                    blurRadius: 6,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Column(
                crossAxisAlignment: isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
                children: [
                  if (!isUser && (msg.senderName.isNotEmpty || _agentName != null))
                    Padding(
                      padding: const EdgeInsets.only(bottom: 3),
                      child: Text(
                        (msg.senderName.isNotEmpty && msg.senderName != 'Unknown')
                            ? msg.senderName
                            : (_agentName ?? (_isSpanish ? 'Soporte Cruise' : 'Cruise Support')),
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: isDispatch
                              ? const Color(0xFF9D8FE8)
                              : const Color(0xFFE8C547).withValues(alpha: 0.8),
                        ),
                      ),
                    ),
                  Text(
                    msg.text,
                    style: TextStyle(
                      color: isUser
                          ? const Color(0xFF0A0800)
                          : Colors.white.withValues(alpha: 0.9),
                      fontSize: 14.5,
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}',
                    style: TextStyle(
                      fontSize: 10,
                      color: isUser
                          ? const Color(0xFF0A0800).withValues(alpha: 0.45)
                          : Colors.white.withValues(alpha: 0.28),
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isUser) const SizedBox(width: 2),
        ],
      ),
    );
  }

  // ── Input bar ───────────────────────────────────────────────────────

  Widget _buildInputBar() {
    if (_chatClosed) {
      return Container(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 14,
          bottom: MediaQuery.of(context).padding.bottom + 14,
        ),
        decoration: BoxDecoration(
          color: const Color(0xFF0D0D0F),
          border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              S.of(context).thisChatClosed,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 12.5,
              ),
            ),
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: _startNewChat,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: const Color(0xFF0A0800),
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(24),
                  ),
                ),
                child: Text(
                  S.of(context).startNewChat,
                  style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 14),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      padding: EdgeInsets.only(
        left: 12,
        right: 8,
        top: 10,
        bottom: MediaQuery.of(context).padding.bottom + 10,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0D0D0F),
        border: Border(top: BorderSide(color: Colors.white.withValues(alpha: 0.06))),
      ),
      child: Row(
        children: [
          Expanded(
            child: TextField(
              controller: _msgCtrl,
              focusNode: _focusNode,
              style: const TextStyle(color: Colors.white, fontSize: 15),
              maxLines: 4,
              minLines: 1,
              textInputAction: TextInputAction.send,
              onSubmitted: (_) => _sendMessage(),
              onChanged: _onTypingChanged,
              decoration: InputDecoration(
                hintText: S.of(context).describeYourProblem,
                hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.28)),
                filled: true,
                fillColor: const Color(0xFF16171B),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 11),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: const BorderSide(color: _gold, width: 1.5),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: (_sending || _msgCtrl.text.trim().isEmpty) ? null : () => _sendMessage(),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              width: 42,
              height: 42,
              decoration: BoxDecoration(
                gradient: (_sending || _msgCtrl.text.trim().isEmpty)
                    ? null
                    : const LinearGradient(
                        colors: [Color(0xFFE8C547), Color(0xFFD4A012)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                color: (_sending || _msgCtrl.text.trim().isEmpty) ? const Color(0xFF2A2A2E) : null,
                shape: BoxShape.circle,
                boxShadow: (_sending || _msgCtrl.text.trim().isEmpty)
                    ? []
                    : [
                        BoxShadow(
                          color: const Color(0xFFE8C547).withValues(alpha: 0.3),
                          blurRadius: 10,
                          offset: const Offset(0, 2),
                        ),
                      ],
              ),
              child: Center(
                child: _sending
                    ? SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      )
                    : Icon(
                        Icons.arrow_upward_rounded,
                        color: _msgCtrl.text.trim().isEmpty
                            ? Colors.white.withValues(alpha: 0.2)
                            : const Color(0xFF0A0800),
                        size: 20,
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ChatMsg {
  final String text;
  final String role; // rider, bot, system, dispatch
  final DateTime time;
  final String senderName;
  const _ChatMsg({
    required this.text,
    required this.role,
    required this.time,
    this.senderName = '',
  });
}

class _HelpCategory {
  final String title;
  final IconData icon;
  final List<_HelpTopic> items;
  const _HelpCategory({
    required this.title,
    required this.icon,
    required this.items,
  });
}

class _HelpTopic {
  final IconData icon;
  final String title;
  final String answer;
  const _HelpTopic({
    required this.icon,
    required this.title,
    required this.answer,
  });
}
