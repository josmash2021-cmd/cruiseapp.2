import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart' show Ticker;
import 'package:flutter/services.dart';
import 'package:flutter_compass/flutter_compass.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;

import '../config/api_keys.dart';
import '../config/map_theme.dart';
import '../config/mapbox_config.dart';
import '../config/page_transitions.dart';
import '../map/map_surface_coordinator.dart';
import '../models/lat_lng.dart';
import '../services/directions_service.dart';
import '../services/haptic_service.dart';
import '../services/socket_service.dart';
import '../utils/mapbox_safe.dart';
import 'package:url_launcher/url_launcher.dart';
import '../utils/route_splice.dart';
import '../utils/smooth_motion.dart';
import '../widgets/neu_style.dart';
import '../widgets/static_route_preview.dart';
import '../widgets/verified_avatar.dart';
import '../l10n/app_localizations.dart';
import 'chat_screen.dart';
import 'help_screen.dart';

/// Find-My pickup screen, shown to the rider when the driver arrives
/// (docs/mockups/find_my_pickup_mockup.html is the approved design).
///
/// Nothing here is pressed to confirm: the phone watches its own GPS against
/// the driver's live position, points a compass arrow at them, and flips to
/// FOUND — green ring, check, glow, pill — while the rider stands at the car
/// (adaptive radius, two consecutive fixes; it flips back to FINDING if they
/// walk away). FOUND writes nothing: the rider reads the 4-digit code to the
/// driver and the driver's PIN entry is the only thing that unlocks Start
/// Ride. The screen NEVER closes by itself: it leaves only when the driver
/// starts the trip (a green "starting your ride" beat, then the fade-out) or
/// when the trip is cancelled (wait timeout).
class RiderConfirmPickupScreen extends StatefulWidget {
  /// Bumped by the tracking screen the instant the DRIVER presses Start
  /// (in_trip lands): the page flips to its green FOUND state immediately,
  /// and the caller fades the whole page out right after — found, then gone,
  /// never a snap (user spec 2026-08-05).
  static final ValueNotifier<int> externalStartPulse = ValueNotifier<int>(0);

  const RiderConfirmPickupScreen({
    super.key,
    required this.driverName,
    required this.vehicleDesc,
    required this.firestoreTripId,
    required this.onConfirmed,
    this.onCancelled,
    this.tripId,
    this.driverPhotoUrl,
    this.driverId,
    this.driverRating,
    this.vehiclePlate,
    this.rideTier,
    this.isAirportTrip = false,
    this.driverPosOf,
    this.driverPhone,
    this.initialDriverPos,
  });

  /// The driver's live position at push time (user spec 2026-09-17): the
  /// mini map must be ALREADY LOADED when the rider lands on this page —
  /// seeded into `_lastDriverPos` + the car's smoother in initState, so the
  /// boot camera centers on the real spot (never the (0,0) ocean) and the
  /// stand-in has an anchor from frame one.
  final LatLng? initialDriverPos;

  /// For the Call round button (Find-My style bottom row).
  final String? driverPhone;

  final String driverName;
  final String vehicleDesc;
  final String? firestoreTripId;
  final int? tripId;
  final String? driverPhotoUrl;
  final String? driverId;
  final double? driverRating;
  final String? vehiclePlate;
  /// Optional: 'standard' | 'premium' | 'vip'. If null we infer from vehicleDesc.
  final String? rideTier;
  /// Airport rides get a longer free wait window (10 min) regardless of tier.
  final bool isAirportTrip;

  /// Live driver position, read on every rider GPS fix — feeds the compass
  /// arrow, the animated distance readout, the proximity FOUND latch and the
  /// mini map's car marker. Null (or a 0,0 reading) keeps the screen in
  /// follow-the-arrow copy with no distance shown.
  final LatLng Function()? driverPosOf;

  /// Called ONLY when the driver starts the trip from their side — never
  /// from proximity. FOUND is pure UI (it writes nothing); this screen
  /// stays up until the trip starts or is cancelled.
  final VoidCallback onConfirmed;

  /// Called when the trip is cancelled (e.g., auto-cancel due to wait timeout).
  final VoidCallback? onCancelled;

  @override
  State<RiderConfirmPickupScreen> createState() =>
      _RiderConfirmPickupScreenState();
}

