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
import '../widgets/tier_badge.dart';
import '../utils/mapbox_safe.dart';
import '../widgets/neu_style.dart';
import '../services/map_controller_cache.dart';
import 'airport_terminal_sheet.dart';
import 'ride_request_screen.dart';
import 'schedule_ride_flow.dart';

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

  late final AnimationController _fadeCtrl;
  late final Animation<double> _fadeAnim;

  List<Map<String, dynamic>> _trips = [];

  /// Drops the ones whose time came and went without anyone taking them.
  ///
  /// Completed and cancelled rides never arrive here — the endpoint only
  /// returns scheduled and in-flight statuses, so those two already leave this
  /// page on their own and turn up under Your Trips.
  ///
  /// What was left behind is a third case: a booking that stayed `scheduled`
  /// past its own time. It sat here wearing an "Expired" badge for ever, which
  /// is not a scheduled ride — it is a thing that did not happen, and a list of
  /// what is coming is the wrong place to keep it.
  ///
  /// Both of the statuses that mean "booked but never started" count, not just
  /// `scheduled`. A driver accepting a booking moves it to
  /// `scheduled_accepted`, and if it then never happened it is every bit as
  /// expired — the first pass only caught the first status and left those
  /// behind, still wearing the badge and still impossible to remove, because
  /// the cancel button requires the ride to be in the future.
  ///
  /// `scheduled_active` and everything after it stay whatever the clock says.
  /// A ride being driven right now has a scheduled_at in the past too, and it
  /// must not vanish from the screen the rider is watching it on.
  List<Map<String, dynamic>> _upcomingOnly(List<Map<String, dynamic>> trips) {
    const neverStarted = {'scheduled', 'scheduled_accepted'};
    final now = DateTime.now();
    return trips.where((t) {
      final status = (t['status'] as String?) ?? 'scheduled';
      if (!neverStarted.contains(status)) return true;
      final raw = t['scheduled_at'] as String?;
      if (raw == null) return true;
      final at = DateTime.tryParse(raw);
      if (at == null) return true;
      return !at.toLocal().isBefore(now);
    }).toList(growable: false);
  }
  bool _loading = true;
  String? _error;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _loadTrips();
    // Refresh every 30s to pick up driver assignment status changes
    _refreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _loadTrips();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
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
        if (mounted) {
          setState(() {
            _error = 'Not logged in';
            _loading = false;
          });
        }
        return;
      }
      final trips = await ApiService.getScheduledTrips(userId);
      if (!mounted) return;
      setState(() {
        _trips = _upcomingOnly(trips);
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
    // Step 1: full-screen date + time flow (replaces the old bottom sheet)
    final result = await showScheduleRideFlow(context);

    if (result == null || !mounted) return;
    final (scheduledAt, isAirport, searchResult) = result;

    // ── Airport branch ────────────────────────────────────────────
    // When the user toggled "Airport trip" in the schedule picker, we
    // must run the same flow as the home screen's Airport card: open
    // AirportTerminalSheet to capture airport / terminal / airline /
    // flight, then push ride_request with both scheduledAt AND the
    // airport selection. Without this branch the toggle was a no-op
    // because we'd skip straight to the generic pickup/dropoff search.
    if (isAirport) {
      final airportResult = await showModalBottomSheet<AirportSelection>(
        context: context,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        useSafeArea: true,
        builder: (_) =>
            AirportTerminalSheet(isDark: AppColors.of(context).isDark),
      );
      if (airportResult == null || !mounted) return;

      await Navigator.of(context).push(
        slideUpFadeRoute(
          RideRequestScreen(
            scheduledAt: scheduledAt,
            isAirportTrip: true,
            airportSelection: airportResult,
          ),
        ),
      );

      if (mounted) _loadTrips();
      return;
    }

    // ── Schedule (non-airport) branch ─────────────────────────────
    // The flow already pushed the pickup/dropoff search ON TOP of the
    // time picker (back goes to Select Time, not here). The confirmed
    // addresses come back inside the flow record.
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
          isAirportTrip: false,
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
      backgroundColor: neuBase,
      floatingActionButton: _trips.isNotEmpty
          ? FloatingActionButton(
              onPressed: _startScheduleFlow,
              backgroundColor: _gold,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(18),
              ),
              child: const Icon(Icons.add_rounded, color: Colors.black87, size: 28),
            )
          : null,
      body: CustomScrollView(
        physics: const BouncingScrollPhysics(),
        slivers: [
          // -- Header: back button + screen title --
          SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(
                24,
                MediaQuery.of(context).padding.top + 8,
                24,
                0,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  GestureDetector(
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
                  const SizedBox(height: 24),
                  Text(
                    S.of(context).scheduledRides,
                    style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.5,
                      color: c.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 20),
                ],
              ),
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
                      color: c.textTertiary,
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
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
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
            decoration: neuBox(radius: 24, pressed: true),
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
              height: 54,
              padding: const EdgeInsets.symmetric(horizontal: 28),
              decoration: BoxDecoration(
                color: _gold,
                borderRadius: BorderRadius.circular(16),
              ),
              child: Center(
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
          ),
        ],
      ),
    );
  }

  Widget _retryButton() {
    return GestureDetector(
      onTap: _loadTrips,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
        decoration: neuBox(radius: 14),
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

  // -- Resolved pickup address (reverse geocoded if "Current location") --
  String? _resolvedPickup;

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
    _resolvePickupAddress();
  }

  /// If pickup_address is generic ("Current location", empty), reverse-geocode
  /// from the stored lat/lng to get the actual street address.
  void _resolvePickupAddress() {
    final raw = widget.trip['pickup_address'] as String? ?? '';
    final lower = raw.toLowerCase().trim();
    final isGeneric = lower.isEmpty ||
        lower == 'current location' ||
        lower == 'ubicación actual' ||
        lower == 'pickup location';
    if (!isGeneric) return; // already has a real address

    final lat = (widget.trip['pickup_lat'] as num?)?.toDouble();
    final lng = (widget.trip['pickup_lng'] as num?)?.toDouble();
    if (lat == null || lng == null) return;

    PlacesService(ApiKeys.webServices).reverseGeocode(lat: lat, lng: lng).then((address) {
      if (address != null && address.isNotEmpty && mounted) {
        setState(() => _resolvedPickup = address);
      }
    }).catchError((_) {});
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
    // Cache controller for reuse across rider screens
    MapControllerCache.instance.cache(ctrl);
    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
    ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
    _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
    try {
      await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-pitch-alignment', 'viewport');
      await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-rotation-alignment', 'viewport');
      await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-allow-overlap', true);
      await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-ignore-placement', true);
      await ctrl.style.setStyleLayerProperty(_pointAnnotMgr!.id, 'icon-anchor', 'bottom');
    } catch (_) {}
    _polyAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager();
    if (_hasCoords && mounted) _loadRouteAndAnimate();
  }

  Future<void> _loadRouteAndAnimate() async {
    if (_routeLoading || _routeLoaded || !_hasCoords) return;
    if (!mounted) return;
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
      // Use road-snapped route points directly from the API.
      // Do NOT override endpoints with raw user coordinates —
      // that creates off-road straight-line segments.
      final routePts = route.points;
      // Fit camera to full route (flat)
      await _fitCamera(routePts, pitch: 0);
      // Place pins
      await _placePins(pickup, dropoff);
      // Animate golden route line
      await _animateRoute(routePts);
      // Cinematic tilt to 55°
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
          mapbox.Point(coordinates: mapbox.Position(lngs.last, lats.last)),
        ],
        mapbox.CameraOptions(pitch: pitch),
        mapbox.MbxEdgeInsets(top: 60, left: 50, bottom: 60, right: 50),
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
        await renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 44);
    final dropBytes =
        await renderCircularPinBytes(icon: CircularPinIcon.home, isPickup: false, radius: 44);
    if (!mounted) return;
    final pickupPoint = safePoint(pickup.longitude, pickup.latitude);
    if (pickupPoint != null) {
      try {
        final a = await _pointAnnotMgr!.create(mapbox.PointAnnotationOptions(
          geometry: pickupPoint,
          image: pickupBytes,
          iconSize: 0.65,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
        _markerAnnots.add(a);
      } catch (_) {}
    }
    final dropoffPoint = safePoint(dropoff.longitude, dropoff.latitude);
    if (dropoffPoint != null) {
      try {
        final a = await _pointAnnotMgr!.create(mapbox.PointAnnotationOptions(
          geometry: dropoffPoint,
          image: dropBytes,
          iconSize: 0.65,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
        _markerAnnots.add(a);
      } catch (_) {}
    }
  }

  Future<void> _animateRoute(List<LatLng> points) async {
    if (_polyAnnotMgr == null || points.length < 2) return;

    // Pre-create annotation before animation to avoid async frame skipping
    if (_routeAnnot != null) { try { await _polyAnnotMgr!.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }
    final routeGeo = safeLineString(points.sublist(0, 2));
    if (routeGeo == null) return;
    try { _routeAnnot = await _polyAnnotMgr!.create(mapbox.PolylineAnnotationOptions(
      geometry: routeGeo,
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 4.5,
      lineJoin: mapbox.LineJoin.ROUND,
    )); } catch (_) {}
    if (!mounted || _routeAnnot == null) return;

    _routeAnimCtrl?.dispose();
    _routeAnimCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    final completer = Completer<void>();
    int lastCount = 2;
    bool updating = false;
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
        _polyAnnotMgr!.update(_routeAnnot!).then((_) => updating = false).catchError((_) => updating = false);
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
    final rawPickup = widget.trip['pickup_address'] as String? ?? '';
    final pickup = _resolvedPickup ?? rawPickup;
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
    final cancelableStatus = status == 'scheduled' || status == 'scheduled_accepted' || status == 'driver_assigned' || status == 'requested';
    final canCancel = cancelableStatus && !isPast && (scheduledAt == null || scheduledAt.difference(DateTime.now()).inMinutes > 60);
    // Note: scheduledAt null check is already handled above (isPast is false when null)
    final showContactSupport = cancelableStatus && !isPast && !canCancel;

    return SizeTransition(
      sizeFactor: _removeSize,
      axisAlignment: -1.0,
      child: FadeTransition(
        opacity: _removeFade,
        child: GestureDetector(
      onTap: _hasCoords && status != 'completed' && status != 'canceled' ? _toggle : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        decoration: neuBox(radius: 20).copyWith(
          border: Border.all(
            color: _expanded
                ? _gold.withValues(alpha: 0.35)
                : isAirport
                    ? const Color(0xFF4285F4).withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.06),
          ),
        ),
        child: Column(
          children: [
            // â”€â”€ Header with date and badges â”€â”€
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
              child: Row(
                children: [
                  if (scheduledAt != null) ...[
                    Container(
                      width: 40,
                      height: 40,
                      decoration: neuBox(radius: 14, pressed: true),
                      child: Icon(
                        isAirport
                            ? Icons.flight_takeoff_rounded
                            : Icons.schedule_rounded,
                        color: isAirport ? const Color(0xFF4285F4) : _gold,
                        size: 22,
                      ),
                    ),
                    const SizedBox(width: 14),
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
                  _statusBadge(context, status, isPast),
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


            // ── Route info (hidden when expanded) ──
            AnimatedCrossFade(
              firstChild: Padding(
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
              secondChild: const SizedBox(width: double.infinity, height: 0),
              crossFadeState: _expanded
                  ? CrossFadeState.showSecond
                  : CrossFadeState.showFirst,
              duration: const Duration(milliseconds: 300),
            ),
            // â”€â”€ Info chips â”€â”€
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
              child: Row(
                children: [
                  TierBadge(rideName: vehicleType),
                  if (fare != null && fare > 0) ...[
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: neuBox(radius: 12, pressed: true),
                      child: Text(
                        '\$ ${fare.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -0.3,
                        ),
                      ),
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


            // ── Expandable mini map — hidden for completed/cancelled trips ──
            if (_hasCoords && status != 'completed' && status != 'canceled')
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
            // ── "Ride Completed" banner for finished trips ──
            if (status == 'completed')
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: neuBox(radius: 14, pressed: true),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle_rounded,
                          color: c.textTertiary, size: 18),
                      const SizedBox(width: 8),
                      Text(
                        'Ride Completed',
                        style: TextStyle(
                          color: c.textTertiary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
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
                      decoration: neuBox(radius: 14),
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
                child: Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  decoration: neuBox(radius: 14, pressed: true),
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
              )
            else
              const SizedBox(height: 14),

          ],
        ),
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
            textureView: true,
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

  Widget _mapAddressLabel(String address, Color dotColor, bool isPickup) {
    if (address.isEmpty) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: BoxDecoration(
              color: dotColor,
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 7),
          Flexible(
            child: Text(
              address,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 11,
                fontWeight: FontWeight.w600,
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

  Widget _statusBadge(BuildContext context, String status, bool isPast) {
    final s = S.of(context);
    Color color;
    String label;
    IconData? icon;
    if (status == 'canceled') {
      color = const Color(0xFFFF5252);
      label = s.cancelledFilter;
    } else if (status == 'completed') {
      color = Colors.white54;
      label = s.completedFilter;
    } else if (isPast) {
      color = Colors.white38;
      label = s.expired;
    } else if (status == 'driver_en_route' || status == 'arrived') {
      color = const Color(0xFF2ECC71);
      label = s.rideConfirmed;
      icon = Icons.directions_car_rounded;
    } else if (status == 'in_trip') {
      color = const Color(0xFFE8C547);
      label = s.tripInProgress;
      icon = Icons.directions_car_rounded;
    } else if (status == 'scheduled_accepted') {
      color = const Color(0xFF22C55E); // green
      label = s.driverAssignedLabel;
      icon = Icons.directions_car_rounded;
    } else if (status == 'scheduled' || status == 'requested') {
      color = Colors.orange;
      label = s.pendingDriver;
      icon = Icons.directions_car_rounded;
    } else {
      color = const Color(0xFF4CAF50);
      label = s.upcoming;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 12, color: color),
            if (status == 'driver_en_route' || status == 'arrived')
              Padding(
                padding: const EdgeInsets.only(left: 1),
                child: Icon(Icons.check_rounded, size: 10, color: color),
              ),
            const SizedBox(width: 4),
          ],
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

  Widget _infoChip(IconData icon, String text, AppColors c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: neuBox(radius: 10, pressed: true),
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
