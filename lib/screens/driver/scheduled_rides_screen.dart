import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:url_launcher/url_launcher.dart';

import '../../config/api_keys.dart';
import '../../config/app_theme.dart';
import '../../config/map_theme.dart';
import '../../config/mapbox_config.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../services/api_service.dart';
import '../../services/directions_service.dart';
import '../../widgets/map/circular_pin_renderer.dart';
import '../../widgets/tier_badge.dart';
import 'scheduled_ride_details_screen.dart';

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
  final Set<int> _claimedIds = {};   // locally claimed — show cancel
  int? _cancellingClaimId;           // cancel in progress
  DateTime? _lastAvailFetch;         // throttle: min 10 s between fetches
  bool _fetchingAvail = false;       // guard concurrent calls

  // ── My Rides tab state ──
  List<Map<String, dynamic>> _myRides = [];
  bool _loadingMine  = true;
  String? _errorMine;
  DateTime? _lastMineFetch;          // throttle: min 10 s between fetches
  bool _fetchingMine = false;        // guard concurrent calls

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

  static const _cacheKey = 'sched_avail_cache';

  Future<void> _loadAvailable({bool force = false}) async {
    // Throttle: skip if already fetching or fetched within 10 s
    if (_fetchingAvail) return;
    if (!force && _lastAvailFetch != null &&
        DateTime.now().difference(_lastAvailFetch!).inSeconds < 10) {
      return;
    }
    _fetchingAvail = true;
    // Show cached data instantly while fresh data loads in background
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_cacheKey);
      if (cached != null && mounted) {
        final list = (jsonDecode(cached) as List).cast<Map<String, dynamic>>();
        setState(() { _available = list; _loadingAvail = false; });
      }
    } catch (_) {}

    // Fetch fresh data in background
    try {
      double lat = 0, lng = 0;
      try {
        final pos = await Geolocator.getLastKnownPosition()
            .timeout(const Duration(milliseconds: 400), onTimeout: () => null);
        if (pos != null) { lat = pos.latitude; lng = pos.longitude; }
      } catch (_) {}
      final trips = await ApiService.getAvailableScheduledTrips(
        lat: lat, lng: lng, radiusKm: 50,
      );
      if (!mounted) return;
      // Save to cache for next open
      SharedPreferences.getInstance().then((p) =>
        p.setString(_cacheKey, jsonEncode(trips)));
      setState(() { _available = trips; _loadingAvail = false; });
    } catch (e) {
      if (!mounted) return;
      if (_available.isEmpty) {
        setState(() { _errorAvail = e.toString(); _loadingAvail = false; });
      } else {
        setState(() { _loadingAvail = false; }); // keep showing cache on error
      }
    } finally {
      _fetchingAvail = false;
      _lastAvailFetch = DateTime.now();
    }
  }

  static const _myCacheKey = 'sched_mine_cache';

  Future<void> _loadMyRides({bool force = false}) async {
    // Throttle: skip if already fetching or fetched within 10 s
    if (_fetchingMine) return;
    if (!force && _lastMineFetch != null &&
        DateTime.now().difference(_lastMineFetch!).inSeconds < 10) {
      return;
    }
    _fetchingMine = true;
    // Show cached data instantly
    try {
      final prefs = await SharedPreferences.getInstance();
      final cached = prefs.getString(_myCacheKey);
      if (cached != null && mounted) {
        final list = (jsonDecode(cached) as List).cast<Map<String, dynamic>>();
        setState(() { _myRides = list; _loadingMine = false; });
      }
    } catch (_) {}

    try {
      final uid = await ApiService.getCurrentUserId();
      if (uid == null) {
        if (mounted) setState(() { _errorMine = 'Not logged in'; _loadingMine = false; });
        return;
      }
      final trips = await ApiService.getDriverScheduledTrips(uid);
      if (!mounted) return;
      SharedPreferences.getInstance().then((p) =>
        p.setString(_myCacheKey, jsonEncode(trips)));
      setState(() { _myRides = trips; _loadingMine = false; });
    } catch (e) {
      if (!mounted) return;
      if (_myRides.isEmpty) {
        setState(() { _errorMine = e.toString(); _loadingMine = false; });
      } else {
        setState(() { _loadingMine = false; });
      }
    } finally {
      _fetchingMine = false;
      _lastMineFetch = DateTime.now();
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
      setState(() => _claimedIds.add(tripId));
      _loadMyRides(force: true);
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

  Future<void> _cancelClaimedTrip(int tripId) async {
    setState(() => _cancellingClaimId = tripId);
    try {
      await ApiService.cancelScheduledTrip(tripId);
      if (!mounted) return;
      HapticFeedback.mediumImpact();
      setState(() => _claimedIds.remove(tripId));
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: const Text('Ride cancelled', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
      _loadMyRides(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('Could not cancel: $e'),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
    } finally {
      if (mounted) setState(() => _cancellingClaimId = null);
    }
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
                  _loadAvailable(force: true);
                  _loadMyRides(force: true);
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
                          const Icon(Icons.people_alt_rounded, size: 14),
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
              onRefresh: () => _loadAvailable(force: true),
              isMyRides: false,
            ),
            _buildTabContent(
              loading: _loadingMine,
              error: _errorMine,
              trips: _myRides,
              onRefresh: () => _loadMyRides(force: true),
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
            ? _DriverMyRideCard(trip: trips[i], onCancelled: onRefresh)
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
    final hasPickup = pickupLat != null && pickupLng != null;

    return _cardShell(
      isAirport: false,
      mapWidget: hasPickup
          ? _AvailableMiniMap(
              pickupLat: pickupLat,
              pickupLng: pickupLng,
              dropoffLat: dropoffLat,
              dropoffLng: dropoffLng,
            )
          : null,
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
            TierBadge(rideName: vehicleType),
          ]),
        ),
        // Action — Accept or Claimed+Cancel
        if (_claimedIds.contains(tripId)) ...[
          // ── Claimed badge ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(vertical: 11),
              decoration: BoxDecoration(
                color: _gold.withValues(alpha: 0.10),
                borderRadius: BorderRadius.circular(13),
                border: Border.all(color: _gold.withValues(alpha: 0.35)),
              ),
              child: const Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.check_circle_rounded, color: _gold, size: 18),
                  SizedBox(width: 6),
                  Text('Claimed', style: TextStyle(color: _gold, fontWeight: FontWeight.w800, fontSize: 15)),
                ],
              ),
            ),
          ),
          // ── Cancel button (only if >60 min before ride) ──
          if (scheduledAt != null && scheduledAt.difference(DateTime.now()).inMinutes > 60)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: GestureDetector(
                onTap: _cancellingClaimId == tripId ? null : () => _cancelClaimedTrip(tripId),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 11),
                  decoration: BoxDecoration(
                    color: const Color(0xFFFF5252).withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(13),
                    border: Border.all(color: const Color(0xFFFF5252).withValues(alpha: 0.25)),
                  ),
                  child: _cancellingClaimId == tripId
                      ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF5252))))
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.cancel_outlined, color: Color(0xFFFF5252), size: 16),
                            SizedBox(width: 6),
                            Text('Cancel Ride', style: TextStyle(color: Color(0xFFFF5252), fontWeight: FontWeight.w700, fontSize: 14)),
                          ],
                        ),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(vertical: 11),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.04),
                  borderRadius: BorderRadius.circular(13),
                  border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                ),
                child: const Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Icon(Icons.support_agent_rounded, color: Colors.white54, size: 16),
                    SizedBox(width: 6),
                    Text('Contact Support to cancel', style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600, fontSize: 13)),
                  ],
                ),
              ),
            ),
        ] else ...[
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
      ],
    );
  }


  // ─────────────────────────────────────────────
  //  Shared card parts
  // ─────────────────────────────────────────────

  Widget _cardShell({
    required bool isAirport,
    Widget? mapWidget,
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
            if (mapWidget != null)
              SizedBox(
                height: 140,
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    mapWidget,
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

// ─────────────────────────────────────────────────────────────────────────────
//  _DriverMyRideCard — expandable card with live animated Mapbox route map
// ─────────────────────────────────────────────────────────────────────────────

class _DriverMyRideCard extends StatefulWidget {
  final Map<String, dynamic> trip;
  final VoidCallback? onCancelled;
  const _DriverMyRideCard({required this.trip, this.onCancelled});

  @override
  State<_DriverMyRideCard> createState() => _DriverMyRideCardState();
}

class _DriverMyRideCardState extends State<_DriverMyRideCard>
    with TickerProviderStateMixin {
  static const _gold      = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);
  static const _darkBg    = Color(0xFF0F1117);
  static const _cardBg    = Color(0xFF1A1D24);
  static const _airport   = Color(0xFF4285F4);

  // ── Expand state ──
  bool _expanded = false;
  bool _mapEverExpanded = false;

  // ── Mapbox state ──
  mapbox.MapboxMap? _mapCtrl;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polyAnnotMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  final List<mapbox.PointAnnotation> _markerAnnots = [];
  AnimationController? _routeAnimCtrl;
  bool _routeLoaded   = false;
  bool _routeLoading  = false;
  String _tripDuration = '';

  // ── Countdown timer ──
  Timer? _countdownTimer;

  // ── Cancel state ──
  bool _cancelling = false;

  double? get _pickupLat  => (widget.trip['pickup_lat']  as num?)?.toDouble();
  double? get _pickupLng  => (widget.trip['pickup_lng']  as num?)?.toDouble();
  double? get _dropoffLat => (widget.trip['dropoff_lat'] as num?)?.toDouble();
  double? get _dropoffLng => (widget.trip['dropoff_lng'] as num?)?.toDouble();
  bool get _hasCoords =>
      _pickupLat != null && _pickupLng != null &&
      _dropoffLat != null && _dropoffLng != null;

  @override
  void initState() {
    super.initState();
    _countdownTimer = Timer.periodic(
        const Duration(minutes: 1), (_) { if (mounted) setState(() {}); });
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _routeAnimCtrl?.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) _mapEverExpanded = true;
    });
  }

  Future<void> _cancelTrip() async {
    final tripId = widget.trip['id'] as int?;
    if (tripId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: const Text('Cancel Ride', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text(
          'Are you sure you want to cancel this scheduled ride? The ride will go back to the marketplace.',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep', style: TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Cancel Ride', style: TextStyle(color: Color(0xFFFF5252), fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _cancelling = true);
    try {
      await ApiService.cancelScheduledTrip(tripId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: const Text('Ride cancelled', style: TextStyle(color: Colors.black, fontWeight: FontWeight.w600)),
          backgroundColor: const Color(0xFFE8C547),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
        widget.onCancelled?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Could not cancel: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
      }
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  // ── Mapbox callbacks ──

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _mapCtrl = ctrl;
    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
    _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
    try {
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-allow-overlap', true);
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-ignore-placement', true);
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-anchor', 'bottom');
    } catch (_) {}
    _polyAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager();
    if (_hasCoords && mounted) _loadRouteAndAnimate();
  }

  Future<void> _loadRouteAndAnimate() async {
    if (_routeLoading || _routeLoaded || !_hasCoords) return;
    setState(() => _routeLoading = true);
    try {
      final pickup  = LatLng(_pickupLat!,  _pickupLng!);
      final dropoff = LatLng(_dropoffLat!, _dropoffLng!);
      final dirs    = DirectionsService(ApiKeys.webServices);
      final route   = await dirs.getRoute(origin: pickup, destination: dropoff);
      if (!mounted || !_expanded) return;
      if (route == null) return;
      setState(() {
        _tripDuration = route.durationText;
        _routeLoaded  = true;
      });
      // Use road-snapped route points directly — do NOT cap with raw coords
      final routePts = route.points;
      await _fitCamera(routePts, pitch: 0);
      await _placePins(pickup, dropoff);
      await _animateRoute(routePts);
      if (_mapCtrl != null && mounted) {
        final curCam = await _mapCtrl!.getCameraState();
        await _mapCtrl!.flyTo(
          mapbox.CameraOptions(
            center: curCam.center,
            zoom: curCam.zoom,
            bearing: curCam.bearing,
            pitch: 35,
          ),
          mapbox.MapAnimationOptions(duration: 700),
        );
      }
    } catch (_) {
    } finally {
      if (mounted) setState(() => _routeLoading = false);
    }
  }

  Future<void> _fitCamera(List<LatLng> pts, {double pitch = 0}) async {
    if (_mapCtrl == null || pts.length < 2) return;
    final lats = pts.map((p) => p.latitude).toList()..sort();
    final lngs = pts.map((p) => p.longitude).toList()..sort();
    try {
      final cam = await _mapCtrl!.cameraForCoordinatesPadding(
        [
          mapbox.Point(coordinates: mapbox.Position(lngs.first, lats.first)),
          mapbox.Point(coordinates: mapbox.Position(lngs.last,  lats.last)),
        ],
        mapbox.CameraOptions(pitch: pitch),
        mapbox.MbxEdgeInsets(top: 70, left: 60, bottom: 70, right: 60),
        null,
        null,
      );
      await _mapCtrl!.flyTo(cam, mapbox.MapAnimationOptions(duration: 900));
    } catch (_) {}
  }

  Future<void> _placePins(LatLng pickup, LatLng dropoff) async {
    if (_pointAnnotMgr == null) return;
    for (final a in _markerAnnots) {
      try { await _pointAnnotMgr!.delete(a); } catch (_) {}
    }
    _markerAnnots.clear();
    final pickupBytes = await renderCircularPinBytes(
        icon: CircularPinIcon.person, isPickup: true,  radius: 44);
    final dropBytes   = await renderCircularPinBytes(
        icon: CircularPinIcon.home,   isPickup: false, radius: 44);
    if (!mounted) return;
    try {
      final a = await _pointAnnotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
            coordinates: mapbox.Position(pickup.longitude, pickup.latitude)),
        image:       pickupBytes,
        iconSize:    0.65,
        iconAnchor:  mapbox.IconAnchor.BOTTOM,
        iconOffset:  [0, 0],
      ));
      _markerAnnots.add(a);
    } catch (_) {}
    try {
      final a = await _pointAnnotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
            coordinates: mapbox.Position(dropoff.longitude, dropoff.latitude)),
        image:      dropBytes,
        iconSize:   0.65,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
      _markerAnnots.add(a);
    } catch (_) {}
  }

  Future<void> _animateRoute(List<LatLng> points) async {
    if (_polyAnnotMgr == null || points.length < 2) return;
    if (_routeAnnot != null) {
      try { await _polyAnnotMgr!.delete(_routeAnnot!); } catch (_) {}
      _routeAnnot = null;
    }
    final initCoords = points
        .sublist(0, 2)
        .map((p) => mapbox.Position(p.longitude, p.latitude))
        .toList();
    try {
      _routeAnnot = await _polyAnnotMgr!.create(mapbox.PolylineAnnotationOptions(
        geometry:  mapbox.LineString(coordinates: initCoords),
        lineColor: const Color(0xFFFFD700).toARGB32(),
        lineWidth: 4.5,
        lineJoin:  mapbox.LineJoin.ROUND,
      ));
    } catch (_) {}
    if (!mounted || _routeAnnot == null) return;

    _routeAnimCtrl?.dispose();
    _routeAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    final completer = Completer<void>();
    int  lastCount = 2;
    bool updating  = false;
    _routeAnimCtrl!.addListener(() {
      if (!mounted || updating) return;
      final eased = Curves.easeInOutSine.transform(_routeAnimCtrl!.value);
      final count = (eased * points.length).round().clamp(2, points.length);
      if (count != lastCount) {
        lastCount = count;
        final coords = points
            .sublist(0, count)
            .map((p) => mapbox.Position(p.longitude, p.latitude))
            .toList();
        _routeAnnot!.geometry = mapbox.LineString(coordinates: coords);
        updating = true;
        _polyAnnotMgr!.update(_routeAnnot!)
            .then((_) => updating = false)
            .catchError((_) { updating = false; return false; });
      }
    });
    _routeAnimCtrl!.addStatusListener((s) {
      if (s == AnimationStatus.completed && !completer.isCompleted) {
        completer.complete();
      }
    });
    _routeAnimCtrl!.forward();
    return completer.future;
  }

  // ── Helpers ──

  String _countdown(DateTime? scheduledAt) {
    if (scheduledAt == null) return '';
    final diff = scheduledAt.difference(DateTime.now());
    if (diff.isNegative) return S.of(context).nowLabel;
    if (diff.inDays  > 0) return 'In ${diff.inDays}d ${diff.inHours % 24}h';
    if (diff.inHours > 0) return 'In ${diff.inHours}h ${diff.inMinutes % 60}m';
    return 'In ${diff.inMinutes}m';
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final pickup      = trip['pickup_address']  as String? ?? '';
    final dropoff     = trip['dropoff_address'] as String? ?? '';
    final fare        = (trip['fare'] as num?)?.toDouble();
    final vehicleType = trip['vehicle_type']    as String? ?? 'Comfort';
    final isAirport   = trip['is_airport'] == true;
    final terminal    = trip['terminal']    as String?;
    final airportCode = trip['airport_code'] as String?;
    final pickupZone  = trip['pickup_zone'] as String?;
    final notes       = trip['notes'] as String?;

    DateTime? scheduledAt;
    final rawTime = trip['scheduled_at'] ?? trip['scheduled_time'] ?? trip['pickup_time'];
    if (rawTime != null) {
      try { scheduledAt = DateTime.parse(rawTime.toString()); } catch (_) {}
    }

    final dateFmt = DateFormat('EEE, MMM d');
    final timeFmt = DateFormat('h:mm a');
    final dateStr     = scheduledAt != null
        ? '${dateFmt.format(scheduledAt)} at ${timeFmt.format(scheduledAt)}'
        : '';
    final countdownStr = _countdown(scheduledAt);
    final accentColor  = isAirport ? _airport : _gold;
    final minutesUntil = scheduledAt != null
        ? scheduledAt.difference(DateTime.now()).inMinutes
        : 0;
    final canCancel = minutesUntil > 60;

    return GestureDetector(
      onTap: _hasCoords ? _toggle : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: _cardBg,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _expanded
                ? _gold.withValues(alpha: 0.35)
                : isAirport
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
              // ── Header ──
              Container(
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
                        isAirport
                            ? Icons.flight_takeoff_rounded
                            : Icons.schedule_rounded,
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
                              color: Colors.white, fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (countdownStr.isNotEmpty) ...[
                            const SizedBox(height: 1),
                            Text(
                              countdownStr,
                              style: TextStyle(
                                color: accentColor, fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                    if (fare != null && fare > 0)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 10, vertical: 5),
                        decoration: BoxDecoration(
                          color: _gold,
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Text(
                          '\$${fare.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: Colors.black, fontWeight: FontWeight.w800,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    if (isAirport && airportCode != null) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: _airport.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.flight_rounded,
                                size: 13, color: _airport),
                            const SizedBox(width: 3),
                            Text(
                              airportCode,
                              style: const TextStyle(
                                color: _airport, fontSize: 12,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    if (_hasCoords) ...[
                      const SizedBox(width: 8),
                      AnimatedRotation(
                        turns: _expanded ? 0.5 : 0,
                        duration: const Duration(milliseconds: 300),
                        child: Icon(
                          Icons.expand_more_rounded,
                          color: _gold.withValues(alpha: 0.7),
                          size: 20,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // ── Route row (hides when expanded) ──
              AnimatedCrossFade(
                firstChild: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        children: [
                          Container(
                            width: 10, height: 10,
                            decoration: BoxDecoration(
                              color: _gold,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: _gold.withValues(alpha: 0.3),
                                  width: 2.5),
                            ),
                          ),
                          Container(
                              width: 1.5, height: 26,
                              color: Colors.white12),
                          Container(
                            width: 10, height: 10,
                            decoration: BoxDecoration(
                              color: isAirport ? _airport : Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: (isAirport ? _airport : Colors.white)
                                    .withValues(alpha: 0.3),
                                width: 2.5,
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
                              pickup.isNotEmpty
                                  ? pickup
                                  : S.of(context).pickupLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white, fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 16),
                            Text(
                              dropoff.isNotEmpty
                                  ? dropoff
                                  : S.of(context).dropOffLabel,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                color: Colors.white70, fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                secondChild:
                    const SizedBox(width: double.infinity, height: 0),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 300),
              ),

              // ── Chips ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Wrap(spacing: 8, runSpacing: 6, children: [
                  TierBadge(rideName: vehicleType),
                  if (fare != null && fare > 0)
                    _chip(Icons.attach_money_rounded,
                        '\$${fare.toStringAsFixed(2)}', _gold),
                  if (terminal != null)
                    _chip(Icons.door_front_door_outlined, terminal, _airport),
                  if (pickupZone != null)
                    _chip(Icons.pin_drop_outlined, pickupZone, _airport),
                ]),
              ),

              // ── Notes ──
              if (notes != null && notes.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: _airport.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                          color: _airport.withValues(alpha: 0.12)),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isAirport
                              ? Icons.airplane_ticket_outlined
                              : Icons.note_outlined,
                          size: 16, color: _airport,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(notes,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── Expandable animated Mapbox map ──
              if (_hasCoords)
                AnimatedSize(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOutCubic,
                  child: _mapEverExpanded
                      ? Padding(
                          padding:
                              const EdgeInsets.fromLTRB(12, 10, 12, 0),
                          child: SizedBox(
                            height: _expanded ? 200.0 : 0.0,
                            child: _buildMiniMap(),
                          ),
                        )
                      : const SizedBox.shrink(),
                ),

              // ── Cancel button (>60 min) or Contact Support (<60 min) ──
              if (canCancel)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: GestureDetector(
                    onTap: _cancelling ? null : _cancelTrip,
                    child: Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(vertical: 11),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF5252).withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(13),
                        border: Border.all(color: const Color(0xFFFF5252).withValues(alpha: 0.25)),
                      ),
                      child: _cancelling
                          ? const Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Color(0xFFFF5252))))
                          : const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.cancel_outlined, color: Color(0xFFFF5252), size: 16),
                                SizedBox(width: 6),
                                Text(
                                  'Cancel Ride',
                                  style: TextStyle(color: Color(0xFFFF5252), fontWeight: FontWeight.w700, fontSize: 14),
                                ),
                              ],
                            ),
                    ),
                  ),
                )
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 0, 16, 0),
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 11),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(13),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
                    ),
                    child: const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(Icons.support_agent_rounded, color: Colors.white54, size: 16),
                        SizedBox(width: 6),
                        Text(
                          'Contact Support to cancel',
                          style: TextStyle(color: Colors.white54, fontWeight: FontWeight.w600, fontSize: 13),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── Navigate to Pickup button ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                child: GestureDetector(
                  onTap: () async {
                    // Open countdown / ride details screen
                    final result = await Navigator.of(context).push<String>(
                      PageRouteBuilder(
                        pageBuilder: (_, __, ___) => ScheduledRideDetailsScreen(
                          trip: widget.trip,
                          minutesUntil: minutesUntil.toDouble(),
                        ),
                        transitionsBuilder: (_, anim, __, child) =>
                            FadeTransition(opacity: anim, child: child),
                        transitionDuration: const Duration(milliseconds: 400),
                        reverseTransitionDuration: const Duration(milliseconds: 300),
                      ),
                    );
                    // If ride was started or cancelled, refresh parent
                    if (result == 'started' || result == 'cancelled') {
                      widget.onCancelled?.call();
                    }
                  },
                  child: Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 13),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                          colors: [_gold, _goldLight]),
                      borderRadius: BorderRadius.circular(13),
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
                        Icon(Icons.navigation_rounded,
                            color: Colors.black87, size: 18),
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
          ),
        ),
      ),
    );
  }

  Widget _buildMiniMap() {
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          mapbox.MapWidget(
            styleUri: MapboxConfig.styleDark,
            cameraOptions: mapbox.CameraOptions(
              center: mapbox.Point(
                coordinates: mapbox.Position(
                  (_pickupLng! + (_dropoffLng ?? _pickupLng!)) / 2,
                  (_pickupLat! + (_dropoffLat ?? _pickupLat!)) / 2,
                ),
              ),
              zoom: 11.5,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedListener: (_) async {
              if (_mapCtrl != null) {
                await MapTheme.applyNavyGold(_mapCtrl!);
                if (_pointAnnotMgr != null) {
                  try {
                    await _mapCtrl!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
                    await _mapCtrl!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
                    await _mapCtrl!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true);
                    await _mapCtrl!.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-anchor', 'bottom');
                  } catch (_) {}
                }
              }
            },
          ),
          if (_routeLoading)
            const Center(
              child: CircularProgressIndicator(
                color: Color(0xFFE8C547),
                strokeWidth: 2.5,
              ),
            ),
          if (_routeLoaded && _tripDuration.isNotEmpty)
            Positioned(
              bottom: 12,
              right: 12,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(
                    color: const Color(0xFFE8C547).withValues(alpha: 0.5),
                  ),
                ),
                child: Text(
                  '$_tripDuration trip',
                  style: const TextStyle(
                    color: Color(0xFFE8C547),
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                  ),
                ),
              ),
            ),
        ],
      ),
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

