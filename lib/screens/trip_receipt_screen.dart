import 'package:flutter/material.dart';

import '../config/app_theme.dart';
import '../l10n/app_localizations.dart';
import '../services/api_service.dart';
import '../services/local_data_service.dart';
import '../widgets/tier_badge.dart';

class TripReceiptScreen extends StatefulWidget {
  final TripHistoryItem trip;

  const TripReceiptScreen({super.key, required this.trip});

  @override
  State<TripReceiptScreen> createState() => _TripReceiptScreenState();
}

class _TripReceiptScreenState extends State<TripReceiptScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  late AnimationController _entryController;
  late Animation<double> _fadeAnim;
  Map<String, dynamic>? _fareBreakdown;

  @override
  void initState() {
    super.initState();
    _entryController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(
      parent: _entryController,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );
    _entryController.forward();
    _loadFareBreakdown();
  }

  @override
  void dispose() {
    _entryController.dispose();
    super.dispose();
  }

  TripHistoryItem get trip => widget.trip;

  Future<void> _loadFareBreakdown() async {
    final tid = trip.tripId;
    if (tid == null) return;
    try {
      final data = await ApiService.getFareBreakdown(tid);
      if (mounted) setState(() => _fareBreakdown = data);
    } catch (e) {
      // Fare breakdown is optional — silently ignore errors in production,
      // but log in debug for troubleshooting
      debugPrint('[TripReceipt] Failed to load fare breakdown: $e');
    }
  }

  /// Distance: prefer backend fare breakdown over local trip data
  String get _effectiveMiles {
    final fbMiles = (_fareBreakdown?['distance_miles'] as num?)?.toDouble();
    if (fbMiles != null && fbMiles > 0) {
      return '${fbMiles.toStringAsFixed(1)} mi';
    }
    final local = trip.miles;
    if (local.isNotEmpty && local != '-- mi' && local != '0.0 mi' && local != '0.00 mi') {
      return local;
    }
    return '0.0 mi';
  }

  /// Duration: prefer backend fare breakdown over local trip data
  String get _effectiveDuration {
    final fbMin = (_fareBreakdown?['duration_minutes'] as num?)?.toInt();
    if (fbMin != null && fbMin > 0) {
      return '$fbMin min';
    }
    final local = trip.duration;
    if (local.isNotEmpty && local != '-- min' && local != '0 min') {
      return local;
    }
    return '0 min';
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Column(
              children: [
                Expanded(
                  child: ListView(
                    physics: const BouncingScrollPhysics(),
                    padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
                    children: [
                      // ── TOP BAR (back only — share + email removed) ──
                      Row(
                        children: [
                          GestureDetector(
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
                        ],
                      ),
                      const SizedBox(height: 28),

                      // ── TITLE ──
                      Text(
                        S.of(context).tripReceipt,
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: c.textPrimary,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _fareBreakdown?['receipt_number'] ?? '#CR-${trip.tripId ?? 0}',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                          color: c.textTertiary,
                          letterSpacing: 0.3,
                        ),
                      ),
                      const SizedBox(height: 28),

                      // ── TOTAL AMOUNT CARD (matches the rest of the
                      // black/gold theme — was a tier-colored gradient
                      // that fought the dark UI). ──
                      Container(
                        padding: const EdgeInsets.symmetric(
                            vertical: 32, horizontal: 24),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1A1A1F),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.30),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: _gold.withValues(alpha: 0.10),
                              blurRadius: 22,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            // Status badge
                            Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 5),
                              decoration: BoxDecoration(
                                color:
                                    _gold.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(20),
                                border: Border.all(
                                  color: _gold.withValues(alpha: 0.35),
                                  width: 1,
                                ),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.check_circle_rounded,
                                    color: _gold,
                                    size: 13,
                                  ),
                                  const SizedBox(width: 5),
                                  Text(
                                    S.of(context).completedOnDate(
                                        _formatDate(trip.createdAt)),
                                    style: const TextStyle(
                                      color: _gold,
                                      fontSize: 11,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            // Total amount in gold
                            Text(
                              trip.price,
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 44,
                                fontWeight: FontWeight.w900,
                                letterSpacing: -1,
                              ),
                            ),
                            const SizedBox(height: 12),
                            // Tier badge (now 1:1 with Choose a Vehicle)
                            TierBadge(rideName: trip.rideName),
                          ],
                        ),
                      ),
                      const SizedBox(height: 16),

                      // ── TRIP DETAILS CARD ──
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: c.panel,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: c.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              S.of(context).tripDetailsHeader,
                              style: TextStyle(
                                color: c.textTertiary,
                                fontSize: 12,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 16),
                            _detailRow(c, Icons.straighten_rounded, S.of(context).distance, _effectiveMiles),
                            Padding(
                              padding: const EdgeInsets.symmetric(vertical: 12),
                              child: Divider(color: c.divider, height: 1),
                            ),
                            _detailRow(c, Icons.schedule_rounded, S.of(context).duration, _effectiveDuration),
                            if (_fareBreakdown?['payment_method'] != null) ...[
                              Padding(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                                child: Divider(color: c.divider, height: 1),
                              ),
                              _detailRow(c, Icons.credit_card_rounded, S.of(context).paymentLabel, _fareBreakdown!['payment_method'] as String),
                            ],
                          ],
                        ),
                      ),

                      const SizedBox(height: 12),

                      // ── FARE BREAKDOWN ──
                      if (_fareBreakdown != null)
                        Container(
                          padding: const EdgeInsets.all(20),
                          decoration: BoxDecoration(
                            color: c.panel,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(color: c.border),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                S.of(context).fareBreakdownHeader,
                                style: TextStyle(
                                  color: c.textTertiary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1.2,
                                ),
                              ),
                              const SizedBox(height: 16),
                              _breakdownRow(c, S.of(context).baseFareLabel, '\$${(_fareBreakdown!['base_fare'] as num?)?.toStringAsFixed(2) ?? '0.00'}'),
                              _breakdownRow(c, S.of(context).mileageLabel('${(_fareBreakdown!['distance_miles'] as num?)?.toStringAsFixed(1) ?? '0'} mi'), '\$${(_fareBreakdown!['mileage_charge'] as num?)?.toStringAsFixed(2) ?? '0.00'}'),
                              _breakdownRow(c, S.of(context).timeFareLabel('${(_fareBreakdown!['duration_minutes'] as num?)?.toInt() ?? 0} min'), '\$${(_fareBreakdown!['time_charge'] as num?)?.toStringAsFixed(2) ?? '0.00'}'),
                              if ((_fareBreakdown!['surge_multiplier'] as num?) != null && (_fareBreakdown!['surge_multiplier'] as num) > 1.0)
                                _breakdownRow(c, S.of(context).surgeLabel('${(_fareBreakdown!['surge_multiplier'] as num).toStringAsFixed(1)}x'), '+\$${(_fareBreakdown!['surge_extra'] as num?)?.toStringAsFixed(2) ?? '0.00'}', highlight: true),
                              if ((_fareBreakdown!['wait_time_charge'] as num?) != null && (_fareBreakdown!['wait_time_charge'] as num) > 0)
                                _breakdownRow(c, S.of(context).waitTimeLabel('${(_fareBreakdown!['wait_time_minutes'] as num?)?.toInt() ?? 0} min'), '\$${(_fareBreakdown!['wait_time_charge'] as num).toStringAsFixed(2)}'),
                              if ((_fareBreakdown!['tip_amount'] as num?) != null && (_fareBreakdown!['tip_amount'] as num) > 0)
                                _breakdownRow(c, S.of(context).tipLabel, '\$${(_fareBreakdown!['tip_amount'] as num).toStringAsFixed(2)}'),
                              Padding(
                                padding: const EdgeInsets.only(top: 12, bottom: 4),
                                child: Divider(color: c.divider, height: 1),
                              ),
                              const SizedBox(height: 4),
                              Row(
                                children: [
                                  Text(S.of(context).totalLabel, style: TextStyle(color: c.textPrimary, fontSize: 15, fontWeight: FontWeight.w700)),
                                  const Spacer(),
                                  Text(trip.price, style: const TextStyle(color: _gold, fontSize: 18, fontWeight: FontWeight.w800)),
                                ],
                              ),
                            ],
                          ),
                        ),

                      if (_fareBreakdown != null) const SizedBox(height: 12),

                      // ── ROUTE CARD ──
                      Container(
                        padding: const EdgeInsets.all(20),
                        decoration: BoxDecoration(
                          color: c.panel,
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(color: c.border),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              S.of(context).routeHeader,
                              style: TextStyle(
                                color: c.textTertiary,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 1.2,
                              ),
                            ),
                            const SizedBox(height: 16),
                            _routePoint(
                              c,
                              isPickup: true,
                              label: S.of(context).pickupTagLabel,
                              address: trip.pickup,
                            ),
                            Padding(
                              padding: const EdgeInsets.only(left: 4),
                              child: const _ShimmerConnector(),
                            ),
                            _routePoint(
                              c,
                              isPickup: false,
                              label: S.of(context).dropoffTagLabel,
                              address: trip.dropoff,
                            ),
                          ],
                        ),
                      ),

                      const SizedBox(height: 20),
                      Center(
                        child: Text(
                          S.of(context).thankYouForRiding,
                          style: TextStyle(
                            color: c.textTertiary,
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // ── DONE BUTTON ──
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
                  child: SizedBox(
                    width: double.infinity,
                    height: 54,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: const Color(0xFF08090C),
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                      ),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(
                        S.of(context).done,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 17,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
    );
  }

  Widget _detailRow(AppColors c, IconData icon, String label, String value) {
    return Row(
      children: [
        Icon(icon, color: c.textTertiary, size: 16),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            style: TextStyle(color: c.textSecondary, fontSize: 14),
          ),
        ),
        Text(
          value,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }

  Widget _routePoint(
    AppColors c, {
    required bool isPickup,
    required String label,
    required String address,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Pickup = gold dot. Dropoff = white square (matches Your Trips
        // card so endpoints are visually distinct at a glance).
        isPickup
            ? Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(
                  color: _gold,
                  borderRadius: BorderRadius.circular(5),
                ),
              )
            : Container(
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
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: c.textTertiary,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                address,
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _formatDate(DateTime value) {
    const months = [
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
    final hour = value.hour % 12 == 0 ? 12 : value.hour % 12;
    final minute = value.minute.toString().padLeft(2, '0');
    final amPm = value.hour >= 12 ? 'PM' : 'AM';
    return '${months[value.month - 1]} ${value.day}, ${value.year} · $hour:$minute $amPm';
  }

  Widget _breakdownRow(AppColors c, String label, String value, {bool highlight = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: highlight ? Colors.redAccent : c.textSecondary,
                fontSize: 13,
                fontWeight: highlight ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: highlight ? Colors.redAccent : c.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

/// Vertical shimmer connector between pickup and dropoff dots — same
/// component used in [RideHistoryScreen]. 1.5 px wide, 18 px tall, gold
/// gradient with a brighter highlight that travels top -> bottom on a
/// 1.6 s loop.
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
          final start = (t - 0.15).clamp(0.0, 1.0);
          final mid = t.clamp(0.0, 1.0);
          final end = (t + 0.15).clamp(0.0, 1.0);
          return Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: const [
                  Color(0x55E8C547),
                  Color(0xFFFFFFFF),
                  Color(0x55E8C547),
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

