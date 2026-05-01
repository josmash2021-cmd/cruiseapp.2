import 'dart:io';
import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/page_transitions.dart';
import '../../config/driver_colors.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/user_session.dart';
import '../../widgets/user_profile_photo.dart';
import '../../widgets/verified_avatar.dart';
import '../home_screen.dart';
import '../splash_screen.dart';
import '../help_screen.dart';
import 'driver_vehicle_screen.dart';
import 'driver_documents_screen.dart';
import 'driver_settings_screen.dart';
import 'driver_profile_screen.dart';
import 'driver_info_pages.dart';
import 'driver_referral_screen.dart';
import 'driver_earnings_screen.dart';
import 'cruise_level_screen.dart';
import 'payout_methods_screen.dart';
import 'scheduled_rides_screen.dart';
import '../about_screen.dart';
import '../../l10n/app_localizations.dart';
import '../../utils/responsive.dart';

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
  static const _surface = Color(0xFF1A1A1F);
  static const _card = Color(0xFF1C1C1E);

  // ── Dynamic profile data ──
  String _driverName = '';
  String _tierName = '';
  String _rating = '—';
  int _completedTrips = 0;
  int _totalTrips = 0;
  int _ratingsCount = 0;
  double _avgRating = 0;
  String? _photoUrl;
  String? _dispatchPassword;
  bool _profileLoaded = false;
  bool _isVerified = false;

  late AnimationController _entranceCtrl;
  late Animation<double> _entranceAnim;

  /// Bounce non-driver users back to the rider home screen.
  void _enforceDriverRole() {
    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          fadeThroughRoute(const HomeScreen()),
          (_) => false,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    _enforceDriverRole();
    _entranceCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    )..forward();
    _entranceAnim = CurvedAnimation(
      parent: _entranceCtrl,
      curve: Curves.easeOutCubic,
    );
    _loadCachedProfile(); // instant from SharedPreferences
    _loadProfile();       // refresh from API in background
    _loadVerifiedState();
    // Seed photo from notifier in case initPhotoNotifier already resolved it
    final cachedUrl = UserSession.photoUrlNotifier.value;
    if (cachedUrl.isNotEmpty) _photoUrl = cachedUrl;
    UserSession.photoNotifier.addListener(_onPhotoChanged);
    UserSession.photoUrlNotifier.addListener(_onPhotoChanged);
  }

  /// Instant cache-first: populate name & photo from SharedPreferences
  /// so the UI never shows a blank skeleton on revisit.
  Future<void> _loadCachedProfile() async {
    final user = await UserSession.getUser();
    if (user != null && mounted && !_profileLoaded) {
      final first = user['firstName'] ?? '';
      final last = user['lastName'] ?? '';
      final url = user['photoUrl'] ?? '';
      if (first.isNotEmpty) {
        setState(() {
          _driverName = last.isNotEmpty
              ? '$first ${last[0].toUpperCase()}.'
              : first;
          if (url.isNotEmpty) _photoUrl = url;
        });
      }
    }
  }

  void _onPhotoChanged() {
    if (!mounted) return;
    final v = UserSession.photoNotifier.value;
    final url = UserSession.photoUrlNotifier.value;
    setState(() {
      if (v.isNotEmpty) _photoUrl = v;
      if (url.isNotEmpty) _photoUrl = url;
    });
  }

  @override
  void dispose() {
    UserSession.photoNotifier.removeListener(_onPhotoChanged);
    UserSession.photoUrlNotifier.removeListener(_onPhotoChanged);
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
          // Fallback to cached URL or local photo if server URL is empty
          if (_photoUrl == null || _photoUrl!.isEmpty) {
            final cachedUrl = UserSession.photoUrlNotifier.value;
            if (cachedUrl.isNotEmpty) {
              _photoUrl = cachedUrl;
            } else if (UserSession.photoNotifier.value.isNotEmpty) {
              _photoUrl = UserSession.photoNotifier.value;
            }
          }
          // Persist photo URL so it's available on next app launch
          if (_photoUrl != null && _photoUrl!.isNotEmpty && _photoUrl!.startsWith('http')) {
            UserSession.savePhotoUrl(_photoUrl!);
          }
          _profileLoaded = true;
        });

        // Fetch real driver stats for rating + tier from completed trips
        final userId = me['id'] as int?;
        if (userId != null) {
          final stats = await ApiService.getDriverStats(userId);
          if (mounted) {
            final completed = (stats['completed_trips'] as num?)?.toInt() ?? 0;
            final total = (stats['total_trips'] as num?)?.toInt() ?? 0;
            // New drivers have no trips → no rating. Don't show fake 5.0 stars.
            final rawRating = stats['avg_rating'];
            final avgRating = rawRating == null
                ? 0.0
                : (rawRating as num).toDouble();
            final ratingsCount = (stats['ratings_count'] as num?)?.toInt() ?? 0;
            setState(() {
              _completedTrips = completed;
              _totalTrips = total;
              _ratingsCount = ratingsCount;
              _avgRating = avgRating;
              // Show '—' for new drivers instead of '0.0'
              _rating = avgRating <= 0 ? '—' : avgRating.toStringAsFixed(1);
              // Use backend authoritative cruise_level, fall back to client-side
              final backendLevel = stats['cruise_level'] as String?;
              if (backendLevel != null && backendLevel.isNotEmpty) {
                _tierName = backendLevel[0].toUpperCase() + backendLevel.substring(1);
              } else if (completed >= 500 && avgRating >= 4.9) {
                _tierName = 'Diamond';
              } else if (completed >= 300 && avgRating >= 4.8) {
                _tierName = 'Platinum';
              } else if (completed >= 150 && avgRating >= 4.7) {
                _tierName = 'Gold';
              } else if (completed >= 50 && avgRating >= 4.5) {
                _tierName = 'Silver';
              } else {
                _tierName = 'Bronze';
              }
            });
          }
        }
      }
    } catch (_) {}
    // Mark loaded even on error so skeleton is replaced with fallback
    if (mounted && !_profileLoaded) {
      setState(() {
        if (_driverName.isEmpty) _driverName = 'Driver';
        if (_tierName.isEmpty) _tierName = 'Bronze';
        _profileLoaded = true;
      });
    }
  }

  Future<void> _loadVerifiedState() async {
    final v = await LocalDataService.isIdentityVerified();
    if (v && mounted) setState(() => _isVerified = true);
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
                    width: Responsive.w(40),
                    height: Responsive.w(40),
                    decoration: BoxDecoration(
                      color: dc.glassBg,
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close_rounded, color: dc.text, size: Responsive.sp(22)),
                  ),
                ),
                const Spacer(),
                Text(
                  S.of(context).menuTitle,
                  style: TextStyle(
                    color: dc.text,
                    fontSize: Responsive.sp(18),
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                SizedBox(width: Responsive.w(40)), // balance close button
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
                  // Opportunities — Coming Soon
                  Stack(
                    children: [
                      IgnorePointer(
                        child: Opacity(
                          opacity: 0.45,
                          child: _item(
                            context,
                            Icons.trending_up_rounded,
                            S.of(context).opportunities,
                            S.of(context).findMoreEarnings,
                            () {},
                          ),
                        ),
                      ),
                      Positioned(
                        right: 20, top: 0, bottom: 0,
                        child: Center(
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(colors: [Color(0xFFE8C547), Color(0xFFF5D990)]),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: const Text(
                              'Coming Soon',
                              style: TextStyle(
                                color: Colors.black,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 0.5,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
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
                      ).push(slideFromRightRoute(const DriverReferralScreen()));
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
                        slideFromRightRoute(const ScheduledRidesScreen(initialTab: 1)),
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
        HapticService.selectionClick();
        Navigator.of(
          context,
        ).push(slideFromRightRoute(const DriverProfileScreen()));
      },
      child: Container(
        margin: EdgeInsets.symmetric(horizontal: Responsive.w(16)),
        padding: EdgeInsets.all(Responsive.w(18)),
        decoration: BoxDecoration(
          color: dc.card,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          children: [
            // Avatar
            VerifiedAvatar(
                photoUrl: _resolvedPhotoUrl,
                photoPath: _photoUrl != null && !_photoUrl!.startsWith('http') ? _photoUrl : null,
                radius: Responsive.w(30),
                fallbackName: _driverName,
                uid: UserSession.currentUid,
                role: 'driver',
                isVerified: _isVerified,
            ),
            SizedBox(width: Responsive.w(14)),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: _profileLoaded
                            ? Text(
                                _driverName,
                                style: TextStyle(
                                  color: dc.text,
                                  fontSize: Responsive.sp(20),
                                  fontWeight: FontWeight.w800,
                                ),
                                overflow: TextOverflow.ellipsis,
                              )
                            : Container(
                                height: Responsive.h(18),
                                width: Responsive.w(120),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.10),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                              ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      // Tier badge
                      if (_profileLoaded)
                        _tierBadgeWidget()
                      else
                        Container(
                          height: 20,
                          width: 56,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      const SizedBox(width: 10),
                      // Rating — visual stars + "New" badge for < 5 ratings
                      if (_profileLoaded) ...[
                        if (_ratingsCount == 0)
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: const Color(0xFFE8C547).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: const Color(0xFFE8C547).withValues(alpha: 0.4),
                                width: 1,
                              ),
                            ),
                            child: const Text(
                              'New Driver',
                              style: TextStyle(
                                color: Color(0xFFE8C547),
                                fontSize: 11,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          )
                        else ...[
                          _buildStarRating(_rating),
                          const SizedBox(width: 5),
                          Text(
                            _rating,
                            style: TextStyle(
                              color: dc.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (_ratingsCount < 5) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                              decoration: BoxDecoration(
                                color: const Color(0xFFE8C547).withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'New',
                                style: TextStyle(
                                  color: const Color(0xFFE8C547).withValues(alpha: 0.9),
                                  fontSize: 10,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ] else
                        Container(
                          height: 14, width: 60,
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.10),
                            borderRadius: BorderRadius.circular(6),
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

  /// Build 5 visual stars based on rating string (e.g. "4.9").
  Widget _buildStarRating(String ratingStr) {
    final rating = double.tryParse(ratingStr) ?? 0.0;
    if (rating <= 0) return const SizedBox.shrink();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) {
        final filled = rating >= i + 1;
        final half = !filled && rating >= i + 0.5;
        return Icon(
          half ? Icons.star_half_rounded : (filled ? Icons.star_rounded : Icons.star_outline_rounded),
          color: _gold,
          size: 14,
        );
      }),
    );
  }

  /// Cruise Level badge with per-tier gradient and icon.
  Widget _tierBadgeWidget() {
    final (List<Color> gradient, IconData icon, Color textColor) = switch (_tierName) {
      'Diamond'  => (const [Color(0xFF80DEEA), Color(0xFF4DD0E1)], Icons.auto_awesome_rounded, Colors.black),
      'Platinum' => (const [Color(0xFF90CAF9), Color(0xFF64B5F6)], Icons.diamond_rounded,      Colors.black),
      'Gold'     => (const [Color(0xFFE8C547), Color(0xFFF5D990)], Icons.star_rounded,         Colors.black),
      'Silver'   => (const [Color(0xFFB0BEC5), Color(0xFF90A4AE)], Icons.workspace_premium_rounded, Colors.black),
      _          => (const [Color(0xFFCD7F32), Color(0xFFB8722E)], Icons.emoji_events_rounded, Colors.white),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        gradient: LinearGradient(colors: gradient),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: textColor, size: 12),
          const SizedBox(width: 3),
          Text(
            _tierName,
            style: TextStyle(color: textColor, fontSize: 11, fontWeight: FontWeight.w800),
          ),
        ],
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
          HapticService.selectionClick();
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
          HapticService.selectionClick();
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
