import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../../config/api_keys.dart';
import '../../config/map_theme.dart';
import '../../config/mapbox_config.dart';
import '../../l10n/app_localizations.dart';
import '../../map/map_surface_coordinator.dart';
import '../../map/web_map_view.dart';
import '../../models/lat_lng.dart';
import '../../services/directions_service.dart';
import '../../services/haptic_service.dart';
import '../../services/resilient_position_stream.dart';
import '../../services/socket_service.dart';
import '../../utils/driver_location_settings.dart';
import '../../utils/mapbox_safe.dart';
import '../../utils/route_splice.dart';
import '../../utils/smooth_motion.dart';
import '../../widgets/gold_location_dot.dart';
import '../../widgets/map/circular_pin_renderer.dart';
import '../../widgets/neu_style.dart';
import '../../widgets/verified_avatar.dart';

/// Who owns the navigation camera.
///
///  * [following]  — the per-frame chase writes the camera (the car stays
///    pinned at ~60% of the screen height).
///  * [freeLook]   — the driver dragged / pinched / rotated the map; the
///    chase never writes, and the Recenter control is up.
///  * [recentering] — a smooth flyTo is returning the camera to the chase
///    target; it flips to [following] when the flight completes, or to
///    [freeLook] if the driver grabs the map mid-flight.
enum _CamState { following, freeLook, recentering }

/// What the navigation layer is doing, derived — never set directly.
///
/// Precedence: internal arrival > GPS health > route-error > in-flight
/// reroute > still-initialising > approaching (>200 m gate) > plain leg.
/// The pickup and dropoff legs each carry their own arriving/arrived pair,
/// so a pickup arrival can never paint while the dropoff leg is active.
enum _NavPhase {
  initializing,
  toPickup,
  approachingPickup,
  arrivedPickup,
  toDropoff,
  approachingDropoff,
  arrivedDropoff,
  rerouting,
  gpsUnavailable,
  routeError,
}

/// Why a route request is on the wire. Initial/retry may show the error
/// card; a background fill only swaps geometry when it truly differs; a
/// reroute keeps the old line until the new one replaces it atomically.
enum _RouteFetchKind { initial, backgroundFill, reroute, retry }

/// Full-screen in-app turn-by-turn navigation, Google Maps-style in navy/gold:
/// maneuver bar on top, live mph box, a draggable rider sheet at the bottom,
/// and the driver's gold arrow chased by a 17.5/55° camera.
///
/// It mounts the app's ONE native Mapbox surface, claimed from
/// [MapSurfaceCoordinator] under an owner id unique per instance — the
/// accept screen's mini map has already let go before this widget exists.
///
/// Stage controls (Arrived → wait bar → slide to pick up → slide to finish)
/// are driven by [stage], computed by the parent from its own trip state, and
/// every action calls back into the parent's existing handlers — this view
/// never talks to the backend itself.
///
/// Production systems layered over the archived view:
///  * **Prefetched route** — the accept screen hands over the geometry its
///    mini map already drew ([prefetchedRoutePoints]); when it still serves
///    this leg's destination the line is on the map the instant the surface
///    is ready, and the network is only asked for what is missing.
///  * **Off-route rerouting** — >40 m from the polyline for 4 straight
///    seconds arms one reroute (15 s cooldown, `_rerouteSeq` staleness
///    token, one request in flight ever); the old line stays until the new
///    one replaces it in the same annotation update.
///  * **Camera state machine** ([_CamState]) and **navigation state
///    machine** ([_NavPhase]) — the banner, pills and recovery cards are
///    pure functions of the derived phase.
///  * **Internal arrival** — approaching under 200 m, arrived after
///    consecutive close-and-accurate fixes. Arrival only changes this
///    view's UI; the parent's sliders stay the trip-flow authority.
///  * **Failure handling** — a dead network keeps the drawn route (offline
///    pill + 5/15/30 s backoff) or shows a retry card when nothing is
///    drawn; a dead GPS shows a recovery card instead of a blank page.
class DriverNavView extends StatefulWidget {
  const DriverNavView({
    super.key,
    required this.tripId,
    required this.riderName,
    required this.riderPhotoUrl,
    required this.riderId,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.fare,
    required this.initialDriverPos,
    required this.toPickup,
    required this.stage,
    required this.passengerInstructions,
    required this.dropoffInstructions,
    required this.waitStartedAt,
    required this.onExit,
    required this.onArrived,
    required this.onSlidePickUp,
    required this.onSlideFinish,
    required this.onOpenChat,
    required this.onCall,
    required this.onSupport,
    this.prefetchedRoutePoints,
    this.prefetchedSteps = const [],
    this.onMapReady,
  });

  final int tripId;
  final String riderName;
  final String riderPhotoUrl;
  final int? riderId;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String pickupAddress;
  final String dropoffAddress;
  final double fare;
  final LatLng initialDriverPos;

  /// Pickup leg (going for the rider) vs dropoff leg (rider aboard). The leg
  /// flip also hides the rider figure — there is nobody left to walk to.
  final bool toPickup;

  /// The parent screen's `_actionStageKey()`: arrived / waiting_rider /
  /// start_ride / finish / *_locked.
  final String stage;

  final String passengerInstructions;
  final String dropoffInstructions;

  /// Backend wait-start timestamp parsed from the notes line, when present —
  /// the wait divider drains from this so a reopened screen stays in sync.
  final DateTime? waitStartedAt;

  final VoidCallback onExit;
  final VoidCallback onArrived;
  final VoidCallback onSlidePickUp;
  final VoidCallback onSlideFinish;
  final VoidCallback onOpenChat;
  final VoidCallback onCall;
  final VoidCallback onSupport;

  /// Geometry the parent's mini map already drew. When its last point lands
  /// within ~150 m of this leg's destination it is drawn at mount with no
  /// fetch; anything missing (steps → maneuvers/ETA) is filled by a
  /// background request that never wipes the already-drawn line.
  final List<LatLng>? prefetchedRoutePoints;

  /// Steps for [prefetchedRoutePoints], when the parent has them. With both
  /// present the view is complete without touching the network.
  final List<NavStep> prefetchedSteps;

  /// Fired when the native map has its first controller — the parent
  /// cross-fades its expansion snapshot out on this signal.
  final VoidCallback? onMapReady;

  @override
  State<DriverNavView> createState() => DriverNavViewState();
}