class _RiderConfirmPickupScreenState extends State<RiderConfirmPickupScreen>
    with TickerProviderStateMixin {
  static const _gold = Color(0xFFE8C547);
  static const _green = Color(0xFF22C55E);
  static const _red = Color(0xFFEF4444);
  // Neumorphic base, not pure black: on #000000 the soft shadows that make
  // the style read simply do not show (see neu_style.dart).
  static const _bg = neuBase;

  // One slow clock for the Find-My particle ring + the animated clock hand.
  late final AnimationController _particleCtrl;

  late final AnimationController _fadeInCtrl;
  late final Animation<double> _fadeInAnim;

  late final AnimationController _fadeOutCtrl;
  late final Animation<double> _fadeOutAnim;

  bool _driverStarted = false; // driver slid Start Trip — green overlay + exit
  StreamSubscription? _tripSub;

  /// 4-digit pickup code the backend mirrors onto the trip doc when the trip
  /// reaches "arrived". Null until it lands — the PIN block stays hidden.
  String? _pickupPin;

  // ── Proximity FOUND latch + compass arrow ──
  // The phone watches its own GPS against the driver's live position, points
  // an arrow at them, and the moment the rider is within 2 m for two
  // consecutive fixes it flips green (FOUND) and writes the confirm flag.
  StreamSubscription<Position>? _riderGpsSub;
  StreamSubscription<CompassEvent>? _compassSub;

  /// Straight-line meters to the driver; negative until both fixes exist.
  double _distanceM = -1;

  /// Bearing rider→driver, degrees clockwise from true north.
  double _bearingToDriver = 0;

  /// Device compass heading (degrees). 0 when the device has no
  /// magnetometer — the arrow then points north-referenced.
  double _heading = 0;

  bool _driverDetected = false; // FOUND state — reversible (unlatches when the rider walks away)
  int _closeFixes = 0;

  /// FOUND enters when two consecutive fixes land inside the proximity
  /// radius. The radius models the COMBINED noise of two phones (user
  /// report 2026-09-17): the rider fix's accuracy plus a flat 8 m for the
  /// driver's fix (the relay carries no accuracy), floored at 12 m — ~40 ft
  /// is "at the car" — and never past [_kDetectMaxMeters], or a basement
  /// fix would mark FOUND a block away.
  static const double _kDetectFloorMeters = 12.0;
  static const double _kDriverNoiseMeters = 8.0;
  static const double _kDetectMaxMeters = 30.0;

  /// FOUND exits only past radius + this buffer (again two consecutive
  /// fixes), so jitter straddling the boundary never flaps the state.
  static const double _kExitBufferMeters = 5.0;

  /// Screen-space angle (radians) the particle crescent is CURRENTLY
  /// facing. Eased toward the arrow's live direction a little every frame
  /// (shortest arc), so the dust swings with the needle instead of
  /// snapping — mutated inside the ring's per-frame builder, no setState.
  double _crescentAngle = -math.pi / 2;

  // ── Hero glow drift (mutated per frame by the glow's AnimatedBuilder) ──
  // The glow centre chases the arrow's direction while FINDING, eases back
  // to centre and gold→green on FOUND — the mockup's paint() loop.
  double _glowX = 0; // percent offsets of the glow centre
  double _glowY = 0;
  double _foundT = 0; // 0 = gold, 1 = green
  final _glowWatch = Stopwatch()..start();
  int _glowLastMs = 0;

  // ── Wait time fee tracking (Uber/Lyft style) ──
  // Per-tier policy. Airport overrides tier with a longer 10 min free window.
  // Free wait counts DOWN (gold); after it expires we count UP and accrue
  // a per-minute charge that will be added to the final fare. Auto-cancel
  // is enforced by the backend / dispatch — this UI only displays state.
  late final int _freeWaitSec;
  late final double _waitFeePerMin;
  Timer? _waitTimer;
  // Seconds elapsed since the driver arrived. Drives both the count-down
  // (while < _freeWaitSec) and the count-up (while >= _freeWaitSec).
  int _waitElapsedSec = 0;

  // ── Mini map (the app's one native Mapbox surface) ──
  /// Identifies this screen to [MapSurfaceCoordinator]. The page is an
  /// inline overlay on top of the rider tracking screen, which holds the
  /// surface until we ask for it — and takes it back when we leave.
  static const String _mapSurfaceOwner = 'RiderFindMyPickup';

  /// The MapWidget mounts only once the coordinator confirms the tracking
  /// screen's surface is gone. Until then the StaticRoutePreview image
  /// stands in, so the strip is never blank.
  bool _miniMapMounted = false;

  mapbox.MapboxMap? _miniMap;
  mapbox.CircleAnnotationManager? _riderDotMgr;
  mapbox.PointAnnotationManager? _carMgr;
  mapbox.CircleAnnotation? _riderDotAnnot;
  mapbox.CircleAnnotation? _riderHaloAnnot;
  mapbox.PointAnnotation? _carAnnot;
  Uint8List? _carBytes;

  /// The DRIVER car glides through SmoothMotion (a relayed feed arrives in
  /// bursts — the engine paces it). The RIDER dot does NOT (user spec
  /// 2026-09-17): this screen reads the phone's OWN GPS stream, which is
  /// already the exact, current position — smoothing it made the dot sit
  /// ~a metre behind the walking rider. `_riderRaw` is the last accepted
  /// fix, held only while the fix reports ~no speed (parked wander is
  /// noise); the moment the rider walks, the dot is on them.
  LatLng? _riderRaw;
  final _driverMotion = SmoothMotion();
  Ticker? _mapTicker;
  Duration _mapLastTick = Duration.zero;
  bool _markersSyncing = false;

  /// Throttle for the distance/bearing refresh that rides the map ticker —
  /// the rider's own GPS can go quiet while the driver walks the last
  /// metres over, and the readout + arrow must not freeze on the last fix.
  Duration _lastDistTick = Duration.zero;

  /// driverPosOf is a pull callback, not a stream — sampled at 1 Hz.
  Timer? _driverSampleTimer;
  StreamSubscription<Map<String, dynamic>>? _driverLocSub;
  double? _lastDriverFixAtMs, _lastDriverFixLat, _lastDriverFixLng;
  LatLng? _prevDriverFix;
  LatLng? _lastDriverPos;

  // Driving route rider→driver, fetched for ONE job (user spec 2026-09-17):
  // snapping the car marker onto the road. It is never drawn — the mini map
  // shows the gold dot and the car, no route line.
  List<LatLng> _snapRoute = const [];
  LatLng? _snapAnchorRider;
  LatLng? _snapAnchorDriver;
  bool _snapFetching = false;
  DateTime _lastSnapFetchAt = DateTime(2000);

  // Camera fit throttle state.
  DateTime _lastFitAt = DateTime(2000);
  LatLng? _fitRiderAnchor;
  LatLng? _fitDriverAnchor;

  /// Set on the first user pan/zoom (the strip is interactive now): the
  /// auto-fit must never drag the camera back once the rider takes it —
  /// the same latch map_picker_screen uses.
  bool _userTookCamera = false;

  /// False until the first REAL fit lands. Scroll/zoom events before that
  /// are the map initializing, not the rider — latching _userTookCamera off
  /// them blocked every refit and the strip stayed on the (0,0) ocean:
  /// "el mini mapa se queda asi, no carga nada" (user report 2026-09-17).
  bool _bootFitted = false;

  @override
  void initState() {
    super.initState();
    RiderConfirmPickupScreen.externalStartPulse.addListener(_onExternalStart);

    // Preloaded positions (user spec 2026-09-17): the strip must be already
    // loaded when the rider lands — the driver's spot comes in from the
    // tracking screen, the rider's own from the OS's last-known fix (free,
    // no wait). The live feeds overwrite both within a second.
    final d0 = widget.initialDriverPos;
    if (d0 != null &&
        isValidLatLng(d0.latitude, d0.longitude) &&
        !(d0.latitude == 0 && d0.longitude == 0)) {
      _lastDriverPos = d0;
      _driverMotion.snapTo(d0.latitude, d0.longitude);
    }
    Geolocator.getLastKnownPosition().then((pos) {
      if (!mounted || pos == null || _riderRaw != null) return;
      _riderRaw = LatLng(pos.latitude, pos.longitude);
      _refreshDistanceBearing();
    }).catchError((_) {});

    // ── Wait time policy per tier (Uber/Lyft inspired) ──
    //
    // rideTier arrives as whatever the caller had on hand: a picker
    // display name ('SUV XL', 'VIP', 'BLACK'), a backend vehicle_type
    // ('black', 'suv_xl') on resume paths, or a legacy tier key. Left
    // raw, the switch below matched only exact 'vip'/'premium' and every
    // Black/SUV XL trip fell to the standard 2-min/$0.40 policy while
    // the backend charged the 5-min/$1.00 one (trips.py
    // _WAIT_POLICY_BY_TYPE). Normalize onto the backend's groups first.
    final tier = _normalizeWaitTier(
        widget.rideTier ?? '', widget.vehicleDesc);
    if (widget.isAirportTrip) {
      _freeWaitSec = 10 * 60;
      _waitFeePerMin = 0.40;
    } else {
      switch (tier) {
        case 'vip':
          _freeWaitSec = 5 * 60;
          _waitFeePerMin = 1.00;
          break;
        case 'premium':
          _freeWaitSec = 3 * 60;
          _waitFeePerMin = 0.60;
          break;
        default: // standard
          _freeWaitSec = 2 * 60;
          _waitFeePerMin = 0.40;
      }
    }
    // 1 Hz tick — cheap, drives both phases of the timer.
    _waitTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted || _driverStarted) return;
      setState(() => _waitElapsedSec++);
    });

    // Content fade-in
    _fadeInCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 700),
    );
    _fadeInAnim = CurvedAnimation(parent: _fadeInCtrl, curve: Curves.easeOut);
    _fadeInCtrl.forward();

    // The Find-My particle ring + the little clock hand both breathe off
    // this one slow clock: 12 s per cycle, repeating — drift, twinkle and
    // needle sweep all derive from its value, one ticker for everything.
    _particleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();

    // Fade out when the driver starts the trip
    _fadeOutCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeOutAnim =
        CurvedAnimation(parent: _fadeOutCtrl, curve: Curves.easeInOut);

    // Listen for the pickup PIN, the driver starting the trip, and cancels.
    _listenForTripStart();

    // Proximity + compass — the FOUND latch.
    _startProximityWatch();

    // The mini map takes the app's one native Mapbox surface from the rider
    // tracking screen underneath — through the coordinator, never alongside
    // it (two live surfaces close the app on iOS). Web has no surface limit
    // but mapbox_maps_flutter does not run there at all: the static stand-in
    // stays up for the whole page lifetime on web.
    if (!kIsWeb) {
      _acquireMapSurface();
      if (widget.driverPosOf != null) {
        _driverSampleTimer = Timer.periodic(
            const Duration(seconds: 1), (_) => _sampleDriverPosition());
      }
      // The live relay is the primary driver feed (2026-09-14): the socket
      // pushes every fix at the driver's own 250–400 ms cadence, so the car
      // glides with the same freshness as the tracking map. The 1 Hz pull
      // sample above stays only as a fallback for quiet-relay paths.
      _startDriverRelayWatch();
    }
  }

  /// Claim the one live Mapbox surface, then mount the mini map.
  ///
  /// [surfaceRemoved] is what makes our own revoke honest: flipping the flag
  /// only schedules the rebuild, so we wait for the frames that unmount the
  /// widget before telling the coordinator we are clear.
  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_miniMapMounted) return;
        _dropMiniMapHandles();
        setState(() => _miniMapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      // Disposed while waiting our turn — do not leave the coordinator
      // holding a claim for a screen that no longer exists.
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    setState(() => _miniMapMounted = true);
  }

  /// Every annotation handle belongs to the PlatformView being torn down —
  /// they all die with it. Nulling them is what keeps a late ticker tick
  /// from writing into a destroyed native map.
  void _dropMiniMapHandles() {
    _miniMap = null;
    _riderDotMgr = null;
    _carMgr = null;
    _riderDotAnnot = null;
    _riderHaloAnnot = null;
    _carAnnot = null;
  }

  /// Watch the rider's own GPS against the driver's live position: keep the
  /// arrow pointed, the distance readout fresh, the mini map's rider dot
  /// gliding, and flip FOUND on/off as consecutive fixes land inside/outside
  /// the adaptive proximity radius.
  void _startProximityWatch() {
    if (kIsWeb) return; // browser GPS is too coarse to point or detect with
    if (widget.driverPosOf == null) return;

    // Compass heading (magnetometer). Some devices have none — events just
    // never arrive and the arrow stays north-referenced.
    try {
      _compassSub = FlutterCompass.events?.listen((event) {
        final h = event.heading;
        if (h == null || !mounted) return;
        if ((h - _heading).abs() > 1.5) setState(() => _heading = h);
      });
    } catch (_) {}

    _riderGpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.bestForNavigation,
        distanceFilter: 0,
      ),
    ).listen((pos) {
      if (!mounted || _driverStarted) return;

      // The mini map's gold dot IS the phone's exact fix (user spec
      // 2026-09-17) — no smoother trailing a metre behind a walking rider.
      // Held only while the fix reports ~no speed (<0.6 m/s): parked wander
      // is noise; the instant the rider walks, the dot is on them.
      final spd = pos.speed.isFinite && pos.speed >= 0 ? pos.speed : null;
      if (_riderRaw == null || spd == null || spd >= 0.6) {
        _riderRaw = LatLng(pos.latitude, pos.longitude);
      }
      _ensureMapTicker();
      if (!_markersSyncing) {
        _markersSyncing = true;
        _syncMiniMapMarkers().whenComplete(() => _markersSyncing = false);
      }

      // Distance, arrow and FOUND detection all read the driver's PHONE —
      // the last raw fix from the relay (_lastDriverPos), never the snapped
      // map marker and never a marked-arrival point. The pull callback is
      // only the bootstrap before the first relay packet lands.
      final driver = _lastDriverPos ?? widget.driverPosOf!();
      if (driver.latitude == 0 && driver.longitude == 0) return;

      final meters = Geolocator.distanceBetween(
          pos.latitude, pos.longitude, driver.latitude, driver.longitude);
      final bearing = Geolocator.bearingBetween(
          pos.latitude, pos.longitude, driver.latitude, driver.longitude);

      setState(() {
        _distanceM = meters;
        _bearingToDriver = (bearing + 360) % 360;
      });

      // Detection: two consecutive fixes inside the radius latch FOUND —
      // a single GPS spike through the threshold cannot trigger it,
      // instant in practice (fixes arrive ~1/s) without being gullible.
      // The radius models the COMBINED noise of two phones (user report
      // 2026-09-17: side-by-side phones read 15-20 ft apart from pure GPS
      // noise and never latched): the rider fix's own accuracy plus a flat
      // 8 m for the driver's fix (the relay carries no accuracy), floored
      // at 12 m — ~40 ft IS "at the car". FOUND is reversible: two
      // consecutive fixes past radius + buffer drop back to FINDING.
      final radius = math.min(
          math.max(pos.accuracy + _kDriverNoiseMeters, _kDetectFloorMeters),
          _kDetectMaxMeters);
      if (_driverDetected) {
        if (meters > radius + _kExitBufferMeters) {
          _closeFixes++;
          if (_closeFixes >= 2) _unlatchFound();
        } else {
          _closeFixes = 0;
        }
      } else {
        if (meters <= radius) {
          _closeFixes++;
          if (_closeFixes >= 2) _latchFound();
        } else {
          _closeFixes = 0;
        }
      }
    }, onError: (Object e) {
      debugPrint('[ConfirmPickup] rider GPS stream error: $e');
    });
  }

  /// Two consecutive fixes within the radius: FOUND — green ring, check,
  /// glow, pill. Pure UI state (user spec 2026-09-16): it writes NOTHING —
  /// the rider still has to read the 4-digit code to the driver, and the
  /// driver's PIN entry is the only thing that unlocks Start Ride. It
  /// NEVER closes the screen: only the driver starting the trip (or a
  /// cancellation) does that.
  void _latchFound() {
    if (_driverDetected || _driverStarted) return;
    _driverDetected = true;
    HapticService.heavyImpact();
    setState(() {});
  }

  /// Two consecutive fixes past radius + buffer: back to FINDING — white
  /// ring, arrow, pill. The rider walked away from the car; walking back
  /// re-latches FOUND.
  void _unlatchFound() {
    if (!_driverDetected || _driverStarted) return;
    _driverDetected = false;
    HapticService.lightImpact();
    setState(() {});
  }

  /// Listen to Firestore for the pickup PIN, the trip status changing to
  /// in_progress/in_trip, or cancelled.
  void _listenForTripStart() {
    final fsId = widget.tripId != null
        ? 'sql_${widget.tripId}'
        : widget.firestoreTripId;
    if (fsId == null || fsId.isEmpty) return;

    _tripSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(fsId)
        .snapshots()
        .listen((snap) {
      if (!mounted || _driverStarted) return;
      final data = snap.data();
      if (data == null) return;

      // The backend mirrors the 4-digit pickup code onto the trip doc when
      // the trip reaches "arrived". Absent → the PIN block stays hidden.
      final pin = (data['pickup_pin'] ?? '').toString().trim();
      if (pin.isNotEmpty && pin != _pickupPin) {
        setState(() => _pickupPin = pin);
      }

      final status = (data['status'] ?? '').toString().toLowerCase().trim();

      // Trip started by the driver — and ONLY that. A startedAt-style
      // timestamp used to count as a start too, and any sync that lands one
      // early (a resumed doc, a backfill) showed "Trip confirmed!" for a
      // Start Trip the driver never pressed. The status is the one signal
      // that means Start Trip: it is written by the driver's own button and
      // by nothing else.
      if (status == 'in_trip' ||
          status == 'in_progress' ||
          status == 'rider_onboard' ||
          status == 'trip_started') {
        _onDriverStartedTrip();
        return;
      }

      // Trip cancelled (e.g., auto-cancel due to wait timeout)
      if (status == 'cancelled' || status == 'canceled') {
        _onTripCancelled(data);
      }
    }, onError: (Object e) {
      // This screen has a REST poll behind it, so a rejected snapshot
      // costs latency rather than correctness. Untreated it was an
      // unhandled error on the rider's most important screen.
      debugPrint('[ConfirmPickup] trip snapshot rejected: $e');
    });
  }

  /// Called when the trip is cancelled while waiting at pickup.
  /// Shows appropriate message and navigates back.
  void _onTripCancelled(Map<String, dynamic> data) {
    final cancelReason = (data['cancel_reason'] ??
            data['cancelReason'] ??
            data['cancellation_reason'] ??
            '')
        .toString()
        .toLowerCase();

    final isWaitTimeout = cancelReason.contains('wait_timeout') ||
        cancelReason.contains('no_show');

    _waitTimer?.cancel();

    if (!mounted) return;

    // Show appropriate message based on cancel reason
    final message = isWaitTimeout
        ? 'Viaje cancelado: no te presentaste al pickup a tiempo.\nTrip cancelled: you did not arrive at pickup on time.'
        : 'Viaje cancelado.\nTrip cancelled.';

    // Show toast/snackbar before navigating
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isWaitTimeout ? _red : Colors.black87,
        duration: const Duration(seconds: 4),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        margin: const EdgeInsets.all(16),
      ),
    );

    // Delay to let user read the message, then call onCancelled or pop
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      if (widget.onCancelled != null) {
        widget.onCancelled!();
      } else {
        Navigator.of(context).pop();
      }
    });
  }

  /// Called when the driver starts the ride from their side: green
  /// full-screen confirmation beat, then the page fades out — the ONLY
  /// path that invokes widget.onConfirmed.
  Future<void> _onDriverStartedTrip() async {
    if (_driverStarted) return;
    _driverStarted = true;
    HapticService.mediumImpact();
    setState(() {});

    // Let the rider read the green "driver confirmed · starting your ride".
    await Future.delayed(const Duration(milliseconds: 2000));
    if (!mounted) return;
    await _fadeOutCtrl.forward();
    if (mounted) widget.onConfirmed();
  }

  /// How far the driver still is, in the rider's own units — feet in
  /// English, meters in Spanish. Tweens between GPS readings so the number
  /// counts toward the new value instead of jumping.
  ///
  /// Nothing is drawn until both fixes exist: "0 ft" while the driver's
  /// position is still unknown would be a lie pointing at your own feet.
  Widget _buildDistanceLine() {
    if (_distanceM < 0) {
      // Hold the slot so the layout doesn't jump when the first fix lands.
      return const SizedBox(height: 36);
    }
    return TweenAnimationBuilder<double>(
      tween: Tween(end: _distanceM),
      // 300 ms (was 600): the readout recomputes every ~300 ms off live
      // phone fixes — a long ease made the number trail reality, which
      // reads as "not real-time" (user report 2026-09-17).
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (context, m, _) {
        final es = S.of(context).isSpanish;
        final v = es ? m : m * 3.28084;
        final small = TextStyle(
          fontFamily: 'Poppins',
          color: Colors.white.withValues(alpha: 0.55),
          fontSize: 13,
          fontWeight: FontWeight.w600,
        );
        return SizedBox(
          height: 36,
          child: Text.rich(
            TextSpan(children: [
              TextSpan(
                text: '${v.round()}',
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 29,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              TextSpan(text: ' ${es ? 'm' : 'ft'}', style: small),
              TextSpan(text: '  ${S.of(context).toYourDriver}', style: small),
            ]),
          ),
        );
      },
    );
  }

  /// The FINDING / FOUND state pill — the only header: there is no X, the
  /// screen closes by itself when the trip starts (or is cancelled).
  Widget _buildStatePill(bool isFound) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 350),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(20),
        color: isFound ? _green : Colors.transparent,
        border: Border.all(
          color: isFound ? _green : _gold.withValues(alpha: 0.55),
        ),
      ),
      child: Text(
        isFound ? S.of(context).found : S.of(context).finding,
        style: TextStyle(
          fontFamily: 'Poppins',
          color: isFound ? _bg : _gold,
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 2.5,
        ),
      ),
    );
  }

  /// Divider with feathered ends: transparent → gold-ish → transparent.
  Widget _buildDivider() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 28),
      child: Container(
        height: 1.5,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(1),
          gradient: LinearGradient(colors: [
            Colors.transparent,
            Colors.white.withValues(alpha: 0.14),
            _gold.withValues(alpha: 0.55),
            Colors.white.withValues(alpha: 0.14),
            Colors.transparent,
          ], stops: const [
            0.0,
            0.18,
            0.5,
            0.82,
            1.0,
          ]),
        ),
      ),
    );
  }

  /// The two centered spec blocks: LICENSE PLATE and VEHICLE.
  Widget _buildSpecRow() {
    final plate = widget.vehiclePlate;
    final (vehicleColor, vehicleName) = _parseVehicleColor(widget.vehicleDesc);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(
          child: _spec(
            S.of(context).licensePlateLabel.toUpperCase(),
            (plate != null && plate.isNotEmpty) ? plate : '—',
          ),
        ),
        const SizedBox(width: 24),
        Expanded(
          child: _spec(
            S.of(context).vehicleLabel.toUpperCase(),
            vehicleName,
            dot: vehicleColor,
            maxLines: 2,
          ),
        ),
      ],
    );
  }

  /// Leading color words a vehicle description may carry ("Black Chevrolet
  /// Camaro") mapped to the dot shown instead of the word.
  static const Map<String, Color> _vehicleColors = {
    'black': Color(0xFF101013),
    'white': Color(0xFFF5F5F5),
    'silver': Color(0xFFC0C0C8),
    'gray': Color(0xFF8A8A92),
    'grey': Color(0xFF8A8A92),
    'red': Color(0xFFDC2626),
    'blue': Color(0xFF3B82F6),
    'dark blue': Color(0xFF1E3A8A),
    'green': Color(0xFF16A34A),
    'brown': Color(0xFF8B5A2B),
    'beige': Color(0xFFD8C9A8),
    'gold': _gold,
    'yellow': Color(0xFFFACC15),
    'orange': Color(0xFFF59E0B),
    'purple': Color(0xFFA855F7),
  };

  /// Split a leading color word off a vehicle description:
  /// ("Black Chevrolet Camaro" → (black, "Chevrolet Camaro")). An unknown
  /// first word keeps the full text and no dot.
  (Color?, String) _parseVehicleColor(String desc) {
    final trimmed = desc.trim();
    if (trimmed.isEmpty) return (null, trimmed);
    final lower = trimmed.toLowerCase();
    String? hit;
    for (final name in _vehicleColors.keys) {
      if (lower.startsWith('$name ') &&
          (hit == null || name.length > hit.length)) {
        hit = name;
      }
    }
    if (hit == null) return (null, trimmed);
    return (_vehicleColors[hit], trimmed.substring(hit.length).trim());
  }

  Widget _spec(String label, String value, {Color? dot, int maxLines = 1}) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: TextStyle(
            fontFamily: 'Poppins',
            color: Colors.white.withValues(alpha: 0.35),
            fontSize: 9.5,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.6,
          ),
        ),
        const SizedBox(height: 3),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (dot != null) ...[
              Container(
                // Bigger and closer to the name (user spec 2026-09-17).
                width: 14,
                height: 14,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: dot,
                  // The thin light ring is what keeps black and other dark
                  // paints readable on the dark page.
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.45),
                    width: 1,
                  ),
                ),
              ),
              const SizedBox(width: 4),
            ],
            Flexible(
              child: Text(
                value,
                maxLines: maxLines,
                overflow: maxLines > 1 ? null : TextOverflow.ellipsis,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  /// Driver info LEFT (gold-ring avatar, name, rating), free-wait badge
  /// content RIGHT.
  Widget _buildMetaRow() {
    return Row(
      children: [
        VerifiedAvatar(
          photoUrl: widget.driverPhotoUrl,
          uid: widget.driverId,
          fallbackName: widget.driverName,
          radius: 23,
          role: 'driver',
          isVerified: true,
        ),
        const SizedBox(width: 11),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.driverName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white,
                  fontSize: 14.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (widget.driverRating != null) ...[
                const SizedBox(height: 2),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.star_rounded, color: _gold, size: 12),
                    const SizedBox(width: 3),
                    Text(
                      widget.driverRating!.toStringAsFixed(1),
                      style: TextStyle(
                        fontFamily: 'Poppins',
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 12),
        _buildWaitBlock(),
      ],
    );
  }

  /// The wait badge, restyled into the right-aligned block of the meta row.
  /// Counts down the free wait time in gold, then switches to a red
  /// count-up + accrued fee once the rider passes the per-tier threshold.
  /// Pure UI — no charge happens client-side; the backend computes the
  /// final wait fee once the trip ends.
  Widget _buildWaitBlock() {
    final isFreePhase = _waitElapsedSec < _freeWaitSec;
    final freeRemaining = (_freeWaitSec - _waitElapsedSec).clamp(0, _freeWaitSec);
    final extraSec = (_waitElapsedSec - _freeWaitSec).clamp(0, 99 * 60);
    // Charge by the minute, started + rounded up so the rider sees the
    // first $X.XX appear the moment the free window closes.
    final extraMin = (extraSec / 60).ceil();
    final extraFee = (extraMin * _waitFeePerMin);

    String fmt(int totalSec) {
      final m = (totalSec ~/ 60).toString();
      final s = (totalSec % 60).toString().padLeft(2, '0');
      return '$m:$s';
    }

    final labelStyle = TextStyle(
      fontFamily: 'Poppins',
      color: Colors.white.withValues(alpha: 0.35),
      fontSize: 9.5,
      fontWeight: FontWeight.w600,
      letterSpacing: 1.2,
    );

    if (isFreePhase) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _AnimatedClockIcon(listenable: _particleCtrl, size: 11),
              const SizedBox(width: 5),
              Text(S.of(context).freeWaitTime.toUpperCase(), style: labelStyle),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            fmt(freeRemaining),
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: _gold,
              fontSize: 19,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.3,
            ),
          ),
        ],
      );
    }

    // Extra fee phase — count UP, accrued $ visible.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.warning_rounded, color: _red, size: 12),
            const SizedBox(width: 5),
            Text(
              'Extra wait fee active',
              style: TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white.withValues(alpha: 0.70),
                fontSize: 9.5,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        Text(
          '+${fmt(extraSec)}  ·  +\$${extraFee.toStringAsFixed(2)}',
          style: const TextStyle(
            fontFamily: 'Poppins',
            color: _red,
            fontSize: 19,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.3,
          ),
        ),
      ],
    );
  }

  /// The 4-digit pickup code the rider reads out to the driver. Hidden
  /// until the backend mirrors `pickup_pin` onto the trip doc.
  Widget _buildPinRow() {
    final digits = _pickupPin!.padRight(4).substring(0, 4).split('');
    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                S.of(context).pickupCodeTitle,
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white.withValues(alpha: 0.35),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 1.6,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                S.of(context).pickupCodeTellDriver,
                style: TextStyle(
                  fontFamily: 'Poppins',
                  color: Colors.white.withValues(alpha: 0.55),
                  fontSize: 9.5,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final d in digits)
              Container(
                width: 31,
                height: 38,
                margin: const EdgeInsets.only(left: 7),
                decoration: neuBox(
                  radius: 10,
                  borderColor: _gold.withValues(alpha: 0.30),
                ),
                alignment: Alignment.center,
                child: Text(
                  d,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: _gold,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }

  // ── Mini map ─────────────────────────────────────────────────────────

  /// The driver car's live feed: every socket relay packet lands here at the
  /// driver's own cadence (250–400 ms moving, carrying `captured_at` from
  /// the driver's GPS), so the mini-map car is as fresh and precise as the
  /// tracking map's — no 1 Hz quantization.
  void _startDriverRelayWatch() {
    _driverLocSub = SocketService.driverLocationStream.listen((data) {
      if (!mounted || _driverStarted) return;
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (lat == null || lng == null || (lat == 0 && lng == 0)) return;
      final heading = (data['heading'] as num?)?.toDouble();
      final speed = (data['speed'] as num?)?.toDouble();
      _acceptDriverFix(
        LatLng(lat, lng),
        bearing: (heading != null && heading.isFinite) ? heading : null,
        timestampMs: _fixTsMs(data['captured_at'] ?? data['timestamp']),
        speedMps: (speed != null && speed.isFinite && speed >= 0) ? speed : null,
      );
    });
  }

  static double? _fixTsMs(dynamic raw) {
    if (raw is num) return raw.toDouble();
    if (raw is String) return double.tryParse(raw);
    return null;
  }

  /// One dedup discipline for BOTH driver feeds (relay + pull sample): an
  /// out-of-order fix is dropped, and the same fix re-sent (same capture
  /// timestamp or same position) carries no new information — feeding it
  /// twice measured 0 m/s between identical points and dragged the glide
  /// velocity to the floor (the tracking map's old pulse-stop bug).
  void _acceptDriverFix(LatLng d,
      {double? bearing, double? timestampMs, double? speedMps}) {
    final last = _lastDriverFixAtMs;
    if (timestampMs != null && last != null) {
      if (timestampMs < last) return;
      if (timestampMs == last &&
          _lastDriverFixLat != null &&
          (d.latitude - _lastDriverFixLat!).abs() < 1e-6 &&
          (d.longitude - _lastDriverFixLng!).abs() < 1e-6) {
        return;
      }
    }
    if (timestampMs == null &&
        _lastDriverFixLat != null &&
        (d.latitude - _lastDriverFixLat!).abs() < 1e-6 &&
        (d.longitude - _lastDriverFixLng!).abs() < 1e-6) {
      return;
    }
    _lastDriverFixAtMs =
        timestampMs ?? DateTime.now().millisecondsSinceEpoch.toDouble();
    _lastDriverFixLat = d.latitude;
    _lastDriverFixLng = d.longitude;
    _lastDriverPos = d;

    // Bearing only when the fix actually moved — a parked car's raw GPS
    // heading is noise and would spin the marker in place.
    double? brg;
    final prev = _prevDriverFix;
    final movedM = prev == null
        ? double.infinity
        : Geolocator.distanceBetween(
            prev.latitude, prev.longitude, d.latitude, d.longitude);
    if (movedM > 2) {
      brg = bearing ??
          Geolocator.bearingBetween(
              prev!.latitude, prev.longitude, d.latitude, d.longitude);
    }
    _prevDriverFix = d;

    // Display vs measurement (user spec 2026-09-17): the MARKER snaps to the
    // road — a car floating inside a parking-lot block while the driver is
    // on the street reads as a lie. But everything that MEASURES — "N ft",
    // the arrow bearing, the FOUND radius — keeps reading the PHONE's raw
    // fix (_lastDriverPos above), never the snapped display point and never
    // a marked-arrival point.
    final display = _snapToRoad(d) ?? d;
    _driverMotion.setTarget(display.latitude, display.longitude,
        bearing: brg, timestampMs: timestampMs, speedMps: speedMps);
    _ensureMapTicker();
    _maybeRefitMiniMap();
    final r = _riderRaw;
    if (r != null) {
      _maybeFetchSnapRoute(r, d);
    }
  }

  /// Nearest point on the driving route between rider and driver, when the
  /// fix sits within 80 m of it — beyond that the raw fix is the truth
  /// (genuinely off any road we know) and snapping would teleport the car.
  LatLng? _snapToRoad(LatLng p) {
    final pts = _snapRoute;
    if (pts.length < 2) return null;
    final seg = RouteSplice.closestSegmentIndex(pts, p);
    final proj = RouteSplice.projectOnSegment(p, pts[seg], pts[seg + 1]);
    return RouteSplice.haversineM(p, proj) <= 80 ? proj : null;
  }

  /// Fallback for paths where the relay is quiet: sample the pull-based
  /// driver position callback at 1 Hz (same dedup as the relay inside
  /// [_acceptDriverFix], so a re-sent fix never double-feeds).
  void _sampleDriverPosition() {
    if (!mounted || _driverStarted) return;
    final d = widget.driverPosOf?.call();
    if (d == null || (d.latitude == 0 && d.longitude == 0)) return;
    _acceptDriverFix(d);
  }

  void _ensureMapTicker() {
    _mapTicker ??= createTicker(_onMapTick);
    if (!_mapTicker!.isActive) {
      _mapLastTick = Duration.zero;
      _lastDistTick = Duration.zero;
      _mapTicker!.start();
    }
  }

  void _stopMapTicker() => _mapTicker?.stop();

  void _onMapTick(Duration elapsed) {
    if (!mounted) {
      _stopMapTicker();
      return;
    }
    final dt = _mapLastTick == Duration.zero
        ? 0.016
        : (elapsed - _mapLastTick).inMicroseconds / 1e6;
    _mapLastTick = elapsed;
    // Only the car runs through the engine — the rider dot is the phone's
    // exact fix, written by the GPS handler the moment it lands.
    final moved = _driverMotion.tick(dt);
    // Two people standing at a pickup never make tick() report movement —
    // a marker that has a position but no annotation yet (the surface was
    // granted before the first fix) still has to be drawn, or the strip
    // shows no dot and no car.
    final uncreated = (_riderDotMgr != null &&
            _riderDotAnnot == null &&
            _riderRaw != null) ||
        (_carMgr != null &&
            _carBytes != null &&
            _carAnnot == null &&
            _driverMotion.hasPosition);
    if ((moved || uncreated) && !_markersSyncing) {
      _markersSyncing = true;
      _syncMiniMapMarkers().whenComplete(() => _markersSyncing = false);
    }
    // Distance + bearing recompute off the LIVE positions at ~300 ms,
    // not just on rider GPS fixes — the readout and arrow stay live while
    // the driver approaches even if the rider's own stream goes quiet.
    if (elapsed - _lastDistTick >= const Duration(milliseconds: 300)) {
      _lastDistTick = elapsed;
      _refreshDistanceBearing();
    }
    // Park the ticker when the car has nothing left to animate — the
    // next fix (either side) wakes it again via _ensureMapTicker().
    if (!uncreated && _driverMotion.isAtTarget) {
      _stopMapTicker();
    }
  }

  /// Recompute "N ft" and the arrow bearing from the rider's exact phone
  /// fix and the driver's RAW phone fix — never the snapped display point,
  /// never a marked-arrival spot (user spec 2026-09-17). Only rebuilds when
  /// the change is visible (>0.3 m ≈ 1 ft, or >2°) so a 60 fps ticker never
  /// becomes a 60 fps setState.
  void _refreshDistanceBearing() {
    if (_driverStarted) return;
    final rLat = _riderRaw?.latitude, rLng = _riderRaw?.longitude;
    final dLat = _lastDriverPos?.latitude ?? _driverMotion.lat;
    final dLng = _lastDriverPos?.longitude ?? _driverMotion.lng;
    if (rLat == null || rLng == null || dLat == null || dLng == null) return;
    if (dLat == 0 && dLng == 0) return;
    final meters = Geolocator.distanceBetween(rLat, rLng, dLat, dLng);
    final bearing =
        (Geolocator.bearingBetween(rLat, rLng, dLat, dLng) + 360) % 360;
    var gap = (bearing - _bearingToDriver).abs() % 360;
    if (gap > 180) gap = 360 - gap;
    if (_distanceM < 0 || (meters - _distanceM).abs() > 0.3 || gap > 2) {
      setState(() {
        _distanceM = meters;
        _bearingToDriver = bearing;
      });
    }
  }

  Future<void> _onMiniMapCreated(mapbox.MapboxMap ctrl) async {
    _miniMap = ctrl;
    try {
      // Interactive strip (user spec 2026-09-15): pan + pinch/double-tap
      // zoom like every other map — still top-down and north-up, so
      // rotate/pitch stay off.
      ctrl.gestures.updateSettings(mapbox.GesturesSettings(
        scrollEnabled: true,
        pinchToZoomEnabled: true,
        doubleTapToZoomInEnabled: true,
        doubleTouchToZoomOutEnabled: true,
        rotateEnabled: false,
        pitchEnabled: false,
        quickZoomEnabled: true,
      ));
      ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
      ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
      ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
      ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));

      // Every await here is a chance for the surface to be handed back —
      // the `_miniMap != ctrl` guard is how a stale setup stops short of a
      // destroyed native map.
      await _applyMiniMapTheme(ctrl);
      await _setupMiniMapLayers(ctrl);
    } catch (e) {
      // A dead channel here means the surface was revoked mid-setup: there
      // is no map left to draw on, so stopping is the only correct move.
      debugPrint('[ConfirmPickup] mini-map setup cut short: $e');
    }
  }

  /// The mini map's navy/gold theme. Must run on style-loaded, not on
  /// map-created: before the style finishes loading every layer property
  /// write fails silently and the strip stays in factory dark-v11 grey.
  Future<void> _applyMiniMapTheme(mapbox.MapboxMap ctrl) async {
    try {
      await MapTheme.applyNavyGold(ctrl);
    } catch (e) {
      debugPrint('[ConfirmPickup] mini-map theme failed: $e');
    }
  }

  /// Rebuild everything the style load destroyed: annotation managers are
  /// wiped when the style (re)loads, taking the rider dot and the car with
  /// them. Runs once from map-created and again on every style-loaded — the
  /// only two moments a fresh manager certainly sticks.
  Future<void> _setupMiniMapLayers(mapbox.MapboxMap ctrl) async {
    try {
      // A style reload killed the native side of these handles already —
      // null them so the sync below re-creates instead of updating ghosts.
      _riderDotAnnot = null;
      _riderHaloAnnot = null;
      _carAnnot = null;

      final dots = await ctrl.annotations.createCircleAnnotationManager();
      if (!mounted || _miniMap != ctrl) return;
      _riderDotMgr = dots;

      final car = await ctrl.annotations.createPointAnnotationManager();
      if (!mounted || _miniMap != ctrl) return;
      _carMgr = car;
      try {
        // The car lies flat on the road and turns with its bearing.
        await ctrl.style.setStyleLayerProperty(car.id, 'icon-pitch-alignment', 'map');
        await ctrl.style.setStyleLayerProperty(car.id, 'icon-rotation-alignment', 'map');
        await ctrl.style.setStyleLayerProperty(car.id, 'icon-allow-overlap', true);
        await ctrl.style.setStyleLayerProperty(car.id, 'icon-ignore-placement', true);
        await ctrl.style.setStyleLayerProperty(car.id, 'icon-anchor', 'center');
      } catch (_) {}

      await _loadCarIcon();
      if (!mounted || _miniMap != ctrl) return;
      await _syncMiniMapMarkers();
      if (!mounted || _miniMap != ctrl) return;
      await _fitMiniMap(instant: true);
    } catch (e) {
      debugPrint('[ConfirmPickup] mini-map layer setup cut short: $e');
    }
  }

  /// Load the tier car PNG (same rideName→asset mapping as the rider
  /// tracking map) resized to a sane map-icon size.
  Future<void> _loadCarIcon() async {
    if (_carBytes != null) return;
    final rideName = (widget.rideTier ?? widget.vehicleDesc).toLowerCase();
    final carAsset = rideName.contains('vip') ||
            rideName.contains('suv') ||
            rideName.contains('suburban') ||
            rideName.contains('luxury')
        ? 'assets/images/car_suv.png'
        : rideName.contains('sedan') ||
                rideName.contains('premium') ||
                rideName.contains('fusion')
            ? 'assets/images/car_sedan.png'
            : 'assets/images/car_economy.png';
    try {
      final raw = await rootBundle.load(carAsset);
      _carBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
    } catch (e) {
      debugPrint('[ConfirmPickup] car icon load failed ($carAsset): $e');
      try {
        final raw = await rootBundle.load('assets/images/car_economy.png');
        _carBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
      } catch (e) {
        debugPrint('[ConfirmPickup] fallback car icon failed: $e');
      }
    }
  }

  /// Resize a PNG to a sane map-icon size and return PNG bytes (not RGBA) —
  /// the same helper the rider tracking map and the driver trip screen use,
  /// duplicated here rather than dragged across the tracking pipeline.
  Future<Uint8List> _resizePngForMap(Uint8List pngBytes, {int maxDim = 160}) async {
    final codec = await ui.instantiateImageCodec(pngBytes);
    final frame = await codec.getNextFrame();
    final img = frame.image;

    final scale = maxDim / math.max(img.width, img.height);
    final newW = (img.width * scale).round().clamp(1, maxDim);
    final newH = (img.height * scale).round().clamp(1, maxDim);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()));
    canvas.drawImageRect(
      img,
      Rect.fromLTWH(0, 0, img.width.toDouble(), img.height.toDouble()),
      Rect.fromLTWH(0, 0, newW.toDouble(), newH.toDouble()),
      Paint()..filterQuality = FilterQuality.high,
    );
    final picture = recorder.endRecording();
    final resized = await picture.toImage(newW, newH);
    final byteData = await resized.toByteData(format: ui.ImageByteFormat.png);
    resized.dispose();
    picture.dispose();
    img.dispose();
    return byteData!.buffer.asUint8List();
  }

  /// Create/move the rider dot (+ halo) to the phone's exact fix and the
  /// driver car to its smoothed position. Called on the map tick, on every
  /// accepted rider fix, and once after the map sets up.
  Future<void> _syncMiniMapMarkers() async {
    final dots = _riderDotMgr;
    final rLat = _riderRaw?.latitude, rLng = _riderRaw?.longitude;
    if (dots != null && rLat != null && rLng != null) {
      final p = safePoint(rLng, rLat);
      if (p != null) {
        try {
          // Halo first so the solid dot lands on top of it. GOLD, not blue
          // (user spec 2026-09-17): the rider dot matches the app's gold.
          if (_riderHaloAnnot == null) {
            _riderHaloAnnot = await dots.create(mapbox.CircleAnnotationOptions(
              geometry: p,
              circleRadius: 13.0,
              circleColor: _gold.withValues(alpha: 0.22).toARGB32(),
            ));
          } else {
            _riderHaloAnnot!.geometry = p;
            await dots.update(_riderHaloAnnot!);
          }
          if (!mounted) return;
          if (_riderDotAnnot == null) {
            _riderDotAnnot = await dots.create(mapbox.CircleAnnotationOptions(
              geometry: p,
              circleRadius: 7.0,
              circleColor: _gold.toARGB32(),
              circleStrokeWidth: 2.5,
              circleStrokeColor: Colors.white.toARGB32(),
            ));
          } else {
            _riderDotAnnot!.geometry = p;
            await dots.update(_riderDotAnnot!);
          }
        } catch (e) {
          debugPrint('[ConfirmPickup] rider dot sync failed: $e');
        }
      }
    }

    final car = _carMgr;
    final bytes = _carBytes;
    final dLat = _driverMotion.lat, dLng = _driverMotion.lng;
    if (car != null && bytes != null && dLat != null && dLng != null) {
      final p = safePoint(dLng, dLat);
      if (p != null) {
        try {
          if (_carAnnot == null) {
            _carAnnot = await car.create(mapbox.PointAnnotationOptions(
              geometry: p,
              image: bytes,
              iconSize: 0.50,
              iconRotate: _driverMotion.bearing,
            ));
          } else {
            _carAnnot!.geometry = p;
            _carAnnot!.iconRotate = _driverMotion.bearing;
            await car.update(_carAnnot!);
          }
        } catch (e) {
          debugPrint('[ConfirmPickup] car marker sync failed: $e');
        }
      }
    }
  }

  /// Refetch the snap route only when an anchor moved enough to matter
  /// (10 m) and never more often than every 15 s — the strip shows a couple
  /// of hundred metres at most.
  void _maybeFetchSnapRoute(LatLng rider, LatLng driver) {
    if (_snapFetching) return;
    final rA = _snapAnchorRider, dA = _snapAnchorDriver;
    if (rA != null && dA != null) {
      final rMoved = Geolocator.distanceBetween(
          rider.latitude, rider.longitude, rA.latitude, rA.longitude);
      final dMoved = Geolocator.distanceBetween(
          driver.latitude, driver.longitude, dA.latitude, dA.longitude);
      if (rMoved < 10 && dMoved < 10) return;
    }
    if (DateTime.now().difference(_lastSnapFetchAt).inSeconds < 15) return;
    unawaited(_fetchSnapRoute(rider, driver));
  }

  Future<void> _fetchSnapRoute(LatLng rider, LatLng driver) async {
    _snapFetching = true;
    _lastSnapFetchAt = DateTime.now();
    try {
      // DRIVING geometry (user spec 2026-09-17): this route is never drawn
      // — its only job is giving _snapToRoad the road line to put the car
      // marker on. A failed fetch leaves the anchors unset, so the next
      // tick retries (15 s throttle) and the car simply stays unsnapped.
      final result = await DirectionsService(ApiKeys.webServices)
          .getRoute(origin: rider, destination: driver, profile: 'driving');
      if (!mounted) return;
      if (result == null || result.points.length < 2) return;
      final pts = List<LatLng>.from(result.points);
      // The router snaps its ends to the road network — snap them back to
      // the exact anchor positions so the projection reads true distances.
      pts[0] = rider;
      pts[pts.length - 1] = driver;
      _snapRoute = pts;
      _snapAnchorRider = rider;
      _snapAnchorDriver = driver;
    } catch (e) {
      debugPrint('[ConfirmPickup] snap route fetch failed: $e');
    } finally {
      _snapFetching = false;
    }
  }

  /// Refit the camera when either anchor moved more than 6 m, at most once
  /// every 2.5 s — the frame should pursue the pair, not breathe with them.
  void _maybeRefitMiniMap({bool force = false}) {
    // A rider who grabbed the camera keeps it — but only after the first
    // real fit landed (boot events must not lock the strip out).
    if (!mounted || _miniMap == null || (_userTookCamera && _bootFitted)) {
      return;
    }
    final rider = _riderRaw;
    final driver = _lastDriverPos;
    if (rider == null && driver == null) return;

    final now = DateTime.now();
    if (!force && now.difference(_lastFitAt).inMilliseconds < 2500) return;

    var moved = force || _fitRiderAnchor == null;
    if (!moved && rider != null && _fitRiderAnchor != null) {
      moved = Geolocator.distanceBetween(rider.latitude, rider.longitude,
              _fitRiderAnchor!.latitude, _fitRiderAnchor!.longitude) >
          6;
    }
    if (!moved && driver != null && _fitDriverAnchor != null) {
      moved = Geolocator.distanceBetween(driver.latitude, driver.longitude,
              _fitDriverAnchor!.latitude, _fitDriverAnchor!.longitude) >
          6;
    }
    if (!moved) return;

    _lastFitAt = now;
    if (rider != null) _fitRiderAnchor = rider;
    if (driver != null) _fitDriverAnchor = driver;
    unawaited(_fitMiniMap());
  }

  /// Frame rider + driver (or whichever exists) on the strip. The first fit
  /// is instant — easing from the default camera would sweep the globe.
  Future<void> _fitMiniMap({bool instant = false}) async {
    final ctrl = _miniMap;
    if (ctrl == null || !mounted) return;
    final pts = <LatLng>[
      if (_riderRaw != null) _riderRaw!,
      if (_lastDriverPos != null) _lastDriverPos!,
    ].where((p) => p.latitude.isFinite && p.longitude.isFinite).toList();
    if (pts.isEmpty) return;

    try {
      if (pts.length == 1) {
        final cam = mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates:
                  mapbox.Position(pts.first.longitude, pts.first.latitude)),
          zoom: 16.5,
          pitch: 0,
          bearing: 0,
        );
        if (instant) {
          await ctrl.setCamera(cam);
        } else {
          await ctrl.easeTo(cam, mapbox.MapAnimationOptions(duration: 500));
        }
        // The first real fit happened — from here a drag is the RIDER's
        // (boot-time camera events before this are the map initializing,
        // and they used to latch _userTookCamera, parking the strip on the
        // (0,0) ocean forever — the "mini map no carga nada" report).
        _bootFitted = true;
        return;
      }

      double minLat = pts[0].latitude, maxLat = pts[0].latitude;
      double minLng = pts[0].longitude, maxLng = pts[0].longitude;
      for (final p in pts) {
        minLat = math.min(minLat, p.latitude);
        maxLat = math.max(maxLat, p.latitude);
        minLng = math.min(minLng, p.longitude);
        maxLng = math.max(maxLng, p.longitude);
      }
      final cam = await ctrl.cameraForCoordinatesPadding(
        [
          mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
          mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
        ],
        mapbox.CameraOptions(bearing: 0, pitch: 0),
        mapbox.MbxEdgeInsets(top: 34, left: 34, bottom: 34, right: 34),
        null,
        null,
      );
      // A NaN zoom comes back out of .clamp() still NaN — the check has to
      // come first (same discipline as TrackingMapCamera.fitBounds).
      final rawZoom = cam.zoom ?? 16.0;
      final zoom = (rawZoom.isFinite ? rawZoom : 16.0).clamp(12.0, 17.0);
      final center = cam.center;
      final centerOk = center != null &&
          center.coordinates.lat.isFinite &&
          center.coordinates.lng.isFinite;
      final target = mapbox.CameraOptions(
        center: centerOk
            ? center
            : mapbox.Point(
                coordinates: mapbox.Position(
                  (minLng + maxLng) / 2,
                  (minLat + maxLat) / 2,
                ),
              ),
        zoom: zoom,
        pitch: 0,
        bearing: 0,
      );
      if (instant) {
        await ctrl.setCamera(target);
      } else {
        await ctrl.easeTo(target, mapbox.MapAnimationOptions(duration: 500));
      }
      _bootFitted = true;
    } catch (e) {
      debugPrint('[ConfirmPickup] mini-map fit failed: $e');
    }
  }

  /// The live strip (200 px, full width) or its static stand-in while the
  /// surface handoff completes. Interactive (pan/zoom); only the four
  /// borders feather into the page background. No card frame, no veil.
  Widget _buildMiniMap() {
    return SizedBox(
      height: 200,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (!_miniMapMounted)
            _buildMiniMapStandIn()
          else
            RepaintBoundary(
              child: mapbox.MapWidget(
                key: const ValueKey('findmy-minimap'),
                styleUri: MapboxConfig.styleDark,
                cameraOptions: mapbox.CameraOptions(
                  center: mapbox.Point(
                    coordinates: mapbox.Position(
                      _lastDriverPos?.longitude ?? 0,
                      _lastDriverPos?.latitude ?? 0,
                    ),
                  ),
                  zoom: 14.0,
                  pitch: 0.0,
                  bearing: 0.0,
                ),
                textureView: true,
                onMapCreated: _onMiniMapCreated,
                onScrollListener: (_) {
                  if (_bootFitted) _userTookCamera = true;
                },
                onZoomListener: (_) {
                  if (_bootFitted) _userTookCamera = true;
                },
                // The style finishes loading AFTER map-created: theme and
                // annotations only stick from here on. Without this the
                // strip stayed factory grey and a reload wiped the markers.
                onStyleLoadedListener: (_) async {
                  final ctrl = _miniMap;
                  if (ctrl == null || !mounted) return;
                  await _applyMiniMapTheme(ctrl);
                  if (!mounted || _miniMap != ctrl) return;
                  await _setupMiniMapLayers(ctrl);
                },
                onMapLoadErrorListener: (err) {
                  // A dead strip is worse than the static stand-in.
                  debugPrint(
                      '[ConfirmPickup] mini-map load error: ${err.message}');
                  if (mounted && _miniMapMounted) {
                    setState(() => _miniMapMounted = false);
                  }
                },
              ),
            ),
          // Edge-only feather (user spec 2026-09-16): a short _bg→transparent
          // fade on the four borders, just deep enough to hide the hard
          // edge line — the map itself shows through untouched.
          Positioned(
            top: 0, left: 0, right: 0, height: 18,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [_bg, _bg.withValues(alpha: 0.0)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            bottom: 0, left: 0, right: 0, height: 18,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.bottomCenter,
                    end: Alignment.topCenter,
                    colors: [_bg, _bg.withValues(alpha: 0.0)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0, bottom: 0, left: 0, width: 14,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                    colors: [_bg, _bg.withValues(alpha: 0.0)],
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            top: 0, bottom: 0, right: 0, width: 14,
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.centerRight,
                    end: Alignment.centerLeft,
                    colors: [_bg, _bg.withValues(alpha: 0.0)],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The stand-in drawn until the coordinator grants the surface (and for
  /// the page's whole life on web): the same static Mapbox image every
  /// preview in the app uses, framed on rider→driver, pins only.
  Widget _buildMiniMapStandIn() {
    final rider = _riderRaw;
    final driver = _lastDriverPos;
    final anchor = rider ?? driver;
    if (anchor == null) {
      return const ColoredBox(color: Color(0xFF191C24));
    }
    return StaticRoutePreview(
      pickupLat: anchor.latitude,
      pickupLng: anchor.longitude,
      dropoffLat: (rider != null && driver != null) ? driver.latitude : null,
      dropoffLng: (rider != null && driver != null) ? driver.longitude : null,
      // No route line on this strip, stand-in included (user spec 2026-09-17):
      // pins only — the live dot and the car carry the map.
    );
  }

  /// Gold radial glow whose centre drifts toward where the compass arrow
  /// points; gold→green in FOUND. Mutates the glow state per frame off the
  /// shared 12 s clock, exactly like the mockup's paint() loop.
  Widget _buildHeroGlow(bool isFound) {
    return AnimatedBuilder(
      animation: _particleCtrl,
      builder: (context, _) {
        final now = _glowWatch.elapsedMilliseconds;
        final dt = (now - _glowLastMs).clamp(0, 100).toDouble();
        _glowLastMs = now;
        if (isFound) {
          // Green fade in ~0.9 s; the glow eases back to centre — the check
          // points nowhere.
          _foundT = math.min(1.0, _foundT + dt / 900);
          final k = (1 - math.pow(0.01, dt / 1000)).toDouble();
          _glowX += (0 - _glowX) * k;
          _glowY += (0 - _glowY) * k;
        } else {
          // Chase the arrow's screen direction (bearing − heading; north
          // is up): x = sin, y = −cos.
          final rad = (_bearingToDriver - _heading) * math.pi / 180.0;
          final k = (1 - math.pow(0.003, dt / 1000)).toDouble();
          _glowX += (math.sin(rad) * 14 - _glowX) * k;
          _glowY += (-math.cos(rad) * 10 - _glowY) * k;
        }
        return CustomPaint(
          painter: _HeroGlowPainter(
            cxPct: _glowX,
            cyPct: _glowY,
            foundT: _foundT,
          ),
        );
      },
    );
  }

  /// Green full-screen beat shown when the driver starts the trip, right
  /// before the page fades out into the active ride.
  Widget _buildDepartOverlay() {
    // The background blurs, not just dims (user spec 2026-09-12): the rider
    // reads "we're leaving" without the page behind staying legible noise.
    return BackdropFilter(
      filter: ui.ImageFilter.blur(sigmaX: 16, sigmaY: 16),
      child: Container(
      color: _bg.withValues(alpha: 0.45),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 76,
            height: 76,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: _green,
              boxShadow: [
                BoxShadow(
                  color: _green.withValues(alpha: 0.45),
                  blurRadius: 34,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: const Icon(Icons.check_rounded, color: _bg, size: 38),
          ),
          const SizedBox(height: 14),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              S.of(context).driverConfirmedStarting,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontFamily: 'Poppins',
                color: Colors.white,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.2,
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  /// Best-effort tier inference from the vehicle description string.
  /// Caller should pass `rideTier` explicitly when possible — this is a
  /// fallback so the timer always picks a sensible policy.
  ///
  /// Collapse a tier string of ANY provenance onto the backend's wait
  /// policy groups: 'vip' = 5 min free/$1.00 per min (vip, black, suv_xl,
  /// suburban), 'premium' = 3 min/$0.60, everything else 'standard' =
  /// 2 min/$0.40 — mirrors trips.py _WAIT_POLICY_BY_TYPE. 'black' is only
  /// matched in the tier string, never in the vehicle description, where
  /// it is usually the car's COLOR.
  String _normalizeWaitTier(String raw, String desc) {
    final t = raw.toLowerCase().replaceAll('_', ' ').trim();
    bool hasAny(String s, List<String> words) => words.any(s.contains);
    if (hasAny(t, ['vip', 'black', 'suv', 'suburban', 'escalade'])) {
      return 'vip';
    }
    if (hasAny(t, ['premium', 'traverse'])) return 'premium';
    if (t.isNotEmpty &&
        hasAny(t, ['standard', 'compact', 'sedan', 'comfort', 'fusion'])) {
      return 'standard';
    }
    // Tier string decided nothing — fall back to the vehicle model text.
    final inferred = _inferTierFromVehicleDesc(desc);
    return inferred == 'compact' ? 'standard' : inferred;
  }

  String _inferTierFromVehicleDesc(String desc) {
    final d = desc.toLowerCase();
    if (d.contains('suburban') || d.contains('escalade') || d.contains('vip')) {
      return 'vip';
    }
    if (d.contains('traverse') || d.contains('accord') || d.contains('premium')) {
      return 'premium';
    }
    if (d.contains('camry') || d.contains('rav4') || d.contains('compact') ||
        d.contains('sedan')) {
      return 'compact';
    }
    return 'standard';
  }

  void _onExternalStart() {
    if (!mounted || _driverDetected) return;
    HapticService.heavyImpact();
    setState(() => _driverDetected = true);
  }

  @override
  void dispose() {
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    RiderConfirmPickupScreen.externalStartPulse
        .removeListener(_onExternalStart);
    _waitTimer?.cancel();
    _tripSub?.cancel();
    _riderGpsSub?.cancel();
    _compassSub?.cancel();
    _driverSampleTimer?.cancel();
    _driverLocSub?.cancel();
    _mapTicker?.stop();
    _mapTicker?.dispose();
    _particleCtrl.dispose();
    _fadeInCtrl.dispose();
    _fadeOutCtrl.dispose();
    super.dispose();
  }

  /// Find-My style round action button (chat / call / support), with its
  /// label underneath. [filled] is the gold call button of the mockup.
  Widget _roundAction({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool filled = false,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 52,
            height: 52,
            decoration: filled
                ? BoxDecoration(
                    shape: BoxShape.circle,
                    color: _gold,
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.35),
                        blurRadius: 20,
                        offset: const Offset(0, 6),
                      ),
                    ],
                  )
                : neuBox(radius: 26),
            child: Icon(icon, color: filled ? _bg : Colors.white, size: 21),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 9.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
        ],
      ),
    );
  }

  void _openChat() {
    HapticService.lightImpact();
    final nav = Navigator.of(context);
    nav.push(
      chatOpenRoute(
        ChatScreen(
          recipientName: widget.driverName,
          recipientPhotoUrl: widget.driverPhotoUrl,
          recipientId: widget.driverId,
          recipientRole: 'driver',
          avatarInitial: widget.driverName.isNotEmpty
              ? widget.driverName[0].toUpperCase()
              : 'D',
          tripId: widget.tripId,
          currentRole: 'rider',
          currentUserId: null,
        ),
      ),
    );
  }

  /// Call the driver DIRECTLY on his registered number (user spec
  /// 2026-09-13): the rider's dialer opens with it — no Twilio bridge, no
  /// number masking on the rider side. The masked callback flow stays on
  /// the driver's own call button.
  ///
  /// Every failure used to be a silent `return`: no number on the trip, or
  /// the dialer refusing, and the rider just tapped a button that did
  /// nothing — indistinguishable from the app being frozen. Failures now
  /// surface as a snackbar.
  Future<void> _callDriver() async {
    HapticService.lightImpact();
    final phone = (widget.driverPhone ?? '').trim();
    if (phone.isEmpty) {
      debugPrint('[ConfirmPickup] call: no driver phone on the trip payload');
      _showCallFailed();
      return;
    }
    await launchUrl(
      Uri.parse('tel:$phone'),
      mode: LaunchMode.externalApplication,
    );
  }

  void _showCallFailed() {
    if (!mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(S.of(context).callDriverUnavailable),
        backgroundColor: const Color(0xFF1A1A1F),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  /// The app's support chat — the same navigation the trip screen and the
  /// inbox use: one conversation per trip (sessionKey), mid-trip quick
  /// actions (inTrip).
  void _openSupport() {
    HapticService.lightImpact();
    Navigator.of(context).push(
      slideFromRightRoute(CruiseSupportChatScreen(
        inTrip: true,
        sessionKey: widget.tripId != null ? 'trip:${widget.tripId}' : null,
      )),
    );
  }

  /// The Find-My particle ring with the compass needle at its centre.
  ///
  /// Not a button: nothing in here responds to touch. FOUND swaps the
  /// needle for a green check and the dust ring fades white→green.
  ///
  /// Drawn at a rigid 320 and scaled by the caller — the painter derives
  /// every radius from `size`, so the dust, the crescent and the needle
  /// all follow.
  Widget _buildParticleRing(bool isFound) {
    return SizedBox(
      width: 320,
      height: 320,
      child: TweenAnimationBuilder<Color?>(
        tween: ColorTween(end: isFound ? _green : Colors.white),
        duration: const Duration(milliseconds: 900),
        child: Center(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 300),
            switchInCurve: Curves.easeOutBack,
            child: isFound
                ? const Icon(
                    key: ValueKey('c_check'),
                    // Filled, and arrow-sized (user spec 2026-09-17): the
                    // outline read as "diminuto" — a green disc with the
                    // cut-out check is visible across the car (240 → 264,
                    // same weight as the 296 arrow).
                    Icons.check_circle_rounded,
                    color: _green,
                    size: 264,
                  )
                : AnimatedRotation(
                    key: const ValueKey('c_arrow'),
                    // Compass needle: bearing to the driver minus device
                    // heading, short-arc sweep — silky. User spec
                    // 2026-09-17: bigger again (280 → 296) — it must read
                    // instantly at arm's length.
                    turns: (_bearingToDriver - _heading) / 360.0,
                    duration: const Duration(milliseconds: 250),
                    curve: Curves.easeOutCubic,
                    child: const Icon(
                      Icons.arrow_upward_rounded,
                      color: Colors.white,
                      size: 296,
                    ),
                  ),
          ),
        ),
        builder: (context, ringColor, child) {
          return AnimatedBuilder(
            animation: _particleCtrl,
            child: child,
            builder: (context, child) {
              // Ease the crescent toward the arrow's live direction —
              // shortest arc, a fraction per frame: the dust SWINGS with
              // the needle. Screen space: 0° bearing (north) = up.
              final target =
                  (_bearingToDriver - _heading) * math.pi / 180.0 -
                      math.pi / 2;
              var d = (target - _crescentAngle) % (2 * math.pi);
              if (d > math.pi) d -= 2 * math.pi;
              if (d < -math.pi) d += 2 * math.pi;
              _crescentAngle += d * 0.09;
              return CustomPaint(
                painter: _ParticleRingPainter(
                  t: _particleCtrl.value,
                  // FOUND: full even ring, no crescent — there is nowhere
                  // to point.
                  focus: isFound ? null : _crescentAngle,
                  color: ringColor ?? Colors.white,
                ),
                child: child,
              );
            },
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pad = MediaQuery.of(context).padding;
    final isFound = _driverDetected || _driverStarted;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: FadeTransition(
        opacity: _fadeInAnim,
        child: FadeTransition(
        opacity: Tween<double>(begin: 1.0, end: 0.0).animate(_fadeOutAnim),
        child: Scaffold(
          backgroundColor: _bg,
          body: SizedBox.expand(
            child: Stack(
              children: [
                // ── Flat neumorphic base ──
                const Positioned.fill(
                  child: ColoredBox(color: _bg),
                ),

                // ── Gold/green hero glow, chasing the arrow ──
                Positioned.fill(child: _buildHeroGlow(isFound)),

                // ── Main content ──
                Positioned.fill(
                  child: SafeArea(
                    // The bottom inset rides on this Padding, inside the
                    // background color (never a SafeArea floating outside a
                    // colored container — that leaves a transparent strip).
                    child: Padding(
                      padding: EdgeInsets.only(bottom: pad.bottom + 2),
                      child: Column(
                        children: [
                          const SizedBox(height: 6),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 18),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [_buildStatePill(isFound)],
                            ),
                          ),
                          const SizedBox(height: 6),

                          // Ring + distance, the flexible block: the ring is
                          // the only piece that gives on short screens. It is
                          // drawn at 320 and scaled down to ~300 by the
                          // FittedBox.
                          Flexible(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Flexible(
                                  child: ConstrainedBox(
                                    constraints: const BoxConstraints(
                                        maxWidth: 300, maxHeight: 300),
                                    child: FittedBox(
                                      fit: BoxFit.scaleDown,
                                      child: _buildParticleRing(isFound),
                                    ),
                                  ),
                                ),
                                _buildDistanceLine(),
                              ],
                            ),
                          ),
                          const SizedBox(height: 12),

                          _buildDivider(),
                          const SizedBox(height: 14),

                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 24),
                            child: _buildSpecRow(),
                          ),
                          const SizedBox(height: 16),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(horizontal: 24),
                            child: _buildMetaRow(),
                          ),
                          if (_pickupPin != null) ...[
                            const SizedBox(height: 14),
                            Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 24),
                              child: _buildPinRow(),
                            ),
                          ],
                          // Slim gap (was 42): the FOUND hero ring needs the
                          // vertical room — the check must read BIG.
                          const SizedBox(height: 16),

                          // The strip rides the bottom, just above the action
                          // row (user spec 2026-09-17: "colócalo más abajo") —
                          // the Spacer above it hands its room to the hero.
                          const Spacer(),
                          _buildMiniMap(),
                          const SizedBox(height: 10),

                          // Chat / Call / Support
                          Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              _roundAction(
                                icon: Icons.chat_bubble_rounded,
                                label: S.of(context).chat,
                                onTap: _openChat,
                              ),
                              const SizedBox(width: 28),
                              _roundAction(
                                icon: Icons.call_rounded,
                                label: S.of(context).callAction,
                                onTap: _callDriver,
                                filled: true,
                              ),
                              const SizedBox(width: 28),
                              _roundAction(
                                icon: Icons.support_agent_rounded,
                                label: S.of(context).supportAction,
                                onTap: _openSupport,
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // ── Driver-started green confirmation beat ──
                Positioned.fill(
                  child: IgnorePointer(
                    ignoring: !_driverStarted,
                    child: AnimatedOpacity(
                      opacity: _driverStarted ? 1.0 : 0.0,
                      duration: const Duration(milliseconds: 500),
                      child: _buildDepartOverlay(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      ),
    );
  }
}

/// The Find-My particle ring: ~640 dots scattered in a gaussian band
/// around a circle, each drifting slowly along it and twinkling — silky
/// because everything derives from one slow 12 s clock, nothing jumps.
class _ParticleRingPainter extends CustomPainter {
  const _ParticleRingPainter({
    required this.t,
    required this.color,
    this.focus,
  });

  /// 0..1 phase of the shared 12 s controller.
  final double t;
  final Color color;

  /// Screen-space angle (radians) the crescent faces — the arrow's
  /// direction. The dust concentrates in a soft lobe around it (dense and
  /// bright toward the driver, sparse behind) and swings with it. Null
  /// draws the full even ring (FOUND state).
  final double? focus;

  static const int _count = 640;

  // Deterministic per-particle pseudo-randoms — stable across frames.
  double _h(int i, double salt) =>
      (math.sin(i * 12.9898 + salt * 78.233) * 43758.5453).abs() % 1.0;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    // Ring at 44% of the canvas (was 36% — read too small on phone
    // screens); the band narrows to keep the outer edge inside 320/2.
    final baseR = size.width * 0.44;
    final paintDot = Paint();
    final phase = t * 2 * math.pi;

    for (var i = 0; i < _count; i++) {
      final h1 = _h(i, 1), h2 = _h(i, 2), h3 = _h(i, 3), h4 = _h(i, 4);
      // Angle: NO net rotation — full orbits read as "the ring is
      // spinning". Each particle only SWAYS around its home spot, 3°–8°
      // at its own slow tempo (a full sway takes 6–12 s), so neighbours
      // slide gently past one another while the ring itself stays put.
      // Every frequency is an integer multiple of the 12 s cycle: the
      // wrap is seamless.
      final s1 = 2 + (h4 * 2).floor(); // 2..3 sways per cycle (4–6 s each)
      final sway = 0.07 + 0.09 * h1; // 4°..9° of local swing
      final ang = h1 * 2 * math.pi +
          math.sin(phase * s1 + h4 * 6.283) * sway;
      // Radius: gaussian-ish band plus a moderate two-frequency weave —
      // particles thread in and out between each other, milling about
      // rather than holding formation.
      final band = ((h2 + h3) - 1.0) * 13.0;
      final w1 = 2 + (h2 * 2).floor(); // 2..3 cycles per loop
      final w2 = 3 + (h3 * 3).floor(); // 3..5 cycles per loop
      final weave = math.sin(phase * w1 + h2 * 6.283) * 3.5 +
          math.sin(phase * w2 + h4 * 6.283) * 2.5;
      final r = baseR + band + weave;
      // Twinkle: moderate opacity swell, never fully off.
      final twf = 2 + (h3 * 3).floor(); // 2..4
      final tw = 0.18 + 0.65 *
          (0.5 + 0.5 * math.sin(phase * twf + h4 * 6.283));
      var sizePx = 0.7 + 1.9 * h3 * h3;
      var alpha = tw * (0.35 + 0.65 * h2);
      // Crescent: a smooth cosine lobe centered on the arrow's direction.
      // Dots near it keep full presence; the far side fades to a faint
      // trace (never fully off — the ring still reads as a ring).
      final f = focus;
      if (f != null) {
        final lobe = 0.5 + 0.5 * math.cos(ang - f);
        final w = lobe * lobe; // sharpen: dense front, sparse back
        alpha *= 0.08 + 0.92 * w;
        sizePx *= 0.6 + 0.5 * w;
      }
      paintDot.color = color.withValues(alpha: alpha.clamp(0.0, 1.0));
      canvas.drawCircle(
        c + Offset(math.cos(ang) * r, math.sin(ang) * r),
        sizePx,
        paintDot,
      );
    }
  }

  @override
  bool shouldRepaint(_ParticleRingPainter old) =>
      old.t != t || old.color != color || old.focus != focus;
}

/// The soft pool of light behind the hero: an elliptical radial gradient
/// (130% wide × 46% tall, like the mockup) whose centre drifts with the
/// compass arrow and whose color lerps gold→green as [foundT] goes 0→1.
class _HeroGlowPainter extends CustomPainter {
  const _HeroGlowPainter({
    required this.cxPct,
    required this.cyPct,
    required this.foundT,
  });

  /// Glow centre as percent offsets (mockup: the gradient sits at
  /// 50+cx % horizontally, −4+cy % vertically).
  final double cxPct;
  final double cyPct;

  /// 0 = gold, 1 = green (FOUND).
  final double foundT;

  static const _gold = Color(0xFFE8C547);
  static const _green = Color(0xFF22C55E);

  @override
  void paint(Canvas canvas, Size size) {
    final c = Color.lerp(_gold, _green, foundT)!;
    final center = Offset(
      size.width * (0.5 + cxPct / 100),
      size.height * (-4 + cyPct) / 100,
    );
    // The ellipse is a circular radial shader under a Y-squishing canvas
    // transform: horizontal radius 1.30·w, vertical 0.46·h.
    final ySquish = (0.46 * size.height) / (1.30 * size.width);
    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.scale(1.0, ySquish);
    final paint = Paint()
      ..shader = ui.Gradient.radial(
        Offset.zero,
        size.width * 1.30,
        [
          c.withValues(alpha: 0.52),
          c.withValues(alpha: 0.22),
          c.withValues(alpha: 0.06),
          c.withValues(alpha: 0.0),
        ],
        const [0.0, 0.34, 0.52, 0.68],
      );
    canvas.drawRect(
      Rect.fromCenter(
          center: Offset.zero,
          width: size.width * 2.6,
          height: size.width * 2.6),
      paint,
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(_HeroGlowPainter old) =>
      old.cxPct != cxPct || old.cyPct != cyPct || old.foundT != foundT;
}

/// Tiny clock with a sweeping hand — the animated icon on the wait line.
class _AnimatedClockIcon extends StatelessWidget {
  const _AnimatedClockIcon({required this.listenable, this.size = 14});

  final Animation<double> listenable;
  final double size;
  static const Color color = Color(0xFFE8C547);

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: listenable,
      builder: (_, __) => CustomPaint(
        size: Size.square(size),
        painter: _ClockPainter(
          // 6 sweeps per 12 s cycle = one full turn every 2 s.
          handTurns: listenable.value * 6,
          color: color,
        ),
      ),
    );
  }
}

class _ClockPainter extends CustomPainter {
  const _ClockPainter({required this.handTurns, required this.color});

  final double handTurns;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    final c = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2 - 0.8;
    final ring = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.3
      ..strokeCap = StrokeCap.round;
    canvas.drawCircle(c, r, ring);
    // Sweeping "minute" hand.
    final a = handTurns * 2 * math.pi - math.pi / 2;
    canvas.drawLine(
      c,
      c + Offset(math.cos(a), math.sin(a)) * (r - 1.6),
      ring,
    );
    // Short fixed hour hand for the clock silhouette.
    canvas.drawLine(
      c,
      c + const Offset(0, -1) * (r * 0.45),
      ring,
    );
  }

  @override
  bool shouldRepaint(_ClockPainter old) =>
      old.handTurns != handTurns || old.color != color;
}
