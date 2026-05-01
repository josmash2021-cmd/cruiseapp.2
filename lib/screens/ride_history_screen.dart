import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/local_data_service.dart';
import '../services/api_service.dart';
import '../widgets/tier_badge.dart';
import 'trip_receipt_screen.dart';

class RideHistoryScreen extends StatefulWidget {
  const RideHistoryScreen({super.key});

  @override
  State<RideHistoryScreen> createState() => _RideHistoryScreenState();
}

class _RideHistoryScreenState extends State<RideHistoryScreen> {
  static const _gold = Color(0xFFE8C547);
  List<TripHistoryItem> _trips = [];
  bool _loading = true;

  /// Format minutes into a human-readable string.
  ///   ≤ 60  → "45 min"
  ///   > 60  → "2h 15m"  (hours + minutes)
  static String _formatDuration(int minutes) {
    if (minutes <= 0) return '-- min';
    if (minutes < 60) return '$minutes min';
    final h = minutes ~/ 60;
    final m = minutes % 60;
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // Show cached trips instantly (cache-first)
    final localTrips = await LocalDataService.getTripHistory();
    if (!mounted) return;
    if (localTrips.isNotEmpty) {
      setState(() {
        _trips = localTrips;
        _loading = false;
      });
    }

    // Refresh from backend in background
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId != null) {
        final backendTrips = await ApiService.getRiderTrips(userId);
        if (backendTrips.isNotEmpty) {
          final parsed = backendTrips.map((t) {
            // Prefer computed fields from backend; fallback to raw distance/duration
            final double distanceMiles = (t['distance_miles'] as num?)?.toDouble() ??
                (t['distance'] as num?)?.toDouble() ?? 0.0;
            final int durationMinutes = (t['duration_minutes'] as num?)?.toInt() ??
                (t['duration'] as num?)?.toInt() ?? 0;
            return TripHistoryItem(
              tripId: (t['id'] as num?)?.toInt(),
              pickup: t['pickup_address']?.toString() ?? '',
              dropoff: t['dropoff_address']?.toString() ?? '',
              rideName: t['vehicle_type']?.toString() ?? 'Comfort',
              price:
                  '\$${((t['fare'] as num?)?.toDouble() ?? 0).toStringAsFixed(2)}',
              miles: distanceMiles > 0
                  ? '${distanceMiles.toStringAsFixed(1)} mi'
                  : '--',
              duration: _formatDuration(durationMinutes),
              createdAt:
                  DateTime.tryParse(t['created_at']?.toString() ?? '') ??
                  DateTime.now(),
            );
          }).toList();
          parsed.sort((a, b) => b.createdAt.compareTo(a.createdAt));

          if (!mounted) return;
          setState(() {
            _trips = parsed;
            _loading = false;
          });
          return;
        }
      }
    } catch (e) {
      debugPrint('[RideHistory] backend fallback to local: $e');
    }

    if (!mounted) return;
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);

    return Scaffold(
      backgroundColor: Colors.black,
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
                    color: const Color(0xFF1A1A1F),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.arrow_back_ios_new_rounded,
                    color: Colors.white,
                    size: 18,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 28),

            // ── Title ──
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                S.of(context).yourTrips,
                style: const TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: -0.5,
                ),
              ),
            ),
            const SizedBox(height: 20),

            // ── Content ──
            Expanded(
              child: _loading
                  ? Center(child: CircularProgressIndicator(color: _gold))
                  : _trips.isEmpty
                  ? _buildEmpty(c)
                  : RefreshIndicator(
                      color: _gold,
                      onRefresh: _load,
                      child: ListView.separated(
                        physics: const AlwaysScrollableScrollPhysics(
                          parent: BouncingScrollPhysics(),
                        ),
                        cacheExtent: 400,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 4,
                        ),
                        itemCount: _trips.length,
                        separatorBuilder: (context2, idx) =>
                            const SizedBox(height: 12),
                        itemBuilder: (context, i) =>
                            _buildTripCard(c, _trips[i]),
                      ),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmpty(AppColors c) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.directions_car_rounded,
            size: 64,
            color: c.textTertiary.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            S.of(context).noTripsYet,
            style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.w700,
              color: c.textPrimary,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            S.of(context).noTripsSubtitle,
            style: TextStyle(fontSize: 15, color: c.textSecondary),
          ),
        ],
      ),
    );
  }

  Widget _buildTripCard(AppColors c, TripHistoryItem trip) {
    final d = trip.createdAt;
    final months = [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ];
    final hour = d.hour > 12 ? d.hour - 12 : (d.hour == 0 ? 12 : d.hour);
    final ampm = d.hour >= 12 ? 'PM' : 'AM';
    final date =
        '${months[d.month - 1]} ${d.day}, ${d.year} · $hour:${d.minute.toString().padLeft(2, '0')} $ampm';

    return GestureDetector(
      onTap: () {
        Navigator.of(
          context,
        ).push(slideFromRightRoute(TripReceiptScreen(trip: trip)));
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1F),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.06),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Date & Price ──
            // Price split into "$" + amount + cents so the dollars
            // dominate visually and the cents read as a superscript-ish
            // suffix. White-on-black, no chip, no gold box.
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Expanded(
                  child: Text(
                    date,
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF9A9AA0),
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                _PriceText(raw: trip.price),
              ],
            ),
            const SizedBox(height: 14),

            // ── Pickup ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: const Color(0xFFE8C547),
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    trip.pickup,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: const _ShimmerConnector(),
            ),

            // ── Dropoff ──
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  // White SQUARE for the dropoff (was a gold circle).
                  // Pickup keeps its gold dot above; the change makes
                  // the two endpoints visually distinct at a glance.
                  width: 10,
                  height: 10,
                  margin: const EdgeInsets.only(top: 4),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    borderRadius: BorderRadius.circular(2),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.white.withValues(alpha: 0.30),
                        blurRadius: 4,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    trip.dropoff,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // ── Ride type + details ──
            Container(
              height: 1,
              color: Colors.white.withValues(alpha: 0.06),
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                TierBadge(rideName: trip.rideName),
                const Spacer(),
                // Distance · duration with subtle icons. Brighter than
                // before so it reads even on data with zero values.
                Icon(
                  Icons.straighten_rounded,
                  size: 13,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 4),
                Text(
                  trip.miles,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFFCFCFD4),
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 10),
                Icon(
                  Icons.schedule_rounded,
                  size: 13,
                  color: Colors.white.withValues(alpha: 0.55),
                ),
                const SizedBox(width: 4),
                Text(
                  trip.duration,
                  style: const TextStyle(
                    fontSize: 12.5,
                    color: Color(0xFFCFCFD4),
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
}

/// Formatted trip price — splits "$4.10" into a small "$" + big
/// dollars + small cents so amounts read like a premium receipt
/// instead of a chunky chip. White-on-black, no background.
/// Falls back to the raw string if the format is unexpected.
class _PriceText extends StatelessWidget {
  final String raw;
  const _PriceText({required this.raw});

  @override
  Widget build(BuildContext context) {
    final match = RegExp(r'^\$?(-?\d+)(?:\.(\d{1,2}))?').firstMatch(raw.trim());
    if (match == null) {
      return Text(
        raw,
        style: const TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: Colors.white,
        ),
      );
    }
    final whole = match.group(1) ?? '0';
    final cents = (match.group(2) ?? '00').padRight(2, '0').substring(0, 2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.only(top: 3),
          child: Text(
            '\$',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFFCFCFD4),
            ),
          ),
        ),
        const SizedBox(width: 1),
        Text(
          whole,
          style: const TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: -0.5,
            height: 1.0,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '.$cents',
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: Color(0xFFCFCFD4),
            ),
          ),
        ),
      ],
    );
  }
}

/// Vertical shimmer connector between pickup and dropoff dots.
/// 1.5 px wide, 18 px tall, gold gradient with a brighter highlight
/// that travels top -> bottom on a 1.6 s loop. Subtle on idle, draws
/// the eye to follow the pickup -> dropoff line.
class _ShimmerConnector extends StatefulWidget {
  const _ShimmerConnector();

  @override
  State<_ShimmerConnector> createState() => _ShimmerConnectorState();
}

class _ShimmerConnectorState extends State<_ShimmerConnector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 1.5,
      height: 18,
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (_, __) {
          final t = _ctl.value;
          // Highlight travels top -> bottom: stops shift each frame so
          // the bright band slides through the gradient.
          final start = (t - 0.15).clamp(0.0, 1.0);
          final mid = t.clamp(0.0, 1.0);
          final end = (t + 0.15).clamp(0.0, 1.0);
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const [
                  Color(0x55E8C547), // faint gold
                  Color(0xFFFFFFFF), // white highlight band
                  Color(0x55E8C547), // faint gold
                ],
                stops: [start, mid, end],
              ),
              borderRadius: BorderRadius.circular(1),
            ),
          );
        },
      ),
    );
  }
}
