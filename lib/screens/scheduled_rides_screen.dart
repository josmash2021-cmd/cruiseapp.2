import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/map_theme.dart';
import '../config/mapbox_config.dart';
import '../config/page_transitions.dart';
import '../models/lat_lng.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/notification_service.dart';
import '../services/places_service.dart';
import '../utils/app_toast.dart';
import '../widgets/map/circular_pin_renderer.dart';
import '../l10n/app_localizations.dart';
import 'help_screen.dart';
import 'pickup_dropoff_search_screen.dart';
import 'ride_request_screen.dart';
import 'schedule_picker_sheet.dart';

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

  Future<bool> _cancelTrip(int tripId) async {
    try {
      await ApiService.cancelTrip(tripId);
      await NotificationService.cancelRideReminder(tripId);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _startScheduleFlow() async {
    final isDark = AppColors.of(context).isDark;

    // Step 1: Show the calendar + time picker
    final result = await showModalBottomSheet<(DateTime, bool)>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SchedulePickerSheet(isDark: isDark),
    );

    if (result == null || !mounted) return;
    final (scheduledAt, isAirport) = result;

    // Step 2: Open search screen for destination
    final searchResult = await Navigator.of(context).push<Map<String, dynamic>>(
      sharedAxisZRoute(
        const PickupDropoffSearchScreen(),
        opaque: false,
      ),
    );

    if (searchResult == null || !mounted) return;

    final pickupDetails = searchResult['pickup'] as PlaceDetails?;
    final dropoffDetails = searchResult['dropoff'] as PlaceDetails?;
    final pickupLabel = searchResult['pickupLabel'] as String? ?? '';
    final dropoffLabel = searchResult['dropoffLabel'] as String? ?? '';

    if (dropoffDetails == null) return;

    final effectiveDropoffLabel =
        dropoffLabel.isNotEmpty ? dropoffLabel : dropoffDetails.address;

    // Step 3: Open ride request screen with scheduledAt + search results
    await Navigator.of(context).push(
      slideUpFadeRoute(
        RideRequestScreen(
          scheduledAt: scheduledAt,
          isAirportTrip: isAirport,
          initialPickupDetails: pickupDetails,
          initialDropoffDetails: dropoffDetails,
          initialPickupLabel: pickupLabel,
          initialDropoffLabel: effectiveDropoffLabel,
          initialDropoffAddress: effectiveDropoffLabel,
        ),
      ),
    );

    // Refresh list after booking
    if (mounted) _loadTrips();
  }

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return Scaffold(
      backgroundColor: c.bg,
      floatingActionButton: _trips.isNotEmpty
          ? FloatingActionButton(
              onPressed: _startScheduleFlow,
              backgroundColor: _gold,
              child: const Icon(Icons.add_rounded, color: Colors.black87, size: 28),
            )
          : null,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // â”€â”€ Premium App Bar â”€â”€
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
              title: Text(
                S.of(context).scheduledRides,
                style: const TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.3,
                ),
              ),
              background: Container(color: c.bg),
            ),
          ),

          // â”€â”€ Content â”€â”€
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
                      onCancelComplete: _loadTrips,
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
            onTap: _startScheduleFlow,
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

// â”€â”€â”€ Trip Card Widget â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

class _TripCard extends StatefulWidget {
  final Map<String, dynamic> trip;
  final int index;
  final Future<bool> Function() onCancel;
  final VoidCallback onCancelComplete;

  const _TripCard({
    required this.trip,
    required this.index,
    required this.onCancel,
    required this.onCancelComplete,
  });

  @override
  State<_TripCard> createState() => _TripCardState();
}

