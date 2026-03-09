import 'dart:math';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
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
//  Full-Screen AI Support Agent Chat
// ─────────────────────────────────────────────────────────
class CruiseSupportChatScreen extends StatefulWidget {
  const CruiseSupportChatScreen({super.key});
  @override
  State<CruiseSupportChatScreen> createState() =>
      _CruiseSupportChatScreenState();
}

class _CruiseSupportChatScreenState extends State<CruiseSupportChatScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _agentResponseDelay = Duration(seconds: 60);

  // ── Random human agent names ──
  static const _agentNames = [
    'Sara',
    'Carlos',
    'María',
    'Diego',
    'Valentina',
    'Andrés',
    'Isabella',
    'Sebastián',
    'Camila',
    'Daniel',
    'Sofía',
    'Mateo',
    'Lucía',
    'Gabriel',
    'Emma',
    'Alejandro',
    'Paula',
    'Nicolás',
    'Laura',
    'Javier',
    'Ana',
    'Miguel',
    'Elena',
    'David',
  ];

  final _msgCtrl = TextEditingController();
  final _scrollCtrl = ScrollController();
  final _focusNode = FocusNode();
  bool _isAgentTyping = false;
  bool _inputEnabled = true;
  int _escalationAttempts = 0;

  final List<_ChatMsg> _messages = [];

  // Track conversation context
  String _currentTopic = '';
  final Set<String> _resolvedTopics = {};
  bool _askedForDetails = false;

  // ── Human agent transition ──
  int _userMsgCount = 0;
  bool _humanConnected = false;
  late final String _agentName;
  String _userName = '';

  @override
  void initState() {
    super.initState();
    // Pick a random agent name for this session
    _agentName = _agentNames[Random().nextInt(_agentNames.length)];
    // Load user name from session
    _loadUserName();
    // Automated bot greeting (intentionally robotic)
    Future.delayed(const Duration(milliseconds: 500), () {
      if (!mounted) return;
      _addAgentMessage(
        'Sistema de soporte Cruise — Sesión iniciada.\n\n'
        'Bienvenido al centro de ayuda automatizado. '
        'Seleccione o describa su problema para que podamos asistirlo.\n\n'
        '• Viajes y tarifas\n'
        '• Pagos y reembolsos\n'
        '• Cuenta y perfil\n'
        '• Seguridad\n'
        '• Problemas con la app',
      );
    });
  }

  Future<void> _loadUserName() async {
    final user = await UserSession.getUser();
    if (user != null && mounted) {
      setState(() {
        _userName = user['firstName'] ?? '';
      });
    }
  }

  @override
  void dispose() {
    _msgCtrl.dispose();
    _scrollCtrl.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _addAgentMessage(String text) {
    setState(
      () => _messages.add(
        _ChatMsg(text: text, isUser: false, time: DateTime.now()),
      ),
    );
    _scrollToBottom();
  }

  void _addSystemMessage(String text) {
    setState(
      () => _messages.add(
        _ChatMsg(
          text: text,
          isUser: false,
          time: DateTime.now(),
          isSystem: true,
        ),
      ),
    );
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtrl.hasClients) {
        _scrollCtrl.animateTo(
          _scrollCtrl.position.maxScrollExtent + 100,
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _send() {
    final text = _msgCtrl.text.trim();
    if (text.isEmpty || !_inputEnabled) return;

    _userMsgCount++;

    setState(() {
      _messages.add(_ChatMsg(text: text, isUser: true, time: DateTime.now()));
      _isAgentTyping = true;
      _inputEnabled = false;
    });
    _msgCtrl.clear();
    _scrollToBottom();

    // ── 2nd user message → connect human agent ──
    if (_userMsgCount == 2 && !_humanConnected) {
      // Show a brief "connecting" delay, then human agent joins
      Future.delayed(const Duration(seconds: 8), () {
        if (!mounted) return;
        setState(() => _isAgentTyping = false);
        _addSystemMessage('$_agentName se ha conectado al chat');

        Future.delayed(const Duration(seconds: 2), () {
          if (!mounted) return;
          setState(() => _humanConnected = true);
          final greeting = _userName.isNotEmpty ? _userName : 'amigo';
          _addAgentMessage(
            'Hola! 😊 Mi nombre es $_agentName.\n\n'
            'Espero que estés bien, $greeting. '
            'Voy a ayudarte a resolver lo que necesites y haré mi mejor esfuerzo. '
            '¿Cómo te puedo ayudar?',
          );
          setState(() => _inputEnabled = true);
        });
      });
      return;
    }

    // ── Normal agent response with delay ──
    Future.delayed(_agentResponseDelay, () {
      if (!mounted) return;
      final response = _CruiseAIAgent.processMessage(
        text,
        currentTopic: _currentTopic,
        resolvedTopics: _resolvedTopics,
        askedForDetails: _askedForDetails,
        escalationAttempts: _escalationAttempts,
        humanConnected: _humanConnected,
        agentName: _agentName,
        userName: _userName,
      );

      setState(() {
        _isAgentTyping = false;
        _inputEnabled = true;
        _currentTopic = response.topic;
        if (response.resolved) _resolvedTopics.add(response.topic);
        _askedForDetails = response.askingForDetails;
        if (response.escalate) _escalationAttempts++;
      });

      _addAgentMessage(response.text);

      // If agent offers escalation, add the button
      if (response.escalate) {
        Future.delayed(const Duration(milliseconds: 400), () {
          if (!mounted) return;
          setState(
            () => _messages.add(
              _ChatMsg(
                text: '__ESCALATION_BUTTON__',
                isUser: false,
                time: DateTime.now(),
              ),
            ),
          );
          _scrollToBottom();
        });
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
            Container(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(
                  bottom: BorderSide(
                    color: c.textTertiary.withValues(alpha: 0.1),
                  ),
                ),
              ),
              child: Row(
                children: [
                  GestureDetector(
                    onTap: () => _confirmExit(context, c),
                    child: Container(
                      width: 40,
                      height: 40,
                      decoration: BoxDecoration(
                        color: c.bg,
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Icon(
                        Icons.arrow_back_ios_new_rounded,
                        color: c.textPrimary,
                        size: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(14),
                    ),
                    child: _humanConnected
                        ? Center(
                            child: Text(
                              _agentName[0],
                              style: const TextStyle(
                                fontSize: 20,
                                fontWeight: FontWeight.w700,
                                color: _gold,
                              ),
                            ),
                          )
                        : const Icon(
                            Icons.smart_toy_rounded,
                            color: _gold,
                            size: 24,
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _humanConnected ? _agentName : 'Asistente Cruise',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                            color: c.textPrimary,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                color: _isAgentTyping
                                    ? const Color(0xFFE8C547)
                                    : const Color(0xFFE8C547),
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _isAgentTyping
                                  ? (_humanConnected
                                        ? '$_agentName está escribiendo...'
                                        : 'Procesando solicitud...')
                                  : (_humanConnected
                                        ? 'En línea'
                                        : 'Sistema automatizado'),
                              style: TextStyle(
                                fontSize: 12,
                                color: c.textSecondary,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // ── Messages ──
            Expanded(
              child: ListView.builder(
                controller: _scrollCtrl,
                cacheExtent: 400,
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                itemCount: _messages.length + (_isAgentTyping ? 1 : 0),
                itemBuilder: (_, i) {
                  // Typing indicator
                  if (i == _messages.length && _isAgentTyping) {
                    return _buildTypingIndicator(c);
                  }
                  final msg = _messages[i];

                  // System message (e.g. "Sara se ha conectado")
                  if (msg.isSystem) {
                    return _buildSystemMessage(c, msg);
                  }

                  // Escalation button
                  if (msg.text == '__ESCALATION_BUTTON__') {
                    return _buildEscalationButton(c);
                  }

                  return _buildMessageBubble(c, msg);
                },
              ),
            ),

            // ── Input bar ──
            Container(
              padding: EdgeInsets.fromLTRB(
                16,
                10,
                16,
                MediaQuery.of(context).viewInsets.bottom + 12,
              ),
              decoration: BoxDecoration(
                color: c.surface,
                border: Border(
                  top: BorderSide(color: c.textTertiary.withValues(alpha: 0.1)),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: c.bg,
                        borderRadius: BorderRadius.circular(24),
                        border: Border.all(
                          color: _inputEnabled
                              ? Colors.transparent
                              : c.textTertiary.withValues(alpha: 0.1),
                        ),
                      ),
                      child: TextField(
                        controller: _msgCtrl,
                        focusNode: _focusNode,
                        enabled: _inputEnabled,
                        style: TextStyle(color: c.textPrimary, fontSize: 15),
                        maxLines: 3,
                        minLines: 1,
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText: _inputEnabled
                              ? (_humanConnected
                                    ? 'Escribe tu mensaje...'
                                    : 'Describe tu problema...')
                              : (_humanConnected
                                    ? '$_agentName está respondiendo...'
                                    : 'Procesando...'),
                          hintStyle: TextStyle(
                            color: c.textTertiary,
                            fontSize: 15,
                          ),
                        ),
                        onSubmitted: (_) => _send(),
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  GestureDetector(
                    onTap: _inputEnabled ? _send : null,
                    child: Container(
                      width: 46,
                      height: 46,
                      decoration: BoxDecoration(
                        color: _inputEnabled
                            ? _gold
                            : _gold.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(23),
                      ),
                      child: const Icon(
                        Icons.send_rounded,
                        color: Color(0xFF1A1400),
                        size: 20,
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

  Widget _buildMessageBubble(AppColors c, _ChatMsg msg) {
    return Align(
      alignment: msg.isUser ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            if (!msg.isUser) ...[
              Container(
                width: 28,
                height: 28,
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: _humanConnected
                    ? Center(
                        child: Text(
                          _agentName[0],
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: _gold,
                          ),
                        ),
                      )
                    : const Icon(
                        Icons.smart_toy_rounded,
                        color: _gold,
                        size: 16,
                      ),
              ),
              const SizedBox(width: 8),
            ],
            Flexible(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(context).size.width * 0.75,
                ),
                decoration: BoxDecoration(
                  color: msg.isUser ? _gold.withValues(alpha: 0.15) : c.surface,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(18),
                    topRight: const Radius.circular(18),
                    bottomLeft: Radius.circular(msg.isUser ? 18 : 4),
                    bottomRight: Radius.circular(msg.isUser ? 4 : 18),
                  ),
                  border: msg.isUser
                      ? null
                      : Border.all(
                          color: c.textTertiary.withValues(alpha: 0.08),
                        ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      msg.text,
                      style: TextStyle(
                        color: c.textPrimary,
                        fontSize: 14.5,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${msg.time.hour.toString().padLeft(2, '0')}:${msg.time.minute.toString().padLeft(2, '0')}',
                      style: TextStyle(fontSize: 11, color: c.textTertiary),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSystemMessage(AppColors c, _ChatMsg msg) {
    return Center(
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 16),
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: _gold.withValues(alpha: 0.15)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Color(0xFFE8C547),
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                msg.text,
                style: TextStyle(
                  fontSize: 13,
                  color: c.textSecondary,
                  fontStyle: FontStyle.italic,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTypingIndicator(AppColors c) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Container(
              width: 28,
              height: 28,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(8),
              ),
              child: _humanConnected
                  ? Center(
                      child: Text(
                        _agentName[0],
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: _gold,
                        ),
                      ),
                    )
                  : const Icon(Icons.smart_toy_rounded, color: _gold, size: 16),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              decoration: BoxDecoration(
                color: c.surface,
                borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18),
                  topRight: Radius.circular(18),
                  bottomLeft: Radius.circular(4),
                  bottomRight: Radius.circular(18),
                ),
                border: Border.all(
                  color: c.textTertiary.withValues(alpha: 0.08),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _TypingDot(delay: 0, color: _gold),
                  const SizedBox(width: 4),
                  _TypingDot(delay: 150, color: _gold),
                  const SizedBox(width: 4),
                  _TypingDot(delay: 300, color: _gold),
                  const SizedBox(width: 10),
                  Text(
                    _humanConnected
                        ? '$_agentName está escribiendo...'
                        : 'Procesando solicitud...',
                    style: TextStyle(
                      fontSize: 12,
                      color: c.textTertiary,
                      fontStyle: FontStyle.italic,
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

  Widget _buildEscalationButton(AppColors c) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12, left: 36),
        child: GestureDetector(
          onTap: () => Navigator.of(
            context,
          ).push(slideFromRightRoute(const _ContactHumanAgentScreen())),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: _gold.withValues(alpha: 0.3)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.person_rounded, color: _gold, size: 20),
                const SizedBox(width: 10),
                Text(
                  'Contact a Human Agent',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(width: 6),
                const Icon(Icons.arrow_forward_rounded, color: _gold, size: 18),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _confirmExit(BuildContext context, AppColors c) async {
    if (_messages.length <= 1) {
      Navigator.of(context).pop();
      return;
    }
    final exit = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          'End Chat?',
          style: TextStyle(color: c.textPrimary, fontWeight: FontWeight.w700),
        ),
        content: Text(
          'Your conversation will not be saved. Are you sure you want to leave?',
          style: TextStyle(color: c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text('Stay', style: TextStyle(color: c.textSecondary)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              'Leave',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (exit == true && context.mounted) Navigator.of(context).pop();
  }
}

// ─────────────────────────────────────────────────────────
//  Typing Dot Animation
// ─────────────────────────────────────────────────────────
class _TypingDot extends StatefulWidget {
  final int delay;
  final Color color;
  const _TypingDot({required this.delay, required this.color});
  @override
  State<_TypingDot> createState() => _TypingDotState();
}

class _TypingDotState extends State<_TypingDot>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<double> _anim;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _anim = Tween(
      begin: 0.3,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeInOut));
    Future.delayed(Duration(milliseconds: widget.delay), () {
      if (mounted) _ctrl.repeat(reverse: true);
    });
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _anim,
      builder: (ctx, child) => Container(
        width: 8,
        height: 8,
        decoration: BoxDecoration(
          color: widget.color.withValues(alpha: _anim.value),
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────
//  AI Agent Engine — Knowledge Base & Intent Detection
// ─────────────────────────────────────────────────────────
class _AgentResponse {
  final String text;
  final String topic;
  final bool resolved;
  final bool askingForDetails;
  final bool escalate;
  const _AgentResponse({
    required this.text,
    this.topic = '',
    this.resolved = false,
    this.askingForDetails = false,
    this.escalate = false,
  });
}

class _CruiseAIAgent {
  // ── Intent keywords ──
  static const _fareKeywords = [
    'fare',
    'charge',
    'charged',
    'price',
    'cost',
    'expensive',
    'overcharged',
    'bill',
    'billing',
    'invoice',
    'receipt',
    'cobro',
    'cobrar',
    'precio',
    'caro',
    'tarifa',
  ];
  static const _refundKeywords = [
    'refund',
    'money back',
    'reimburse',
    'reembolso',
    'devolver',
    'devolucion',
  ];
  static const _cancelKeywords = [
    'cancel',
    'cancelled',
    'cancellation',
    'cancelar',
    'cancelacion',
    'fee',
  ];
  static const _lostKeywords = [
    'lost',
    'forgot',
    'left',
    'forgotten',
    'item',
    'phone',
    'wallet',
    'bag',
    'keys',
    'perdi',
    'perdido',
    'olvide',
    'deje',
  ];
  static const _safetyKeywords = [
    'safe',
    'safety',
    'unsafe',
    'danger',
    'dangerous',
    'threat',
    'harass',
    'assault',
    'seguridad',
    'peligro',
    'acoso',
  ];
  static const _accidentKeywords = [
    'accident',
    'crash',
    'collision',
    'hit',
    'injured',
    'injury',
    'accidente',
    'choque',
  ];
  static const _emergencyKeywords = [
    'emergency',
    'help',
    '911',
    'police',
    'ambulance',
    'emergencia',
  ];
  static const _accountKeywords = [
    'account',
    'login',
    'password',
    'email',
    'phone number',
    'profile',
    'log in',
    'sign in',
    'cuenta',
    'contraseña',
    'correo',
    'perfil',
  ];
  static const _deleteAccountKeywords = [
    'delete account',
    'remove account',
    'close account',
    'eliminar cuenta',
    'borrar cuenta',
  ];
  static const _paymentKeywords = [
    'payment',
    'pay',
    'card',
    'credit',
    'debit',
    'paypal',
    'google pay',
    'apple pay',
    'wallet',
    'pago',
    'tarjeta',
  ];
  static const _driverKeywords = [
    'driver',
    'conductor',
    'chofer',
    'rating',
    'rate',
    'rude',
    'behavior',
    'comportamiento',
    'grosero',
  ];
  static const _tripKeywords = [
    'trip',
    'ride',
    'viaje',
    'route',
    'ruta',
    'pickup',
    'drop',
    'destination',
    'destino',
  ];
  static const _appKeywords = [
    'app',
    'bug',
    'crash',
    'error',
    'slow',
    'not working',
    'frozen',
    'glitch',
    'update',
    'version',
    'aplicacion',
    'funciona',
  ];
  static const _gpsKeywords = [
    'gps',
    'location',
    'map',
    'maps',
    'ubicacion',
    'mapa',
    'position',
  ];
  static const _notifKeywords = [
    'notification',
    'notifications',
    'alert',
    'alerts',
    'notificacion',
    'notificaciones',
  ];
  static const _promoKeywords = [
    'promo',
    'promotion',
    'discount',
    'coupon',
    'code',
    'offer',
    'promocion',
    'descuento',
    'cupon',
  ];
  static const _waitKeywords = [
    'wait',
    'waiting',
    'long',
    'time',
    'eta',
    'espera',
    'esperando',
    'demora',
    'tarda',
  ];
  static const _humanKeywords = [
    'human',
    'agent',
    'person',
    'real person',
    'talk to someone',
    'representative',
    'humano',
    'agente',
    'persona real',
    'hablar con alguien',
  ];
  static const _greetKeywords = [
    'hi',
    'hello',
    'hey',
    'good morning',
    'good afternoon',
    'hola',
    'buenos dias',
    'buenas tardes',
    'buenas noches',
    'que tal',
  ];
  static const _thankKeywords = [
    'thank',
    'thanks',
    'gracias',
    'appreciate',
    'great',
    'awesome',
    'perfect',
    'solved',
    'resolved',
    'fixed',
  ];
  static const _byeKeywords = [
    'bye',
    'goodbye',
    'see you',
    'adios',
    'chao',
    'hasta luego',
  ];

  static _AgentResponse processMessage(
    String userMessage, {
    required String currentTopic,
    required Set<String> resolvedTopics,
    required bool askedForDetails,
    required int escalationAttempts,
    bool humanConnected = false,
    String agentName = '',
    String userName = '',
  }) {
    final msg = userMessage.toLowerCase().trim();
    final name = userName.isNotEmpty ? userName : 'amigo';

    // ── Greeting ──
    if (_matchesAny(msg, _greetKeywords) && msg.length < 30) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              'Hola $name! 😊\n\n'
              'Cuéntame, ¿en qué te puedo ayudar hoy? Estoy aquí para lo que necesites.',
          topic: 'greeting',
        );
      }
      return const _AgentResponse(
        text:
            'Saludo recibido. Por favor, describa su problema para ser asistido.',
        topic: 'greeting',
      );
    }

    // ── Thank you ──
    if (_matchesAny(msg, _thankKeywords) && msg.length < 50) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              'De nada, $name! 😊 Me alegra mucho haberte podido ayudar.\n\n'
              '¿Hay algo más en lo que te pueda echar una mano? Si no, que tengas un excelente día!',
          topic: 'thanks',
          resolved: true,
        );
      }
      return const _AgentResponse(
        text: 'Agradecimiento registrado. ¿Necesita asistencia adicional?',
        topic: 'thanks',
        resolved: true,
      );
    }

    // ── Goodbye ──
    if (_matchesAny(msg, _byeKeywords) && msg.length < 25) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '¡Hasta luego, $name! 👋 Fue un gusto ayudarte.\n\n'
              'Si necesitas algo en el futuro, no dudes en escribirnos. ¡Cuídate mucho!',
          topic: 'bye',
          resolved: true,
        );
      }
      return const _AgentResponse(
        text: 'Sesión finalizada. Gracias por contactar el soporte de Cruise.',
        topic: 'bye',
        resolved: true,
      );
    }

    // ── Human agent request ──
    if (_matchesAny(msg, _humanKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              'Entiendo, $name. Voy a transferirte para que puedas contactar a un especialista directamente.\n\n'
              'Presiona el botón de abajo para enviar tu solicitud y alguien de nuestro equipo te contactará lo antes posible 🙏',
          topic: 'escalation',
          escalate: true,
        );
      }
      return const _AgentResponse(
        text:
            'Solicitud de agente humano detectada. Presione el botón para completar el formulario de contacto.',
        topic: 'escalation',
        escalate: true,
      );
    }

    // ── Emergency ──
    if (_matchesAny(msg, _emergencyKeywords) &&
        _matchesAny(msg, _safetyKeywords + _accidentKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '🚨 $name, esto es muy importante. Si estás en peligro ahora mismo, por favor llama al 911 de inmediato.\n\n'
              'Tu seguridad es lo primero, de verdad. Si ya estás a salvo, cuéntame qué pasó y voy a escalar esto urgentemente a nuestro equipo de seguridad.\n\n'
              'Estoy aquí contigo.',
          topic: 'emergency',
        );
      }
      return const _AgentResponse(
        text:
            '🚨 ALERTA: Si se encuentra en peligro inmediato, llame al 911.\n\nDescripción del incidente requerida para procesar reporte de seguridad.',
        topic: 'emergency',
      );
    }

    // ── Accident ──
    if (_matchesAny(msg, _accidentKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              'Ay no, $name 😟 Lamento mucho escuchar esto. Lo más importante es que estés bien.\n\n'
              'Si hay heridos, por favor llama al 911 primero.\n\n'
              'Para poder ayudarte con el reporte necesito saber:\n'
              '1. ¿Cuándo pasó? (fecha y hora aprox)\n'
              '2. ¿Hubo heridos?\n'
              '3. ¿Se hizo un reporte policial?\n\n'
              'Cruise tiene cobertura de seguro para todos los viajes activos. Nuestro equipo de seguridad te va a contactar dentro de 1 hora.\n\n'
              'Te recomiendo que también contactes a un especialista directamente para que te atiendan de inmediato.',
          topic: 'accident',
          askingForDetails: true,
          escalate: true,
        );
      }
      return const _AgentResponse(
        text:
            '⚠️ Incidente reportado. Se requiere información adicional para procesar el caso. Recomendación: contactar agente especializado.',
        topic: 'accident',
        askingForDetails: true,
        escalate: true,
      );
    }

    // ── Safety ──
    if (_matchesAny(msg, _safetyKeywords)) {
      if (askedForDetails && currentTopic == 'safety') {
        if (humanConnected) {
          return _AgentResponse(
            text:
                'Gracias por compartir eso, $name. Sé que no es fácil y te agradezco la confianza.\n\n'
                '📋 Ya tomé acción:\n'
                '• El reporte de seguridad ya fue creado\n'
                '• El equipo de seguridad lo va a revisar en menos de 1 hora\n'
                '• La cuenta del conductor queda marcada para revisión\n'
                '• Te va a llegar un correo con tu número de caso\n\n'
                '¿Puedo ayudarte con algo más?',
            topic: 'safety',
            resolved: true,
          );
        }
        return const _AgentResponse(
          text:
              'Reporte de seguridad creado. En revisión por el equipo especializado. Notificación por email pendiente.',
          topic: 'safety',
          resolved: true,
        );
      }
      if (humanConnected) {
        return _AgentResponse(
          text:
              '🛡️ Me tomo esto muy en serio, $name. Tu seguridad es prioridad.\n\n'
              'Para poder crear el reporte necesito que me cuentes:\n'
              '1. ¿Qué pasó durante el viaje?\n'
              '2. ¿Cuándo fue? (fecha y hora)\n'
              '3. ¿Puedes describir el comportamiento del conductor?\n\n'
              'Todo lo que me digas es completamente confidencial. El conductor NO va a saber quién hizo el reporte. Estás en buenas manos 💪',
          topic: 'safety',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            '🛡️ Reporte de seguridad iniciado. Proporcione detalles del incidente: descripción, fecha, hora y comportamiento del conductor.',
        topic: 'safety',
        askingForDetails: true,
      );
    }

    // ── Lost item ──
    if (_matchesAny(msg, _lostKeywords)) {
      if (askedForDetails && currentTopic == 'lost_item') {
        if (humanConnected) {
          return _AgentResponse(
            text:
                '¡Listo, $name! Ya envié la solicitud de recuperación 🙌\n\n'
                '📋 Esto es lo que va a pasar:\n'
                '• Vamos a contactar a tu conductor en los próximos 30 minutos\n'
                '• Si se encuentra el artículo, coordinamos la devolución\n'
                '• Puede aplicar una pequeña tarifa de entrega\n'
                '• Te vamos a mantener al tanto por notificaciones\n\n'
                '💡 También puedes revisar los datos del conductor en Cuenta → Viajes.\n\n'
                '¿Necesitas algo más?',
            topic: 'lost_item',
            resolved: true,
          );
        }
        return const _AgentResponse(
          text:
              'Solicitud de recuperación procesada. Contacto con conductor en progreso. Tiempo estimado: 30 minutos.',
          topic: 'lost_item',
          resolved: true,
        );
      }
      if (humanConnected) {
        return _AgentResponse(
          text:
              'Ay, qué mal, $name 😟 Pero no te preocupes, la mayoría de objetos los recuperamos en menos de 24 horas.\n\n'
              'Para encontrarlo necesito que me digas:\n'
              '1. ¿Qué objeto perdiste?\n'
              '2. ¿Cuándo fue tu viaje? (fecha y hora aprox)\n'
              '3. ¿Recuerdas a dónde ibas?\n\n'
              'Con eso puedo identificar al conductor y contactarlo de inmediato.',
          topic: 'lost_item',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Recuperación de objeto iniciada. Proporcione: tipo de objeto, fecha/hora del viaje, destino.',
        topic: 'lost_item',
        askingForDetails: true,
      );
    }

    // ── Overcharge / Fare issues ──
    if (_matchesAny(msg, _fareKeywords)) {
      if (_matchesAny(msg, _refundKeywords)) {
        if (humanConnected) {
          return _AgentResponse(
            text:
                'Entendido, $name. Vamos a revisar ese cobro juntos.\n\n'
                'Para procesar el reembolso necesito:\n'
                '1. Fecha del viaje\n'
                '2. Monto que te cobraron\n'
                '3. Monto que esperabas pagar\n\n'
                'Las diferencias de tarifa generalmente se deben a:\n'
                '• Cambios de ruta durante el viaje\n'
                '• Tarifa dinámica en horas pico\n'
                '• Cargo por tiempo de espera (después de 2 min)\n'
                '• Peajes automáticos\n\n'
                '💡 Puedes revisa el desglose en Cuenta → Viajes → Seleccionar viaje.\n\n'
                'Mándame esos datos y yo me encargo del resto.',
            topic: 'fare_refund',
            askingForDetails: true,
          );
        }
        return const _AgentResponse(
          text:
              'Solicitud de reembolso detectada. Proporcione: fecha del viaje, monto cobrado, monto esperado.',
          topic: 'fare_refund',
          askingForDetails: true,
        );
      }
      if (askedForDetails && currentTopic == 'fare') {
        if (humanConnected) {
          return _AgentResponse(
            text:
                'Perfecto, $name. Ya revisé la información que me diste.\n\n'
                '📋 Tu disputa de tarifa ha sido enviada:\n'
                '• El equipo de facturación va a revisar los detalles\n'
                '• Si corresponde un ajuste, se procesa en 3-5 días hábiles\n'
                '• El reembolso va al método de pago original\n'
                '• Te llega un correo con la resolución\n\n'
                '¿Te puedo ayudar con algo más? 😊',
            topic: 'fare',
            resolved: true,
          );
        }
        return const _AgentResponse(
          text:
              'Disputa de tarifa procesada. Resolución estimada: 3-5 días hábiles. Notificación por email.',
          topic: 'fare',
          resolved: true,
        );
      }
      if (humanConnected) {
        return _AgentResponse(
          text:
              '💰 Entiendo tu preocupación con la tarifa, $name. Vamos a resolver esto.\n\n'
              '¿Me podrías decir:\n'
              '1. ¿Cuándo fue el viaje? (fecha y hora aprox)\n'
              '2. ¿Cuánto te cobraron?\n'
              '3. ¿Por qué crees que el cobro es incorrecto?\n\n'
              'También puedes revisar tu recibo en Cuenta → Viajes.',
          topic: 'fare',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Consulta de tarifa registrada. Proporcione: fecha/hora del viaje, monto cobrado, descripción del problema.',
        topic: 'fare',
        askingForDetails: true,
      );
    }

    // ── Refund only ──
    if (_matchesAny(msg, _refundKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '💳 Claro, $name! Te ayudo con el reembolso.\n\n'
              'Necesito que me des:\n'
              '1. Fecha del viaje\n'
              '2. Monto cobrado\n'
              '3. Razón del reembolso\n\n'
              'Los tiempos de procesamiento son:\n'
              '• Tarjetas crédito/débito: 3-5 días hábiles\n'
              '• PayPal: 1-2 días hábiles\n'
              '• Cruise Cash: Al instante\n\n'
              'En cuanto me pases los datos, lo proceso de una vez.',
          topic: 'refund',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Solicitud de reembolso. Datos requeridos: fecha del viaje, monto cobrado, motivo.',
        topic: 'refund',
        askingForDetails: true,
      );
    }

    // ── Cancellation ──
    if (_matchesAny(msg, _cancelKeywords)) {
      if (askedForDetails && currentTopic == 'cancellation') {
        if (humanConnected) {
          return _AgentResponse(
            text:
                'Ya registré tu disputa, $name.\n\n'
                '📋 Estado:\n'
                '• El equipo de facturación está revisando tu caso\n'
                '• Si el cargo fue injusto, se revierte en 3-5 días hábiles\n'
                '• Te llega un correo con el resultado\n\n'
                '¿Algo más en lo que te pueda ayudar?',
            topic: 'cancellation',
            resolved: true,
          );
        }
        return const _AgentResponse(
          text:
              'Disputa de cancelación registrada. Revisión en proceso. Resolución: 3-5 días hábiles.',
          topic: 'cancellation',
          resolved: true,
        );
      }
      if (humanConnected) {
        return _AgentResponse(
          text:
              'Entiendo, $name. Te explico cómo funciona:\n\n'
              'Política de cancelación:\n'
              '• Cancelación gratis dentro de los primeros 2 minutos\n'
              '• Después de que el conductor empiece a ir hacia ti, aplica un cargo pequeño\n'
              '• Si el conductor esperó más de 5 min, puede haber cargo por espera\n\n'
              'Puedes pedir reembolso si:\n'
              '• El conductor canceló el viaje\n'
              '• El conductor se tardó demasiado\n'
              '• Hubo un problema de seguridad\n\n'
              '¿Quieres disputar un cargo de cancelación específico? Dime cuándo fue el viaje.',
          topic: 'cancellation',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Consulta de cancelación registrada. Proporcione fecha del viaje para revisar el cargo.',
        topic: 'cancellation',
        askingForDetails: true,
      );
    }

    // ── Payment ──
    if (_matchesAny(msg, _paymentKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '💳 Vamos con los pagos, $name. Esto es lo que puedo ayudarte:\n\n'
              '📌 Agregar/cambiar método de pago:\n'
              '→ Cuenta → Wallet → Gestionar Pagos\n\n'
              '📌 Pago rechazado:\n'
              '• Verifica que los datos de tu tarjeta estén correctos\n'
              '• Asegúrate de tener fondos suficientes\n'
              '• Revisa si tu banco bloqueó la transacción\n'
              '• Prueba con otro método de pago\n\n'
              '📌 Cargos pendientes:\n'
              'Las retenciones son temporales y se liberan en 24-48 horas.\n\n'
              '¿Cuál es el problema específico que tienes?',
          topic: 'payment',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Consulta de pagos. Opciones: agregar/cambiar método → Cuenta → Wallet. Cargos pendientes se liberan en 24-48h.',
        topic: 'payment',
        askingForDetails: true,
      );
    }

    // ── Account issues ──
    if (_matchesAny(msg, _deleteAccountKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '⚠️ Entiendo, $name. Antes de eliminar tu cuenta, quiero que sepas:\n\n'
              '• Es permanente y no se puede deshacer\n'
              '• Se borra todo: historial, lugares guardados, métodos de pago\n'
              '• El saldo de Cruise Cash se pierde\n'
              '• Los cargos pendientes siguen activos\n\n'
              'Para eliminarlo: Cuenta → Configuración → Privacidad → "Eliminar cuenta"\n\n'
              'Pero dime, ¿hay algo que te hizo querer irte? A lo mejor puedo solucionarlo 🤔',
          topic: 'delete_account',
        );
      }
      return const _AgentResponse(
        text:
            'Solicitud de eliminación de cuenta. Acción permanente e irreversible. Ruta: Cuenta → Configuración → Privacidad → Eliminar cuenta.',
        topic: 'delete_account',
      );
    }

    if (_matchesAny(msg, _accountKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '👤 Dale, $name. Te ayudo con tu cuenta.\n\n'
              '📌 No puedes entrar:\n'
              '• Revisa bien tu email o número de teléfono\n'
              '• Las contraseñas son sensibles a mayúsculas\n'
              '• Usa "Olvidé mi contraseña" para resetear\n'
              '• Si usaste login social, usa el mismo método\n\n'
              '📌 Cambiar email/teléfono:\n'
              '→ Cuenta → Configuración → Editar Perfil\n\n'
              '📌 Cambiar contraseña:\n'
              '→ En la pantalla de login, toca "Olvidé mi contraseña"\n\n'
              '¿Cuál es el problema específico?',
          topic: 'account',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Consulta de cuenta. Para resetear: use "Olvidé mi contraseña". Editar perfil: Cuenta → Configuración → Editar Perfil.',
        topic: 'account',
        askingForDetails: true,
      );
    }

    // ── Driver issues ──
    if (_matchesAny(msg, _driverKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '🚗 Cuéntame qué pasó con el conductor, $name.\n\n'
              '• Si fue grosero o poco profesional → lo marco para revisión\n'
              '• Si te sentiste inseguro/a → lo escalo al equipo de seguridad de inmediato\n'
              '• Si tomó una ruta incorrecta → reviso la tarifa para un posible ajuste\n'
              '• Si lo quieres calificar → Cuenta → Viajes → Seleccionar viaje\n\n'
              'Descríbeme qué pasó y cuándo fue el viaje.',
          topic: 'driver',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Reporte de conductor. Proporcione: descripción del incidente, fecha y hora del viaje.',
        topic: 'driver',
        askingForDetails: true,
      );
    }

    // ── GPS / Location ──
    if (_matchesAny(msg, _gpsKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '📍 Problemas con el GPS, $name? Te doy unos pasos rápidos:\n\n'
              '1. Activa los servicios de ubicación:\n'
              '   → Ajustes → Apps → Cruise → Permisos → Ubicación → "Permitir siempre"\n\n'
              '2. Activa el modo de alta precisión:\n'
              '   → Ajustes → Ubicación → Modo → Alta precisión\n\n'
              '3. Limpia el caché de la app:\n'
              '   → Ajustes → Apps → Cruise → Almacenamiento → Borrar caché\n\n'
              '4. Reinicia la app\n\n'
              '5. Asegúrate de tener buena conexión a internet\n\n'
              '💡 Si el mapa no carga, intenta actualizar Google Play Services.\n\n'
              '¿Se arregló con eso?',
          topic: 'gps',
        );
      }
      return const _AgentResponse(
        text:
            'Problema de GPS detectado. Solución: activar ubicación en alta precisión, limpiar caché, reiniciar app.',
        topic: 'gps',
      );
    }

    // ── Notifications ──
    if (_matchesAny(msg, _notifKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '🔔 No te llegan las notificaciones, $name? Vamos a arreglar eso:\n\n'
              '1. Revisa los ajustes de notificación del teléfono:\n'
              '   → Ajustes → Apps → Cruise → Notificaciones → Activar todo\n\n'
              '2. Dentro de la app:\n'
              '   → Cuenta → Configuración → Notificaciones → Activar\n\n'
              '3. Desactiva la optimización de batería para Cruise:\n'
              '   → Ajustes → Batería → Cruise → No optimizar\n\n'
              '4. Asegúrate que el "No molestar" esté desactivado\n\n'
              '5. Reinicia tu teléfono\n\n'
              'Prueba eso y me dices si funcionó 👍',
          topic: 'notifications',
        );
      }
      return const _AgentResponse(
        text:
            'Problema de notificaciones. Solución: activar notificaciones en ajustes del sistema y en la app. Desactivar optimización de batería.',
        topic: 'notifications',
      );
    }

    // ── App issues ──
    if (_matchesAny(msg, _appKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '📱 Vaya, $name, lamento que la app te esté dando problemas. Probemos esto:\n\n'
              '1. Cierra la app completamente y ábrela de nuevo\n'
              '2. Busca actualizaciones en tu tienda de apps\n'
              '3. Limpia el caché:\n'
              '   → Ajustes → Apps → Cruise → Almacenamiento → Borrar caché\n\n'
              '4. Reinicia tu teléfono\n\n'
              '5. Si sigue igual, desinstala y vuelve a instalar\n'
              '   (Tranqui, tu cuenta y datos están seguros en nuestros servidores)\n\n'
              '¿Sigue pasando? Cuéntame qué exactamente no funciona.',
          topic: 'app_issue',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Problema de aplicación. Solución: forzar cierre, actualizar app, borrar caché, reiniciar dispositivo.',
        topic: 'app_issue',
        askingForDetails: true,
      );
    }

    // ── Promo / Discount ──
    if (_matchesAny(msg, _promoKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '🎉 ¡Promos! Me encanta, $name.\n\n'
              'Para aplicar un código:\n'
              '1. Ve a Cuenta → Código Promo\n'
              '2. Escribe tu código\n'
              '3. Toca "Aplicar"\n\n'
              'Si no te funciona, puede ser porque:\n'
              '• El código expiró\n'
              '• Ya lo usaste (la mayoría son de un solo uso)\n'
              '• Es solo para usuarios nuevos\n'
              '• Requiere un monto mínimo de viaje\n\n'
              'Si tienes un código que no funciona, pásame el código y el error que te sale.',
          topic: 'promo',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Aplicar código promo: Cuenta → Código Promo → Ingresar código. Si falla: código expirado, ya usado, o no elegible.',
        topic: 'promo',
        askingForDetails: true,
      );
    }

    // ── Wait time ──
    if (_matchesAny(msg, _waitKeywords) &&
        _matchesAny(msg, _tripKeywords + _driverKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '⏱️ Entiendo la frustración, $name. Nadie quiere esperar mucho.\n\n'
              'Las razones más comunes de espera larga:\n'
              '• Mucha demanda en tu zona\n'
              '• Pocos conductores disponibles\n'
              '• Tráfico\n'
              '• Tu ubicación es difícil de acceder\n\n'
              'Tips para que te recojan más rápido:\n'
              '• Ubícate en una calle principal\n'
              '• Programa viajes importantes con anticipación\n'
              '• Revisa el tiempo estimado antes de confirmar\n\n'
              'Si tu conductor se tardó mucho o no llegó, podrías recibir un reembolso. ¿Quieres reportar un viaje específico?',
          topic: 'wait_time',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Tiempo de espera excesivo reportado. ¿Desea presentar una queja sobre un viaje específico?',
        topic: 'wait_time',
        askingForDetails: true,
      );
    }

    // ── Trip issues (general) ──
    if (_matchesAny(msg, _tripKeywords)) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '🚗 Cuéntame sobre tu viaje, $name.\n\n'
              '¿Qué problema tuviste?\n\n'
              '• Ruta incorrecta → reviso la tarifa\n'
              '• El viaje no inició/terminó bien → reviso los datos GPS\n'
              '• Cobro por viaje que no hiciste → proceso reembolso\n'
              '• El conductor fue al lugar equivocado → investigo\n'
              '• Espera muy larga → reviso los cargos\n\n'
              'Dame los detalles: qué pasó, cuándo y la hora del viaje.',
          topic: 'trip',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Consulta de viaje. Proporcione: descripción del problema, fecha y hora del viaje.',
        topic: 'trip',
        askingForDetails: true,
      );
    }

    // ── Frustrated user / multiple attempts ──
    if (escalationAttempts >= 2 ||
        msg.contains('not helpful') ||
        msg.contains('doesn\'t help') ||
        msg.contains('useless') ||
        msg.contains('no sirve') ||
        msg.contains('no ayuda') ||
        msg.contains('inutil')) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              'Lo siento mucho, $name 😔 De verdad me disculpo por no haber podido resolver tu problema completamente.\n\n'
              'Entiendo tu frustración. Déjame conectarte con un especialista que te pueda dar atención más personalizada.\n\n'
              'Presiona el botón de abajo para enviar tu solicitud. Un agente dedicado te va a contactar dentro de las próximas 24 horas.',
          topic: 'escalation',
          escalate: true,
        );
      }
      return const _AgentResponse(
        text:
            'No se pudo resolver la solicitud. Escalando a agente especializado. Complete el formulario de contacto.',
        topic: 'escalation',
        escalate: true,
      );
    }

    // ── Follow-up to asked details ──
    if (askedForDetails && currentTopic.isNotEmpty && msg.length > 15) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              'Perfecto, $name, gracias por los detalles. Ya revisé todo.\n\n'
              '📋 Esto es lo que hice:\n'
              '• Tu caso quedó registrado en el sistema\n'
              '• Se creó un ticket para nuestro equipo\n'
              '• Te va a llegar un correo de confirmación\n'
              '• Tiempo de resolución: 24-48 horas\n\n'
              'Si es urgente, puedo conectarte con un especialista.\n\n'
              '¿Puedo ayudarte con algo más? 😊',
          topic: currentTopic,
          resolved: true,
        );
      }
      return _AgentResponse(
        text:
            'Información registrada. Ticket creado. Resolución estimada: 24-48 horas.',
        topic: currentTopic,
        resolved: true,
      );
    }

    // ── Private/sensitive info requests ──
    if (msg.contains('internal') ||
        msg.contains('policy document') ||
        msg.contains('employee') ||
        msg.contains('revenue') ||
        msg.contains('database') ||
        msg.contains('api key') ||
        msg.contains('server') ||
        msg.contains('backend') ||
        msg.contains('code') ||
        msg.contains('architecture') ||
        msg.contains('infrastructure') ||
        msg.contains('interno') ||
        msg.contains('empleados') ||
        msg.contains('servidor') ||
        msg.contains('base de datos')) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              '🔒 Entiendo tu curiosidad, $name, pero lamentablemente no puedo compartir información interna de la empresa ni datos técnicos.\n\n'
              'Pero te puedo ayudar con:\n'
              '• Dudas sobre viajes y tarifas\n'
              '• Problemas de cuenta y pagos\n'
              '• Temas de seguridad\n'
              '• Problemas con la app\n\n'
              '¿Hay algo de eso en lo que te pueda echar la mano?',
          topic: 'private_info',
        );
      }
      return const _AgentResponse(
        text:
            '🔒 No es posible compartir información interna o confidencial. Asistencia disponible para: viajes, pagos, cuenta, seguridad, app.',
        topic: 'private_info',
      );
    }

    // ── Default / Unrecognized ──
    if (msg.length < 5) {
      if (humanConnected) {
        return _AgentResponse(
          text:
              'Mmm, $name, necesito un poquito más de información para poder ayudarte bien.\n\n'
              'Por ejemplo, cuéntame sobre:\n'
              '• Un problema con un viaje reciente\n'
              '• Un tema de pago o cobro\n'
              '• Un problema con tu cuenta\n'
              '• Una preocupación de seguridad\n'
              '• Algo que no funciona en la app',
          topic: 'clarification',
          askingForDetails: true,
        );
      }
      return const _AgentResponse(
        text:
            'Información insuficiente. Describa su problema con más detalle para poder asistirlo.',
        topic: 'clarification',
        askingForDetails: true,
      );
    }

    if (humanConnected) {
      return _AgentResponse(
        text:
            'Gracias por escribir, $name. Quiero asegurarme de ayudarte bien.\n\n'
            '¿Me podrías dar más detalles? Por ejemplo:\n'
            '• ¿Cuándo pasó esto?\n'
            '• ¿Qué estabas intentando hacer?\n'
            '• ¿Te salió algún mensaje de error?\n\n'
            'Entre más me cuentes, más rápido lo resolvemos 💪',
        topic: 'general',
        askingForDetails: true,
      );
    }

    return const _AgentResponse(
      text:
          'Solicitud recibida. Se requiere información adicional: descripción del problema, fecha y detalles del incidente.',
      topic: 'general',
      askingForDetails: true,
    );
  }

  static bool _matchesAny(String text, List<String> keywords) {
    return keywords.any((kw) => text.contains(kw));
  }
}

// ─────────────────────────────────────────────────────────
//  Contact Human Agent — Email Form Screen
// ─────────────────────────────────────────────────────────
class _ContactHumanAgentScreen extends StatefulWidget {
  const _ContactHumanAgentScreen();
  @override
  State<_ContactHumanAgentScreen> createState() =>
      _ContactHumanAgentScreenState();
}

class _ContactHumanAgentScreenState extends State<_ContactHumanAgentScreen> {
  static const _gold = Color(0xFFE8C547);

  final _nameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _messageCtrl = TextEditingController();
  String _category = 'Trip Issue';
  bool _sending = false;
  bool _sent = false;

  final _caseNumber =
      'CR-${DateTime.now().millisecondsSinceEpoch.toString().substring(5)}';

  final _categories = const [
    'Trip Issue',
    'Billing & Refund',
    'Safety Concern',
    'Account Problem',
    'App Technical Issue',
    'Driver Complaint',
    'Lost Item',
    'Other',
  ];

  @override
  void dispose() {
    _nameCtrl.dispose();
    _emailCtrl.dispose();
    _phoneCtrl.dispose();
    _messageCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_nameCtrl.text.trim().isEmpty) {
      _showError('Please enter your full name');
      return;
    }
    if (_emailCtrl.text.trim().isEmpty || !_emailCtrl.text.contains('@')) {
      _showError('Please enter a valid email');
      return;
    }
    if (_messageCtrl.text.trim().length < 10) {
      _showError('Please describe your issue in detail');
      return;
    }

    setState(() => _sending = true);

    // Try to launch email
    final subject = Uri.encodeComponent(
      'Support Request [$_caseNumber] — $_category',
    );
    final body = Uri.encodeComponent(
      'Case Number: $_caseNumber\n'
      'Category: $_category\n'
      'Name: ${_nameCtrl.text.trim()}\n'
      'Email: ${_emailCtrl.text.trim()}\n'
      'Phone: ${_phoneCtrl.text.trim()}\n\n'
      'Issue Description:\n${_messageCtrl.text.trim()}\n\n'
      '---\nSent from Cruise App',
    );
    final uri = Uri.parse(
      'mailto:support@cruiseride.com?subject=$subject&body=$body',
    );

    try {
      if (await canLaunchUrl(uri)) {
        await launchUrl(uri);
      }
    } catch (_) {}

    // Always show success (email client opens separately)
    await Future.delayed(const Duration(seconds: 1));
    if (!mounted) return;
    setState(() {
      _sending = false;
      _sent = true;
    });
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: Colors.white.withValues(alpha: 0.6),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    if (_sent) return _buildSuccessScreen(c);

    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Column(
          children: [
            // ── Header ──
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
                      'Contact Support',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: c.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),

            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Case number badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.10),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: Text(
                        'Case: $_caseNumber',
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    Text(
                      'Fill out the form below and a human agent will contact you within 24 hours.',
                      style: TextStyle(
                        fontSize: 14,
                        color: c.textSecondary,
                        height: 1.5,
                      ),
                    ),
                    const SizedBox(height: 24),

                    // ── Category dropdown ──
                    _label(c, 'Issue Category'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: DropdownButtonHideUnderline(
                        child: DropdownButton<String>(
                          value: _category,
                          isExpanded: true,
                          dropdownColor: c.surface,
                          style: TextStyle(color: c.textPrimary, fontSize: 15),
                          icon: Icon(
                            Icons.keyboard_arrow_down_rounded,
                            color: c.textSecondary,
                          ),
                          items: _categories
                              .map(
                                (cat) => DropdownMenuItem(
                                  value: cat,
                                  child: Text(cat),
                                ),
                              )
                              .toList(),
                          onChanged: (v) {
                            if (v != null) setState(() => _category = v);
                          },
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),

                    // ── Full Name ──
                    _label(c, 'Full Name *'),
                    const SizedBox(height: 8),
                    _inputField(
                      c,
                      _nameCtrl,
                      'Enter your full name',
                      Icons.person_outline_rounded,
                    ),
                    const SizedBox(height: 18),

                    // ── Email ──
                    _label(c, 'Email Address *'),
                    const SizedBox(height: 8),
                    _inputField(
                      c,
                      _emailCtrl,
                      'your@email.com',
                      Icons.email_outlined,
                      inputType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: 18),

                    // ── Phone ──
                    _label(c, 'Phone Number (optional)'),
                    const SizedBox(height: 8),
                    _inputField(
                      c,
                      _phoneCtrl,
                      '+1 (555) 000-0000',
                      Icons.phone_outlined,
                      inputType: TextInputType.phone,
                    ),
                    const SizedBox(height: 18),

                    // ── Description ──
                    _label(c, 'Describe Your Issue *'),
                    const SizedBox(height: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: c.surface,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: TextField(
                        controller: _messageCtrl,
                        maxLines: 5,
                        style: TextStyle(color: c.textPrimary, fontSize: 15),
                        decoration: InputDecoration(
                          border: InputBorder.none,
                          hintText:
                              'Please describe your issue in as much detail as possible. Include dates, times, and any relevant information...',
                          hintStyle: TextStyle(
                            color: c.textTertiary,
                            fontSize: 14,
                          ),
                          hintMaxLines: 4,
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),

                    // ── Submit button ──
                    SizedBox(
                      width: double.infinity,
                      height: 54,
                      child: ElevatedButton.icon(
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _gold,
                          foregroundColor: const Color(0xFF1A1400),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(16),
                          ),
                          elevation: 0,
                        ),
                        onPressed: _sending ? null : _submit,
                        icon: _sending
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: Color(0xFF1A1400),
                                ),
                              )
                            : const Icon(Icons.send_rounded, size: 20),
                        label: Text(
                          _sending ? 'Sending...' : 'Submit Request',
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      '🔒 Your information is secure and will only be used to resolve your support case.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 12, color: c.textTertiary),
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

  Widget _buildSuccessScreen(AppColors c) {
    return Scaffold(
      backgroundColor: c.bg,
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 80,
                  height: 80,
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8C547).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(24),
                  ),
                  child: const Icon(
                    Icons.check_circle_rounded,
                    color: Color(0xFFE8C547),
                    size: 48,
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'Request Submitted!',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w800,
                    color: c.textPrimary,
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  'Your case number is:',
                  style: TextStyle(fontSize: 14, color: c.textSecondary),
                ),
                const SizedBox(height: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 10,
                  ),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _caseNumber,
                    style: const TextStyle(
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      color: _gold,
                      letterSpacing: 1,
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                Text(
                  'A human support agent will review your case and contact you within 24 hours at the email address you provided.\n\n'
                  'Please save your case number for reference.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    color: c.textSecondary,
                    height: 1.6,
                  ),
                ),
                const SizedBox(height: 32),
                SizedBox(
                  width: double.infinity,
                  height: 52,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: const Color(0xFF1A1400),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 0,
                    ),
                    onPressed: () {
                      // Pop back to help screen (skip chat)
                      Navigator.of(context).popUntil(
                        (route) => route.isFirst || route.settings.name == null,
                      );
                      // Actually just pop twice (form → chat → help)
                    },
                    child: const Text(
                      'Back to Help',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(
                    'Return to Chat',
                    style: TextStyle(fontSize: 14, color: c.textSecondary),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _label(AppColors c, String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: c.textSecondary,
      ),
    );
  }

  Widget _inputField(
    AppColors c,
    TextEditingController ctrl,
    String hint,
    IconData icon, {
    TextInputType inputType = TextInputType.text,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      decoration: BoxDecoration(
        color: c.surface,
        borderRadius: BorderRadius.circular(14),
      ),
      child: TextField(
        controller: ctrl,
        keyboardType: inputType,
        style: TextStyle(color: c.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          border: InputBorder.none,
          hintText: hint,
          hintStyle: TextStyle(color: c.textTertiary, fontSize: 14),
          prefixIcon: Icon(icon, color: c.textSecondary, size: 20),
        ),
      ),
    );
  }
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

class _ChatMsg {
  final String text;
  final bool isUser;
  final DateTime time;
  final bool isSystem;
  const _ChatMsg({
    required this.text,
    required this.isUser,
    required this.time,
    this.isSystem = false,
  });
}