/// Public so the accept screen can hold a GlobalKey to it: the reverse morph
/// needs a one-shot snapshot of the nav map before the view unmounts.
class DriverNavViewState extends State<DriverNavView>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  static const _gold = Color(0xFFE8C547);
  static const _navyBar = Color(0xFF0A1128);

  // Unique per instance: this view can be re-mounted over a surface another
  // screen still holds, and a shared static id is what made the coordinator
  // skip the revoke (two native maps = iOS crash). Same pattern as
  // ride_request_screen's _mapSurfaceOwner.
  static int _nextMapSurfaceId = 0;
  late final String _mapSurfaceOwner = 'DriverTripNav-${++_nextMapSurfaceId}';
  bool _mapMounted = false;

  mapbox.MapboxMap? _map;
  mapbox.PolylineAnnotationManager? _polyMgr;
  mapbox.PointAnnotationManager? _pointMgr;
  // The driver arrow gets its OWN manager (user report 2026-09-17): the
  // arrow needs icon-rotation-alignment 'map' so it stays pointing up while
  // the chase camera rotates the map — but that layer property is set per
  // MANAGER, and sharing it laid the destination pin and the rider figure
  // down on their side every time the camera turned. _pointMgr keeps the
  // default viewport alignment, so pins stand upright at any bearing.
  mapbox.PointAnnotationManager? _carMgr;
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.PointAnnotation? _driverAnnot;
  mapbox.PointAnnotation? _destAnnot;
  bool _annotWriteBusy = false;
  // Last values actually sent to the native annotation — a parked car pays
  // zero channel writes (same discipline as the accept screen's mini car).
  double? _lastSentLat;
  double? _lastSentLng;
  double? _lastSentBearing;

  // ── Driver marker: the same GoldLocationDot + SmoothMotion as the online
  //    map. onTick (throttled) writes the annotation; onFrame chases. ──
  final GoldLocationDot _dot = GoldLocationDot(heading: true);

  // ── Rider live location (pickup leg only) ──
  final SmoothMotion _riderMotion = SmoothMotion();
  Ticker? _riderTicker;
  Duration _riderLastTick = Duration.zero;
  // The blue location puck (user spec 2026-09-17 — the same blue dot the
  // rider side draws), never an icon: halo circle + blue dot with a white
  // ring, native CircleAnnotations so they scale with the map zoom.
  mapbox.CircleAnnotationManager? _circleMgr;
  mapbox.CircleAnnotation? _riderHaloAnnot;
  mapbox.CircleAnnotation? _riderDotAnnot;
  static const _riderBlue = Color(0xFF3B82F6);
  DateTime? _riderFixAt;
  Timer? _riderStaleTimer;
  Offset? _riderLabelPos;
  int _riderStaleSecs = 0;

  // ── Camera state machine ──
  _CamState _camState = _CamState.following;
  bool _overview = false;
  int _mapPointers = 0;
  mapbox.CameraOptions? _pendingCamWrite;
  bool _camWriteBusy = false;

  // Dynamic chase zoom: 17.5 at city pace, 17.0 past 20 m/s, 18.0 with a
  // maneuver under 150 m — lerped at ≤0.5 zoom/sec, never a step.
  double _chaseZoom = 17.5;
  DateTime? _lastChaseFrameAt;
  static const _chaseZoomDefault = 17.5;
  static const _chaseZoomFast = 17.0;
  static const _chaseZoomManeuver = 18.0;
  static const _zoomLerpPerSec = 0.5;
  // Chase tilt: 25° (user spec 2026-09-17 — the flat, map-forward view of
  // the reference shot; 55 read as a horizon view and hid the streets).
  static const _chasePitch = 25.0;

  // ── Route + maneuvers ──
  List<LatLng> _routePts = [];
  double _routeLenM = 0;
  NavProgress? _navProgress;
  bool _routeFetching = false;
  String _streetLabel = '';
  String _thenLabel = '';
  String _maneuverDistLabel = '';
  String _maneuverType = 'depart';
  String _maneuverModifier = '';
  double _speedMps = 0;
  int _lastMphShown = -1;
  int _remainSecs = 0;
  double _remainMeters = 0;

  // ── Navigation state machine ──
  _NavPhase _navPhase = _NavPhase.initializing;

  // Off-route: >40 m from the line held for 4 s of fixes arms a reroute;
  // back within 25 m resets the clock. One request in flight, 15 s cooldown,
  // and a sequence token so a stale response can never replace a newer plan.
  DateTime? _offRouteSince;
  int _rerouteSeq = 0;
  DateTime? _lastRerouteAt;
  bool _rerouting = false;
  static const _offRouteM = 40.0;
  static const _offRouteResetM = 25.0;
  static const _offRouteHoldSecs = 4;
  static const _rerouteCooldownSecs = 15;
  static const _prefetchDestMaxM = 150.0;

  // Internal arrival: approaching under 200 m; arrived after 2 consecutive
  // fixes under 30 m with accuracy better than 25 m (3 fixes on distance
  // alone when the fix carries no accuracy). UI state only — the parent's
  // sliders stay the trip-flow authority.
  int _arriveHits = 0;
  bool _navArrived = false;
  // One auto-raise per arrival (see _recomputeNavPhase) — reset on leg flip.
  bool _endRouteRaised = false;
  bool _navApproaching = false;
  static const _arriveRadiusM = 30.0;
  static const _arriveAccuracyM = 25.0;
  static const _approachRadiusM = 200.0;

  // GPS health: no valid fix for >6 s starts a cause check — the phase only
  // flips to gpsUnavailable when location is genuinely off for this app
  // (service disabled or permission revoked), never on a mere signal stall.
  DateTime? _lastGpsFixAt;
  bool _gpsDown = false;
  bool _gpsDiagnosing = false;
  Timer? _gpsWatchdog;
  static const _gpsStaleSecs = 6;

  // Network health: a failed fetch with a line on the map keeps everything
  // and retries quietly (5/15/30 s, capped); with nothing drawn it is a
  // routeError card with a retry button.
  bool _routeError = false;
  bool _offlineKeepRoute = false;
  Timer? _offlineRetryTimer;
  int _offlineRetryAttempt = 0;
  static const _offlineBackoff = <Duration>[
    Duration(seconds: 5),
    Duration(seconds: 15),
    Duration(seconds: 30),
  ];

  // ── Stage controls ──
  // NONE (user spec 2026-09-17): the nav view is navigation-only — no
  // Arrived button, no slide to pick up / finish in here. When the driver
  // arrives, the sheet zone shows only End Route, which hands them back to
  // the trip page whose own buttons/sliders are the flow's authority.
  String _lastStageSynced = '';
  Timer? _waitTicker;
  DateTime? _waitStartLocal; // fallback clock when notes carry no timestamp
  double _waitRemainFrac = 1.0;
  String _waitClock = '5:00';
  static const _waitTotalSecs = 300;

  /// The only bottom action the nav view ever shows: closes navigation
  /// (reverse morph back to the sheet), never a trip-state transition.
  static const _endRouteHeight = 44.0;

  ResilientPositionStream? _gps;
  StreamSubscription? _riderLocSub;
  WebMapController? _webMap;

  final DraggableScrollableController _sheetCtrl =
      DraggableScrollableController();

  LatLng get _dest =>
      widget.toPickup ? widget.pickupLatLng : widget.dropoffLatLng;

  /// End Route appears once the driver has arrived — by the nav view's own
  /// arrival latch or by any post-arrival stage the parent reports. Never
  /// mid-drive (the old early "Desliza para terminar" at 58 m).
  bool get _endRouteVisible =>
      _phaseArrived ||
      widget.stage == 'arrived' ||
      widget.stage == 'waiting_rider' ||
      widget.stage == 'start_ride' ||
      widget.stage == 'finish';

  bool get _phaseArrived =>
      _navPhase == _NavPhase.arrivedPickup ||
      _navPhase == _NavPhase.arrivedDropoff;

  /// The live controller, exposed to the parent for the one-shot exit-morph
  /// snapshot (see _collapseNavMode on the accept screen).
  mapbox.MapboxMap? get mapForSnapshot => _map;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _acquireMapSurface();
    // Prefetched geometry goes into state BEFORE the first frame, so
    // _onMapCreated draws it the instant the surface is ready.
    _seedPrefetchedRoute();
    _navPhase = _derivePhase();
    // Drives the marker and hands the per-frame callbacks: onTick writes the
    // annotation (throttled by GoldLocationDot), onFrame chases the camera.
    _dot.build(this, _onDotTick, onFrame: _onDotFrame);
    _riderTicker = createTicker(_onRiderTick)..start();
    _listenRiderLocation();
    // Localizations and the first stage sync need a built context.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _startGps();
      _syncStageControls(widget.stage);
      _loadRoute();
    });
  }

  @override
  void didUpdateWidget(DriverNavView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.stage != widget.stage) {
      _syncStageControls(widget.stage);
    }
    if (oldWidget.toPickup != widget.toPickup) {
      // Leg flip (pickup → dropoff): re-aim the route and drop the rider
      // dot — after the slide to pick up there is nobody left to show.
      _riderFixAt = null;
      if (_riderLabelPos != null) setState(() => _riderLabelPos = null);
      final halo = _riderHaloAnnot;
      final dot = _riderDotAnnot;
      _riderHaloAnnot = null;
      _riderDotAnnot = null;
      final mgr = _circleMgr;
      if (mgr != null) {
        if (halo != null) mgr.delete(halo).catchError((Object _) {});
        if (dot != null) mgr.delete(dot).catchError((Object _) {});
      }
      _onDestinationChanged();
    } else if (!widget.toPickup &&
        oldWidget.dropoffLatLng != widget.dropoffLatLng) {
      // The rider moved the destination mid-trip — the leg is the same,
      // the target is not.
      _onDestinationChanged();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _sheetCtrl.dispose();
    unawaited(_gps?.stop());
    _gpsWatchdog?.cancel();
    _offlineRetryTimer?.cancel();
    _riderLocSub?.cancel();
    _riderStaleTimer?.cancel();
    _waitTicker?.cancel();
    _riderTicker?.dispose();
    _dot.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    _gps?.onAppResumed();
    _dot.ensureRunning();
    // Grace: a suspended stream needs a beat to come back before the
    // watchdog is allowed to call it dead again.
    _lastGpsFixAt = DateTime.now();
    if (_gpsDown) {
      _gpsDown = false;
      _recomputeNavPhase();
    }
    // The surface may have been revoked (or Android destroyed the
    // PlatformView) while away — claim it back.
    if (!_mapMounted) _acquireMapSurface();
  }

  // ─────────────────────────────────────────────
  //  Navigation state machine
  // ─────────────────────────────────────────────

  /// The one place the phase comes from. Everything that can change an
  /// input calls this; the phase itself is never assigned ad hoc.
  _NavPhase _derivePhase() {
    if (_navArrived) {
      return widget.toPickup
          ? _NavPhase.arrivedPickup
          : _NavPhase.arrivedDropoff;
    }
    if (_gpsDown) return _NavPhase.gpsUnavailable;
    if (_routeError) return _NavPhase.routeError;
    if (_rerouting) return _NavPhase.rerouting;
    if (_routePts.length < 2) return _NavPhase.initializing;
    if (_navApproaching) {
      return widget.toPickup
          ? _NavPhase.approachingPickup
          : _NavPhase.approachingDropoff;
    }
    return widget.toPickup ? _NavPhase.toPickup : _NavPhase.toDropoff;
  }

  void _recomputeNavPhase() {
    final next = _derivePhase();
    if (next == _navPhase) return;
    setState(() => _navPhase = next);
    // Arrival raises the sheet ONCE so the in-sheet End Route is actually
    // visible (user spec 2026-09-17) — a driver who dragged it back down
    // keeps it there; a leg flip re-arms the raise.
    final arrivedNow =
        next == _NavPhase.arrivedPickup || next == _NavPhase.arrivedDropoff;
    if (arrivedNow && !_endRouteRaised) {
      _endRouteRaised = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted || !_sheetCtrl.isAttached) return;
        _sheetCtrl.animateTo(0.42,
            duration: const Duration(milliseconds: 450),
            curve: Curves.easeOutCubic);
      });
    }
  }

  // ─────────────────────────────────────────────
  //  Map surface
  // ─────────────────────────────────────────────

  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_mapMounted) return;
        // Every annotation handle belongs to the PlatformView being
        // destroyed — drop them so nothing writes to a dead channel.
        _map = null;
        _polyMgr = null;
        _pointMgr = null;
        _carMgr = null;
        _circleMgr = null;
        _routeAnnot = null;
        _driverAnnot = null;
        _destAnnot = null;
        _riderHaloAnnot = null;
        _riderDotAnnot = null;
        _lastSentLat = null;
        _lastSentLng = null;
        _lastSentBearing = null;
        setState(() => _mapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    setState(() => _mapMounted = true);
  }

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _map = ctrl;
    // Each call stands alone so one refusal does not skip the rest.
    for (final step in <Future<void> Function()>[
      () => ctrl.scaleBar
          .updateSettings(mapbox.ScaleBarSettings(enabled: false)),
      () =>
          ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false)),
      () => ctrl.attribution
          .updateSettings(mapbox.AttributionSettings(enabled: false)),
      () => ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false)),
    ]) {
      try {
        await step();
      } catch (_) {}
    }
    _polyMgr = await ctrl.annotations.createPolylineAnnotationManager();
    _pointMgr = await ctrl.annotations.createPointAnnotationManager();
    _carMgr = await ctrl.annotations.createPointAnnotationManager();
    _circleMgr = await ctrl.annotations.createCircleAnnotationManager();
    try {
      final lid = _pointMgr!.id;
      await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
    } catch (_) {}
    try {
      final lid = _carMgr!.id;
      await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
    } catch (_) {}
    // A recreated surface (app backgrounded on Android) loses everything —
    // redraw the route and destination pin from the State that survived.
    await _drawRoute();
    await _drawDestPin();
    // The driver arrow is created EAGERLY (user spec 2026-09-16): the dot's
    // ticker only fires while the car moves, so a parked driver used to get
    // no annotation at all — the arrow simply never appeared.
    unawaited(_updateDriverAnnotation());
    // The opening camera is the chase pose (tilted, down-route), never a
    // top-down overview (user spec 2026-09-16): the per-frame chase sleeps
    // while the car is parked, so the pose is written explicitly here. The
    // full-route fit stays for the overview toggle.
    if (_overview) {
      await _fitRouteOnce();
    } else {
      _snapToChasePose();
    }
    widget.onMapReady?.call();
  }

  // ─────────────────────────────────────────────
  //  GPS → marker + maneuvers + arrival + off-route
  // ─────────────────────────────────────────────

  void _startGps() {
    // Foreground-only: the parent screen already runs the background stream
    // that publishes the driver's position; this one only feeds the marker
    // and the camera of a screen the driver is looking at. A second
    // foreground-service notification would read as a second tracker.
    final s = S.of(context);
    _gps = ResilientPositionStream(
      label: 'DriverNavGps',
      settings: driverLocationSettings(
        background: false,
        // 0 m: the 6 s GPS-down watchdog is only meaningful when a healthy
        // stream keeps emitting while the car stands still.
        distanceFilter: 0,
        notificationTitle: s.driverLocationNotifTitle,
        notificationText: s.driverLocationNotifOnTrip,
      ),
      onPosition: _onGpsFix,
    )..start();
    // Seed the marker where the accept screen last had the driver, so the
    // arrow never slides in from (0,0) while the first fix is in flight.
    // A restart keeps the position the dot already has.
    if (_dot.lat == null) {
      _dot.setTarget(
        widget.initialDriverPos.latitude,
        widget.initialDriverPos.longitude,
        timestampMs: DateTime.now().millisecondsSinceEpoch.toDouble(),
      );
    }
    // Aim down-route from the very first frame: the GPS heading at 0 mph is
    // noise, so the opening arrow (and chase camera) takes the route
    // tangent instead (user spec 2026-09-16).
    final h = _routeHeadingFor(widget.initialDriverPos);
    if (h != null) _dot.setBearing(h);
    _lastGpsFixAt = DateTime.now(); // warm-up grace for the first fix
    _armGpsWatchdog();
  }

  /// The GPS-down detector. ResilientPositionStream resubscribes on its own,
  /// so every failure mode (stream error, permission revoked, location
  /// service off, a manager the OS tore down) presents here as the same
  /// thing: silence. 6 s of it flips the phase — and the first fix flips
  /// it back.
  void _armGpsWatchdog() {
    _gpsWatchdog?.cancel();
    _gpsWatchdog = Timer.periodic(const Duration(seconds: 2), (_) {
      if (!mounted) return;
      final last = _lastGpsFixAt;
      final stale = last == null ||
          DateTime.now().difference(last).inSeconds > _gpsStaleSecs;
      if (!stale) {
        if (_gpsDown) {
          _gpsDown = false;
          _recomputeNavPhase();
        }
        return;
      }
      // A stall is not a cause (user spec 2026-09-17): tunnels, urban
      // canyons and iOS pausing updates on a parked car all look like
      // silence with every permission ON. The recovery card is ONLY for
      // location actually disabled — service off or permission revoked —
      // so the silence gets diagnosed before it is allowed to flip the
      // phase. The smoother holds the car meanwhile.
      _diagnoseGpsStall();
    });
  }

  /// Async cause-check behind the watchdog: sets [_gpsDown] only when
  /// location is genuinely unavailable to the app. One in flight ever.
  Future<void> _diagnoseGpsStall() async {
    if (_gpsDiagnosing) return;
    _gpsDiagnosing = true;
    try {
      final serviceOn = await Geolocator.isLocationServiceEnabled();
      final perm = await Geolocator.checkPermission();
      final denied = perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever;
      final down = !serviceOn || denied;
      if (!mounted) return;
      if (down != _gpsDown) {
        _gpsDown = down;
        _recomputeNavPhase();
      }
    } catch (_) {
      // A failed diagnosis proves nothing either way — keep the last state.
    } finally {
      _gpsDiagnosing = false;
    }
  }

  void _onGpsFix(Position pos) {
    if (!mounted) return;
    _lastGpsFixAt = DateTime.now();
    if (_gpsDown) {
      _gpsDown = false;
      _recomputeNavPhase();
    }
    _dot.setTarget(
      pos.latitude,
      pos.longitude,
      bearing: pos.heading >= 0 ? pos.heading : null,
      accuracyM: pos.accuracy,
      timestampMs: pos.timestamp.millisecondsSinceEpoch.toDouble(),
      // The fix's own speed reading parks the arrow against GPS wander —
      // a parked driver's position jumps but his speed keeps reading ~0.
      speedMps: pos.speed.isFinite && pos.speed >= 0 ? pos.speed : null,
    );
    // Speed readout (user spec 2026-09-17 — precise, never frozen at a
    // stale figure): the platform speed when the fix carries one; iOS
    // reports -1 when it has none, so fall back to the smoother's own
    // measured glide speed instead of lying with a 0. Under ~1 mph is a
    // parked car, not a speed — the deadband kills the 0↔1 flicker.
    final rawSpeed = pos.speed.isFinite && pos.speed >= 0
        ? pos.speed
        : _dot.speedMps;
    _speedMps = rawSpeed < 0.45 ? 0.0 : rawSpeed;
    final mph = (_speedMps * 2.23694).round();
    if (mph != _lastMphShown) {
      _lastMphShown = mph;
      setState(() {}); // the mph box is the only reader
    }
    final fixLL = LatLng(pos.latitude, pos.longitude);
    _updateManeuvers(fixLL);
    // Parked or crawling, the GPS heading is noise (or stale from the last
    // drive): the arrow — and with it the chase camera — aims down-route,
    // where the driver has to GO (user spec 2026-09-16).
    if (_speedMps < 1.0) {
      final h = _routeHeadingFor(fixLL);
      // Deadband (user spec 2026-09-17): a parked car's fix wanders metres
      // between readings and the tangent computed off it swings with the
      // projection — re-aiming on every fix made the arrow twitch through
      // big arcs at stoplights. Only a meaningful change of where the route
      // points retargets the arrow; the SmoothMotion lerp turns it there.
      if (h != null) {
        var diff = (h - _dot.bearing).abs() % 360;
        if (diff > 180) diff = 360 - diff;
        if (diff > 20) _dot.setBearing(h);
      }
    }
    _checkArrival(pos);
    _checkOffRoute(fixLL);
  }

  /// Where the arrow should point when the GPS has nothing to say: along
  /// the route, from the driver's projection toward a look-ahead point
  /// ~30 m on — the same tangent trick the rider's tracking map steers its
  /// car by.
  double? _routeHeadingFor(LatLng pos) {
    final pts = _routePts;
    if (pts.length < 2) return null;
    final seg = RouteSplice.closestSegmentIndex(pts, pos);
    var from = RouteSplice.projectOnSegment(pos, pts[seg], pts[seg + 1]);
    var remaining = 30.0;
    for (var i = seg + 1; i < pts.length; i++) {
      final d = RouteSplice.haversineM(from, pts[i]);
      if (d >= remaining && d > 1e-3) {
        final b = Geolocator.bearingBetween(
            from.latitude, from.longitude, pts[i].latitude, pts[i].longitude);
        return (b + 360) % 360;
      }
      remaining -= d;
      from = pts[i];
    }
    // Closer to the destination than the look-ahead: aim at the pin — unless
    // we are already on top of it, where a bearing means nothing.
    if (RouteSplice.haversineM(pos, pts.last) < 1.0) return null;
    final b = Geolocator.bearingBetween(
        pos.latitude, pos.longitude, pts.last.latitude, pts.last.longitude);
    return (b + 360) % 360;
  }

  /// Approaching under 200 m; arrived after consecutive close fixes — with
  /// real accuracy (2 fixes, accuracy < 25 m) or without it (3 fixes on
  /// distance alone). Fires NO backend transition: it only moves the nav UI
  /// to its arrived banner; the parent's sliders stay the authority.
  void _checkArrival(Position pos) {
    if (_navArrived) return;
    final d = RouteSplice.haversineM(
        LatLng(pos.latitude, pos.longitude), _dest);
    final approaching = d < _approachRadiusM;
    if (approaching != _navApproaching) {
      _navApproaching = approaching;
      _recomputeNavPhase();
    }
    final accKnown = pos.accuracy.isFinite && pos.accuracy > 0;
    final qualifies =
        d < _arriveRadiusM && (!accKnown || pos.accuracy < _arriveAccuracyM);
    if (!qualifies) {
      _arriveHits = 0;
      return;
    }
    _arriveHits++;
    final needed = accKnown ? 2 : 3;
    if (_arriveHits >= needed) {
      _navArrived = true;
      HapticService.mediumImpact();
      _recomputeNavPhase();
    }
  }

  /// GPS noise never reroutes: the driver must sit more than 40 m off the
  /// polyline for 4 straight seconds of fixes (sampled per fix, reset the
  /// moment a fix lands back within 25 m) before a reroute is even asked
  /// for. Inside the approach radius there is nothing to reroute to — the
  /// line already ends at the pin.
  void _checkOffRoute(LatLng pos) {
    if (_routePts.length < 2 || _navArrived || _routeFetching) return;
    if (RouteSplice.haversineM(pos, _dest) < _approachRadiusM) return;
    final d = RouteSplice.distanceToPolylineM(_routePts, pos);
    if (d <= _offRouteResetM) {
      _offRouteSince = null;
      return;
    }
    if (d <= _offRouteM) return; // hysteresis band: neither arm nor reset
    final now = DateTime.now();
    _offRouteSince ??= now;
    if (now.difference(_offRouteSince!).inSeconds >= _offRouteHoldSecs) {
      _offRouteSince = null;
      unawaited(_fetchRoute(kind: _RouteFetchKind.reroute, origin: pos));
    }
  }

  /// One-shot steps fill (user report 2026-09-17): a route the parallel
  /// race drew from Google/OSRM carries no maneuvers — the bar fell back to
  /// a bare "Follow the route" with no distance to the next turn. Ask
  /// Mapbox for just the steps and swap them in; failures keep the bar on
  /// the distance-to-destination fallback.
  bool _stepsFilling = false;
  Future<void> _fillSteps(LatLng origin) async {
    if (_stepsFilling) return;
    _stepsFilling = true;
    try {
      final steps = await DirectionsService(ApiKeys.webServices)
          .getSteps(origin: origin, destination: _dest);
      if (!mounted || steps == null || steps.length < 2) return;
      _navProgress = NavProgress(steps);
      _updateManeuvers(_driverLatLng());
    } finally {
      _stepsFilling = false;
    }
  }

  /// Advance the step tracker and repaint the bar — only when what the bar
  /// SAYS changed, so a driver sitting at a light causes no rebuilds.
  void _updateManeuvers(LatLng driverPos) {
    final nav = _navProgress;
    if (nav == null || !nav.hasSteps) return;
    nav.update(driverPos);
    final cur = nav.current;
    final s = S.of(context);
    final street =
        cur == null || cur.name.isEmpty ? s.navFollowRoute : cur.name;
    final dist = cur == null
        ? ''
        : _fmtDist(nav.distanceToCurrentMeters(driverPos), s);
    final then = nav.then == null || nav.then!.name.isEmpty
        ? ''
        : '${s.navThen} → ${nav.then!.name}';

    // Remaining trip = distance to the current maneuver plus every step
    // after it — the "9 min · 4.1 mi" of the sheet.
    var meters = cur == null ? 0.0 : nav.distanceToCurrentMeters(driverPos);
    var secs = 0;
    if (cur != null) {
      for (var i = nav.steps.indexOf(cur) + 1; i < nav.steps.length; i++) {
        meters += nav.steps[i].distanceMeters;
        secs += nav.steps[i].durationSeconds;
      }
    }

    final type = cur?.maneuverType ?? 'arrive';
    final modifier = cur?.modifier ?? '';
    if (street == _streetLabel &&
        dist == _maneuverDistLabel &&
        then == _thenLabel &&
        type == _maneuverType &&
        modifier == _maneuverModifier &&
        (secs - _remainSecs).abs() < 15) {
      return;
    }
    setState(() {
      _streetLabel = street;
      _maneuverDistLabel = dist;
      _thenLabel = then;
      _maneuverType = type;
      _maneuverModifier = modifier;
      _remainSecs = secs;
      _remainMeters = meters;
    });
  }

  /// Bilingual maneuver distance: EN feet/mi, ES m/km.
  String _fmtDist(double meters, S s) {
    if (s.isSpanish) {
      if (meters < 950) return '${meters.round()} m';
      return '${(meters / 1000).toStringAsFixed(1)} km';
    }
    final mi = meters / 1609.34;
    if (mi < 0.1) return '${(meters * 3.28084).round()} ft';
    return '${mi.toStringAsFixed(1)} mi';
  }

  // ─────────────────────────────────────────────
  //  Route
  // ─────────────────────────────────────────────

  LatLng _driverLatLng() => LatLng(
        _dot.lat ?? widget.initialDriverPos.latitude,
        _dot.lng ?? widget.initialDriverPos.longitude,
      );

  static double _polylineLenM(List<LatLng> pts) {
    var m = 0.0;
    for (var i = 0; i + 1 < pts.length; i++) {
      m += RouteSplice.haversineM(pts[i], pts[i + 1]);
    }
    return m;
  }

  /// The accept screen hands over the route its mini map already drew. When
  /// that geometry still serves THIS leg's destination it goes on the map
  /// with no fetch — and the network is only asked for what is missing.
  void _seedPrefetchedRoute() {
    final pre = widget.prefetchedRoutePoints ?? const <LatLng>[];
    if (pre.length < 2) return;
    if (RouteSplice.haversineM(pre.last, _dest) > _prefetchDestMaxM) return;
    _routePts = List.of(pre);
    _routeLenM = _polylineLenM(_routePts);
    if (widget.prefetchedSteps.isNotEmpty) {
      _navProgress = NavProgress(widget.prefetchedSteps);
    }
  }

  Future<void> _loadRoute() async {
    if (_routePts.length >= 2) {
      if (_navProgress != null) {
        // Geometry + steps: complete without touching the network.
        await _drawRoute();
        await _drawDestPin();
        _updateManeuvers(_driverLatLng());
        _recomputeNavPhase();
        return;
      }
      // Geometry only: fill NavProgress/ETA in the background. The drawn
      // line is replaced inside the fetch only when the fresh geometry
      // really differs.
      unawaited(_fetchRoute(kind: _RouteFetchKind.backgroundFill));
      return;
    }
    await _fetchRoute(kind: _RouteFetchKind.initial);
  }

  /// The single route-request entry. One in flight ever ([_routeFetching]);
  /// reroutes additionally respect the 15 s cooldown and every response is
  /// checked against the [_rerouteSeq] it was launched with, so a stale
  /// answer can never overwrite a newer plan (a leg flip invalidates the
  /// request that was on the wire for the old destination).
  Future<void> _fetchRoute({
    required _RouteFetchKind kind,
    LatLng? origin,
  }) async {
    if (_routeFetching) return;
    if (kind == _RouteFetchKind.reroute) {
      final now = DateTime.now();
      final last = _lastRerouteAt;
      if (last != null &&
          now.difference(last).inSeconds < _rerouteCooldownSecs) {
        return;
      }
      _lastRerouteAt = now;
    }
    final seq = ++_rerouteSeq;
    _routeFetching = true;
    if (kind == _RouteFetchKind.reroute) {
      _rerouting = true;
      _recomputeNavPhase();
    }
    try {
      final o = origin ?? _driverLatLng();
      final result = await DirectionsService(ApiKeys.webServices).getRoute(
        origin: o,
        destination: _dest,
      );
      if (!mounted || seq != _rerouteSeq) return;
      if (result == null || result.points.length < 2) {
        _onRouteFetchFailed();
        return;
      }
      await _onRouteFetchSucceeded(kind, result, o);
    } catch (e) {
      debugPrint('[Nav] route fetch failed: $e');
      if (!mounted || seq != _rerouteSeq) return;
      _onRouteFetchFailed();
    } finally {
      // A destination change bumped the seq and owns the flags now — a
      // stale fetch must not clear the guard of its successor.
      if (seq == _rerouteSeq) {
        _routeFetching = false;
        if (mounted && _rerouting) {
          _rerouting = false;
          _recomputeNavPhase();
        }
      }
    }
  }

  Future<void> _onRouteFetchSucceeded(
      _RouteFetchKind kind, RouteResult result, LatLng origin) async {
    _offlineRetryTimer?.cancel();
    _offlineRetryAttempt = 0;
    _routeError = false;
    switch (kind) {
      case _RouteFetchKind.backgroundFill:
        // The prefetched line stays unless the fresh geometry differs by
        // more than 5% — the driver never watches the route redraw itself
        // for no reason. Steps always land: they are what the fetch was for.
        _navProgress = NavProgress(result.steps);
        final newLen = _polylineLenM(result.points);
        if (_routeLenM <= 0 ||
            (newLen - _routeLenM).abs() > _routeLenM * 0.05) {
          _routePts = result.points;
          _routeLenM = newLen;
          await _drawRoute();
        }
        break;
      case _RouteFetchKind.reroute:
        // Atomic: state first, then ONE annotation update — the old line is
        // replaced, never doubled, and it stays up for the whole fetch.
        _routePts = result.points;
        _routeLenM = _polylineLenM(result.points);
        _navProgress = NavProgress(result.steps);
        await _drawRoute();
        await _drawDestPin();
        break;
      case _RouteFetchKind.initial:
      case _RouteFetchKind.retry:
        _routePts = result.points;
        _routeLenM = _polylineLenM(result.points);
        _navProgress = NavProgress(result.steps);
        await _drawRoute();
        await _drawDestPin();
        break;
    }
    if (!mounted) return;
    _offlineKeepRoute = false;
    // A race won by Google/OSRM arrives with EMPTY steps — the bar would
    // read "Follow the route" forever (user report 2026-09-17). Fill the
    // maneuvers from Mapbox in the background, once per plan.
    if (_navProgress == null || !_navProgress!.hasSteps) {
      unawaited(_fillSteps(origin));
    }
    _updateManeuvers(origin);
    _recomputeNavPhase();
    // A parked driver re-aims at the fresh geometry too — the tangent of a
    // rerouted line can point somewhere new entirely.
    if (_speedMps < 1.0) {
      final h = _routeHeadingFor(origin);
      if (h != null) _dot.setBearing(h);
    }
    // Same rule as _onMapCreated: chase pose, never a top-down fit — the
    // bounds fit belongs to the overview toggle (user spec 2026-09-16).
    if (_overview) {
      await _fitRouteOnce();
    } else {
      _snapToChasePose();
    }
  }

  /// A dead network is two different problems: with a line on the map the
  /// driver keeps navigating on it (offline pill, quiet 5/15/30 s retries);
  /// with nothing drawn there is no navigation without it — routeError.
  void _onRouteFetchFailed() {
    if (_routePts.length >= 2) {
      _offlineKeepRoute = true;
      _recomputeNavPhase();
      _armOfflineRetry();
    } else {
      _routeError = true;
      _recomputeNavPhase();
    }
  }

  void _armOfflineRetry() {
    _offlineRetryTimer?.cancel();
    final idx =
        _offlineRetryAttempt.clamp(0, _offlineBackoff.length - 1);
    _offlineRetryAttempt++;
    _offlineRetryTimer = Timer(_offlineBackoff[idx], () {
      if (!mounted) return;
      unawaited(_fetchRoute(kind: _RouteFetchKind.retry));
    });
  }

  void _retryRouteFetch() {
    HapticService.lightImpact();
    _routeError = false;
    _recomputeNavPhase(); // back to initializing while the request flies
    unawaited(_fetchRoute(kind: _RouteFetchKind.retry));
  }

  void _retryGps() {
    HapticService.lightImpact();
    unawaited(_gps?.stop());
    _gps = null;
    _gpsDown = false;
    _recomputeNavPhase();
    _startGps(); // fresh stream, fresh 6 s grace window
  }

  Future<void> _openLocationSettings() async {
    HapticService.lightImpact();
    try {
      await Geolocator.openLocationSettings();
    } catch (e) {
      debugPrint('[Nav] openLocationSettings failed: $e');
    }
  }

  /// The destination moved (leg flip or a mid-trip change): every product
  /// of the old plan is invalidated, the in-flight request is orphaned via
  /// the seq token, and the line comes off the map until the new one lands.
  /// A prefetch that still ends at the NEW destination is reused — the leg
  /// flip is exactly that case (the parent's pickup→dropoff geometry).
  void _onDestinationChanged() {
    _rerouteSeq++;
    _routeFetching = false;
    _rerouting = false;
    _lastRerouteAt = null;
    _offRouteSince = null;
    _navProgress = null;
    _navArrived = false;
    _navApproaching = false;
    _arriveHits = 0;
    _endRouteRaised = false;
    _offlineRetryTimer?.cancel();
    _offlineRetryAttempt = 0;
    _offlineKeepRoute = false;
    _routeError = false;
    _routePts = [];
    _routeLenM = 0;
    unawaited(_clearRouteAnnotation());
    unawaited(_drawDestPin());
    _recomputeNavPhase();
    _seedPrefetchedRoute();
    unawaited(_loadRoute());
  }

  Future<void> _clearRouteAnnotation() async {
    final annot = _routeAnnot;
    _routeAnnot = null;
    final mgr = _polyMgr;
    if (annot != null && mgr != null) {
      try {
        await mgr.delete(annot);
      } catch (_) {}
    }
  }

  Future<void> _drawRoute() async {
    if (kIsWeb) {
      final web = _webMap;
      if (web != null && _routePts.length >= 2) {
        web.setPolyline(
          'navRoute',
          [
            for (final p in _routePts)
              (lng: p.longitude, lat: p.latitude)
          ],
          color: '#E8C547',
          width: 5,
        );
      }
      return;
    }
    final mgr = _polyMgr;
    if (mgr == null) return;
    final geom = safeLineString(_routePts);
    if (geom == null) return;
    if (_routeAnnot != null) {
      _routeAnnot!.geometry = geom;
      try {
        await mgr.update(_routeAnnot!);
      } catch (_) {}
    } else {
      try {
        _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
          geometry: geom,
          lineColor: _gold.toARGB32(),
          lineWidth: 5.0,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
      } catch (_) {}
    }
  }

  Future<void> _drawDestPin() async {
    final mgr = _pointMgr;
    final point = safePoint(_dest.longitude, _dest.latitude);
    if (mgr == null || point == null) return;
    final old = _destAnnot;
    _destAnnot = null;
    if (old != null) {
      try {
        await mgr.delete(old);
      } catch (_) {}
    }
    try {
      // The same golden teardrop every other map draws: person at the
      // pickup, flag at the dropoff.
      final bytes = await renderCircularPinBytes(
        icon: widget.toPickup ? CircularPinIcon.person : CircularPinIcon.flag,
        isPickup: widget.toPickup,
        radius: 32,
      );
      if (!mounted) return;
      _destAnnot = await mgr.create(mapbox.PointAnnotationOptions(
        geometry: point,
        image: bytes,
        iconSize: 0.62,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
      ));
    } catch (_) {}
  }

  /// The overview-toggle bounds fit (the only top-down view left, user spec
  /// 2026-09-16 — opening and route updates use _snapToChasePose instead).
  Future<void> _fitRouteOnce() async {
    if (_routePts.length < 2) return;
    if (kIsWeb) {
      _webMap?.fitBounds(
        [
          for (final p in _routePts)
            (lng: p.longitude, lat: p.latitude)
        ],
        paddingTop: 120,
        paddingLeft: 48,
        paddingBottom: 220,
        paddingRight: 48,
      );
      return;
    }
    final map = _map;
    if (map == null) return;
    final media = MediaQuery.of(context);
    final coords = _routePts
        .where((p) => isValidLatLng(p.latitude, p.longitude))
        .map((p) =>
            mapbox.Point(coordinates: mapbox.Position(p.longitude, p.latitude)))
        .toList();
    if (coords.isEmpty) return;
    try {
      final cam = await map.cameraForCoordinatesPadding(
        coords,
        mapbox.CameraOptions(pitch: 0, bearing: 0),
        mapbox.MbxEdgeInsets(
          top: media.padding.top + 120,
          left: 48,
          bottom: media.size.height * 0.30,
          right: 48,
        ),
        null,
        null,
      );
      if (!mounted) return;
      // The overview toggle reuses this fit; chasing from it keeps follow on.
      await map.flyTo(cam, mapbox.MapAnimationOptions(duration: 900));
    } catch (e) {
      debugPrint('[Nav] route fit failed: $e');
    }
  }

  // ─────────────────────────────────────────────
  //  Per-frame: marker annotation + chase camera
  // ─────────────────────────────────────────────

  /// GoldLocationDot onTick — throttled (~30 fps), position changed.
  void _onDotTick() {
    _updateDriverAnnotation();
  }

  /// Where the chase zoom wants to be: tighter (18.0) with a maneuver under
  /// 150 m ahead, looser (17.0) past 20 m/s, 17.5 the rest of the time.
  double _zoomTarget() {
    final nav = _navProgress;
    final lat = _dot.lat;
    final lng = _dot.lng;
    if (nav != null && nav.hasSteps && lat != null && lng != null) {
      final dManeuver = nav.distanceToCurrentMeters(LatLng(lat, lng));
      if (dManeuver > 0 && dManeuver < 150) return _chaseZoomManeuver;
    }
    if (_speedMps > 20) return _chaseZoomFast;
    return _chaseZoomDefault;
  }

  /// GoldLocationDot onFrame — unthrottled, repaint-rate. While following,
  /// the marker never moves on screen — the map slides under it — so the
  /// camera is the only thing to write per frame. In freeLook / recentering
  /// / overview the chase writes nothing at all.
  void _onDotFrame() {
    if (_camState != _CamState.following || _overview || !_mapMounted) {
      return;
    }
    final lat = _dot.lat;
    final lng = _dot.lng;
    if (lat == null || lng == null) return;
    // Zoom lerps toward its target at ≤0.5/sec — a speed or maneuver change
    // is felt as a glide, never as a cut.
    final now = DateTime.now();
    var dt = _lastChaseFrameAt == null
        ? 0.0
        : now.difference(_lastChaseFrameAt!).inMilliseconds / 1000.0;
    _lastChaseFrameAt = now;
    if (dt > 0.1) dt = 0.1; // long frame (resume): no catch-up jump
    final target = _zoomTarget();
    final maxStep = _zoomLerpPerSec * dt;
    if ((_chaseZoom - target).abs() <= maxStep) {
      _chaseZoom = target;
    } else {
      _chaseZoom += _chaseZoom < target ? maxStep : -maxStep;
    }
    // Top padding pushes the focal point below centre (the car sits at
    // ~60% of the screen height, Google-Maps style) and keeps the arrow
    // clear of the maneuver bar.
    final topPad = (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 130;
    _writeCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
      zoom: _chaseZoom,
      bearing: _dot.bearing,
      pitch: _chasePitch,
      padding: mapbox.MbxEdgeInsets(top: topPad, left: 0, right: 0, bottom: 0),
    ));
  }

  /// One explicit chase-pose write, for the moments the per-frame chase is
  /// asleep: the dot's ticker only fires on movement, so a parked driver
  /// gets no frames — and without this the camera stayed wherever a
  /// top-down bounds fit had left it (user spec 2026-09-16). Writes nothing
  /// in freeLook / recentering / overview, exactly like the per-frame chase.
  void _snapToChasePose() {
    if (_camState != _CamState.following || _overview || !_mapMounted) {
      return;
    }
    final lat = _dot.lat;
    final lng = _dot.lng;
    if (lat == null || lng == null) return;
    final topPad = (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 130;
    _writeCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
      zoom: _chaseZoom,
      bearing: _dot.bearing,
      pitch: _chasePitch,
      padding: mapbox.MbxEdgeInsets(top: topPad, left: 0, right: 0, bottom: 0),
    ));
  }

  /// Coalesced per-frame camera write — one in flight, one pending, ever.
  /// Same discipline as the online screen's _writeCamera: a dropped frame
  /// carries no information, the next one is already newer.
  void _writeCamera(mapbox.CameraOptions options) {
    if (kIsWeb) {
      final web = _webMap;
      final center = options.center?.coordinates;
      if (web == null || center == null) return;
      web.flyTo(
        lng: center.lng.toDouble(),
        lat: center.lat.toDouble(),
        zoom: options.zoom,
        bearing: options.bearing,
        pitch: options.pitch,
        durationMs: 0,
      );
      return;
    }
    final map = _map;
    if (map == null) return;
    _pendingCamWrite = options;
    if (_camWriteBusy) return;
    _flushCameraWrite(map);
  }

  void _flushCameraWrite(mapbox.MapboxMap map) {
    final opts = _pendingCamWrite;
    if (opts == null) return;
    _pendingCamWrite = null;
    _camWriteBusy = true;
    try {
      map.setCamera(opts).timeout(const Duration(seconds: 2)).then((_) {
        _camWriteBusy = false;
        _flushCameraWrite(map);
      }).catchError((Object _) {
        _camWriteBusy = false;
        _flushCameraWrite(map);
      });
    } catch (_) {
      _camWriteBusy = false;
    }
  }

  Future<void> _updateDriverAnnotation() async {
    if (!mounted || _annotWriteBusy) return;
    // The arrow's own manager: icon-rotation-alignment 'map' is set per
    // manager — on the shared pins manager it laid the destination pin and
    // the rider figure down whenever the chase camera rotated (user report
    // 2026-09-17, the "pin acostado").
    final mgr = _carMgr;
    final lat = _dot.lat;
    final lng = _dot.lng;
    if (mgr == null || lat == null || lng == null) return;
    if (!isValidLatLng(lat, lng)) return;
    final img = _dot.currentBytesHiRes ?? _dot.currentBytes;
    if (img == null) return;
    final bearing = _dot.bearing;
    // Sub-threshold gate: a parked car must not pay a native write per tick
    // (~0.1 m / 0.5°). The arrow keeps its last reliable bearing instead of
    // trembling with GPS noise — SmoothMotion already refuses GPS headings
    // under 1 m/s, so what reaches here is worth writing.
    if (_driverAnnot != null &&
        _lastSentLat != null &&
        (lat - _lastSentLat!).abs() < 1e-6 &&
        (lng - _lastSentLng!).abs() < 1e-6 &&
        (bearing - _lastSentBearing!).abs() < 0.5) {
      return;
    }
    _annotWriteBusy = true;
    try {
      if (_driverAnnot == null) {
        _driverAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
          image: img,
          // Hi-res bitmap at 1/3 density lands at the overlay's size.
          iconSize: GoldLocationDot.driverIconSize /
              (_dot.currentBytesHiRes != null
                  ? GoldLocationDot.rasterScale
                  : 1.0),
          iconAnchor: mapbox.IconAnchor.CENTER,
          iconRotate: bearing,
        ));
        try {
          await _map?.style.setStyleLayerProperty(
              mgr.id, 'icon-rotation-alignment', 'map');
        } catch (_) {}
      } else {
        _driverAnnot!.geometry =
            mapbox.Point(coordinates: mapbox.Position(lng, lat));
        _driverAnnot!.iconRotate = bearing;
        await mgr.update(_driverAnnot!);
      }
      _lastSentLat = lat;
      _lastSentLng = lng;
      _lastSentBearing = bearing;
    } catch (_) {
      // Annotation died with its surface — null it so the next tick
      // recreates it on the fresh map.
      _driverAnnot = null;
      _lastSentLat = null;
      _lastSentLng = null;
      _lastSentBearing = null;
    } finally {
      _annotWriteBusy = false;
    }
  }

  // ─────────────────────────────────────────────
  //  Rider figure (pickup leg only)
  // ─────────────────────────────────────────────

  void _listenRiderLocation() {
    _riderLocSub = SocketService.riderLocationStream.listen((data) {
      if (!mounted) return;
      if ((data['trip_id'] as num?)?.toInt() != widget.tripId) return;
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (!isValidLatLng(lat, lng)) return;
      _riderFixAt = DateTime.now();
      _riderMotion.setTarget(
        lat!,
        lng!,
        bearing: (data['heading'] as num?)?.toDouble(),
        timestampMs: (data['captured_at'] as num?)?.toDouble(),
      );
      _armRiderStaleTimer();
    });
  }

  void _onRiderTick(Duration elapsed) {
    final dtSec = _riderLastTick == Duration.zero
        ? 0.0
        : (elapsed - _riderLastTick).inMicroseconds / 1e6;
    _riderLastTick = elapsed;
    if (!_riderMotion.tick(dtSec)) return;
    _updateRiderAnnotation();
  }

  Future<void> _updateRiderAnnotation() async {
    if (!mounted) return;
    // Pickup leg only: once the rider is aboard (slide to pick up done)
    // the dot hides with the leg flip.
    if (!widget.toPickup) return;
    final mgr = _circleMgr;
    final lat = _riderMotion.lat;
    final lng = _riderMotion.lng;
    if (mgr == null || lat == null || lng == null) return;
    if (!isValidLatLng(lat, lng)) return;
    final p = mapbox.Point(coordinates: mapbox.Position(lng, lat));
    try {
      // The blue location puck (user spec 2026-09-17): translucent halo +
      // blue dot with a white ring — the same marker the rider side draws,
      // never an icon.
      if (_riderHaloAnnot == null) {
        _riderHaloAnnot = await mgr.create(mapbox.CircleAnnotationOptions(
          geometry: p,
          circleRadius: 13.0,
          circleColor: _riderBlue.withValues(alpha: 0.22).toARGB32(),
        ));
      } else {
        _riderHaloAnnot!.geometry = p;
        await mgr.update(_riderHaloAnnot!);
      }
      if (!mounted) return;
      if (_riderDotAnnot == null) {
        _riderDotAnnot = await mgr.create(mapbox.CircleAnnotationOptions(
          geometry: p,
          circleRadius: 7.0,
          circleColor: _riderBlue.toARGB32(),
          circleStrokeWidth: 2.5,
          circleStrokeColor: Colors.white.toARGB32(),
        ));
      } else {
        _riderDotAnnot!.geometry = p;
        await mgr.update(_riderDotAnnot!);
      }
    } catch (_) {
      _riderHaloAnnot = null;
      _riderDotAnnot = null;
    }
  }

  /// Fix older than 15 s → a subtle "hace Xs" next to the halo. The label is
  /// a Flutter widget (annotation text would need a re-raster per second);
  /// its anchor re-projects once a second, which the channel barely notices.
  void _armRiderStaleTimer() {
    _riderStaleTimer ??= Timer.periodic(const Duration(seconds: 1), (_) async {
      if (!mounted) return;
      final fixAt = _riderFixAt;
      if (fixAt == null || !widget.toPickup) {
        if (_riderLabelPos != null) setState(() => _riderLabelPos = null);
        return;
      }
      final age = DateTime.now().difference(fixAt).inSeconds;
      if (age <= 15) {
        if (_riderLabelPos != null) setState(() => _riderLabelPos = null);
        return;
      }
      final map = _map;
      final lat = _riderMotion.lat;
      final lng = _riderMotion.lng;
      if (map == null || lat == null || lng == null) return;
      try {
        final sc = await map.pixelForCoordinate(
            mapbox.Point(coordinates: mapbox.Position(lng, lat)));
        if (!mounted) return;
        setState(() {
          _riderStaleSecs = age;
          _riderLabelPos = Offset(sc.x, sc.y);
        });
      } catch (_) {}
    });
  }

  // ─────────────────────────────────────────────
  //  Stage controls (wait bar + slides)
  // ─────────────────────────────────────────────

  void _syncStageControls(String stage) {
    if (stage == _lastStageSynced) return;
    _lastStageSynced = stage;
    final waiting = stage == 'waiting_rider' || stage == 'start_ride';
    if (waiting && _waitTicker == null) {
      // The backend timestamp wins; a notes-less trip starts the clock when
      // the stage first shows.
      _waitStartLocal ??= DateTime.now();
      _tickWait();
      _waitTicker = Timer.periodic(const Duration(seconds: 1), (_) {
        if (mounted) _tickWait();
      });
    }
    if (!waiting && _waitTicker != null) {
      _waitTicker?.cancel();
      _waitTicker = null;
    }
  }

  void _tickWait() {
    final start = widget.waitStartedAt ?? _waitStartLocal ?? DateTime.now();
    final elapsed = DateTime.now().difference(start).inSeconds;
    final remain = (_waitTotalSecs - elapsed).clamp(0, _waitTotalSecs);
    if (!mounted) return;
    setState(() {
      _waitRemainFrac = remain / _waitTotalSecs;
      _waitClock =
          '${remain ~/ 60}:${(remain % 60).toString().padLeft(2, '0')}';
    });
  }

  // ─────────────────────────────────────────────
  //  Camera buttons
  // ─────────────────────────────────────────────

  void _toggleOverview() {
    HapticService.lightImpact();
    if (_overview) {
      // Leaving overview (user spec 2026-09-17): hand the camera back to the
      // chase the SMOOTH way — the same flyTo the recenter button uses, not
      // a state flip that lets the next chase frame snap the camera.
      unawaited(_recenter());
      return;
    }
    setState(() {
      _overview = !_overview;
      _camState = _overview ? _CamState.freeLook : _CamState.following;
    });
    if (_overview) unawaited(_fitRouteOnce());
  }

  /// Recenter → recentering: a smooth flyTo back to the chase target, then
  /// following. A drag mid-flight moves the state to freeLook instead.
  Future<void> _recenter() async {
    HapticService.lightImpact();
    final lat = _dot.lat;
    final lng = _dot.lng;
    setState(() {
      _overview = false;
      _camState = _CamState.recentering;
    });
    if (lat == null || lng == null) {
      setState(() => _camState = _CamState.following);
      return;
    }
    if (kIsWeb) {
      _webMap?.flyTo(
        lng: lng,
        lat: lat,
        zoom: _chaseZoom,
        bearing: _dot.bearing,
        pitch: _chasePitch,
        durationMs: 1200,
      );
      if (!mounted) return;
      setState(() => _camState = _CamState.following);
      return;
    }
    final map = _map;
    if (map == null) {
      setState(() => _camState = _CamState.following);
      return;
    }
    final topPad = (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 130;
    try {
      await map.flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
          zoom: _chaseZoom,
          bearing: _dot.bearing,
          pitch: _chasePitch,
          padding:
              mapbox.MbxEdgeInsets(top: topPad, left: 0, right: 0, bottom: 0),
        ),
        mapbox.MapAnimationOptions(duration: 1200),
      );
    } catch (_) {}
    if (!mounted) return;
    // Only close the maneuver if the recenter still owns the camera.
    if (_camState == _CamState.recentering) {
      setState(() => _camState = _CamState.following);
    }
  }

  /// Drag / pinch / rotate → freeLook. The map's own gesture callbacks cover
  /// drag and pinch; a second finger down (pinch or rotate — rotate has no
  /// widget-level listener in this SDK) is caught by the pointer Listener
  /// wrapping the MapWidget. onCameraChangeListener is never usable here:
  /// it fires for the chase's own writes and would unlatch follow on them.
  void _onUserGesture() {
    if (_overview) return;
    if (_camState == _CamState.freeLook) return;
    setState(() => _camState = _CamState.freeLook);
  }

  // ─────────────────────────────────────────────
  //  Build
  // ─────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final media = MediaQuery.of(context);
    return Stack(
      children: [
        // ── Map ──
        Positioned.fill(
          child: _mapMounted && !kIsWeb
              ? RepaintBoundary(
                  // Pointer Listener, not a GestureDetector: it observes the
                  // hit stream without entering the gesture arena, so the map
                  // keeps every one of its own gestures. A second finger is
                  // pinch or rotate — both mean the driver took the camera.
                  child: Listener(
                    onPointerDown: (_) {
                      _mapPointers++;
                      if (_mapPointers >= 2) _onUserGesture();
                    },
                    onPointerUp: (_) {
                      if (_mapPointers > 0) _mapPointers--;
                    },
                    onPointerCancel: (_) {
                      if (_mapPointers > 0) _mapPointers--;
                    },
                    child: mapbox.MapWidget(
                      textureView: true,
                      styleUri: MapboxConfig.styleDark,
                      // The very first native frame is already the chase
                      // pose (user spec 2026-09-16): tilted, aimed down-
                      // route — never a flat overview that a later write
                      // has to correct in front of the driver.
                      cameraOptions: mapbox.CameraOptions(
                        center: mapbox.Point(
                            coordinates: mapbox.Position(
                                widget.initialDriverPos.longitude,
                                widget.initialDriverPos.latitude)),
                        zoom: _chaseZoomDefault,
                        pitch: _chasePitch,
                        bearing:
                            _routeHeadingFor(widget.initialDriverPos) ?? 0.0,
                        padding: mapbox.MbxEdgeInsets(
                            top: media.padding.top + 130,
                            left: 0,
                            right: 0,
                            bottom: 0),
                      ),
                      onMapCreated: _onMapCreated,
                      onStyleLoadedListener: (_) async {
                        final m = _map;
                        if (m != null) await MapTheme.applyNavyGold(m);
                      },
                      // Gesture callbacks, not onCameraChangeListener: that
                      // one also fires for the per-frame chase and would
                      // unlatch follow on the very writes the chase performs.
                      onScrollListener: (_) => _onUserGesture(),
                      onZoomListener: (_) => _onUserGesture(),
                    ),
                  ),
                )
              : kIsWeb
                  ? WebMapView(
                      initialLng: widget.initialDriverPos.longitude,
                      initialLat: widget.initialDriverPos.latitude,
                      initialZoom: 14,
                      styleUri: MapboxConfig.styleDark,
                      onControllerCreated: (c) {
                        _webMap = c;
                        c.applyNavyGoldTheme();
                        c.onUserGesture = _onUserGesture;
                        if (_routePts.length >= 2) {
                          c.setPolyline(
                            'navRoute',
                            [
                              for (final p in _routePts)
                                (lng: p.longitude, lat: p.latitude)
                            ],
                            color: '#E8C547',
                            width: 5,
                          );
                        }
                      },
                    )
                  : const NeuDotsBackdrop(),
        ),

        // ── Maneuver bar + status pills (rerouting / offline) ──
        Positioned(
          top: media.padding.top + 10,
          left: 14,
          right: 14,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildManeuverBar(s),
              if (_navPhase == _NavPhase.rerouting)
                _buildNavPill(s.navRerouting, spinner: true),
              if (_offlineKeepRoute)
                _buildNavPill(s.navOfflineKeepRoute,
                    icon: Icons.wifi_off_rounded),
            ],
          ),
        ),

        // ── Failure cards: never a blank page ──
        if (_navPhase == _NavPhase.gpsUnavailable)
          Positioned(
            left: 24,
            right: 24,
            top: media.size.height * 0.30,
            child: _buildNavCard(
              icon: Icons.gps_off_rounded,
              title: s.navGpsUnavailableTitle,
              body: s.navGpsUnavailableBody,
              buttons: [
                (
                  label: s.navOpenSettings,
                  filled: true,
                  onTap: _openLocationSettings,
                ),
                (label: s.navRetry, filled: false, onTap: _retryGps),
              ],
            ),
          ),
        if (_navPhase == _NavPhase.routeError)
          Positioned(
            left: 24,
            right: 24,
            top: media.size.height * 0.30,
            child: _buildNavCard(
              icon: Icons.cloud_off_rounded,
              title: s.connectionError,
              buttons: [
                (label: s.navRetry, filled: true, onTap: _retryRouteFetch),
              ],
            ),
          ),

        // ── Sheet-anchored overlays: mph, camera buttons, wait bar and the
        //    stage control all ride the sheet's top edge, so they rebuild
        //    with the drag rather than a frame behind it. ──
        AnimatedBuilder(
          animation: _sheetCtrl,
          builder: (ctx, _) {
            final extent =
                _sheetCtrl.isAttached ? _sheetCtrl.size : 0.20;
            final lift = media.size.height * extent + 16;
            return Stack(
              children: [
                // The speed box yields to the arrival button stack — it has
                // nothing to say while parked at the destination.
                if (!_phaseArrived)
                  Positioned(
                    left: 16,
                    bottom: lift,
                    child: _buildSpeedBox(),
                  ),
                Positioned(
                  right: 14,
                  bottom: lift,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _roundMapBtn(
                        icon: _overview
                            ? Icons.navigation_rounded
                            : Icons.map_outlined,
                        tooltip: _overview ? s.navRecenter : s.navOverview,
                        onTap: _toggleOverview,
                      ),
                      // Recenter appears only once the driver has taken
                      // the camera.
                      if (_camState == _CamState.freeLook && !_overview) ...[
                        const SizedBox(height: 10),
                        _roundMapBtn(
                          icon: Icons.my_location_rounded,
                          tooltip: s.navRecenter,
                          onTap: _recenter,
                        ),
                      ],
                    ],
                  ),
                ),
                if (widget.stage == 'waiting_rider' ||
                    widget.stage == 'start_ride')
                  Positioned(
                    left: 16,
                    right: 16,
                    bottom: lift,
                    child: _buildWaitBar(s),
                  ),
                // End Route lives IN the sheet now (user spec 2026-09-17):
                // on arrival the addresses swap out and the gold button
                // fades in below the face — never floating above the sheet.
              ],
            );
          },
        ),

        // ── Rider stale-fix label, next to the halo ──
        if (_riderLabelPos != null && widget.toPickup)
          Positioned(
            left: _riderLabelPos!.dx + 26,
            top: _riderLabelPos!.dy - 10,
            child: IgnorePointer(
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: _navyBar.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  s.navRiderLocationStale(_riderStaleSecs),
                  style: const TextStyle(
                      color: Colors.white70,
                      fontSize: 10,
                      fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ),

        // ── Rider sheet ──
        DraggableScrollableSheet(
          controller: _sheetCtrl,
          initialChildSize: 0.20,
          minChildSize: 0.12,
          maxChildSize: 0.72,
          builder: (ctx, scrollCtrl) => Container(
            decoration: BoxDecoration(
              color: neuBase,
              borderRadius:
                  const BorderRadius.vertical(top: Radius.circular(24)),
              border: Border.all(
                  color: Colors.white.withValues(alpha: 0.06), width: 1),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 24,
                  offset: const Offset(0, -6),
                ),
              ],
            ),
            child: _buildSheet(s, scrollCtrl),
          ),
        ),
      ],
    );
  }

  /// Fallback for a steps-less route: the distance left to the destination
  /// — real information instead of repeating the title (user report
  /// 2026-09-17: the bar read "Follow the route / Follow the route").
  String _destDistLabel(S s) {
    final d = RouteSplice.haversineM(_driverLatLng(), _dest);
    return '${s.navFollowRoute} · ${_fmtDist(d, s)}';
  }

  Widget _buildManeuverBar(S s) {
    final destName =
        widget.toPickup ? widget.pickupAddress : widget.dropoffAddress;
    final title = _phaseArrived
        ? (widget.toPickup ? s.navArrivedPickup : s.navArrivedDropoff)
        : (_streetLabel.isEmpty ? s.navFollowRoute : _streetLabel);
    final subtitle = _phaseArrived
        ? destName
        : (_maneuverDistLabel.isNotEmpty
            ? _maneuverDistLabel
            : _destDistLabel(s));
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
      decoration: BoxDecoration(
        color: _navyBar.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: _gold.withValues(alpha: 0.25), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.45),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Row(
        children: [
          // Bigger (34 → 44, user spec 2026-09-17) and the indication swaps
          // crossfade — a turn icon never snaps.
          AnimatedSwitcher(
            duration: const Duration(milliseconds: 220),
            transitionBuilder: (child, anim) => FadeTransition(
              opacity: anim,
              child: ScaleTransition(scale: anim, child: child),
            ),
            child: Icon(
                _phaseArrived
                    ? Icons.flag_rounded
                    : _maneuverIcon(_maneuverType, _maneuverModifier),
                key: ValueKey(
                    '${_phaseArrived}_${_maneuverType}_$_maneuverModifier'),
                color: Colors.white,
                size: 44),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (!_phaseArrived && _thenLabel.isNotEmpty)
                  Text(
                    _thenLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
          // Way back to the trip sheet — navigation never traps the driver.
          // The arrival close action lives at the bottom, under the stage
          // control (_buildEndRouteButton); the bar keeps the quiet X.
          Tooltip(
            message: s.navExit,
            child: GestureDetector(
              onTap: () {
                HapticService.lightImpact();
                widget.onExit();
              },
              child: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(Icons.close_rounded,
                    color: Colors.white70, size: 18),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Small status pill under the maneuver bar (Rerouting… / offline).
  Widget _buildNavPill(String label,
      {bool spinner = false, IconData? icon}) {
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: _navyBar.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.35)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (spinner) ...[
            const SizedBox(
              width: 12,
              height: 12,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: _gold,
              ),
            ),
            const SizedBox(width: 8),
          ] else if (icon != null) ...[
            Icon(icon, color: _gold, size: 13),
            const SizedBox(width: 6),
          ],
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: _gold,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Centered recovery card (GPS down / route error) — the honest face of a
  /// failure, with the way out on it, instead of a blank page.
  Widget _buildNavCard({
    required IconData icon,
    required String title,
    String? body,
    required List<({String label, bool filled, VoidCallback onTap})> buttons,
  }) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: _navyBar.withValues(alpha: 0.97),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: _gold.withValues(alpha: 0.3)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: _gold, size: 34),
          const SizedBox(height: 10),
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          if (body != null) ...[
            const SizedBox(height: 6),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 12.5,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 14),
          Row(
            children: [
              for (var i = 0; i < buttons.length; i++) ...[
                if (i > 0) const SizedBox(width: 10),
                Expanded(child: _navCardButton(buttons[i])),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _navCardButton(
      ({String label, bool filled, VoidCallback onTap}) b) {
    if (b.filled) {
      return ElevatedButton(
        onPressed: b.onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: Colors.black,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14)),
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 12),
        ),
        child: Text(
          b.label,
          style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w800),
        ),
      );
    }
    return OutlinedButton(
      onPressed: b.onTap,
      style: OutlinedButton.styleFrom(
        side: const BorderSide(color: Colors.white24),
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14)),
        foregroundColor: Colors.white,
        padding: const EdgeInsets.symmetric(vertical: 12),
      ),
      child: Text(
        b.label,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      ),
    );
  }

  IconData _maneuverIcon(String type, String modifier) {
    if (type == 'arrive') return Icons.flag_rounded;
    if (type == 'roundabout' || type == 'rotary') {
      return Icons.roundabout_left_rounded;
    }
    if (type == 'merge') return Icons.merge_rounded;
    if (type == 'fork') {
      return modifier.contains('left')
          ? Icons.fork_left_rounded
          : Icons.fork_right_rounded;
    }
    if (type == 'on ramp' || type == 'off ramp') {
      return modifier.contains('left')
          ? Icons.ramp_left_rounded
          : Icons.ramp_right_rounded;
    }
    if (modifier.contains('uturn')) return Icons.u_turn_left_rounded;
    if (modifier.contains('sharp left')) return Icons.turn_sharp_left_rounded;
    if (modifier.contains('sharp right')) {
      return Icons.turn_sharp_right_rounded;
    }
    if (modifier.contains('slight left')) {
      return Icons.turn_slight_left_rounded;
    }
    if (modifier.contains('slight right')) {
      return Icons.turn_slight_right_rounded;
    }
    if (modifier.contains('left')) return Icons.turn_left_rounded;
    if (modifier.contains('right')) return Icons.turn_right_rounded;
    return Icons.straight_rounded;
  }

  Widget _buildSpeedBox() {
    final mph = (_speedMps * 2.23694).round();
    return Container(
      width: 64,
      padding: const EdgeInsets.symmetric(vertical: 8),
      decoration: BoxDecoration(
        color: _navyBar.withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '$mph',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'mph',
            style: TextStyle(
              color: Colors.white54,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _roundMapBtn({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          width: 46,
          height: 46,
          decoration: BoxDecoration(
            color: _navyBar.withValues(alpha: 0.92),
            shape: BoxShape.circle,
            border:
                Border.all(color: _gold.withValues(alpha: 0.35), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: Icon(icon, color: _gold, size: 22),
        ),
      ),
    );
  }

  Widget _buildWaitBar(S s) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 12),
      decoration: BoxDecoration(
        color: _navyBar.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            s.navWaitFor(_waitClock),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          // The divider IS the timer: it drains to nothing over 5 minutes.
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: _waitRemainFrac.clamp(0.0, 1.0),
                child: Container(height: 3, color: _gold),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The arrival action inside the sheet (user spec 2026-09-17): gold
  /// FILLED, where the addresses were. Closes navigation (reverse morph back
  /// to the trip page) without touching trip state.
  Widget _buildEndRouteButton(S s) {
    return SizedBox(
      width: double.infinity,
      height: _endRouteHeight + 8,
      child: ElevatedButton.icon(
        onPressed: () {
          HapticService.lightImpact();
          widget.onExit();
        },
        icon: const Icon(Icons.flag_rounded, color: Colors.black, size: 20),
        label: Text(
          s.navEndRoute,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
        ),
        style: ElevatedButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: Colors.black,
          elevation: 0,
          shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(26)),
        ),
      ),
    );
  }

  // ─────────────────────────────────────────────
  //  Sheet
  // ─────────────────────────────────────────────

  Widget _buildSheet(S s, ScrollController scrollCtrl) {
    final mins = (_remainSecs / 60).ceil();
    final distLabel = _remainMeters > 0 ? _fmtDist(_remainMeters, s) : '';
    final destName =
        widget.toPickup ? widget.pickupAddress : widget.dropoffAddress;
    // The rider's first name rides WITH the miles/minutes (user spec
    // 2026-09-17) — never a bare "—" while we know who this is.
    final firstName = widget.riderName.trim().split(' ').first;
    final etaLabel = _remainSecs > 0 && distLabel.isNotEmpty
        ? '$mins min · $distLabel'
        : distLabel;
    final faceTitle =
        [etaLabel, firstName].where((e) => e.isNotEmpty).join(' · ');
    return ListView(
      controller: scrollCtrl,
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
      children: [
        Center(
          child: Container(
            margin: const EdgeInsets.only(top: 10, bottom: 10),
            width: 40,
            height: 4,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.18),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
        ),
        // Collapsed face: rider, "9 min · 4.1 mi · Jhon", destination,
        // chat/call.
        Row(
          children: [
            VerifiedAvatar(
              photoUrl: widget.riderPhotoUrl,
              radius: 24,
              fallbackName: widget.riderName,
              uid: widget.riderId?.toString(),
              role: 'rider',
              isVerified: true,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    faceTitle.isEmpty ? '—' : faceTitle,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    destName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 12,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ],
              ),
            ),
            _sheetCircleBtn(
                Icons.message_rounded, s.messageAction, widget.onOpenChat),
            const SizedBox(width: 8),
            _sheetCircleBtn(Icons.phone_rounded, s.callAction, widget.onCall,
                filled: true),
          ],
        ),
        const SizedBox(height: 16),
        // On arrival the expanded content hands its slot to End Route (user
        // spec 2026-09-17): addresses, instructions, earnings and report fade
        // out, the gold button fades in — same slot, one motion, and the
        // sheet auto-raises once so the driver actually sees it.
        AnimatedSwitcher(
          duration: const Duration(milliseconds: 320),
          switchInCurve: Curves.easeOutCubic,
          switchOutCurve: Curves.easeInCubic,
          child: _endRouteVisible
              ? Padding(
                  key: const ValueKey('end-route'),
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _buildEndRouteButton(s),
                )
              : Column(
                  key: const ValueKey('trip-details'),
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _sheetAddressRow(
                        Icons.place_rounded, s.pickupLabel, widget.pickupAddress),
                    const SizedBox(height: 10),
                    _sheetAddressRow(
                        Icons.flag_rounded, s.dropOffLabel, widget.dropoffAddress),
                    if (widget.passengerInstructions.isNotEmpty) ...[
                      const SizedBox(height: 14),
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(12),
                        decoration: neuBox(radius: 14),
                        child: Text(
                          widget.passengerInstructions,
                          style: const TextStyle(
                              color: Colors.white70, fontSize: 13, height: 1.4),
                        ),
                      ),
                    ],
                    const SizedBox(height: 14),
                    Row(
                      children: [
                        Text(
                          s.navEstimatedEarnings,
                          style: const TextStyle(color: Colors.white54, fontSize: 13),
                        ),
                        const Spacer(),
                        Text(
                          '\$${widget.fare.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    GestureDetector(
                      onTap: () {
                        HapticService.lightImpact();
                        widget.onSupport();
                      },
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(vertical: 13),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(14),
                          border:
                              Border.all(color: Colors.white.withValues(alpha: 0.12)),
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Icon(Icons.report_problem_rounded,
                                color: Colors.white54, size: 17),
                            const SizedBox(width: 8),
                            Text(
                              s.navReportProblem,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
        ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _sheetCircleBtn(IconData icon, String label, VoidCallback onTap,
      {bool filled = false}) {
    // Same language as the trip screen's action discs (user spec 2026-09-17):
    // chat is the quiet dark disc, the call disc is the gold-filled one —
    // bigger, glowing, the obvious primary action.
    final d = filled ? 54.0 : 44.0;
    return Tooltip(
      message: label,
      child: GestureDetector(
        onTap: () {
          HapticService.lightImpact();
          onTap();
        },
        child: Container(
          width: d,
          height: d,
          decoration: filled
              ? BoxDecoration(
                  color: _gold,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 6),
                    ),
                  ],
                )
              : BoxDecoration(
                  color: neuSurface,
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: Colors.white.withValues(alpha: 0.10), width: 1),
                ),
          child: Icon(icon, color: filled ? neuBase : _gold, size: d * 0.40),
        ),
      ),
    );
  }

  Widget _sheetAddressRow(IconData icon, String label, String address) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: _gold, size: 16),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                style: const TextStyle(
                  color: Colors.white38,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.6,
                ),
              ),
              const SizedBox(height: 1),
              Text(
                address,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  height: 1.3,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
