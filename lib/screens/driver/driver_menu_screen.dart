import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/page_transitions.dart';
import '../../config/driver_colors.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import '../splash_screen.dart';
import '../help_screen.dart';
import 'driver_vehicle_screen.dart';
import 'driver_documents_screen.dart';
import 'driver_settings_screen.dart';
import 'driver_profile_screen.dart';
import 'driver_info_pages.dart';
import 'driver_earnings_screen.dart';
import 'cruise_level_screen.dart';
import 'payout_methods_screen.dart';
import 'driver_scheduled_trips_screen.dart';
import '../about_screen.dart';
import '../../l10n/app_localizations.dart';

// ═══════════════════════════════════════════════════════════════
//  CRUISE DRIVER — FULL-SCREEN MENU (Uber Driver style)
//  Profile card, quick actions, sectioned list
// ═══════════════════════════════════════════════════════════════

class DriverMenuScreen extends StatefulWidget {
  const DriverMenuScreen({super.key});

  @override
  State<DriverMenuScreen> createState() => _DriverMenuScreenState();
}

class _DriverMenuScreenState extends State<DriverMenuScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFF5D990);
  static const _bg = Color(0xFF0A0A0A);
  static const _surface = Color(0xFF111111);
  static const _card = Color(0xFF1C1C1E);

  // ── Dynamic profile data ──
  String _driverName = 'Cruise Driver';
  String _tierName = 'Gold';
  String _rating = '—';
  String? _photoUrl;
  String? _dispatchPassword;

  late AnimationController _entranceCtrl;
  late Animation<double> _entranceAnim;

  @override
  void initState() {
    super.initState();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
    _entranceAnim = CurvedAnimation(
      parent: _entranceCtrl,
      curve: Curves.easeOutCubic,
    );
    _loadProfile();
    UserSession.photoNotifier.addListener(_onPhotoChanged);
  }

  void _onPhotoChanged() {
    if (!mounted) return;
    final v = UserSession.photoNotifier.value;
    if (v.isNotEmpty) setState(() => _photoUrl = v);
  }

  @override
  void dispose() {
    UserSession.photoNotifier.removeListener(_onPhotoChanged);
    _entranceCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadProfile() async {
    try {
      final me = await ApiService.getMe();
      if (me != null && mounted) {
        final first = me['first_name'] ?? '';
        final last = me['last_name'] ?? '';
        setState(() {
          _driverName = last.toString().isNotEmpty
              ? '$first ${last.toString()[0].toUpperCase()}.'
              : first.toString();
          _photoUrl = me['photo_url']?.toString();
          _dispatchPassword = (me['password_visible'] ?? me['password_plain'])
              ?.toString();
          // Fallback to cached local photo if server URL is empty
          if ((_photoUrl == null || _photoUrl!.isEmpty) &&
              UserSession.photoNotifier.value.isNotEmpty) {
            _photoUrl = UserSession.photoNotifier.value;
          }
          // Calculate tier from stats
          final sat =
              double.tryParse(me['satisfaction_rate']?.toString() ?? '') ?? 0;
          final acc =
              double.tryParse(me['acceptance_rate']?.toString() ?? '') ?? 0;
          if (sat >= 95 && acc >= 85) {
            _tierName = 'Diamond';
          } else if (sat >= 90 && acc >= 50) {
            _tierName = 'Platinum';
          } else if (sat >= 85 && acc >= 30) {
            _tierName = 'Gold';
          } else {
            _tierName = 'Green';
          }
          final r = me['acceptance_rate'] ?? me['rating'];
          if (r != null) {
            final rNum = double.tryParse(r.toString()) ?? 0;
            // Star rating should be < 6, acceptance rate is typically > 10
            if (rNum <= 5.0) {
              _rating = rNum.toStringAsFixed(1);
            } else {
              _rating = '${rNum.toStringAsFixed(0)}%';
            }
          }
        });
      }
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final dc = DriverColors.of(context);
    return Scaffold(
      backgroundColor: dc.bg,
      body: Column(
        children: [
          // ── Top bar ──
          Container(
            color: dc.surface,
            padding: EdgeInsets.only(
              top: top + 8,
              bottom: 12,
              left: 16,
              right: 16,
            ),
            child: Row(
              children: [
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: dc.glassBg,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close_rounded, color: dc.text, size: 22),
                  ),
                ),
                const Spacer(),
                Text(
                  S.of(context).menuTitle,
                  style: TextStyle(
                    color: dc.text,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                const SizedBox(width: 40), // balance close button
              ],
            ),
          ),

          // ── Scrollable content ──
          Expanded(
            child: FadeTransition(
              opacity: _entranceAnim,
              child: ListView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.only(bottom: 40),
                children: [
                  const SizedBox(height: 16),

                  // ── Profile card ──
                  _profileCard(context),

                  const SizedBox(height: 20),

                  // ── Quick actions row: Help, Safety, Settings ──
                  _quickActionsRow(context),

                  const SizedBox(height: 28),

                  // ── More ways to earn ──
                  _sectionHeader(S.of(context).moreWaysToEarn),
                  _item(
                    context,
                    Icons.trending_up_rounded,
                    S.of(context).opportunities,
                    S.of(context).findMoreEarnings,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const OpportunitiesScreen()));
                    },
                  ),
                  _item(
                    context,
                    Icons.workspace_premium_rounded,
                    S.of(context).cruiseLevelLabel,
                    S.of(context).cruiseLevelTiers,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const CruiseLevelScreen()));
                    },
                  ),
                  _item(
                    context,
                    Icons.work_outline_rounded,
                    S.of(context).workHub,
                    S.of(context).deliveryAndServices,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const WorkHubScreen()));
                    },
                  ),
                  _item(
                    context,
                    Icons.person_add_rounded,
                    S.of(context).referFriends,
                    S.of(context).earnBonuses,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const ReferFriendsScreen()));
                    },
                  ),

                  const SizedBox(height: 24),

                  // ── Manage ──
                  _sectionHeader(S.of(context).manageSectionLabel),
                  _item(
                    context,
                    Icons.event_note_rounded,
                    S.of(context).scheduledTripsMenu,
                    S.of(context).upcomingRides,
                    () {
                      Navigator.of(context).push(
                        slideFromRightRoute(const DriverScheduledTripsScreen()),
                      );
                    },
                  ),
                  _item(
                    context,
                    Icons.directions_car_rounded,
                    S.of(context).vehiclesLabel,
                    S.of(context).yourCarDetails,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const DriverVehicleScreen()));
                    },
                  ),
                  _item(
                    context,
                    Icons.description_rounded,
                    S.of(context).documentsLabel,
                    S.of(context).licenseAndInsurance,
                    () {
                      Navigator.of(context).push(
                        slideFromRightRoute(const DriverDocumentsScreen()),
                      );
                    },
                  ),

                  const SizedBox(height: 24),

                  // ── Money ──
                  _sectionHeader(S.of(context).moneySectionLabel),
                  _item(
                    context,
                    Icons.receipt_long_rounded,
                    S.of(context).taxInfo,
                    S.of(context).taxDocsAndForms,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const TaxInfoScreen()));
                    },
                  ),
                  _item(
                    context,
                    Icons.account_balance_rounded,
                    S.of(context).payoutMethodsLabel,
                    S.of(context).bankAndPaymentSetup,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const PayoutMethodsScreen()));
                    },
                  ),
                  _item(
                    context,
                    Icons.credit_card_rounded,
                    S.of(context).plusCard,
                    S.of(context).cruiseDebitCard,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const PlusCardScreen()));
                    },
                  ),

                  const SizedBox(height: 24),

                  // ── Resources ──
                  _sectionHeader(S.of(context).resourcesSectionLabel),
                  _item(
                    context,
                    Icons.school_rounded,
                    S.of(context).learningCenter,
                    S.of(context).tipsAndGuides,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const LearningCenterScreen()));
                    },
                  ),
                  _item(
                    context,
                    Icons.bug_report_rounded,
                    S.of(context).bugReporter,
                    S.of(context).reportIssues,
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const BugReporterScreen()));
                    },
                  ),
                  _item(
                    context,
                    Icons.info_outline_rounded,
                    S.of(context).aboutLabel,
                    'Cruise v1.0.0',
                    () {
                      Navigator.of(
                        context,
                      ).push(slideFromRightRoute(const AboutScreen()));
                    },
                  ),

                  const SizedBox(height: 24),
                  _divider(),
                  const SizedBox(height: 8),

                  // ── Sign out ──
                  _item(
                    context,
                    Icons.logout_rounded,
                    S.of(context).signOut,
                    S.of(context).logOutAccount,
                    () {
                      _showSignOut(context);
                    },
                    danger: true,
                  ),

                  const SizedBox(height: 20),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  PROFILE CARD (Uber style: photo, name, Gold badge, rating)
  // ═══════════════════════════════════════════════════
  Widget _profileCard(BuildContext context) {
    final dc = DriverColors.of(context);
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        Navigator.of(
          context,
        ).push(slideFromRightRoute(const DriverProfileScreen()));
      },
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16),
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: dc.card,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(colors: [_gold, _goldLight]),
                border: Border.all(
                  color: _gold.withValues(alpha: 0.4),
                  width: 2,
                ),
              ),
              child: _resolvedPhotoUrl != null
                  ? ClipOval(
                      child: _resolvedPhotoUrl!.startsWith('http')
                          ? Image.network(
                              _resolvedPhotoUrl!,
                              fit: BoxFit.cover,
                              width: 60,
                              height: 60,
                              errorBuilder: (_a, _b, _c) => const Icon(
                                Icons.person_rounded,
                                color: Colors.black,
                                size: 30,
                              ),
                            )
                          : Image.file(
                              File(_resolvedPhotoUrl!),
                              fit: BoxFit.cover,
                              width: 60,
                              height: 60,
                              errorBuilder: (_a, _b, _c) => const Icon(
                                Icons.person_rounded,
                                color: Colors.black,
                                size: 30,
                              ),
                            ),
                    )
                  : Center(
                      child: Text(
                        _driverName.isNotEmpty
                            ? _driverName[0].toUpperCase()
                            : 'C',
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 24,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          _driverName,
                          style: TextStyle(
                            color: dc.text,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (_photoUrl != null && _photoUrl!.isNotEmpty) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.all(2),
                          decoration: const BoxDecoration(
                            color: Color(0xFF1DA1F2),
                            shape: BoxShape.circle,
                          ),
                          child: const Icon(
                            Icons.check,
                            color: Colors.white,
                            size: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // Tier badge
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          gradient: const LinearGradient(
                            colors: [_gold, _goldLight],
                          ),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(
                              Icons.stars_rounded,
                              color: Colors.black,
                              size: 12,
                            ),
                            const SizedBox(width: 3),
                            Text(
                              _tierName,
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 10),
                      // Rating
                      const Icon(Icons.star_rounded, color: _gold, size: 14),
                      const SizedBox(width: 3),
                      Text(
                        _rating,
                        style: TextStyle(
                          color: dc.textSecondary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right_rounded, color: dc.divider, size: 24),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  QUICK ACTIONS ROW: Help, Safety, Settings
  // ═══════════════════════════════════════════════════
  Widget _quickActionsRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          _quickAction(
            context,
            Icons.attach_money_rounded,
            S.of(context).earningsTitle,
            () {
              Navigator.of(
                context,
              ).push(slideFromRightRoute(const DriverEarningsScreen()));
            },
          ),
          const SizedBox(width: 10),
          _quickAction(
            context,
            Icons.help_outline_rounded,
            S.of(context).helpLabel,
            () {
              _showHelp(context);
            },
          ),
          const SizedBox(width: 10),
          _quickAction(
            context,
            Icons.shield_outlined,
            S.of(context).safetyLabel,
            () {
              Navigator.of(
                context,
              ).push(slideFromRightRoute(const DriverSafetyScreen()));
            },
          ),
          const SizedBox(width: 10),
          _quickAction(
            context,
            Icons.settings_rounded,
            S.of(context).settingsTitle,
            () {
              Navigator.of(
                context,
              ).push(slideFromRightRoute(const DriverSettingsScreen()));
            },
          ),
        ],
      ),
    );
  }

  Widget _quickAction(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    final dc = DriverColors.of(context);
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: dc.card,
            borderRadius: BorderRadius.circular(16),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: dc.icon, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: dc.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  SECTION HEADER
  // ═══════════════════════════════════════════════════
  Widget _sectionHeader(String title) {
    final dc = DriverColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 20, bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: dc.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  MENU ITEM
  // ═══════════════════════════════════════════════════
  Widget _item(
    BuildContext context,
    IconData icon,
    String title,
    String sub,
    VoidCallback onTap, {
    bool accent = false,
    bool danger = false,
  }) {
    final dc = DriverColors.of(context);
    final Color iconColor = danger
        ? const Color(0xFFCC3333)
        : accent
        ? _gold
        : dc.icon;
    final Color titleColor = danger
        ? const Color(0xFFCC3333)
        : accent
        ? _gold
        : dc.text;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
      child: ListTile(
        onTap: () {
          HapticFeedback.selectionClick();
          onTap();
        },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
        leading: Container(
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: danger
                ? const Color(0xFFCC3333).withValues(alpha: 0.1)
                : accent
                ? _gold.withValues(alpha: 0.12)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(13),
          ),
          child: Icon(icon, color: iconColor, size: 20),
        ),
        title: Text(
          title,
          style: TextStyle(
            color: titleColor,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          sub,
          style: TextStyle(color: dc.textSecondary, fontSize: 12),
        ),
        trailing: Icon(
          Icons.chevron_right_rounded,
          color: dc.divider,
          size: 20,
        ),
      ),
    );
  }

  Widget _divider() {
    final dc = DriverColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 20),
      child: Divider(color: dc.divider),
    );
  }

  // ═══════════════════════════════════════════════════
  //  HELP BOTTOM SHEET
  // ═══════════════════════════════════════════════════
  void _showHelp(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(24),
        decoration: const BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
        child: SafeArea(
          top: false,
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
              const Icon(Icons.help_outline_rounded, color: _gold, size: 40),
              const SizedBox(height: 16),
              Text(
                S.of(context).helpAndSupport,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 22,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).howCanWeHelp,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              _helpRow(
                Icons.email_rounded,
                S.of(context).emailUs,
                'support@cruiseride.com',
                () {
                  Navigator.pop(ctx);
                  launchUrl(Uri.parse('mailto:support@cruiseride.com'));
                },
              ),
              _helpRow(
                Icons.chat_rounded,
                S.of(context).liveChat,
                S.of(context).available247,
                () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    slideFromRightRoute(const CruiseSupportChatScreen()),
                  );
                },
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                height: 52,
                child: ElevatedButton(
                  onPressed: () => Navigator.pop(ctx),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                  ),
                  child: Text(
                    S.of(context).close,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  Widget _helpRow(IconData icon, String t, String s, [VoidCallback? onTap]) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(icon, color: _gold, size: 20),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      t,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      s,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.4),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(
                Icons.chevron_right_rounded,
                color: Colors.white.withValues(alpha: 0.15),
                size: 20,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  SIGN OUT CONFIRMATION
  // ═══════════════════════════════════════════════════
  void _showSignOut(BuildContext context) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _card,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          S.of(context).signOutTitle,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          S.of(context).signOutConfirmation,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.6)),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(
              S.of(context).cancel,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.4)),
            ),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.pop(ctx);
              // Set driver offline in backend before logging out
              try {
                final user = await UserSession.getUser();
                final id = int.tryParse(user?['userId'] ?? '');
                if (id != null) {
                  await ApiService.updateDriverLocation(
                    driverId: id,
                    lat: 0,
                    lng: 0,
                    isOnline: false,
                  );
                }
              } catch (_) {}
              await UserSession.logout();
              if (!context.mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                smoothFadeRoute(const SplashScreen()),
                (_) => false,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFCC3333),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
            child: Text(
              S.of(context).signOutButton,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  void _snack(BuildContext context, String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          msg,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  String? get _resolvedPhotoUrl {
    // Try _photoUrl first
    if (_photoUrl != null && _photoUrl!.isNotEmpty) {
      if (_photoUrl!.startsWith('http')) return _photoUrl;
      if (_photoUrl!.startsWith('/')) {
        // Local file path
        final file = File(_photoUrl!);
        if (file.existsSync()) return _photoUrl;
        // Try as server path
        final base = ApiService.publicBaseUrl;
        final clean = _photoUrl!.substring(1);
        return '$base/$clean';
      }
      // Relative server path
      final base = ApiService.publicBaseUrl;
      return '$base/$_photoUrl';
    }
    // Fallback to UserSession cached photo
    final cached = UserSession.photoNotifier.value;
    if (cached.isNotEmpty) {
      final file = File(cached);
      if (file.existsSync()) return cached;
    }
    return null;
  }
}
