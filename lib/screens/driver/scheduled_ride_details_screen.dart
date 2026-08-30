import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:intl/intl.dart';

import '../../config/page_transitions.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../services/api_service.dart';
import '../../services/masked_call_service.dart';
import '../../widgets/neu_style.dart';
import 'driver_trip_accept_screen.dart';

/// Full-screen countdown + details for an upcoming scheduled ride.
/// Shown when driver is "locked" (<=30 min before pickup).
///
/// Visual system: the shared dark-neumorphism of `neu_style.dart`
/// (redesign 2026-08-30) — flat [neuBase] page, [neuBox] surfaces, the
/// gold→goldLight gradient CTA of the scheduled-rides cards. Before, this
/// page mounted a full-screen live map under a 0.75-alpha blur tint (an
/// invisible map that still claimed the one native surface) with ad-hoc
/// `_cardBg` panels and a thin gradient ring — none of it matched the
/// rest of the app.
class ScheduledRideDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> trip;
  final double minutesUntil;

  const ScheduledRideDetailsScreen({
    super.key,
    required this.trip,
    required this.minutesUntil,
  });

  @override
  State<ScheduledRideDetailsScreen> createState() =>
      _ScheduledRideDetailsScreenState();
}

class _ScheduledRideDetailsScreenState extends State<ScheduledRideDetailsScreen>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);
  static const _red = Color(0xFFFF5252);

  late int _secondsRemaining;
  Timer? _countdownTimer;
  bool _starting = false;
  bool _cancelling = false;
  bool _autoStarted = false;
  late final AnimationController _pulseCtrl;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _secondsRemaining = (widget.minutesUntil * 60).round().clamp(0, 999999);
    // If already <= 15 min, auto-redirect immediately
    if (_secondsRemaining <= 900) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _autoStartRide();
      });
    }
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _secondsRemaining = (_secondsRemaining - 1).clamp(0, 999999);
      });
      // Auto-redirect when countdown hits 15 minutes
      if (_secondsRemaining <= 900 && !_autoStarted && !_starting) {
        _autoStartRide();
      }
    });
    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    _pulseCtrl.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      _refreshTripStatus();
    }
  }

  /// Re-fetch trip status from backend when app resumes.
  Future<void> _refreshTripStatus() async {
    try {
      final data = await ApiService.getActiveScheduledTrip();
      if (!mounted) return;
      final hasTrip = data['has_scheduled_trip'] == true;
      if (!hasTrip) {
        // Trip was cancelled or completed while away
        Navigator.of(context).pop('refreshed');
        return;
      }
      final trip = data['trip'] as Map<String, dynamic>?;
      if (trip == null) return;
      final status = (trip['status'] ?? '').toString();
      // If trip already started (driver_en_route or beyond), navigate to trip screen
      final activeStatuses = {'driver_en_route', 'en_route_to_pickup', 'arrived',
          'driver_arrived', 'in_trip', 'in_progress'};
      if (activeStatuses.contains(status) && !_starting) {
        _navigateToTripScreen();
        return;
      }
      // Update countdown from fresh server data
      final minutesUntil = (data['minutes_until'] as num?)?.toDouble();
      if (minutesUntil != null) {
        setState(() {
          _secondsRemaining = (minutesUntil * 60).round().clamp(0, 999999);
        });
      }
    } catch (e) {
      debugPrint('[ScheduledRide] Refresh failed: $e');
    }
  }

  int get _tripId => widget.trip['id'] as int;

  /// Auto-start triggered by 15-min countdown or immediate if already <= 15 min.
  Future<void> _autoStartRide() async {
    if (_autoStarted) return;
    _autoStarted = true;
    await _startRideAndNavigate();
  }

  /// Start the ride via API, then navigate to the trip accept screen.
  /// Retries once on failure before showing an error.
  Future<void> _startRideAndNavigate() async {
    setState(() => _starting = true);
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await ApiService.startScheduledTrip(_tripId);
        if (!mounted) return;
        HapticService.mediumImpact();
        _navigateToTripScreen();
        return;
      } catch (e) {
        if (!mounted) return;
        if (attempt < 2) {
          debugPrint('[ScheduledRide] Start attempt $attempt failed: $e — retrying…');
          await Future.delayed(const Duration(seconds: 2));
          if (!mounted) return;
          continue;
        }
        _autoStarted = false; // allow retry
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).connectionError),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
    if (mounted) setState(() => _starting = false);
  }

  /// Navigate to DriverTripAcceptScreen with all trip data.
  void _navigateToTripScreen() {
    final trip = widget.trip;
    final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
    final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
    final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();

    if (pickupLat == null || pickupLng == null ||
        dropoffLat == null || dropoffLng == null) {
      Navigator.of(context).pop('started');
      return;
    }

    final pickup = LatLng(pickupLat, pickupLng);
    final dropoff = LatLng(dropoffLat, dropoffLng);
    // Use pickup as fallback for driver position
    final driverPos = pickup;
    final distKm = _haversineKm(driverPos, pickup);
    final etaMinutes = ((distKm * 1000) / 17.88 / 60).ceil().clamp(1, 99);
    final riderName = trip['rider_name']?.toString() ?? '';
    final riderId = int.tryParse((trip['rider_id'] ?? '').toString());

    // Replace this screen with the trip screen
    Navigator.of(context).pushReplacement(
      slideFromRightRoute(
        DriverTripAcceptScreen(
          tripId: _tripId,
          riderName: riderName,
          riderPhotoUrl: _normalizePhotoUrl(trip['rider_photo_url']?.toString() ?? ''),
          riderRating: (trip['rider_rating'] as num?)?.toDouble() ?? 0,
          riderIsNew: trip['rider_is_new'] == true,
          riderId: riderId,
          pickupLatLng: pickup,
          dropoffLatLng: dropoff,
          pickupAddress: trip['pickup_address']?.toString() ?? '',
          dropoffAddress: trip['dropoff_address']?.toString() ?? '',
          fare: (trip['fare'] as num?)?.toDouble() ?? 0,
          vehicleType: trip['vehicle_type']?.toString() ?? 'Comfort',
          driverPos: driverPos,
          distToPickupKm: distKm,
          etaMinutes: etaMinutes,
          riderPhone: trip['rider_phone']?.toString() ?? '',
          tripAlreadyStarted: true,
        ),
      ),
    );
  }

  Future<void> _startRide() async {
    await _startRideAndNavigate();
  }

  static String _normalizePhotoUrl(String rawUrl) {
    final raw = rawUrl.trim();
    if (raw.isEmpty) return '';
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '${ApiService.publicBaseUrl}$raw';
    return '${ApiService.publicBaseUrl}/$raw';
  }

  static double _haversineKm(LatLng a, LatLng b) {
    const r = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final sa = math.sin(dLat / 2);
    final sb = math.sin(dLng / 2);
    final aa = sa * sa +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            sb * sb;
    return r * 2 * math.atan2(math.sqrt(aa), math.sqrt(1 - aa));
  }

  Future<void> _cancelRide() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final ls = S.of(ctx);
        return AlertDialog(
          backgroundColor: neuSurface,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20)),
          title: Text(ls.cancelRideTitle, style: const TextStyle(color: Colors.white)),
          content: Text(
            ls.cancelRideBody,
            style: const TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(ls.no, style: const TextStyle(color: Colors.white54)),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(ls.cancel, style: const TextStyle(color: _red)),
            ),
          ],
        );
      },
    );
    if (confirm != true) return;

    setState(() => _cancelling = true);
    try {
      await ApiService.cancelScheduledTrip(_tripId);
      if (!mounted) return;
      Navigator.of(context).pop('cancelled');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        // Clean message (2026-08-28): never the raw "ApiException(400): …".
        SnackBar(
            content: Text(
                '${S.of(context).error}: ${e is ApiException ? e.message : S.of(context).connectionError}'),
            backgroundColor: Colors.red),
      );
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  static String _formatMinutesAsTime(int totalMinutes) {
    if (totalMinutes <= 0) return '0 min';
    if (totalMinutes < 60) return '$totalMinutes min';
    final h = totalMinutes ~/ 60;
    final m = totalMinutes % 60;
    if (m == 0) return '${h}h';
    return '${h}h ${m}m';
  }

  String get _countdownText {
    final h = _secondsRemaining ~/ 3600;
    final m = (_secondsRemaining % 3600) ~/ 60;
    final s = _secondsRemaining % 60;
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m ${s.toString().padLeft(2, '0')}s';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final loc = S.of(context);
    final trip = widget.trip;
    final pickup = trip['pickup_address'] ?? '';
    final dropoff = trip['dropoff_address'] ?? '';
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
    final riderName = trip['rider_name'] ?? '';
    final riderPhoto = trip['rider_photo_url']?.toString() ?? '';
    final vehicleType = trip['vehicle_type'] ?? 'standard';
    final scheduledAt = trip['scheduled_at'] != null
        ? DateTime.tryParse(trip['scheduled_at'])
        : null;
    final dateStr = scheduledAt != null
        ? DateFormat('EEEE d MMMM, h:mm a').format(scheduledAt.toLocal())
        : '';

    final canStart = _secondsRemaining <= 900; // Can start 15 min early

    return Scaffold(
      backgroundColor: neuBase,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar: SCHEDULED RIDE badge + X close button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
                    decoration: neuBox(radius: 20, pressed: true),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.event, color: _gold, size: 16),
                        const SizedBox(width: 6),
                        Text(
                          S.of(context).scheduledRideLabel,
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const Spacer(),
                  // X close button
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: Container(
                      width: 38,
                      height: 38,
                      decoration: neuBox(radius: 13),
                      child: const Icon(Icons.close_rounded,
                          color: Colors.white70, size: 20),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 20),

            // Countdown circle — a raised neu coin with a faint gold edge
            // (the old thin gradient ring is gone).
            AnimatedBuilder(
              animation: _pulseCtrl,
              builder: (context, child) {
                final scale = 1.0 + _pulseCtrl.value * 0.03;
                return Transform.scale(scale: scale, child: child);
              },
              child: Container(
                width: 200,
                height: 200,
                decoration: neuBox(
                  radius: 100,
                  borderColor: _gold.withValues(alpha: 0.2),
                ),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      _secondsRemaining <= 0 ? loc.nowLabel.toUpperCase() : _countdownText,
                      style: TextStyle(
                        color: _secondsRemaining <= 0 ? Colors.green : _gold,
                        fontSize: _secondsRemaining <= 0 ? 32 : 36,
                        fontWeight: FontWeight.w900,
                        fontFeatures: const [FontFeature.tabularFigures()],
                      ),
                    ),
                    if (_secondsRemaining > 0)
                      Text(
                        loc.forPickup,
                        style: const TextStyle(color: Colors.white54, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 8),
            Text(
              dateStr,
              style: const TextStyle(color: Colors.white70, fontSize: 14),
            ),

            const SizedBox(height: 24),

            // Trip details card
            Expanded(
              child: Container(
                margin: const EdgeInsets.symmetric(horizontal: 16),
                padding: const EdgeInsets.all(20),
                decoration: neuBox(radius: 20),
                child: Column(
                  children: [
                    Expanded(
                      child: SingleChildScrollView(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                      // Pickup
                      _addressRow(
                        icon: Icons.circle,
                        color: Colors.green,
                        label: S.of(context).pickupUpperLabel,
                        address: pickup,
                      ),
                      Padding(
                        padding: const EdgeInsets.only(left: 7),
                        child: Container(width: 2, height: 20, color: Colors.white12),
                      ),
                      // Dropoff
                      _addressRow(
                        icon: Icons.circle,
                        color: _red,
                        label: S.of(context).dropoffUpperLabel,
                        address: dropoff,
                      ),

                      // ── Fare below addresses ──
                      const SizedBox(height: 20),
                      Center(
                        child: Column(
                          children: [
                            Text(
                              '\$${fare.toStringAsFixed(2)}',
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 32,
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0.5,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              '+ Tips',
                              style: TextStyle(
                                color: _gold.withValues(alpha: 0.5),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),

                      // ── Rider info row ──
                      if (riderName.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                          decoration: neuBox(radius: 14, pressed: true),
                          child: Row(
                            children: [
                              CircleAvatar(
                                backgroundColor: _gold.withValues(alpha: 0.2),
                                radius: 18,
                                backgroundImage: riderPhoto.isNotEmpty
                                    ? CachedNetworkImageProvider(riderPhoto)
                                    : null,
                                child: riderPhoto.isEmpty
                                    ? Text(
                                        riderName.isNotEmpty ? riderName[0].toUpperCase() : '?',
                                        style: const TextStyle(color: _gold, fontWeight: FontWeight.bold, fontSize: 14),
                                      )
                                    : null,
                              ),
                              const SizedBox(width: 10),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      riderName,
                                      style: const TextStyle(
                                        color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                    Text(
                                      vehicleType.toUpperCase(),
                                      style: const TextStyle(color: _gold, fontSize: 10, fontWeight: FontWeight.w700),
                                    ),
                                  ],
                                ),
                              ),
                              IconButton(
                                  icon: const Icon(Icons.phone, color: Colors.green, size: 20),
                                  onPressed: () async {
                                    // Masked callback — the server rings the
                                    // driver's phone, then bridges to the rider.
                                    final ok = await MaskedCallService.callCounterparty(
                                      tripId: _tripId,
                                      role: 'driver',
                                    );
                                    if (!context.mounted) return;
                                    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                                      SnackBar(
                                        content: Text(ok
                                            ? S.of(context).callingYouBack
                                            : S.of(context).connectionError),
                                        behavior: SnackBarBehavior.floating,
                                      ),
                                    );
                                  },
                                  constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
                                  padding: EdgeInsets.zero,
                                ),
                            ],
                          ),
                        ),
                      ],

                    ],
                  ),
                ),
              ),
                // No more offers banner pinned at bottom of card
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                    decoration: neuBox(
                      radius: 12,
                      pressed: true,
                      borderColor: Colors.orange.withValues(alpha: 0.25),
                    ),
                    child: Row(
                      children: [
                        Icon(Icons.info_outline, color: Colors.orange.withValues(alpha: 0.7), size: 16),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            loc.noNewRidesUntilComplete,
                            style: TextStyle(color: Colors.orange.withValues(alpha: 0.8), fontSize: 11),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                  ],
                ),
              ),
            ),

            const SizedBox(height: 16),

            // Bottom buttons
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child: Row(
                children: [
                  // Cancel button — only show when > 1 hour remains
                  if (_secondsRemaining > 3600) ...[
                  Expanded(
                    flex: 1,
                    child: GestureDetector(
                      onTap: _cancelling ? null : _cancelRide,
                      child: Container(
                        height: 52,
                        decoration: neuBox(
                          radius: 14,
                          pressed: true,
                          borderColor: _red.withValues(alpha: 0.35),
                        ),
                        child: Center(
                          child: _cancelling
                              ? const SizedBox(
                                  width: 18, height: 18,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: _red),
                                )
                              : Text(
                                  loc.cancel.toUpperCase(),
                                  style: const TextStyle(
                                    color: _red, fontWeight: FontWeight.w700, fontSize: 13,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ],
                  // Start ride button — the gold→goldLight gradient CTA of
                  // the scheduled-rides cards; a sunken well while disabled.
                  Expanded(
                    flex: _secondsRemaining > 3600 ? 2 : 1,
                    child: GestureDetector(
                      onTap: canStart && !_starting ? _startRide : null,
                      child: Container(
                        height: 52,
                        decoration: canStart
                            ? BoxDecoration(
                                gradient: const LinearGradient(
                                    colors: [_gold, _goldLight]),
                                borderRadius: BorderRadius.circular(14),
                                boxShadow: [
                                  BoxShadow(
                                    color: _gold.withValues(alpha: 0.25),
                                    blurRadius: 8,
                                    offset: const Offset(0, 3),
                                  ),
                                ],
                              )
                            : neuBox(radius: 14, pressed: true),
                        child: Center(
                          child: _starting
                              ? const SizedBox(
                                  width: 20, height: 20,
                                  child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black87),
                                )
                              : Text(
                                  canStart
                                      ? loc.startRideButton
                                      : '${loc.availableInLabel} ${_formatMinutesAsTime((_secondsRemaining ~/ 60) - 15)}',
                                  style: TextStyle(
                                    color: canStart ? Colors.black87 : Colors.white38,
                                    fontWeight: FontWeight.w800,
                                    fontSize: canStart ? 16 : 12,
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _addressRow({
    required IconData icon,
    required Color color,
    required String label,
    required String address,
  }) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(icon, color: color, size: 14),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: TextStyle(
                  color: color.withValues(alpha:0.7),
                  fontSize: 10,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                address,
                style: const TextStyle(color: Colors.white, fontSize: 14),
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
