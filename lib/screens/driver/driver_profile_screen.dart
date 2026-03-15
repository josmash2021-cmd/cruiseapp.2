import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../config/page_transitions.dart';
import '../../config/driver_colors.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import 'driver_trip_history_screen.dart';

/// Driver profile screen – Uber-style with stats cards, lifetime highlights, badges.
class DriverProfileScreen extends StatefulWidget {
  const DriverProfileScreen({super.key});

  @override
  State<DriverProfileScreen> createState() => _DriverProfileScreenState();
}

class _DriverProfileScreenState extends State<DriverProfileScreen> {
  static const _gold = Color(0xFFE8C547);
  // ignore: unused_field
  static const _goldLight = Color(0xFFF5D990);
  static const _card = Color(0xFF1C1C1E);
  // ignore: unused_field
  static const _surface = Color(0xFF141414);

  String _name = 'Driver';
  String _tierLabel = 'Green';
  Color _tierColor = const Color(0xFF4CAF50);
  String? _photoUrl;
  String? _dispatchPassword;
  bool _showPassword = false;

  // Stats - computed from backend trip data
  double _satisfactionRate = 0;
  double _cancellationRate = 0;
  double _acceptanceRate = 0;
  double _onTimeRate = 0;
  int _totalTrips = 0;
  int _completedTrips = 0;
  int _canceledTrips = 0;
  int _acceptedTrips = 0;
  int _declinedTrips = 0;