// ─────────────────────────────────────────────────────────────────────────────
//  _AvailableMiniMap — lightweight interactive map with golden teardrop pins
// ─────────────────────────────────────────────────────────────────────────────

class _AvailableMiniMap extends StatefulWidget {
  final double pickupLat;
  final double pickupLng;
  final double? dropoffLat;
  final double? dropoffLng;

  const _AvailableMiniMap({
    required this.pickupLat,
    required this.pickupLng,
    this.dropoffLat,
    this.dropoffLng,
  });

  @override
  State<_AvailableMiniMap> createState() => _AvailableMiniMapState();
}

class _AvailableMiniMapState extends State<_AvailableMiniMap> {
  mapbox.MapboxMap? _mapCtrl;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polyAnnotMgr;
  bool _routeLoading = false;
  bool _routeLoaded = false;

  bool get _hasDropoff =>
      widget.dropoffLat != null && widget.dropoffLng != null;

  @override
  Widget build(BuildContext context) {
    final centerLng = _hasDropoff
        ? (widget.pickupLng + widget.dropoffLng!) / 2
        : widget.pickupLng;
    final centerLat = _hasDropoff
        ? (widget.pickupLat + widget.dropoffLat!) / 2
        : widget.pickupLat;

    return mapbox.MapWidget(
      styleUri: MapboxConfig.styleDark,
      cameraOptions: mapbox.CameraOptions(
        center: mapbox.Point(
          coordinates: mapbox.Position(centerLng, centerLat),
        ),
        zoom: _hasDropoff ? 11.0 : 14.0,
      ),
      onMapCreated: _onMapCreated,
      onStyleLoadedListener: (_) async {
        if (_mapCtrl != null) {
          await MapTheme.applyNavyGold(_mapCtrl!);
        }
      },
    );
  }

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _mapCtrl = ctrl;
    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    ctrl.attribution
        .updateSettings(mapbox.AttributionSettings(enabled: false));
    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
    _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
    try {
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-allow-overlap', true);
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-ignore-placement', true);
      await ctrl.style.setStyleLayerProperty(
          _pointAnnotMgr!.id, 'icon-anchor', 'bottom');
    } catch (_) {}
    _polyAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager();
    if (mounted) await _placePins();
    if (mounted && _hasDropoff) await _fitBounds();
  }

  Future<void> _placePins() async {
    if (_pointAnnotMgr == null) return;
    final pickupBytes = await renderCircularPinBytes(
        icon: CircularPinIcon.person, isPickup: true, radius: 44);
    if (!mounted) return;
    try {
      await _pointAnnotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(
            coordinates:
                mapbox.Position(widget.pickupLng, widget.pickupLat)),
        image: pickupBytes,
        iconSize: 0.55,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
    } catch (_) {}

    if (_hasDropoff) {
      final dropBytes = await renderCircularPinBytes(
          icon: CircularPinIcon.flag, isPickup: false, radius: 44);
      if (!mounted) return;
      try {
        await _pointAnnotMgr!.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(
              coordinates:
                  mapbox.Position(widget.dropoffLng!, widget.dropoffLat!)),
          image: dropBytes,
          iconSize: 0.55,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      } catch (_) {}

      // Fetch real road-based route and draw golden polyline
      if (_polyAnnotMgr != null) {
        _fetchAndDrawRoute();
      }
    }
  }

  Future<void> _fetchAndDrawRoute() async {
    if (!_hasDropoff || _routeLoading || _routeLoaded) return;
    _routeLoading = true;
    try {
      final pickup = LatLng(widget.pickupLat, widget.pickupLng);
      final dropoff = LatLng(widget.dropoffLat!, widget.dropoffLng!);
      final dirs = DirectionsService(ApiKeys.webServices);
      final route = await dirs.getRoute(origin: pickup, destination: dropoff);
      if (!mounted || route == null || route.points.length < 2) {
        // Fallback: straight line if directions API fails
        _drawStraightLine();
        return;
      }
      _routeLoaded = true;
      // Use road-snapped route points directly — do NOT cap with raw coords
      final coords = route.points
          .map((p) => mapbox.Position(p.longitude, p.latitude))
          .toList();
      try {
        await _polyAnnotMgr!.create(mapbox.PolylineAnnotationOptions(
          geometry: mapbox.LineString(coordinates: coords),
          lineColor: const Color(0xFFE8C547).toARGB32(),
          lineWidth: 3.0,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
      } catch (_) {}
      // Fit bounds to route
      if (_mapCtrl != null) await _fitBounds();
    } catch (_) {
      _drawStraightLine();
    } finally {
      _routeLoading = false;
    }
  }

  void _drawStraightLine() {
    if (_polyAnnotMgr == null || !_hasDropoff) return;
    try {
      _polyAnnotMgr!.create(mapbox.PolylineAnnotationOptions(
        geometry: mapbox.LineString(coordinates: [
          mapbox.Position(widget.pickupLng, widget.pickupLat),
          mapbox.Position(widget.dropoffLng!, widget.dropoffLat!),
        ]),
        lineColor: const Color(0xFFE8C547).toARGB32(),
        lineWidth: 3.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    } catch (_) {}
  }

  Future<void> _fitBounds() async {
    if (_mapCtrl == null || !_hasDropoff) return;
    try {
      final cam = await _mapCtrl!.cameraForCoordinateBounds(
        mapbox.CoordinateBounds(
          southwest: mapbox.Point(
            coordinates: mapbox.Position(
              math.min(widget.pickupLng, widget.dropoffLng!),
              math.min(widget.pickupLat, widget.dropoffLat!),
            ),
          ),
          northeast: mapbox.Point(
            coordinates: mapbox.Position(
              math.max(widget.pickupLng, widget.dropoffLng!),
              math.max(widget.pickupLat, widget.dropoffLat!),
            ),
          ),
          infiniteBounds: false,
        ),
        mapbox.MbxEdgeInsets(top: 55, left: 45, bottom: 55, right: 45),
        null, null, null, null,
      );
      await _mapCtrl!.flyTo(cam, mapbox.MapAnimationOptions(duration: 600));
    } catch (_) {}
  }
}
