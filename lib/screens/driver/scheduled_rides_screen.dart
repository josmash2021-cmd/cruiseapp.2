import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import '../../services/haptic_service.dart';
import 'package:geolocator/geolocator.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/api_keys.dart';
import '../../config/app_theme.dart';
import '../../widgets/static_route_preview.dart';
import '../../widgets/neu_style.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../services/api_service.dart';
import '../../services/directions_service.dart';
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
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);
  static const _airport = Color(0xFF4285F4);

  late final TabController _tabCtrl;
  Timer? _countdownTimer;

  // ── Available tab state ──
  List<Map<String, dynamic>> _available = [];
  bool _loadingAvail = true;
  String? _errorAvail;
  int? _claimingId;
  DateTime? _lastAvailFetch; // throttle: min 10 s between fetches
  bool _fetchingAvail = false; // guard concurrent calls

  // ── My Rides tab state ──
  List<Map<String, dynamic>> _myRides = [];
  bool _loadingMine = true;
  String? _errorMine;
  DateTime? _lastMineFetch; // throttle: min 10 s between fetches
  bool _fetchingMine = false; // guard concurrent calls

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
    if (!force &&
        _lastAvailFetch != null &&
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
        setState(() {
          _available = list;
          _loadingAvail = false;
        });
      }
    } catch (_) {}

    // Fetch fresh data in background
    try {
      double lat = 0, lng = 0;
      try {
        final pos = await Geolocator.getLastKnownPosition()
            .timeout(const Duration(milliseconds: 400), onTimeout: () => null);
        if (pos != null) {
          lat = pos.latitude;
          lng = pos.longitude;
        }
      } catch (_) {}
      final trips = await ApiService.getAvailableScheduledTrips(
        lat: lat,
        lng: lng,
        radiusKm: 50,
      );
      if (!mounted) return;
      // Save to cache for next open
      SharedPreferences.getInstance()
          .then((p) => p.setString(_cacheKey, jsonEncode(trips)));
      setState(() {
        _available = trips;
        _loadingAvail = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (_available.isEmpty) {
        setState(() {
          _errorAvail = e.toString();
          _loadingAvail = false;
        });
      } else {
        setState(() {
          _loadingAvail = false;
        }); // keep showing cache on error
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
    if (!force &&
        _lastMineFetch != null &&
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
        setState(() {
          _myRides = list;
          _loadingMine = false;
        });
      }
    } catch (_) {}

    try {
      final uid = await ApiService.getCurrentUserId();
      if (uid == null) {
        if (mounted)
          setState(() {
            _errorMine = 'Not logged in';
            _loadingMine = false;
          });
        return;
      }
      final trips = await ApiService.getDriverScheduledTrips(uid);
      if (!mounted) return;
      SharedPreferences.getInstance()
          .then((p) => p.setString(_myCacheKey, jsonEncode(trips)));
      setState(() {
        _myRides = trips;
        _loadingMine = false;
      });
    } catch (e) {
      if (!mounted) return;
      if (_myRides.isEmpty) {
        setState(() {
          _errorMine = e.toString();
          _loadingMine = false;
        });
      } else {
        setState(() {
          _loadingMine = false;
        });
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
      HapticService.mediumImpact();
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(
          result['message'] ?? S.of(context).scheduledRideConfirmed,
          style:
              const TextStyle(color: Colors.black, fontWeight: FontWeight.w600),
        ),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
      // The ride belongs to the My Rides tab now: jump there and refresh
      // both lists so it leaves Requests instead of staying behind as a
      // persistent "Claimed" badge.
      _tabCtrl.animateTo(1);
      _loadMyRides(force: true);
      _loadAvailable(force: true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        // The one refusal the driver can act on gets its own sentence.
        // Everything else keeps the raw server reason.
        content: Text(
          e is ApiException && e.statusCode == 403
              ? S.of(context).scheduledOutOfState
              // 409: the row lock gave it to whoever asked first. The
              // loser was reading a raw exception for what is an ordinary
              // outcome of two drivers wanting the same ride.
              : e is ApiException && e.statusCode == 409
                  ? S.of(context).scheduledRideTaken
                  : '${S.of(context).error}: $e',
        ),
        backgroundColor: Colors.red,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
      // The list still shows a ride that has just gone to someone else.
      if (mounted) _loadAvailable();
    } finally {
      if (mounted) setState(() => _claimingId = null);
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
      backgroundColor: neuBase,
      body: Stack(
        children: [
          // Same dotted backdrop as the rider's home, so the neumorphic
          // cards sit on a surface instead of floating on flat black.
          const Positioned.fill(child: NeuDotsBackdrop()),
          NestedScrollView(
        headerSliverBuilder: (ctx, _) => [
          SliverAppBar(
            pinned: true,
            backgroundColor: neuBase,
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
        ],
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
            const Icon(Icons.error_outline_rounded,
                color: Colors.white24, size: 48),
            const SizedBox(height: 12),
            Text(error,
                style: const TextStyle(color: Colors.white54, fontSize: 13)),
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
                isMyRides
                    ? Icons.event_available_rounded
                    : Icons.event_busy_rounded,
                color: _gold,
                size: 34,
              ),
            ),
            const SizedBox(height: 20),
            Text(
              isMyRides
                  ? S.of(context).noUpcomingRides
                  : S.of(context).noScheduledTrips,
              style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 8),
            Text(
              isMyRides
                  ? S.of(context).scheduledRidesAssigned
                  : S.of(context).scheduledTripsHint,
              textAlign: TextAlign.center,
              style: const TextStyle(
                  color: Colors.white38, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: onRefresh,
      color: _gold,
      backgroundColor: neuSurface,
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
    final tripId = trip['id'] as int;
    final fare = (trip['fare'] as num?)?.toDouble() ?? 0;
    final pickup = trip['pickup_address'] as String? ?? '';
    final dropoff = trip['dropoff_address'] as String? ?? '';
    final vehicleType = trip['vehicle_type'] as String? ?? 'standard';
    final distKm = (trip['distance_km'] as num?)?.toDouble() ?? 0;
    final pickupLat = (trip['pickup_lat'] as num?)?.toDouble();
    final pickupLng = (trip['pickup_lng'] as num?)?.toDouble();
    final dropoffLat = (trip['dropoff_lat'] as num?)?.toDouble();
    final dropoffLng = (trip['dropoff_lng'] as num?)?.toDouble();

    DateTime? scheduledAt;
    if (trip['scheduled_at'] != null) {
      try {
        scheduledAt = DateTime.parse(trip['scheduled_at']);
      } catch (_) {}
    }

    final dateStr = scheduledAt != null
        ? DateFormat('EEE d MMM, h:mm a').format(scheduledAt.toLocal())
        : '';
    final countdownStr = _countdown(scheduledAt);
    final isClaiming = _claimingId == tripId;
    final hasPickup = pickupLat != null && pickupLng != null;

    return _cardShell(
      isAirport: false,
      children: [
        // 1) Header: clock + date + countdown left, gold fare pill right
        _cardHeader(
          dateStr: dateStr,
          countdown: countdownStr,
          fare: fare,
          isAirport: false,
        ),
        // 2) One row: tier badge + chips
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
          child: Wrap(spacing: 8, runSpacing: 6, children: [
            TierBadge(rideName: vehicleType),
            _chip(Icons.timer_rounded, countdownStr, _gold),
            if (distKm > 0)
              _chip(Icons.near_me_rounded, '${distKm.toStringAsFixed(1)} km',
                  Colors.blue),
          ]),
        ),
        // 3) Route preview — a still, not a live map. One of these is
        // mounted per card, and a native Mapbox surface per card is the
        // crash that closed the app.
        if (hasPickup)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
            child: SizedBox(
              height: 140,
              width: double.infinity,
              child: _previewWithFade(
                StaticRoutePreview(
                  pickupLat: pickupLat,
                  pickupLng: pickupLng,
                  dropoffLat: dropoffLat,
                  dropoffLng: dropoffLng,
                  borderRadius: 14,
                ),
              ),
            ),
          ),
        // 4) Route row
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
          child: _routeRow(pickup, dropoff, isAirport: false),
        ),
        // 5) Primary CTA
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
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2.5, color: Colors.black87),
                    )
                  : Text(
                      S.of(context).acceptRideButton,
                      style: const TextStyle(
                          fontWeight: FontWeight.w800, fontSize: 15),
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
    required List<Widget> children,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      // Airport trips keep their blue edge; everything else takes the
      // shared neu border.
      decoration: neuBox(
        radius: 20,
        borderColor: isAirport ? _airport.withValues(alpha: 0.25) : null,
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: children,
        ),
      ),
    );
  }

  /// Map thumbnail with its bottom edge fading into the card surface.
  Widget _previewWithFade(Widget map) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(14),
      child: Stack(
        fit: StackFit.expand,
        children: [
          map,
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              height: 32,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    neuSurface.withValues(alpha: 0.95),
                  ],
                ),
              ),
            ),
          ),
        ],
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
              color: accentColor,
              size: 18,
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
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (countdown.isNotEmpty) ...[
                  const SizedBox(height: 1),
                  Text(
                    countdown,
                    style: TextStyle(
                      color: accentColor,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
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
                  color: Colors.black,
                  fontWeight: FontWeight.w800,
                  fontSize: 14,
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
                      color: _airport,
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
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
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: _gold,
                shape: BoxShape.circle,
                border:
                    Border.all(color: _gold.withValues(alpha: 0.3), width: 2.5),
              ),
            ),
            Container(width: 1.5, height: 26, color: Colors.white12),
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: dropColor,
                shape: BoxShape.circle,
                border: Border.all(
                    color: dropColor.withValues(alpha: 0.3), width: 2.5),
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
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                dropoff.isNotEmpty ? dropoff : S.of(context).dropOffLabel,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
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
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
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
  static const _gold = Color(0xFFE8C547);
  static const _goldLight = Color(0xFFFBE47A);
  static const _airport = Color(0xFF4285F4);

  // ── Expand state ──
  bool _expanded = false;
  bool _mapEverExpanded = false;

  // ── Mapbox state ──
  AnimationController? _routeAnimCtrl;
  bool _routeLoaded = false;
  bool _routeLoading = false;
  String _tripDuration = '';

  // ── Countdown timer ──
  Timer? _countdownTimer;

  // ── Cancel state ──
  bool _cancelling = false;

  double? get _pickupLat => (widget.trip['pickup_lat'] as num?)?.toDouble();
  double? get _pickupLng => (widget.trip['pickup_lng'] as num?)?.toDouble();
  double? get _dropoffLat => (widget.trip['dropoff_lat'] as num?)?.toDouble();
  double? get _dropoffLng => (widget.trip['dropoff_lng'] as num?)?.toDouble();
  bool get _hasCoords =>
      _pickupLat != null &&
      _pickupLng != null &&
      _dropoffLat != null &&
      _dropoffLng != null;

  @override
  void initState() {
    super.initState();
    _countdownTimer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
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
    if (_expanded) unawaited(_loadRouteDuration());
  }

  Future<void> _cancelTrip() async {
    final tripId = widget.trip['id'] as int?;
    if (tripId == null) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1A1D24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(S.of(context).cancelRideTitle,
            style: const TextStyle(
                color: Colors.white, fontWeight: FontWeight.w700)),
        content: const Text(
          'Are you sure you want to cancel this scheduled ride? The ride will go back to the marketplace.',
          style: TextStyle(color: Colors.white70, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(S.of(context).keep,
                style: const TextStyle(color: Colors.white54)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(S.of(context).cancelRideTitle,
                style: const TextStyle(
                    color: Color(0xFFFF5252), fontWeight: FontWeight.w700)),
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
          content: Text(S.of(context).rideCancelled,
              style: const TextStyle(
                  color: Colors.black, fontWeight: FontWeight.w600)),
          backgroundColor: const Color(0xFFE8C547),
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
        widget.onCancelled?.call();
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${S.of(context).error}: $e'),
          backgroundColor: Colors.red,
          behavior: SnackBarBehavior.floating,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        ));
      }
    } finally {
      if (mounted) setState(() => _cancelling = false);
    }
  }

  // ── Mapbox callbacks ──

  /// Fetches the trip duration for the chip on the preview.
  ///
  /// This used to be _loadRouteAndAnimate and was kicked off by the map's
  /// onMapCreated — drawing pins and animating a polyline onto a live Mapbox
  /// surface. The preview is a still image now, so the drawing is gone; the
  /// duration is not, and it still has to load or the "X min trip" chip
  /// never appears.
  Future<void> _loadRouteDuration() async {
    if (_routeLoading || _routeLoaded || !_hasCoords) return;
    setState(() => _routeLoading = true);
    try {
      final pickup = LatLng(_pickupLat!, _pickupLng!);
      final dropoff = LatLng(_dropoffLat!, _dropoffLng!);
      final dirs = DirectionsService(ApiKeys.webServices);
      final route = await dirs.getRoute(origin: pickup, destination: dropoff);
      if (!mounted || !_expanded) return;
      if (route == null) return;
      setState(() {
        _tripDuration = route.durationText;
        _routeLoaded = true;
      });
    } catch (_) {
    } finally {
      if (mounted) setState(() => _routeLoading = false);
    }
  }

  String _countdown(DateTime? scheduledAt) {
    if (scheduledAt == null) return '';
    final diff = scheduledAt.difference(DateTime.now());
    if (diff.isNegative) return S.of(context).nowLabel;
    if (diff.inDays > 0) return 'In ${diff.inDays}d ${diff.inHours % 24}h';
    if (diff.inHours > 0) return 'In ${diff.inHours}h ${diff.inMinutes % 60}m';
    return 'In ${diff.inMinutes}m';
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final trip = widget.trip;
    final pickup = trip['pickup_address'] as String? ?? '';
    final dropoff = trip['dropoff_address'] as String? ?? '';
    final fare = (trip['fare'] as num?)?.toDouble();
    final vehicleType = trip['vehicle_type'] as String? ?? 'Comfort';
    final isAirport = trip['is_airport'] == true;
    final terminal = trip['terminal'] as String?;
    final airportCode = trip['airport_code'] as String?;
    final pickupZone = trip['pickup_zone'] as String?;
    final notes = trip['notes'] as String?;

    DateTime? scheduledAt;
    final rawTime =
        trip['scheduled_at'] ?? trip['scheduled_time'] ?? trip['pickup_time'];
    if (rawTime != null) {
      try {
        scheduledAt = DateTime.parse(rawTime.toString());
      } catch (_) {}
    }

    final dateFmt = DateFormat('EEE, MMM d');
    final timeFmt = DateFormat('h:mm a');
    final dateStr = scheduledAt != null
        ? '${dateFmt.format(scheduledAt)} at ${timeFmt.format(scheduledAt)}'
        : '';
    final countdownStr = _countdown(scheduledAt);
    final accentColor = isAirport ? _airport : _gold;
    final minutesUntil = scheduledAt != null
        ? scheduledAt.difference(DateTime.now()).inMinutes
        : 0;
    final canCancel = minutesUntil > 60;

    return GestureDetector(
      onTap: _hasCoords ? _toggle : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        // Airport trips keep their blue edge, an expanded card its gold
        // one; everything else takes the shared neu border.
        decoration: neuBox(
          radius: 20,
          borderColor: _expanded
              ? _gold.withValues(alpha: 0.35)
              : isAirport
                  ? _airport.withValues(alpha: 0.25)
                  : null,
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
                        color: accentColor,
                        size: 18,
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
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (countdownStr.isNotEmpty) ...[
                            const SizedBox(height: 1),
                            Text(
                              countdownStr,
                              style: TextStyle(
                                color: accentColor,
                                fontSize: 11,
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
                            color: Colors.black,
                            fontWeight: FontWeight.w800,
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
                                color: _airport,
                                fontSize: 12,
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

              // ── Expandable route preview ──
              if (_hasCoords)
                AnimatedSize(
                  duration: const Duration(milliseconds: 350),
                  curve: Curves.easeOutCubic,
                  child: _mapEverExpanded
                      ? Padding(
                          padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
                          child: SizedBox(
                            height: _expanded ? 200.0 : 0.0,
                            child: _buildMiniMap(),
                          ),
                        )
                      : const SizedBox.shrink(),
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
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: _gold,
                              shape: BoxShape.circle,
                              border: Border.all(
                                  color: _gold.withValues(alpha: 0.3),
                                  width: 2.5),
                            ),
                          ),
                          Container(
                              width: 1.5, height: 26, color: Colors.white12),
                          Container(
                            width: 10,
                            height: 10,
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
                                color: Colors.white,
                                fontSize: 13,
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
                                color: Colors.white70,
                                fontSize: 13,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                secondChild: const SizedBox(width: double.infinity, height: 0),
                crossFadeState: _expanded
                    ? CrossFadeState.showSecond
                    : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 300),
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
                      border:
                          Border.all(color: _airport.withValues(alpha: 0.12)),
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
                          child: Text(notes,
                              style: const TextStyle(
                                  color: Colors.white70, fontSize: 13)),
                        ),
                      ],
                    ),
                  ),
                ),

              // ── Navigate to Pickup button (primary CTA) ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
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
                        reverseTransitionDuration:
                            const Duration(milliseconds: 300),
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
                      gradient:
                          const LinearGradient(colors: [_gold, _goldLight]),
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

              // ── Discreet cancel (>60 min) or Contact Support (<60 min) ──
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                child: canCancel
                    ? TextButton(
                        onPressed: _cancelling ? null : _cancelTrip,
                        child: _cancelling
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2, color: Color(0xFFFF5252)))
                            : const Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.cancel_outlined,
                                      color: Color(0xFFFF5252), size: 16),
                                  SizedBox(width: 6),
                                  Text(
                                    'Cancel Ride',
                                    style: TextStyle(
                                        color: Color(0xFFFF5252),
                                        fontWeight: FontWeight.w700,
                                        fontSize: 14),
                                  ),
                                ],
                              ),
                      )
                    : const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(Icons.support_agent_rounded,
                              color: Colors.white54, size: 16),
                          SizedBox(width: 6),
                          Text(
                            'Contact Support to cancel',
                            style: TextStyle(
                                color: Colors.white54,
                                fontWeight: FontWeight.w600,
                                fontSize: 13),
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMiniMap() {
    // Every expanded card used to mount its own live Mapbox surface, so two
    // cards open at once was already two of them. This is a still image, so
    // the count no longer matters.
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        children: [
          Positioned.fill(
            child: StaticRoutePreview(
              pickupLat: _pickupLat!,
              pickupLng: _pickupLng!,
              dropoffLat: _dropoffLat,
              dropoffLng: _dropoffLng,
            ),
          ),
          // Fade the bottom edge into the card surface.
          const Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: SizedBox(
                height: 32,
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [Colors.transparent, neuSurface],
                    ),
                  ),
                ),
              ),
            ),
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
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
