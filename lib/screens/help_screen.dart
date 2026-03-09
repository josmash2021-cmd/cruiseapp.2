import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/user_session.dart';

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

  final List<_HelpCategory> _categories = const [
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
          answer:
              'If you were charged for a ride that never took place, we apologize for the inconvenience.\n\n'
              'This can happen due to:\n'
              '• A driver starting the trip accidentally\n'
              '• GPS errors\n'
              '• App glitches\n\n'
              'Please contact support and we\'ll investigate and issue a full refund if confirmed.',
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
          title: 'GPS / location issues',
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
    for (final cat in _categories) {
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
      backgroundColor: c.bg,
      body: SafeArea(
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
      ),
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
        ..._categories.map(
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
      backgroundColor: c.bg,
      body: SafeArea(
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
                            Icon(
                              _helpful
                                  ? Icons.check_circle_rounded
                                  : Icons.support_agent_rounded,
                              color: _helpful ? const Color(0xFFE8C547) : _gold,
                              size: 32,
                            ),
                          if (_voted && !_helpful) ...[
                            const SizedBox(height: 12),
                            Text(
                              'We\'ll connect you with our team.',
                              style: TextStyle(
                                fontSize: 13,
                                color: c.textSecondary,
                              ),
                            ),
                          ],
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
      ),
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
//  Live Support Chat (connected to backend)
// ─────────────────────────────────────────────────────────
class CruiseSupportChatScreen extends StatefulWidget {
  const CruiseSupportChatScreen({super.key});
  @override
  State<CruiseSupportChatScreen> createState() =>
      _CruiseSupportChatScreenState();
}

class _CruiseSupportChatScreenState extends State<CruiseSupportChatScreen> {
  static const _gold = Color(0xFFE8C547);

  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode();
  final List<_ChatMsg> _messages = [];
  int? _chatId;
  bool _loading = true;
  bool _sending = false;
  Timer? _pollTimer;

  @override
  void initState() {
    super.initState();
    _initChat();
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  Future<void> _initChat() async {
    try {
      final chat = await ApiService.createSupportChat(subject: 'Soporte general');
      _chatId = chat['id'] as int?;
      if (_chatId != null) {
        await _loadMessages();
        _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _loadMessages());
      }
    } catch (e) {
      debugPrint('[SupportChat] init error: $e');
    }
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _loadMessages() async {
    if (_chatId == null) return;
    try {
      final msgs = await ApiService.getSupportMessages(_chatId!);
      if (!mounted) return;
      final newMessages = msgs.map((m) => _ChatMsg(
        text: m['message'] ?? '',
        isUser: m['sender_role'] != 'dispatch',
        time: DateTime.tryParse(m['created_at'] ?? '') ?? DateTime.now(),
        senderName: m['sender_name'] ?? '',
      )).toList();
      if (newMessages.length != _messages.length) {
        setState(() {
          _messages.clear();
          _messages.addAll(newMessages);
        });
        _scrollToBottom();
      }
    } catch (e) {
      debugPrint('[SupportChat] poll error: $e');
    }
  }

  Future<void> _sendMessage() async {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || _chatId == null || _sending) return;
    _msgCtrl.clear();
    setState(() {
      _sending = true;
      _messages.add(_ChatMsg(text: text, isUser: true, time: DateTime.now()));
    });
    _scrollToBottom();
    try {
      await ApiService.sendSupportMessage(_chatId!, text);
    } catch (e) {
      debugPrint('[SupportChat] send error: $e');
    }
    if (mounted) setState(() => _sending = false);
  }

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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF1A1A1A),
      appBar: AppBar(
        backgroundColor: const Color(0xFF1A1A1A),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Row(
          children: [
            Container(
              width: 36, height: 36,
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [_gold, Color(0xFFD4A017)]),
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.support_agent, color: Colors.black, size: 20),
            ),
            const SizedBox(width: 10),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text('Soporte Cruise', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                Row(
                  children: [
                    Container(
                      width: 7, height: 7,
                      decoration: const BoxDecoration(color: Color(0xFF4CAF50), shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 4),
                    Text('En línea', style: TextStyle(fontSize: 11, color: Colors.grey[400])),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(color: _gold))
                : _messages.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.chat_bubble_outline, size: 48, color: Colors.grey[600]),
                            const SizedBox(height: 12),
                            Text('Escribe tu mensaje para iniciar',
                                style: TextStyle(color: Colors.grey[500], fontSize: 14)),
                            const SizedBox(height: 4),
                            Text('Un agente te responderá pronto',
                                style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                          ],
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollCtrl,
                        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                        itemCount: _messages.length,
                        itemBuilder: (context, i) => _buildBubble(_messages[i]),
                      ),
          ),
          _buildInputBar(),
        ],
      ),
    );
  }

  Widget _buildBubble(_ChatMsg msg) {
    final isUser = msg.isUser;
    return Align(
      alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        constraints: BoxConstraints(maxWidth: MediaQuery.of(context).size.width * 0.78),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isUser ? _gold : const Color(0xFF2A2A2A),
          borderRadius: BorderRadius.only(
            topLeft: const Radius.circular(16),
            topRight: const Radius.circular(16),
            bottomLeft: Radius.circular(isUser ? 16 : 4),
            bottomRight: Radius.circular(isUser ? 4 : 16),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isUser && msg.senderName.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Text(msg.senderName,
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600,
                        color: _gold.withValues(alpha: 0.9))),
              ),
            Text(msg.text,
                style: TextStyle(
                    color: isUser ? Colors.black : Colors.white, fontSize: 14.5, height: 1.35)),
            const SizedBox(height: 3),
            Text(
              '${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}',
              style: TextStyle(fontSize: 10,
                  color: isUser ? Colors.black54 : Colors.grey[600]),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInputBar() {
    return Container(
      padding: EdgeInsets.only(
        left: 12, right: 8, top: 8,
        bottom: MediaQuery.of(context).padding.bottom + 8,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        border: Border(top: BorderSide(color: Colors.grey[800]!, width: 0.5)),
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
              decoration: InputDecoration(
                hintText: 'Escribe tu mensaje...',
                hintStyle: TextStyle(color: Colors.grey[600]),
                filled: true,
                fillColor: const Color(0xFF2A2A2A),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(24),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          const SizedBox(width: 6),
          Material(
            color: _gold,
            shape: const CircleBorder(),
            child: InkWell(
              customBorder: const CircleBorder(),
              onTap: _sendMessage,
              child: const Padding(
                padding: EdgeInsets.all(10),
                child: Icon(Icons.send_rounded, color: Colors.black, size: 20),
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
  final bool isUser;
  final DateTime time;
  final String senderName;
  const _ChatMsg({
    required this.text,
    required this.isUser,
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
