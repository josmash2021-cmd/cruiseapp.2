import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../config/app_theme.dart';
import '../services/api_service.dart';
import '../services/notification_service.dart';
import '../l10n/app_localizations.dart';

/// Premium Scheduled Rides screen for riders.
/// Shows upcoming and past scheduled/airport rides with cancel ability.
class ScheduledRidesScreen extends StatefulWidget {
  const ScheduledRidesScreen({super.key});

  @override
  State<ScheduledRidesScreen> createState() => _ScheduledRidesScreenState();
}

class _ScheduledRidesScreenState extends State<ScheduledRidesScreen>
    with SingleTickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  List<Map<String, dynamic>> _trips = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _loadTrips();
  }

  @override
  void dispose() {
    _fadeCtrl.dispose();
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
      final trips = await ApiService.getScheduledTrips(userId);
      if (!mounted) return;
      setState(() {
        _trips = trips;
        _loading = false;
      });
      _fadeCtrl.forward(from: 0);

      // Schedule 30-minute reminders for upcoming trips
      _scheduleReminders(trips);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Schedule local 30-minute reminders for all upcoming trips.
  Future<void> _scheduleReminders(List<Map<String, dynamic>> trips) async {
    for (final trip in trips) {
      final status = trip['status'] as String? ?? 'scheduled';
      if (status != 'scheduled') continue;

      final tripId = trip['id'] as int? ?? 0;
      if (tripId == 0) continue;

      DateTime? scheduledAt;
      if (trip['scheduled_at'] != null) {
        try {
          scheduledAt = DateTime.parse(trip['scheduled_at'] as String);
        } catch (_) {
          continue;
        }
      }
      if (scheduledAt == null || scheduledAt.isBefore(DateTime.now())) continue;

      final pickup = trip['pickup_address'] as String? ?? 'your pickup';
      final dropoff = trip['dropoff_address'] as String? ?? 'your destination';

      await NotificationService.scheduleRideReminder(
        tripId: tripId,
        rideTime: scheduledAt,
        pickup: pickup,
        dropoff: dropoff,
      );
    }
  }

  Future<void> _cancelTrip(int tripId) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          S.of(ctx).cancelRideQuestion,
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          S.of(ctx).cancelRideConfirm,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              S.of(ctx).keep,
              style: const TextStyle(color: Colors.white54),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              S.of(ctx).cancelRideBtn,
              style: const TextStyle(color: Color(0xFFFF5252)),
            ),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await ApiService.cancelTrip(tripId);
      // Also cancel the scheduled notification reminder
      await NotificationService.cancelRideReminder(tripId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _gold,
          content: Text(
            S.of(context).rideCancelled,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w600,
            ),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );
      _loadTrips();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFFF5252),
          content: Text(
            S.of(context).failedToCancel(e.toString()),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
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
                      Icons.schedule_rounded,
                      color: Colors.black87,
                      size: 16,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    S.of(context).scheduledRides,
                    style: const TextStyle(
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
                    colors: [_gold.withValues(alpha: 0.08), c.bg],
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
                    Icon(
                      Icons.error_outline_rounded,
                      color: Colors.white24,
                      size: 48,
                    ),
                    const SizedBox(height: 12),
                    Text(_error!, style: TextStyle(color: c.textSecondary)),
                    const SizedBox(height: 16),
                    _retryButton(),
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
                  (ctx, i) => FadeTransition(
                    opacity: _fadeAnim,
                    child: _TripCard(
                      trip: _trips[i],
                      index: i,
                      onCancel: () => _cancelTrip(_trips[i]['id'] as int),
                    ),
                  ),
                  childCount: _trips.length,
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _emptyState(AppColors c) {
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
              Icons.calendar_today_rounded,
              color: _gold,
              size: 36,
            ),
          ),
          const SizedBox(height: 20),
          Text(
            S.of(context).noScheduledRides,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            S.of(context).scheduleFromHome,
            textAlign: TextAlign.center,
            style: TextStyle(color: c.textSecondary, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 24),
          GestureDetector(
            onTap: () => Navigator.pop(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [_gold, _goldLight]),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Text(
                S.of(context).scheduleARide,
                style: const TextStyle(
                  color: Colors.black87,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _retryButton() {
    return GestureDetector(
      onTap: _loadTrips,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: _gold.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Text(
          'Retry',
          style: TextStyle(color: _gold, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

// ─── Trip Card Widget ───────────────────────────────────────────────────────

class _TripCard extends StatelessWidget {
  final Map<String, dynamic> trip;
  final int index;
  final VoidCallback onCancel;

  const _TripCard({
    required this.trip,
    required this.index,
    required this.onCancel,
  });

  static const _gold = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dateFmt = DateFormat('EEE, MMM d');
    final timeFmt = DateFormat('h:mm a');
    final isAirport = trip['is_airport'] == true;
    final status = trip['status'] as String? ?? 'scheduled';
    final pickup = trip['pickup_address'] as String? ?? '';
    final dropoff = trip['dropoff_address'] as String? ?? '';
    final fare = (trip['fare'] as num?)?.toDouble();
    final vehicleType = trip['vehicle_type'] as String? ?? 'Economy';
    final terminal = trip['terminal'] as String?;
    final airportCode = trip['airport_code'] as String?;
    final pickupZone = trip['pickup_zone'] as String?;
    final notes = trip['notes'] as String?;

    DateTime? scheduledAt;
    if (trip['scheduled_at'] != null) {
      try {
        scheduledAt = DateTime.parse(trip['scheduled_at'] as String);
      } catch (_) {}
    }

    final isPast = scheduledAt != null && scheduledAt.isBefore(DateTime.now());
    final canCancel = status == 'scheduled' && !isPast;

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1D24),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isAirport
              ? const Color(0xFF4285F4).withValues(alpha: 0.25)
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
          // Header with date and badges
          Container(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
            decoration: BoxDecoration(
              color: isAirport
                  ? const Color(0xFF4285F4).withValues(alpha: 0.06)
                  : _gold.withValues(alpha: 0.04),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            child: Row(
              children: [
                // Date/time
                if (scheduledAt != null) ...[
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: isAirport
                          ? const Color(0xFF4285F4).withValues(alpha: 0.12)
                          : _gold.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      isAirport
                          ? Icons.flight_takeoff_rounded
                          : Icons.schedule_rounded,
                      color: isAirport ? const Color(0xFF4285F4) : _gold,
                      size: 20,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dateFmt.format(scheduledAt),
                        style: TextStyle(
                          color: c.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        timeFmt.format(scheduledAt),
                        style: TextStyle(color: c.textSecondary, fontSize: 13),
                      ),
                    ],
                  ),
                ],
                const Spacer(),
                // Badges
                if (isAirport)
                  _badge(
                    icon: Icons.flight_rounded,
                    label: airportCode ?? 'Airport',
                    color: const Color(0xFF4285F4),
                  ),
                const SizedBox(width: 6),
                _statusBadge(status, isPast),
              ],
            ),
          ),

          // Route info
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Route dots
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
                        color: isAirport
                            ? const Color(0xFF4285F4)
                            : Colors.white,
                        shape: BoxShape.circle,
                        border: Border.all(
                          color:
                              (isAirport
                                      ? const Color(0xFF4285F4)
                                      : Colors.white)
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
                        pickup.isNotEmpty ? pickup : 'Pickup location',
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
                        dropoff.isNotEmpty ? dropoff : 'Dropoff location',
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

          // Details row: vehicle, fare, terminal
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Row(
              children: [
                _infoChip(Icons.directions_car_outlined, vehicleType, c),
                if (fare != null && fare > 0) ...[
                  const SizedBox(width: 8),
                  _infoChip(
                    Icons.attach_money_rounded,
                    '\$${fare.toStringAsFixed(2)}',
                    c,
                  ),
                ],
                if (terminal != null) ...[
                  const SizedBox(width: 8),
                  _infoChip(Icons.door_front_door_outlined, terminal, c),
                ],
                if (pickupZone != null) ...[
                  const SizedBox(width: 8),
                  _infoChip(Icons.pin_drop_outlined, pickupZone, c),
                ],
              ],
            ),
          ),

          // Notes
          if (notes != null && notes.isNotEmpty)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
              child: Row(
                children: [
                  Icon(Icons.note_outlined, size: 14, color: c.textSecondary),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      notes,
                      style: TextStyle(
                        color: c.textSecondary,
                        fontSize: 12,
                        fontStyle: FontStyle.italic,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),

          // Cancel button
          if (canCancel)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
              child: SizedBox(
                width: double.infinity,
                child: GestureDetector(
                  onTap: onCancel,
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF5252).withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFFFF5252).withValues(alpha: 0.2),
                      ),
                    ),
                    child: const Center(
                      child: Text(
                        'Cancel Ride',
                        style: TextStyle(
                          color: Color(0xFFFF5252),
                          fontWeight: FontWeight.w700,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            )
          else
            const SizedBox(height: 14),
        ],
      ),
    );
  }

  Widget _badge({
    required IconData icon,
    required String label,
    required Color color,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              color: color,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _statusBadge(String status, bool isPast) {
    Color color;
    String label;
    if (status == 'canceled') {
      color = const Color(0xFFFF5252);
      label = 'Canceled';
    } else if (isPast) {
      color = Colors.white38;
      label = 'Expired';
    } else {
      color = const Color(0xFF4CAF50);
      label = 'Upcoming';
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: color,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _infoChip(IconData icon, String text, AppColors c) {
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
}
