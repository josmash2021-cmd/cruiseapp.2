import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../../config/api_keys.dart';
import '../../config/map_theme.dart';
import '../../config/mapbox_config.dart';
import '../../l10n/app_localizations.dart';
import '../../map/camera_action_gate.dart';
import '../../map/driver_road_lock.dart';
import '../../map/map_surface_coordinator.dart';
import '../../map/web_map_view.dart';
import '../../models/lat_lng.dart';
import '../../services/chat_service.dart';
import '../../services/directions_service.dart';
import '../../services/haptic_service.dart';
import '../../services/resilient_position_stream.dart';
import '../../services/socket_service.dart';
import '../../utils/driver_location_settings.dart';
import '../../utils/gps_fix_policy.dart';
import '../../utils/mapbox_safe.dart';
import '../../utils/route_splice.dart';
import '../../utils/smooth_motion.dart';
import '../../widgets/glass_style.dart';
import '../../map/flat_map_projection.dart';
import '../../widgets/smooth_reveal.dart';
import '../../widgets/gold_location_dot.dart';
import '../../widgets/map/circular_pin_renderer.dart';
import '../../widgets/neu_style.dart';
import '../../utils/fix_kinematics.dart';
import 'nav_trip_panel.dart';

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
/// and the driver's gold arrow chased by a 17.5/35° camera.
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
    this.stopLatLng,
    this.stopLabel = '',
    this.stopDone = false,
    this.onArrivedStop,
    this.onSlideFromStop,
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
    this.riderRating,
    this.riderTrips,
    this.riderDays,
    this.riderVerified = false,
    this.receivingRides = true,
    this.lastTrip = false,
    this.supportUnread = 0,
    this.queuedCanceled = false,
    this.onCancelTrip,
    this.onToggleReceiving,
    this.onToggleLastTrip,
    this.onNoShow,
    this.onSafety,
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

  /// The booking-time (or mid-trip) stop. On the dropoff leg the route runs
  /// through it as a waypoint (one continuous line, and Mapbox's steps carry
  /// the "arrive at the stop" maneuver) and it gets the flag pin.
  final LatLng? stopLatLng;
  final String stopLabel;

  /// The driver left the stop ("Desliza para ir al destino", owner design
  /// 2026-11-02). Until then the dropoff leg ENDS at the stop: route,
  /// approach, "Llegué" and the wait all happen there, as at the pickup.
  final bool stopDone;

  /// "Llegué" at the stop / "Desliza para ir al destino".
  final VoidCallback? onArrivedStop;
  final VoidCallback? onSlideFromStop;

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

  // ── The redesigned panel (owner design 2026-11-02) ──
  final double? riderRating;
  final int? riderTrips;
  final int? riderDays;
  final bool riderVerified;

  /// "Recibiendo viajes" ⇄ "Te has desconectado" in the whole-trip card.
  final bool receivingRides;

  /// "Último viaje" in the trip options: Online ⇄ Offline.
  final bool lastTrip;

  /// Unread messages from support, on the support button.
  final int supportUnread;

  /// "Viaje en cola cancelado" is up (the parent holds it for 7 s).
  final bool queuedCanceled;

  final VoidCallback? onCancelTrip;
  final VoidCallback? onToggleReceiving;
  final VoidCallback? onToggleLastTrip;

  /// The free wait is over and the rider never came (the red slider).
  final VoidCallback? onNoShow;

  /// "Seguridad y soporte" (911 first) — the shield on the map, since the
  /// trip page that carried it goes away (owner 2026-11-02).
  final VoidCallback? onSafety;

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
  // Traffic lights and stop signs get their own layer too (owner 2026-11-02,
  // "se ve muy mal la ruta completa con todos esos semáforos… como se ve en
  // Lyft"): it shows only close in — hidden in the route overview and below
  // [_kSignsMinZoom] — like Lyft and Google, where the overview is clean.
  mapbox.PointAnnotationManager? _signMgr;
  static const double _kSignsMinZoom = 14.5;
  bool? _signsShown;

  /// The arrow's drawn position after route projection (user report
  /// 2026-10-02, same "se sale de las líneas" as the online map): each fix's
  /// TARGET is already projected onto the route line, but the engine's
  /// extrapolated lead runs past it between fixes and the arrow leaves the
  /// road. Refreshed at dot-tick rate and consumed by the annotation write
  /// and the chase camera, so every rendered thing rides the line.
  LatLng? _renderPos;
  final DriverRoadLock _roadLock = DriverRoadLock();
  double? _roadLockBearing;
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.PointAnnotation? _driverAnnot;
  mapbox.PointAnnotation? _destAnnot;
  // The booking/mid-trip stop pin (flag pin like the dropoff) — only on
  // the dropoff leg; on the pickup leg it is nobody's business yet.
  mapbox.PointAnnotation? _stopAnnot;
  bool _annotWriteBusy = false;
  // Every annotation pigeon call is bounded by this (audit D1): a call the
  // dead PlatformView never answers must not hold the latch above forever.
  static const _annotIpcTimeout = Duration(milliseconds: 1500);
  // Audit D2: 2 s watchdog, twin of the online controller's
  // _startDotWatchdog — late/failed raster, a create that threw.
  Timer? _arrowWatchdog;
  // Audit D7: while following, the arrow is the Flutter vector overlay at
  // the camera focus; the native annotation lives only in freeLook /
  // overview / recentering. The overlay covers the handoff until the
  // native one exists (never a frame with no arrow).
  bool _arrowHandoffPending = false;
  Timer? _arrowHandoffTimer;
  // Last values actually sent to the native annotation — a parked car pays
  // zero channel writes (same discipline as the accept screen's mini car).
  double? _lastSentLat;
  double? _lastSentLng;
  double? _lastSentBearing;

  // ── Driver marker: the same GoldLocationDot + SmoothMotion as the online
  //    map. onTick (throttled) writes the annotation; onFrame chases. ──
  final GoldLocationDot _dot = GoldLocationDot(heading: true);
  final GpsFixPolicy _gpsFixPolicy = GpsFixPolicy();

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
  final CameraActionGate _cameraActionGate = CameraActionGate();
  bool _overview = false;
  int _mapPointers = 0;
  mapbox.CameraOptions? _pendingCamWrite;
  bool _camWriteBusy = false;
  // Audit D4: recenter is a per-frame blend from the pose the camera had
  // to the live chase pose (~600 ms, eased), on its own ticker so a parked
  // car blends too, cancelled by any gesture through the action gate.
  Ticker? _recenterTicker;
  mapbox.CameraState? _recenterFrom;
  Duration? _recenterStartedAt;
  int _recenterSeq = -1;
  // The glide INTO the route overview: from the chase pose to a flat,
  // north-up frame of the whole route.
  Ticker? _overviewTicker;
  mapbox.CameraState? _overviewFrom;
  ({LatLng center, double zoom})? _overviewTo;
  Duration? _overviewStartedAt;
  int _overviewSeq = -1;
  // The route overview and the way back to the chase glide the same,
  // frame by frame (owner 2026-11-02: "debe de moverse de forma smooth y no
  // tan de golpe, al igual cuando regresa a la vista chase" — and then, at
  // 1.1 s easeInOutCubic, "sigue muy rápido"): 1.6 s on a sine ease, whose
  // middle runs at about half the cubic's peak speed. It was 0.6 s back and
  // a native 0.9 s flyTo out.
  static const _recenterBlendMs = 1600;
  static const Curve _camGlideCurve = Curves.easeInOutSine;

  // Dynamic chase zoom: 16.8 at city pace, 16.3 past 20 m/s, 17.3 with a
  // maneuver under 150 m — lerped at ≤0.5 zoom/sec, never a step. Owner
  // request 2026-11-02 (screenshot: "como esta foto 2"): less tilt and a
  // little further out, so more of the road ahead is on screen — replaces
  // the 17.5 / 55 pose of 2026-10-28 (audit D6).
  double _chaseZoom = 16.8;
  static const _chaseZoomDefault = 16.8;
  static const _chaseZoomFast = 16.3;
  static const _chaseZoomManeuver = 17.3;
  static const _zoomLerpPerSec = 0.5;
  // Chase tilt: 45° (same owner request as the zoom above).
  static const _chasePitch = 45.0;

  // Top-down at the point (owner design 2026-11-02, drawings 7 and 10):
  // ~200 m from the pickup or the stop, and while waiting there, the camera
  // straightens to look straight down — smoothly, without turning; leaving,
  // it tilts back behind the car the same way. A time-based ease, so a
  // parked car (no dot frames) still glides: the settle ticker drives it.
  static const _pitchGlideMs = 1400;
  double _pitch = _chasePitch;
  double _pitchFrom = _chasePitch;
  double _pitchTo = _chasePitch;
  DateTime? _pitchSince;

  bool get _pitchGliding => _pitchSince != null;

  double get _pitchTarget {
    switch (_panelStage) {
      case NavPanelStage.approaching:
      case NavPanelStage.waitingPickup:
      case NavPanelStage.waitingStop:
        return 0.0;
      case NavPanelStage.driving:
      case NavPanelStage.arrivedDropoff:
        return _chasePitch;
    }
  }

  /// Starts a glide when the target changed; advances the live pitch.
  void _stepPitch() {
    final target = _pitchTarget;
    if (target != _pitchTo) {
      _pitchFrom = _pitch;
      _pitchTo = target;
      _pitchSince = DateTime.now();
    }
    final since = _pitchSince;
    if (since == null) return;
    final t = (DateTime.now().difference(since).inMilliseconds / _pitchGlideMs)
        .clamp(0.0, 1.0);
    _pitch = _pitchFrom + (_pitchTo - _pitchFrom) * Curves.easeInOutCubic.transform(t);
    if (t >= 1.0) {
      _pitch = _pitchTo;
      _pitchSince = null;
    }
  }

  /// A stage or phase change may move the pitch target: wake the settle
  /// ticker so the glide runs even with the car parked.
  void _syncPitch() {
    if (_pitchTarget == _pitchTo) return;
    _stepPitch();
    _ensureCamSettle();
  }

  // Owner request 2026-10-30: "la flecha un poco más grande" on the
  // navigation map — overlay and native annotation alike.
  static const double _kNavArrowScale = 1.2;

  // The map turns WITH the arrow, frame for frame (owner 2026-11-02: "que
  // gire junto con la cámara… no modo resorte… no que gire y se devuelva").
  // The 2026-10-30 damped spring kept the map ~1 s behind the arrow, so at
  // every turn the arrow swung on screen and swung back as the map caught
  // up. A kink in the route no longer whips the map because the arrow's own
  // heading is continuous now (_navAimBearing) and glides at ≤ 120°/s.
  // Null bearing = snap on the next frame.
  double? _camBearing;
  double _camBearingVel = 0;
  final ValueNotifier<double> _arrowScreenBearing = ValueNotifier<double>(0);
  Ticker? _camSettleTicker;
  Duration _camSettleLast = Duration.zero;
  DateTime _lastChaseFrameAt = DateTime.fromMillisecondsSinceEpoch(0);

  static double _shortestArc(double from, double to) {
    var d = (to - from) % 360;
    if (d > 180) d -= 360;
    if (d < -180) d += 360;
    return d;
  }

  bool get _camBearingSettled {
    final cur = _camBearing;
    if (cur == null) return true;
    return _shortestArc(cur, _dot.bearing).abs() < 0.1 &&
        _camBearingVel.abs() < 0.5;
  }

  /// Bottom inset of the chase camera (owner 2026-11-02: an open panel
  /// "no puede tapar la ruta o la flecha, se acomoda"): when the panel's top
  /// would come within ~70 px of the arrow, the focus rises by exactly that
  /// much. It follows the panel's height, which glides frame by frame, so
  /// the map lifts in step with it; closed, it is 0.
  double get _camBottomPad {
    final mq = MediaQuery.maybeOf(context);
    if (mq == null || _panelH <= 0) return 0;
    final h = mq.size.height;
    final focus = h / 2 + (mq.padding.top + 240) / 2;
    final want = h - _panelH - 70;
    return math.max(0.0, 2 * (focus - want));
  }

  /// The camera carries the arrow's bearing exactly, frame for frame: on
  /// screen the arrow always points up and the map does the turning.
  double _followCamBearing(double bearing) {
    _snapCamBearing(bearing);
    return _camBearing!;
  }

  /// Camera pinned straight to the arrow (snaps, recenter blend end).
  void _snapCamBearing(double bearing) {
    _camBearing = bearing % 360;
    _camBearingVel = 0;
    _arrowScreenBearing.value = 0;
  }

  void _ensureCamSettle() {
    if (_camBearingSettled && !_pitchGliding) return;
    final t = _camSettleTicker ??= createTicker(_onCamSettleTick);
    if (!t.isActive) {
      _camSettleLast = Duration.zero;
      t.start();
    }
  }

  void _onCamSettleTick(Duration elapsed) {
    final dt = _camSettleLast == Duration.zero
        ? 0.0
        : ((elapsed - _camSettleLast).inMicroseconds / 1e6).clamp(0.0, 0.05);
    _camSettleLast = elapsed;
    if (!mounted ||
        _camState != _CamState.following ||
        _overview ||
        !_mapMounted ||
        (_camBearingSettled && !_pitchGliding)) {
      _camSettleTicker?.stop();
      return;
    }
    // The dot's own frames drive the chase while it moves.
    if (DateTime.now().difference(_lastChaseFrameAt) <
        const Duration(milliseconds: 40)) {
      return;
    }
    if (dt > 0) _chaseFrame(dt);
  }

  // ── Route + maneuvers ──
  List<LatLng> _routePts = [];

  // ── Route erase (user spec 2026-09-19): the line is eaten behind the car
  // as the driver advances — monotonic forward only, so a jittery fix can
  // never regrow it. Trimmed off the dot's ANIMATED position (throttled to
  // ~2.5 writes/s) so the erase rides the glide with no steps and no delay.
  double _trimS = 0;
  DateTime _lastTrimAt = DateTime(2000);

  // ── The next leg and the departure (owner design 2026-11-02, drawing 10):
  // the stretch after this one (pickup → stop/destination, stop →
  // destination) shows in faded gold; when the leg flips its geometry seeds
  // the new route at once — the map is never left without a line — and the
  // new line draws itself out from the car over 1.4 s.
  List<LatLng> _nextLegPts = [];
  mapbox.PolylineAnnotation? _nextLegAnnot;
  int _nextLegSeq = 0;
  bool _drawOnNext = false;
  Timer? _drawOnTimer;
  DateTime? _drawOnUntil;
  static const _drawOnMs = 1400;
  static const _nextLegAlpha = 0x73; // the accepted-trip overlay's faded gold

  // ── Traffic lights / stop signs (user spec 2026-09-19): parsed off the
  // Mapbox intersections, drawn as upright icons on the shared pins manager
  // (viewport-aligned — they never lie down with the chase), and eaten by
  // the same trim cursor as the line — a sign the driver passed disappears
  // with the stretch of road behind him.
  List<_NavSign> _furniture = [];
  Uint8List? _signalBytes;
  Uint8List? _stopBytes;
  double _routeLenM = 0;
  NavProgress? _navProgress;
  bool _routeFetching = false;
  String _streetLabel = '';
  String _thenLabel = '';
  // The step after the current one, for the banner's gold "Luego" tab:
  // its street (or instruction) and the maneuver that draws its icon.
  String _thenText = '';
  String _thenType = '';
  String _thenModifier = '';
  String _maneuverDistLabel = '';
  // The trip guide (owner design 2026-11-02): the maneuver box unfolds
  // into every turn left on the leg; its X folds it back.
  bool _guideOpen = false;
  // 0 = the turn box, 1 = the guide unfolded. Two steps, in order (owner
  // 2026-11-02: "primero se esconde la parte amarilla y luego sale lo
  // demás"): the gold tab tucks away, then the box grows down with the
  // list; folding plays the same steps backwards.
  late final AnimationController _guideCtrl = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 560));
  static const double _kGuideTuckEnd = 0.32;
  double get _guideTuck => kSmoothRevealCurve
      .transform((_guideCtrl.value / _kGuideTuckEnd).clamp(0.0, 1.0));
  double get _guideGrow => kSmoothRevealCurve.transform(
      ((_guideCtrl.value - _kGuideTuckEnd) / (1 - _kGuideTuckEnd))
          .clamp(0.0, 1.0));
  String _instructionLabel = '';
  String _maneuverType = 'depart';
  String _maneuverModifier = '';
  String _maneuverExit = ''; // structured maneuver.exit when Mapbox has it
  double _speedMps = 0;
  // Where the fix stood when the arrow's heading was last set — the anchor
  // the stoplight heading-freeze measures genuine movement against.
  LatLng? _headingSetAt;
  int _lastMphShown = -1;
  // When the speed was last measured, and whether the box gave up on it.
  DateTime _speedAt = DateTime.fromMillisecondsSinceEpoch(0);
  bool _speedStale = false;
  int _remainSecs = 0;
  double _remainMeters = 0;

  // ── Navigation state machine ──
  _NavPhase _navPhase = _NavPhase.initializing;

  // Off-route: >25 m from the line held for 600 ms of fixes arms a reroute;
  // back within 20 m resets the clock. One request in flight, 4 s cooldown,
  // and a sequence token so a stale response can never replace a newer plan.
  DateTime? _offRouteSince;
  int _rerouteSeq = 0;
  DateTime? _lastRerouteAt;
  bool _rerouting = false;
  // Off-route rerouting (user spec 2026-09-27: "redireccionar de forma
  // instantanea y agradable"): 25 m off the polyline held for 600 ms of
  // fixes arms the fetch (reset the moment a fix lands back within 20 m),
  // 4 s between fetches — under the 30 m accuracy gate that keeps GPS noise
  // from arming it. The landing stays smooth (_flyToChasePose 600 ms).
  static const _offRouteM = 25.0;
  static const _offRouteResetM = 20.0;
  static const _offRouteHoldMs = 600;
  static const _rerouteCooldownSecs = 4;
  static const _prefetchDestMaxM = 150.0;

  // Internal arrival: approaching under 200 m; arrived after 2 consecutive
  // fixes under 30 m with accuracy better than 25 m (3 fixes on distance
  // alone when the fix carries no accuracy). UI state only — the parent's
  // sliders stay the trip-flow authority.
  int _arriveHits = 0;
  bool _navArrived = false;
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
  // Tunnel mode (owner request 2026-10-29, "como Google"): with no fix for
  // 1.5 s while on the route and moving, the arrow keeps driving ALONG THE
  // ROUTE at the last speed — virtual fixes every 0.5 s, up to 30 s. The
  // first real fix takes over. Off-route or slower than 3 m/s: no guessing.
  Timer? _tunnelTimer;
  DateTime? _lastUsableFixAt;
  LatLng? _tunnelAnchor;
  DateTime? _tunnelAnchorAt;
  double _tunnelSpeed = 0;
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

  ResilientPositionStream? _gps;
  StreamSubscription? _riderLocSub;
  WebMapController? _webMap;

  // The redesigned bottom panel (owner design 2026-11-02): its height on
  // screen (the map controls and the overlay arrow ride on it), whether it
  // is open, and whether the car counts as driving — driving, opening it
  // gives only the trip options.
  double _panelH = 0;
  // The panel's height at rest: the mph and the map buttons stay above it
  // while the panel opens over them (the camera still follows [_panelH]).
  double _panelRestH = 0;
  bool _panelMoving = false;
  DateTime? _stillSince;
  late final Stream<int> _chatUnread = ChatService().unreadCountStream(
    rideId: widget.tripId.toString(),
    readerRole: 'driver',
  );

  /// The rider is aboard and the stop is still ahead: this leg ends there.
  bool get _stopLeg =>
      !widget.toPickup && widget.stopLatLng != null && !widget.stopDone;

  LatLng get _dest => widget.toPickup
      ? widget.pickupLatLng
      : (_stopLeg ? widget.stopLatLng! : widget.dropoffLatLng);

  /// The waypoint the dropoff leg runs through — none once the stop is the
  /// destination itself, or already behind.
  LatLng? get _routeStop =>
      widget.toPickup || widget.stopDone || _stopLeg ? null : widget.stopLatLng;

  /// End Route appears once the driver has arrived — by the nav view's own
  /// arrival latch or by any post-arrival stage the parent reports. Never
  /// mid-drive (the old early "Desliza para terminar" at 58 m).
  bool get _endRouteVisible =>
      _phaseArrived ||
      widget.stage == 'arrived' ||
      widget.stage == 'waiting_rider' ||
      widget.stage == 'start_ride' ||
      widget.stage == 'stop_near' ||
      widget.stage == 'stop_waiting' ||
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
    // The nav marker is the ONE thing the driver watches continuously on a
    // full-screen map (user spec 2026-09-27: "el movimiento de la flecha
    // muchisimo mas smooth") — annotation writes at ~60 fps here; every
    // other screen keeps the 33 ms default.
    _dot.minTickIntervalMs = 16;
    // Drives the marker and hands the per-frame callbacks: onTick writes the
    // annotation (throttled by GoldLocationDot), onFrame chases the camera.
    _dot.build(this, _onDotTick, onFrame: _onDotFrame);
    // The offer-preview shrink (0.8) is shared and animated on the ONLINE
    // screen's ticker, which is muted once the trip screen covers it — the
    // grow-back could stall mid-way and the nav arrow opened small. The
    // navigation always shows it full size.
    GoldLocationDot.animateOfferMarkerScale(this, 1.0, durationMs: 0);
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _syncPitch();
    });
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
    } else if (oldWidget.stopLatLng != widget.stopLatLng ||
        oldWidget.stopDone != widget.stopDone) {
      // A stop appeared (or moved) mid-drive, or the driver left it — the
      // route re-fetches from the car, same path as a destination change.
      _onDestinationChanged();
    }
  }

  @override
  void dispose() {
    _guideCtrl.dispose();
    WidgetsBinding.instance.removeObserver(this);
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    unawaited(_gps?.stop());
    _gpsWatchdog?.cancel();
    _tunnelTimer?.cancel();
    _offlineRetryTimer?.cancel();
    _riderLocSub?.cancel();
    _riderStaleTimer?.cancel();
    _waitTicker?.cancel();
    _drawOnTimer?.cancel();
    _arrowWatchdog?.cancel();
    _arrowHandoffTimer?.cancel();
    _recenterTicker?.dispose();
    _overviewTicker?.dispose();
    _riderTicker?.dispose();
    _camSettleTicker?.dispose();
    _arrowScreenBearing.dispose();
    _dot.dispose();
    _roadLock.reset();
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
    _syncPitch();
    // User spec 2026-09-27: arrival does NOT auto-raise the sheet anymore —
    // the face keeps its collapsed summary and the driver drags it up by
    // hand to reach the gold I've-arrived button (which still crossfades in
    // via _endRouteVisible).
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
        _signMgr = null;
        _signsShown = null;
        _carMgr = null;
        _circleMgr = null;
        _routeAnnot = null;
        _nextLegAnnot = null;
        _drawOnTimer?.cancel();
        _drawOnUntil = null;
        _driverAnnot = null;
        _destAnnot = null;
        _stopAnnot = null;
        _riderHaloAnnot = null;
        _riderDotAnnot = null;
        // The signs' handles died with the surface too — null them so the
        // redraw in _onMapCreated recreates them instead of skipping the
        // lot as "already drawn" (user report 2026-09-23, "no aparecen").
        for (final sign in _furniture) {
          sign.annot = null;
        }
        _lastSentLat = null;
        _lastSentLng = null;
        _lastSentBearing = null;
        // The in-flight annotation write died with the channel too — a
        // latch left true here kept every later tick out of
        // _updateDriverAnnotation for the life of the view (audit D1).
        _annotWriteBusy = false;
        _arrowWatchdog?.cancel();
        _arrowHandoffTimer?.cancel();
        _arrowHandoffPending = false;
        // A recenter blend mid-flight has no camera left to blend.
        _recenterTicker?.stop();
        _stopOverviewGlide();
        _recenterFrom = null;
        _recenterStartedAt = null;
        if (_camState == _CamState.recentering) {
          _camState = _CamState.following;
        }
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

  /// Nav-view road labels (user spec 2026-09-19): street names big enough
  /// to READ at speed — Google-style size + halo. The map style's own
  /// traffic-light / stop-sign layers are NOT enabled here: those render
  /// network-wide, but the product rule is route-only signals (user report
  /// 2026-09-25) — the parsed furniture set handles those, on the line only.
  Future<void> _applyNavRoadFurniture(mapbox.MapboxMap m) async {
    for (final l in const [
      'road-label',
      'road-label-navigation',
      'road-label-simple',
    ]) {
      try {
        await m.style.setStyleLayerProperty(l, 'text-size', 15.0);
        await m.style.setStyleLayerProperty(l, 'text-color', '#C9D2E8');
        await m.style.setStyleLayerProperty(l, 'text-halo-color', '#0A1128');
        await m.style.setStyleLayerProperty(l, 'text-halo-width', 1.2);
      } catch (_) {}
    }
  }

  Future<void> _onMapCreated(mapbox.MapboxMap ctrl) async {
    _map = ctrl;
    // Each call stands alone so one refusal does not skip the rest.
    for (final step in <Future<void> Function()>[
      () =>
          ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false)),
      () => ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false)),
      () => _showMapBrand(ctrl),
    ]) {
      try {
        await step();
      } catch (_) {}
    }
    _polyMgr = await ctrl.annotations.createPolylineAnnotationManager();
    _pointMgr = await ctrl.annotations.createPointAnnotationManager();
    // Under the car, over the line.
    _signMgr = await ctrl.annotations.createPointAnnotationManager();
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
    try {
      final lid = _signMgr!.id;
      await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
      // Zoomed out by hand: gone below the street zoom.
      await ctrl.style.setStyleLayerProperty(lid, 'minzoom', _kSignsMinZoom);
      await ctrl.style.setStyleLayerProperty(
          lid, 'icon-opacity-transition', {'duration': 400, 'delay': 0});
    } catch (_) {}
    unawaited(_syncSignsShown());
    // A recreated surface (app backgrounded on Android) loses everything —
    // redraw the route and destination pin from the State that survived.
    await _drawRoute();
    await _drawDestPin();
    // The faded next leg (owner design 2026-11-02) — fetched once the map
    // can draw it; its geometry also seeds the next leg's line at the flip.
    unawaited(_loadNextLeg());
    // The signs as well (user report 2026-09-23, "no aparecen los stops y
    // los semaforos"): a surface rebirth left them on dead handles, and a
    // route/steps fetch that won the race against this setup bailed on the
    // null manager — the list is populated either way, so draw what is
    // missing. Signs already drawn are skipped inside.
    unawaited(_drawFurniture());
    // The driver arrow is created EAGERLY (user spec 2026-09-16): the dot's
    // ticker only fires while the car moves, so a parked driver used to get
    // no annotation at all — the arrow simply never appeared.
    unawaited(_updateDriverAnnotation());
    // And a 2 s watchdog behind it (audit D2) — late/failed raster, a
    // create that threw, a surface rebirth: nothing else retries them
    // while the car is parked.
    _startArrowWatchdog();
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
    // A restart keeps the position the dot already has. Snapped onto the
    // route like every later fix (2026-09-19) — the nav opens with the
    // arrow ON the line, never floating in the pickup's block.
    if (_dot.lat == null) {
      final seed = _snapToNavRoute(widget.initialDriverPos);
      if (seed != null) {
        _dot.setTarget(
          seed.latitude,
          seed.longitude,
          timestampMs: DateTime.now().millisecondsSinceEpoch.toDouble(),
        );
      }
    }
    // Aim down-route from the very first frame: the GPS heading at 0 mph is
    // noise, so the opening arrow (and chase camera) takes the route
    // tangent instead (user spec 2026-09-16).
    final h = _routeHeadingFor(widget.initialDriverPos);
    if (h != null) {
      _dot.setBearing(h);
      _headingSetAt = widget.initialDriverPos;
    }
    // The map can be created before this post-frame seed: its own chase
    // write then found no dot and bailed. Aim it at the seed now.
    _snapToChasePose();
    _lastGpsFixAt = DateTime.now(); // warm-up grace for the first fix
    _armGpsWatchdog();
    _tunnelTimer?.cancel();
    _tunnelTimer = Timer.periodic(
        const Duration(milliseconds: 500), (_) => _tunnelTick());
  }

  void _tunnelTick() {
    if (!mounted) return;
    // A speed nobody re-measured for 3 s is not a speed (owner 2026-11-02):
    // with no fixes the box froze on the last number — 45 mph through a
    // tunnel or after the signal died. It reads "–" until a fix measures
    // again. Stopped stays 0: iOS pauses the fixes of a parked car.
    if (!_speedStale &&
        _speedMps > 0 &&
        DateTime.now().difference(_speedAt) > const Duration(seconds: 3)) {
      setState(() => _speedStale = true);
    }
    final still = _stillSince;
    if (_panelMoving &&
        still != null &&
        DateTime.now().difference(still) > const Duration(seconds: 3)) {
      setState(() => _panelMoving = false);
    }
    final last = _lastUsableFixAt ?? _lastGpsFixAt;
    final pts = _routePts;
    final now = DateTime.now();
    if (last == null || pts.length < 2) {
      _tunnelAnchor = null;
      return;
    }
    final age = now.difference(last);
    if (age < const Duration(milliseconds: 1500) ||
        age > const Duration(seconds: 30)) {
      if (age < const Duration(milliseconds: 1500)) _tunnelAnchor = null;
      return;
    }
    if (_tunnelAnchor == null) {
      final lat = _dot.lat, lng = _dot.lng;
      final speed = _speedMps;
      if (lat == null || lng == null || speed < 3) return;
      final here = LatLng(lat, lng);
      if (RouteSplice.distanceToPolylineM(pts, here) > 40) return;
      _tunnelAnchor = here;
      _tunnelAnchorAt = now;
      _tunnelSpeed = speed;
      debugPrint('[DriverNav] no GPS — following the route at '
          '${speed.toStringAsFixed(1)} m/s');
    }
    final sec = now.difference(_tunnelAnchorAt!).inMilliseconds / 1000.0;
    final step = RouteSplice.pointAlong(pts, _tunnelAnchor!, _tunnelSpeed * sec);
    if (step == null) return;
    _dot.setTarget(step.$1.latitude, step.$1.longitude,
        bearing: step.$2, accuracyM: 10, speedMps: _tunnelSpeed);
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

  /// The fix's Doppler speed when the platform measured it and vouches for
  /// it: a reported speed accuracy worse than 2.5 m/s (~6 mph) is noise.
  double? _trustedSpeedMps(Position pos) {
    final s = measuredSpeedMps(pos);
    if (s == null) return null;
    final acc = pos.speedAccuracy;
    if (acc.isFinite && acc > 2.5) return null;
    return s;
  }

  /// The one writer of the speed readout. Deadband at 0.9 m/s (~2 mph):
  /// under that the car is stopped and the box reads 0 THE SAME fix.
  void _setSpeed(double mps) {
    _speedMps = mps < 0.9 ? 0.0 : mps;
    _speedAt = DateTime.now();
    // Driving vs parked for the panel (owner design 2026-11-02): driving
    // from ~5 mph; parked once it has been under 2 mph for ~3 s — the
    // tunnel tick settles that, since a parked iPhone stops sending fixes.
    if (_speedMps >= 2.2) {
      _stillSince = null;
      if (!_panelMoving) setState(() => _panelMoving = true);
    } else if (_speedMps < 0.9) {
      _stillSince ??= DateTime.now();
    }
    final mph = (_speedMps * 2.23694).round();
    if (mph != _lastMphShown || _speedStale) {
      _lastMphShown = mph;
      _speedStale = false;
      setState(() {}); // the mph box is the only reader
    }
  }

  void _onGpsFix(Position pos) {
    if (!mounted || !_gpsFixPolicy.accept(pos)) return;
    _lastGpsFixAt = DateTime.now();
    if (_gpsDown) {
      _gpsDown = false;
      _recomputeNavPhase();
    }
    // Speed before the position gate (owner 2026-11-02, "la velocidad exacta
    // … sin fallas ni error"): the satellites' Doppler speed is measured
    // apart from the position, so a fix whose POSITION is poor (> 30 m, a
    // street between tall buildings) still carries a good speed — the gate
    // below dropped it and the box froze on an old number.
    final measuredSpeed = _trustedSpeedMps(pos);
    // 30 m accuracy gate (audit extra; was 65): a fix that declares itself
    // worse must not steer the chase, the trim, the off-route check or the
    // arrival latch — with the arrow snapped to the line, a 65 m fix only
    // yanked the road-lock bearing around at crossings.
    if (pos.accuracy > 30) {
      if (measuredSpeed != null) _setSpeed(measuredSpeed);
      return;
    }
    // Tunnel mode keys on USABLE fixes: a stream of > 30 m fixes kept
    // _lastGpsFixAt fresh and the tunnel never engaged (review 2026-10-30).
    _lastUsableFixAt = DateTime.now();
    _tunnelAnchor = null; // a real fix ends tunnel mode
    final fixLL = LatLng(pos.latitude, pos.longitude);
    // Display vs measurement (user specs 2026-09-19, "la flecha fuera de
    // las lineas del mapa", y 2026-09-27, "la flecha no puede salirse de
    // las lineas"): the arrow rides the route LINE — a house driveway or a
    // parking lot is genuinely off the road, and the raw fix floating in a
    // block reads as a bug. The DISPLAY target is ALWAYS the projection on
    // the line now. Everything that MEASURES keeps the raw fix: the
    // off-route check (which answers "did he take the exit or not" in real
    // time), the trim cursor and the arrival latch.
    final display = _snapToNavRoute(fixLL);
    // On the route, the tangent below is the arrow's ONLY compass (user
    // spec 2026-09-19, "que gire fluido, no de golpe"): GPS headings arrive
    // once a second and the lerp chased them in steps through every curve —
    // the tangent is continuous geometry, so the arrow and with it the
    // chase camera sweep with the road itself. The fix's own heading only
    // speaks off-route, where a tangent means nothing.
    final onRoute = _routePts.length >= 2 &&
        RouteSplice.distanceToPolylineM(_routePts, fixLL) <= 40;
    if (display != null) {
      _dot.setTarget(
        display.latitude,
        display.longitude,
        bearing: onRoute ? _navAimBearing(display) : measuredCourseDeg(pos),
        accuracyM: pos.accuracy,
        timestampMs: pos.timestamp.millisecondsSinceEpoch.toDouble(),
        // The fix's own speed reading parks the arrow against GPS wander —
        // a parked driver's position jumps but his speed keeps reading ~0.
        // Measured only — Android's Doppler-less 0 is "unknown" (2026-10-29).
        speedMps: measuredSpeedMps(pos),
      );
    }
    // Speed readout (user spec 2026-09-27 — "tiene que ser instantaneo y en
    // tiempo real"): the platform speed when the fix carries one; iOS
    // reports -1 when it has none, so fall back to the smoother's own
    // measured glide speed instead of lying with a 0. Deadband at 0.9 m/s
    // (~2 mph): under that the car is stopped and the box must read 0 THE
    // SAME fix — the old 0.45 floor let a stop sit at 7-10 mph while the
    // extrapolated glide bled off.
    _setSpeed(measuredSpeed ?? _dot.speedMps);
    _updateManeuvers(fixLL);
    // Route-tangent heading at EVERY speed while on-route (see above).
    if (onRoute) {
      final h = _routeHeadingFor(fixLL);
      if (h != null) {
        if (_speedMps < 1.0) {
          // Heading freeze (user report: "parado en el semaforo, sin haber
          // girado, la flecha ya se puso de lado y la camara giro"): a
          // parked car keeps its last moving heading — the route's next
          // turn is not the driver's turn yet, and the tangent crosses the
          // corner long before he does. The only escape: a fix that has
          // genuinely MOVED from where the heading was last set — a crawl
          // the speed channel has not confirmed yet — re-aims once and
          // re-anchors. GPS wander rotates in place and never crosses it.
          final anchor = _headingSetAt;
          if (anchor != null && RouteSplice.haversineM(anchor, fixLL) > 10) {
            _dot.setBearing(h);
            _headingSetAt = fixLL;
          }
        } else {
          _dot.setBearing(h);
          _headingSetAt = fixLL;
        }
      }
    }
    _checkArrival(pos);
    _checkOffRoute(fixLL);
  }

  /// The arrow's DISPLAY position: ALWAYS the nearest point on the drawn
  /// route (user spec 2026-09-27: "la flecha no puede estar fuera de las
  /// lineas") — any distance, no gate, so through curves and crossings the
  /// arrow rides the line and turns with it in real time. The off-route
  /// CHECK still reads the raw fix: the instant the driver misses an exit,
  /// ramp or crossing, the 25 m / 600 ms hold fires the reroute, the
  /// Rerouting pill tells him clearly, and the fresh line replaces under
  /// the arrow — so "did he take it or not" is answered in real time by
  /// the line itself, never by the arrow lying off-road.
  LatLng? _snapToNavRoute(LatLng p) {
    final result = _roadLock.project(_routePts, p, speedMps: _speedMps);
    _roadLockBearing = result.trusted ? result.bearing : null;
    return result.point;
  }

  double? _routeHeadingFor(LatLng pos) {
    return _roadLock.project(_routePts, pos, speedMps: _speedMps).bearing;
  }

  /// Where the arrow points on the route while moving (owner 2026-11-02,
  /// "que gire fluido… no que gire y se devuelva"): the chord to a point a
  /// little ahead ALONG the line, through corners too. The road-lock
  /// heading stops at a corner and jumped by the whole corner angle the
  /// moment the car passed the vertex; this one turns continuously over the
  /// last metres before it. Below 2 m/s it keeps the road-lock heading, so
  /// a car waiting at a light before a turn never pre-rotates.
  double? _navAimBearing(LatLng onLine) {
    if (_routePts.length < 2 || _speedMps < 2.0) return _roadLockBearing;
    final ahead = (_speedMps * 1.0).clamp(8.0, 30.0).toDouble();
    final step = RouteSplice.pointAlong(_routePts, onLine, ahead);
    if (step == null || RouteSplice.haversineM(onLine, step.$1) < 3) {
      return _roadLockBearing;
    }
    final b = Geolocator.bearingBetween(onLine.latitude, onLine.longitude,
        step.$1.latitude, step.$1.longitude);
    return (b + 360) % 360;
  }

  /// Where the opening camera centres: the arrow itself — the seeded dot,
  /// or the driver's last known position projected onto the route — never
  /// the raw fix, which a parked car can have tens of metres off the road.
  LatLng get _openCameraPos {
    final lat = _dot.lat;
    final lng = _dot.lng;
    if (lat != null && lng != null) return LatLng(lat, lng);
    return _roadLock.project(_routePts, widget.initialDriverPos).point ??
        widget.initialDriverPos;
  }

  /// Approaching under 200 m; arrived after consecutive close fixes — with
  /// real accuracy (2 fixes, accuracy < 25 m) or without it (3 fixes on
  /// distance alone). Fires NO backend transition: it only moves the nav UI
  /// to its arrived banner; the parent's sliders stay the authority.
  void _checkArrival(Position pos) {
    if (_navArrived) return;
    final d =
        RouteSplice.haversineM(LatLng(pos.latitude, pos.longitude), _dest);
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
      // Aim the arrow at the client's spot, deterministically (user report
      // 2026-09-19, "ese carrito no puede estar"): parked, iOS pauses GPS
      // updates and the arrow froze at whatever the LAST DRIVING heading
      // was — pointing backwards at the pin reads as a car at an angle.
      // One explicit aim on arrival overrides the frozen compass.
      final d = _driverLatLng();
      final b = Geolocator.bearingBetween(
          d.latitude, d.longitude, _dest.latitude, _dest.longitude);
      if (b.isFinite) _dot.setBearing((b + 360) % 360);
      HapticService.mediumImpact();
      _recomputeNavPhase();
    }
  }

  /// GPS noise never reroutes: the driver must sit more than 25 m off the
  /// polyline for 600 ms of fixes (sampled per fix, reset the moment a fix
  /// lands back within 20 m) before a reroute is even asked for. Possible at
  /// all under the 65 m fix-accuracy gate — without it, a bad-signal day
  /// would arm false reroutes at 25 m. Inside the approach radius there is
  /// nothing to reroute to — the line already ends at the pin.
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
    if (now.difference(_offRouteSince!).inMilliseconds >= _offRouteHoldMs) {
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
      final res = await DirectionsService(ApiKeys.webServices).getSteps(
          origin: origin,
          destination: _dest,
          language: Localizations.localeOf(context).languageCode);
      if (!mounted || res == null || res.steps.length < 2) return;
      _navProgress = NavProgress(res.steps);
      _setRouteFurniture(res.furniture, crossings: res.crossings);
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
    final dist =
        cur == null ? '' : _fmtDist(nav.distanceToCurrentMeters(driverPos), s);
    // The full maneuver instruction ("Take exit 67B on the right onto
    // I-4 W") — what the bar announces on the freeway, where the bare
    // street name says nothing about the exit to take (user report).
    final instruction = cur?.instruction ?? '';
    final thenStep = nav.then;
    final thenText = thenStep == null
        ? ''
        : (thenStep.name.isNotEmpty ? thenStep.name : thenStep.instruction);
    final then = thenText.isEmpty ? '' : '${s.navThen} → $thenText';
    final thenType = thenStep?.maneuverType ?? '';
    final thenModifier = thenStep?.modifier ?? '';

    // Remaining trip — the "9 min · 4.1 mi" of the sheet (user report: "no
    // marca los minutos y millas correctamente").
    //
    // Distance ALONG the route, never the crow-fly to the next maneuver —
    // a curvy road undercounts and a cloverleaf lies outright.
    var meters = _remainingRouteMeters(driverPos);
    var secs = 0;
    if (cur != null) {
      final idx = nav.steps.indexOf(cur);
      if (meters <= 0) {
        // No drawn route to measure along: fall back to the crow-fly sum.
        meters = nav.distanceToCurrentMeters(driverPos);
        for (var i = idx + 1; i < nav.steps.length; i++) {
          meters += nav.steps[i].distanceMeters;
        }
      }
      // Time: the step the driver is ON (idx-1 — steps[idx] begins AT the
      // next maneuver) contributes its remaining fraction, prorated by the
      // share of its road distance still ahead. It used to contribute
      // NOTHING — on a freeway that step is the whole drive, so the ETA
      // read minutes low for the entire trip. Steps from idx on count full.
      final onStep = idx >= 1 ? nav.steps[idx - 1] : null;
      if (onStep != null && onStep.distanceMeters > 1) {
        final frac =
            (nav.distanceToCurrentMeters(driverPos) / onStep.distanceMeters)
                .clamp(0.0, 1.0);
        secs += (onStep.durationSeconds * frac).round();
      }
      for (var i = idx; i < nav.steps.length; i++) {
        secs += nav.steps[i].durationSeconds;
      }
    }

    final type = cur?.maneuverType ?? 'arrive';
    final modifier = cur?.modifier ?? '';
    final exitNum = cur?.exitNumber ?? '';
    if (street == _streetLabel &&
        dist == _maneuverDistLabel &&
        then == _thenLabel &&
        thenType == _thenType &&
        thenModifier == _thenModifier &&
        instruction == _instructionLabel &&
        type == _maneuverType &&
        modifier == _maneuverModifier &&
        exitNum == _maneuverExit &&
        (secs - _remainSecs).abs() < 15) {
      return;
    }
    setState(() {
      _streetLabel = street;
      _maneuverDistLabel = dist;
      _thenLabel = then;
      _thenText = thenText;
      _thenType = thenType;
      _thenModifier = thenModifier;
      _instructionLabel = instruction;
      _maneuverType = type;
      _maneuverModifier = modifier;
      _maneuverExit = exitNum;
      _remainSecs = secs;
      _remainMeters = meters;
    });
  }

  /// Maneuver distance — imperial ALWAYS (user spec 2026-09-19, "en vez de
  /// metros sean millas asi tal cual"): feet under 0.1 mi, miles past it.
  String _fmtDist(double meters, S s) {
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
    _trimS = 0; // fresh geometry restarts the erase cursor
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
      // The stop is the leg's end until the driver leaves it (_dest); a
      // waypoint only when nothing else covers it.
      final stop = _routeStop;
      final result = await DirectionsService(ApiKeys.webServices).getRoute(
        origin: o,
        destination: _dest,
        waypoints: stop == null ? null : [stop],
        // The app's locale, so maneuver instructions ("Take exit 67B…")
        // come back in the driver's language.
        language: Localizations.localeOf(context).languageCode,
        // Reroutes take the fast lane (user report 2026-09-19, "tarda
        // mucho en redireccionar"): Mapbox alone, 5 s cap — the normal
        // race waits for all three providers (up to 8 s) even when one
        // answered long ago. Initial/retry/backgroundFill keep the race.
        fast: kind == _RouteFetchKind.reroute,
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
          _trimS = 0; // fresh geometry restarts the erase cursor
          _routeLenM = newLen;
          await _drawRoute();
        }
        // Furniture lands ALWAYS (user report 2026-09-19, "me quitaste los
        // semaforos"): the dominant path — prefetched geometry, background
        // fill that returns the SAME route — never crossed the 5% gate, and
        // _fillSteps stays parked because the steps already arrived, so the
        // signs silently never drew.
        _setRouteFurniture(result.furniture, crossings: result.crossings);
        break;
      case _RouteFetchKind.reroute:
        // Atomic: state first, then ONE annotation update — the old line is
        // replaced, never doubled, and it stays up for the whole fetch.
        _routePts = result.points;
        _trimS = 0; // fresh geometry restarts the erase cursor
        _routeLenM = _polylineLenM(result.points);
        _navProgress = NavProgress(result.steps);
        await _drawRoute();
        await _drawDestPin();
        _setRouteFurniture(result.furniture, crossings: result.crossings);
        break;
      case _RouteFetchKind.initial:
      case _RouteFetchKind.retry:
        _routePts = result.points;
        _trimS = 0; // fresh geometry restarts the erase cursor
        _routeLenM = _polylineLenM(result.points);
        _navProgress = NavProgress(result.steps);
        await _drawRoute();
        await _drawDestPin();
        _setRouteFurniture(result.furniture, crossings: result.crossings);
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
    // rerouted line can point somewhere new entirely (one deterministic aim
    // when the plan changes, not the stoplight pre-rotation).
    if (_speedMps < 1.0) {
      final h = _routeHeadingFor(origin);
      if (h != null) {
        _dot.setBearing(h);
        _headingSetAt = origin;
      }
    }
    // Same rule as _onMapCreated: chase pose, never a top-down fit — the
    // bounds fit belongs to the overview toggle (user spec 2026-09-16). A
    // reroute GLIDES into the new pose (user spec: "redireccionando rapido
    // y fluido") — a hard camera cut mid-drive reads as the map glitching.
    if (_overview) {
      await _fitRouteOnce();
    } else if (kind == _RouteFetchKind.reroute) {
      unawaited(_flyToChasePose(600));
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
    final idx = _offlineRetryAttempt.clamp(0, _offlineBackoff.length - 1);
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
    _headingSetAt = null; // the new leg re-anchors the heading freeze
    _offlineRetryTimer?.cancel();
    _offlineRetryAttempt = 0;
    _offlineKeepRoute = false;
    _routeError = false;
    _roadLock.reset();
    _routePts = [];
    _trimS = 0; // leg flip: the erase cursor starts over with the new plan
    _routeLenM = 0;
    unawaited(_clearFurniture()); // and the signs of the old leg go with it
    unawaited(_clearRouteAnnotation());
    unawaited(_drawDestPin());
    _recomputeNavPhase();
    _seedPrefetchedRoute();
    // The next leg's geometry, fetched while driving the last one, starts
    // where the car is now: the new line is there at once.
    final next = _nextLegPts;
    if (_routePts.length < 2 &&
        next.length >= 2 &&
        RouteSplice.haversineM(next.last, _dest) <= _prefetchDestMaxM &&
        RouteSplice.haversineM(next.first, _driverLatLng()) <= 300) {
      _routePts = List.of(next);
      _routeLenM = _polylineLenM(_routePts);
    }
    _drawOnNext = true;
    if (_routePts.length >= 2) unawaited(_drawRoute());
    unawaited(_loadRoute());
    unawaited(_loadNextLeg(afterDrawOn: true));
  }

  /// Arc-length of [proj] (projected on segment [seg]) along [pts] from the
  /// route start — the coordinate the trim cursor is measured in.
  double _routeSOf(List<LatLng> pts, int seg, LatLng proj) {
    var s = 0.0;
    for (var i = 0; i < seg; i++) {
      s += RouteSplice.haversineM(pts[i], pts[i + 1]);
    }
    return s + RouteSplice.haversineM(pts[seg], proj);
  }

  /// Distance left to the destination measured ALONG the route polyline
  /// (user report: "no marca los minutos y millas correctamente") — the
  /// crow-fly to the next maneuver undercounts every curve and lies
  /// outright on cloverleaf ramps. 0 when there is no route to measure on.
  double _remainingRouteMeters(LatLng from) {
    final pts = _routePts;
    if (pts.length < 2 || _routeLenM <= 0) return 0;
    final seg = RouteSplice.closestSegmentIndex(pts, from);
    final proj = RouteSplice.projectOnSegment(from, pts[seg], pts[seg + 1]);
    return (_routeLenM - _routeSOf(pts, seg, proj)).clamp(0.0, _routeLenM);
  }

  /// Eats the route line behind [pos]: splices the polyline from the
  /// driver's projection forward and rewrites only the remainder.
  /// Forward-only — the cursor never steps back, so GPS noise never
  /// regrows the line ("se va borrando al mismo tiempo, sin errores").
  void _trimRouteTo(LatLng pos) {
    final pts = _routePts;
    if (pts.length < 2 || _overview) return;
    if (!kIsWeb && _routeAnnot == null) return;
    final now = DateTime.now();
    if (now.difference(_lastTrimAt).inMilliseconds < 400) return;
    final drawOn = _drawOnUntil;
    if (drawOn != null && now.isBefore(drawOn)) return;
    final seg = RouteSplice.closestSegmentIndex(pts, pos);
    final proj = RouteSplice.projectOnSegment(pos, pts[seg], pts[seg + 1]);
    final s = _routeSOf(pts, seg, proj);
    // Gates (user report 2026-09-25, "los semaforos solo salen cerca del
    // carro"): an off-line fix, or a self-crossing street where the car is
    // closest to a segment far ALONG the route, used to drag the cursor
    // hundreds of metres forward in one tick — every sign between the true
    // position and the leap point was permanently eaten, so top-down only
    // showed furniture right where the arrow was about to pass.
    if (RouteSplice.haversineM(proj, pos) > 40) return; // fix off the line
    if (s - _trimS > 150) return; // self-crossing leap: never skip ahead
    if (s < _trimS - 2) return; // backward jitter: keep the longer line
    if (s - _trimS < 1.0) return; // sub-metre forward: not worth a write
    _trimS = s;
    _lastTrimAt = now;
    unawaited(_replaceRouteGeometry([proj, ...pts.sublist(seg + 1)]));
    // The signs are eaten with the line: what the driver already passed
    // disappears with the stretch of road behind him.
    final passed = _furniture.where((e) => e.s < _trimS - 5).toList();
    if (passed.isNotEmpty) {
      _furniture.removeWhere((e) => e.s < _trimS - 5);
      final mgr = _signMgr;
      for (final sign in passed) {
        final a = sign.annot;
        sign.annot = null;
        if (a != null && mgr != null) {
          unawaited(mgr.delete(a).catchError((Object _) {}));
        }
      }
    }
  }

  /// Geometry-only rewrite of the drawn line (native annotation or web).
  /// Route REPLACEMENTS (load/reroute/leg-flip) go through _drawRoute and
  /// reset the trim cursor; this is only the erase.
  Future<void> _replaceRouteGeometry(List<LatLng> pts) async {
    if (kIsWeb) {
      _webMap?.setPolyline(
        'navRoute',
        [for (final p in pts) (lng: p.longitude, lat: p.latitude)],
        color: '#E8C547',
        // 8 como en nativo (user spec 2026-09-27).
        width: 8,
      );
      return;
    }
    final mgr = _polyMgr;
    final annot = _routeAnnot;
    if (mgr == null || annot == null) return;
    if (pts.length < 2) {
      await _clearRouteAnnotation();
      return;
    }
    final geom = safeLineString(pts);
    if (geom == null) return;
    annot.geometry = geom;
    try {
      await mgr.update(annot);
    } catch (_) {}
  }

  /// Swap the traffic-light / stop-sign set for the current route: each
  /// sign's arc-length is measured once so the trim cursor can eat the ones
  /// the driver passes, exactly like the line behind him.
  void _setRouteFurniture(List<NavFurniture> furniture,
      {List<LatLng> crossings = const []}) {
    unawaited(_clearFurniture());
    // Where the route crosses other roads, as arc-lengths on the drawn line.
    final cs = <double>[];
    if (_routePts.length >= 2) {
      for (final c in crossings) {
        final snapped = _snapFurniture((at: c, isStopSign: false));
        if (snapped != null &&
            RouteSplice.haversineM(snapped.f.at, c) <= 15) {
          cs.add(snapped.s);
        }
      }
    }
    cs.sort();
    _crossingS = cs;
    final signs = <_NavSign>[];
    if (_routePts.length >= 2) {
      for (final f in furniture) {
        final snapped = _snapFurniture(f);
        if (snapped != null) signs.add(_NavSign(s: snapped.s, f: snapped.f));
      }
    }
    _furniture = signs;
    unawaited(_drawFurniture());
    _tileSignsSeq++;
    unawaited(_mergeTileSigns());
  }

  /// Sequence token for [_mergeTileSigns]: a tile read must never land on
  /// a route that has since been replaced (reroute / leg flip).
  int _tileSignsSeq = 0;
  bool _tileSignsBusy = false;
  // The route's intersections as arc-lengths (Mapbox steps). Empty = not
  // known yet: no tile sign is taken on faith without them.
  List<double> _crossingS = const [];
  DateTime _lastTileSignsAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// How far off the drawn line a tile sign may sit and still be the
  /// route's own: the node is ON the road the car drives. The stop of a
  /// side street sits on that street, metres off the line (5.6 m on Pelham
  /// Pkwy), and a crossing's lights on the other carriageway ~19 m off.
  static const double _kSignOnRouteM = 4.0;

  /// Lights and stops the map's tiles carry (owner 2026-11-02: "los
  /// semáforos no aparecen en el lugar exacto donde están y tampoco los
  /// stops"): read from the tiles already loaded around the car (Mapbox
  /// Streets `road` points — the OSM nodes themselves), kept only when they
  /// sit on the route ahead, deduped at ~30 m against the whole set in route
  /// order. Re-read every few seconds as new tiles come in.
  Future<void> _mergeTileSigns() async {
    final map = _map;
    if (kIsWeb ||
        map == null ||
        !_mapMounted ||
        _tileSignsBusy ||
        _routePts.length < 2 ||
        _crossingS.isEmpty) {
      return;
    }
    _tileSignsBusy = true;
    _lastTileSignsAt = DateTime.now();
    final seq = _tileSignsSeq;
    try {
      final feats = await map.querySourceFeatures(
        'composite',
        mapbox.SourceQueryOptions(
          sourceLayerIds: ['road'],
          filter: '["in", ["get", "class"], '
              '["literal", ["traffic_signals", "stop_sign"]]]',
        ),
      );
      if (!mounted || seq != _tileSignsSeq) return;
      final fresh = <_NavSign>[];
      for (final f in DirectionsService.parseTileSigns(
          feats.map((q) => q?.queriedFeature.feature))) {
        final snapped = _snapFurniture(f);
        if (snapped == null) continue;
        if (RouteSplice.haversineM(snapped.f.at, f.at) > _kSignOnRouteM) {
          continue; // a side street's sign, or the other carriageway's
        }
        if (snapped.s < _trimS - 5) continue; // already behind the car
        // At a crossing or on its near approach, in the driver's direction;
        // the far approach's stop is for oncoming traffic.
        if (!DirectionsService.signAtCrossing(snapped.s, _crossingS)) {
          continue;
        }
        fresh.add(_NavSign(s: snapped.s, f: snapped.f));
      }
      // Route order, lights first on a tie: the near approach's node wins
      // the corner, the far approach's (oncoming traffic) is the dupe.
      fresh.sort((a, b) {
        final c = a.s.compareTo(b.s);
        if (c != 0) return c;
        return (a.f.isStopSign ? 1 : 0) - (b.f.isStopSign ? 1 : 0);
      });
      var added = false;
      for (final sign in fresh) {
        final dup = _furniture
            .any((e) => RouteSplice.haversineM(e.f.at, sign.f.at) < 30);
        if (dup) continue;
        _furniture.add(sign);
        added = true;
      }
      if (added) unawaited(_drawFurniture());
    } catch (e) {
      debugPrint('[Nav] tile signs read failed: $e');
    } finally {
      _tileSignsBusy = false;
    }
  }

  /// Snap a sign onto the DRAWN line (user report 2026-09-23, "los
  /// semaforos no aparecen en el lugar correcto"): the furniture coords
  /// ride Mapbox intersections, but the drawn geometry can be the prefetch
  /// or a Google/OSRM line (provider race) — an icon anchored to the raw
  /// intersection sits visibly off the road at chase zoom. The projected
  /// point lies exactly on the line the driver sees, in chase AND top-down.
  /// Past 30 m off the line the sign belongs to a different path: dropped.
  ({double s, NavFurniture f})? _snapFurniture(NavFurniture f) {
    final pts = _routePts;
    final seg = RouteSplice.closestSegmentIndex(pts, f.at);
    final proj = RouteSplice.projectOnSegment(f.at, pts[seg], pts[seg + 1]);
    if (RouteSplice.haversineM(proj, f.at) > 30) return null;
    return (
      s: _routeSOf(pts, seg, proj),
      f: (at: proj, isStopSign: f.isStopSign),
    );
  }

  Future<void> _clearFurniture() async {
    // Detach the list BEFORE the first await (user report 2026-09-25,
    // "semaforos duplicados"): the old code ended with `_furniture = []`
    // AFTER the per-sign delete awaits — a concurrent _setRouteFurniture had
    // already swapped the new set in by then, so the wipe clobbered the new
    // handles, the icons stayed on the map orphaned, and every later clear
    // iterated an empty list.
    final old = _furniture;
    _furniture = [];
    final mgr = _signMgr;
    for (final sign in old) {
      final a = sign.annot;
      sign.annot = null;
      if (a != null && mgr != null) {
        try {
          await mgr.delete(a);
        } catch (_) {}
      }
    }
  }

  Future<void> _drawFurniture() async {
    if (kIsWeb) return;
    final mgr = _signMgr;
    if (mgr == null || !mounted) return;
    for (final sign in _furniture) {
      if (sign.annot != null) continue;
      final bytes = sign.f.isStopSign
          ? (_stopBytes ??= await _renderStopSignBytes())
          : (_signalBytes ??= await _renderTrafficLightBytes());
      if (!mounted || _signMgr != mgr) return;
      try {
        sign.annot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(
              coordinates:
                  mapbox.Position(sign.f.at.longitude, sign.f.at.latitude)),
          image: bytes,
          // 0.9 → 1.35 (user spec 2026-09-19): the iOS plugin reads image
          // bytes at the device scale (×3), so 0.9 landed at ~11×18 pt —
          // unreadably small at chase zoom.
          iconSize: 1.35,
          // Standing ON its corner (owner 2026-11-02, "no aparecen en el
          // lugar exacto"): centred, the lower half of the upright icon
          // covered the road before the crossing and, in the tilted chase,
          // read as a light some metres short of it.
          iconAnchor: mapbox.IconAnchor.BOTTOM,
        ));
      } catch (_) {
        return; // surface died mid-draw — the next setup recreates
      }
    }
  }

  /// Mini traffic light, reference-nav style: dark rounded head with the
  /// three lamps and a white casing so it reads on the navy tiles.
  Future<Uint8List> _renderTrafficLightBytes() async {
    const double w = 36, h = 60;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(2, 2, w - 4, h - 4), const Radius.circular(9)),
      Paint()..color = Colors.white,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(
          const Rect.fromLTWH(4, 4, w - 8, h - 8), const Radius.circular(7)),
      Paint()..color = const Color(0xFF1A1A1A),
    );
    const lamps = [Color(0xFFE5484D), Color(0xFFF5A524), Color(0xFF30A46C)];
    for (var i = 0; i < 3; i++) {
      canvas.drawCircle(
          Offset(w / 2, 14.0 + i * 16), 6.5, Paint()..color = lamps[i]);
    }
    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
  }

  /// Mini stop sign: red octagon, white border and inset ring.
  Future<Uint8List> _renderStopSignBytes() async {
    const double w = 56, h = 56;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
    Path octagon(double inset) {
      final c = const Offset(w / 2, h / 2);
      final r = w / 2 - inset;
      final path = Path();
      for (var i = 0; i < 8; i++) {
        final a = math.pi / 8 + i * math.pi / 4;
        final p = c + Offset(math.cos(a), math.sin(a)) * r;
        if (i == 0) {
          path.moveTo(p.dx, p.dy);
        } else {
          path.lineTo(p.dx, p.dy);
        }
      }
      return path..close();
    }

    canvas.drawPath(octagon(2), Paint()..color = Colors.white);
    canvas.drawPath(octagon(5), Paint()..color = const Color(0xFFC81E1E));
    canvas.drawPath(
      octagon(9),
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6,
    );
    // The word, like the real sign (user reference 2026-09-25): at top-down
    // zoom the bare octagon read as a red blob.
    final tp = TextPainter(
      text: const TextSpan(
        text: 'STOP',
        style: TextStyle(
          color: Colors.white,
          fontSize: 13,
          fontWeight: FontWeight.w900,
          letterSpacing: 0.5,
          height: 1.0,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(canvas, Offset((w - tp.width) / 2, (h - tp.height) / 2));
    final img = await recorder.endRecording().toImage(w.toInt(), h.toInt());
    final data = await img.toByteData(format: ui.ImageByteFormat.png);
    return data!.buffer.asUint8List();
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
          [for (final p in _routePts) (lng: p.longitude, lat: p.latitude)],
          color: '#E8C547',
          // 8 como en nativo (user spec 2026-09-27).
          width: 8,
        );
      }
      return;
    }
    final mgr = _polyMgr;
    if (mgr == null) return;
    if (_routeAnnot == null && _drawOnNext && _routePts.length >= 2) {
      _drawOnNext = false;
      await _drawOnRoute(mgr);
      return;
    }
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
          // 8.0 → 6.5 (owner request 2026-11-02, "un poquito finita pero no
          // tanto"): with the lighter 45° tilt the line no longer needs the
          // extra width 8 gave it under 55°.
          // ROUND join + ROUND cap: the curve corners are eased, never
          // pointed ("las esquinas de curva no punteagudas").
          lineWidth: 6.5,
          lineJoin: mapbox.LineJoin.ROUND,
        ));
        // line-cap va por capa (no es parámetro del annotation en este
        // SDK): extremos redondeados también en el corte del trim.
        await _map?.style.setStyleLayerProperty(mgr.id, 'line-cap', 'round');
      } catch (_) {}
    }
  }

  /// The first [meters] of [pts], the last point interpolated.
  static List<LatLng> _prefixOf(List<LatLng> pts, double meters) {
    final out = <LatLng>[pts.first];
    var acc = 0.0;
    for (var i = 1; i < pts.length; i++) {
      final seg = RouteSplice.haversineM(pts[i - 1], pts[i]);
      if (acc + seg >= meters) {
        final f = seg <= 0 ? 0.0 : ((meters - acc) / seg).clamp(0.0, 1.0);
        out.add(LatLng(
          pts[i - 1].latitude + (pts[i].latitude - pts[i - 1].latitude) * f,
          pts[i - 1].longitude + (pts[i].longitude - pts[i - 1].longitude) * f,
        ));
        return out;
      }
      acc += seg;
      out.add(pts[i]);
    }
    return out;
  }

  /// The new leg's line grows out from the car along the road (ease in-out,
  /// 1.4 s), then the full line is written once more so the last frame —
  /// the one most likely to be dropped — always lands.
  Future<void> _drawOnRoute(mapbox.PolylineAnnotationManager mgr) async {
    final pts = List.of(_routePts);
    final total = _polylineLenM(pts);
    final first = safeLineString(_prefixOf(pts, math.min(2.0, total)));
    if (first == null || total <= 0) return;
    try {
      _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: first,
        lineColor: _gold.toARGB32(),
        lineWidth: 6.5,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
      await _map?.style.setStyleLayerProperty(mgr.id, 'line-cap', 'round');
    } catch (_) {
      return;
    }
    final start = DateTime.now();
    _drawOnUntil = start.add(const Duration(milliseconds: _drawOnMs + 200));
    _drawOnTimer?.cancel();
    _drawOnTimer = Timer.periodic(const Duration(milliseconds: 40), (t) {
      final annot = _routeAnnot;
      if (!mounted || annot == null) {
        t.cancel();
        return;
      }
      final f = (DateTime.now().difference(start).inMilliseconds / _drawOnMs)
          .clamp(0.0, 1.0);
      if (f >= 1.0) {
        t.cancel();
        _drawOnUntil = null;
        unawaited(_drawRoute());
        return;
      }
      final geom = safeLineString(
          _prefixOf(pts, math.max(2.0, total * Curves.easeInOut.transform(f))));
      if (geom == null) return;
      annot.geometry = geom;
      unawaited(mgr.update(annot).catchError((Object _) {}));
    });
  }

  /// Where the stretch after this one ends — none on the last leg.
  LatLng? get _nextLegEnd {
    if (widget.toPickup) {
      final stop = widget.stopDone ? null : widget.stopLatLng;
      return stop ?? widget.dropoffLatLng;
    }
    return _stopLeg ? widget.dropoffLatLng : null;
  }

  Future<void> _clearNextLeg() async {
    final annot = _nextLegAnnot;
    _nextLegAnnot = null;
    final mgr = _polyMgr;
    if (annot != null && mgr != null) {
      try {
        await mgr.delete(annot);
      } catch (_) {}
    }
  }

  /// Fetches and draws the next leg in faded gold. After a leg flip it
  /// waits for the new line to draw itself, then fades in.
  Future<void> _loadNextLeg({bool afterDrawOn = false}) async {
    final seq = ++_nextLegSeq;
    await _clearNextLeg();
    final end = _nextLegEnd;
    final from = _dest;
    if (end == null || kIsWeb) {
      _nextLegPts = [];
      return;
    }
    List<LatLng> pts = const [];
    try {
      final result = await DirectionsService(ApiKeys.webServices).getRoute(
        origin: from,
        destination: end,
        language: Localizations.localeOf(context).languageCode,
      );
      pts = result?.points ?? const [];
    } catch (e) {
      debugPrint('[Nav] next leg fetch failed: $e');
    }
    if (!mounted || seq != _nextLegSeq || pts.length < 2) return;
    _nextLegPts = pts;
    if (afterDrawOn) {
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      if (!mounted || seq != _nextLegSeq) return;
    }
    final mgr = _polyMgr;
    final geom = safeLineString(pts);
    if (mgr == null || geom == null) return;
    try {
      // Fades in over ~0.8 s.
      final annot = await mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: geom,
        lineColor: _gold.withAlpha(_nextLegAlpha).toARGB32(),
        lineWidth: 5.5,
        lineJoin: mapbox.LineJoin.ROUND,
        lineOpacity: 0.25,
      ));
      if (!mounted || seq != _nextLegSeq) {
        unawaited(mgr.delete(annot).catchError((Object _) {}));
        return;
      }
      _nextLegAnnot = annot;
      for (final o in const [0.5, 0.75, 1.0]) {
        await Future<void>.delayed(const Duration(milliseconds: 200));
        if (!mounted || seq != _nextLegSeq || _nextLegAnnot != annot) return;
        annot.lineOpacity = o;
        try {
          await mgr.update(annot);
        } catch (_) {}
      }
    } catch (_) {}
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
    unawaited(_drawStopPin());
  }

  /// The stop rides the dropoff leg: flag pin at its coordinates. On the
  /// pickup leg (or with no stop) any existing pin comes down.
  Future<void> _drawStopPin() async {
    final mgr = _pointMgr;
    if (mgr == null) return;
    // On the stop leg the destination pin already marks it.
    final stop = _routeStop;
    if (stop == null) {
      final old = _stopAnnot;
      _stopAnnot = null;
      if (old != null) {
        try {
          await mgr.delete(old);
        } catch (_) {}
      }
      return;
    }
    final point = safePoint(stop.longitude, stop.latitude);
    if (point == null) return;
    if (_stopAnnot != null) {
      _stopAnnot!.geometry = point;
      try {
        await mgr.update(_stopAnnot!);
      } catch (_) {}
      return;
    }
    try {
      final bytes = await renderCircularPinBytes(
          icon: CircularPinIcon.flag, isPickup: false, radius: 32);
      if (!mounted) return;
      _stopAnnot = await mgr.create(mapbox.PointAnnotationOptions(
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
        [for (final p in _routePts) (lng: p.longitude, lat: p.latitude)],
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
    final seq = _cameraActionGate.begin();
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
      if (!mounted || !_cameraActionGate.isCurrent(seq)) return;
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
    final lat = _dot.lat;
    final lng = _dot.lng;
    if (lat != null && lng != null) {
      final projected = _snapToNavRoute(LatLng(lat, lng));
      if (projected != null) {
        _renderPos = projected;
        final aim = _navAimBearing(projected);
        if (aim != null && _speedMps >= 1.0) _dot.setBearing(aim);
        _trimRouteTo(projected);
      }
    }
    // The dot's FIRST position (seed or first fix) and a parked driver's
    // nudges land with no vsync frames, so the per-frame chase never ran
    // and the camera stayed on its opening pose — the arrow beside the
    // line while the trim already ate the route up to the car (owner
    // report 2026-11-02). One explicit pose write while the chase sleeps.
    if (DateTime.now().difference(_lastChaseFrameAt) >
        const Duration(milliseconds: 250)) {
      _snapToChasePose();
    }
    // New tiles come in as the car drives: read their lights and stops.
    if (DateTime.now().difference(_lastTileSignsAt) >
        const Duration(seconds: 3)) {
      unawaited(_mergeTileSigns());
    }
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
  void _onDotFrame() => _chaseFrame(_dot.lastFrameDtSec);

  void _chaseFrame(double dt) {
    if (_camState != _CamState.following || _overview || !_mapMounted) {
      _camBearing = null; // the next follow frame starts from the arrow
      return;
    }
    _lastChaseFrameAt = DateTime.now();
    final lat = _renderPos?.latitude ?? _dot.lat;
    final lng = _renderPos?.longitude ?? _dot.lng;
    if (lat == null || lng == null) return;
    _stepPitch();
    // Zoom lerps toward its target at ≤0.5/sec — a speed or maneuver change
    // is felt as a glide, never as a cut. dt is the dot ticker's own vsync
    // delta (already capped at 50 ms), never a wall clock read mid-frame.
    final target = _zoomTarget();
    final maxStep = _zoomLerpPerSec * dt;
    if ((_chaseZoom - target).abs() <= maxStep) {
      _chaseZoom = target;
    } else {
      _chaseZoom += _chaseZoom < target ? maxStep : -maxStep;
    }
    // Top padding pushes the focal point well below centre (user spec
    // 2026-09-19: the car rides at ~70% of the screen height so the road
    // AHEAD — the next light, stop or intersection — is on screen with
    // anticipation) and keeps the arrow clear of the maneuver bar.
    final topPad = (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 240;
    _writeCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
      zoom: _chaseZoom,
      // The map follows the arrow's bearing on a damped spring (2026-10-30,
      // "como Google"); the overlay arrow shows the difference.
      bearing: _followCamBearing(_dot.bearing),
      pitch: _pitch,
      padding: mapbox.MbxEdgeInsets(
          top: topPad, left: 0, right: 0, bottom: _camBottomPad),
    ));
    _ensureCamSettle();
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
    final lat = _renderPos?.latitude ?? _dot.lat;
    final lng = _renderPos?.longitude ?? _dot.lng;
    if (lat == null || lng == null) return;
    final topPad = (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 240;
    _snapCamBearing(_dot.bearing);
    _writeCamera(mapbox.CameraOptions(
      center: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
      zoom: _chaseZoom,
      bearing: _dot.bearing,
      pitch: _pitch,
      padding: mapbox.MbxEdgeInsets(
          top: topPad, left: 0, right: 0, bottom: _camBottomPad),
    ));
  }

  /// The chase pose as a smooth flyTo instead of a cut — for the reroute
  /// landing, where the line (and often the whole street direction) just
  /// changed under the driver. Same gates as the per-frame chase.
  Future<void> _flyToChasePose(int durationMs) async {
    if (_camState != _CamState.following || _overview || !_mapMounted) {
      return;
    }
    final lat = _renderPos?.latitude ?? _dot.lat;
    final lng = _renderPos?.longitude ?? _dot.lng;
    if (lat == null || lng == null) return;
    final topPad = (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 240;
    if (kIsWeb) {
      _webMap?.flyTo(
        lng: lng,
        lat: lat,
        zoom: _chaseZoom,
        bearing: _dot.bearing,
        pitch: _pitch,
        durationMs: durationMs,
      );
      return;
    }
    // Native: nothing to do. While following, _onDotFrame already writes the
    // full chase pose (centre, zoom, pitch, bearing) every frame, so a flyTo
    // here only raced it — the next frame's setCamera cancelled the native
    // animation mid-way and the camera jumped (same mechanism as the old
    // recenter cut). The frame loop converges on its own, smoothly.
    assert(topPad >= 0);
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
    if (!mounted || !identical(map, _map)) {
      _pendingCamWrite = null;
      return;
    }
    _pendingCamWrite = null;
    _camWriteBusy = true;
    try {
      // 800 ms, not 2 s (user report: "la pantalla esta con delay"): a hung
      // native write must stop gating fresh frames quickly — the timeout is
      // only the Dart-side latch, the native side applies the latest camera
      // it receives regardless.
      map.setCamera(opts).timeout(const Duration(milliseconds: 800)).then((_) {
        _camWriteBusy = false;
        if (mounted && identical(map, _map)) _flushCameraWrite(map);
      }).catchError((Object _) {
        _camWriteBusy = false;
        if (mounted && identical(map, _map)) _flushCameraWrite(map);
      });
    } catch (_) {
      _camWriteBusy = false;
    }
  }

  Future<void> _updateDriverAnnotation() async {
    if (!mounted || _annotWriteBusy) return;
    // Following = the vector overlay IS the arrow (audit D7): the native
    // one is deleted here, never written.
    if (_arrowOverlayMode) {
      if (_driverAnnot != null) _deleteNativeArrow();
      return;
    }
    // The arrow's own manager: icon-rotation-alignment 'map' is set per
    // manager — on the shared pins manager it laid the destination pin and
    // the rider figure down whenever the chase camera rotated (user report
    // 2026-09-17, the "pin acostado").
    final mgr = _carMgr;
    final lat = _renderPos?.latitude ?? _dot.lat;
    final lng = _renderPos?.longitude ?? _dot.lng;
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
        // House rule: deleteAll before create. This manager holds only the
        // arrow, and a delete that failed silently would leave two of them.
        try {
          await mgr.deleteAll().timeout(_annotIpcTimeout);
        } catch (_) {}
        if (!mounted || !identical(mgr, _carMgr)) return;
        final dpr = MediaQuery.maybeDevicePixelRatioOf(context) ?? 1.0;
        // Every pigeon call is bounded (audit D1): a PlatformView torn down
        // mid-call never answers, and an unbounded await here left the
        // latch above true for the life of the view — no arrow, ever.
        final created = await mgr
            .create(mapbox.PointAnnotationOptions(
              geometry: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
              image: img,
              iconSize: GoldLocationDot.driverAnnotationIconSize(
                devicePixelRatio: dpr,
                highRes: _dot.currentBytesHiRes != null,
                scale: GoldLocationDot.driverIconSize * _kNavArrowScale,
              ),
              iconAnchor: mapbox.IconAnchor.CENTER,
              iconRotate: bearing,
            ))
            .timeout(_annotIpcTimeout);
        if (!mounted || !identical(mgr, _carMgr)) {
          // The surface changed under the create — the handle is dead.
          unawaited(mgr.delete(created).catchError((Object _) {}));
          return;
        }
        _driverAnnot = created;
        if (_arrowOverlayMode) {
          // The chase re-latched while the create was in flight: the
          // overlay owns the arrow again, so this one goes straight back.
          _deleteNativeArrow();
          return;
        }
        try {
          await _map?.style
              .setStyleLayerProperty(mgr.id, 'icon-rotation-alignment', 'map');
          // La flecha también se inclina con la cámara (user spec 2026-09-27,
          // "la flecha un poquito inclinada"): pitch-alignment 'map' la
          // acuesta con el tilt de la cámara en vez de dejarla parada como
          // sticker.
          await _map?.style
              .setStyleLayerProperty(mgr.id, 'icon-pitch-alignment', 'map');
        } catch (_) {}
        if (!mounted) return;
        if (_arrowHandoffPending) {
          // The native arrow exists — the overlay cover can go.
          _arrowHandoffTimer?.cancel();
          setState(() => _arrowHandoffPending = false);
        }
      } else {
        _driverAnnot!.geometry =
            mapbox.Point(coordinates: mapbox.Position(lng, lat));
        _driverAnnot!.iconRotate = bearing;
        await mgr.update(_driverAnnot!).timeout(_annotIpcTimeout);
        if (!mounted) return;
      }
      _lastSentLat = lat;
      _lastSentLng = lng;
      _lastSentBearing = bearing;
    } catch (e) {
      // Timed out, or died with its surface (audit D1/D3): say so, null the
      // handle so the next tick — or the watchdog — recreates it.
      debugPrint('[Nav] arrow create/update failed: $e');
      _driverAnnot = null;
      _lastSentLat = null;
      _lastSentLng = null;
      _lastSentBearing = null;
    } finally {
      _annotWriteBusy = false;
    }
  }

  // ─────────────────────────────────────────────
  //  Arrow ownership: vector overlay (following) vs native annotation
  // ─────────────────────────────────────────────

  /// While the chase follows, the arrow is the Flutter overlay drawn at the
  /// camera focus (audit D7) — the same trade the online map made: the map
  /// slides under a pinned marker, so a per-frame native write buys nothing
  /// but channel latency and a two-channel jitter against the camera.
  /// Everywhere the camera is NOT pinned to the car (freeLook, overview,
  /// the recenter blend) the native annotation marks the spot.
  bool get _arrowOverlayMode =>
      !kIsWeb &&
      _mapMounted &&
      _camState == _CamState.following &&
      !_overview;

  /// The overlay stays up through a handoff to the native arrow until that
  /// one exists (bounded by [_arrowHandoffTimer]) — never a frame with no
  /// arrow at all.
  bool get _arrowOverlayVisible => _arrowOverlayMode || _arrowHandoffPending;

  /// Called after every camera-state change: makes the drawn arrow match
  /// [_arrowOverlayMode]. Overlay mode deletes the native one (handle nulled
  /// first, delete fire-and-forget); native mode creates it and keeps the
  /// overlay as cover until the create lands.
  void _syncArrowOwner() {
    if (kIsWeb || !mounted) return;
    if (_arrowOverlayMode) {
      _arrowHandoffTimer?.cancel();
      _arrowHandoffPending = false;
      if (_driverAnnot != null) _deleteNativeArrow();
      return;
    }
    // Leaving follow mode means the camera is about to move away from the
    // marker (a drag, or the overview fit). An overlay pinned to the screen
    // centre would then slide across the map as a second, wrongly placed
    // arrow until the native one landed, so it goes down NOW and the native
    // arrow comes up on its own IPC round trip (one or two frames with no
    // arrow is the lesser evil).
    _arrowHandoffTimer?.cancel();
    if (_arrowHandoffPending) {
      _arrowHandoffPending = false;
      if (mounted) setState(() {});
    }
    unawaited(_updateDriverAnnotation());
  }

  /// Null the handle FIRST, then delete fire-and-forget (house rule: a
  /// failed delete must never leave a live handle behind — the next create
  /// runs deleteAll on this single-annotation manager anyway).
  void _deleteNativeArrow() {
    final annot = _driverAnnot;
    final mgr = _carMgr;
    _driverAnnot = null;
    _lastSentLat = null;
    _lastSentLng = null;
    _lastSentBearing = null;
    if (annot == null || mgr == null) return;
    unawaited(
        mgr.delete(annot).timeout(_annotIpcTimeout).catchError((Object e) {
      debugPrint('[Nav] arrow delete failed: $e');
    }));
  }

  /// Audit D2 — the twin of the online controller's _startDotWatchdog. The
  /// dot's ticker only fires while the car moves, so a parked driver whose
  /// bitmap rasterised late (cold start straight into a trip), or whose
  /// raster failed (GPU lost in background, OOM), or whose create threw,
  /// never got a second attempt: the arrow simply never appeared.
  void _startArrowWatchdog() {
    if (kIsWeb) return;
    _arrowWatchdog?.cancel();
    _arrowWatchdog = Timer.periodic(const Duration(seconds: 2), (_) async {
      if (!mounted || !_mapMounted) return;
      if (!_dot.isReady) {
        // build() re-arms the raster AND the ticker (it clears the dispose
        // latch) — the only way back for a dot whose first raster failed,
        // since nothing else ever calls build() again.
        await _dot.build(this, _onDotTick, onFrame: _onDotFrame);
        if (!mounted) return;
      }
      if (_arrowOverlayMode) return;
      if (_driverAnnot == null) unawaited(_updateDriverAnnotation());
    });
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
    final waiting = stage == 'waiting_rider' ||
        stage == 'start_ride' ||
        stage == 'stop_waiting';
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
      // The stop's wait starts its own clock.
      _waitStartLocal = null;
      _waitRemainFrac = 1.0;
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
      // chase the SMOOTH way — the same blend the recenter button uses, not
      // a state flip that lets the next chase frame snap the camera.
      unawaited(_recenter());
      return;
    }
    // Audit D5: the fit needs a line and a map. Flipping the state without
    // them left the button inverted over a camera that never moved.
    if (_routePts.length < 2 || (!kIsWeb && _map == null)) {
      debugPrint('[Nav] overview skipped — route pts=${_routePts.length}, '
          'map=${_map != null}');
      return;
    }
    // A recenter blend in flight yields to the fit.
    _recenterTicker?.stop();
    _recenterFrom = null;
    _recenterStartedAt = null;
    setState(() {
      _overview = true;
      _camState = _CamState.freeLook;
    });
    unawaited(_syncSignsShown());
    _syncArrowOwner();
    unawaited(_glideToOverview());
  }

  /// Into the route overview the same way [_recenter] comes back out: the
  /// camera blended frame by frame from the pose it has to a flat,
  /// north-up frame of the whole route (worked out by our own Mercator,
  /// flown with ZERO map padding), over [_recenterBlendMs] eased.
  Future<void> _glideToOverview() async {
    final map = _map;
    if (kIsWeb || map == null) {
      await _fitRouteOnce();
      return;
    }
    final media = MediaQuery.of(context);
    final pts = _routePts
        .where((p) => isValidLatLng(p.latitude, p.longitude))
        .toList();
    final to = FlatMapProjection.fitFlat(
      points: pts,
      viewport: media.size,
      top: media.padding.top + 120,
      left: 48,
      bottom: media.size.height * 0.30,
      right: 48,
      maxZoom: 17,
    );
    if (to == null) {
      await _fitRouteOnce();
      return;
    }
    final seq = _cameraActionGate.begin();
    mapbox.CameraState? from;
    try {
      from = await map
          .getCameraState()
          .timeout(const Duration(milliseconds: 800));
    } catch (e) {
      debugPrint('[Nav] overview: camera state unavailable: $e');
    }
    if (!mounted || !_overview || !_cameraActionGate.isCurrent(seq)) return;
    if (from == null) {
      await _fitRouteOnce();
      return;
    }
    _overviewTicker ??= createTicker(_onOverviewTick);
    _overviewTicker!.stop();
    _overviewFrom = from;
    _overviewTo = to;
    _overviewStartedAt = null;
    _overviewSeq = seq;
    _overviewTicker!.start();
  }

  void _stopOverviewGlide() {
    _overviewTicker?.stop();
    _overviewFrom = null;
    _overviewTo = null;
    _overviewStartedAt = null;
  }

  /// One frame of the glide into the overview — the mirror of
  /// [_onRecenterTick]: same length, same curve, shortest way round to
  /// north, the tilt easing flat and the chase padding easing to none.
  void _onOverviewTick(Duration elapsed) {
    final from = _overviewFrom;
    final to = _overviewTo;
    if (!mounted ||
        from == null ||
        to == null ||
        !_mapMounted ||
        !_overview ||
        !_cameraActionGate.isCurrent(_overviewSeq)) {
      // Back to the chase, a gesture or a revoke took the camera: yield.
      _stopOverviewGlide();
      return;
    }
    _overviewStartedAt ??= elapsed;
    final t =
        ((elapsed - _overviewStartedAt!).inMilliseconds / _recenterBlendMs)
            .clamp(0.0, 1.0);
    final e = _camGlideCurve.transform(t);
    double lerp(double a, double b) => a + (b - a) * e;
    final fc = from.center.coordinates;
    var dBrg = (0 - from.bearing) % 360;
    if (dBrg > 180) dBrg -= 360;
    final fp = from.padding;
    _writeCamera(mapbox.CameraOptions(
      center: mapbox.Point(
          coordinates: mapbox.Position(
              lerp(fc.lng.toDouble(), to.center.longitude),
              lerp(fc.lat.toDouble(), to.center.latitude))),
      zoom: lerp(from.zoom, to.zoom),
      bearing: (from.bearing + dBrg * e) % 360,
      pitch: lerp(from.pitch, 0),
      padding: mapbox.MbxEdgeInsets(
        top: lerp(fp.top, 0),
        left: lerp(fp.left, 0),
        right: lerp(fp.right, 0),
        bottom: lerp(fp.bottom, 0),
      ),
    ));
    if (t >= 1.0) _stopOverviewGlide();
  }

  /// Recenter → recentering → following. Audit D4: NOT a flyTo. The
  /// plugin's flyTo returns the moment the native animation STARTS, so
  /// "await it, then follow" let the very next chase frame's setCamera
  /// cancel the flight — the smooth recenter was a cut by construction.
  /// Now the camera is blended per frame from the pose it had toward the
  /// LIVE chase pose over [_recenterBlendMs] (eased), on its own ticker so
  /// a parked car blends too; any gesture supersedes the action-gate
  /// sequence and the blend yields to freeLook mid-flight.
  Future<void> _recenter() async {
    HapticService.lightImpact();
    final seq = _cameraActionGate.begin();
    final lat = _renderPos?.latitude ?? _dot.lat;
    final lng = _renderPos?.longitude ?? _dot.lng;
    if (lat == null || lng == null) {
      _settleFollowing();
      return;
    }
    if (kIsWeb) {
      _webMap?.flyTo(
        lng: lng,
        lat: lat,
        zoom: _chaseZoom,
        bearing: _dot.bearing,
        pitch: _pitch,
        durationMs: _recenterBlendMs,
      );
      _settleFollowing();
      return;
    }
    final map = _map;
    if (map == null) {
      _settleFollowing();
      return;
    }
    mapbox.CameraState? from;
    try {
      from = await map
          .getCameraState()
          .timeout(const Duration(milliseconds: 800));
    } catch (e) {
      debugPrint('[Nav] recenter: camera state unavailable: $e');
    }
    if (!mounted || !_cameraActionGate.isCurrent(seq)) return;
    if (from == null) {
      // No pose to blend from — one explicit chase write, then follow.
      _settleFollowing();
      _snapToChasePose();
      return;
    }
    _recenterTicker ??= createTicker(_onRecenterTick);
    _recenterTicker!.stop();
    _recenterFrom = from;
    _recenterStartedAt = null;
    _recenterSeq = seq;
    setState(() {
      _overview = false;
      _camState = _CamState.recentering;
    });
    unawaited(_syncSignsShown());
    _syncArrowOwner();
    _recenterTicker!.start();
  }

  /// following, overview off, arrow owner synced — the common landing.
  void _settleFollowing() {
    if (!mounted) return;
    setState(() {
      _overview = false;
      _camState = _CamState.following;
    });
    _syncArrowOwner();
    unawaited(_syncSignsShown());
  }

  /// Lights and stops fade out for the route overview and back in for the
  /// drive (owner 2026-11-02: "como se ve en Lyft") — 0.4 s, on the layer.
  Future<void> _syncSignsShown() async {
    final map = _map;
    final mgr = _signMgr;
    if (kIsWeb || map == null || mgr == null) return;
    final show = !_overview;
    if (_signsShown == show) return;
    _signsShown = show;
    try {
      await map.style
          .setStyleLayerProperty(mgr.id, 'icon-opacity', show ? 1.0 : 0.0);
    } catch (_) {
      _signsShown = null;
    }
  }

  /// One frame of the recenter blend: eased lerp from [_recenterFrom] to the
  /// chase pose evaluated NOW (the car keeps moving during the blend), so
  /// the landing frame is exactly what the next chase frame would write —
  /// no cut on either end.
  void _onRecenterTick(Duration elapsed) {
    if (!mounted) {
      _recenterTicker?.stop();
      return;
    }
    final from = _recenterFrom;
    if (from == null ||
        !_mapMounted ||
        _camState != _CamState.recentering ||
        !_cameraActionGate.isCurrent(_recenterSeq)) {
      // A gesture (or a revoke) took the camera mid-blend: yield.
      _endRecenterBlend(_CamState.freeLook);
      return;
    }
    final lat = _renderPos?.latitude ?? _dot.lat;
    final lng = _renderPos?.longitude ?? _dot.lng;
    if (lat == null || lng == null) {
      _endRecenterBlend(_CamState.following);
      return;
    }
    _recenterStartedAt ??= elapsed;
    final t =
        ((elapsed - _recenterStartedAt!).inMilliseconds / _recenterBlendMs)
            .clamp(0.0, 1.0);
    final e = _camGlideCurve.transform(t);
    double lerp(double a, double b) => a + (b - a) * e;
    final fc = from.center.coordinates;
    var dBrg = (_dot.bearing - from.bearing) % 360;
    if (dBrg > 180) dBrg -= 360;
    final bearing = (from.bearing + dBrg * e) % 360;
    final topPad = (MediaQuery.maybeOf(context)?.padding.top ?? 0) + 240;
    final fp = from.padding;
    _writeCamera(mapbox.CameraOptions(
      center: mapbox.Point(
          coordinates: mapbox.Position(
              lerp(fc.lng.toDouble(), lng), lerp(fc.lat.toDouble(), lat))),
      zoom: lerp(from.zoom, _chaseZoom),
      bearing: bearing,
      pitch: lerp(from.pitch, _pitch),
      padding: mapbox.MbxEdgeInsets(
        top: lerp(fp.top, topPad),
        left: lerp(fp.left, 0),
        right: lerp(fp.right, 0),
        bottom: lerp(fp.bottom, _camBottomPad),
      ),
    ));
    if (t >= 1.0) _endRecenterBlend(_CamState.following);
  }

  void _endRecenterBlend(_CamState to) {
    _recenterTicker?.stop();
    _recenterFrom = null;
    _recenterStartedAt = null;
    if (!mounted) return;
    if (_camState == _CamState.recentering) {
      setState(() => _camState = to);
    }
    // The blend landed on the arrow's bearing: the spring starts from there
    // and the overlay arrow points straight up (review 2026-10-30).
    if (to == _CamState.following) _snapCamBearing(_dot.bearing);
    _syncArrowOwner();
  }

  /// Drag / pinch / rotate → freeLook. The map's own gesture callbacks cover
  /// drag and pinch; a second finger down (pinch or rotate — rotate has no
  /// widget-level listener in this SDK) is caught by the pointer Listener
  /// wrapping the MapWidget. onCameraChangeListener is never usable here:
  /// it fires for the chase's own writes and would unlatch follow on them.
  void _onUserGesture() {
    _cameraActionGate.begin();
    if (_overview) return;
    if (_camState == _CamState.recentering) {
      // The blend yields to the finger (audit D4).
      _endRecenterBlend(_CamState.freeLook);
      return;
    }
    if (_camState == _CamState.freeLook) return;
    setState(() => _camState = _CamState.freeLook);
    _syncArrowOwner();
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
                      // Same centre and inset as every chase write and the
                      // overlay arrow (owner report 2026-11-02, "la flecha
                      // fuera de la línea"): this pose used the raw fix and
                      // +130 while the arrow sits at the +240 focus, so until
                      // a chase write landed the arrow was 55 pt below the
                      // car and beside the line.
                      cameraOptions: mapbox.CameraOptions(
                        center: mapbox.Point(
                            coordinates: mapbox.Position(
                                _openCameraPos.longitude,
                                _openCameraPos.latitude)),
                        zoom: _chaseZoomDefault,
                        pitch: _chasePitch,
                        bearing:
                            _routeHeadingFor(widget.initialDriverPos) ?? 0.0,
                        padding: mapbox.MbxEdgeInsets(
                            top: media.padding.top + 240,
                            left: 0,
                            right: 0,
                            bottom: 0),
                      ),
                      onMapCreated: _onMapCreated,
                      onStyleLoadedListener: (_) async {
                        final m = _map;
                        if (m != null) await MapTheme.applyNavyGold(m);
                        if (m != null && mounted && _map == m) {
                          await _applyNavRoadFurniture(m);
                        }
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
                            // Same as native (owner request 2026-11-02).
                            width: 6.5,
                          );
                        }
                      },
                    )
                  : const NeuDotsBackdrop(),
        ),

        // ── The driver arrow while the chase follows (audit D7): a Flutter
        //    vector at the camera focus — the map slides under it, so there
        //    is nothing to send over the channel, no bitmap to rasterise and
        //    no manager to be ready. The native annotation exists only in
        //    freeLook / overview / recentering (see _syncArrowOwner). ──
        if (_arrowOverlayVisible)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (ctx, c) {
                  const sz = GoldLocationDot.driverOverlaySize * _kNavArrowScale;
                  // Same focal point the chase camera writes: Mapbox centres
                  // the car inside the padded viewport, i.e. topPad/2 below
                  // the screen centre.
                  final topPad =
                      (MediaQuery.maybeOf(ctx)?.padding.top ?? 0) + 240;
                  final focusY =
                      c.maxHeight / 2 + topPad / 2 - _camBottomPad / 2;
                  return Stack(
                    children: [
                      Positioned(
                        left: c.maxWidth / 2 - sz / 2,
                        top: focusY - sz / 2,
                        child: Transform(
                          alignment: Alignment.center,
                          // Laid on the ground like the native arrow
                          // (icon-pitch-alignment 'map'): foreshortened by
                          // the chase tilt, with a touch of perspective.
                          transform: Matrix4.identity()
                            ..setEntry(3, 2, 0.0015)
                            ..rotateX(_pitch * math.pi / 180),
                          // Heading-up chase: the camera carries the arrow's
                          // bearing, so on screen the arrow always points up.
                          // Heading-up chase with a damped map: the arrow
                          // shows what the camera has not turned yet.
                          child: ValueListenableBuilder<double>(
                            valueListenable: _arrowScreenBearing,
                            builder: (_, rel, __) => GoldLocationDotOverlay(
                              bearing: rel,
                              size: sz,
                            ),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
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
              // The guide is the SAME box (owner 2026-11-02: "debe de
              // abrirse de forma smooth y cerrarse también… no quiero que
              // desaparezca, sino que… se guarda… se ve como que si fuera
              // otro cuadro, el color se disuelve"): the turn box stays
              // exactly as it is on top, and the list of turns unfolds out
              // from under it and folds back under it — nothing fades into
              // anything else. A tap on it opens or folds it.
              AnimatedBuilder(
                animation: _guideCtrl,
                builder: (context, _) {
                  final t = _guideCtrl.value;
                  // The route's end folds an open guide away, the same way.
                  if (_guideOpen && _endRouteVisible) {
                    WidgetsBinding.instance.addPostFrameCallback((_) {
                      if (mounted && _guideOpen && _endRouteVisible) {
                        _setGuide(false);
                      }
                    });
                  }
                  final open = _guideOpen && !_endRouteVisible;
                  final canOpen = !_endRouteVisible &&
                      _navProgress != null &&
                      _navProgress!.hasSteps;
                  return GestureDetector(
                    key: const ValueKey('nav-guide-fold'),
                    onTap: open || canOpen
                        ? () {
                            HapticService.lightImpact();
                            _setGuide(!open);
                          }
                        : null,
                    child: _buildManeuverBar(
                      s,
                      tuck: _guideTuck,
                      list: t > 0 || open ? _buildGuide(s, _guideGrow) : null,
                    ),
                  );
                },
              ),
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

        // ── Rider stale-fix label, next to the halo ──
        if (_riderLabelPos != null && widget.toPickup)
          Positioned(
            left: _riderLabelPos!.dx + 26,
            top: _riderLabelPos!.dy - 10,
            child: IgnorePointer(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
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

        // ── The trip panel (owner design 2026-11-02) ──
        Positioned.fill(
          child: NavTripPanel(
            mapControls: _panelControls(s),
            etaLabel: _panelEtaLabel(s),
            riderName: widget.riderName,
            riderPhotoUrl: widget.riderPhotoUrl,
            riderId: widget.riderId,
            riderRating: widget.riderRating,
            riderTrips: widget.riderTrips,
            riderDays: widget.riderDays,
            riderVerified: widget.riderVerified,
            toPickup: widget.toPickup,
            pickupAddress: widget.pickupAddress,
            dropoffAddress: widget.dropoffAddress,
            stopLabel: widget.stopLabel,
            hasStop: widget.stopLatLng != null,
            stopLeg: _stopLeg,
            stopDone: widget.stopDone,
            pickupNote: widget.passengerInstructions,
            dropoffNote: widget.dropoffInstructions,
            onSlideFromStop: widget.onSlideFromStop,
            fare: widget.fare,
            moving: _panelMoving,
            stage: _panelStage,
            canPickUp: widget.stage == 'start_ride',
            waitClock: _waitClock,
            waitProgress: (1 - _waitRemainFrac).clamp(0.0, 1.0),
            receivingRides: widget.receivingRides,
            lastTrip: widget.lastTrip,
            chatUnread: _chatUnread,
            supportUnread: widget.supportUnread,
            queuedCanceled: widget.queuedCanceled,
            onOpenChat: widget.onOpenChat,
            onSupport: widget.onSupport,
            onCancelTrip: widget.onCancelTrip ?? widget.onExit,
            onArrived: _stopLeg
                ? (widget.onArrivedStop ?? widget.onArrived)
                : widget.onArrived,
            onSlidePickUp: widget.onSlidePickUp,
            onSlideFinish: widget.onSlideFinish,
            onToggleReceiving: widget.onToggleReceiving,
            onToggleLastTrip: widget.onToggleLastTrip,
            onNoShow: widget.onNoShow,
            onHeightChanged: (h) {
              if (!mounted || (h - _panelH).abs() < 0.5) return;
              setState(() => _panelH = h);
            },
            onRestHeightChanged: (h) {
              if (!mounted || (h - _panelRestH).abs() < 0.5) return;
              setState(() => _panelRestH = h);
            },
          ),
        ),
      ],
    );
  }

  /// The Mapbox wordmark and "i" in the strip of map under the floating
  /// panel (its bottom margin, 8 + half the bottom inset — nav_trip_panel),
  /// centred in it; the wordmark is 21 pt tall. The open panel covers them.
  Future<void> _showMapBrand(mapbox.MapboxMap m) {
    if (!mounted) return Future<void>.value();
    final inset = MediaQuery.maybeOf(context)?.padding.bottom ?? 0;
    final strip = 8 + inset * 0.5;
    return MapBrand.show(m,
        bottom: math.max(0.0, (strip - 21) / 2).roundToDouble());
  }

  /// The mph box and the camera buttons, above the panel's RESTING top:
  /// they stay where they are while the panel opens over them (owner
  /// 2026-11-02: "los botones del mapa y velocímetro deben de quedarse donde
  /// están cuando el sheet se abra"). Handed to the panel, which lays them
  /// above its blurred-map scrim, under the panel itself.
  Widget _panelControls(S s) {
    return Stack(
      children: [
        Positioned(
          left: 16,
          bottom: _panelRestH + 12,
          child: _phaseArrived ? const SizedBox.shrink() : _buildSpeedBox(),
        ),
        Positioned(
          right: 14,
          bottom: _panelRestH + 12,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Safety and support, one tap away while driving or parked
              // (owner 2026-11-02): Emergencia 911 sits at the top.
              if (widget.onSafety != null) ...[
                _roundMapBtn(
                  icon: Icons.shield_rounded,
                  tooltip: s.safetyAndSupport,
                  onTap: widget.onSafety!,
                ),
                const SizedBox(height: 10),
              ],
              // The route button (owner 2026-11-02): dot, zigzag, dot —
              // stood upright — shows the whole route; again, back to the
              // chase.
              _roundMapBtn(
                icon: _overview
                    ? Icons.navigation_rounded
                    : Icons.route_rounded,
                quarterTurns: _overview ? 0 : 1,
                tooltip: _overview ? s.navRecenter : s.navOverview,
                onTap: _toggleOverview,
              ),
              // Recenter appears only once the driver has taken the camera.
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
      ],
    );
  }

  /// Open or fold the trip guide; a route that ends folds it too.
  void _setGuide(bool open) {
    if (!mounted) return;
    setState(() => _guideOpen = open);
    if (open) {
      _guideCtrl.forward();
    } else {
      _guideCtrl.reverse();
    }
  }

  /// "7 min · 2.9 mi" for the panel's face.
  String _panelEtaLabel(S s) {
    final mins = (_remainSecs / 60).ceil();
    final distLabel = _remainMeters > 0 ? _fmtDist(_remainMeters, s) : '';
    return _remainSecs > 0 && distLabel.isNotEmpty
        ? '$mins min · $distLabel'
        : distLabel;
  }

  /// What the closed panel carries: approaching the pickup (photo, name,
  /// Contactar, "Llegué"), waiting there (the wait line, the slider), at
  /// the destination (the finish slider), or plain driving.
  NavPanelStage get _panelStage {
    final st = widget.stage;
    if (_stopLeg) {
      if (st == 'stop_waiting') return NavPanelStage.waitingStop;
      if (st == 'stop_near' ||
          _navPhase == _NavPhase.approachingDropoff ||
          _navPhase == _NavPhase.arrivedDropoff) {
        return NavPanelStage.approaching;
      }
      return NavPanelStage.driving;
    }
    if (widget.toPickup && (st == 'waiting_rider' || st == 'start_ride')) {
      return NavPanelStage.waitingPickup;
    }
    if (!widget.toPickup && st == 'finish') {
      return NavPanelStage.arrivedDropoff;
    }
    if (widget.toPickup &&
        (st == 'arrived' ||
            _navPhase == _NavPhase.approachingPickup ||
            _navPhase == _NavPhase.arrivedPickup)) {
      return NavPanelStage.approaching;
    }
    return NavPanelStage.driving;
  }

  /// Fallback for a steps-less route: the distance left to the destination
  /// — real information instead of repeating the title (user report
  /// 2026-09-17: the bar read "Follow the route / Follow the route").
  String _destDistLabel(S s) {
    final alongRoute = _remainingRouteMeters(_driverLatLng());
    final d = alongRoute > 0
        ? alongRoute
        : RouteSplice.haversineM(_driverLatLng(), _dest);
    return '${s.navFollowRoute} · ${_fmtDist(d, s)}';
  }

  Widget _buildManeuverBar(S s, {double tuck = 0, Widget? list}) {
    final destName = widget.toPickup
        ? widget.pickupAddress
        : (_stopLeg ? widget.stopLabel : widget.dropoffAddress);
    // Once End Route is showing (the nav's own latch OR a post-arrival stage
    // from the parent — user spec 2026-09-19) the bar stops guiding and
    // answers where you ARE: the client's address up top, the "you've
    // arrived" note under it. Before that, maneuvers as usual — and the
    // full instruction ("Take exit 67B on the right onto I-4 W") beats the
    // bare street name, which on a freeway says nothing about the exit the
    // driver has to take (user report: "en el freeway no indica las
    // salidas").
    final useInstruction = !_endRouteVisible && _instructionLabel.isNotEmpty;
    final title = _endRouteVisible
        ? destName
        : (useInstruction
            ? _instructionLabel
            : (_streetLabel.isEmpty ? s.navFollowRoute : _streetLabel));
    final subtitle = _endRouteVisible
        ? (widget.toPickup
            ? s.navArrivedPickup
            : (_stopLeg ? s.navArrivedStop : s.navArrivedDropoff))
        : (_maneuverDistLabel.isNotEmpty
            ? _maneuverDistLabel
            : _destDistLabel(s));
    // The freeway exit badge (user spec 2026-09-27, Google-style): the exit
    // number parsed out of the instruction ("Take exit 157 on the right
    // onto Amphitheater Rd" → "exit 157"), in its own gold-bordered chip at
    // the bar's top-right — a ramp is easier to spot by its number than by
    // a sentence.
    final exitLabel = useInstruction
        ? _exitLabelFor(s, _maneuverExit, _instructionLabel)
        : null;
    // Glass banner, Lyft layout in Cruise gold (owner design 2026-11-02,
    // https://claude.ai/artifact/HJUuivr8N4vih8WmmqGnTX): the turn arrow
    // with its distance under it on the left, the instruction big on the
    // right, and the next turn in a gold-glass "Luego" tab hanging under
    // the box. Arrived: the pin, the client's address and the arrival note.
    final showThen = !_phaseArrived && !_endRouteVisible && _thenText.isNotEmpty;
    // The open sheet's dark frost (owner 2026-11-02: "el cuadro de guía,
    // que se vea más borroso el fondo para que no se vea nada detrás").
    final mainBox = TweenAnimationBuilder<double>(
      // The corner over the tab squares off as the tab unfolds, in step.
      tween: Tween(end: showThen ? 0 : 14),
      duration: kSmoothRevealDuration,
      curve: kSmoothRevealCurve,
      builder: (context, corner, child) => GlassSurface(
        blur: kGlassSheetBlurOpen,
        tint: glassSheetOpenTint,
        borderRadius: BorderRadius.only(
          topLeft: const Radius.circular(14),
          topRight: const Radius.circular(14),
          bottomRight: const Radius.circular(14),
          // Square over the "Luego" tab; rounds as the tab tucks away.
          bottomLeft: Radius.circular(corner + (14 - corner) * tuck),
        ),
        // The guide's list grows INSIDE this same glass (owner 2026-11-02:
        // "debe de verse que es el mismo") — one surface, one edge, no
        // second box and no divider between them.
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
              child: Row(
                children: [
                  SizedBox(
                    width: 64,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Bigger (44 → 48, user spec 2026-09-19 — the big reference
                        // card) and the indication swaps crossfade — a turn icon
                        // never snaps.
                        AnimatedSwitcher(
                          duration: const Duration(milliseconds: 220),
                          transitionBuilder: (child, anim) => FadeTransition(
                            opacity: anim,
                            child: ScaleTransition(scale: anim, child: child),
                          ),
                          child: Icon(
                              _endRouteVisible
                                  ? Icons.place_rounded
                                  : _maneuverIcon(_maneuverType, _maneuverModifier),
                              key: ValueKey(
                                  '${_endRouteVisible}_${_maneuverType}_$_maneuverModifier'),
                              color: _gold,
                              // A touch bigger again (owner 2026-11-02:
                              // "las flechas un poquito más grandecitas").
                              size: 56),
                        ),
                        if (!_endRouteVisible)
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.fade,
                            softWrap: false,
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 15,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // The exit badge sits over the sentence (owner
                        // 2026-11-02: "este texto puede aparecer de una forma
                        // agradable para que se pueda ver mejor") — beside it,
                        // it squeezed the sentence into a five-line column.
                        if (exitLabel != null)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 6),
                            child: _exitChip(exitLabel),
                          ),
                        Text.rich(
                          TextSpan(
                            children: useInstruction
                                ? _instructionSpans(title)
                                : [TextSpan(text: _keepRefsWhole(title))],
                          ),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            // Un poquito mas grande (user spec 2026-09-27): a full
                            // instruction sentence steps down a size; a bare street
                            // name keeps the big treatment.
                            fontSize: useInstruction ? 20 : 24,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                            height: 1.2,
                          ),
                        ),
                        if (_endRouteVisible) ...[
                          const SizedBox(height: 2),
                          Text(
                            subtitle,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 15,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ],
              ),
            ),
            if (list != null) list,
          ],
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        mainBox,
        // Opening the guide, the "Luego" tab first tucks up under the box
        // (owner 2026-11-02: "no se puede quedar la parte dorada… primero se
        // esconde la parte amarilla y luego sale lo demás"); folding, it
        // comes back down last.
        ClipRect(
          child: Align(
            alignment: Alignment.bottomLeft,
            heightFactor: 1 - tuck,
            // The "Luego" tab: flat solid gold, 2D (owner 2026-11-02: "debe
            // de verse dorada, no opaco… no quiero que se vea como 3D"),
            // dark text, the next turn's icon and street. It unfolds and
            // folds the same way; crossfades as the steps advance.
            child: SmoothReveal(
              visible: showThen,
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 220),
                child: Container(
                  key: ValueKey('then_$_thenText$_thenType$_thenModifier'),
                  decoration: const BoxDecoration(
                    color: kNavGold,
                    borderRadius:
                        BorderRadius.vertical(bottom: Radius.circular(12)),
                  ),
                  padding: const EdgeInsets.fromLTRB(14, 7, 14, 8),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        s.navThen,
                        style: TextStyle(
                          color: const Color(0xFF141414).withValues(alpha: 0.7),
                          fontSize: 15,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(_maneuverIcon(_thenType, _thenModifier),
                          color: const Color(0xFF141414), size: 23),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 220),
                        child: Text(
                          _thenText,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Color(0xFF141414),
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// The trip guide (owner design 2026-11-02, Lyft layout in Cruise gold):
  /// under the turn box itself, every turn left on the leg with the
  /// distance from the one before, ending at the pickup, the stop or the
  /// destination. [t] is how far it has unfolded (0 folded under the box,
  /// 1 open). The arrow at its foot (or a tap on the box) folds it back; it
  /// only unfolds as far as the list is long, so the map stays below.
  Widget _buildGuide(S s, double t) {
    final nav = _navProgress;
    final cur = nav?.current;
    if (nav == null || cur == null) return const SizedBox.shrink();
    final idx = nav.steps.indexOf(cur);
    final first = widget.riderName.trim().split(' ').first;
    final rows = <Widget>[];
    for (var j = idx + 1; j < nav.steps.length; j++) {
      final st = nav.steps[j];
      final last = j == nav.steps.length - 1;
      final isArrive = st.maneuverType == 'arrive';
      final title = !isArrive
          ? (st.name.isNotEmpty ? st.name : st.instruction)
          : (last
              ? (widget.toPickup
                  ? s.navPickUpName(first)
                  : s.navDropOffName(first))
              : s.navStopOf(first));
      final sub = !isArrive
          ? ''
          : (last
              ? (widget.toPickup ? widget.pickupAddress : widget.dropoffAddress)
              : widget.stopLabel);
      final exit =
          isArrive ? null : _exitLabelFor(s, st.exitNumber, st.instruction);
      rows.add(Container(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
        // Hairlines between turns only — the first sits flush under the box.
        decoration: BoxDecoration(
          border: j == idx + 1
              ? null
              : Border(
                  top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
                ),
        ),
        child: Row(
          children: [
            Icon(
                isArrive
                    ? Icons.location_on_rounded
                    : _maneuverIcon(st.maneuverType, st.modifier),
                color: Colors.white,
                size: 34),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 18,
                          fontWeight: FontWeight.w600)),
                  if (sub.isNotEmpty)
                    Text(sub,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 14,
                            fontWeight: FontWeight.w500)),
                  if (exit != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: _exitChip(exit),
                    ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            // From the turn before: Mapbox's step distance runs from its
            // maneuver to the next one.
            Text(_fmtDist(nav.steps[j - 1].distanceMeters, s),
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.62),
                    fontSize: 15)),
          ],
        ),
      ));
    }
    final maxH = MediaQuery.maybeOf(context)?.size.height ?? 800;
    // Grows down inside the turn box's own glass: the top shows first, the
    // list is drawn whole and clipped while it folds — it never fades.
    return ClipRect(
      child: Align(
        alignment: Alignment.topCenter,
        heightFactor: t,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxH * 0.62),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ...rows,
                // Folds the list back up into the box (a tap on the box
                // does too).
                GestureDetector(
                  key: const ValueKey('nav-guide-fold-up'),
                  behavior: HitTestBehavior.opaque,
                  onTap: () {
                    HapticService.lightImpact();
                    _setGuide(false);
                  },
                  child: Container(
                    height: 44,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      border: Border(
                        top: BorderSide(
                            color: Colors.white.withValues(alpha: 0.06)),
                      ),
                    ),
                    child: Icon(Icons.keyboard_arrow_up_rounded,
                        color: Colors.white.withValues(alpha: 0.7), size: 28),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// A highway ref never splits across lines: "I-459", "US-280" keep the
  /// number on the hyphen's line (a word joiner after it).
  static String _keepRefsWhole(String text) => text.replaceAllMapped(
      RegExp(r'([A-Za-z])-(\d)'), (m) => '${m[1]}-\u2060${m[2]}');

  /// The instruction made easy to read at a glance (owner 2026-11-02): the
  /// names the driver looks for — the road after "onto"/"hacia" and the
  /// place after "toward"/"en dirección a" — bold and white; the words
  /// around them softer. A sentence with none of those stays all bold.
  static final RegExp _namePart = RegExp(
      r'\b(onto|towards?|hacia|en dirección a|por)\s+(.+?)'
      r'(?=\s+(?:onto|towards?|hacia|en dirección a)\b|[.;]|$)',
      caseSensitive: false);

  List<TextSpan> _instructionSpans(String text) {
    final t = _keepRefsWhole(text);
    final matches = _namePart.allMatches(t).toList();
    if (matches.isEmpty) return [TextSpan(text: t)];
    final soft = TextStyle(
        color: Colors.white.withValues(alpha: 0.72),
        fontWeight: FontWeight.w500);
    final spans = <TextSpan>[];
    var at = 0;
    for (final m in matches) {
      final nameStart = m.start + m[0]!.length - m[2]!.length;
      spans.add(TextSpan(text: t.substring(at, nameStart), style: soft));
      spans.add(TextSpan(text: m[2]));
      at = m.end;
    }
    if (at < t.length) spans.add(TextSpan(text: t.substring(at), style: soft));
    return spans;
  }

  /// "Salida 245" / "Exit 245" for a freeway exit, or null. The exact exit
  /// number first (user spec 2026-09-30: "Salida 155, el numero correcto"):
  /// Mapbox's structured maneuver.exit, in the app's language. The text
  /// regex (both languages: "Take exit 155" / "Tome la salida 155") stays
  /// as the fallback for providers that carry no exit field.
  String? _exitLabelFor(S s, String exitNumber, String instruction) {
    if (exitNumber.isNotEmpty) return '${s.navExitNumber} $exitNumber';
    final m = RegExp(r'(?:exit|salida)\s+[0-9][0-9A-Za-z-]*',
            caseSensitive: false)
        .firstMatch(instruction);
    final raw = m?.group(0) ?? '';
    return raw.isEmpty ? null : raw[0].toUpperCase() + raw.substring(1);
  }

  /// The exit badge: an outlined box — only its border is gold, no fill
  /// (owner 2026-11-02: "en un cuadro encerrado que no sea dorado, quiero
  /// que los bordes solamente sean dorados"), white number.
  Widget _exitChip(String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: _gold, width: 1.5),
        ),
        child: Text(
          label,
          maxLines: 1,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 13,
            fontWeight: FontWeight.w800,
          ),
        ),
      );

  /// Small status pill under the maneuver bar (Rerouting… / offline).
  Widget _buildNavPill(String label, {bool spinner = false, IconData? icon}) {
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

  Widget _navCardButton(({String label, bool filled, VoidCallback onTap}) b) {
    if (b.filled) {
      return ElevatedButton(
        onPressed: b.onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: Colors.black,
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
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
    if (type == 'arrive') return Icons.place_rounded;
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
            _speedStale ? '–' : '$mph',
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
    int quarterTurns = 0,
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
            border: Border.all(color: _gold.withValues(alpha: 0.35), width: 1),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 10,
                offset: const Offset(0, 3),
              ),
            ],
          ),
          child: RotatedBox(
            quarterTurns: quarterTurns,
            child: Icon(icon, color: _gold, size: 22),
          ),
        ),
      ),
    );
  }

}

/// One traffic light / stop sign on the route: its parsed location and kind
/// plus the arc-length where it sits, so the trim cursor can eat it the
/// moment the driver passes — the annotation handle rides along.
class _NavSign {
  _NavSign({required this.s, required this.f});

  final double s;
  final NavFurniture f;
  mapbox.PointAnnotation? annot;
}
