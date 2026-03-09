import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_theme.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

/// Premium Scheduled Trips screen for drivers.
/// Shows upcoming assigned rides with airport indicators and pickup zone info.
class DriverScheduledTripsScreen extends StatefulWidget {
  const DriverScheduledTripsScreen({super.key});

  @override
  State<DriverScheduledTripsScreen> createState() =>
      _DriverScheduledTripsScreenState();
}

class _DriverScheduledTripsScreenState extends State<DriverScheduledTripsScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);
  static const _airport = Color(0xFF4285F4);

  late final AnimationController _staggerCtrl;
  Timer? _countdownTimer;

  List<Map<String, dynamic>> _trips = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _staggerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    // Refresh countdown every minute so the "In Xh Ym" text stays live
    _countdownTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
    _loadTrips();
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _staggerCtrl.dispose();
    super.dispose();
  }

  Future<void> _loadTrips() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId == null) {
        setState(() {
          _error = 'Not logged in';
          _loading = false;
        });
        return;
      }
      final trips = await ApiService.getDriverScheduledTrips(userId);
      if (!mounted) return;
      setState(() {
        _trips = trips;
        _loading = false;
      });
      _staggerCtrl.forward(from: 0);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final s = S.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // ── Premium App Bar ──
          SliverAppBar(
            expandedHeight: 140,
            pinned: true,
            backgroundColor: c.bg,
            surfaceTintColor: Colors.transparent,
            leading: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.arrow_back_ios_new_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
            ),
            actions: [
              GestureDetector(
                onTap: _loadTrips,
                child: Container(
                  margin: const EdgeInsets.only(right: 16),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(
                    Icons.refresh_rounded,
                    color: Colors.white70,
                    size: 20,
                  ),
                ),
              ),
            ],
            flexibleSpace: FlexibleSpaceBar(
              titlePadding: const EdgeInsets.only(left: 20, bottom: 16),
              title: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [_gold, _goldLight],
                      ),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.event_note_rounded,
                      color: Colors.black87,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    s.upcomingTrips,
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ],
              ),
              background: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_gold.withValues(alpha: 0.06), c.bg],
                  ),
                ),
              ),
            ),
          ),

          // ── Content ──
          if (_loading)
            const SliverFillRemaining(
              child: Center(
                child: CircularProgressIndicator(
                  color: _gold,
                  strokeWidth: 2.5,
                ),
              ),
            )
          else if (_error != null)
            SliverFillRemaining(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.error_outline_rounded,
                      color: Colors.white24,
                      size: 48,
                    ),
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: c.textSecondary)),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: _loadTrips,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 24,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.4),
                          ),
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Text(
                          s.retry,
                          style: TextStyle(
                            color: _gold,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
          else if (_trips.isEmpty)
            SliverFillRemaining(child: _emptyState(c))
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              sliver: SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) => _buildCard(i, c),
                  childCount: _trips.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildCard(int i, AppColors c) {
    final s = S.of(context);
    final trip = _trips[i];
    final isAirport = trip['is_airport'] == true;
    final dateFmt = DateFormat('EEE, MMM d');
    final timeFmt = DateFormat('h:mm a');
    final pickup = trip['pickup_address'] as String? ?? '';
    final dropoff = trip['dropoff_address'] as String? ?? '';
    final fare = (trip['fare'] as num?)?.toDouble();
    final vehicleType = trip['vehicle_type'] as String? ?? 'Economy';
    final terminal = trip['terminal'] as String?;
    final airportCode = trip['airport_code'] as String?;
    final pickupZone = trip['pickup_zone'] as String?;
    final notes = trip['notes'] as String?;
    final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();

    DateTime? scheduledAt;
    if (trip['scheduled_at'] != null) {
      try {
        scheduledAt = DateTime.parse(trip['scheduled_at'] as String);
      } catch (_) {}
    }

    // Countdown
    String countdown = '';
    if (scheduledAt != null) {
      final diff = scheduledAt.difference(DateTime.now());
      if (diff.isNegative) {
        countdown = s.nowLabel;
      } else if (diff.inDays > 0) {
        countdown = 'In ${diff.inDays}d ${diff.inHours % 24}h';
      } else if (diff.inHours > 0) {
        countdown = 'In ${diff.inHours}h ${diff.inMinutes % 60}m';
      } else {
        countdown = 'In ${diff.inMinutes}m';
      }
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1D24),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isAirport
              ? _airport.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.06),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Header ──
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: BoxDecoration(
              color: isAirport
                  ? _airport.withValues(alpha: 0.06)
                  : _gold.withValues(alpha: 0.04),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: isAirport
                        ? _airport.withValues(alpha: 0.12)
                        : _gold.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    isAirport
                        ? Icons.flight_takeoff_rounded
                        : Icons.schedule_rounded,
                    color: isAirport ? _airport : _gold,
                    size: 20,
                  ),
                ),
                const SizedBox(width: 12),
                if (scheduledAt != null)
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${dateFmt.format(scheduledAt)} at ${timeFmt.format(scheduledAt)}',
                          style: TextStyle(
                            color: c.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          countdown,
                          style: TextStyle(
                            color: isAirport ? _airport : _gold,
                            fontSize: 12,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ],
                    ),
                  ),
                if (isAirport && airportCode != null)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: _airport.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(
                          Icons.flight_rounded,
                          size: 14,
                          color: _airport,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          airportCode,
                          style: const TextStyle(
                            color: _airport,
                            fontSize: 13,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // ── Route ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Column(
                  children: [
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: _gold,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: _gold.withValues(alpha: 0.3),
                          width: 3,
                        ),
                      ),
                    ),
                    Container(width: 1.5, height: 28, color: Colors.white12),
                    Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: isAirport ? _airport : Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: (isAirport ? _airport : Colors.white)
                              .withValues(alpha: 0.3),
                          width: 3,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pickup.isNotEmpty ? pickup : s.pickupLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 18),
                      Text(
                        dropoff.isNotEmpty ? dropoff : s.dropOffLabel,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),

          // ── Info chips ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Wrap(
              spacing: 8,
              runSpacing: 6,
              children: [
                _chip(Icons.directions_car_outlined, vehicleType, c),
                if (fare != null && fare > 0)
                  _chip(
                    Icons.attach_money_rounded,
                    '\$${fare.toStringAsFixed(2)}',
                    c,
                  ),
                if (terminal != null)
                  _chip(Icons.door_front_door_outlined, terminal, c),
                if (pickupZone != null)
                  _chip(Icons.pin_drop_outlined, pickupZone, c),
              ],
            ),
          ),

          // ── Notes / Flight # ──
          if (notes != null && notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: _airport.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: _airport.withValues(alpha: 0.12)),
                ),
                child: Row(
                  children: [
                    Icon(
                      isAirport
                          ? Icons.airplane_ticket_outlined
                          : Icons.note_outlined,
                      size: 16,
                      color: _airport,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        notes,
                        style: TextStyle(color: c.textPrimary, fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
            ),

          // ── Navigate button ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
            child: SizedBox(
              width: double.infinity,
              child: GestureDetector(
                onTap: () async {
                  if (pickupLat == null || pickupLng == null) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        backgroundColor: const Color(0xFFFF5252),
                        content: Text(
                          s.pickupCoordinatesNotAvailable,
                          style: TextStyle(color: Colors.white),
                        ),
                        behavior: SnackBarBehavior.floating,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                    );
                    return;
                  }
                  final uri = Uri.parse(
                    'https://www.google.com/maps/dir/?api=1'
                    '&destination=$pickupLat,$pickupLng'
                    '&travelmode=driving',
                  );
                  if (await canLaunchUrl(uri)) {
                    await launchUrl(uri, mode: LaunchMode.externalApplication);
                  }
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: BoxDecoration(
                    gradient: const LinearGradient(colors: [_gold, _goldLight]),
                    borderRadius: BorderRadius.circular(14),
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.25),
                        blurRadius: 8,
                        offset: const Offset(0, 3),
                      ),
                    ],
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.navigation_rounded,
                        color: Colors.black87,
                        size: 18,
                      ),
                      SizedBox(width: 8),
                      Text(
                        'Navigate to Pickup',
                        style: TextStyle(
                          color: Colors.black87,
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(IconData icon, String text, AppColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: c.textSecondary),
          const SizedBox(width: 4),
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

  Widget _emptyState(AppColors c) {
    final s = S.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(24),
            ),
            child: const Icon(
              Icons.event_available_rounded,
              color: _gold,
              size: 36,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            s.noUpcomingRides,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            s.scheduledRidesAssigned,
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textSecondary, fontSize: 14, height: 1.5),
          ),
        ],
      ),
    );
  }
}
