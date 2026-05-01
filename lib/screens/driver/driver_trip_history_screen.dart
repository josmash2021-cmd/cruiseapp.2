import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import '../../services/api_service.dart';
import '../../services/user_session.dart';
import '../../l10n/app_localizations.dart';

/// Trip history screen with filterable past rides list.
class DriverTripHistoryScreen extends StatefulWidget {
  const DriverTripHistoryScreen({super.key});

  @override
  State<DriverTripHistoryScreen> createState() =>
      _DriverTripHistoryScreenState();
}

class _DriverTripHistoryScreenState extends State<DriverTripHistoryScreen> {
  static const _gold = Color(0xFFE8C547);
  static const _card = Color(0xFF1C1C1E);
  static const _surface = Color(0xFF141414);
  static const _red = Color(0xFFFF453A);

  int _selectedFilter = 0; // 0=All, 1=Completed, 2=Cancelled

  bool _loading = true;
  List<Map<String, dynamic>> _trips = [];

  List<Map<String, dynamic>> get _filtered {
    if (_selectedFilter == 0) return _trips;
    final status = _selectedFilter == 1 ? 'completed' : 'cancelled';
    return _trips.where((t) => t['status'] == status).toList();
  }

  int get _completedCount =>
      _trips.where((t) => t['status'] == 'completed').length;
  int get _cancelledCount =>
      _trips.where((t) => t['status'] == 'cancelled').length;
  double get _totalEarnings => _trips
      .where((t) => t['status'] == 'completed')
      .fold<double>(0, (a, t) => a + ((t['fare'] as num?)?.toDouble() ?? 0));

  @override
  void initState() {
    super.initState();
    _fetchTrips();
  }

  Future<void> _fetchTrips() async {
    setState(() => _loading = true);
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId == null || !mounted) return;
      final trips = await ApiService.getDriverTrips(userId);
      if (!mounted) return;
      setState(() {
        _trips = trips;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final filters = [s.allFilter, s.completedFilter, s.cancelledFilter];
    return Scaffold(
      backgroundColor: Colors.black,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── AppBar with back chevron ──
          SliverAppBar(
            backgroundColor: _surface,
            pinned: true,
            expandedHeight: 110,
            automaticallyImplyLeading: false,
            leading: IconButton(
              icon: const Icon(Icons.chevron_left_rounded, color: _gold, size: 28),
              onPressed: () => Navigator.pop(context),
            ),
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 56, bottom: 16),
              title: Text(
                s.tripHistoryTitle,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),

          // ── Stats header with gradient and icons ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 20, 20, 0),
              child: Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      _card,
                      const Color(0xFF252528),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
                child: Row(
                  children: [
                    _summStat(
                      value: '$_completedCount',
                      label: s.completedFilter,
                      icon: Icons.check_circle_rounded,
                      iconColor: _gold,
                      valueColor: Colors.white,
                    ),
                    _dividerVert(),
                    _summStat(
                      value: '$_cancelledCount',
                      label: s.cancelledFilter,
                      icon: Icons.cancel_rounded,
                      iconColor: _red.withValues(alpha: 0.7),
                      valueColor: Colors.white.withValues(alpha: 0.7),
                    ),
                    _dividerVert(),
                    _summStat(
                      value: '\$${_totalEarnings.toStringAsFixed(0)}',
                      label: s.total,
                      icon: Icons.attach_money_rounded,
                      iconColor: _gold,
                      valueColor: _gold,
                    ),
                  ],
                ),
              ),
            ),
          ),

          // ── Filter tabs ──
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
              child: Row(
                children: List.generate(3, (i) {
                  final sel = i == _selectedFilter;
                  return Expanded(
                    child: GestureDetector(
                      onTap: () {
                        HapticService.selectionClick();
                        setState(() => _selectedFilter = i);
                      },
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                        margin: EdgeInsets.only(right: i < 2 ? 8 : 0),
                        padding: const EdgeInsets.symmetric(vertical: 10),
                        decoration: BoxDecoration(
                          color: sel
                              ? _gold.withValues(alpha: 0.12)
                              : Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(24),
                          border: sel
                              ? Border.all(
                                  color: _gold.withValues(alpha: 0.35),
                                  width: 1.2,
                                )
                              : null,
                        ),
                        child: Text(
                          filters[i],
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: sel ? _gold : Colors.white38,
                            fontSize: 13,
                            fontWeight: sel ? FontWeight.w800 : FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  );
                }),
              ),
            ),
          ),