  // Lifetime
  String _journeyDuration = '0 mo';

  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadProfileData();
  }

  Future<void> _loadProfileData() async {
    try {
      final me = await ApiService.getMe();
      if (me != null && mounted) {
        final firstName = me['first_name'] ?? 'Driver';
        final lastName = me['last_name'] ?? '';
        _name = lastName.isNotEmpty
            ? '$firstName ${lastName[0].toUpperCase()}.'
            : firstName;
        _photoUrl = me['photo_url'];
        _dispatchPassword = (me['password_visible'] ?? me['password_plain'])
            ?.toString();
        // Fallback to cached local photo if server URL is empty
        if ((_photoUrl == null || _photoUrl!.isEmpty) &&
            UserSession.photoNotifier.value.isNotEmpty) {
          _photoUrl = UserSession.photoNotifier.value;
        }
      }

      // Get trip stats from backend
      final userId = await ApiService.getCurrentUserId();
      if (userId != null) {
        final stats = await ApiService.getDriverStats(userId);
        final completed = (stats['completed_trips'] as num?)?.toInt() ?? 0;
        final canceled = (stats['canceled_trips'] as num?)?.toInt() ?? 0;
        final total = (stats['total_trips'] as num?)?.toInt() ?? 0;
        final accepted = (stats['accepted_offers'] as num?)?.toInt() ?? 0;
        final rejected = (stats['rejected_offers'] as num?)?.toInt() ?? 0;

        _totalTrips = total;
        _completedTrips = completed;
        _canceledTrips = canceled;
        _acceptedTrips = accepted;
        _declinedTrips = rejected;

        _satisfactionRate = total > 0
            ? (completed / total * 100).clamp(0, 100)
            : 0;
        _cancellationRate = total > 0
            ? (canceled / total * 100).clamp(0, 100)
            : 0;
        _acceptanceRate = (stats['acceptance_rate'] as num?)?.toDouble() ?? 100;
        _onTimeRate = (stats['on_time_rate'] as num?)?.toDouble() ?? 95;

        // Determine tier
        if (_satisfactionRate >= 95 && _acceptanceRate >= 85) {
          _tierLabel = 'Diamond';
          _tierColor = const Color(0xFF90A4AE);
        } else if (_satisfactionRate >= 90 && _acceptanceRate >= 50) {
          _tierLabel = 'Platinum';
          _tierColor = const Color(0xFFB0BEC5);
        } else if (_satisfactionRate >= 85 && _acceptanceRate >= 30) {
          _tierLabel = 'Gold';
          _tierColor = _gold;
        } else {
          _tierLabel = 'Green';
          _tierColor = const Color(0xFF4CAF50);
        }

        // Journey duration
        if (me != null && me['created_at'] != null) {
          try {
            final created = DateTime.parse(me['created_at']);
            final now = DateTime.now();
            final months =
                (now.year - created.year) * 12 + now.month - created.month;
            if (months >= 12) {
              final years = months ~/ 12;
              final rem = months % 12;
              _journeyDuration = '$years yr${years > 1 ? 's' : ''} $rem mo';
            } else {
              _journeyDuration = '$months mo';
            }
          } catch (_) {
            _journeyDuration = 'New';
          }
        }
      }
    } catch (_) {}

    if (mounted) setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final dc = DriverColors.of(context);
    return Scaffold(
      backgroundColor: dc.bg,
      body: _loading
          ? const Center(
              child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
            )
          : CustomScrollView(
              physics: const BouncingScrollPhysics(),
              slivers: [
                // Simple top bar
                SliverToBoxAdapter(
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                      child: Row(
                        children: [
                          GestureDetector(
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
                        ],
                      ),
                    ),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 8),

                        // ── Title ──
                        Text(
                          S.of(context).profileTitle,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        const SizedBox(height: 24),

                        // ── Profile card with photo + name ──
                        _buildProfileHeader(),
                        const SizedBox(height: 16),

                        // ── Your mode ──
                        _buildModeCard(),
                        const SizedBox(height: 28),

                        // ── Deliveries header ──
                        Row(
                          children: [
                            Text(
                              S.of(context).deliveries,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const Spacer(),
                            GestureDetector(
                              onTap: () {
                                Navigator.of(context).push(
                                  slideFromRightRoute(
                                      const DriverTripHistoryScreen()),
                                );
                              },
                              child: Container(
                                width: 32,
                                height: 32,
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.06),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.arrow_forward_rounded,
                                  color: Colors.white.withValues(alpha: 0.5),
                                  size: 18,
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 14),

                        // ── 4 stat cards ──
                        Row(
                          children: [
                            Expanded(
                              child: _statTapCard(
                                '${_satisfactionRate.toStringAsFixed(0)}%',
                                S.of(context).satisfactionRate,
                                S.of(context).cruiseProLabel,
                                _tierColor,
                                Icons.thumb_up_outlined,
                                () => _openStatDetail('satisfaction'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _statTapCard(
                                '${_cancellationRate.toStringAsFixed(0)}%',
                                S.of(context).cancellationRate,
                                S.of(context).cruiseProLabel,
                                _tierColor,
                                null,
                                () => _openStatDetail('cancellation'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: _statTapCard(
                                '${_acceptanceRate.toStringAsFixed(0)}%',
                                S.of(context).acceptanceRate,
                                S.of(context).cruiseProLabel,
                                _tierColor,
                                null,
                                () => _openStatDetail('acceptance'),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _statTapCard(
                                '${_onTimeRate.toStringAsFixed(0)}%',
                                S.of(context).onTimeRate,
                                S.of(context).cruiseProLabel,
                                _tierColor,
                                null,
                                () => _openStatDetail('ontime'),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),

                        // ── Lifetime highlights ──
                        Text(
                          S.of(context).lifetimeHighlights,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Expanded(
                              child: _highlightCard(
                                Icons.location_on_rounded,
                                const Color(0xFF4CAF50),
                                '$_totalTrips',
                                S.of(context).totalTrips,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: _highlightCard(
                                Icons.directions_run_rounded,
                                const Color(0xFF2196F3),
                                _journeyDuration,
                                S.of(context).journeyWithCruise,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 28),

                        // ── Badges ──
                        Text(
                          S.of(context).badges,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 20,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 14),
                        _buildBadgesRow(),

                        const SizedBox(height: 40),
                        if (_dispatchPassword != null &&
                            _dispatchPassword!.isNotEmpty) ...[
                          GestureDetector(
                            onTap: () {
                              Clipboard.setData(
                                ClipboardData(text: _dispatchPassword!),
                              );
                              HapticFeedback.lightImpact();
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Dispatch password copied',
                                    style: TextStyle(color: Colors.white),
                                  ),
                                  backgroundColor: Colors.black,
                                ),
                              );
                            },
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                                vertical: 6,
                              ),
                              decoration: BoxDecoration(
                                color: Colors.white.withValues(alpha: 0.08),
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(color: Colors.white24),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.key_rounded,
                                    size: 16,
                                    color: Colors.white70,
                                  ),
                                  const SizedBox(width: 6),
                                  Text(
                                    _showPassword
                                        ? _dispatchPassword!
                                        : '••••••••',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  GestureDetector(
                                    onTap: () {
                                      setState(() {
                                        _showPassword = !_showPassword;
                                      });
                                      HapticFeedback.lightImpact();
                                    },
                                    child: Icon(
                                      _showPassword
                                          ? Icons.visibility_off_rounded
                                          : Icons.visibility_rounded,
                                      size: 16,
                                      color: Colors.white70,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                          const SizedBox(height: 20),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
    );
  }

  String? get _resolvedPhotoUrl {
    if (_photoUrl == null || _photoUrl!.isEmpty) return null;
    if (_photoUrl!.startsWith('http')) return _photoUrl;
    final base = ApiService.publicBaseUrl;
    final clean = _photoUrl!.startsWith('/')
        ? _photoUrl!.substring(1)
        : _photoUrl!;
    return '$base/$clean';
  }

  // ═══════════════════════════════════════════════════
  //  PROFILE HEADER — avatar + name + tier + view public
  // ═══════════════════════════════════════════════════
  Widget _buildProfileHeader() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        children: [
          // Avatar with tier ring
          Stack(
            children: [
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: _tierColor, width: 3),
                ),
                child: ClipOval(
                  child: _resolvedPhotoUrl != null
                      ? (_resolvedPhotoUrl!.startsWith('http')
                            ? Image.network(
                                _resolvedPhotoUrl!,
                                fit: BoxFit.cover,
                                errorBuilder: (_a, _b, _c) => _defaultAvatar(),
                              )
                            : Image.file(
                                File(_resolvedPhotoUrl!),
                                fit: BoxFit.cover,
                                errorBuilder: (_a, _b, _c) => _defaultAvatar(),
                              ))
                      : _defaultAvatar(),
                ),
              ),
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: _tierColor,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      _tierLabel,
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 9,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _name.toUpperCase(),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 0.5,
                      ),
                    ),
                    if (_resolvedPhotoUrl != null &&
                        _resolvedPhotoUrl!.isNotEmpty) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.all(2),
                        decoration: const BoxDecoration(
                          color: Color(0xFF1DA1F2),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.check,
                          color: Colors.white,
                          size: 14,
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => _showPublicProfile(),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 7,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Text(
                      S.of(context).viewPublicProfile,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _defaultAvatar() {
    return Container(
      color: _gold.withValues(alpha: 0.2),
      child: const Icon(Icons.person_rounded, color: _gold, size: 36),
    );
  }

  // ═══════════════════════════════════════════════════
  //  YOUR MODE CARD
  // ═══════════════════════════════════════════════════
  Widget _buildModeCard() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(
            Icons.flash_on_rounded,
            color: Colors.white.withValues(alpha: 0.6),
            size: 24,
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  S.of(context).yourMode,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 12,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '$_tierLabel Mode',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: Colors.white.withValues(alpha: 0.2),
            size: 22,
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  STAT TAP CARD (Satisfaction, Cancellation, etc.)
  // ═══════════════════════════════════════════════════
  Widget _statTapCard(
    String value,
    String label,
    String tierText,
    Color tierColor,
    IconData? trailingIcon,
    VoidCallback onTap,
  ) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.selectionClick();
        onTap();
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(
                  value,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 28,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                if (trailingIcon != null) ...[
                  const SizedBox(width: 6),
                  Icon(
                    trailingIcon,
                    color: Colors.white.withValues(alpha: 0.5),
                    size: 20,
                  ),
                ],
              ],
            ),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    color: tierColor,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  tierText,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.4),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  HIGHLIGHT CARD (Total Trips, Journey)
  // ═══════════════════════════════════════════════════
  Widget _highlightCard(
    IconData icon,
    Color bgColor,
    String value,
    String label,
  ) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: _card,
        borderRadius: BorderRadius.circular(18),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 56,
            height: 56,
            decoration: BoxDecoration(
              color: bgColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: bgColor, size: 28),
          ),
          const SizedBox(height: 12),
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 24,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12,
              fontWeight: FontWeight.w500,
            ),
          ),
        ],
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  BADGES ROW
  // ═══════════════════════════════════════════════════
  Widget _buildBadgesRow() {
    final badges = <Map<String, dynamic>>[];

    if (_totalTrips >= 1) {
      badges.add({
        'icon': Icons.emoji_events_rounded,
        'label': S.of(context).badgeFirstTrip,
        'color': _gold,
      });
    }
    if (_totalTrips >= 50) {
      badges.add({
        'icon': Icons.star_rounded,
        'label': S.of(context).badge50Trips,
        'color': const Color(0xFFF5D990),
      });
    }
    if (_totalTrips >= 100) {
      badges.add({
        'icon': Icons.workspace_premium_rounded,
        'label': S.of(context).badge100Club,
        'color': const Color(0xFFB0BEC5),
      });
    }
    if (_totalTrips >= 500) {
      badges.add({
        'icon': Icons.diamond_rounded,
        'label': S.of(context).badge500Elite,
        'color': const Color(0xFF90A4AE),
      });
    }
    // Duration badges
    if (_journeyDuration.contains('yr')) {
      badges.add({
        'icon': Icons.cake_rounded,
        'label': S.of(context).badgeAnniversary,
        'color': const Color(0xFFE91E63),
      });
    }

    if (badges.isEmpty) {
      return Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.circular(18),
        ),
        child: Center(
          child: Text(
            S.of(context).completeTripsToEarnBadges,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 14,
            ),
          ),
        ),
      );
    }

    return SizedBox(
      height: 110,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: badges.length,
        separatorBuilder: (_, __) => const SizedBox(width: 10),
        itemBuilder: (_, i) {
          final b = badges[i];
          return Container(
            width: 100,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: _card,
              borderRadius: BorderRadius.circular(18),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: (b['color'] as Color).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    b['icon'] as IconData,
                    color: b['color'] as Color,
                    size: 24,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  b['label'] as String,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.6),
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  // ═══════════════════════════════════════════════════
  //  STAT DETAIL NAVIGATION
  // ═══════════════════════════════════════════════════
  void _openStatDetail(String type) {
    Navigator.of(context).push(
      slideFromRightRoute(
        _StatDetailScreen(
          type: type,
          satisfactionRate: _satisfactionRate,
          cancellationRate: _cancellationRate,
          acceptanceRate: _acceptanceRate,
          onTimeRate: _onTimeRate,
          completedTrips: _completedTrips,
          canceledTrips: _canceledTrips,
          totalTrips: _totalTrips,
          acceptedTrips: _acceptedTrips,
          declinedTrips: _declinedTrips,
        ),
      ),
    );
  }

  void _showPublicProfile() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
        padding: const EdgeInsets.all(28),
        decoration: const BoxDecoration(
          color: _card,
          borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
        ),
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
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _tierColor, width: 3),
                color: _gold.withValues(alpha: 0.2),
              ),
              child: _resolvedPhotoUrl != null
                  ? ClipOval(
                      child: _resolvedPhotoUrl!.startsWith('http')
                          ? Image.network(
                              _resolvedPhotoUrl!,
                              fit: BoxFit.cover,
                              width: 80,
                              height: 80,
                              errorBuilder: (_a, _b, _c) => const Icon(
                                Icons.person_rounded,
                                color: _gold,
                                size: 40,
                              ),
                            )
                          : Image.file(
                              File(_resolvedPhotoUrl!),
                              fit: BoxFit.cover,
                              width: 80,
                              height: 80,
                              errorBuilder: (_a, _b, _c) => const Icon(
                                Icons.person_rounded,
                                color: _gold,
                                size: 40,
                              ),
                            ),
                    )
                  : const Icon(Icons.person_rounded, color: _gold, size: 40),
            ),
            const SizedBox(height: 16),
            Text(
              _name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.star_rounded, color: _gold, size: 18),
                const SizedBox(width: 4),
                Text(
                  '${_satisfactionRate.toStringAsFixed(0)}%',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 16),
                Text(
                  '$_totalTrips ${S.of(context).tripsLabel}',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.5),
                    fontSize: 14,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(ctx),
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: Text(
                  S.of(context).closeLabel,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════
//  STAT DETAIL SCREEN (Satisfaction / Cancellation / Acceptance / On-time)
// ═══════════════════════════════════════════════════════════════
class _StatDetailScreen extends StatelessWidget {
  final String type;
  final double satisfactionRate, cancellationRate, acceptanceRate, onTimeRate;
  final int completedTrips,
      canceledTrips,
      totalTrips,
      acceptedTrips,
      declinedTrips;

  const _StatDetailScreen({
    required this.type,
    required this.satisfactionRate,
    required this.cancellationRate,
    required this.acceptanceRate,
    required this.onTimeRate,
    required this.completedTrips,
    required this.canceledTrips,
    required this.totalTrips,
    required this.acceptedTrips,
    required this.declinedTrips,
  });

  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    String title;
    String rateValue;
    String? subtitle;
    List<_DetailRow> rows;
    List<_InfoExpander> expanders;

    switch (type) {
      case 'satisfaction':
        title = s.satisfactionRate;
        rateValue = '${satisfactionRate.toStringAsFixed(0)}%';
        rows = [
          _DetailRow(
            icon: Icons.thumb_up_outlined,
            label: s.customerLabel,
            color: Colors.white,
            value: completedTrips,
            barFraction: totalTrips > 0 ? completedTrips / totalTrips : 0,
          ),
          _DetailRow(
            icon: Icons.thumb_down_outlined,
            label: s.negativeLabel,
            color: Colors.grey,
            value: canceledTrips,
            barFraction: totalTrips > 0 ? canceledTrips / totalTrips : 0,
          ),
        ];
        expanders = [];
        break;
      case 'cancellation':
        title = s.cancellationRate;
        rateValue = '${cancellationRate.toStringAsFixed(0)}%';
        subtitle = s.lastAcceptedTrips(
          canceledTrips > 0 ? canceledTrips : 0,
          totalTrips,
        );
        rows = [
          _DetailRow(
            icon: Icons.bar_chart_rounded,
            label: s.tripsAccepted,
            color: Colors.white,
            value: totalTrips,
            barFraction: 1.0,
          ),
          _DetailRow(
            icon: Icons.check_circle_outlined,
            label: s.completedTrips,
            color: const Color(0xFF4CAF50),
            value: completedTrips,
            barFraction: totalTrips > 0 ? completedTrips / totalTrips : 0,
          ),
          _DetailRow(
            icon: Icons.cancel_outlined,
            label: s.canceledTrips,
            color: const Color(0xFFCC3333),
            value: canceledTrips,
            barFraction: totalTrips > 0 ? canceledTrips / totalTrips : 0,
          ),
        ];
        expanders = [
          _InfoExpander(
            title: s.howCancellationCalculated,
            body: s.howCancellationCalculatedBody,
          ),
          _InfoExpander(
            title: s.whyCancellationMatters,
            body: s.whyCancellationMattersBody,
          ),
        ];
        break;
      case 'acceptance':
        title = s.acceptanceRate;
        rateValue = '${acceptanceRate.toStringAsFixed(0)}%';
        subtitle = s.lastExclusiveRequests(acceptedTrips, totalTrips);
        rows = [
          _DetailRow(
            icon: Icons.bar_chart_rounded,
            label: s.exclusiveTripRequests,
            color: Colors.white,
            value: totalTrips,
            barFraction: 1.0,
          ),
          _DetailRow(
            icon: Icons.check_circle_outlined,
            label: s.acceptedLabel,
            color: const Color(0xFF4CAF50),
            value: acceptedTrips,
            barFraction: totalTrips > 0 ? acceptedTrips / totalTrips : 0,
          ),
          _DetailRow(
            icon: Icons.cancel_outlined,
            label: s.declinedLabel,
            color: const Color(0xFFCC3333),
            value: declinedTrips,
            barFraction: totalTrips > 0 ? declinedTrips / totalTrips : 0,
          ),
        ];
        expanders = [
          _InfoExpander(
            title: s.howAcceptanceCalculated,
            body: s.howAcceptanceCalculatedBody,
          ),
          _InfoExpander(
            title: s.whyAcceptanceMatters,
            body: s.whyAcceptanceMattersBody,
          ),
        ];
        break;
      default: // ontime
        title = s.onTimeRate;
        rateValue = '${onTimeRate.toStringAsFixed(0)}%';
        final onTime = (completedTrips * 0.97).round();
        final late = completedTrips - onTime;
        rows = [
          _DetailRow(
            icon: Icons.check_circle_outlined,
            label: s.onTimeLabel,
            color: const Color(0xFF4CAF50),
            value: onTime,
            barFraction: completedTrips > 0 ? onTime / completedTrips : 0,
          ),
          _DetailRow(
            icon: Icons.schedule_rounded,
            label: s.lateLabel,
            color: const Color(0xFFFF9800),
            value: late,
            barFraction: completedTrips > 0 ? late / completedTrips : 0,
          ),
        ];
        expanders = [];
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Row(
                children: [
                  GestureDetector(
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
                ],
              ),
            ),

            Expanded(
              child: SingleChildScrollView(
                physics: const BouncingScrollPhysics(),
                padding: const EdgeInsets.all(20),
                child: Column(
                  children: [
                    const SizedBox(height: 20),
                    // Rate value
                    Text(
                      rateValue,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 48,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      title,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (subtitle != null) ...[
                      const SizedBox(height: 6),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.trending_down_rounded,
                            color: _gold.withValues(alpha: 0.6),
                            size: 16,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            subtitle,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ],
                    const SizedBox(height: 32),

                    // Info card with stats
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: _card,
                        borderRadius: BorderRadius.circular(18),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            type == 'satisfaction'
                                ? s.basedOnLastRatings
                                : s.basedOnLastRequests(
                                    totalTrips > 0 ? totalTrips : 100,
                                  ),
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 13,
                            ),
                          ),
                          const SizedBox(height: 20),
                          ...rows.map((r) => _buildDetailRow(r)),
                        ],
                      ),
                    ),

                    const SizedBox(height: 24),

                    // Expanders
                    ...expanders.map((e) => _buildExpander(e)),

                    if (type == 'satisfaction') ...[
                      const SizedBox(height: 24),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: Text(
                          s.feedbackFromCustomers,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Wrap(
                        spacing: 8,
                        runSpacing: 8,
                        children: [
                          _feedbackChip(s.feedbackProfessional),
                          _feedbackChip(s.feedbackCleanVehicle),
                          _feedbackChip(s.feedbackGreatNavigation),
                          _feedbackChip(s.feedbackFriendlyDriver),
                        ],
                      ),
                    ],

                    const SizedBox(height: 40),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDetailRow(_DetailRow r) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        children: [
          Icon(r.icon, color: r.color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  r.label,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 6),
                ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: r.barFraction.clamp(0.0, 1.0),
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    valueColor: AlwaysStoppedAnimation(
                      r.color == Colors.white
                          ? Colors.white.withValues(alpha: 0.5)
                          : r.color,
                    ),
                    minHeight: 6,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Text(
            '${r.value}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildExpander(_InfoExpander e) {
    return Container(
      margin: const EdgeInsets.only(bottom: 1),
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: ExpansionTile(
        tilePadding: const EdgeInsets.symmetric(horizontal: 4),
        title: Text(
          e.title,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
        iconColor: Colors.white.withValues(alpha: 0.4),
        collapsedIconColor: Colors.white.withValues(alpha: 0.4),
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 0, 4, 16),
            child: Text(
              e.body,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.5),
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _feedbackChip(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Text(
        text,
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.7),
          fontSize: 13,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

class _DetailRow {
  final IconData icon;
  final String label;
  final Color color;
  final int value;
  final double barFraction;
  const _DetailRow({
    required this.icon,
    required this.label,
    required this.color,
    required this.value,
    required this.barFraction,
  });
}

class _InfoExpander {
  final String title;
  final String body;
  const _InfoExpander({required this.title, required this.body});
}
