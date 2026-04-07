import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/app_theme.dart';
import '../../config/mapbox_config.dart';
import '../../l10n/app_localizations.dart';
import '../../services/api_service.dart';

/// Unified scheduled rides screen with two tabs:
///   0 = Available  (marketplace — claim a ride)
///   1 = My Rides   (driver's claimed upcoming rides)
class ScheduledRidesScreen extends StatefulWidget {
  /// 0 = Available tab, 1 = My Rides tab
  final int initialTab;

  const ScheduledRidesScreen({super.key, this.initialTab = 0});

  @override
  State<ScheduledRidesScreen> createState() => _ScheduledRidesScreenState();
}

class _ScheduledRidesScreenState extends State<ScheduledRidesScreen>
    with SingleTickerProviderStateMixin {
  static const _gold     = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);
  static const _darkBg   = Color(0xFF0F1117);
  static const _cardBg   = Color(0xFF1A1D24);
  static const _airport  = Color(0xFF4285F4);

  late final TabController _tabCtrl;
  Timer? _countdownTimer;

  // ── Available tab state ──
  List<Map<String, dynamic>> _available = [];
  bool _loadingAvail  = true;
  String? _errorAvail;
  int? _claimingId;

  // ── My Rides tab state ──
  List<Map<String, dynamic>> _myRides = [];
  bool _loadingMine  = true;
  String? _errorMine;

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab,
    );
    _loadAvailable();
    _loadMyRides();
    // Refresh countdown text every minute
    _countdownTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tabCtrl.dispose();
    _countdownTimer?.cancel();
    super.dispose();
  }

  // ─────────────────────────────────────────────
  //  Data loaders
  // ─────────────────────────────────────────────

  Future<void> _loadAvailable() async {
    setState(() { _loadingAvail = true; _errorAvail = null; });
    try {
      double lat = 0, lng = 0;
      try {
        final pos = await Geolocator.getLastKnownPosition();
        if (pos != null) { lat = pos.latitude; lng = pos.longitude; }
      } catch (_) {}
      final trips = await ApiService.getAvailableScheduledTrips(
        lat: lat, lng: lng, radiusKm: 50,
      );
      if (!mounted) return;
      setState(() { _available = trips; _loadingAvail = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _errorAvail = e.toString(); _loadingAvail = false; });
    }
  }

  Future<void> _loadMyRides() async {
    setState(() { _loadingMine = true; _errorMine = null; });
    try {
      final uid = await ApiService.getCurrentUserId();
      if (uid == null) {
        setState(() { _errorMine = 'Not logged in'; _loadingMine = false; });
        return;
      }
      final trips = await ApiService.getDriverScheduledTrips(uid);
      if (!mounted) return;
      setState(() { _myRides = trips; _loadingMine = false; });
    } catch (e) {
      if (!mounted) return;
      setState(() { _errorMine = e.toString(); _loadingMine = false; });
    }
  }

  Future<void> _claimTrip(int tripId) async {
    setState(() => _claimingId = tripId);
    try {
      final result = await ApiService.claimScheduledTrip(tripId);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result['message'] ?? S.of(context).scheduledRideConfirmed,
          style: const TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
        ),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
      _loadAvailable();
      _loadMyRides();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Error: $e'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
    } finally {
      if (mounted) setState(() => _claimingId = null);
    }
  }

  // ─────────────────────────────────────────────
  //  Mapbox Static mini-map URL
  // ─────────────────────────────────────────────

  String? _miniMapUrl({
    double? pickupLat, double? pickupLng,
    double? dropoffLat, double? dropoffLng,
  }) {
    if (pickupLat == null || pickupLng == null) return null;
    final token = MapboxConfig.accessToken;
    final pLng = pickupLng.toStringAsFixed(6);
    final pLat = pickupLat.toStringAsFixed(6);

    String overlay;
    String viewport;

    if (dropoffLat != null && dropoffLng != null) {
      final dLng = dropoffLng.toStringAsFixed(6);
      final dLat = dropoffLat.toStringAsFixed(6);
      overlay = 'pin-s+22c55e($pLng,$pLat),pin-s+ef4444($dLng,$dLat)';
      viewport = 'auto';
    } else {
      overlay = 'pin-s+22c55e($pLng,$pLat)';
      viewport = '$pLng,$pLat,14';
    }

    return 'https://api.mapbox.com/styles/v1/mapbox/dark-v11/static/'
        '$overlay/$viewport/360x140@2x'
        '?padding=35,25,35,25&access_token=$token';
  }

  // ─────────────────────────────────────────────
  //  Countdown helper
  // ─────────────────────────────────────────────

  String _countdown(DateTime? scheduledAt) {
    if (scheduledAt == null) return '';
    final diff = scheduledAt.difference(DateTime.now());
    if (diff.isNegative) return S.of(context).nowLabel;
    if (diff.inDays > 0) return 'In ${diff.inDays}d ${diff.inHours % 24}h';
    if (diff.inHours > 0) return 'In ${diff.inHours}h ${diff.inMinutes % 60}m';
    return 'In ${diff.inMinutes}m';
  }

  // ─────────────────────────────────────────────
  //  Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    return Scaffold(
      backgroundColor: _darkBg,
      body: NestedScrollView(
        headerSliverBuilder: (ctx, _) => [
          SliverAppBar(
            pinned: true,
            backgroundColor: _darkBg,
            surfaceTintColor: Colors.transparent,
            elevation: 0,
            leading: GestureDetector(
              onTap: () => Navigator.pop(context),
              child: Container(
                margin: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.arrow_back_ios_new_rounded,
                    color: Colors.white, size: 18),
              ),
            ),
            centerTitle: true,
            title: const Text(
              'Scheduled Rides',
              style: TextStyle(
                color: Colors.white,
                fontSize: 19,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            actions: [
              GestureDetector(
                onTap: () {
                  _loadAvailable();
                  _loadMyRides();
                },
                child: Container(
                  margin: const EdgeInsets.only(right: 14),
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Icon(Icons.refresh_rounded,
                      color: Colors.white70, size: 20),
                ),
              ),
            ],
            bottom: PreferredSize(
              preferredSize: const Size.fromHeight(48),
              child: Container(
                margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                height: 40,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: TabBar(
                  controller: _tabCtrl,
                  indicator: BoxDecoration(
                    color: _gold,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  indicatorSize: TabBarIndicatorSize.tab,
                  dividerColor: Colors.transparent,
                  labelColor: Colors.black,
                  unselectedLabelColor: Colors.white54,
                  labelStyle: const TextStyle(
                      fontWeight: FontWeight.w700, fontSize: 13),
                  unselectedLabelStyle: const TextStyle(
                      fontWeight: FontWeight.w500, fontSize: 13),
                  padding: const EdgeInsets.all(4),
                  tabs: [
                    Tab(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.storefront_rounded, size: 14),
                          const SizedBox(width: 5),
                          Text(s.availableLabel),
                        ],
                      ),
                    ),
                    Tab(
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Icon(Icons.event_available_rounded, size: 14),
                          const SizedBox(width: 5),
                          Text(s.myRidesLabel),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
        body: TabBarView(
          controller: _tabCtrl,
          children: [
            _buildTabContent(
              loading: _loadingAvail,
              error: _errorAvail,
              trips: _available,
              onRefresh: _loadAvailable,
              isMyRides: false,
            ),
            _buildTabContent(
              loading: _loadingMine,
              error: _errorMine,
              trips: _myRides,
              onRefresh: _loadMyRides,
              isMyRides: true,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTabContent({
    required bool loading,
    required String? error,
    required List<Map<String, dynamic>> trips,
    required Future<void> Function() onRefresh,
    required bool isMyRides,
  }) {
    if (loading) {
      return const Center(
        child: CircularProgressIndicator(color: _gold, strokeWidth: 2.5),
      );
    }
    if (error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline_rounded, color: Colors.white24, size: 48),
            const SizedBox(height: 12),
            Text(error, style: const TextStyle(color: Colors.white54, fontSize: 13)),
            const SizedBox(height: 16),
            _retryBtn(onRefresh),
          ],
        ),
      );
    }
    if (trips.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 76,
              height: 76,
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(24),
              ),
              child: Icon(
                isMyRides ? Icons.event_available_rounded : Icons.event_busy_rounded,
                color: _gold, size: 34,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              isMyRides ? S.of(context).noUpcomingRides : S.of(context).noScheduledTrips,
              style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              isMyRides ? S.of(context).scheduledRidesAssigned : S.of(context).scheduledTripsHint,
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white38, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: _gold,
      backgroundColor: _cardBg,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
        itemCount: trips.length,
        itemBuilder: (ctx, i) => isMyRides
            ? _buildMyRideCard(trips[i])
            : _buildAvailableCard(trips[i]),
      ),
    );
  }

  Widget _retryBtn(Future<void> Function() onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
        decoration: BoxDecoration(
          border: Border.all(color: _gold.withValues(alpha: 0.4)),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(S.of(context).retry,
            style: const TextStyle(color: _gold, fontWeight: FontWeight.w600)),
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Available card (claim)
  // ─────────────────────────────────────────────

  Widget _buildAvailableCard(Map<String, dynamic> trip) {
    final tripId     = trip['id'] as int;
    final fare       = (trip['fare'] as num?)?.toDouble() ?? 0;
    final pickup     = trip['pickup_address'] as String? ?? '';
    final dropoff    = trip['dropoff_address'] as String? ?? '';
    final vehicleType = trip['vehicle_type'] as String? ?? 'standard';
    final distKm     = (trip['distance_km'] as num?)?.toDouble() ?? 0;
    final pickupLat  = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng  = (trip['pickup_lng'] as num?)?.toDouble();
    final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
    final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();

    DateTime? scheduledAt;
    if (trip['scheduled_at'] != null) {
      try { scheduledAt = DateTime.parse(trip['scheduled_at']); } catch (_) {}
    }

    final dateStr = scheduledAt != null
        ? DateFormat('EEE d MMM, h:mm a').format(scheduledAt.toLocal())
        : '';
    final countdownStr = _countdown(scheduledAt);
    final isClaiming = _claimingId == tripId;
    final mapUrl = _miniMapUrl(
      pickupLat: pickupLat, pickupLng: pickupLng,
      dropoffLat: dropoffLat, dropoffLng: dropoffLng,
    );

    return _cardShell(
      isAirport: false,
      mapUrl: mapUrl,
      children: [
        // Header
        _cardHeader(
          dateStr: dateStr,
          countdown: countdownStr,
          fare: fare,
          isAirport: false,
        ),
        // Route
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: _routeRow(pickup, dropoff, isAirport: false),
        ),
        // Chips
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 6, children: [
            _chip(Icons.timer_rounded, countdownStr, _gold),
            if (distKm > 0)
              _chip(Icons.near_me_rounded, '${distKm.toStringAsFixed(1)} km', Colors.blue),
            _chip(Icons.directions_car_rounded, vehicleType.toUpperCase(), Colors.white54),
          ]),
        ),
        // Action
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: SizedBox(
            width: double.infinity,
            height: 48,
            child: ElevatedButton(
              onPressed: isClaiming ? null : () => _claimTrip(tripId),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                disabledBackgroundColor: _gold.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(13),
                ),
                elevation: 0,
              ),
              child: isClaiming
                  ? const SizedBox(
                      width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2.5, color: Colors.black87),
                    )
                  : Text(
                      S.of(context).acceptRideButton,
                      style: const TextStyle(fontWeight: FontWeight.w800, fontSize: 15),
                    ),
            ),
          ),
        ),
      ],
    );
  }

  // ─────────────────────────────────────────────
  //  My Rides card (navigate)
  // ─────────────────────────────────────────────

  Widget _buildMyRideCard(Map<String, dynamic> trip) {
    final pickup     = trip['pickup_address'] as String? ?? '';
    final dropoff    = trip['dropoff_address'] as String? ?? '';
    final fare       = (trip['fare'] as num?)?.toDouble();
    final vehicleType = trip['vehicle_type'] as String? ?? 'Comfort';
    final isAirport  = trip['is_airport'] == true;
    final terminal   = trip['terminal'] as String?;
    final airportCode = trip['airport_code'] as String?;
    final pickupZone = trip['pickup_zone'] as String?;
    final notes      = trip['notes'] as String?;
    final pickupLat  = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng  = (trip['pickup_lng'] as num?)?.toDouble();
    final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
    final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();

    DateTime? scheduledAt;
    final rawTime = trip['scheduled_at'] ?? trip['scheduled_time'] ?? trip['pickup_time'];
    if (rawTime != null) {
      try { scheduledAt = DateTime.parse(rawTime.toString()); } catch (_) {}
    }

    final dateFmt = DateFormat('EEE, MMM d');
    final timeFmt = DateFormat('h:mm a');
    final dateStr  = scheduledAt != null
        ? '${dateFmt.format(scheduledAt)} at ${timeFmt.format(scheduledAt)}'
        : '';
    final countdownStr = _countdown(scheduledAt);
    final mapUrl = _miniMapUrl(
      pickupLat: pickupLat, pickupLng: pickupLng,
      dropoffLat: dropoffLat, dropoffLng: dropoffLng,
    );

    return _cardShell(
      isAirport: isAirport,
      mapUrl: mapUrl,
      children: [
        // Header
        _cardHeader(
          dateStr: dateStr,
          countdown: countdownStr,
          fare: fare,
          isAirport: isAirport,
          airportCode: airportCode,
        ),
        // Route
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: _routeRow(pickup, dropoff, isAirport: isAirport),
        ),
        // Chips
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 6, children: [
            _chip(Icons.directions_car_rounded, vehicleType, Colors.white54),
            if (fare != null && fare > 0)
              _chip(Icons.attach_money_rounded, '\$${fare.toStringAsFixed(2)}', _gold),
            if (terminal != null) _chip(Icons.door_front_door_outlined, terminal, _airport),
            if (pickupZone != null) _chip(Icons.pin_drop_outlined, pickupZone, _airport),
          ]),
        ),
        // Notes
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
                    isAirport ? Icons.airplane_ticket_outlined : Icons.note_outlined,
                    size: 16, color: _airport,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(notes,
                        style: const TextStyle(color: Colors.white70, fontSize: 13)),
                  ),
                ],
              ),
            ),
          ),
        // Navigate button
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
          child: GestureDetector(
            onTap: () async {
              if (pickupLat == null || pickupLng == null) {
                ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                  content: Text(S.of(context).pickupCoordinatesNotAvailable),
                  backgroundColor: Colors.redAccent,
                  behavior: SnackBarBehavior.floating,
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ));
                return;
              }
              final uri = Uri.parse(
                'https://www.google.com/maps/dir/?api=1'
                '&destination=$pickupLat,$pickupLng&travelmode=driving',
              );
              if (await canLaunchUrl(uri)) {
                await launchUrl(uri, mode: LaunchMode.externalApplication);
              }
            },
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 13),
              decoration: BoxDecoration(
                gradient: const LinearGradient(colors: [_gold, _goldLight]),
                borderRadius: BorderRadius.circular(13),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.25),
                    blurRadius: 8, offset: const Offset(0, 3),
                  ),
                ],
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.navigation_rounded, color: Colors.black87, size: 18),
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
      ],
    );
  }

  // ─────────────────────────────────────────────
  //  Shared card parts
  // ─────────────────────────────────────────────

  Widget _cardShell({
    required bool isAirport,
    String? mapUrl,
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      decoration: BoxDecoration(
        color: _cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: isAirport
              ? _airport.withValues(alpha: 0.25)
              : Colors.white.withValues(alpha: 0.07),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.2),
            blurRadius: 14, offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Mini-map ──
            if (mapUrl != null)
              SizedBox(
                height: 140,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    Image.network(
                      mapUrl,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Container(
                        color: const Color(0xFF12151C),
                        child: const Center(
                          child: Icon(Icons.map_outlined,
                              color: Colors.white12, size: 36),
                        ),
                      ),
                      loadingBuilder: (_, child, progress) {
                        if (progress == null) return child;
                        return Container(
                          color: const Color(0xFF12151C),
                          child: const Center(
                            child: CircularProgressIndicator(
                                color: _gold, strokeWidth: 2),
                          ),
                        );
                      },
                    ),
                    // Fade bottom into card
                    Positioned(
                      bottom: 0, left: 0, right: 0,
                      child: Container(
                        height: 32,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                            colors: [
                              Colors.transparent,
                              _cardBg.withValues(alpha: 0.95),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ...children,
          ],
        ),
      ),
    );
  }

  Widget _cardHeader({
    required String dateStr,
    required String countdown,
    double? fare,
    required bool isAirport,
    String? airportCode,
  }) {
    final accentColor = isAirport ? _airport : _gold;
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: BoxDecoration(
        color: accentColor.withValues(alpha: 0.05),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.all(7),
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(
              isAirport ? Icons.flight_takeoff_rounded : Icons.schedule_rounded,
              color: accentColor, size: 18,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  dateStr,
                  style: const TextStyle(
                    color: Colors.white, fontSize: 13, fontWeight: FontWeight.w700,
                  ),
                ),
                if (countdown.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    countdown,
                    style: TextStyle(
                      color: accentColor, fontSize: 11, fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (fare != null && fare > 0)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(
                '\$${fare.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: Colors.black, fontWeight: FontWeight.w800, fontSize: 14,
                ),
              ),
            ),
          if (isAirport && airportCode != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _airport.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.flight_rounded, size: 13, color: _airport),
                  const SizedBox(width: 3),
                  Text(
                    airportCode,
                    style: const TextStyle(
                      color: _airport, fontSize: 12, fontWeight: FontWeight.w800,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _routeRow(String pickup, String dropoff, {required bool isAirport}) {
    final dropColor = isAirport ? _airport : Colors.white;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Column(
          children: [
            Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                color: _gold,
                shape: BoxShape.circle,
                border: Border.all(color: _gold.withValues(alpha: 0.3), width: 2.5),
              ),
            ),
            Container(width: 1.5, height: 26, color: Colors.white12),
            Container(
              width: 10, height: 10,
              decoration: BoxDecoration(
                color: dropColor,
                shape: BoxShape.circle,
                border: Border.all(color: dropColor.withValues(alpha: 0.3), width: 2.5),
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
                pickup.isNotEmpty ? pickup : S.of(context).pickupLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                dropoff.isNotEmpty ? dropoff : S.of(context).dropOffLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70, fontSize: 13, fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _chip(IconData icon, String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
