import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/haptic_service.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../config/page_transitions.dart';
import '../../services/api_service.dart';
import '../../services/local_data_service.dart';
import '../../services/user_session.dart';
import '../../widgets/user_profile_photo.dart';
import '../../widgets/verified_avatar.dart';
import '../../widgets/neu_style.dart';
import '../home_screen.dart';
import '../splash_screen.dart';
import '../help_screen.dart';
import 'driver_vehicle_screen.dart';
import 'driver_documents_screen.dart';
import 'driver_settings_screen.dart';
import 'driver_profile_screen.dart';
import 'driver_info_pages.dart';
import 'driver_referral_screen.dart';
import 'driver_terms_screen.dart';
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
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);
  static const _danger = Color(0xFFFF5252);

  // Text ramp for the dark neumorphic surface (neuBase/neuSurface).
  // The shared neu system is dark-only, so these are fixed — see
  // lib/widgets/neu_style.dart.
  static const _text = Colors.white;
  static final _textSecondary = Colors.white.withValues(alpha: 0.60);
  static final _textTertiary = Colors.white.withValues(alpha: 0.38);

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
    WidgetsBinding.instance.addObserver(this);
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

  /// Where the card's own values live between visits.
  ///
  /// Keyed by driver id: two drivers sharing a phone must not see each
  /// other's tier, and a stale badge after a logout is worse than a blank
  /// one. Written whenever the server answers, read before it is asked.
  static const _kCardKey = 'driver_menu_card';

  /// Instant cache-first: populate the whole card from SharedPreferences so
  /// it is already drawn when the menu opens.
  ///
  /// It used to restore the name and the photo only. The tier badge and the
  /// stars came from two sequential network calls — getMe, then
  /// getDriverStats with the id it returns — so on every single visit the
  /// driver watched an empty badge and an em dash turn into "Bronze" and
  /// "5.0" a moment later. None of that changes between one menu open and
  /// the next; it changes when they level up, are rated, or set a new
  /// photo.
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

    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_kCardKey);
      if (raw == null || !mounted || _profileLoaded) return;
      final card = jsonDecode(raw) as Map<String, dynamic>;
      // Only this driver's card, checked against the session on disk.
      //
      // Not ApiService.getCurrentUserId(): that falls through to getMe()
      // when its in-memory cache is cold, which is a network round trip —
      // and waiting on the network is the exact thing this method exists to
      // avoid. The session record is already in hand from the read above.
      final cachedId = card['id']?.toString();
      final myId = user?['userId']?.toString();
      if (cachedId == null || myId == null || cachedId != myId) return;
      if (!mounted || _profileLoaded) return;
      setState(() {
        _tierName = (card['tier'] ?? '').toString();
        _avgRating = (card['avgRating'] as num?)?.toDouble() ?? 0;
        _rating = _avgRating <= 0 ? '—' : _avgRating.toStringAsFixed(1);
        _ratingsCount = (card['ratingsCount'] as num?)?.toInt() ?? 0;
        _completedTrips = (card['completed'] as num?)?.toInt() ?? 0;
        _totalTrips = (card['total'] as num?)?.toInt() ?? 0;
      });
    } catch (e) {
      // A malformed or missing card is not worth a blank menu.
      debugPrint('[DriverMenu] cached card unavailable: $e');
    }
  }

  /// Keep what the card is showing, so the next visit opens on it.
  ///
  /// Stamped with the same id the reader checks — the session's own
  /// `userId`, not the one the API returned, so both sides are comparing
  /// the same thing.
  Future<void> _cacheCard() async {
    try {
      final id = (await UserSession.getUser())?['userId']?.toString();
      if (id == null || id.isEmpty) return;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _kCardKey,
        jsonEncode(<String, dynamic>{
          'id': id,
          'tier': _tierName,
          'avgRating': _avgRating,
          'ratingsCount': _ratingsCount,
          'completed': _completedTrips,
          'total': _totalTrips,
        }),
      );
    } catch (e) {
      debugPrint('[DriverMenu] could not cache the card: $e');
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
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _entranceCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      if (!_entranceCtrl.isCompleted) _entranceCtrl.forward();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
        final userId = (me['id'] is num) ? (me['id'] as num).toInt() : int.tryParse(me['id']?.toString() ?? '');
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
            // Written after the server has spoken, so the next open starts
            // where this one ended.
            unawaited(_cacheCard());
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
    final s = S.of(context);
    return Scaffold(
      backgroundColor: neuBase,
      body: Column(
        children: [
          // ── Top bar ──
          Container(
            color: neuBase,
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
                    decoration: neuBox(radius: 14, pressed: true),
                    child: Icon(
                      Icons.close_rounded,
                      color: _text,
                      size: Responsive.sp(22),
                    ),
                  ),
                ),
                const Spacer(),
                Text(
                  s.menuTitle,
                  style: TextStyle(
                    color: _text,
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
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 40),
                children: [
                  const SizedBox(height: 16),

                  // ── Profile card ──
                  _profileCard(context),

                  const SizedBox(height: 20),

                  // ── Quick actions row: Earnings, Help, Settings ──
                  _quickActionsRow(context),

                  const SizedBox(height: 28),

                  // ── More ways to earn ──
                  _sectionHeader(s.moreWaysToEarn),
                  _sectionCard([
                    _item(
                      Icons.workspace_premium_rounded,
                      s.cruiseLevelLabel,
                      s.cruiseLevelTiers,
                      () => Navigator.of(context)
                          .push(slideFromRightRoute(const CruiseLevelScreen())),
                    ),
                    _item(
                      Icons.work_outline_rounded,
                      s.workHub,
                      s.deliveryAndServices,
                      () => Navigator.of(context)
                          .push(slideFromRightRoute(const WorkHubScreen())),
                    ),
                    _item(
                      Icons.person_add_rounded,
                      s.referFriends,
                      s.earnBonuses,
                      () => Navigator.of(context).push(
                        slideFromRightRoute(const DriverReferralScreen()),
                      ),
                    ),
                  ]),

                  const SizedBox(height: 22),

                  // ── Manage ──
                  _sectionHeader(s.manageSectionLabel),
                  _sectionCard([
                    _item(
                      Icons.event_note_rounded,
                      s.scheduledTripsMenu,
                      s.upcomingRides,
                      () => Navigator.of(context).push(
                        slideFromRightRoute(
                          const ScheduledRidesScreen(initialTab: 1),
                        ),
                      ),
                    ),
                    _item(
                      Icons.directions_car_rounded,
                      s.vehiclesLabel,
                      s.yourCarDetails,
                      () => Navigator.of(context)
                          .push(slideFromRightRoute(const DriverVehicleScreen())),
                    ),
                    _item(
                      Icons.description_rounded,
                      s.documentsLabel,
                      s.licenseAndInsurance,
                      () => Navigator.of(context).push(
                        slideFromRightRoute(const DriverDocumentsScreen()),
                      ),
                    ),
                    _item(
                      Icons.gavel_rounded,
                      s.driverTermsOfServiceMenu,
                      s.driverTermsOfServiceMenuSubtitle,
                      () => Navigator.of(context)
                          .push(slideFromRightRoute(const DriverTermsScreen())),
                    ),
                  ]),

                  const SizedBox(height: 22),

                  // ── Money ──
                  _sectionHeader(s.moneySectionLabel),
                  _sectionCard([
                    _item(
                      Icons.receipt_long_rounded,
                      s.taxInfo,
                      s.taxDocsAndForms,
                      () => Navigator.of(context)
                          .push(slideFromRightRoute(const TaxInfoScreen())),
                    ),
                    _item(
                      Icons.account_balance_rounded,
                      s.payoutMethodsLabel,
                      s.bankAndPaymentSetup,
                      () => Navigator.of(context)
                          .push(slideFromRightRoute(const PayoutMethodsScreen())),
                    ),
                  ]),

                  const SizedBox(height: 22),

                  // ── Resources ──
                  _sectionHeader(s.resourcesSectionLabel),
                  _sectionCard([
                    _item(
                      Icons.school_rounded,
                      s.learningCenter,
                      s.tipsAndGuides,
                      () => Navigator.of(context)
                          .push(slideFromRightRoute(const LearningCenterScreen())),
                    ),
                    _item(
                      Icons.bug_report_rounded,
                      s.bugReporter,
                      s.reportIssues,
                      () => Navigator.of(context)
                          .push(slideFromRightRoute(const BugReporterScreen())),
                    ),
                    _item(
                      Icons.info_outline_rounded,
                      s.aboutLabel,
                      'Cruise v1.0.0',
                      () => Navigator.of(context)
                          .push(slideFromRightRoute(const AboutScreen())),
                    ),
                  ]),

                  const SizedBox(height: 26),

                  // ── Sign out ──
                  _sectionCard([
                    _item(
                      Icons.logout_rounded,
                      s.signOut,
                      s.logOutAccount,
                      () => _showSignOut(context),
                      danger: true,
                    ),
                  ]),

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
    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        Navigator.of(
          context,
        ).push(slideFromRightRoute(const DriverProfileScreen()));
      },
      child: Container(
        padding: EdgeInsets.all(Responsive.w(18)),
        decoration: neuBox(radius: 22),
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
                                  color: _text,
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
                              color: _textSecondary,
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
            Icon(Icons.chevron_right_rounded, color: _textTertiary, size: 24),
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
    return Row(
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
            Icons.health_and_safety_outlined,
            S.of(context).helpAndSafety,
            () {
              _showHelp(context);
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
    );
  }

  Widget _quickAction(
    BuildContext context,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return Expanded(
      child: GestureDetector(
        onTap: () {
          HapticService.selectionClick();
          onTap();
        },
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: neuBox(radius: 18),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: _gold, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  color: _textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
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
    return Padding(
      padding: const EdgeInsets.only(left: 6, bottom: 10),
      child: Text(
        title.toUpperCase(),
        style: TextStyle(
          color: _textTertiary,
          fontSize: 12,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      ),
    );
  }

  /// Raised neumorphic card holding a group of menu rows, hairline-divided.
  Widget _sectionCard(List<Widget> rows) {
    return Container(
      decoration: neuBox(radius: 20),
      child: Column(
        children: [
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0)
              Divider(
                height: 1,
                indent: 70,
                color: Colors.white.withValues(alpha: 0.05),
              ),
            rows[i],
          ],
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  MENU ITEM — icon in a pressed well, title, subtitle, chevron
  // ═══════════════════════════════════════════════════
  Widget _item(
    IconData icon,
    String title,
    String sub,
    VoidCallback onTap, {
    bool danger = false,
  }) {
    final Color accentColor = danger ? _danger : _gold;
    final Color titleColor = danger ? _danger : _text;

    return GestureDetector(
      onTap: () {
        HapticService.selectionClick();
        onTap();
      },
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: neuBox(radius: 14, pressed: true),
              child: Icon(icon, color: accentColor, size: 21),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: titleColor,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    sub,
                    style: TextStyle(color: _textTertiary, fontSize: 12),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right_rounded,
              color: _textTertiary,
              size: 20,
            ),
          ],
        ),
      ),
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
          color: neuBase,
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
                'support@cruiseapp.com',
                () {
                  Navigator.pop(ctx);
                  launchUrl(Uri.parse('mailto:support@cruiseapp.com'));
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
              _helpRow(
                Icons.shield_outlined,
                S.of(context).safetyCenter,
                S.of(context).safetySection,
                () {
                  Navigator.pop(ctx);
                  Navigator.push(
                    context,
                    slideFromRightRoute(const DriverSafetyScreen()),
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
        behavior: HitTestBehavior.opaque,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: neuBox(radius: 16),
          child: Row(
            children: [
              Container(
                width: 38,
                height: 38,
                decoration: neuBox(radius: 13, pressed: true),
                child: Icon(icon, color: _gold, size: 19),
              ),
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
        backgroundColor: neuSurface,
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
              backgroundColor: _danger,
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