class _TripCardState extends State<_TripCard> with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);

  // -- Cancel state --
  bool _cancelling = false;
  late final AnimationController _removeCtrl;
  late final Animation<double> _removeFade;
  late final Animation<double> _removeSize;

  @override
  void initState() {
    super.initState();
    _removeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _removeFade = Tween<double>(begin: 1.0, end: 0.0)
        .animate(CurvedAnimation(parent: _removeCtrl, curve: Curves.easeIn));
    _removeSize = Tween<double>(begin: 1.0, end: 0.0)
        .animate(CurvedAnimation(parent: _removeCtrl, curve: Curves.easeInCubic));
  }

  Future<void> _handleCancel() async {
    setState(() => _cancelling = true);
    final ok = await widget.onCancel();
    if (!mounted) return;
    if (ok) {
      AppToast.success(context, S.of(context).rideCancelled);
      await _removeCtrl.forward();
      if (mounted) widget.onCancelComplete();
    } else {
      setState(() => _cancelling = false);
      AppToast.error(context, S.of(context).failedToCancel(''));
    }
  }

  // -- Expand state --
  bool _expanded = false;
  bool _mapEverExpanded = false; // once true, keep MapWidget in tree

  // â”€â”€ Mini map â”€â”€
  mapbox.MapboxMap? _mapCtrl;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polyAnnotMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  final List<mapbox.PointAnnotation> _markerAnnots = [];
  AnimationController? _routeAnimCtrl;
  bool _routeLoaded = false;
  bool _routeLoading = false;
  String _tripDuration = '';

  double? get _pickupLat => (widget.trip['pickup_lat'] as num?)?.toDouble();
  double? get _pickupLng => (widget.trip['pickup_lng'] as num?)?.toDouble();
  double? get _dropoffLat => (widget.trip['dropoff_lat'] as num?)?.toDouble();
  double? get _dropoffLng => (widget.trip['dropoff_lng'] as num?)?.toDouble();
  bool get _hasCoords =>
      _pickupLat != null && _pickupLng != null && _dropoffLat != null && _dropoffLng != null;

  @override
  void dispose() {
    _removeCtrl.dispose();
    _routeAnimCtrl?.dispose();
    super.dispose();
  }

  void _toggle() {
    setState(() {
      _expanded = !_expanded;
      if (_expanded) _mapEverExpanded = true;
    });
  }

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
    } catch (_) {}
    _polyAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager();
    if (_hasCoords && mounted) _loadRouteAndAnimate();
  }

  Future<void> _loadRouteAndAnimate() async {
    if (_routeLoading || _routeLoaded || !_hasCoords) return;
    if (!mounted) setState(() => _routeLoading = true);
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
      // Fit camera
      await _fitCamera([pickup, dropoff]);
      // Place pins
      await _placePins(pickup, dropoff);
      // Animate golden route line
      await _animateRoute(route.points);
    } catch (_) {
    } finally {
      if (mounted) setState(() => _routeLoading = false);
    }
  }

  Future<void> _fitCamera(List<LatLng> pts) async {
    if (_mapCtrl == null || pts.length < 2) return;
    final lats = pts.map((p) => p.latitude).toList()..sort();
    final lngs = pts.map((p) => p.longitude).toList()..sort();
    try {
      final cam = await _mapCtrl!.cameraForCoordinatesPadding(
        [
          mapbox.Point(coordinates: mapbox.Position(lngs.first, lats.first)),
          mapbox.Point(coordinates: mapbox.Position(lngs.last, lats.last)),
        ],
        mapbox.CameraOptions(),
        mapbox.MbxEdgeInsets(top: 40, left: 30, bottom: 50, right: 30),
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
    final pickupBytes =
        await renderCircularPinBytes(icon: CircularPinIcon.dot, isPickup: true, radius: 28);
    final dropBytes =
        await renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 28);
    if (!mounted) return;
    try {
      final a = await _pointAnnotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(pickup.longitude, pickup.latitude)),
        image: pickupBytes,
        iconSize: 0.9,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
      _markerAnnots.add(a);
    } catch (_) {}
    try {
      final a = await _pointAnnotMgr!.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(dropoff.longitude, dropoff.latitude)),
        image: dropBytes,
        iconSize: 0.9,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
      _markerAnnots.add(a);
    } catch (_) {}
  }

  Future<void> _animateRoute(List<LatLng> points) async {
    if (_polyAnnotMgr == null || points.length < 2) return;
    _routeAnimCtrl?.dispose();
    _routeAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    final completer = Completer<void>();
    int lastCount = 0;
    _routeAnimCtrl!.addListener(() async {
      if (!mounted) {
        _routeAnimCtrl?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final eased = Curves.easeInOutSine.transform(_routeAnimCtrl!.value);
      final count = (eased * points.length).round().clamp(2, points.length);
      if (count != lastCount) {
        lastCount = count;
        final coords = points
            .sublist(0, count)
            .map((p) => mapbox.Position(p.longitude, p.latitude))
            .toList();
        final geo = mapbox.LineString(coordinates: coords);
        if (_routeAnnot == null) {
          try {
            _routeAnnot = await _polyAnnotMgr!.create(
              mapbox.PolylineAnnotationOptions(
                geometry: geo,
                lineColor: const Color(0xFFFFD700).toARGB32(),
                lineWidth: 4.5,
                lineJoin: mapbox.LineJoin.ROUND,
              ),
            );
          } catch (_) {}
        } else {
          _routeAnnot!.geometry = geo;
          try { await _polyAnnotMgr!.update(_routeAnnot!); } catch (_) {}
        }
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

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final dateFmt = DateFormat('EEE, MMM d');
    final timeFmt = DateFormat('h:mm a');
    final isAirport = widget.trip['is_airport'] == true;
    final status = widget.trip['status'] as String? ?? 'scheduled';
    final pickup = widget.trip['pickup_address'] as String? ?? '';
    final dropoff = widget.trip['dropoff_address'] as String? ?? '';
    final fare = (widget.trip['fare'] as num?)?.toDouble();
    final vehicleType = widget.trip['vehicle_type'] as String? ?? 'Comfort';
    final terminal = widget.trip['terminal'] as String?;
    final airportCode = widget.trip['airport_code'] as String?;
    final pickupZone = widget.trip['pickup_zone'] as String?;
    final notes = widget.trip['notes'] as String?;

    DateTime? scheduledAt;
    if (widget.trip['scheduled_at'] != null) {
      try {
        scheduledAt = DateTime.parse(widget.trip['scheduled_at'] as String);
      } catch (_) {}
    }

    final isPast = scheduledAt != null && scheduledAt.isBefore(DateTime.now());
    final minutesUntil = scheduledAt != null
        ? scheduledAt.difference(DateTime.now()).inMinutes
        : 0;
    final canCancel = status == 'scheduled' && !isPast && minutesUntil > 60;
    final showContactSupport =
        status == 'scheduled' && !isPast && minutesUntil <= 60 && minutesUntil > 0;

    return SizeTransition(
      sizeFactor: _removeSize,
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: _removeFade,
        child: GestureDetector(
      onTap: _hasCoords ? _toggle : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1D24),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: _expanded
                ? _gold.withValues(alpha: 0.35)
                : isAirport
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
            // â”€â”€ Header with date and badges â”€â”€
            Container(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              decoration: BoxDecoration(
                color: isAirport
                    ? const Color(0xFF4285F4).withValues(alpha: 0.06)
                    : _gold.withValues(alpha: 0.04),
                borderRadius: BorderRadius.vertical(
                  top: const Radius.circular(20),
                  bottom: _expanded ? Radius.zero : Radius.zero,
                ),
              ),
              child: Row(
                children: [
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
                  if (isAirport)
                    _badge(
                      icon: Icons.flight_rounded,
                      label: airportCode ?? 'Airport',
                      color: const Color(0xFF4285F4),
                    ),
                  const SizedBox(width: 6),
                  _statusBadge(status, isPast),
                  if (_hasCoords) ...[
                    const SizedBox(width: 6),
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

            // â”€â”€ Route info â”€â”€
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
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
                          color: isAirport
                              ? const Color(0xFF4285F4)
                              : Colors.white,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: (isAirport
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

            // â”€â”€ Info chips â”€â”€
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

            // â”€â”€ Notes â”€â”€
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

            // -- Cancel / Contact support --
            if (_cancelling)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(
                        color: Color(0xFFFF5252),
                        strokeWidth: 2,
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Text(
                      'Cancelling ride...',
                      style: TextStyle(
                        color: Color(0xFFFF5252),
                        fontWeight: FontWeight.w600,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              )
            else if (canCancel)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: GestureDetector(
                    onTap: _handleCancel,
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
            else if (showContactSupport)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: SizedBox(
                  width: double.infinity,
                  child: GestureDetector(
                    onTap: () {
                      Navigator.of(context).push(
                        slideFromRightRoute(const HelpScreen()),
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                      child: Center(
                        child: Text(
                          S.of(context).contactSupport,
                          style: const TextStyle(
                            color: Colors.white70,
                            fontWeight: FontWeight.w600,
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

            // â”€â”€ Expandable mini map â”€â”€
            if (_hasCoords)
              AnimatedSize(
                duration: const Duration(milliseconds: 350),
                curve: Curves.easeOutCubic,
                child: _mapEverExpanded
                    ? SizedBox(
                        height: _expanded ? 200.0 : 0.0,
                        child: _buildMiniMap(),
                      )
                    : const SizedBox.shrink(),
              ),
          ],
        ),
      ),
    ),
    ),
    );
  }

  Widget _buildMiniMap() {
    return ClipRRect(
      borderRadius: const BorderRadius.vertical(bottom: Radius.circular(20)),
      child: Stack(
        children: [
          mapbox.MapWidget(
            styleUri: MapboxConfig.styleDark,
            cameraOptions: mapbox.CameraOptions(
              center: mapbox.Point(
                coordinates: mapbox.Position(_pickupLng!, _pickupLat!),
              ),
              zoom: 13.0,
            ),
            onMapCreated: _onMapCreated,
            onStyleLoadedListener: (_) async {
              if (_mapCtrl != null) await MapTheme.applyNavyGold(_mapCtrl!);
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
    } else if (status == 'completed') {
      color = Colors.white54;
      label = 'Completed';
    } else if (isPast) {
      color = Colors.white38;
      label = 'Expired';
    } else if (status == 'driver_en_route' || status == 'arrived') {
      color = const Color(0xFF2ECC71);
      label = 'âœ“ Driver Assigned';
    } else if (status == 'in_trip') {
      color = const Color(0xFFE8C547);
      label = 'ðŸš— In Progress';
    } else if (status == 'scheduled' || status == 'requested') {
      color = Colors.orange;
      label = 'â³ Pending Driver';
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
