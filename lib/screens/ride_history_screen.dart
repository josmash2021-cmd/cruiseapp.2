import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../config/page_transitions.dart';
import '../l10n/app_localizations.dart';
import '../services/local_data_service.dart';
import '../services/api_service.dart';
import '../widgets/neu_style.dart';
import '../widgets/tier_badge.dart';
import 'trip_receipt_screen.dart';

class RideHistoryScreen extends StatefulWidget {
  const RideHistoryScreen({super.key});

  @override
  State<RideHistoryScreen> createState() => _RideHistoryScreenState();
}

final _fareRe = RegExp(r'^\$?(-?\d+)(?:\.(\d{1,2}))?');

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
      backgroundColor: neuBase,
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
                  decoration: neuBox(radius: 14, pressed: true),
                  child: Icon(
                    Icons.arrow_back_rounded,
                    color: c.textPrimary,
                    size: 22,
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
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: c.textPrimary,
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
          Container(
            width: 96,
            height: 96,
            decoration: neuBox(radius: 24, pressed: true),
            child: Icon(
              Icons.directions_car_rounded,
              size: 44,
              color: _gold.withValues(alpha: 0.6),
            ),
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

    final tier = TierInfo.from(trip.rideName);
    final tierIcon = tier.isVIP
        ? Icons.diamond_rounded
        : tier.isPremium
            ? Icons.star_rounded
            : Icons.directions_car_rounded;
    final tierColor = tier.isComfort ? const Color(0xFFC7C7D1) : _gold;

    return GestureDetector(
      onTap: () {
        Navigator.of(
          context,
        ).push(slideFromRightRoute(TripReceiptScreen(trip: trip)));
      },
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: neuBox(radius: 20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header: tier icon + ride title + date · price ──
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: neuBox(radius: 14, pressed: true),
                  child: Icon(tierIcon, color: tierColor, size: 21),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        TierInfo.displayTitle(trip.rideName),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: c.textPrimary,
                          letterSpacing: 0.2,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 3),
                      Text(
                        date,
                        style: TextStyle(
                          fontSize: 12,
                          color: c.textTertiary,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                _PriceText(raw: trip.price),
              ],
            ),
            const SizedBox(height: 14),
            Container(
              height: 1,
              color: Colors.white.withValues(alpha: 0.05),
            ),
            const SizedBox(height: 14),

            // ── Route timeline: dot — connector — square rail ──
            IntrinsicHeight(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Column(
                    children: [
                      const SizedBox(height: 5),
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(5),
                          boxShadow: [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.45),
                              blurRadius: 6,
                            ),
                          ],
                        ),
                      ),
                      const Expanded(child: _RouteConnector()),
                      Container(
                        width: 10,
                        height: 10,
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
                      const SizedBox(height: 5),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          trip.pickup,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 16),
                        Text(
                          trip.dropoff,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: c.textPrimary,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // ── Footer: distance + duration chips · tap hint ──
            Row(
              children: [
                _metricChip(c, Icons.straighten_rounded, trip.miles),
                const SizedBox(width: 8),
                _metricChip(c, Icons.schedule_rounded, trip.duration),
                const Spacer(),
                Icon(
                  Icons.arrow_forward_ios_rounded,
                  size: 13,
                  color: c.textTertiary,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricChip(AppColors c, IconData icon, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: neuBox(radius: 10, pressed: true),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: _gold),
          const SizedBox(width: 5),
          Text(
            text,
            style: TextStyle(
              fontSize: 12,
              color: c.textSecondary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
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
    final c = AppColors.of(context);
    final match = _fareRe.firstMatch(raw.trim());
    if (match == null) {
      return Text(
        raw,
        style: TextStyle(
          fontSize: 18,
          fontWeight: FontWeight.w800,
          color: c.textPrimary,
        ),
      );
    }
    final whole = match.group(1) ?? '0';
    final cents = (match.group(2) ?? '00').padRight(2, '0').substring(0, 2);
    return Row(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 3),
          child: Text(
            '\$',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: c.textSecondary,
            ),
          ),
        ),
        const SizedBox(width: 1),
        Text(
          whole,
          style: TextStyle(
            fontSize: 22,
            fontWeight: FontWeight.w800,
            color: c.textPrimary,
            letterSpacing: -0.5,
            height: 1.0,
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Text(
            '.$cents',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w700,
              color: c.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// Animated route connector — dashed gold line with a glowing pulse
/// traveling pickup -> dropoff on a 2 s loop. Painted so it stretches
/// to exactly fill the gap between the endpoint shapes.
class _RouteConnector extends StatefulWidget {
  const _RouteConnector();

  @override
  State<_RouteConnector> createState() => _RouteConnectorState();
}

class _RouteConnectorState extends State<_RouteConnector>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
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
      width: 12,
      child: AnimatedBuilder(
        animation: _ctl,
        builder: (_, __) => CustomPaint(
          painter: _RouteConnectorPainter(t: _ctl.value),
        ),
      ),
    );
  }
}

class _RouteConnectorPainter extends CustomPainter {
  final double t;

  _RouteConnectorPainter({required this.t});

  @override
  void paint(Canvas canvas, Size size) {
    final x = size.width / 2;
    const inset = 1.0;

    final dashPaint = Paint()
      ..color = const Color(0x59E8C547)
      ..strokeWidth = 1.5
      ..strokeCap = StrokeCap.round;
    const dashH = 3.5;
    const gap = 3.5;
    double y = inset;
    while (y < size.height - inset) {
      final end = (y + dashH).clamp(y, size.height - inset);
      canvas.drawLine(Offset(x, y), Offset(x, end), dashPaint);
      y += dashH + gap;
    }

    final eased = Curves.easeInOut.transform(t);
    final cy = inset + (size.height - inset * 2) * eased;
    final edgeFade =
        (1.0 - ((t - 0.5).abs() * 2 - 0.7) / 0.3).clamp(0.0, 1.0);
    final glowPaint = Paint()
      ..color = const Color(0xFFE8C547).withValues(alpha: 0.9 * edgeFade)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4);
    canvas.drawCircle(Offset(x, cy), 3.2, glowPaint);
    canvas.drawCircle(
      Offset(x, cy),
      1.8,
      Paint()..color = Colors.white.withValues(alpha: edgeFade),
    );
  }

  @override
  bool shouldRepaint(_RouteConnectorPainter oldDelegate) =>
      oldDelegate.t != t;
}