          // ── Trip list ──
          SliverPadding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            sliver: _loading
                ? const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.only(top: 60),
                      child: Center(
                        child: CircularProgressIndicator(
                          color: _gold,
                          strokeWidth: 2,
                        ),
                      ),
                    ),
                  )
                : _filtered.isEmpty
                ? SliverToBoxAdapter(
                    child: _emptyState(),
                  )
                : SliverList(
                    delegate: SliverChildBuilderDelegate(
                      (ctx, i) => _tripCard(_filtered[i], i),
                      childCount: _filtered.length,
                    ),
                  ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 40)),
        ],
      ),
    );
  }

  // ── Empty state ──
  Widget _emptyState() {
    final s = S.of(context);
    String message;
    IconData icon;
    if (_selectedFilter == 1) {
      message = s.noCompletedTrips;
      icon = Icons.check_circle_outline_rounded;
    } else if (_selectedFilter == 2) {
      message = s.noCancelledTrips;
      icon = Icons.cancel_outlined;
    } else {
      message = s.noTripsFound;
      icon = Icons.history_rounded;
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.only(top: 60),
        child: Column(
          children: [
            Icon(
              icon,
              color: Colors.white.withValues(alpha: 0.1),
              size: 60,
            ),
            const SizedBox(height: 16),
            Text(
              message,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.3),
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(String raw, BuildContext context) {
    final dt = DateTime.tryParse(raw);
    if (dt == null) return raw;
    final now = DateTime.now();
    final diff = now.difference(dt);
    final s = S.of(context);
    if (diff.inDays == 0) {
      final h = dt.hour > 12 ? dt.hour - 12 : dt.hour;
      final ampm = dt.hour >= 12 ? 'PM' : 'AM';
      return '${s.todayDatePrefix}, $h:${dt.minute.toString().padLeft(2, '0')} $ampm';
    } else if (diff.inDays == 1) {
      final h = dt.hour > 12 ? dt.hour - 12 : dt.hour;
      final ampm = dt.hour >= 12 ? 'PM' : 'AM';
      return '${s.yesterdayDatePrefix}, $h:${dt.minute.toString().padLeft(2, '0')} $ampm';
    }
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${months[dt.month - 1]} ${dt.day}';
  }

  Widget _tripCard(Map<String, dynamic> trip, int index) {
    final completed = trip['status'] == 'completed';
    final pickup = (trip['pickup_address'] ?? trip['pickup'] ?? '') as String;
    final dropoff =
        (trip['dropoff_address'] ?? trip['dropoff'] ?? '') as String;
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0.0;
    final tip = (trip['tip'] as num?)?.toDouble() ?? 0.0;
    final riderName =
        (trip['rider'] ?? trip['rider_name'] ?? dropoff) as String;
    final date = (trip['date'] ?? trip['created_at'] ?? '') as String;
    // Prefer computed fields from backend; fallback to raw distance/duration
    final distance = (trip['distance_miles'] as num?)?.toDouble() ??
        (trip['distance'] as num?)?.toDouble() ?? 0.0;
    final duration = (trip['duration_minutes'] as num?)?.toInt() ??
        (trip['duration'] as num?)?.toInt() ?? 0;

    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: Duration(milliseconds: 350 + (index * 60)),
      curve: Curves.easeOut,
      builder: (context, value, child) => Opacity(
        opacity: value,
        child: Transform.translate(
          offset: Offset(0, 20 * (1 - value)),
          child: child,
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: completed ? _card : const Color(0xFF18181A),
          borderRadius: BorderRadius.circular(20),
          border: completed
              ? Border.all(color: Colors.white.withValues(alpha: 0.05))
              : Border.all(color: _red.withValues(alpha: 0.2)),
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(20),
          child: InkWell(
            borderRadius: BorderRadius.circular(20),
            onTap: () => _showTripDetails(trip),
            splashColor: _gold.withValues(alpha: 0.08),
            highlightColor: _gold.withValues(alpha: 0.04),
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: Column(
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // ── Circular badge ──
                      Container(
                        width: 46,
                        height: 46,
                        decoration: BoxDecoration(
                          gradient: completed
                              ? LinearGradient(
                                  colors: [
                                    _gold.withValues(alpha: 0.2),
                                    _gold.withValues(alpha: 0.08),
                                  ],
                                  begin: Alignment.topLeft,
                                  end: Alignment.bottomRight,
                                )
                              : null,
                          color: completed
                              ? null
                              : _red.withValues(alpha: 0.1),
                          shape: BoxShape.circle,
                        ),
                        child: Center(
                          child: completed
                              ? const Icon(
                                  Icons.check_rounded,
                                  color: _gold,
                                  size: 22,
                                )
                              : Icon(
                                  Icons.close_rounded,
                                  color: _red.withValues(alpha: 0.7),
                                  size: 22,
                                ),
                        ),
                      ),
                      const SizedBox(width: 14),

                      // ── Address + date ──
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              dropoff.isNotEmpty
                                  ? dropoff
                                  : S.of(context).tripFallback,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Icon(
                                  Icons.location_on_outlined,
                                  size: 12,
                                  color: Colors.white.withValues(alpha: 0.25),
                                ),
                                const SizedBox(width: 4),
                                Expanded(
                                  child: Text(
                                    pickup.isNotEmpty
                                        ? pickup
                                        : S.of(context).pickupFallback,
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.35),
                                      fontSize: 12,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 6),
                            Text(
                              _formatDate(date, context),
                              style: TextStyle(
                                color: Colors.white.withValues(alpha: 0.3),
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(width: 10),

                      // ── Price / Cancelled badge ──
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        children: [
                          if (completed)
                            Text(
                              '\$${fare.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 18,
                                fontWeight: FontWeight.w900,
                              ),
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 5,
                              ),
                              decoration: BoxDecoration(
                                color: _red.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                S.of(context).cancelledBadge,
                                style: TextStyle(
                                  color: _red.withValues(alpha: 0.9),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          if (completed && tip > 0) ...[
                            const SizedBox(height: 4),
                            Text(
                              '+\$${tip.toStringAsFixed(2)} ${S.of(context).tipSuffix}',
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),

                  // ── Distance / Duration / Rating row ──
                  if (completed) ...[
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(12),
                      ),
                      child: Row(
                        children: [
                          if (distance > 0)
                            _miniInfo(
                              Icons.route_rounded,
                              '${distance.toStringAsFixed(1)} mi',
                            )
                          else
                            _miniInfo(
                              Icons.route_rounded,
                              '-',
                            ),
                          const SizedBox(width: 16),
                          if (duration > 0)
                            _miniInfo(
                              Icons.schedule_rounded,
                              '$duration min',
                            )
                          else
                            _miniInfo(
                              Icons.schedule_rounded,
                              '-',
                            ),
                          const Spacer(),
                          Row(
                            children: List.generate(
                              5,
                              (j) => Icon(
                                Icons.star_rounded,
                                size: 14,
                                color:
                                    j < ((trip['rating'] as num?)?.toInt() ?? 0)
                                    ? _gold
                                    : Colors.white.withValues(alpha: 0.1),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _miniInfo(IconData icon, String text) {
    return Row(
      children: [
        Icon(icon, size: 13, color: Colors.white.withValues(alpha: 0.3)),
        const SizedBox(width: 5),
        Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _summStat({
    required String value,
    required String label,
    required IconData icon,
    required Color iconColor,
    required Color valueColor,
  }) {
    return Expanded(
      child: Column(
        children: [
          Icon(icon, size: 20, color: iconColor),
          const SizedBox(height: 8),
          Text(
            value,
            style: TextStyle(
              color: valueColor,
              fontSize: 22,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _dividerVert() {
    return Container(
      width: 1,
      height: 50,
      margin: const EdgeInsets.symmetric(horizontal: 12),
      color: Colors.white.withValues(alpha: 0.08),
    );
  }

  void _showTripDetails(Map<String, dynamic> trip) {
    final completed = trip['status'] == 'completed';
    final pickup = (trip['pickup_address'] ?? trip['pickup'] ?? '') as String;
    final dropoff =
        (trip['dropoff_address'] ?? trip['dropoff'] ?? '') as String;
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0.0;
    final tip = (trip['tip'] as num?)?.toDouble() ?? 0.0;
    final distance = (trip['distance_miles'] as num?)?.toDouble() ??
        (trip['distance'] as num?)?.toDouble() ?? 0.0;
    final duration = (trip['duration_minutes'] as num?)?.toInt() ??
        (trip['duration'] as num?)?.toInt() ?? 0;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.all(24),
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
              Text(
                completed
                    ? S.of(context).tripDetails
                    : S.of(context).cancelledTrip,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 20),

              // Route
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    _detailRoute(
                      Icons.circle,
                      8,
                      const Color(0xFFE8C547),
                      S.of(context).pickupUpperLabel,
                      pickup,
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 3.5),
                      child: Container(
                        width: 1,
                        height: 20,
                        color: Colors.white12,
                      ),
                    ),
                    _detailRoute(
                      Icons.location_on_rounded,
                      14,
                      Colors.white.withValues(alpha: 0.5),
                      S.of(context).dropoffUpperLabel,
                      dropoff,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),

              if (completed) ...[
                Row(
                  children: [
                    _detailStat(
                      S.of(context).fareLabel,
                      '\$${fare.toStringAsFixed(2)}',
                    ),
                    _detailStat(
                      S.of(context).distanceLabel,
                      distance > 0 ? '${distance.toStringAsFixed(1)} mi' : '-',
                    ),
                    _detailStat(
                      S.of(context).durationLabel,
                      duration > 0 ? '$duration min' : '-',
                    ),
                    if (tip > 0)
                      _detailStat(
                        S.of(context).tipLabel,
                        '\$${tip.toStringAsFixed(2)}',
                      ),
                  ],
                ),
                const SizedBox(height: 16),
              ],

              const SizedBox(height: 8),
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
        );
      },
    );
  }

  Widget _detailRoute(
    IconData icon,
    double size,
    Color color,
    String label,
    String text,
  ) {
    return Row(
      children: [
        SizedBox(
          width: 8,
          child: Icon(icon, size: size, color: color),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.3),
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                text,
                style: const TextStyle(color: Colors.white, fontSize: 14),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailStat(String label, String value) {
    return Expanded(
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.35),
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}
