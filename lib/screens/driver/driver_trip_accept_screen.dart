import 'dart:async';
import 'dart:convert';
import '../../services/map_launcher_service.dart';
import '../../utils/app_platform.dart';
import '../../widgets/neu_style.dart';
import 'driver_earnings_screen.dart';
import 'driver_menu_screen.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/services.dart';
import '../../services/haptic_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import 'package:firebase_auth/firebase_auth.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import '../../config/page_transitions.dart';
import '../../widgets/verified_avatar.dart';
import '../../widgets/static_route_preview.dart';
import '../../widgets/nav_morph_overlay.dart';
import '../../widgets/map/circular_pin_renderer.dart';
import '../../l10n/app_localizations.dart';
import '../../models/lat_lng.dart';
import '../../map/map_surface_coordinator.dart';
import '../../map/web_map_view.dart';
import '../../config/api_keys.dart';
import '../../services/places_service.dart';
import '../../services/resilient_position_stream.dart';
import '../../utils/driver_location_settings.dart';
import '../../utils/mapbox_safe.dart';
import '../../utils/smooth_motion.dart';
import '../../services/map_controller_cache.dart';
import '../chat_screen.dart';
import '../help_screen.dart';
import '../../services/chat_service.dart';
import '../../services/socket_service.dart';
import 'driver_home_screen.dart';
import 'driver_nav_view.dart';
import 'driver_online_screen.dart';
import '../../services/user_session.dart';
import '../home_screen.dart';
import 'driver_rate_rider_screen.dart';
import '../../services/api_service.dart';
import '../../services/masked_call_service.dart';
import '../../services/complimentary_drink_service.dart';
import '../../services/gps_service.dart';
import '../../services/trip_firestore_service.dart';
import '../../navigation/nav_state_machine.dart';
import '../../state/chained_ride_store.dart';
import '../../utils/responsive.dart';
import '../../utils/name_helper.dart' as nh;
import '../../widgets/offer_countdown_ring.dart';
import '../../services/firebase_auth_recovery.dart';

// ═══════════════════════════════════════════════════════════════════════════
//  DRIVER TRIP ACCEPT SCREEN  — DoorDash-style trip details sheet
//  Shown after driver accepts a ride offer.
//  • Client photo + star rating
//  • Mini Mapbox map preview centred on pickup
//  • Continue  → full navigation to pickup
//  • Directions → same navigation (overview-first)
// ═══════════════════════════════════════════════════════════════════════════

class DriverTripAcceptScreen extends StatefulWidget {
  const DriverTripAcceptScreen({
    super.key,
    required this.tripId,
    required this.riderName,
    this.riderPhotoUrl = '',
    this.riderRating = 0,
    this.riderIsNew = true,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    required this.pickupAddress,
    required this.dropoffAddress,
    required this.fare,
    required this.vehicleType,
    required this.driverPos,
    required this.distToPickupKm,
    required this.etaMinutes,
    this.routePoints,
    this.riderPhone = '',
    this.pickupInstructions = '',
    this.dropoffInstructions = '',
    this.arrivedAtPickup = false,
    this.rideStarted = false,
    this.tripAlreadyStarted = false,
    this.riderId,
  });

  final int tripId;
  final String riderName;
  final String riderPhotoUrl;
  final int? riderId;
  final double riderRating;
  final bool riderIsNew;
  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final String pickupAddress;
  final String dropoffAddress;
  final double fare;
  final String vehicleType;
  final LatLng driverPos;
  final double distToPickupKm;
  final int etaMinutes;
  final List<LatLng>? routePoints;
  final String riderPhone;
  final String pickupInstructions;
  final String dropoffInstructions;
  final bool arrivedAtPickup;
  final bool rideStarted;
  final bool tripAlreadyStarted;

  @override
  State<DriverTripAcceptScreen> createState() => _DriverTripAcceptScreenState();
}

class _DriverTripAcceptScreenState extends State<DriverTripAcceptScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  // ── Colours ──────────────────────────────────────────────────────────────
  static const _gold   = Color(0xFFD4A843);
  // Neumorphic base, not near-black: soft shadows are invisible on
  // #0A0A0A, which is why neuBase exists (see neu_style.dart).
  static const _bg     = neuBase;
  // No _card / _border constants: every surface on this screen now goes
  // through neuBox(), which owns its own fill, shadows and edge.

  static final _usSuffixRe = RegExp(r',\s*United States$');
  static final _prSuffixRe = RegExp(r',\s*Puerto Rico$');

  // ── Firestore doc ID (matches backend convention) ─────────────────────
  String get _fsDocId => 'sql_${widget.tripId}';

  // ── State ─────────────────────────────────────────────────────────────────
  late final AnimationController _fadeCtrl;
  late final Animation<double>   _fadeAnim;
  late final AnimationController _slideCtrl;
  late final Animation<Offset>   _slideAnim;
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _annotMgr;
  mapbox.PolylineAnnotationManager? _polyMgr;

  // ── Start Trip → Continue/Directions fade ──
  bool _tripStarted = false;
  late final AnimationController _btnFadeCtrl;
  late final Animation<double>   _btnFadeAnim;

  // ── Resolved addresses (replace generic placeholders) ──
  late String _pickupAddr;
  late String _dropoffAddr;
  String? _riderPhotoUrl;
  bool _resolvingAddresses = false;

  // ── VIP complimentary drink (null = not VIP or rider hasn't chosen yet) ──
  String? _complimentaryDrink;

  // ── Tilt animation (controller kept for dispose symmetry; the mini map
  //    is fixed top-down since 2026-08-04 and never tilts) ──
  late final AnimationController _tiltCtrl;

  // ── Smooth route draw ──
  Ticker? _routeDrawTicker;
  mapbox.PolylineAnnotation? _routeAnnot;
  List<LatLng> _routePoints = [];

  // ── Pin annotations (pop-in animation runs inline in _onStyleLoaded) ──
  final List<mapbox.PointAnnotation> _pinAnnots = [];

  // ── Start Trip tap state ──
  bool   _slid     = false;

  // ── Mini map animation already played flag ──
  bool _miniMapAnimDone = false;

  // ── Live car on the mini map (2026-08-04) ──
  // Its own annotation manager: the car rotates WITH the map (map-aligned)
  // while the pins stay upright (viewport-aligned on _annotMgr).
  mapbox.PointAnnotationManager? _carMgr;
  mapbox.PointAnnotation? _carAnnot;
  Uint8List? _carBytes;
  StreamSubscription<Position>? _carGpsSub;
  final SmoothMotion _carMotion = SmoothMotion();
  Ticker? _carTicker;
  Duration _carLastTick = Duration.zero;
  bool _carUpdateInFlight = false;
  // Last values actually sent to the native map (2026-08-25 heat fix): the
  // annotation IPC is skipped entirely while the car hasn't moved — a
  // parked car used to pay 60 native updates/second for zero visual change.
  double? _lastSentCarLat;
  double? _lastSentCarLng;
  double? _lastSentCarBearing;
  DateTime _lastEraseAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _eraseHintIdx = 0;
  bool _pickupPopped = false;
  mapbox.PolylineAnnotation? _sweepAnnot;
  LatLng? _prevCarFix;

  // ── Camera angle cycling removed 2026-08-04 (top-down only). The timer
  //    and controller stay declared for their dispose calls.
  Timer? _camCycleTimer;
  AnimationController? _camCycleCtrl;

  // ── Continuous GPS → GpsService (keeps RTDB live for rider tracking) ──
  ResilientPositionStream? _liveGps;
  final GpsService _gpsService = GpsService();

  // ── Arrived at pickup detection ──
  bool _nearPickup = false;
  StreamSubscription<Position>? _gpsSub;
  static const _pickupRadiusMeters = 100.0;

  // ── Arrived at pickup confirmation (driver slid "Arrived") ──
  bool _arrivedConfirmed = false;
  double _arrivedSlideVal = 0;
  bool _arrivedSlidDone = false;

  // ── Ride started (passenger picked up → "Start Ride") ──
  bool _rideStarted = false;
  bool _startRideSlidDone = false;
  /// Thumb is down on Start Ride — drives the sink/spring animation.
  bool _startRidePressed = false;

  // ── Rider pickup confirmation listener ──
  StreamSubscription? _riderConfirmSub;
  bool _riderConfirmedPickup = false;

  // ── Pickup PIN (arrived / waiting-for-rider stage) ──
  // The rider reads a 4-digit code from their app; a correct entry sets the
  // same local flag the Firestore listener sets, so the "Waiting for your
  // rider" pill morphs into Start Ride even if the backend's flag write
  // lands a beat later.
  final TextEditingController _pinCtrl = TextEditingController();
  final FocusNode _pinFocusNode = FocusNode();
  late final AnimationController _pinShakeCtrl;
  bool _pinSubmitting = false;
  bool _pinLocked = false;
  Timer? _pinLockTimer;
  String? _pinError; // 'invalid' | 'locked'

  /// True exactly while [_buildSlideWaitingForRider] is the active phase
  /// widget — never before arriving, never after the ride started.
  bool get _showPickupPinCard =>
      _arrivedConfirmed && !_rideStarted && !_riderConfirmedPickup;

  // Safety-net: backend status poll. The Firestore listener above is the
  // primary signal but can silently miss events (auth expired, doc not
  // mirrored yet, transient network). Without this poll the driver can
  // sit on the FINISH RIDE screen forever after dispatch cancels/completes.
  Timer? _statusPollTimer;
  bool _isPollingTripStatus = false; // prevents overlapping in-flight requests

  // ── Mid-trip route change from the rider (multi-stop v1) ──
  LatLng? _stopLatLng;
  String _stopLabel = '';
  LatLng? _dropoffOverride;
  Timer? _routeBannerTimer;
  bool _proposalDeclineShown = false;
  mapbox.PointAnnotation? _stopPinAnnot;

  /// Every consumer reads the dropoff through this: a mid-trip
  /// destination change re-aims proximity detection, navigation and the
  /// mini map without touching the immutable widget param.
  LatLng get _dropoffLL => _dropoffOverride ?? widget.dropoffLatLng;

  // ── "Passenger confirmed" banner above the action button ──
  bool _confirmBannerShow = false;
  Timer? _confirmBannerTimer;

  // ── Driver pre-pickup cancel (POST /trips/{id}/driver-cancel) ──
  bool _driverCancelling = false;
  LatLng? _lastDriverPos; // latest live GPS fix, for the cancel audit trail

  /// Live distance to the pickup, in miles, shown on the mini map.
  ///
  /// Seeded from the value dispatch sent so the chip is never blank, then
  /// refreshed from the driver's own GPS as they drive.
  double? _milesToPickup;

  /// Miles to pickup, formatted. Falls back to the dispatch estimate until
  /// the first GPS fix lands.
  String get _pickupDistanceLabel {
    final raw = _milesToPickup ?? (widget.distToPickupKm * 0.621371);
    // Non-finite would render as "NaN mi" on the card.
    final mi = raw.isFinite && raw > 0 ? raw : 0.0;
    // No comparison sign. Under a tenth of a mile it gains a decimal
    // instead: "0.04 mi" says the same thing as the old "less than 0.1 mi"
    // and says it more precisely, without an operator in the driver's face.
    if (mi < 0.1) return '${mi.toStringAsFixed(2)} mi';
    return '${mi.toStringAsFixed(1)} mi';
  }

  /// What the passenger wrote when they booked, with machine-appended lines
  /// stripped.
  ///
  /// `notes` is a shared column: the backend appends a `Wait started:`
  /// timestamp line to it when the pickup wait timer starts, so the raw value
  /// is not safe to put in front of a driver. Filtering here instead of at the
  /// call sites means every route into this screen is sanitised, not just the
  /// one I plumbed.
  String get _passengerInstructions {
    final raw = widget.pickupInstructions.trim();
    if (raw.isEmpty) return '';
    return raw
        .split('\n')
        .map((l) => l.trim())
        // "Web booking — {name}" is dispatch bookkeeping the web widget
        // stamps into notes, not something the passenger asked for.
        .where((l) =>
            l.isNotEmpty &&
            !l.startsWith('Wait started:') &&
            !l.toLowerCase().startsWith('web booking'))
        .join('\n');
  }

  // ── Dropoff proximity + trip finish ──
  bool _nearDropoff = false;
  StreamSubscription<Position>? _dropoffGpsSub;
  static const _dropoffRadiusMeters = 100.0;
  double _finishSlideVal = 0;
  bool _finishSlidDone = false;
  bool _tripFinished = false;
  Timer? _finishNavTimer;
  late final AnimationController _finishFadeCtrl;
  late final Animation<double> _finishFadeAnim;

  // ── Shimmer sweep animation for slide buttons ──
  late final AnimationController _shimmerCtrl;
  late final Animation<double> _shimmerAnim;

  // ── Map preview surface handoff ──
  /// Identifies this screen to [MapSurfaceCoordinator]. The 190pt preview
  /// card is a live MapWidget again, and there can be one native Mapbox
  /// surface in the whole app — this screen is always pushed over the
  /// online screen, which holds that surface until we ask for it.
  static const String _mapSurfaceOwner = 'DriverTripAccept';

  /// The MapWidget mounts only once the coordinator confirms the previous
  /// holder's surface is gone. Until then the StaticRoutePreview image
  /// stands in, so the card is never blank.
  bool _previewMapMounted = false;

  // ── In-app navigation mode (DriverNavView) ─────────────────────────────
  //
  // Continue / Directions no longer leave the app: the preview releases the
  // one native surface, the nav view claims it full-screen, and Exit hands
  // it back. Two live MapWidgets are the iOS crash — the handoff below is
  // ordered so they never coexist.
  bool _navMode = false;
  bool _navEntering = false;
  bool _navExiting = false;

  // ── Mini-map ⇄ navigation morph ────────────────────────────────────────
  //
  // A native Mapbox surface can't be resized or cross-faded mid-flight, so
  // the morph animates a one-shot snapshot of the departing map instead
  // (NavMorphOverlay). Enter blooms the preview's last frame out of the
  // card rect; exit dissolves the nav map's last frame back into it. Any
  // snapshot failure falls back to the plain fade — never a broken screen.
  final GlobalKey _miniMapBoxKey = GlobalKey();
  final GlobalKey<DriverNavViewState> _navViewKey =
      GlobalKey<DriverNavViewState>();
  Uint8List? _morphBytes;
  Rect? _morphRect;
  bool _morphEnter = false;
  bool _morphReveal = false;
  bool _morphExit = false;
  Timer? _navReadyTimeout;

  /// Web only: GL JS controller for the preview (no surface limit there).
  WebMapController? _webMapCtrl;

  // ── Chained (next-ride) offer over this trip ─────────────────────────────
  //
  // Dispatch flags an offer `chained` when it goes to a driver still driving
  // another trip (backend/routers/dispatch.py). The online screen underneath
  // hears the same stream, but its card UI is invisible below this one — so
  // the card lives HERE, on the screen the driver is actually looking at.
  // The event bus keeps one queue per subscription (event_bus.py), so this
  // stream is independent of the hidden screen's. Camera and route stay with
  // the trip being driven: the card is the only thing this feature draws.
  int? _driverId;
  StreamSubscription<List<Map<String, dynamic>>>? _chainedSseSub;
  Timer? _chainedPollTimer;
  bool _chainedSseActive = false;
  Map<String, dynamic>? _chainedOffer;
  final Set<int> _chainedRejectedIds = {};
  bool _chainedBusy = false;

  // ── Trip distance pickup→dropoff ─────────────────────────────────────────
  double get _tripKm {
    const r = 6371.0;
    final lat1 = widget.pickupLatLng.latitude  * math.pi / 180;
    final lat2 = _dropoffLL.latitude * math.pi / 180;
    final dLat = (_dropoffLL.latitude  - widget.pickupLatLng.latitude)  * math.pi / 180;
    final dLng = (_dropoffLL.longitude - widget.pickupLatLng.longitude) * math.pi / 180;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1) * math.cos(lat2) *
        math.sin(dLng / 2) * math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
  }
  int get _tripEta => (_tripKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);

  void _enforceDriverRole() {
    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context).pushAndRemoveUntil(
          fadeThroughRoute(const HomeScreen()),
          (_) => false,
        );
      }
    });
  }

  // ══════════════════════════════════════════════════════════════════════
  //  CHAINED (NEXT-RIDE) OFFER over the live trip
  // ══════════════════════════════════════════════════════════════════════

  void _startChainedOfferListener() {
    ApiService.getCurrentUserId().then((id) {
      if (!mounted || id == null) return;
      _driverId = id;
      _chainedSseSub = ApiService.streamDriverOffers(id).listen(
        (offers) {
          _chainedSseActive = true;
          _onChainedOffers(offers);
        },
        onError: (_) => _chainedStreamDown(),
        onDone: _chainedStreamDown,
      );
    });
  }

  /// SSE died — poll the same endpoint every 5 s until it comes back.
  /// Chained offers live 20 s, so a 5 s poll cannot miss one whole.
  void _chainedStreamDown() {
    if (!mounted) return;
    _chainedSseActive = false;
    _chainedPollTimer ??=
        Timer.periodic(const Duration(seconds: 5), (_) async {
      if (!mounted || _chainedSseActive || _driverId == null) return;
      try {
        final offers = await ApiService.getDriverPendingOffers(_driverId!);
        if (!mounted) return;
        _onChainedOffers(offers);
      } catch (_) {}
    });
  }

  void _onChainedOffers(List<Map<String, dynamic>> offers) {
    if (!mounted) return;
    String idOf(Map<String, dynamic> o) =>
        (o['offer_id'] ?? o['id'] ?? '').toString();
    final visible = offers.where((o) {
      // Mid-trip only chained offers belong here — anything else is for the
      // online screen's flow.
      if (o['chained'] != true) return false;
      final oid = (o['offer_id'] as num?)?.toInt();
      if (oid != null && _chainedRejectedIds.contains(oid)) return false;
      return true;
    }).toList();
    if (visible.isEmpty) return; // dismissal is the countdown ring's job
    final newest = visible.first;
    final currentId =
        _chainedOffer != null ? idOf(_chainedOffer!) : null;
    if (idOf(newest) != currentId) {
      // A NEW offer, not a re-send of the card already up: cue the driver
      // the same way the online screen does on a fresh offer.
      HapticService.heavyImpact();
    }
    setState(() => _chainedOffer = newest);
  }

  int? get _chainedOfferTimeoutSecs =>
      (_chainedOffer?['offer_timeout_seconds'] as num?)?.toInt();

  Future<void> _acceptChained() async {
    final offer = _chainedOffer;
    if (offer == null || _chainedBusy) return;
    final offerId = (offer['offer_id'] as num?)?.toInt();
    if (offerId == null || _driverId == null) {
      _chainedSnack('Unable to accept — please try again.');
      return;
    }
    setState(() => _chainedBusy = true);
    try {
      // Same lock as the online screen's _acceptChainedOffer: the ride is
      // ours from this moment, inside its countdown window.
      await ApiService.acceptRideOffer(offerId: offerId, driverId: _driverId!);
      ChainedRideStore.set(offer);
      setState(() => _chainedOffer = null);
      _chainedSnack('Next ride booked — it starts after this dropoff.');
    } catch (e) {
      debugPrint('[Driver] chained accept failed: $e');
      // It is gone — remember that, or the next SSE/poll delivery paints
      // the same dead offer again (audit #19).
      _chainedRejectedIds.add(offerId);
      setState(() => _chainedOffer = null);
      _chainedSnack('That ride is no longer available.');
    } finally {
      if (mounted) setState(() => _chainedBusy = false);
    }
  }

  /// Reject — by tap or by the countdown ring firing. Either way the driver
  /// stays on the trip being driven; only the card leaves.
  Future<void> _rejectChained() async {
    final offer = _chainedOffer;
    if (offer == null || _chainedBusy) return;
    final offerId = (offer['offer_id'] as num?)?.toInt();
    if (offerId != null) _chainedRejectedIds.add(offerId);
    setState(() => _chainedOffer = null);
    if (offerId != null && _driverId != null) {
      await ApiService.rejectRideOffer(offerId: offerId, driverId: _driverId!)
          .catchError((_) => <String, dynamic>{});
    }
  }

  void _chainedSnack(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 3),
    ));
  }

  /// The next-ride card, floating over the trip page. Compact on purpose:
  /// the live trip owns the map, the camera and the route — this card never
  /// touches any of them.
  Widget _buildChainedOfferCard(Map<String, dynamic> offer) {
    final s = S.of(context);
    final fare = (offer['driver_earnings'] as num?)?.toDouble() ??
        (offer['fare'] as num?)?.toDouble() ??
        0.0;
    final riderName =
        (offer['rider_name'] as String?)?.trim().isNotEmpty == true
            ? (offer['rider_name'] as String).trim()
            : s.riderFallback;
    final pickup = (offer['pickup_address'] as String?) ?? '';
    final offerId = (offer['offer_id'] as num?)?.toInt() ?? 0;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: neuBox(radius: 18),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              OfferCountdownRing(
                key: ValueKey('chained_$offerId'),
                seconds: _chainedOfferTimeoutSecs ?? kOfferCountdownSeconds,
                onExpired: _rejectChained,
                child: Image.asset(
                  'assets/images/cruise_logo.png',
                  fit: BoxFit.contain,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(s.newRideOffer,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 14,
                            fontWeight: FontWeight.w800)),
                    const SizedBox(height: 2),
                    Text(riderName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.65),
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600)),
                    if (pickup.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(pickup,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.45),
                              fontSize: 12)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 10),
              Text('\$${fare.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: _gold,
                      fontSize: 20,
                      fontWeight: FontWeight.w900)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: _chainedBusy ? null : _rejectChained,
                  child: Container(
                    height: 44,
                    decoration: neuBox(radius: 12, pressed: true),
                    alignment: Alignment.center,
                    child: Text(s.reject,
                        style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.7),
                            fontSize: 14,
                            fontWeight: FontWeight.w700)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                flex: 2,
                child: GestureDetector(
                  onTap: _chainedBusy ? null : _acceptChained,
                  child: Container(
                    height: 44,
                    decoration: BoxDecoration(
                      color: _gold,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    alignment: Alignment.center,
                    child: Text(s.acceptRideButton,
                        style: const TextStyle(
                            color: Colors.black,
                            fontSize: 14,
                            fontWeight: FontWeight.w800)),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    // Observed for one reason: coming back from background is where a dead
    // GPS stream is found, and this screen owns the one the passenger sees.
    WidgetsBinding.instance.addObserver(this);
    _enforceDriverRole();
    _pickupAddr = widget.pickupAddress;
    _dropoffAddr = widget.dropoffAddress;
    _riderPhotoUrl = _normalizedPhotoUrl(widget.riderPhotoUrl);
    _resolveGenericAddresses();
    _resolveRiderPhotoFromTrip();
    _loadComplimentaryDrinkIfVip();

    // If returning from nav (trip already started), skip slide-to-confirm
    if (widget.arrivedAtPickup) {
      _tripStarted = true;
      _slid = true;
      _nearPickup = true;
      _arrivedConfirmed = true;
      _arrivedSlidDone = true;
    }
    // If ride already started (returning from dropoff nav), skip both sliders
    if (widget.rideStarted) {
      _tripStarted = true;
      _slid = true;
      _nearPickup = true;
      _arrivedConfirmed = true;
      _arrivedSlidDone = true;
      _rideStarted = true;
      _startRideSlidDone = true;
    }
    // Resume at Continue/Directions (trip accepted, en route to pickup)
    if (widget.tripAlreadyStarted && !widget.arrivedAtPickup && !widget.rideStarted) {
      _tripStarted = true;
      _slid = true;
    }

    _fadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..forward();
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);

    // Slide-up animation: fast snap
    _slideCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )..forward();
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, 0.04),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _slideCtrl, curve: Curves.easeOutCubic));

    // Tilt controller: created only for dispose symmetry — the mini map
    // is fixed top-down since 2026-08-04 and never tilts.
    _tiltCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    );

    // Button fade controller for Start Trip → Continue/Directions transition
    _btnFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
      value: (widget.arrivedAtPickup || widget.rideStarted) ? 1.0 : 0.0,
    );
    _btnFadeAnim = CurvedAnimation(parent: _btnFadeCtrl, curve: Curves.easeOut);

    // Start GPS proximity detection for pickup (only if not already picked up)
    if (!widget.rideStarted) _startPickupProximityDetection();
    // Start dropoff proximity detection if ride already started
    if (widget.rideStarted) _startDropoffProximityDetection();

    // Finish overlay fade controller
    _finishFadeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _finishFadeAnim = CurvedAnimation(parent: _finishFadeCtrl, curve: Curves.easeInOut);

    // Shimmer sweep for slide buttons (repeating left→right light)
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();
    _shimmerAnim = Tween<double>(begin: -1.0, end: 2.0).animate(
      CurvedAnimation(parent: _shimmerCtrl, curve: Curves.easeInOut),
    );

    // Shake for a rejected pickup PIN (403).
    _pinShakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 420),
    );

    // Listen for rider confirming pickup in Firestore
    _listenForRiderConfirmation();
    _startStatusPoll();
    _startChainedOfferListener();

    // Start continuous GPS → GpsService so RTDB stays fresh for rider tracking.
    // The online screen's stream may not reliably feed GpsService while this
    // screen is on top, so we ensure the driver's live location is always
    // uploaded during the entire trip lifecycle.
    _startLiveGpsForRider();

    // Fetch the route right away: the StaticRoutePreview fallback draws it
    // while the surface handoff completes, and _onStyleLoaded reuses it so
    // the live map does not fetch a second time.
    _loadPreviewRoute();

    // Mount the live preview map once the screen we came from has actually
    // let go of the native surface. Web has no surface limit — mount now.
    if (kIsWeb) {
      _previewMapMounted = true;
    } else {
      _acquireMapSurface();
    }
  }

  /// Claim the one live Mapbox surface, then mount our map.
  ///
  /// [surfaceRemoved] is what makes our own revoke honest: flipping the flag
  /// only schedules the rebuild, so we wait for the frames that unmount the
  /// widget before telling the coordinator we are clear.
  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_previewMapMounted) return;
        setState(() => _previewMapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      // Disposed while waiting our turn — do not leave the coordinator
      // holding a claim for a screen that no longer exists.
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    setState(() => _previewMapMounted = true);
  }

  // ── In-app navigation mode ─────────────────────────────────────────────

  /// The backend appends `Wait started: <iso>` to the trip notes when the
  /// pickup wait timer opens; the nav view's wait divider drains from it so
  /// a reopened screen shows the real remaining time, not a fresh 5:00.
  DateTime? get _waitStartedAt {
    for (final line in widget.pickupInstructions.split('\n')) {
      final t = line.trim();
      if (t.startsWith('Wait started:')) {
        return DateTime.tryParse(
            t.substring('Wait started:'.length).trim());
      }
    }
    return null;
  }

  /// Continue / Directions → in-app turn-by-turn navigation.
  ///
  /// Hand the surface over BEFORE the nav view mounts: two live MapWidgets
  /// are the iOS crash, and the coordinator only revokes politely — the
  /// preview lets go voluntarily here.
  Future<void> _enterNavMode() async {
    if (_navMode || _navEntering) return;
    _navEntering = true;
    HapticService.mediumImpact();
    // Morph continuity: capture the preview's exact last frame BEFORE the
    // surface handoff unmounts it. The overlay blooms this image out of the
    // card rect while the nav view's own map initialises underneath.
    final morphRect = _miniMapRect();
    final morphBytes = await _captureMapSnapshot(_map);
    if (!mounted) {
      _navEntering = false;
      return;
    }
    if (morphBytes != null && morphRect != null) {
      // Decode off the morph's critical path — the first frame must paint
      // with the image already warm.
      try {
        await precacheImage(MemoryImage(morphBytes), context);
      } catch (_) {}
      if (!mounted) {
        _navEntering = false;
        return;
      }
    }
    if (_previewMapMounted) {
      setState(() {
        _previewMapMounted = false;
        if (morphBytes != null && morphRect != null) {
          _morphBytes = morphBytes;
          _morphRect = morphRect;
          _morphEnter = true;
          _morphReveal = false;
          // A re-entry during the exit dissolve supersedes it — one morph
          // overlay at a time.
          _morphExit = false;
        }
      });
      await surfaceRemoved();
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    }
    if (!mounted) {
      _navEntering = false;
      return;
    }
    setState(() => _navMode = true);
    _navEntering = false;
    if (_morphEnter) {
      // Belt and suspenders: if the nav map never signals ready (revoked
      // surface, init failure), reveal anyway — the driver is never left
      // stuck under a frozen snapshot.
      _navReadyTimeout?.cancel();
      _navReadyTimeout = Timer(const Duration(seconds: 4), () {
        if (!mounted || !_morphEnter) return;
        setState(() => _morphReveal = true);
      });
    }
  }

  /// Back out of navigation: the nav view's dispose releases its surface
  /// claim, and the preview card claims it back through the coordinator.
  void _exitNavMode() {
    if (!_navMode || _navExiting) return;
    _navExiting = true;
    _collapseNavMode();
  }

  /// Reverse morph: capture the nav map's last frame, cover the view with
  /// it (identical pixels — the swap is invisible), then unmount the nav
  /// view and dissolve that frame back into the mini-map card while the
  /// preview re-claims the surface underneath.
  Future<void> _collapseNavMode() async {
    final morphBytes =
        await _captureMapSnapshot(_navViewKey.currentState?.mapForSnapshot);
    if (!mounted) {
      _navExiting = false;
      return;
    }
    final morphRect = _miniMapRect();
    // An in-flight enter morph is superseded — one overlay at a time.
    _navReadyTimeout?.cancel();
    if (morphBytes != null && morphRect != null) {
      try {
        await precacheImage(MemoryImage(morphBytes), context);
      } catch (_) {}
      if (!mounted) {
        _navExiting = false;
        return;
      }
      setState(() {
        _morphBytes = morphBytes;
        _morphRect = morphRect;
        _morphEnter = false;
        _morphReveal = false;
        _morphExit = true;
      });
      // The overlay's first frame is pixel-identical to the view it covers —
      // let it paint before the live nav map leaves the tree.
      await surfaceRemoved();
      if (!mounted) {
        _navExiting = false;
        return;
      }
    } else if (_morphEnter || _morphReveal) {
      setState(() {
        _morphEnter = false;
        _morphReveal = false;
        _morphBytes = null;
        _morphRect = null;
      });
    }
    setState(() => _navMode = false);
    _acquireMapSurface();
    _navExiting = false;
  }

  /// One-shot screenshot of a live Mapbox surface for the morph overlay.
  /// Null everywhere it cannot work (web, dead controller, platform
  /// refusal, timeout) — the caller falls back to the plain fade.
  Future<Uint8List?> _captureMapSnapshot(mapbox.MapboxMap? m) async {
    if (m == null || kIsWeb) return null;
    try {
      return await m.snapshot().timeout(const Duration(milliseconds: 500));
    } catch (_) {
      return null;
    }
  }

  /// Global rect of the mini-map card — where the morph blooms from and
  /// where it lands on the way back.
  Rect? _miniMapRect() {
    final ro = _miniMapBoxKey.currentContext?.findRenderObject();
    if (ro is RenderBox && ro.hasSize) {
      return ro.localToGlobal(Offset.zero) & ro.size;
    }
    return null;
  }

  /// The nav map has its first controller and route drawn — cross-fade the
  /// expansion snapshot out over it.
  void _onNavMapReady() {
    if (!mounted || !_morphEnter) return;
    _navReadyTimeout?.cancel();
    setState(() => _morphReveal = true);
  }

  void _onEnterMorphFinished() {
    if (!mounted) return;
    setState(() {
      _morphEnter = false;
      _morphReveal = false;
      _morphBytes = null;
      _morphRect = null;
    });
  }

  void _onExitMorphFinished() {
    if (!mounted) return;
    setState(() {
      _morphExit = false;
      _morphBytes = null;
      _morphRect = null;
    });
  }

  /// Fetch the driving route for the preview card.
  ///
  /// Cheap to be wrong about — the card shows the two pins either way, and
  /// the line is the part that arrives a moment later. Failures are left to
  /// the empty list rather than retried: a preview without a route line is a
  /// smaller problem than a screen that keeps hitting the network during a
  /// trip.
  Future<void> _loadPreviewRoute() async {
    try {
      final pts = await _loadRoute();
      if (!mounted || pts.length < 2) return;
      setState(() => _routePoints = pts);
    } catch (e) {
      debugPrint('[DriverTripAccept] preview route unavailable: $e');
    }
  }

  Future<void> _resolveRiderPhotoFromTrip() async {
    if (_riderPhotoUrl != null && _riderPhotoUrl!.isNotEmpty) return;
    // 1) Try Firestore trip document
    try {
      final snap = await FirebaseFirestore.instance
          .collection('trips')
          .doc(_fsDocId)
          .get();
      final data = snap.data();
      if (data != null && mounted) {
        final recovered = _normalizedPhotoUrl(
          data['riderPhotoUrl']?.toString() ??
              data['rider_photo_url']?.toString() ??
              data['passengerPhotoUrl']?.toString() ??
              data['passenger_photo_url']?.toString() ??
              data['photo_url']?.toString() ??
              data['profile_photo_url']?.toString(),
        );
        if (recovered != null && recovered.isNotEmpty) {
          setState(() => _riderPhotoUrl = recovered);
          return;
        }
      }
    } catch (_) {}
    // 2) Try Firestore users collection directly using rider's SQL ID
    if (widget.riderId != null) {
      try {
        final doc = await FirebaseFirestore.instance
            .collection('users')
            .doc('sql_${widget.riderId}')
            .get();
        if (doc.exists && mounted) {
          final url = doc.data()?['photoUrl'] as String?;
          final recovered = _normalizedPhotoUrl(url);
          if (recovered != null && recovered.isNotEmpty) {
            setState(() => _riderPhotoUrl = recovered);
            return;
          }
        }
      } catch (_) {}
    }
    // 3) Fallback: query dispatch status API for rider photo
    try {
      final status = await ApiService.getDispatchStatus(widget.tripId);
      if (!mounted) return;
      // Check top-level fields first, then nested trip object
      final trip = (status['trip'] is Map)
          ? Map<String, dynamic>.from((status['trip'] as Map).cast<String, dynamic>())
          : <String, dynamic>{};
      final recovered = _normalizedPhotoUrl(
        status['rider_photo_url']?.toString() ??
            trip['rider_photo_url']?.toString() ??
            trip['riderPhotoUrl']?.toString() ??
            trip['passenger_photo_url']?.toString(),
      );
      if (recovered != null && recovered.isNotEmpty) {
        setState(() => _riderPhotoUrl = recovered);
      }
    } catch (_) {}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // The driver was in Google Maps, or the screen was locked. If iOS or
      // Android killed the location stream while we were away, this is the
      // earliest possible moment to notice — the watchdog would take up to
      // half a minute more, and that is half a minute of frozen car.
      _liveGps?.onAppResumed();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _chainedSseSub?.cancel();
    _chainedPollTimer?.cancel();
    unawaited(_liveGps?.stop());
    _gpsSub?.cancel();
    _dropoffGpsSub?.cancel();
    _riderConfirmSub?.cancel();
    _statusPollTimer?.cancel();
    _finishNavTimer?.cancel();
    _navReadyTimeout?.cancel();
    _camCycleTimer?.cancel();
    _camCycleCtrl?.dispose();
    _fadeCtrl.dispose();
    _slideCtrl.dispose();
    _tiltCtrl.dispose();
    _confirmBannerTimer?.cancel();
    _routeBannerTimer?.cancel();
    _pinCtrl.dispose();
    _pinFocusNode.dispose();
    _pinShakeCtrl.dispose();
    _pinLockTimer?.cancel();
    _carGpsSub?.cancel();
    _carTicker?.stop();
    _carTicker?.dispose();
    _btnFadeCtrl.dispose();
    _finishFadeCtrl.dispose();
    _shimmerCtrl.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routePoints = [];
    _pinAnnots.clear();
    super.dispose();
  }

  // ── Continuous GPS → GpsService (rider can track driver in real-time) ────
  void _startLiveGpsForRider() async {
    // H5 fix: cancel any pre-existing live GPS subscription before creating
    // a new one. Without this, calling _startLiveGpsForRider more than once
    // (e.g. on lifecycle resume) leaks a native geolocation stream.
    await _liveGps?.stop();
    // One frame of delay: this runs from initState, and the Android
    // foreground-service strings come from Localizations — an inherited
    // lookup that initState is not allowed to make.
    await WidgetsBinding.instance.endOfFrame;
    if (!mounted) return;
    // Background-capable AND self-healing. This is the stream the
    // passenger's car marker is driven by; the driver spends most of a trip
    // with this app behind Google Maps or behind a locked screen, and if it
    // dies there is nothing on the passenger's side that can compensate —
    // their car simply stops. See driverLocationSettings and
    // ResilientPositionStream.
    final s = S.of(context);
    _liveGps = ResilientPositionStream(
      label: 'DriverTripGps',
      settings: driverLocationSettings(
        distanceFilter: 5,
        notificationTitle: s.driverLocationNotifTitle,
        notificationText: s.driverLocationNotifOnTrip,
      ),
      // Push the first fix after a gap straight out instead of waiting for
      // the upload throttle — the passenger has been watching a frozen car.
      onFirstFixAfterGap: () {
        final p = _lastDriverPos;
        if (p != null) _gpsService.updatePosition(p, 0, 0);
      },
      onPosition: (pos) {
        if (!mounted) return;
        _lastDriverPos = LatLng(pos.latitude, pos.longitude);
        _gpsService.updatePosition(
          LatLng(pos.latitude, pos.longitude),
          pos.heading,
          pos.speed,
          capturedAt: pos.timestamp,
        );
        // Refresh the distance chip. The stream already only fires every 5 m,
        // and rebuilding is skipped unless the rounded label would change —
        // no setState storm from a driver sitting at a light.
        if (!_rideStarted) {
          final miles = Geolocator.distanceBetween(
                pos.latitude,
                pos.longitude,
                widget.pickupLatLng.latitude,
                widget.pickupLatLng.longitude,
              ) /
              1609.34;
          final prev = _milesToPickup;
          if (prev == null || (prev - miles).abs() >= 0.05) {
            setState(() => _milesToPickup = miles);
          } else {
            _milesToPickup = miles;
          }
        }
      },
    )..start();

    // Start GpsService upload ASAP — don't block on async user ID lookup.
    // The position stream is already running; once GpsService starts, it
    // will upload the latest position immediately.
    try {
      final driverId = await ApiService.getCurrentUserId();
      if (!mounted) return;
      if (driverId != null) {
        _gpsService.startTracking(driverId.toString());
        _gpsService.setActiveTrip(widget.tripId.toString());

        // FIX CRÍTICO: El driver DEBE unirse a la room del trip en Socket.io
        // para que el servidor reenvíe sus driver_location events al rider.
        // Antes el driver nunca hacía joinTrip, así que el rider no recibía
        // las actualizaciones de GPS aunque el driver las enviara.
        final tid = int.tryParse(widget.tripId.toString());
        if (tid != null) {
          await SocketService.init();
          if (mounted) SocketService.joinTrip(tid);
        }

        // Eager-upload the latest known position so the rider sees the car
        // immediately instead of waiting for the next Geolocator tick.
        final lastPos = await Geolocator.getLastKnownPosition();
        if (lastPos != null) {
          _gpsService.updatePosition(
            LatLng(lastPos.latitude, lastPos.longitude),
            lastPos.heading,
            lastPos.speed,
            capturedAt: lastPos.timestamp,
          );
        }
      }
    } catch (_) {}
  }

  // ── Resolve generic / placeholder addresses via reverse geocoding ────────
  static bool _isGenericAddress(String addr) {
    if (addr.isEmpty) return true;
    final lower = addr.toLowerCase().trim();
    return lower == 'current location' ||
        lower == 'ubicación actual' ||
        lower == 'pickup' ||
        lower == 'drop-off' ||
        lower == 'mi ubicación';
  }

  Future<String?> _reverseGeocode(double lat, double lng) async {
    try {
      final url = Uri.parse(
        'https://api.mapbox.com/geocoding/v5/mapbox.places/$lng,$lat.json'
        '?types=address,poi&limit=1&access_token=${MapboxConfig.accessToken}',
      );
      final res = await http.get(url).timeout(const Duration(seconds: 6));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        final features = data['features'] as List?;
        if (features != null && features.isNotEmpty) {
          return (features[0]['place_name'] as String?)
              ?.replaceAll(_usSuffixRe, '')
              .replaceAll(_prSuffixRe, '');
        }
      }
    } catch (_) {}
    return null;
  }

  Future<void> _loadComplimentaryDrinkIfVip() async {
    // Only VIP trips have a complimentary drink menu
    final vt = widget.vehicleType.toLowerCase();
    if (!vt.contains('vip')) return;
    // Fetch drink selection from backend using trip ID
    final tripId = widget.tripId;
    if (tripId <= 0) return;
    final drink = await ComplimentaryDrinkService.fetchForTrip(tripId);
    if (!mounted) return;
    if (drink != null && drink.isNotEmpty) {
      setState(() => _complimentaryDrink = drink);
    }
  }

  Future<void> _resolveGenericAddresses() async {
    final needsPickup = _isGenericAddress(_pickupAddr);
    final needsDropoff = _isGenericAddress(_dropoffAddr);
    if (!needsPickup && !needsDropoff) return;
    if (mounted) setState(() => _resolvingAddresses = true);
    if (needsPickup) {
      final resolved = await _reverseGeocode(
          widget.pickupLatLng.latitude, widget.pickupLatLng.longitude);
      if (mounted) {
        setState(() {
          _pickupAddr = resolved ??
              '${widget.pickupLatLng.latitude.toStringAsFixed(5)}, '
              '${widget.pickupLatLng.longitude.toStringAsFixed(5)}';
        });
      }
    }
    if (needsDropoff) {
      final resolved = await _reverseGeocode(
          _dropoffLL.latitude, _dropoffLL.longitude);
      if (mounted) {
        setState(() {
          _dropoffAddr = resolved ??
              '${_dropoffLL.latitude.toStringAsFixed(5)}, '
              '${_dropoffLL.longitude.toStringAsFixed(5)}';
        });
      }
    }
    if (mounted) setState(() => _resolvingAddresses = false);
  }

  // ── GPS proximity detection for pickup ──────────────────────────────────
  void _startPickupProximityDetection() {
    // Check initial position
    _checkPickupProximity(widget.driverPos);
    // Listen to GPS updates
    _gpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      if (!mounted || _nearPickup) return;
      _checkPickupProximity(LatLng(pos.latitude, pos.longitude));
    }, onError: (Object e) {
      // Keep platform-channel errors (permission revoked, location off) from
      // becoming unhandled async errors reported as FATAL crashes.
      debugPrint('[DriverTrip] pickup proximity stream error: $e');
    });
  }

  void _checkPickupProximity(LatLng driverPos) {
    final distM = _haversineMeters(driverPos, widget.pickupLatLng);
    if (distM <= _pickupRadiusMeters && !_nearPickup) {
      setState(() => _nearPickup = true);
      HapticService.heavyImpact();
      _gpsSub?.cancel(); // Stop listening once arrived
    }
  }

  double _haversineMeters(LatLng a, LatLng b) {
    const r = 6371000.0; // Earth radius in meters
    final dLat = (b.latitude  - a.latitude)  * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final s = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
        math.cos(b.latitude * math.pi / 180) *
        math.sin(dLng / 2) * math.sin(dLng / 2);
    return r * 2 * math.atan2(math.sqrt(s), math.sqrt(1 - s));
  }

  // ── GPS proximity detection for DROPOFF ─────────────────────────────────
  void _startDropoffProximityDetection() {
    // Check current driver position first
    _checkDropoffProximity(widget.driverPos);
    _dropoffGpsSub = Geolocator.getPositionStream(
      locationSettings: const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 10,
      ),
    ).listen((pos) {
      if (!mounted || _nearDropoff) return;
      _checkDropoffProximity(LatLng(pos.latitude, pos.longitude));
    }, onError: (Object e) {
      // Same guard as the pickup stream: no unhandled PlatformExceptions.
      debugPrint('[DriverTrip] dropoff proximity stream error: $e');
    });
  }

  void _checkDropoffProximity(LatLng driverPos) {
    final distM = _haversineMeters(driverPos, _dropoffLL);
    if (distM <= _dropoffRadiusMeters && !_nearDropoff) {
      setState(() => _nearDropoff = true);
      HapticService.heavyImpact();
      _dropoffGpsSub?.cancel();
    }
  }

  /// Write to this trip's Firestore doc now, re-authenticating only if the
  /// write actually fails.
  ///
  /// Replaces `await _ensureFirebaseAuth()` before every write: a network
  /// round trip paid on every single call to guard against a session that is
  /// almost never expired. On the arrival and ride-start paths that round trip
  /// sat between the driver's swipe and the rider being told anything — which
  /// is exactly what writing to Firestore first was supposed to avoid. The
  /// common path now costs nothing, and the rare expired-token path costs one
  /// retry instead of delaying everyone.
  Future<void> _writeTripDoc(Map<String, dynamic> data, String label) async {
    final ref = FirebaseFirestore.instance.collection('trips').doc(_fsDocId);
    try {
      await ref.set(data, SetOptions(merge: true));
      debugPrint('[Driver] Firestore $label write OK → $_fsDocId');
      return;
    } catch (e) {
      debugPrint('[Driver] Firestore $label write failed ($e) — re-auth, retry');
    }
    await _ensureFirebaseAuth();
    try {
      await ref.set(data, SetOptions(merge: true));
      debugPrint('[Driver] Firestore $label write OK after re-auth → $_fsDocId');
    } catch (e) {
      debugPrint('[Driver] Firestore $label write FAILED after re-auth: $e');
    }
  }

  /// Ensure Firebase anonymous auth is active before any Firestore write.
  /// The token can expire after long sessions; re-auth is instant.
  Future<void> _ensureFirebaseAuth() async {
    if (FirebaseAuth.instance.currentUser == null) {
      try {
        await FirebaseAuthRecovery.ensureSignedIn();
      } catch (e) {
        debugPrint('[Driver] Firebase re-auth failed: $e');
      }
    }
  }

  // ── Confirm arrival at pickup (Arrived slider) ──────────────────────────
  Future<void> _confirmArrival() async {
    setState(() => _arrivedConfirmed = true);

    // Tell the rider FIRST. Nothing is awaited above this line, and nothing
    // may be added above it.
    //
    // This write used to happen only after the backend call succeeded —
    // behind a 6 s timeout and up to two 2 s retry gaps. On a weak signal
    // the rider's "your driver has arrived" screen appeared many seconds
    // after the driver swiped, or not at all, while the driver stood there
    // believing the passenger had been told. Firestore is the rider's
    // fastest channel; firing it now makes their overlay appear in the
    // same beat as the swipe. Reverted below if the backend ultimately
    // rejects the arrival, exactly like the optimistic write on accept.
    //
    // An `await _ensureFirebaseAuth()` used to sit directly above this,
    // which quietly undid all of it: on an expired anonymous session that
    // is a network round trip, and the passenger was told nothing until it
    // came back. _writeTripDoc re-authenticates on failure instead.
    unawaited(_writeTripDoc({
      'status': 'arrived',
      'arrivedAt': FieldValue.serverTimestamp(),
    }, 'arrived'));

    // Retry backend API up to 3 times — it remains the source of truth.
    bool apiOk = false;
    for (int attempt = 0; attempt < 3 && !apiOk; attempt++) {
      try {
        await ApiService.updateTripStatus(tripId: widget.tripId, status: 'arrived')
            .timeout(const Duration(seconds: 6));
        apiOk = true;
      } catch (e) {
        debugPrint('[Driver] arrived API attempt ${attempt + 1} failed: $e');
        if (attempt < 2) await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (!apiOk) {
      debugPrint('[Driver] arrived API FAILED after 3 attempts');
      // Undo the optimistic write above, or the rider is left staring at a
      // "confirm you are with the driver" screen for an arrival the
      // backend never accepted.
      unawaited(_writeTripDoc({
        'status': 'driver_en_route',
      }, 'arrived rollback'));
      // H2 fix: previously the UI stayed in "arrived" state even when all
      // 3 backend attempts failed — the driver thought they were at pickup
      // but neither the backend nor the rider ever knew. Roll back the
      // local state and surface the failure so the driver can retry.
      if (mounted) {
        setState(() => _arrivedConfirmed = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text(
              'Could not confirm arrival — check your connection and swipe again',
            ),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
      return;
    }
    debugPrint('[Driver] arrived confirmed → $_fsDocId');
  }

  // ── Listen for rider confirming they are with the driver ────────────────
  void _listenForRiderConfirmation() {
    _riderConfirmSub = FirebaseFirestore.instance
        .collection('trips')
        .doc(_fsDocId)
        .snapshots()
        .listen((snap) async {
      if (!mounted) return;
      final data = snap.data();
      if (data == null) return;

      // Detect external completion (dispatch admin finished the trip)
      final status = (data['status'] ?? '').toString().toLowerCase();
      if (status == 'completed' && !_tripFinished) {
        debugPrint('[Driver] Trip completed externally (dispatch) → navigating to rating');
        _onExternalCompletion();
        return;
      }

      // Detect external cancellation (dispatch cancelled the trip, or
      // guardian ghost cleanup fired, or an auto-cancel reason landed).
      // Driver-initiated cancels go through _performDriverCancel; any
      // cancel arriving here is remote. Pop back to the online controller
      // which will show a gold toast and reset to searching.
      if (!_tripFinished &&
          (status == 'cancelled' || status == 'canceled')) {
        // Re-check mounted: this listener is async-firing and the
        // widget may have been disposed between the snapshot arriving
        // and the cancel check.
        if (!mounted) return;

        // Check if this was a wait timeout (passenger no-show)
        final cancelReason = (data['cancel_reason'] ??
                data['cancelReason'] ??
                data['cancellation_reason'] ??
                '')
            .toString()
            .toLowerCase();
        final isWaitTimeout = cancelReason.contains('wait_timeout') ||
            cancelReason.contains('no_show');

        debugPrint('[Driver] Trip cancelled externally (wait_timeout=$isWaitTimeout) → returning to online');
        _tripFinished = true;
        _riderConfirmSub?.cancel();

        // Show specific message for passenger no-show
        if (isWaitTimeout && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: const Text(
                'Pasajero no apareció — Viaje cancelado por no-show.\n'
                'Passenger no-show — Trip auto-cancelled.',
                style: TextStyle(fontSize: 14),
              ),
              backgroundColor: const Color(0xFFEF4444),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              duration: const Duration(seconds: 5),
              margin: const EdgeInsets.all(16),
            ),
          );
          // Delay to let driver read the message
          await Future.delayed(const Duration(seconds: 3));
        }

        // Navigate back to DriverOnlineScreen. pushAndRemoveUntil (rather
        // than pop) because this screen is also reached from entry points
        // that leave nothing sensible underneath — resume-from-home, a
        // push notification — so popping is not always an option. The
        // notice flag tells it to open with the "Viaje cancelado" overlay
        // already up, since that notice lives on the online screen.
        if (!mounted) return;
        try {
          _exitAfterRemoteCancel();
        } catch (e) {
          debugPrint('[Driver] cancel-navigate failed: $e');
        }
        return;
      }

      // Dispatch advanced the trip (arrived / start trip from the panel)
      // — morph the action button to the matching stage.
      _applyRemoteStage(status);

      // The rider added a stop or moved the destination mid-trip.
      _applyRouteChangeFromDoc(data);

      // Fase 2: the rider answered our proposal with a decline.
      final prc = data['pending_route_change'];
      if (prc is Map &&
          (prc['proposed_by'] ?? '') == 'driver' &&
          (prc['status'] ?? '') == 'declined' &&
          !_proposalDeclineShown) {
        _proposalDeclineShown = true;
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
            content: Text(S.of(context).riderDeclinedProposal),
            behavior: SnackBarBehavior.floating));
        unawaited(_writeTripDoc(
            {'pending_route_change': FieldValue.delete()},
            'clear declined proposal'));
      }

      if (_riderConfirmedPickup || _rideStarted) return;
      if (data['rider_confirmed_pickup'] == true && !_riderConfirmedPickup) {
        HapticService.mediumImpact();
        if (mounted) {
          setState(() => _riderConfirmedPickup = true);
          _showConfirmBanner();
        }
      }
    }, onError: (e) {
      debugPrint('[Driver] trip listener error: $e');
      // permission-denied → Firebase Auth expired. Re-auth silently
      // so the snapshot listener recovers on the next server push.
      final isPermDenied = e is FirebaseException && e.code == 'permission-denied';
      if (isPermDenied || e.toString().contains('permission-denied')) {
        FirebaseAuthRecovery.ensureSignedIn().ignore();
      }
    });
  }

  /// Backend status poll — runs every 8s and mirrors the Firestore
  /// listener's exit logic. This is a safety net for cases where the
  /// snapshot stream is lagging or muted (auth expired, doc not yet
  /// mirrored, transient connectivity). Without it, dispatch can
  /// cancel/complete a trip and the driver is stuck on FINISH RIDE.
  void _startStatusPoll() {
    _statusPollTimer?.cancel();
    _statusPollTimer = Timer.periodic(const Duration(seconds: 8), (_) async {
      if (!mounted || _tripFinished) return;
      // Guard: skip if a request is already in-flight (prevents polling storm
      // when the network is slow or the backend is under load).
      if (_isPollingTripStatus) return;
      _isPollingTripStatus = true;
      try {
        final trip = await ApiService.getTrip(widget.tripId);
        if (!mounted || _tripFinished) return;
        final status = (trip['status'] ?? '').toString().toLowerCase();
        if (status == 'completed') {
          debugPrint('[Driver] Backend poll: trip completed → onExternalCompletion');
          _onExternalCompletion();
        } else if (status == 'cancelled' || status == 'canceled') {
          // Check if this was a wait timeout (passenger no-show)
          final cancelReason = (trip['cancel_reason'] ??
                  trip['cancelReason'] ??
                  trip['cancellation_reason'] ??
                  '')
              .toString()
              .toLowerCase();
          final isWaitTimeout = cancelReason.contains('wait_timeout') ||
              cancelReason.contains('no_show');

          debugPrint('[Driver] Backend poll: trip cancelled (wait_timeout=$isWaitTimeout) → popping');
          _tripFinished = true;
          _statusPollTimer?.cancel();
          _riderConfirmSub?.cancel();

          // Show specific message for passenger no-show
          if (isWaitTimeout && mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: const Text(
                  'Pasajero no apareció — Viaje cancelado por no-show.\n'
                  'Passenger no-show — Trip auto-cancelled.',
                  style: TextStyle(fontSize: 14),
                ),
                backgroundColor: const Color(0xFFEF4444),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                duration: const Duration(seconds: 5),
                margin: const EdgeInsets.all(16),
              ),
            );
            await Future.delayed(const Duration(seconds: 3));
          }

          if (!mounted) return;
          try {
            _exitAfterRemoteCancel();
          } catch (e) {
            debugPrint('[Driver] poll-cancel-navigate failed: $e');
          }
        } else {
          // Dispatch advanced the trip while the Firestore stream lagged.
          _applyRemoteStage(status);
        }
      } on ApiException catch (e) {
        // A 404 is not transient: the trip does not exist server-side at
        // all, so there is nothing to keep this screen for. Treat it like
        // an external cancel and leave — retrying it every 8 s forever was
        // how a driver got stuck on a dead trip (the sql_453 case, where
        // only an optimistic Firestore doc kept the trip "alive").
        if (e.statusCode == 404 && mounted && !_tripFinished) {
          debugPrint('[Driver] Backend poll: trip ${widget.tripId} not found (404) → leaving');
          _tripFinished = true;
          _statusPollTimer?.cancel();
          _riderConfirmSub?.cancel();
          try {
            _exitAfterRemoteCancel();
          } catch (navErr) {
            debugPrint('[Driver] 404-navigate failed: $navErr');
          }
        }
      } catch (_) {
        // Ignore transient errors — next tick retries.
      } finally {
        _isPollingTripStatus = false;
      }
    });
  }

  /// Handle trip completed externally (by dispatch admin).
  /// Skip the API status update (already done) but still show completion
  /// overlay and navigate to rating screen.
  void _onExternalCompletion() {
    if (_tripFinished) return;
    setState(() => _tripFinished = true);
    HapticService.heavyImpact();

    _finishFadeCtrl.forward(from: 0);

    // Cleanup (fire-and-forget)
    unawaited(() async {
      final gps = GpsService();
      try { await gps.clearTripLocation(); } catch (_) {}
      gps.setActiveTrip(null);
      try {
        await TripFirestoreService.clearDriverLocation(_fsDocId);
      } catch (_) {}
    }());

    // Navigate to rating screen after brief overlay.
    // H4 fix: cancel any pre-existing timer so the local-finish and the
    // external-completion paths cannot both schedule a navigation.
    _finishNavTimer?.cancel();
    _finishNavTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          pageBuilder: (_, anim, __) => DriverRateRiderScreen(
            tripId: widget.tripId,
            riderName: widget.riderName,
            riderPhotoUrl: _normalizedPhotoUrl(widget.riderPhotoUrl) ?? '',
            riderId: widget.riderId,
            fare: widget.fare,
            dropoffLat: _dropoffLL.latitude,
            dropoffLng: _dropoffLL.longitude,
          ),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOutCubic),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 600),
        ),
        (route) => false,
      );
    });
  }

  // ── Update trip status to in_trip when Start Ride is pressed ────────
  //
  // Returns whether the backend confirmed the transition — Start Ride only
  // opens dropoff navigation on success, so navigation state can never run
  // ahead of the trip's real state.
  Future<bool> _updateTripInTrip() async {
    // Tell the rider FIRST, for the same reason as _confirmArrival — this
    // path had the identical defect and it was never fixed here.
    //
    // The Firestore write was the LAST thing this method did, after up to
    // three backend attempts with 2 s gaps and a 6 s timeout each. On a weak
    // signal the rider's "confirm you are with the driver" overlay stayed on
    // their screen for that whole time, long after the driver swiped Start
    // Ride and started driving. Firestore is the rider's fastest channel, so
    // it goes first; the backend below is still the source of truth.
    //
    // No rollback on API failure, matching the previous behaviour: the old
    // code wrote in_trip to Firestore unconditionally too, success or not.
    unawaited(_writeTripDoc({
      'status': 'in_trip',
      'rideStartedAt': FieldValue.serverTimestamp(),
    }, 'in_trip'));

    // Retry backend API up to 3 times.
    bool apiOk = false;
    for (int attempt = 0; attempt < 3 && !apiOk; attempt++) {
      try {
        await ApiService.updateTripStatus(tripId: widget.tripId, status: 'in_trip')
            .timeout(const Duration(seconds: 6));
        apiOk = true;
      } catch (e) {
        debugPrint('[Driver] in_trip API attempt ${attempt + 1} failed: $e');
        if (attempt < 2) await Future.delayed(const Duration(seconds: 2));
      }
    }
    if (!apiOk) {
      debugPrint('[Driver] in_trip API FAILED after 3 attempts');
    }
    // Firestore already went out at the top of this method.
    return apiOk;
  }

  // ── Complete trip (API + Firestore + navigate to online) ────────────────
  Future<void> _finishTrip() async {
    if (_tripFinished) return;
    setState(() => _tripFinished = true);
    HapticService.heavyImpact();

    // Show completion overlay immediately (do not block on network).
    //
    // "Immediately" was not true: an awaited _ensureFirebaseAuth() sat above
    // this line, so on an expired session the driver swiped and watched
    // nothing happen until a sign-in round trip came back. The write below
    // goes through _writeTripDoc, which re-authenticates if it is rejected.
    _finishFadeCtrl.forward(from: 0);

    // Fire-and-forget cleanup/status updates so UI never hangs.
    unawaited(() async {
      // Retry trip completion up to 3 times — if backend never marks it
      // 'completed', dispatch will still consider driver busy.
      bool apiOk = false;
      for (int attempt = 0; attempt < 3 && !apiOk; attempt++) {
        try {
          await ApiService.updateTripStatus(tripId: widget.tripId, status: 'completed')
              .timeout(const Duration(seconds: 6));
          apiOk = true;
        } catch (e) {
          debugPrint('[Driver] completeTrip API attempt ${attempt + 1} failed: $e');
          if (attempt < 2) await Future.delayed(const Duration(seconds: 2));
        }
      }
      if (!apiOk) {
        debugPrint('[Driver] completeTrip API FAILED after 3 attempts — trip may be stuck');
      }
      // Stays after the API loop, unlike arrived and in_trip: completion is
      // what charges the rider, and writing `completed` to Firestore first
      // would send them to the rating screen for a trip the backend may
      // never have completed. _writeTripDoc only replaces the bare set()
      // here — it re-authenticates if the write is rejected, which the
      // previous plain try/catch did not.
      await _writeTripDoc({
        'status': 'completed',
        'completedAt': FieldValue.serverTimestamp(),
      }, 'completed');

      final gps = GpsService();
      try { await gps.clearTripLocation(); } catch (_) {}
      gps.setActiveTrip(null);
      try {
        await TripFirestoreService.clearDriverLocation(_fsDocId);
      } catch (_) {}
    }());

    // After 1.5 seconds navigate to DriverRateRiderScreen.
    // H4 fix: cancel the pre-existing timer (see _finishTrip) so both
    // finish paths can't schedule a navigation at the same time.
    _finishNavTimer?.cancel();
    _finishNavTimer = Timer(const Duration(milliseconds: 1500), () {
      if (!mounted) return;
      Navigator.of(context).pushAndRemoveUntil(
        PageRouteBuilder(
          pageBuilder: (_, anim, __) => DriverRateRiderScreen(
            tripId: widget.tripId,
            riderName: widget.riderName,
            riderPhotoUrl: _normalizedPhotoUrl(widget.riderPhotoUrl) ?? '',
            riderId: widget.riderId,
            fare: widget.fare,
            dropoffLat: _dropoffLL.latitude,
            dropoffLng: _dropoffLL.longitude,
          ),
          transitionsBuilder: (_, anim, __, child) => FadeTransition(
            opacity: CurvedAnimation(parent: anim, curve: Curves.easeInOutCubic),
            child: child,
          ),
          transitionDuration: const Duration(milliseconds: 600),
        ),
        (route) => false,
      );
    });
  }

  // ── Navigation ────────────────────────────────────────────────────────────
  Future<void> _openNativeMaps(LatLng dest) async {
    final lat = dest.latitude;
    final lng = dest.longitude;

    // Ask Settings → Navigation first.
    //
    // This screen is where a driver actually presses Navigate, and it
    // used to ignore every one of those settings: it opened Google Maps,
    // then Waze, then Apple Maps, in that fixed order, with no avoid
    // parameters. A driver who chose Waze and turned on Avoid Tolls got
    // Google Maps and a route through the toll booth.
    //
    // False means either they prefer in-app navigation or their chosen
    // app would not open — both fall through to the chain below, which
    // is the behaviour this button has always had.
    if (await MapLauncherService.navigate(destLat: lat, destLng: lng)) {
      return;
    }
    if (!mounted) return;

    if (AppPlatform.isIOS) {
      final gMapsUrl = Uri.parse(
        'comgooglemaps://?daddr=$lat,$lng&directionsmode=driving',
      );
      if (await canLaunchUrl(gMapsUrl)) {
        await launchUrl(gMapsUrl, mode: LaunchMode.externalApplication);
        return;
      }
      final wazeUrl = Uri.parse('waze://?ll=$lat,$lng&navigate=yes');
      if (await canLaunchUrl(wazeUrl)) {
        await launchUrl(wazeUrl, mode: LaunchMode.externalApplication);
        return;
      }
      await launchUrl(
        Uri.parse('https://maps.apple.com/?daddr=$lat,$lng&dirflg=d&t=m'),
        mode: LaunchMode.externalApplication,
      );
    } else {
      final gMapsUrl = Uri.parse('google.navigation:q=$lat,$lng&mode=d');
      if (await canLaunchUrl(gMapsUrl)) {
        await launchUrl(gMapsUrl, mode: LaunchMode.externalApplication);
        return;
      }
      final wazeUrl = Uri.parse('waze://?ll=$lat,$lng&navigate=yes');
      if (await canLaunchUrl(wazeUrl)) {
        await launchUrl(wazeUrl, mode: LaunchMode.externalApplication);
        return;
      }
      await launchUrl(
        Uri.parse('https://www.google.com/maps/dir/?api=1&destination=$lat,$lng&travelmode=driving'),
        mode: LaunchMode.externalApplication,
      );
    }
  }

  // ── Phone / Message ───────────────────────────────────────────────────────
  Future<void> _call() async {
    // Masked callback — the server rings the driver's phone and bridges to
    // the rider; real numbers are never exposed on either side.
    final ok = await MaskedCallService.callCounterparty(tripId: widget.tripId, role: 'driver');
    if (!mounted) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(
        content: Text(
          ok ? S.of(context).callingYouBack : S.of(context).connectionError,
        ),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  // ═══ Fase 2: the driver PROPOSES a route change ═══
  //
  // The proposal is a Firestore-only handshake: this app writes
  // pending_route_change to the trip doc, the rider's tracking screen
  // quotes it with its own anchored pricing and shows the confirm
  // sheet, and the COMMIT still goes through the rider-authorized
  // backend endpoints — the driver never touches the money path.
  Future<void> _openProposeRouteChange({required bool isStop}) async {
    HapticService.selectionClick();
    final det = await showModalBottomSheet<PlaceDetails>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => _ProposeSearchSheet(
        isStop: isStop,
        near: widget.driverPos,
      ),
    );
    if (det == null || !mounted) return;
    _proposalDeclineShown = false;
    unawaited(_writeTripDoc({
      'pending_route_change': {
        'type': isStop ? 'add_stop' : 'change_destination',
        'lat': det.lat,
        'lng': det.lng,
        'label': det.address,
        'proposed_by': 'driver',
        'status': 'proposed',
      },
    }, 'route proposal'));
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(S.of(context).proposalSentToRider),
        behavior: SnackBarBehavior.floating));
  }

  // ═══ Mid-trip route changes pushed by the rider (multi-stop v1) ═══

  void _applyRouteChangeFromDoc(Map<String, dynamic> data) {
    if (_tripFinished || !mounted) return;
    // New stop — applied once.
    final stops = data['stops'];
    if (stops is List && stops.isNotEmpty && _stopLatLng == null) {
      final st = stops.first;
      if (st is Map) {
        final lat = (st['lat'] as num?)?.toDouble();
        final lng = (st['lng'] as num?)?.toDouble();
        if (lat != null && lng != null) {
          final label = (st['label'] ?? '').toString();
          setState(() {
            _stopLatLng = LatLng(lat, lng);
            _stopLabel = label;
          });
          _showRouteChangeBanner(S.of(context).newStopBanner, label);
          unawaited(_redrawMiniMapForRouteChange());
        }
      }
    }
    // Destination moved (>50 m from what we're steering to).
    final dLat = (data['dropoff_lat'] as num?)?.toDouble();
    final dLng = (data['dropoff_lng'] as num?)?.toDouble();
    if (dLat != null && dLng != null) {
      final next = LatLng(dLat, dLng);
      if (_haversineMeters(_dropoffLL, next) > 50) {
        final addr =
            (data['dropoff_address'] ?? data['dropoffAddress'] ?? '')
                .toString();
        setState(() {
          _dropoffOverride = next;
          if (addr.isNotEmpty) _dropoffAddr = addr;
        });
        _showRouteChangeBanner(
            S.of(context).destinationChangedBanner, addr);
        unawaited(_redrawMiniMapForRouteChange());
      }
    }
  }

  /// Top in-app notification — slides in, auto-hides after 6 s.
  void _showRouteChangeBanner(String title, String body) {
    HapticService.heavyImpact();
    final sm = ScaffoldMessenger.maybeOf(context);
    if (sm == null) return;
    sm.clearMaterialBanners();
    sm.showMaterialBanner(MaterialBanner(
      backgroundColor: const Color(0xFF1C1C24),
      dividerColor: Colors.transparent,
      leading: Icon(Icons.add_location_alt_rounded, color: _gold, size: 24),
      content: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w800,
                  fontSize: 15)),
          if (body.isNotEmpty)
            Text(body,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.65),
                    fontSize: 12.5)),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => sm.clearMaterialBanners(),
          child: Text('OK',
              style:
                  TextStyle(color: _gold, fontWeight: FontWeight.w800)),
        ),
      ],
    ));
    _routeBannerTimer?.cancel();
    _routeBannerTimer = Timer(const Duration(seconds: 6), () {
      try {
        sm.clearMaterialBanners();
      } catch (_) {}
    });
  }

  /// New legs pickup → (stop) → dropoff, the line's geometry swapped in
  /// place, the stop pin dropped once, the dropoff pin moved if needed,
  /// and one smooth reframe over the whole new plan. Nothing rebuilt.
  Future<void> _redrawMiniMapForRouteChange() async {
    if (kIsWeb) return;
    final ctrl = _map;
    if (ctrl == null || !mounted) return;
    try {
      List<LatLng> pts;
      final stop = _stopLatLng;
      if (stop != null) {
        final l1 = await _fetchRoutePoints(widget.pickupLatLng, stop);
        final l2 = await _fetchRoutePoints(stop, _dropoffLL);
        pts = [...l1, ...l2.skip(1)];
      } else {
        pts = await _fetchRoutePoints(widget.pickupLatLng, _dropoffLL);
      }
      if (!mounted || pts.length < 2) return;
      _routePoints = pts;
      _eraseHintIdx = 0;
      final geom = safeLineString(pts);
      if (geom != null && _routeAnnot != null && _polyMgr != null) {
        _routeAnnot!.geometry = geom;
        _polyMgr!.update(_routeAnnot!).catchError((_) {});
      }
      if (stop != null && _stopPinAnnot == null && _annotMgr != null) {
        final bytes = await renderCircularPinBytes(
            icon: CircularPinIcon.flag, isPickup: false, radius: 32);
        final p = safePoint(stop.longitude, stop.latitude);
        if (p != null && mounted && _annotMgr != null) {
          _stopPinAnnot = await _annotMgr!.create(
            mapbox.PointAnnotationOptions(
              geometry: p,
              image: bytes,
              iconSize: 0.62,
              iconAnchor: mapbox.IconAnchor.BOTTOM,
            ),
          );
        }
      }
      if (_dropoffOverride != null &&
          _pinAnnots.isNotEmpty &&
          _annotMgr != null) {
        final annot = _pinAnnots.last; // dropoff is created last
        final p = safePoint(_dropoffLL.longitude, _dropoffLL.latitude);
        if (p != null) {
          annot.geometry = p;
          _annotMgr!.update(annot).catchError((_) {});
        }
      }
      // Same hardening its twin in _runStyleLoadedSetup got, and for the same
      // reason: this fold seeds sentinels and every comparison against a NaN
      // is false, so ONE bad coordinate leaves 90/-90/180/-180 in place and
      // ships an inverted box across the channel — which raises inside
      // Objective-C ("Invalid number value (NaN) in JSON write") where no
      // Dart catch can reach it. Filter first, seed from a real point.
      final finite = [
        widget.pickupLatLng,
        if (stop != null) stop,
        _dropoffLL,
        ...pts,
      ].where((p) => isValidLatLng(p.latitude, p.longitude)).toList();
      if (finite.isEmpty) {
        debugPrint('[DriverTrip] redraw skipped — no finite coordinates');
        return;
      }
      double minLat = finite.first.latitude, maxLat = finite.first.latitude;
      double minLng = finite.first.longitude, maxLng = finite.first.longitude;
      for (final p in finite) {
        if (p.latitude < minLat) minLat = p.latitude;
        if (p.latitude > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      final rawBearing = _routeBearing(pts);
      final prettBearing = rawBearing.isFinite ? (rawBearing + 15.0) % 360 : 0.0;
      final cam = await ctrl.cameraForCoordinateBounds(
        mapbox.CoordinateBounds(
          southwest:
              mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
          northeast:
              mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
          infiniteBounds: false,
        ),
        mapbox.MbxEdgeInsets(top: 60, left: 50, bottom: 70, right: 50),
        prettBearing,
        0,
        null,
        null,
      );
      if (!mounted) return;
      final targetZoom = ((cam.zoom ?? 13) - 0.5).clamp(9.0, 14.0);
      if (!_cameraIsSane(cam.center, targetZoom.toDouble())) {
        debugPrint('[DriverTrip] redraw skipped — camera not finite');
        return;
      }
      await ctrl.flyTo(
        mapbox.CameraOptions(
            center: cam.center,
            zoom: targetZoom,
            bearing: prettBearing,
            pitch: 0.0),
        mapbox.MapAnimationOptions(duration: 1200),
      );
    } catch (e) {
      debugPrint('[DriverTrip] route-change redraw failed: $e');
    }
  }

  void _showConfirmBanner() {
    _confirmBannerTimer?.cancel();
    setState(() => _confirmBannerShow = true);
    _confirmBannerTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) setState(() => _confirmBannerShow = false);
    });
  }

  /// Arrived, rider not aboard yet: a calm non-tappable pill. The pickup
  /// code is the ONLY way past it (user spec 2026-09-16): the rider reads
  /// their 4 digits, the driver types them below, the backend writes
  /// rider_confirmed_pickup, and the AnimatedSwitcher morphs this into the
  /// pulsing Start Ride.
  Widget _buildSlideWaitingForRider() {
    return Stack(
      key: const ValueKey('waiting_rider'),
      children: [
        Container(
          height: 62,
          width: double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: _gold.withValues(alpha: 0.14),
            borderRadius: BorderRadius.circular(31),
            border: Border.all(color: _gold.withValues(alpha: 0.38)),
          ),
          child: Text(
            S.of(context).waitingForYourRider,
            style: TextStyle(
              color: _gold,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _buildShimmerOverlay(62),
      ],
    );
  }

  // ── Pickup PIN ────────────────────────────────────────────────────────────

  void _onPinChanged(String value) {
    if (_pinLocked || _pinSubmitting) return;
    if (_pinError == 'invalid') _pinError = null;
    if (value.length == 4) {
      _pinFocusNode.unfocus();
      _submitPickupPin();
    }
    setState(() {});
  }

  Future<void> _submitPickupPin() async {
    if (_pinSubmitting) return;
    final pin = _pinCtrl.text;
    if (pin.length != 4) return;
    HapticService.mediumImpact();
    setState(() => _pinSubmitting = true);
    try {
      await ApiService.confirmPickupPin(widget.tripId, pin);
      if (!mounted) return;
      HapticService.heavyImpact();
      // Same local state the Firestore proximity listener sets — the
      // listener stays the cross-device source of truth and early-returns
      // on this flag, so its late write causes no double haptic/banner.
      setState(() => _riderConfirmedPickup = true);
      _showConfirmBanner();
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(S.of(context).pickupCodeMatched),
        behavior: SnackBarBehavior.floating,
      ));
    } on ApiException catch (e) {
      if (!mounted) return;
      _pinCtrl.clear();
      if (e.statusCode == 403) {
        HapticService.vibrate();
        setState(() => _pinError = 'invalid');
        _pinShakeCtrl.forward(from: 0);
        _pinFocusNode.requestFocus();
      } else if (e.statusCode == 429) {
        setState(() {
          _pinError = 'locked';
          _pinLocked = true;
        });
        _pinLockTimer?.cancel();
        _pinLockTimer = Timer(const Duration(minutes: 1), () {
          if (!mounted) return;
          setState(() {
            _pinLocked = false;
            if (_pinError == 'locked') _pinError = null;
          });
        });
      } else {
        // 409 / 422 / 503 — nothing client-side to fix, or a transient
        // write failure on a correct code: neutral note, fresh boxes.
        setState(() {});
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
          content: Text(S.of(context).networkError),
          behavior: SnackBarBehavior.floating,
        ));
      }
    } catch (e) {
      debugPrint('[Driver] pickup PIN confirm failed: $e');
      if (!mounted) return;
      _pinCtrl.clear();
      setState(() {});
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
        content: Text(S.of(context).networkError),
        behavior: SnackBarBehavior.floating,
      ));
    } finally {
      if (mounted) setState(() => _pinSubmitting = false);
    }
  }

  /// "PICKUP CODE · Ask the rider" card with the 4 digit boxes. The boxes
  /// are paint; a zero-sized TextField inside owns the numeric keyboard,
  /// backspace and paste (OTP autofill included).
  Widget _buildPickupPinCard() {
    final s = S.of(context);
    const pinGold = Color(0xFFE8C547);
    const pinRed = Color(0xFFEF4444);
    final pin = _pinCtrl.text;
    final hasError = _pinError != null;
    final accent = hasError ? pinRed : pinGold;
    return GestureDetector(
      onTap: (_pinLocked || _pinSubmitting)
          ? null
          : () => _pinFocusNode.requestFocus(),
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: neuBox(radius: 18, borderColor: accent.withValues(alpha: 0.22)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(s.pickupCodeTitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.35),
                          fontSize: 9.5, fontWeight: FontWeight.w600,
                          letterSpacing: 1.4,
                        )),
                      const SizedBox(height: 2),
                      Text(s.pickupCodeAskRider,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 9.5, fontWeight: FontWeight.w500,
                        )),
                    ],
                  ),
                ),
                AnimatedBuilder(
                  animation: _pinShakeCtrl,
                  builder: (context, child) {
                    final t = _pinShakeCtrl.value;
                    final dx = math.sin(t * math.pi * 5) * 8 * (1 - t);
                    return Transform.translate(
                        offset: Offset(dx, 0), child: child);
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: List.generate(4, (i) {
                      final filled = i < pin.length;
                      final isCursor =
                          !hasError && !_pinLocked && i == pin.length;
                      return Container(
                        width: 30, height: 38,
                        margin: EdgeInsets.only(left: i == 0 ? 0 : 6),
                        alignment: Alignment.center,
                        decoration: neuBox(
                          radius: 9,
                          pressed: true,
                          borderColor: hasError
                              ? pinRed.withValues(alpha: 0.65)
                              : isCursor
                                  ? pinGold
                                  : Colors.white.withValues(alpha: 0.09),
                        ),
                        child: Text(
                          filled ? pin[i] : '',
                          style: TextStyle(
                            color: hasError ? pinRed : pinGold,
                            fontSize: 17, fontWeight: FontWeight.w800,
                          ),
                        ),
                      );
                    }),
                  ),
                ),
              ],
            ),
            SizedBox(
              width: 1, height: 1,
              child: Opacity(
                opacity: 0.01,
                child: TextField(
                  controller: _pinCtrl,
                  focusNode: _pinFocusNode,
                  enabled: !_pinLocked,
                  keyboardType: TextInputType.number,
                  autofillHints: const [AutofillHints.oneTimeCode],
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(4),
                  ],
                  onChanged: _onPinChanged,
                  showCursor: false,
                  style: const TextStyle(fontSize: 1),
                  decoration: const InputDecoration(
                    border: InputBorder.none,
                    isCollapsed: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
            ),
            if (hasError) ...[
              const SizedBox(height: 8),
              Text(
                _pinError == 'locked'
                    ? s.pickupCodeTooManyAttempts
                    : s.pickupCodeInvalid,
                style: const TextStyle(
                  color: pinRed, fontSize: 11.5, fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Helpers ───────────────────────────────────────────────────────────────
  String _timeLabel() {
    // Compute arrival ETA based on phase:
    // Before ride started → ETA to pickup, from the driver's LIVE
    //   distance when GPS has reported one (0.4 mi/min ≈ urban 24 mph —
    //   same constant the rider tracking uses); the dispatch estimate
    //   only until then. So "by 1:58" moves with the car, not with the
    //   number dispatch guessed at accept time (user spec 2026-08-05).
    // After ride started  → ETA to dropoff (_tripEta)
    final liveToPickup = _milesToPickup != null
        ? (_milesToPickup! / 0.4).ceil().clamp(1, 999)
        : widget.etaMinutes;
    final etaMins = _rideStarted ? _tripEta : liveToPickup;
    final arrival = DateTime.now().add(Duration(minutes: etaMins));
    int h = arrival.hour % 12;
    if (h == 0) h = 12;
    final m  = arrival.minute.toString().padLeft(2, '0');
    final ap = arrival.hour >= 12 ? 'PM' : 'AM';
    return 'by $h:$m $ap';
  }

  String? _normalizedPhotoUrl(String? rawUrl) {
    final raw = (rawUrl ?? '').replaceAll('"', '').trim();
    if (raw.isEmpty) return null;
    // Filter Python/JS sentinel strings that backend may send
    if (raw == 'null' || raw == 'None' || raw == 'undefined' || raw == 'none') return null;
    if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
    if (raw.startsWith('/')) return '${ApiService.publicBaseUrl}$raw';
    return '${ApiService.publicBaseUrl}/$raw';
  }

  Widget _avatar() {
    return VerifiedAvatar(
      photoUrl: _riderPhotoUrl,
      radius: Responsive.w(33),
      fallbackName: widget.riderName,
      uid: widget.riderId?.toString(),
      role: 'rider',
      isVerified: true,
    );
  }

  Widget _initialsFill(String init) => Container(
    color: const Color(0xFF1A1F35),
    child: Center(
      child: Text(init,
        style: const TextStyle(color: _gold, fontSize: 22, fontWeight: FontWeight.w700)),
    ),
  );

  Widget _initialsCircle(String init) => Container(
    width: 66, height: 66,
    decoration: const BoxDecoration(
      shape: BoxShape.circle,
      gradient: LinearGradient(
        colors: [Color(0xFFD4A843), Color(0xFFF5D990)],
        begin: Alignment.topLeft,
        end: Alignment.bottomRight,
      ),
    ),
    child: Center(
      child: Text(init,
        style: const TextStyle(color: Colors.black, fontSize: 26, fontWeight: FontWeight.w900)),
    ),
  );

  Widget _stars(double r) {
    final full = r.floor();
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: List.generate(5, (i) => Icon(
        i < full ? Icons.star_rounded
                 : (i < r ? Icons.star_half_rounded : Icons.star_outline_rounded),
        color: _gold, size: 15,
      )),
    );
  }

  Widget _complimentaryDrinkCard() {
    final drink = _complimentaryDrink ?? '';
    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: Responsive.w(14),
        vertical: Responsive.h(12),
      ),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _gold.withValues(alpha: 0.45), width: 1),
      ),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(Icons.local_bar_rounded, color: _gold, size: 20),
          ),
          SizedBox(width: Responsive.w(12)),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Complimentary drink',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.55),
                    fontSize: Responsive.sp(11),
                    fontWeight: FontWeight.w600,
                    letterSpacing: 1.2,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  drink,
                  style: TextStyle(
                    color: _gold,
                    fontSize: Responsive.sp(16),
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  void _copyAddress(String label, String address) {
    final value = address.trim();
    if (value.isEmpty) return;
    Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('$label copied'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(milliseconds: 1300),
      ),
    );
  }

  /// What the passenger typed when they booked, shown directly under the map.
  ///
  /// Titled, unlike the hanging note that dangles off the address cards: this
  /// is the first thing the driver should read after seeing where they are
  /// going, and an untitled paragraph of text under a map does not announce
  /// whose words it is.
  Widget _passengerInstructionsCard(String text) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 13),
    decoration: neuBox(radius: 16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              width: 26, height: 26,
              decoration: neuBox(radius: 9, pressed: true),
              child: Icon(Icons.format_quote_rounded,
                  color: _gold, size: 15),
            ),
            const SizedBox(width: 9),
            Text(
              S.of(context).passengerInstructionsLabel,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.45),
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 9),
        Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.88),
            fontSize: 14,
            height: 1.42,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    ),
  );

  /// Raised pill that floats over the map preview. Opaque on purpose — a
  /// translucent chip over a moving dark map is the one place where the
  /// neumorphic highlight stops reading as an edge.
  Widget _mapChip(Widget child) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    decoration: neuBox(radius: 10),
    child: child,
  );

  /// [iconSize] exists because the pickup ring and the dropoff square are not
  /// the same weight at the same size — the filled square needs to sit smaller
  /// than the open ring to read as its equal.
  Widget _infoRow(
    IconData icon,
    Color iconColor,
    String label,
    String address, {
    bool showChevron = false,
    double iconSize = 18,
  }) => Container(
    padding: const EdgeInsets.all(14),
    decoration: neuBox(radius: 16),
    child: Row(
      children: [
        // Sunken well, not a coloured tile: the icon reads as set into the
        // card instead of pasted onto it, which is the whole point of the
        // neumorphic system (project rule 18).
        Container(
          width: 38, height: 38,
          decoration: neuBox(radius: 12, pressed: true),
          child: Icon(icon, color: iconColor, size: iconSize),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 11, fontWeight: FontWeight.w600,
                  letterSpacing: 0.5,
                )),
              const SizedBox(height: 2),
              Text(address,
                style: const TextStyle(color: Colors.white, fontSize: 14,
                    fontWeight: FontWeight.w600),
                maxLines: 3, overflow: TextOverflow.ellipsis),
            ],
          ),
        ),
        if (showChevron)
          Icon(Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.24), size: 22),
      ],
    ),
  );

  // ── Chat ─────────────────────────────────────────────────────────────────
  void _openChat() async {
    HapticService.lightImpact();
    // Resolve driver user ID before navigating so chat doesn't have to await
    // Open first, resolve the id after — ChatScreen resolves it itself when
    // it is not supplied, and awaiting an HTTP call here made the button
    // feel dead for as long as the network took.
    if (!mounted) return;
    unawaited(ApiService.getCurrentUserId());
    Navigator.of(context).push(
      chatOpenRoute(ChatScreen(
        recipientName: widget.riderName,
        recipientPhotoUrl: widget.riderPhotoUrl,
        recipientId: widget.riderId?.toString(),
        recipientRole: 'rider',
        tripId: widget.tripId,
        currentRole: 'driver',
      )),
    );
  }

  /// Message button with real-time unread badge + bounce animation from Firebase RTDB.
  /// Find-My style round action with its label underneath (user spec
  /// 2026-09-14): chat / call / support as one centered row — the call disc
  /// is the only gold-filled one, and chat can carry the unread badge.
  Widget _tripActionBtn({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    bool filled = false,
    Stream<int>? badge,
    double d = 52.0,
    bool showLabel = true,
  }) {
    final disc = Container(
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
          : neuBox(radius: d / 2),
      child: Icon(icon, color: filled ? neuBase : _gold, size: d * 0.4),
    );
    return GestureDetector(
      onTap: () {
        HapticService.lightImpact();
        onTap();
      },
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (badge != null)
            StreamBuilder<int>(
              stream: badge,
              builder: (context, snap) {
                final count = snap.data ?? 0;
                return Stack(
                  clipBehavior: Clip.none,
                  children: [
                    disc,
                    if (count > 0)
                      Positioned(
                        right: -4,
                        top: -4,
                        child: TweenAnimationBuilder<double>(
                          key: ValueKey(count),
                          tween: Tween(begin: 0.0, end: 1.0),
                          duration: const Duration(milliseconds: 500),
                          curve: Curves.elasticOut,
                          builder: (_, scale, child) =>
                              Transform.scale(scale: scale, child: child),
                          child: Container(
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            constraints: const BoxConstraints(
                                minWidth: 18, minHeight: 18),
                            decoration: BoxDecoration(
                              color: const Color(0xFFEF4444),
                              borderRadius: BorderRadius.circular(9),
                              border: Border.all(color: neuBase, width: 2),
                            ),
                            child: Text(
                              count > 9 ? '9+' : '$count',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 10,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                        ),
                      ),
                  ],
                );
              },
            )
          else
            disc,
          if (showLabel) ...[
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.55),
                fontSize: Responsive.sp(9.5),
                fontWeight: FontWeight.w600,
                letterSpacing: 0.4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ── Navigation app integration ───────────────────────────────────────────
  void _showNavigationSheet({required bool isPickup}) {
    final coords = isPickup ? widget.pickupLatLng : _dropoffLL;
    final address = isPickup ? _pickupAddr : _dropoffAddr;
    final bot = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1F),
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, bot + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Icon(isPickup ? Icons.location_on_rounded : Icons.flag_rounded,
                  color: _gold, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(address,
                  style: const TextStyle(color: Colors.white, fontSize: 15,
                      fontWeight: FontWeight.w700),
                  maxLines: 2, overflow: TextOverflow.ellipsis),
              ),
            ]),
            const SizedBox(height: 20),
            _navOption(
              icon: Icons.map_rounded,
              label: S.of(context).openAppleMaps,
              onTap: () {
                Navigator.pop(context);
                _openAppleMaps(coords);
              },
            ),
            const SizedBox(height: 8),
            _navOption(
              icon: Icons.map_outlined,
              label: S.of(context).openGoogleMaps,
              onTap: () {
                Navigator.pop(context);
                _openGoogleMaps(coords);
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _navOption({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) => GestureDetector(
    onTap: onTap,
    child: Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(children: [
        Container(
          width: 38, height: 38,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: Colors.white70, size: 18),
        ),
        const SizedBox(width: 12),
        Expanded(child: Text(label,
          style: const TextStyle(color: Colors.white, fontSize: 14,
              fontWeight: FontWeight.w600))),
        Icon(Icons.chevron_right_rounded,
            color: Colors.white.withValues(alpha: 0.28), size: 18),
      ]),
    ),
  );

  Future<void> _openAppleMaps(LatLng coords) async {
    final uri = Uri.parse(
      'https://maps.apple.com/?daddr=${coords.latitude},${coords.longitude}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _openGoogleMaps(LatLng coords) async {
    final uri = Uri.parse(
      'https://www.google.com/maps/dir/?api=1'
      '&destination=${coords.latitude},${coords.longitude}');
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ── Safety / Help menus ───────────────────────────────────────────────────
  /// Header pill — sunken neumorphic well, the shared idiom for icon
  /// buttons (see neu_style.dart).
  Widget _headerIconBtn(
    IconData icon,
    VoidCallback onTap, {
    Color? color,
    double size = 19,
  }) {
    final d = Responsive.w(36);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: d,
        height: d,
        decoration: neuBox(radius: 12, pressed: true),
        child: Icon(icon,
            color: color ?? Colors.white.withValues(alpha: 0.75),
            size: Responsive.sp(size)),
      ),
    );
  }

  /// Driver menu, opened from the header. Replaces the bare back arrow.
  ///
  /// Comes in from the left edge, not up from the bottom: a bottom sheet
  /// reads as one more control belonging to the trip, and this is the way
  /// out of it — to the menu, to earnings, to support. The motion is the
  /// only thing that says so before the driver has read a single row.
  void _showDriverMenu() {
    HapticService.mediumImpact();
    final s = S.of(context);
    _showLeftPanel(
      title: s.menu,
      icon: Icons.menu_rounded,
      iconColor: _gold,
      items: [
        // Opens the real driver menu — profile, Cruise Level, earnings,
        // vehicles, documents. It used to drop the driver onto the home
        // screen instead, which is a different place with a different job,
        // and left them a tap further from everything the menu holds.
        _SheetItem(Icons.grid_view_rounded, s.menu, s.driverMenuSubtitle, () {
          Navigator.pop(context);
          Navigator.of(context).push(
            slideFromRightRoute(const DriverMenuScreen()),
          );
        }),
        _SheetItem(Icons.account_balance_wallet_rounded, s.earningsTitle,
            s.earningsMenuSubtitle, () {
          Navigator.pop(context);
          Navigator.of(context).push(
            slideFromRightRoute(const DriverEarningsScreen()),
          );
        }),
        // One row for what used to be two: the header carries a single
        // Safety & Support button now (see _showSafetySupportMenu).
        _SheetItem(Icons.shield_rounded, s.safetyAndSupport,
            s.safetyAndSupportSubtitle, () {
          Navigator.pop(context);
          _showSafetySupportMenu();
        }),
      ],
    );
  }

  /// Safety and support in one panel.
  ///
  /// They were two header buttons opening two sheets, and the split was ours,
  /// not the driver's: someone whose passenger is shouting does not first
  /// decide whether that is a "safety" matter or a "support" matter, they
  /// reach for help. Emergency sits at the top where it can be hit without
  /// reading, the trip problems follow, and Cancel stays at the bottom.
  void _showSafetySupportMenu() {
    HapticService.mediumImpact();
    _showSheet(
      title: S.of(context).safetyAndSupport,
      icon: Icons.shield_rounded,
      iconColor: const Color(0xFF4CAF50),
      fullScreen: true,
      items: [
        _SheetItem(Icons.emergency_rounded, S.of(context).emergency,
            S.of(context).call911OrEmergency, () {
          Navigator.pop(context);
          launchUrl(Uri.parse('tel:911'));
        }),
        _SheetItem(Icons.report_problem_rounded, S.of(context).reportSafetyIssueTip,
            S.of(context).reportSafetyIssueSubtitle, () => Navigator.pop(context)),
        _SheetItem(Icons.share_location_rounded, S.of(context).shareMyLocationTip,
            S.of(context).shareMyLocationSubtitle, () => Navigator.pop(context)),
        // All three go straight into the support chat with the problem
        // already stated, instead of opening a second form to pick a reason
        // from. The reason lists still exist for the cancel flow below.
        // Fase 2 (2026-08-05): the DRIVER proposes a stop or a new
        // destination; the RIDER gets the confirm sheet and pays. This
        // menu only exists during a live trip, so no extra gating.
        _SheetItem(Icons.add_location_alt_rounded,
            S.of(context).addStopLabel,
            S.of(context).riderConfirmsAndPays, () {
          Navigator.pop(context);
          _openProposeRouteChange(isStop: true);
        }),
        _SheetItem(Icons.edit_location_alt_outlined,
            S.of(context).changeDestination,
            S.of(context).riderConfirmsAndPays, () {
          Navigator.pop(context);
          _openProposeRouteChange(isStop: false);
        }),
        _SheetItem(Icons.trip_origin, S.of(context).problemWithPickup,
            S.of(context).problemWithPickupSubtitle,
            () {
          Navigator.pop(context);
          _openSupportChat(
            problem: S.of(context).pickupAddressProblem,
            reportType: 'pickup_address_problem',
          );
        }),
        _SheetItem(Icons.square_rounded, S.of(context).problemWithDropoff,
            S.of(context).problemWithDropoffSubtitle,
            () {
          Navigator.pop(context);
          _openSupportChat(
            problem: S.of(context).dropoffAddressProblem,
            reportType: 'dropoff_address_problem',
          );
        }),
        _SheetItem(Icons.directions_car_rounded, S.of(context).problemWithTrip,
            S.of(context).problemWithTripSubtitle,
            () {
          Navigator.pop(context);
          _openSupportChat(
            problem: S.of(context).tripProblem,
            reportType: 'trip_problem',
          );
        }),
        _SheetItem(Icons.support_agent_rounded, S.of(context).contactSupportTip,
            S.of(context).contactSupportSubtitle,
            () { Navigator.pop(context); _openSupportChat(); }),
        // Cancel lives here now instead of sitting exposed under the
        // slider, where it was one mis-tap away for the whole ride.
        // Still pre-pickup only — never once the rider is aboard.
        if (!_rideStarted)
          _SheetItem(Icons.cancel_outlined, S.of(context).cancelTrip,
              S.of(context).cancelTripMenuSubtitle,
              () { Navigator.pop(context); _showDriverCancelSheet(); },
              danger: true),
      ],
    );
  }

  // ── Contact Support (live chat) ─────────────────────────────────────────
  //
  // [problem] is sent as the driver's opening line the moment the chat is
  // ready. The three "problem with..." buttons used to open a second form
  // asking them to pick a reason from a list, while parked with a passenger
  // waiting; now the tap itself introduces them and states what is wrong.
  //
  // [reportType] still files the structured trip report that form filed.
  // Replacing the flow with a chat message alone would have quietly dropped
  // it: the chat is a conversation, but the report is a typed row on the trip
  // that dispatch can find later without reading a transcript.
  void _openSupportChat({String? problem, String? reportType}) async {
    HapticService.lightImpact();

    if (reportType != null) {
      unawaited(_submitReport(
        type: reportType,
        reason: problem ?? '',
        urgent: false,
      ));
    }

    String? opener;
    if (problem != null) {
      // The driver's own name, not the rider's. Falls back to no introduction
      // rather than to a wrong name or a literal "null".
      String me = '';
      try {
        final u = await UserSession.getUser();
        me = (u?['firstName'] ?? '').trim();
      } catch (_) {}
      if (!mounted) return;
      final es = Localizations.localeOf(context).languageCode.startsWith('es');
      final hello = me.isEmpty
          ? (es ? 'Hola.' : 'Hi.')
          : (es ? 'Hola, mi nombre es $me.' : 'Hi, my name is $me.');
      opener = '$hello $problem';
    }

    if (!mounted) return;
    Navigator.of(context).push(
      // Slides in rather than cutting: the driver is being taken somewhere
      // else mid-trip, and the motion is what tells them so.
      slideFromRightRoute(CruiseSupportChatScreen(
        initialMessage: opener,
        inTrip: true,
        // One conversation per trip. Without this the driver reopens support
        // on trip #400 and lands in the transcript from #398 — including the
        // escalation that muted the bot in it (see CruiseSupportChatScreen's
        // sessionKey). Reopening support during THIS trip keeps its history.
        sessionKey: 'trip:${widget.tripId}',
      )),
    );
  }

  // ── Submit report to Firestore ─────────────────────────────────────────
  Future<void> _submitReport({
    required String type,
    required String reason,
    required bool urgent,
  }) async {
    try {
      // Guard: Firestore subcollection writes require an authenticated
      // request. If the anonymous sign-in in main.dart failed or got
      // invalidated, re-run it here so we don't surface a
      // permission-denied crash to Crashlytics.
      await _ensureFirebaseAuth();
      final driverId = FirebaseAuth.instance.currentUser?.uid ?? '';
      await FirebaseFirestore.instance
          .collection('trips')
          .doc(_fsDocId)
          .collection('reports')
          .add({
        'type': type,
        'reason': reason,
        'reportedAt': FieldValue.serverTimestamp(),
        'tripId': widget.tripId,
        'driverId': driverId,
        if (urgent) 'urgent': true,
      });
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(S.of(context).reportSent),
        // Uses global snackBarTheme
      ));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        // Clean message (2026-08-28): never the raw "ApiException(400): …".
        content: Text(
            '${S.of(context).reportError}: ${e is ApiException ? e.message : S.of(context).connectionError}'),
        backgroundColor: Colors.red,
      ));
    }
  }

  // ── Driver pre-pickup cancel ───────────────────────────────────────────
  // Only reachable while `!_rideStarted` (en route to pickup / arrived but
  // rider not aboard). Once the trip is in_trip the backend rejects direct
  // cancels with 409 and the driver must use the end-ride flow.

  /// Bottom sheet with the MANDATORY reason picker. The labels are
  /// localized; the machine strings are what the API expects.
  void _showDriverCancelSheet() {
    if (_driverCancelling || _rideStarted || _tripFinished) return;
    HapticService.mediumImpact();
    final s = S.of(context);
    // (icon, localized label, machine reason for the API)
    final reasons = <(IconData, String, String)>[
      (Icons.directions_car_rounded, s.driverCancelReasonVehicleIssue, 'vehicle_issue'),
      (Icons.person_off_rounded, s.driverCancelReasonRiderUnreachable, 'rider_unreachable'),
      (Icons.shield_rounded, s.driverCancelReasonSafety, 'safety'),
      (Icons.wrong_location_rounded, s.driverCancelReasonWrongPickup, 'wrong_pickup'),
      (Icons.emergency_rounded, s.emergency, 'emergency'),
      (Icons.more_horiz_rounded, s.otherLabel, 'other'),
    ];
    final bot = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A1F),
          borderRadius: BorderRadius.vertical(top: Radius.circular(22)),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, bot + 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              const Icon(Icons.cancel_outlined,
                  color: Color(0xFFEF4444), size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(s.driverCancelReasonTitle,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 17,
                      fontWeight: FontWeight.w800)),
              ),
            ]),
            const SizedBox(height: 14),
            ...reasons.map((r) => _driverCancelOption(ctx, r)),
            const SizedBox(height: 10),
            GestureDetector(
              onTap: () => Navigator.pop(ctx),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 10),
                child: Text(s.cancelBtn,
                  style: TextStyle(color: Colors.white.withValues(alpha: 0.42),
                      fontSize: 14, fontWeight: FontWeight.w600)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _driverCancelOption(BuildContext ctx, (IconData, String, String) reason) {
    return GestureDetector(
      onTap: () {
        Navigator.pop(ctx);
        _confirmDriverCancel(reason.$3);
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: const Color(0xFF0d0d1a),
          borderRadius: BorderRadius.circular(12),
          border: const Border(left: BorderSide(color: Color(0xFFc8a951), width: 2)),
        ),
        child: Row(children: [
          Icon(reason.$1, color: Colors.white70, size: 18),
          const SizedBox(width: 12),
          Expanded(child: Text(reason.$2,
            style: const TextStyle(color: Colors.white, fontSize: 14,
                fontWeight: FontWeight.w700))),
          const Icon(Icons.chevron_right_rounded,
              color: Color(0xFFc8a951), size: 20),
        ]),
      ),
    );
  }

  /// Explicit confirmation before the cancel request is sent.
  void _confirmDriverCancel(String reason) {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1a1a2e),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(s.driverCancelConfirmTitle,
          style: const TextStyle(color: Colors.white,
              fontWeight: FontWeight.w800, fontSize: 17)),
        content: Text(s.driverCancelConfirmBody,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.70),
              fontSize: 14, height: 1.4)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(s.cancelBtn,
              style: TextStyle(color: Colors.white.withValues(alpha: 0.6))),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.red,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(ctx);
              _performDriverCancel(reason);
            },
            child: Text(s.driverCancelConfirmButton,
              style: const TextStyle(color: Colors.white,
                  fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }

  /// Calls POST /trips/{id}/driver-cancel. On success the trip returns to
  /// "requested" and the backend rematches another driver, so the driver
  /// exits via the SAME return-to-online path the external-cancellation
  /// handler uses (Firestore listener / status poll above).
  Future<void> _performDriverCancel(String reason) async {
    if (_driverCancelling || !mounted) return;
    setState(() => _driverCancelling = true);
    try {
      final pos = _lastDriverPos ?? widget.driverPos;
      await ApiService.driverCancelTrip(
        tripId: widget.tripId,
        reason: reason,
        lat: pos.latitude,
        lng: pos.longitude,
      );
      if (!mounted) return;
      debugPrint('[Driver] Trip cancelled by driver (reason=$reason) → returning to online');
      _tripFinished = true;
      _riderConfirmSub?.cancel();
      _statusPollTimer?.cancel();
      try {
        // A chained ride booked before this cancel is already locked on the
        // backend — hand it to the fresh online screen instead of losing it.
        DriverOnlineScreen.chainedHandoffOffer = ChainedRideStore.take();
        Navigator.of(context).pushAndRemoveUntil(
          PageRouteBuilder(
            // resuming: the driver never went offline — no "Go" chime replay.
            pageBuilder: (_, __, ___) => const DriverOnlineScreen(resuming: true),
            transitionsBuilder: (_, anim, __, child) =>
                FadeTransition(opacity: anim, child: child),
            transitionDuration: const Duration(milliseconds: 400),
          ),
          (route) => route.isFirst, // keep only the very first route (usually home)
        );
      } catch (e) {
        debugPrint('[Driver] driver-cancel-navigate failed: $e');
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      if (e.statusCode == 409) {
        // Rider already aboard → direct cancel no longer allowed.
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).driverCancelRiderAboard),
            backgroundColor: const Color(0xFFEF4444),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('${S.of(context).driverCancelFailed}: ${e.message}'),
            backgroundColor: Colors.red.shade700,
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 5),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          // Clean message (2026-08-28): never the raw "ApiException(400): …".
          content: Text(
              '${S.of(context).driverCancelFailed}: ${e is ApiException ? e.message : S.of(context).connectionError}'),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 5),
        ),
      );
    } finally {
      if (mounted) setState(() => _driverCancelling = false);
    }
  }

  /// [fullScreen] makes the sheet cover the display instead of rising to
  /// roughly half of it. Opt-in per sheet: the driver menu is a destination
  /// and earns the whole screen, while Help and Safety are three-item
  /// pickers that would look abandoned in all that space.
  /// Full-height panel that slides in from the left edge.
  ///
  /// Deliberately a `showGeneralDialog` and not a pushed route: a route would
  /// put a PageRoute over this screen, and the driver home underneath now
  /// drops its Mapbox surface whenever that happens (route_observers.dart).
  /// A popup route leaves the trip's own map alone, which is the whole point
  /// of a panel that is gone in a third of a second.
  void _showLeftPanel({
    required String title,
    required IconData icon,
    required Color iconColor,
    required List<_SheetItem> items,
  }) {
    final media = MediaQuery.of(context);
    // Never the full width: the sliver of trip still showing on the right is
    // what tells the driver this is a layer, not a screen they navigated to.
    final panelW = math.min(media.size.width * 0.86, 360.0);
    showGeneralDialog(
      context: context,
      barrierDismissible: true,
      barrierLabel: MaterialLocalizations.of(context).modalBarrierDismissLabel,
      barrierColor: Colors.black.withValues(alpha: 0.55),
      transitionDuration: const Duration(milliseconds: 320),
      pageBuilder: (ctx, _, __) => Align(
        alignment: Alignment.centerLeft,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: panelW,
            height: double.infinity,
            decoration: const BoxDecoration(
              color: neuBase,
              borderRadius: BorderRadius.only(
                topRight: Radius.circular(22),
                bottomRight: Radius.circular(22),
              ),
            ),
            padding: EdgeInsets.fromLTRB(
                18, media.padding.top + 14, 18, media.padding.bottom + 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(children: [
                  Icon(icon, color: iconColor, size: 22),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w800)),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.pop(ctx),
                    child: Container(
                      width: Responsive.w(34),
                      height: Responsive.w(34),
                      decoration: neuBox(radius: Responsive.w(17), pressed: true),
                      child: Icon(Icons.close_rounded,
                          color: Colors.white.withValues(alpha: 0.8),
                          size: Responsive.sp(18)),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(children: items.map(_buildSheetItem).toList()),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      transitionBuilder: (ctx, anim, __, child) {
        final curved = CurvedAnimation(
          parent: anim,
          curve: Curves.easeOutCubic,
          reverseCurve: Curves.easeInCubic,
        );
        return SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(-1, 0),
            end: Offset.zero,
          ).animate(curved),
          child: FadeTransition(opacity: curved, child: child),
        );
      },
    );
  }

  void _showSheet({
    required String title,
    required IconData icon,
    required Color iconColor,
    required List<_SheetItem> items,
    bool fullScreen = false,
  }) {
    final bot = MediaQuery.of(context).padding.bottom;
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      // A full-height sheet has to clear the status bar, or the drag handle
      // ends up under the clock.
      useSafeArea: fullScreen,
      builder: (_) => Container(
        // double.infinity, not size.height: showModalBottomSheet already
        // constrains the child to the space it is allowed to use, and with
        // useSafeArea that space is smaller than the screen.
        height: fullScreen ? double.infinity : null,
        decoration: BoxDecoration(
          color: neuBase,
          borderRadius: BorderRadius.vertical(
            top: Radius.circular(fullScreen ? 0 : 22),
          ),
        ),
        padding: EdgeInsets.fromLTRB(20, 12, 20, fullScreen ? 0 : bot + 24),
        child: Column(
          mainAxisSize: fullScreen ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Container(
              width: 40, height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(height: 20),
            Row(children: [
              Icon(icon, color: iconColor, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: Colors.white, fontSize: 17,
                        fontWeight: FontWeight.w800)),
              ),
              // A full-height sheet covers the trip, so it needs a visible way
              // back to it. On a half sheet the drag handle and the backdrop
              // are enough, and a button there is clutter.
              if (fullScreen)
                GestureDetector(
                  onTap: () => Navigator.pop(context),
                  child: Container(
                    width: Responsive.w(34),
                    height: Responsive.w(34),
                    decoration: neuBox(radius: Responsive.w(17), pressed: true),
                    child: Icon(Icons.arrow_back_rounded,
                        color: Colors.white.withValues(alpha: 0.8),
                        size: Responsive.sp(18)),
                  ),
                ),
            ]),
            const SizedBox(height: 14),
            // Scrollable when full-height: the items no longer size the
            // sheet, so on a short phone they would overflow instead of
            // shrinking it.
            if (fullScreen)
              Expanded(
                child: SingleChildScrollView(
                  padding: EdgeInsets.only(bottom: bot + 12),
                  child: Column(children: items.map(_buildSheetItem).toList()),
                ),
              )
            else
              ...items.map(_buildSheetItem),
          ],
        ),
      ),
    );
  }

  Widget _buildSheetItem(_SheetItem item) {
    const danger = Color(0xFFEF4444);
    final accent = item.danger ? danger : Colors.white70;
    return GestureDetector(
      onTap: item.onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(14),
        decoration: neuBox(
          radius: 16,
          borderColor: item.danger ? danger.withValues(alpha: 0.35) : null,
        ),
        child: Row(children: [
          Container(
            width: 38, height: 38,
            decoration: neuBox(radius: 12, pressed: true),
            child: Icon(item.icon, color: accent, size: 18),
          ),
          const SizedBox(width: 12),
          Expanded(child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(item.label,
                style: TextStyle(
                    color: item.danger ? danger : Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
              if (item.sub.isNotEmpty) ...[const SizedBox(height: 2),
                Text(item.sub,
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.42),
                      fontSize: 12)),
              ],
            ],
          )),
          Icon(Icons.chevron_right_rounded,
              color: Colors.white.withValues(alpha: 0.28), size: 18),
        ]),
      ),
    );
  }

  // ── Map ─────────────────────────────────────────────────────────────────────

  List<mapbox.Position> _decodePoly(String encoded) {
    final pts = <mapbox.Position>[];
    int i = 0, lat = 0, lng = 0;
    while (i < encoded.length) {
      int s = 0, r = 0, b;
      do { b = encoded.codeUnitAt(i++) - 63; r |= (b & 0x1F) << s; s += 5; } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0; r = 0;
      do { b = encoded.codeUnitAt(i++) - 63; r |= (b & 0x1F) << s; s += 5; } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add(mapbox.Position(lng / 1E5, lat / 1E5));
    }
    return pts;
  }

  /// Load route: prefer cached widget.routePoints, fallback to OSRM fetch
  Future<List<LatLng>> _loadRoute() async {
    // Use cached route only when it actually matches pickup->dropoff.
    if (widget.routePoints != null && widget.routePoints!.length >= 8) {
      final cached = List<LatLng>.from(widget.routePoints!);
      final startMatchesPickup = _haversineMeters(cached.first, widget.pickupLatLng) <= 120;
      final endMatchesDropoff = _haversineMeters(cached.last, _dropoffLL) <= 120;
      if (startMatchesPickup && endMatchesDropoff) {
        return cached;
      }
    }
    // Fetch fresh routed geometry for the mini-map details view.
    return _fetchRoutePoints(widget.pickupLatLng, _dropoffLL);
  }

  // onMapCreated — capture controller + open pan/zoom for the preview.
  void _onMapReady(mapbox.MapboxMap ctrl) {
    _map = ctrl;
    // Cache controller for reuse across driver screens
    MapControllerCache.instance.cache(ctrl);
    // Interactive preview (user spec 2026-09-15): the driver can pan and
    // zoom the mini map to inspect the route. Rotate and pitch stay off —
    // it is a flat top-down preview. The whole block in try/catch:
    // updateSettings are pigeon calls that reject with
    // PlatformException(channel-error) if the surface dies under us. The
    // settings are re-applied in _runStyleLoadedSetup — a surface still
    // initialising here can silently drop this first call, and a preview
    // that will not pan reads as broken.
    try {
      ctrl.gestures.updateSettings(mapbox.GesturesSettings(
        scrollEnabled: true,
        rotateEnabled: false,
        pinchToZoomEnabled: true,
        doubleTapToZoomInEnabled: true,
        doubleTouchToZoomOutEnabled: true,
        pitchEnabled: false,
        quickZoomEnabled: true,
        simultaneousRotateAndPinchToZoomEnabled: false,
      ));
      // Hide compass + attribution for clean preview.
      ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
      ctrl.attribution.updateSettings(mapbox.AttributionSettings(
        iconColor: 0x00000000,
        position: mapbox.OrnamentPosition.BOTTOM_LEFT,
      ));
      ctrl.logo.updateSettings(mapbox.LogoSettings(
        position: mapbox.OrnamentPosition.BOTTOM_LEFT,
        marginLeft: -100,
      ));
    } catch (_) {}
  }

  /// The camera guard mapbox_safe.dart never had. A non-finite centre — or
  /// one past the poles, which arrives the same way, from arithmetic on a
  /// location that was never set — is not a Dart exception we can catch: it
  /// crosses the pigeon channel and raises NSInvalidArgumentException
  /// ("Invalid number value (NaN) in JSON write") inside Objective-C.
  bool _cameraIsSane(mapbox.Point? center, double zoom) {
    if (center == null || !zoom.isFinite) return false;
    final c = center.coordinates;
    final lat = c.lat.toDouble(), lng = c.lng.toDouble();
    return isValidLatLng(lat, lng) && lat.abs() <= 90 && lng.abs() <= 180;
  }

  /// Creates the pickup + dropoff pins on [mgr], or returns null when the
  /// platform channel is already gone.
  ///
  /// These two creates used to be bare while the polyline create right below
  /// them was wrapped — that asymmetry was the whole crash. _onStyleLoaded is
  /// an async void wired as onStyleLoadedListener, so a
  /// PlatformException(channel-error) from a surface that died between the
  /// style event and here had no awaiter and escaped as an unhandled async
  /// error. Returning null instead of throwing makes that impossible, and
  /// lets the caller stop rather than keep talking to a dead channel.
  Future<List<mapbox.PointAnnotation>?> _createPinPair(
    mapbox.PointAnnotationManager mgr, {
    required mapbox.Point pickupPoint,
    required mapbox.Point dropoffPoint,
    required Uint8List pickupBytes,
    required Uint8List dropoffBytes,
    required double iconSize,
  }) async {
    // Rule 17(a): clear the manager before creating.
    //
    // A second style load runs this again on the same manager, and the pins
    // from the first pass are still on it — the create would put a new pair
    // on top of the old one and the driver sees doubled pickup and dropoff
    // markers. deleteAll is the only sweep that reaches annotations whose
    // Dart handles we already dropped.
    try { await mgr.deleteAll(); } catch (_) {}
    // deleteAll took the mid-route stop flag with it, and `_stopPinAnnot` is
    // the one annotation handle in this file that is never nulled anywhere —
    // its create is gated on `_stopPinAnnot == null`, so a swept pin with a
    // live handle could never be drawn again. The flag simply vanished for
    // the rest of the trip. The handle has to die with the pin.
    _stopPinAnnot = null;
    if (!mounted || _annotMgr != mgr) return null;

    // Caught PER CREATE, not around the pair.
    //
    // `Future.wait` propagates the first rejection and DISCARDS whatever the
    // other future resolved to — so if the dropoff create failed and the
    // pickup succeeded, the pickup pin existed natively with no Dart handle
    // left to delete it: precisely the orphan the block below exists to
    // prevent. Resolving each to null instead keeps every handle that was
    // actually produced, so the cleanup can reach it.
    final results = await Future.wait([
      mgr
          .create(mapbox.PointAnnotationOptions(
            geometry: pickupPoint,
            image: pickupBytes, iconSize: iconSize, iconAnchor: mapbox.IconAnchor.BOTTOM,
            iconOffset: const [0.0, 0.0],
          ))
          .then<mapbox.PointAnnotation?>((p) => p)
          .catchError((_) => null),
      mgr
          .create(mapbox.PointAnnotationOptions(
            geometry: dropoffPoint,
            image: dropoffBytes, iconSize: iconSize, iconAnchor: mapbox.IconAnchor.BOTTOM,
            iconOffset: const [0.0, 0.0],
          ))
          .then<mapbox.PointAnnotation?>((p) => p)
          .catchError((_) => null),
    ]);
    final made = results.whereType<mapbox.PointAnnotation>().toList();

    // Two channel round-trips is plenty of time for dispose, or a second
    // style load, to swap the manager underneath us. Pins bound to a
    // manager we no longer hold can never be updated or deleted through
    // _annotMgr again — they would sit on the map as orphan markers
    // (rule 17), so they are dropped here while we still have the handle.
    // A half-made pair goes the same way: one lone pin is worse than none.
    if (!mounted || _annotMgr != mgr || made.length != 2) {
      for (final p in made) {
        try { await mgr.delete(p); } catch (_) {}
      }
      return null;
    }
    return made;
  }

  // onStyleLoadedListener — style is guaranteed ready here; run all setup.
  /// The listener Mapbox actually calls — a net around the whole setup.
  ///
  /// This is wired as `onStyleLoadedListener`, so it is an async void that
  /// NOBODY awaits: any rejection escapes as an unhandled async error and
  /// takes the isolate with it. The body below has a dozen awaits into the
  /// platform channel (`cameraForCoordinateBounds`, `setCamera`, annotation
  /// creates, the route animation), and every one of them rejects with
  /// PlatformException(channel-error) if the driver leaves the screen
  /// between the style event and that line. Guarding only the first await —
  /// which is what shipped — left the other eleven bare.
  ///
  /// Catching here is not swallowing: with the surface gone there is no map
  /// left to draw on, so stopping is the only correct continuation.
  Future<void> _onStyleLoaded(mapbox.StyleLoadedEventData e) async {
    try {
      await _runStyleLoadedSetup(e);
    } on PlatformException catch (err) {
      debugPrint('[TripAccept] style setup abandoned — map channel gone: $err');
    }
  }

  Future<void> _runStyleLoadedSetup(mapbox.StyleLoadedEventData _) async {
    final ctrl = _map;
    if (ctrl == null || !mounted) return;

    // Fire all independent setup in parallel for speed.
    final setupFutures = <Future>[
      MapTheme.applyNavyGold(ctrl),
      ctrl.annotations.createPolylineAnnotationManager().then((m) => _polyMgr = m),
      ctrl.annotations.createPointAnnotationManager().then((m) async {
        _annotMgr = m;
        try {
          // Keep pins upright in mini-map while preserving bottom tip anchor.
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-pitch-alignment', 'viewport');
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-rotation-alignment', 'viewport');
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-allow-overlap', true);
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-ignore-placement', true);
          await ctrl.style.setStyleLayerProperty(m.id, 'icon-anchor', 'bottom');
        } catch (_) {}
      }),
    ];
    // The style-loaded event is delivered by the platform, and it can land
    // AFTER the surface is gone — the driver dismissed the offer, the app
    // went to background, or MapSurfaceCoordinator handed the surface to
    // another screen. Every pigeon call then rejects with
    // PlatformException(channel-error), and this method is an async void
    // wired as onStyleLoadedListener: nobody awaits it, so that rejection
    // escaped as an unhandled async error and took down the isolate.
    // Catching it here is not swallowing — without the managers there is no
    // map left to draw on, so stopping is the only correct continuation.
    try {
      await Future.wait(setupFutures);
    } on PlatformException catch (_) {
      return;
    }
    if (!mounted) return;

    // Re-apply the interactive gestures (user spec 2026-09-16): the same
    // settings _onMapReady asks for, repeated here because a surface still
    // initialising at onMapCreated can silently drop that first call — and
    // a preview that will not pan reads as broken.
    try {
      await ctrl.gestures.updateSettings(mapbox.GesturesSettings(
        scrollEnabled: true,
        rotateEnabled: false,
        pinchToZoomEnabled: true,
        doubleTapToZoomInEnabled: true,
        doubleTouchToZoomOutEnabled: true,
        pitchEnabled: false,
        quickZoomEnabled: true,
        simultaneousRotateAndPinchToZoomEnabled: false,
      ));
    } catch (e) {
      debugPrint('[DriverTrip] gesture re-apply failed: $e');
    }
    if (!mounted) return;

    // Load route + render pins in parallel. _loadPreviewRoute usually beat
    // us to the route — reuse it instead of hitting the network again.
    final results = await Future.wait([
      _routePoints.length >= 2 ? Future.value(_routePoints) : _loadRoute(),
      renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32),
      renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 32),
    ]);
    if (!mounted) return;

    _routePoints = results[0] as List<LatLng>;
    final pickupPinBytes = results[1] as Uint8List;
    final dropoffPinBytes = results[2] as Uint8List;

    // A failed route fetch leaves _routePoints EMPTY — there is no
    // straight-line stand-in any more. Do NOT bail out here: the pins and
    // the camera fit still owe the driver the two endpoints, and every
    // route draw below is already guarded on `_routePoints.length >= 2`.

    // Do NOT force raw pin coordinates — Mapbox Directions API already
    // snaps start/end to the nearest road. Replacing them with the user's
    // raw coordinates creates off-road straight-line segments.

    // Include pickup + dropoff + route in bounds so both addresses fill the
    // card. driverPos is deliberately OUT of the fold (user spec 2026-08-08):
    // the route already covers both endpoints, the car always sits on or near
    // it, and framing the driver's current fix pushed the zoom out.
    //
    // The old fold was NaN-blind: it seeded minLat/maxLat/minLng/maxLng with
    // the 90/-90/180/-180 sentinels, and every `<` / `>` against a NaN is
    // false — so a single NaN in pickup/dropoff/route left the
    // sentinels in place and produced an INVERTED CoordinateBounds
    // (southwest 180/90, northeast -180/-90). cameraForCoordinateBounds
    // resolved that to a non-finite centre which went straight back through
    // setCamera, and a NaN crossing the channel is not a Dart exception: it
    // raises NSInvalidArgumentException "Invalid number value (NaN) in JSON
    // write" inside convertDictionaryToGeometry, which no `catch` on this
    // side can hold. The pins below already went through safePoint() and the
    // polyline through safeLineString() — that asymmetry is exactly why the
    // annotations survived and the camera did not; mapbox_safe.dart never
    // covered the camera. Now: drop non-finite and out-of-range points
    // first, and seed the fold from a real point so no sentinel can leak.
    final allPoints = <LatLng>[
      widget.pickupLatLng,
      _dropoffLL,
      ..._routePoints,
    ].where((p) =>
        isValidLatLng(p.latitude, p.longitude) &&
        p.latitude.abs() <= 90 &&
        p.longitude.abs() <= 180).toList();
    mapbox.CoordinateBounds? bounds;
    if (allPoints.isNotEmpty) {
      double minLat = allPoints.first.latitude, maxLat = minLat;
      double minLng = allPoints.first.longitude, maxLng = minLng;
      for (final p in allPoints) {
        if (p.latitude  < minLat) minLat = p.latitude;
        if (p.latitude  > maxLat) maxLat = p.latitude;
        if (p.longitude < minLng) minLng = p.longitude;
        if (p.longitude > maxLng) maxLng = p.longitude;
      }
      bounds = mapbox.CoordinateBounds(
        southwest: mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
        northeast: mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat)),
        infiniteBounds: false,
      );
    }
    // Compute a small auto-bearing based on route direction for a pleasant angle.
    // atan2 over a NaN route point returns NaN, and that NaN rode into the
    // camera as the bearing — same crossing, same Objective-C raise.
    final rBearing = _routeBearing(_routePoints);
    final prettBearing = rBearing.isFinite ? (rBearing + 15.0) % 360 : 0.0;

    // ── If returning (animation already played), show final state instantly ──
    if (_miniMapAnimDone || widget.arrivedAtPickup) {
      _miniMapAnimDone = true;
      // Top-down eagle view only (user spec 2026-08-04 — the tilt is gone).
      // No finite point to frame means no camera move: skipping the fit
      // leaves the map wherever it was, which is survivable — writing a
      // non-finite camera is not.
      if (bounds != null) {
        final cam = await ctrl.cameraForCoordinateBounds(
          bounds,
          mapbox.MbxEdgeInsets(top: 60, left: 50, bottom: 70, right: 50),
          prettBearing,
          0,
          null, null,
        );
        if (!mounted) return;
        // Moderate zoom in (user spec 2026-08-08): only −0.2 below the exact
        // fit so the whole route fills the card, clamped to [9.0, 15.5]
        // (clamp() passes a NaN straight through, so it is checked).
        final targetZoom = ((cam.zoom ?? 13) - 0.2).clamp(9.0, 15.5);
        if (_cameraIsSane(cam.center, targetZoom)) {
          ctrl.setCamera(mapbox.CameraOptions(
            center: cam.center, zoom: targetZoom, bearing: prettBearing, pitch: 0.0,
          )).catchError((Object _) {});
        }
      }
      // Place pins + route instantly
      final pickupPoint = safePoint(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude);
      final dropoffPoint = safePoint(_dropoffLL.longitude, _dropoffLL.latitude);
      _pinAnnots.clear();
      final mgr = _annotMgr;
      if (mgr != null && pickupPoint != null && dropoffPoint != null) {
        final pins = await _createPinPair(
          mgr,
          pickupPoint: pickupPoint,
          dropoffPoint: dropoffPoint,
          pickupBytes: pickupPinBytes,
          dropoffBytes: dropoffPinBytes,
          iconSize: 0.62,
        );
        // A dead channel here means the surface is gone: there is no route
        // to draw and no car to start on top of pins that do not exist.
        if (pins == null) return;
        _pinAnnots.addAll(pins);
      }
      if (_polyMgr != null && _routePoints.length >= 2) {
        final safeGeom = safeLineString(_routePoints);
        if (safeGeom != null) {
          try {
            _routeAnnot = await _polyMgr!.create(mapbox.PolylineAnnotationOptions(
              geometry: safeGeom,
              lineColor: const Color(0xFFFFD700).toARGB32(),
              lineWidth: 3.5,
              lineJoin: mapbox.LineJoin.ROUND,
            ));
          } catch (_) {}
        }
      }
      // Resume mid-trip: the pickup already happened — no pin to pop.
      if (_rideStarted && _pinAnnots.isNotEmpty) {
        _pickupPopped = true;
        final pickupPin = _pinAnnots.removeAt(0);
        try { await _annotMgr?.delete(pickupPin); } catch (_) {}
      }
      unawaited(_startMiniMapCar());
      return;
    }

    // ── First visit: animated sequence ──

    // STEP 1: Fit bounds at pitch 0 (top-down) so everything is visible flat
    // Same guard as the resume branch: with no finite point to frame there
    // is nothing to fit, and a NaN centre would raise in Objective-C.
    if (bounds != null) {
      final camFlat = await ctrl.cameraForCoordinateBounds(
        bounds,
        mapbox.MbxEdgeInsets(top: 60, left: 50, bottom: 70, right: 50),
        prettBearing,
        0, // pitch 0 for flat fit
        null, null,
      );
      if (!mounted) return;
      // Same moderate zoom as the resume branch: −0.2 below the exact fit,
      // the full route filling the card, clamped to [9.0, 15.5].
      final targetZoom = ((camFlat.zoom ?? 13) - 0.2).clamp(9.0, 15.5);
      if (_cameraIsSane(camFlat.center, targetZoom)) {
        ctrl.setCamera(mapbox.CameraOptions(
          center: camFlat.center, zoom: targetZoom, bearing: prettBearing, pitch: 0.0,
        )).catchError((Object _) {});
      }
    }

    // STEP 2: Pins pop in (scale 0 → 1.0 with spring)
    final pickupPoint = safePoint(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude);
    final dropoffPoint = safePoint(_dropoffLL.longitude, _dropoffLL.latitude);
    _pinAnnots.clear();
    final mgr = _annotMgr;
    if (mgr != null && pickupPoint != null && dropoffPoint != null) {
      final pins = await _createPinPair(
        mgr,
        pickupPoint: pickupPoint,
        dropoffPoint: dropoffPoint,
        pickupBytes: pickupPinBytes,
        dropoffBytes: dropoffPinBytes,
        iconSize: 0.01,
      );
      // Channel gone: there are no pins to pop, no route to animate and no
      // car to launch. Pressing on only queues more rejected pigeon calls.
      if (pins == null) return;
      _pinAnnots.addAll(pins);
    }
    // Animate pins: 0.01 → 1.15 → 1.0 over 400ms
    const pinMs = 400;
    final pinSw = Stopwatch()..start();
    await Future.doWhile(() async {
      await Future.delayed(const Duration(milliseconds: 16));
      if (!mounted) return false;
      final t = (pinSw.elapsedMilliseconds / pinMs).clamp(0.0, 1.0);
      double scale;
      if (t < 0.6) {
        scale = Curves.easeOutCubic.transform(t / 0.6) * 0.70;
      } else if (t < 0.85) {
        scale = 0.70 - 0.08 * Curves.easeInOut.transform((t - 0.6) / 0.25);
      } else {
        scale = 0.62;
      }
      for (final pin in _pinAnnots) {
        pin.iconSize = scale;
        try { await _annotMgr?.update(pin); } catch (_) {}
      }
      return t < 1.0;
    });
    if (!mounted) return;

    // STEP 3: Animated route draw (use robust ticker-based method)
    if (_polyMgr != null && _routePoints.length >= 2) {
      try {
        // Filter out any invalid coordinates before drawing
        final validPts = _routePoints.where((p) =>
          p.latitude.isFinite && p.longitude.isFinite &&
          p.latitude.abs() <= 90 && p.longitude.abs() <= 180
        ).toList();
        if (validPts.length >= 2) {
          await _animateGoldRoute(points: validPts)
              .timeout(const Duration(seconds: 8));
        }
      } catch (_) {
        // Fallback: draw full route instantly if animation fails/times out
        if (_polyMgr != null && _routePoints.length >= 2 && mounted) {
          final safeGeom = safeLineString(_routePoints);
          if (safeGeom != null) {
            try {
              _routeAnnot ??= await _polyMgr!.create(mapbox.PolylineAnnotationOptions(
                geometry: safeGeom,
                lineColor: const Color(0xFFFFD700).toARGB32(),
                lineWidth: 3.5,
                lineJoin: mapbox.LineJoin.ROUND,
              ));
            } catch (_) {}
          }
        }
      }
    }
    if (!mounted) return;

    // Top-down eagle view only — the 0°→40° tilt and the 10 s camera
    // cycle are gone (user spec 2026-08-04: no map-tilting animations).
    _miniMapAnimDone = true;
    unawaited(_startMiniMapCar());
  }

  // Camera cycle + tilt functions removed 2026-08-04: the mini map is a
  // fixed top-down eagle view now (user spec — no tilting animations).

  // ═══ Live car + route erase + pickup pop-out + light sweep ═══

  /// The driver's own car on the mini map, gliding through SmoothMotion
  /// (rule 13) — never hopping fix to fix.
  Future<void> _startMiniMapCar() async {
    final ctrl = _map;
    if (ctrl == null || !mounted || kIsWeb) return;
    if (_carMgr != null) return;
    try {
      _carMgr = await ctrl.annotations.createPointAnnotationManager();
      try {
        await ctrl.style.setStyleLayerProperty(_carMgr!.id, 'icon-rotation-alignment', 'map');
        await ctrl.style.setStyleLayerProperty(_carMgr!.id, 'icon-allow-overlap', true);
        await ctrl.style.setStyleLayerProperty(_carMgr!.id, 'icon-ignore-placement', true);
      } catch (_) {}
      // Same car PNG as the rider tracking map (user spec 2026-08-08 — was
      // the Canvas-rendered black Uber car): same rideName→asset mapping as
      // lib/map/tracking_map_car.dart, resized to maxDim 240 like there.
      final rideName = widget.vehicleType.toLowerCase();
      final carAsset =
          rideName.contains('vip') || rideName.contains('suv') ||
                  rideName.contains('suburban') || rideName.contains('luxury')
              ? 'assets/images/car_suv.png'
              : rideName.contains('sedan') || rideName.contains('premium') ||
                      rideName.contains('fusion')
                  ? 'assets/images/car_sedan.png'
                  : 'assets/images/car_suv.png';
      if (_carBytes == null) {
        try {
          final raw = await rootBundle.load(carAsset);
          _carBytes = await _resizePngForMap(raw.buffer.asUint8List(), maxDim: 240);
        } catch (e) {
          debugPrint('[DriverTrip] mini-map car load failed ($carAsset): $e');
        }
      }
      if (!mounted || _carBytes == null || _carMgr == null) return;
      final p0 = safePoint(widget.driverPos.longitude, widget.driverPos.latitude);
      if (p0 == null) return;
      _carMotion.setTarget(widget.driverPos.latitude, widget.driverPos.longitude);
      _carAnnot = await _carMgr!.create(mapbox.PointAnnotationOptions(
        geometry: p0,
        image: _carBytes!,
        iconSize: 0.50,
        iconRotate: 0,
      ));
      _carGpsSub?.cancel();
      _carGpsSub = Geolocator.getPositionStream(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          distanceFilter: 3,
        ),
      ).listen((pos) {
        if (!mounted) return;
        double? brg;
        final prev = _prevCarFix;
        final here = LatLng(pos.latitude, pos.longitude);
        if (prev != null && _haversineMeters(prev, here) > 2) {
          brg = Geolocator.bearingBetween(
              prev.latitude, prev.longitude, pos.latitude, pos.longitude);
        }
        _prevCarFix = here;
        _carMotion.setTarget(pos.latitude, pos.longitude,
            bearing: brg,
            accuracyM: pos.accuracy,
            timestampMs: pos.timestamp.millisecondsSinceEpoch.toDouble());
        _ensureCarTicker();
      }, onError: (Object e) {
        debugPrint('[DriverTrip] mini-map car stream error: $e');
      });
      _ensureCarTicker();
    } catch (e) {
      debugPrint('[DriverTrip] mini-map car setup failed: $e');
    }
  }

  /// Resize a PNG to a sane map-icon size and return PNG bytes (not RGBA) —
  /// the same helper the rider tracking map uses, duplicated here rather
  /// than dragged across the tracking pipeline.
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

  void _ensureCarTicker() {
    _carTicker ??= createTicker(_onCarTick);
    if (!_carTicker!.isActive) {
      _carLastTick = Duration.zero;
      _carTicker!.start();
    }
  }

  void _onCarTick(Duration elapsed) {
    if (!mounted) {
      _carTicker?.stop();
      return;
    }
    final dt = _carLastTick == Duration.zero
        ? 0.016
        : (elapsed - _carLastTick).inMicroseconds / 1e6;
    _carLastTick = elapsed;
    _carMotion.tick(dt.clamp(0.0, 0.1));
    final lat = _carMotion.lat, lng = _carMotion.lng;
    final annot = _carAnnot;
    final mgr = _carMgr;
    if (lat == null || lng == null || annot == null || mgr == null) return;
    if (!_carUpdateInFlight) {
      final p = safePoint(lng, lat);
      final bearing = _carMotion.bearing;
      // Skip the native update when nothing changed: ~1 mm of position and
      // half a degree of rotation are below anything the eye can register,
      // and each skipped call is a full native re-render saved.
      final moved = _lastSentCarLat == null ||
          (lat - _lastSentCarLat!).abs() > 1e-7 ||
          (lng - _lastSentCarLng!).abs() > 1e-7 ||
          ((bearing - (_lastSentCarBearing ?? bearing)).abs() > 0.5);
      if (p != null && moved) {
        _carUpdateInFlight = true;
        _lastSentCarLat = lat;
        _lastSentCarLng = lng;
        _lastSentCarBearing = bearing;
        annot.geometry = p;
        annot.iconRotate = bearing;
        mgr
            .update(annot)
            .catchError((_) {})
            .whenComplete(() => _carUpdateInFlight = false);
      }
    }
    // Erase the line behind the car once the rider is aboard — the
    // geometry IPC is throttled to ~6 Hz, the car itself stays 60 fps.
    if (_rideStarted &&
        _routeAnnot != null &&
        DateTime.now().difference(_lastEraseAt).inMilliseconds > 160) {
      _lastEraseAt = DateTime.now();
      _eraseRouteBehindCar(LatLng(lat, lng));
    }
  }

  /// Trim the gold line to [car → dropoff]. Monotonic: the erase index
  /// never walks backwards, so GPS wander cannot resurrect eaten road.
  void _eraseRouteBehindCar(LatLng car) {
    final pts = _routePoints;
    final annot = _routeAnnot;
    final mgr = _polyMgr;
    if (annot == null || mgr == null || pts.length < 2) return;
    var best = double.infinity;
    var bestIdx = _eraseHintIdx;
    final from = (_eraseHintIdx - 5).clamp(0, pts.length - 1);
    for (var i = from; i < pts.length; i++) {
      final d = _haversineMeters(car, pts[i]);
      if (d < best) {
        best = d;
        bestIdx = i;
      }
    }
    if (best > 120) return; // off the drawn road — leave the line alone
    if (bestIdx < _eraseHintIdx) bestIdx = _eraseHintIdx;
    _eraseHintIdx = bestIdx;
    if (bestIdx >= pts.length - 1) return;
    // The remaining line starts at the car's projection ON the road
    // segment, not at the raw GPS fix: a straight car→next-vertex
    // connector cuts the corner across the block and reads as "the line
    // doesn't follow the streets".
    final start = _projectOntoSegment(car, pts[bestIdx], pts[bestIdx + 1]);
    final geom = safeLineString(<LatLng>[start, ...pts.sublist(bestIdx + 1)]);
    if (geom == null) return;
    annot.geometry = geom;
    mgr.update(annot).catchError((_) {});
  }

  /// [p] projected onto the a→b segment, in local meters. Keeps the eaten
  /// route glued to the road instead of jumping to the car's raw fix.
  LatLng _projectOntoSegment(LatLng p, LatLng a, LatLng b) {
    final cosLat = math.cos(a.latitude * math.pi / 180.0);
    final bx = (b.longitude - a.longitude) * 111320.0 * cosLat;
    final by = (b.latitude - a.latitude) * 110540.0;
    final px = (p.longitude - a.longitude) * 111320.0 * cosLat;
    final py = (p.latitude - a.latitude) * 110540.0;
    final len2 = bx * bx + by * by;
    if (len2 <= 0) return a;
    final t = ((px * bx + py * by) / len2).clamp(0.0, 1.0);
    return LatLng(
      a.latitude + (b.latitude - a.latitude) * t,
      a.longitude + (b.longitude - a.longitude) * t,
    );
  }

  /// Rider aboard: the pickup pin pops OUT, then a light travels the
  /// pickup→dropoff line — the line is already there, only the light
  /// sweeps it (user spec 2026-08-04). Nothing is destroyed.
  void _onRideStartedMiniMap() {
    if (_pickupPopped) return;
    _pickupPopped = true;
    unawaited(_popOutPickupPin());
    unawaited(_runRouteLightSweep());
  }

  Future<void> _popOutPickupPin() async {
    final mgr = _annotMgr;
    if (mgr == null || _pinAnnots.isEmpty || !mounted) return;
    final pin = _pinAnnots.removeAt(0); // pickup is created first
    const ms = 320;
    final sw = Stopwatch()..start();
    try {
      await Future.doWhile(() async {
        await Future.delayed(const Duration(milliseconds: 16));
        if (!mounted) return false;
        final t = (sw.elapsedMilliseconds / ms).clamp(0.0, 1.0);
        // Swell 0.62 → 0.85, then shrink to nothing.
        final sc = t < 0.35
            ? 0.62 + 0.23 * Curves.easeOut.transform(t / 0.35)
            : 0.85 * (1 - Curves.easeIn.transform((t - 0.35) / 0.65));
        pin.iconSize = sc.clamp(0.01, 1.0);
        try {
          await mgr.update(pin);
        } catch (_) {
          return false;
        }
        return t < 1.0;
      });
    } catch (_) {}
    try {
      await mgr.delete(pin);
    } catch (_) {}
  }

  Future<void> _runRouteLightSweep() async {
    final mgr = _polyMgr;
    final pts = List<LatLng>.of(_routePoints);
    if (mgr == null || pts.length < 2 || !mounted) return;
    const ms = 1400;
    final sw = Stopwatch()..start();
    try {
      await Future.doWhile(() async {
        await Future.delayed(const Duration(milliseconds: 24));
        if (!mounted) return false;
        final t = Curves.easeInOutCubic
            .transform((sw.elapsedMilliseconds / ms).clamp(0.0, 1.0));
        final n = (pts.length * t).round().clamp(2, pts.length);
        final geom = safeLineString(pts.sublist(0, n));
        if (geom != null) {
          try {
            if (_sweepAnnot == null) {
              _sweepAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
                geometry: geom,
                lineColor: const Color(0xFFFFF3B0).toARGB32(),
                lineWidth: 4.5,
                lineJoin: mapbox.LineJoin.ROUND,
              ));
            } else {
              _sweepAnnot!.geometry = geom;
              await mgr.update(_sweepAnnot!);
            }
          } catch (_) {
            return false;
          }
        }
        return sw.elapsedMilliseconds < ms;
      });
      // Hold the lit line a beat, then the base gold line carries on.
      await Future.delayed(const Duration(milliseconds: 350));
    } catch (_) {}
    final sweep = _sweepAnnot;
    _sweepAnnot = null;
    if (sweep != null) {
      try {
        await mgr.delete(sweep);
      } catch (_) {}
    }
  }

  /// Dispatch advanced the trip from the panel — mirror it locally so the
  /// action button morphs to the matching stage (the AnimatedSwitcher on
  /// the phase router does the silk).
  void _applyRemoteStage(String rawStatus) {
    if (_tripFinished || !mounted) return;
    const arrivedAliases = {'arrived', 'driver_arrived', 'arrived_pickup', 'arrived_at_pickup'};
    const inTripAliases = {'in_trip', 'on_trip', 'in_progress', 'rider_onboard', 'trip_started'};
    final status = rawStatus.trim().toLowerCase();
    var changed = false;
    if (inTripAliases.contains(status) && !_rideStarted) {
      _arrivedConfirmed = true;
      _arrivedSlidDone = true;
      _nearPickup = true;
      _rideStarted = true;
      _startRideSlidDone = true;
      changed = true;
      _startDropoffProximityDetection();
      _onRideStartedMiniMap();
    } else if (arrivedAliases.contains(status) && !_arrivedConfirmed) {
      _arrivedConfirmed = true;
      _arrivedSlidDone = true;
      _nearPickup = true;
      changed = true;
    }
    if (changed) {
      debugPrint('[DriverTrip] remote stage → $status (dispatch advanced the trip)');
      HapticService.mediumImpact();
      setState(() {});
    }
  }

  /// Leave after a remote cancel. When the online screen is right
  /// underneath (the normal accept flow) POP back to it — it re-acquires
  /// the map surface on our dispose and handles the 'cancelled' result
  /// with its gold toast: nothing destroyed, nothing rebuilt. Orphan
  /// entry points (resume-from-home, push notification) keep the
  /// rebuild fallback.
  void _exitAfterRemoteCancel() {
    final nav = Navigator.of(context);
    if (nav.canPop()) {
      // The online screen underneath consumes this when it resets to
      // searching (_handoffChainedOffer) — a chained ride booked before the
      // cancel is already locked on the backend and must not die with this
      // screen.
      DriverOnlineScreen.chainedHandoffOffer = ChainedRideStore.take();
      nav.pop('cancelled');
      return;
    }
    // A chained ride booked before this cancel is already locked on the
    // backend — hand it to the fresh online screen instead of losing it.
    DriverOnlineScreen.chainedHandoffOffer = ChainedRideStore.take();
    nav.pushAndRemoveUntil(
      PageRouteBuilder(
        // resuming: the driver never went offline — no "Go" chime replay.
        pageBuilder: (_, __, ___) =>
            const DriverOnlineScreen(showCancelledNotice: true, resuming: true),
        transitionsBuilder: (_, anim, __, child) =>
            FadeTransition(opacity: anim, child: child),
        transitionDuration: const Duration(milliseconds: 400),
      ),
      (route) => route.isFirst,
    );
  }

  /// Compute overall bearing of the route (start → end) for camera orientation.
  double _routeBearing(List<LatLng> pts) {
    if (pts.length < 2) return 0;
    final a = pts.first;
    final b = pts.last;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final lat1 = a.latitude * math.pi / 180;
    final lat2 = b.latitude * math.pi / 180;
    final y = math.sin(dLng) * math.cos(lat2);
    final x = math.cos(lat1) * math.sin(lat2) -
        math.sin(lat1) * math.cos(lat2) * math.cos(dLng);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Web preview setup: same navy/gold, same gold route, same two pins.
  /// There is no one-surface limit in the browser, so no coordinator here.
  Future<void> _setupWebPreview(WebMapController c) async {
    _webMapCtrl = c;
    // The same navy/gold the native map gets in _onStyleLoaded — raw
    // dark-v11 is grey, not ours.
    c.applyNavyGoldTheme();
    try {
      final pts = _routePoints.length >= 2 ? _routePoints : await _loadRoute();
      if (!mounted || _webMapCtrl != c) return;
      _routePoints = pts;
      final pins = await Future.wait([
        renderCircularPinBytes(icon: CircularPinIcon.person, isPickup: true, radius: 32),
        renderCircularPinBytes(icon: CircularPinIcon.flag, isPickup: false, radius: 32),
      ]);
      if (!mounted || _webMapCtrl != c) return;
      // pts may legitimately be empty (all providers failed): no line is
      // drawn then — never a straight stand-in — but the pins still are.
      if (pts.length >= 2) {
        c.setPolyline(
          'preview-route',
          pts.map((p) => (lng: p.longitude, lat: p.latitude)).toList(),
          color: '#FFD700',
          width: 5,
        );
      }
      c.addMarker('pickup', widget.pickupLatLng.longitude,
          widget.pickupLatLng.latitude, iconBytes: pins[0]);
      c.addMarker('dropoff', _dropoffLL.longitude,
          _dropoffLL.latitude, iconBytes: pins[1]);
      // Same content as the native fit: pickup + dropoff + route (driverPos
      // stays out of the bounds on web too, user spec 2026-08-08), with
      // extra bottom padding so the "N min trip" chip never covers it.
      c.fitBounds([
        (lng: widget.pickupLatLng.longitude, lat: widget.pickupLatLng.latitude),
        (lng: _dropoffLL.longitude, lat: _dropoffLL.latitude),
        ...pts.map((p) => (lng: p.longitude, lat: p.latitude)),
      ], paddingTop: 60, paddingLeft: 50, paddingBottom: 70, paddingRight: 50);
    } catch (e) {
      debugPrint('[DriverTripAccept] web preview setup failed: $e');
    }
  }

  /// Fetch route points: Mapbox → OSRM, retried once after a short backoff.
  ///
  /// Returns an EMPTY list when every provider fails — never the two-endpoint
  /// straight line this used to fall back to. A line cutting across blocks
  /// lies; the pins and the StaticRoutePreview still render without it.
  Future<List<LatLng>> _fetchRoutePoints(LatLng o, LatLng d) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) break;
      }
      final pts = await _fetchRoutePointsOnce(o, d);
      if (pts.length >= 2) return pts;
    }
    debugPrint('[DriverTripAccept] route providers failed — no line drawn');
    return const [];
  }

  /// One pass over the providers: Mapbox Directions → OSRM.
  Future<List<LatLng>> _fetchRoutePointsOnce(LatLng o, LatLng d) async {
    // Mapbox Directions API (primary)
    try {
      final mbxUrl = Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/driving/'
        '${o.longitude},${o.latitude};${d.longitude},${d.latitude}'
        '?geometries=geojson&overview=full&steps=false'
        '&access_token=${MapboxConfig.accessToken}',
      );
      final mbxRes = await http.get(mbxUrl).timeout(const Duration(seconds: 8));
      if (mbxRes.statusCode == 200) {
        final mbxData = jsonDecode(mbxRes.body);
        final mbxRoutes = mbxData['routes'] as List?;
        if (mbxRoutes != null && mbxRoutes.isNotEmpty) {
          final coords = mbxRoutes[0]['geometry']?['coordinates'] as List?;
          if (coords != null && coords.isNotEmpty) {
            final pts = coords
                .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
            return pts;
          }
        }
      }
    } catch (_) {}
    // OSRM fallback
    try {
      final path = '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full', 'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      final data = jsonDecode(res.body) as Map<String, dynamic>;
      if (data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final positions = _decodePoly(routes[0]['geometry'] as String);
          final pts = positions.map((p) => LatLng(p.lat.toDouble(), p.lng.toDouble())).toList();
          if (pts.length >= 2) return pts;
        }
      }
    } catch (_) {}
    // No last-resort straight line: empty means "no route line" — pins and
    // camera still get drawn by the caller.
    return const [];
  }

  /// Smooth 60fps gold route draw with distance-based interpolation.
  /// The line tip smoothly glides along the road geometry instead of jumping
  /// between discrete polyline vertices.
  Future<void> _animateGoldRoute({
    required List<LatLng> points,
    Duration? duration,
  }) async {
    final polyMgr = _polyMgr;
    if (polyMgr == null || points.length < 2) return;

    // Pre-create annotation before ticker to avoid async frame skipping
    if (_routeAnnot != null) { try { await polyMgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }
    final initSafe = safeLineString(points.sublist(0, 2));
    if (initSafe == null) return;
    _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
      geometry: initSafe,
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 3.5,
      lineJoin: mapbox.LineJoin.ROUND,
    ));
    if (!mounted || _routeAnnot == null) return;

    // Pre-compute cumulative distances for distance-based interpolation
    final cumDist = <double>[0.0];
    for (int i = 1; i < points.length; i++) {
      final dx = points[i].longitude - points[i - 1].longitude;
      final dy = points[i].latitude - points[i - 1].latitude;
      cumDist.add(cumDist.last + math.sqrt(dx * dx + dy * dy));
    }
    final totalDist = cumDist.last;
    if (totalDist <= 0) return;

    final totalMs = duration?.inMilliseconds ?? (points.length * 10).clamp(1800, 3500);
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    bool updating = false;
    double lastFrac = -1;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (updating) return;
      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      // S-curve easing for fluid acceleration/deceleration
      final eased = progress < 0.5
          ? 4 * progress * progress * progress
          : 1 - math.pow(-2 * progress + 2, 3) / 2;
      final targetDist = eased * totalDist;

      // Find which segment the tip falls in
      int seg = 0;
      for (int i = 1; i < cumDist.length; i++) {
        if (cumDist[i] >= targetDist) { seg = i - 1; break; }
        if (i == cumDist.length - 1) seg = i - 1;
      }

      // Fractional position within segment for smooth interpolation
      final segLen = cumDist[seg + 1] - cumDist[seg];
      final frac = segLen > 0 ? (targetDist - cumDist[seg]) / segLen : 1.0;
      final quantized = (seg * 1000 + (frac * 100).round()).toDouble();
      if (quantized == lastFrac) return;
      lastFrac = quantized;

      // Build coords: all points up to seg + interpolated tip
      final coords = <mapbox.Position>[];
      for (int i = 0; i <= seg; i++) {
        coords.add(mapbox.Position(points[i].longitude, points[i].latitude));
      }
      // Interpolated tip point
      final tipLat = points[seg].latitude + frac * (points[seg + 1].latitude - points[seg].latitude);
      final tipLng = points[seg].longitude + frac * (points[seg + 1].longitude - points[seg].longitude);
      if (!isValidLatLng(tipLat, tipLng)) return;
      coords.add(mapbox.Position(tipLng, tipLat));

      final safeCoords = coords.where((p) => isValidLatLng(p.lat.toDouble(), p.lng.toDouble())).toList();
      if (safeCoords.length >= 2) {
        _routeAnnot!.geometry = mapbox.LineString(coordinates: safeCoords);
        updating = true;
        polyMgr.update(_routeAnnot!).then((_) => updating = false).catchError((_) => updating = false);
      }

      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullSafe = safeLineString(points);
        if (fullSafe != null) {
          _routeAnnot?.geometry = fullSafe;
          if (_routeAnnot != null) polyMgr.update(_routeAnnot!);
        }
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }



  // ── Hanging instruction card ────────────────────────────────────────────
  Widget _buildHangingInstruction(String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Gold connector line
        Padding(
          padding: const EdgeInsets.only(left: 20),
          child: Column(
            children: [
              Container(
                width: 1.5,
                height: 28,
                color: _gold.withValues(alpha: 0.40),
              ),
              Icon(Icons.sticky_note_2_outlined,
                  size: 16, color: _gold.withValues(alpha: 0.70)),
            ],
          ),
        ),
        const SizedBox(width: 10),
        // Instruction card
        Expanded(
          child: Container(
            margin: const EdgeInsets.only(top: 4),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF1A1F35),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: _gold.withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            child: Text(
              text,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.82),
                fontSize: 13,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }

  void _returnToDriverHome() {
    if (!mounted) return;
    HapticService.lightImpact();
    // Pop with 'back_to_home' so the parent (DriverOnlineController) knows
    // the driver pressed back — NOT that the trip was cancelled.  The trip
    // stays active in Firestore/backend and the driver home screen will
    // show a Resume button.
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop('back_to_home');
    } else {
      // Fallback: if we're the root (shouldn't happen), push a fresh home
      Navigator.of(context).pushAndRemoveUntil(
        fadeThroughRoute(const DriverHomeScreen(returnFromTrip: true)),
        (route) => false,
      );
    }
  }

  // ── BUILD ─────────────────────────────────────────────────────────────────
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bot = MediaQuery.of(context).padding.bottom;

    SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
      statusBarIconBrightness:  Brightness.light,
    ));

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        // Inside navigation, back leaves NAVIGATION — not the trip.
        if (_navMode) {
          _exitNavMode();
          return;
        }
        _returnToDriverHome();
      },
      child: Scaffold(
      backgroundColor: _bg,
      body: Stack(
        children: [
          // Same fine dot grid as the rider's home (user spec 2026-08-04).
          const Positioned.fill(child: NeuDotsBackdrop()),
          SlideTransition(
        position: _slideAnim,
        child: FadeTransition(
          opacity: _fadeAnim,
          child: Column(
          children: [
            // ── Header ────────────────────────────────────────────────────
            Container(
              // Transparent so the page's dot backdrop shows through.
              color: Colors.transparent,
              padding: EdgeInsets.fromLTRB(Responsive.w(16), top + 10, Responsive.w(16), Responsive.h(14)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Top row: back / help icons
                  Row(
                    children: [
                      // Was a plain back arrow that dropped the driver
                      // straight out of the trip. Now it opens the driver
                      // menu, with going back as one option among several.
                      _headerIconBtn(
                        Icons.menu_rounded,
                        _showDriverMenu,
                        color: Colors.white,
                        size: 22,
                      ),
                      const Spacer(),
                      // One button, not two. A shield and a headset side by
                      // side asked the driver to classify their own problem
                      // before they could report it; both now open the same
                      // panel, with 911 at the top and Cancel Trip at the
                      // bottom. See _showSafetySupportMenu.
                      _headerIconBtn(
                          Icons.shield_rounded, _showSafetySupportMenu),
                    ],
                  ),
                  SizedBox(height: Responsive.h(16)),
                  // Title
                  Text(S.of(context).rideForName(nh.displayName(widget.riderName, widget.vehicleType)),
                    style: TextStyle(
                      color: Colors.white, fontSize: Responsive.sp(24),
                      fontWeight: FontWeight.w800, height: 1.15)),
                  const SizedBox(height: 3),
                  Text(_timeLabel(),
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.42),
                      fontSize: Responsive.sp(13), fontWeight: FontWeight.w400)),
                  SizedBox(height: Responsive.h(16)),
                  // Rider row: avatar + info + call/msg
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _avatar(),
                      SizedBox(width: Responsive.w(12)),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(nh.displayName(widget.riderName, widget.vehicleType),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: Colors.white, fontSize: Responsive.sp(15),
                                fontWeight: FontWeight.w700)),
                            // Reputation, directly under the name. This block
                            // has always been here — it never rendered
                            // because the offers payload did not carry
                            // rider_rating or rider_is_new, so both arrived
                            // at their 0/false defaults and every passenger
                            // showed as a bare name. Backend sends them now.
                            if (widget.riderIsNew || widget.riderRating > 0)
                              const SizedBox(height: 4),
                            if (widget.riderIsNew)
                              // Sunken pill, so "first ride" reads as a
                              // standing fact about the passenger and not as
                              // a warning.
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 3),
                                decoration: neuBox(radius: 8, pressed: true),
                                child: Text(S.of(context).newRiderLabel,
                                  style: TextStyle(
                                    color: _gold,
                                    fontSize: Responsive.sp(10.5),
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.2,
                                  )),
                              )
                            else if (widget.riderRating > 0)
                              // One line, not stars-then-a-caption: two
                              // stacked lines under the name pushed this
                              // column taller than the call and message
                              // buttons beside it.
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _stars(widget.riderRating),
                                  SizedBox(width: Responsive.w(6)),
                                  Text(widget.riderRating.toStringAsFixed(1),
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.55),
                                      fontSize: Responsive.sp(11),
                                      fontWeight: FontWeight.w600)),
                                ],
                              ),
                          ],
                        ),
                      ),
                      SizedBox(width: Responsive.w(10)),
                      // Chat / Call / Support ride at the right end of the
                      // rider row (user spec 2026-09-15): compact discs with
                      // no labels so profile and actions share one line. The
                      // call disc is the only gold-filled one, and the unread
                      // count rides the chat disc.
                      _tripActionBtn(
                        icon: Icons.chat_bubble_rounded,
                        label: S.of(context).chat,
                        onTap: _openChat,
                        badge: ChatService().unreadCountStream(
                          rideId: widget.tripId.toString(),
                          readerRole: 'driver',
                        ),
                        d: 44,
                        showLabel: false,
                      ),
                      SizedBox(width: Responsive.w(10)),
                      _tripActionBtn(
                        icon: Icons.call_rounded,
                        label: S.of(context).callAction,
                        onTap: _call,
                        filled: true,
                        d: 44,
                        showLabel: false,
                      ),
                      SizedBox(width: Responsive.w(10)),
                      _tripActionBtn(
                        icon: Icons.support_agent_rounded,
                        label: S.of(context).supportAction,
                        onTap: _openSupportChat,
                        d: 44,
                        showLabel: false,
                      ),
                    ],
                  ),
                  if (_complimentaryDrink != null) ...[
                    SizedBox(height: Responsive.h(14)),
                    _complimentaryDrinkCard(),
                  ],
                ],
              ),
            ),

            // ── Map preview (tilt animation on enter) ─────────────────
            // Loose so a short screen shrinks the map instead of overflowing
            // the Column; tall screens still get the full 300.
            Flexible(
              fit: FlexFit.loose,
              child: Padding(
              padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), Responsive.h(12)),
              child: ClipRRect(
                // Frameless (user spec 2026-09-13): the map no longer sits in
                // the shared raised card — its edges dissolve into the page
                // via _buildMapEdgeFade below, like the rider's Find-My mini
                // map. The ClipRRect keeps the rounded-18 corners.
                borderRadius: BorderRadius.circular(18),
                  child: SizedBox(
                    key: _miniMapBoxKey,
                    // Bigger again (190 → 240 → 300): more of the trip in
                    // view (user spec 2026-09-16).
                    height: Responsive.h(300),
                    width: double.infinity,
                    // expand: every child fills the card edge to edge —
                    // the map can never letterbox inside its box (user
                    // report 2026-08-05: "no puede dejar marcos").
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        // The live preview is back. It takes the app's one
                        // native Mapbox surface — but it asks for it first
                        // (see _acquireMapSurface), so the online screen
                        // underneath lets go cleanly instead of being
                        // destroyed underneath us, and takes it back when
                        // this screen is disposed. Until the handoff
                        // completes, the StaticRoutePreview image stands in:
                        // it draws the same route and pins and cannot hold a
                        // surface.
                        if (!_previewMapMounted)
                          StaticRoutePreview(
                            pickupLat: widget.pickupLatLng.latitude,
                            pickupLng: widget.pickupLatLng.longitude,
                            dropoffLat: _dropoffLL.latitude,
                            dropoffLng: _dropoffLL.longitude,
                            route: _routePoints,
                          )
                        // Mapbox GL JS in the browser, the native SDK
                        // everywhere else — same pattern as the online and
                        // scheduled-ride screens.
                        else if (kIsWeb)
                          IgnorePointer(
                            // Web stays a read-only stand-in; the native
                            // preview is the interactive one (pan + zoom in
                            // _onMapReady).
                            child: WebMapView(
                              key: const ValueKey('trip_accept_preview_web'),
                              initialLng: widget.pickupLatLng.longitude,
                              initialLat: widget.pickupLatLng.latitude,
                              initialZoom: 12,
                              styleUri: MapboxConfig.styleDark,
                              onControllerCreated: _setupWebPreview,
                            ),
                          )
                        else
                          RepaintBoundary(
                            child: mapbox.MapWidget(
                              styleUri: MapboxConfig.styleDark,
                              cameraOptions: mapbox.CameraOptions(
                                center: mapbox.Point(coordinates: mapbox.Position(
                                  widget.pickupLatLng.longitude,
                                  widget.pickupLatLng.latitude,
                                )),
                                zoom: 12.0,
                                pitch: 0.0,
                                bearing: 0.0,
                              ),
                              onMapCreated: _onMapReady,
                              onStyleLoadedListener: _onStyleLoaded,
                            ),
                          ),
                        // Edges dissolve into the page background (user spec
                        // 2026-09-13) — the frame is this fade, not a card.
                        // Above the map, below the chips.
                        Positioned.fill(
                          child: IgnorePointer(child: _buildMapEdgeFade()),
                        ),
                        // The 3D fade vignettes that darkened the top and
                        // bottom edges are gone (user spec 2026-08-05):
                        // they sold the old tilted look, but on a flat
                        // top-down map they read as dark FRAMES over the
                        // box the map is supposed to fill completely.
                        // Trip time, with the distance to pickup stacked
                        // underneath it.
                        //
                        // The two used to sit in opposite corners, so the
                        // driver read one number top-left and the other
                        // top-right with a whole map between them. Stacked in
                        // one corner they read as what they are: two figures
                        // about the same trip.
                        Positioned(
                          top: 10, right: 10,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.end,
                            children: [
                              _mapChip(Text(
                                '$_tripEta min trip',
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                ),
                              )),
                              // Live, from the driver's own GPS. Only while
                              // heading there; once the rider is aboard the
                              // pickup is behind them.
                              if (!_rideStarted) ...[
                                const SizedBox(height: 6),
                                _mapChip(Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    Icon(Icons.near_me_rounded,
                                        color: _gold, size: 12),
                                    const SizedBox(width: 5),
                                    Text(
                                      _pickupDistanceLabel,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                      ),
                                    ),
                                  ],
                                )),
                              ],
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
              ),
            ),
            ),

            // ── Passenger instructions, straight under the map ────────────
            //
            // Was a small untitled note hanging off the bottom of the pickup
            // card, below the fold on a short phone. What the passenger asked
            // for belongs where the driver is already looking.
            if (_passengerInstructions.isNotEmpty) ...[
              Padding(
                padding: EdgeInsets.fromLTRB(
                    Responsive.w(16), 0, Responsive.w(16), Responsive.h(12)),
                child: _passengerInstructionsCard(_passengerInstructions),
              ),
            ],

            // ── Pickup address card ───────────────────────────────────────
            Padding(
              padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), 0),
              child: GestureDetector(
                // On iPhone this goes straight to Apple Maps — one tap,
                // no picker sheet in between while the driver is moving.
                // Android still gets the chooser, since there is no single
                // obvious default there.
                onTap: () => AppPlatform.isIOS
                    ? _openAppleMaps(widget.pickupLatLng)
                    : _showNavigationSheet(isPickup: true),
                onLongPress: () => _copyAddress(S.of(context).pickupAddressLabel, _pickupAddr),
                child: _infoRow(
                  // Map pin for the pickup, flag pin for the dropoff —
                  // the same icon pair the rider's map labels carry
                  // (user spec 2026-08-05: pins, not a ring/square).
                  Icons.place_rounded,
                  _gold,
                  S.of(context).pickupLabel,
                  _resolvingAddresses && _pickupAddr.isEmpty
                      ? S.of(context).fetchingAddress
                      : _pickupAddr,
                  showChevron: true,
                ),
              ),
            ),
            // ── Pickup PIN card — waiting-for-rider stage only ──────────
            // Slides in exactly while _buildSlideWaitingForRider() is the
            // active phase widget: a correct code flips _riderConfirmedPickup
            // locally and the pill below morphs into Start Ride.
            AnimatedSize(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeInOutCubicEmphasized,
              alignment: Alignment.topCenter,
              child: _showPickupPinCard
                  ? Padding(
                      padding: EdgeInsets.fromLTRB(Responsive.w(16),
                          Responsive.h(10), Responsive.w(16), 0),
                      child: _buildPickupPinCard(),
                    )
                  : const SizedBox.shrink(),
            ),
            // ── Stop card (rider added mid-trip) — slides in animated ──
            AnimatedSize(
              duration: const Duration(milliseconds: 420),
              curve: Curves.easeInOutCubicEmphasized,
              alignment: Alignment.topCenter,
              child: _stopLatLng == null
                  ? const SizedBox.shrink()
                  : Padding(
                      padding: EdgeInsets.fromLTRB(Responsive.w(16), 0,
                          Responsive.w(16), Responsive.h(10)),
                      child: _infoRow(
                        Icons.add_location_alt_rounded,
                        _gold,
                        S.of(context).stopLabelShort,
                        _stopLabel.isEmpty ? '—' : _stopLabel,
                        iconSize: 16,
                      ),
                    ),
            ),

            // ── Dropoff address card + hanging instructions ───────────────
            // Hidden until the rider is aboard. On the way to pickup the
            // only address that matters is the pickup, and showing both
            // invites navigating to the wrong one.
            if (_rideStarted) ...[
              const SizedBox(height: 8),
              Padding(
                padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), 0),
                child: GestureDetector(
                  onTap: () => AppPlatform.isIOS
                      ? _openAppleMaps(_dropoffLL)
                      : _showNavigationSheet(isPickup: false),
                  onLongPress: () => _copyAddress(S.of(context).dropoffAddressLabel, _dropoffAddr),
                  child: _infoRow(
                    Icons.flag_rounded,
                    _gold,
                    S.of(context).dropOffLabel,
                    _resolvingAddresses && _dropoffAddr.isEmpty
                        ? S.of(context).fetchingAddress
                        : _dropoffAddr,
                    showChevron: true,
                    iconSize: 14,
                  ),
                ),
              ),
              if (widget.dropoffInstructions.isNotEmpty)
                Padding(
                  padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), 0),
                  child: _buildHangingInstruction(widget.dropoffInstructions),
                ),
            ],
            const SizedBox(height: 10),

            // The "new message from rider" box is gone (user spec
            // 2026-08-05) — the badge on the message disc already
            // carries the unread count.

            const Spacer(),

            // ── Bottom buttons: 6 phases ─────────────────────────────────
            // Phase 1: Slide "Start Trip" (driving to pickup)
            // Phase 2: Continue/Directions (pickup nav)
            // Phase 3: Slide "Arrived" (near pickup, GPS detected)
            // Phase 4: Slide "Start Trip" #2 (confirmed arrival → go to dropoff)
            // Phase 5: Continue/Directions (dropoff nav)
            // Phase 6: Slide "Finalizar Viaje" (near dropoff, GPS detected)
            if (!_tripFinished)
            Padding(
              padding: EdgeInsets.fromLTRB(Responsive.w(16), 0, Responsive.w(16), bot + 18),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // "Passenger confirmed they are in your vehicle" — right
                  // above the action button, gone by itself after 5 s
                  // (user spec 2026-08-05).
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 450),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    child: _confirmBannerShow
                        ? Padding(
                            key: const ValueKey('confirm-banner'),
                            padding: const EdgeInsets.only(bottom: 12),
                            child: Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(Icons.check_circle_rounded,
                                    color: _gold, size: 18),
                                const SizedBox(width: 8),
                                Flexible(
                                  child: Text(
                                    S.of(context).passengerConfirmedOnboard,
                                    style: TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                      color: _gold,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          )
                        : const SizedBox.shrink(
                            key: ValueKey('confirm-banner-off')),
                  ),
                  AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    switchInCurve: Curves.easeOut,
                    switchOutCurve: Curves.easeIn,
                    child: AnimatedSwitcher(
                      // The stage swap is felt, not snapped — whether the
                      // driver slid it or dispatch advanced it remotely.
                      duration: const Duration(milliseconds: 420),
                      switchInCurve: Curves.easeOutCubic,
                      switchOutCurve: Curves.easeInCubic,
                      transitionBuilder: (child, anim) => FadeTransition(
                        opacity: anim,
                        child: ScaleTransition(
                          scale: Tween<double>(begin: 0.96, end: 1.0)
                              .animate(anim),
                          child: child,
                        ),
                      ),
                      child: KeyedSubtree(
                        key: ValueKey(_actionStageKey()),
                        child: _buildCurrentPhaseWidget(),
                      ),
                    ),
                  ),
                  // Cancel trip moved into the support sheet — see
                  // _showSafetySupportMenu. It used to sit right under the slider,
                  // one mis-tap from ending a live trip.
                ],
              ),
            ),
          ],
        ),
      ),
      ),

      // ── In-app turn-by-turn navigation (Continue / Directions) ────────
      // Full-screen; owns the one native map surface while it is up (the
      // preview let go of it in _enterNavMode). The chained-offer card and
      // the finish overlay sit ABOVE it in this Stack, so they keep working
      // over navigation untouched. The morph overlay covers the surface
      // swap — the live map itself is never resized or moved mid-flight.
      if (_navMode)
        Positioned.fill(
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0.0, end: 1.0),
            duration: const Duration(milliseconds: 250),
            builder: (ctx, t, child) => Opacity(opacity: t, child: child),
            child: DriverNavView(
              key: _navViewKey,
              tripId: widget.tripId,
              riderName: widget.riderName,
              riderPhotoUrl: _riderPhotoUrl ?? widget.riderPhotoUrl,
              riderId: widget.riderId,
              pickupLatLng: widget.pickupLatLng,
              dropoffLatLng: _dropoffLL,
              pickupAddress: _pickupAddr.isEmpty
                  ? widget.pickupAddress
                  : _pickupAddr,
              dropoffAddress: _dropoffAddr.isEmpty
                  ? widget.dropoffAddress
                  : _dropoffAddr,
              fare: widget.fare,
              initialDriverPos: _lastDriverPos ?? widget.driverPos,
              toPickup: !_rideStarted,
              stage: _actionStageKey(),
              passengerInstructions: _passengerInstructions,
              dropoffInstructions: widget.dropoffInstructions,
              waitStartedAt: _waitStartedAt,
              prefetchedRoutePoints: _routePoints,
              onExit: _exitNavMode,
              onArrived: _confirmArrival,
              onSlidePickUp: _startRideConfirmed,
              onSlideFinish: _finishTrip,
              onOpenChat: _openChat,
              onCall: _call,
              onSupport: _openSupportChat,
              onMapReady: _onNavMapReady,
            ),
          ),
        ),

      // ── Mini-map ⇄ navigation morph ─────────────────────────────────
      // One-shot snapshot of the departing map, blooming out of / collapsing
      // into the preview card. Sits above the nav view (it covers the
      // surface swap) but below the chained-offer card and the finish
      // overlay, which keep working over it untouched.
      if (_morphEnter || _morphExit)
        Positioned.fill(
          child: NavMorphOverlay(
            key: ValueKey(_morphExit ? 'exit' : 'enter'),
            direction:
                _morphExit ? NavMorphDirection.exit : NavMorphDirection.enter,
            imageBytes: _morphBytes!,
            sourceRect: _morphRect!,
            backgroundColor: _bg,
            revealRequested: _morphReveal,
            onFinished:
                _morphExit ? _onExitMorphFinished : _onEnterMorphFinished,
          ),
        ),

      // ── Chained (next-ride) offer over the live trip ─────────────────
      // Floating card, hidden once the completion overlay owns the screen.
      // It never touches the map, the camera or the route — the trip being
      // driven keeps all three.
      if (_chainedOffer != null && !_tripFinished)
        Positioned(
          top: top + 8,
          left: 12,
          right: 12,
          child: _buildChainedOfferCard(_chainedOffer!),
        ),

      // ── Phase 4: "Viaje Finalizado" full-screen overlay ───────────────
      if (_tripFinished)
        Positioned.fill(
          child: FadeTransition(
          opacity: _finishFadeAnim,
          child: BackdropFilter(
            filter: ui.ImageFilter.blur(sigmaX: 28, sigmaY: 28),
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.black.withValues(alpha: 0.82),
                    Colors.black.withValues(alpha: 0.90),
                    Colors.black.withValues(alpha: 0.85),
                  ],
                  stops: const [0.0, 0.5, 1.0],
                ),
              ),
              child: SafeArea(
                child: Column(
                  children: [
                    const Spacer(flex: 3),
                    // ── Glowing check icon ──
                    Container(
                      width: 110, height: 110,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        gradient: RadialGradient(
                          colors: [
                            _gold.withValues(alpha: 0.30),
                            _gold.withValues(alpha: 0.08),
                            Colors.transparent,
                          ],
                          stops: const [0.0, 0.6, 1.0],
                          radius: 1.4,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.35),
                            blurRadius: 50,
                            spreadRadius: 12,
                          ),
                        ],
                      ),
                      child: Container(
                        margin: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: _gold.withValues(alpha: 0.12),
                          border: Border.all(color: _gold, width: 2.5),
                        ),
                        child: const Icon(Icons.check_rounded,
                            color: _gold, size: 52),
                      ),
                    ),
                    const SizedBox(height: 32),
                    // ── Title ──
                    Text(S.of(context).tripCompleted,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 32,
                        fontWeight: FontWeight.w900,
                        letterSpacing: -0.5,
                      ),
                    ),
                    const SizedBox(height: 20),
                    // ── Fare pill ──
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 12),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(30),
                        border: Border.all(color: _gold.withValues(alpha: 0.40), width: 1.5),
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.15),
                            blurRadius: 24,
                            spreadRadius: 2,
                          ),
                        ],
                      ),
                      child: Text('\$${widget.fare.toStringAsFixed(2)}',
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 32,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2,
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    // ── Rider name ──
                    Text(widget.riderName,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.50),
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(flex: 4),
                  ],
                ),
              ),
            ),
          ),
        ),
        ),
      ],
      ),
    ));
  }

  /// One key per stage so the AnimatedSwitcher cross-fades exactly when
  /// the stage really changes.
  String _actionStageKey() {
    if (_rideStarted && _nearDropoff) return 'finish';
    if (_rideStarted) return 'finish_locked';
    if (_arrivedConfirmed) {
      return _riderConfirmedPickup ? 'start_ride' : 'waiting_rider';
    }
    if (_tripStarted && _nearPickup) return 'arrived';
    if (_tripStarted) return 'arrived_locked';
    return 'start_trip';
  }

  // ── Phase router: returns the correct widget for the current state ────
  Widget _buildCurrentPhaseWidget() {
    // Phase 6: Near dropoff → Finalizar Viaje
    if (_rideStarted && _nearDropoff) {
      return _buildSlideFinishTrip();
    }
    // Phase 5: Ride started, not near dropoff → Finalizar bloqueado
    if (_rideStarted && !_nearDropoff) {
      return _buildSlideFinishTripLocked();
    }
    // Phase 4: Arrived confirmed, ride not started. Until the rider's
    // pickup code is entered (the only unlock — user spec 2026-09-16),
    // the button reads "Waiting for your rider" and cannot be pressed.
    if (_arrivedConfirmed && !_rideStarted) {
      return _riderConfirmedPickup
          ? _buildSlideStartRide()
          : _buildSlideWaitingForRider();
    }
    // Phase 3: Near pickup, not confirmed → Arrived slider
    if (_tripStarted && _nearPickup && !_arrivedConfirmed) {
      return _buildSlideArrived();
    }
    // Phase 2: Trip started, not near pickup → Arrived bloqueado
    if (_tripStarted && !_nearPickup && !_arrivedConfirmed) {
      return _buildSlideArrivedLocked();
    }
    // Phase 1: Slide Start Trip
    return _buildSlideStartTrip();
  }

  /// Shimmer sweep overlay for slide buttons — a gold-light that moves
  /// left→right hinting the user to slide.
  Widget _buildShimmerOverlay(double height) {
    return AnimatedBuilder(
      animation: _shimmerAnim,
      builder: (context, _) {
        return Positioned.fill(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(height / 2),
            child: IgnorePointer(
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment(_shimmerAnim.value - 1.0, 0),
                    end: Alignment(_shimmerAnim.value, 0),
                    colors: [
                      Colors.transparent,
                      _gold.withValues(alpha: 0.18),
                      Colors.transparent,
                    ],
                    stops: const [0.0, 0.5, 1.0],
                  ),
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  /// The preview map's edges dissolving into the page background (user spec
  /// 2026-09-13): two multi-stop linear fades (vertical + horizontal) plus a
  /// radial vignette for the corners, all in the page's _bg color — the same
  /// treatment as the rider's Find-My mini map.
  Widget _buildMapEdgeFade() {
    // A soft rim hugging the border only (user spec 2026-09-16): the fade
    // must read as the edges dissolving into the page, never as a blur
    // reaching inward — fully transparent by ~5% from every side.
    LinearGradient edge(Alignment begin, Alignment end) => LinearGradient(
          begin: begin,
          end: end,
          colors: [
            _bg,
            _bg.withValues(alpha: .55),
            _bg.withValues(alpha: .18),
            Colors.transparent,
            Colors.transparent,
            _bg.withValues(alpha: .18),
            _bg.withValues(alpha: .55),
            _bg,
          ],
          stops: const [0, .01, .028, .05, .95, .972, .99, 1],
        );
    return Stack(
      fit: StackFit.expand,
      children: [
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: edge(Alignment.topCenter, Alignment.bottomCenter),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            gradient: edge(Alignment.centerLeft, Alignment.centerRight),
          ),
        ),
        DecoratedBox(
          decoration: BoxDecoration(
            // Corner caps only: the radius lands the opaque stop right at
            // the rounded corners, so the rim never creeps in diagonally.
            gradient: RadialGradient(
              center: Alignment.center,
              radius: 0.8,
              colors: [
                Colors.transparent,
                Colors.transparent,
                _bg.withValues(alpha: .18),
                _bg,
              ],
              stops: const [0, .85, .95, 1],
            ),
          ),
        ),
      ],
    );
  }

  // ── Tap "Start Trip" button ──────────────────────────────────────────────
  Widget _buildSlideStartTrip() {
    return SizedBox(
      key: const ValueKey('tap_start_trip'),
      width: double.infinity,
      height: 62,
      child: ElevatedButton(
        onPressed: _slid ? null : () {
          setState(() => _slid = true);
          HapticService.heavyImpact();
          // Navigate immediately — don't wait for route animation
          Future.delayed(const Duration(milliseconds: 400), () {
            if (!mounted) return;
            setState(() => _tripStarted = true);
            _openNativeMaps(widget.pickupLatLng);
          });
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: _gold,
          foregroundColor: Colors.black,
          disabledBackgroundColor: _gold.withValues(alpha: 0.6),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(31),
          ),
          elevation: 0,
        ),
        child: Text(
          _slid ? S.of(context).startingLabel : S.of(context).startTripLabel,
          style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
        ),
      ),
    );
  }

  // ── Continue / Directions buttons (shown after slide) ───────────────────
  Widget _buildContinueDirections() {
    return Column(
      key: const ValueKey('continue_directions_pickup'),
      mainAxisSize: MainAxisSize.min,
      children: [
        // Continue button — gold filled
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: _enterNavMode,
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              elevation: 0,
            ),
            child: Text(S.of(context).continueBtn,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 12),
        // Directions button — outlined
        SizedBox(
          width: double.infinity,
          height: 56,
          child: OutlinedButton(
            onPressed: _enterNavMode,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              foregroundColor: Colors.white,
            ),
            child: Text(S.of(context).directions,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }

  // ── Slide-to-confirm "Arrived" (at pickup) ──────────────────────────────
  Widget _buildSlideArrived() {
    const height = 62.0;
    const thumbW = 62.0;
    return Container(
      key: const ValueKey('slide_arrived'),
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final trackW = constraints.maxWidth;
          final maxDrag = trackW - thumbW - 4;
          return SizedBox(
            height: height,
            child: Stack(
              children: [
                // Fill
                Positioned(
                  left: 0, top: 0, bottom: 0,
                  width: (_arrivedSlideVal * maxDrag + thumbW).clamp(thumbW.toDouble(), trackW),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.45),
                          _gold.withValues(alpha: 0.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                ),
                // Shimmer sweep hint
                _buildShimmerOverlay(height),
                // Label
                Center(
                  child: AnimatedOpacity(
                    opacity: 1.0 - _arrivedSlideVal,
                    duration: const Duration(milliseconds: 100),
                    child: Text(S.of(context).arrived,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
                // Thumb
                Positioned(
                  left: 2 + _arrivedSlideVal * maxDrag,
                  top: 3, bottom: 3,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) {
                      if (_arrivedSlidDone) return;
                      setState(() {
                        _arrivedSlideVal = (_arrivedSlideVal + d.delta.dx / maxDrag)
                            .clamp(0.0, 1.0);
                      });
                      if (_arrivedSlideVal >= 0.88) {
                        setState(() => _arrivedSlidDone = true);
                        HapticService.heavyImpact();
                        _confirmArrival();
                      }
                    },
                    onHorizontalDragEnd: (_) {
                      if (!_arrivedSlidDone) setState(() => _arrivedSlideVal = 0);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: thumbW - 4,
                      decoration: BoxDecoration(
                        color: _arrivedSlidDone ? _gold.withValues(alpha: 0.8) : _gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Icon(
                        _arrivedSlidDone ? Icons.check_rounded : Icons.chevron_right_rounded,
                        color: Colors.black,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSlideArrivedLocked() {
    return Column(
      key: const ValueKey('slide_arrived_locked'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _LockedSlideButton(label: S.of(context).arrived),
        const SizedBox(height: 10),
        Text(
          S.of(context).arrivedButtonTooltip,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  // ── Tap "Start Ride" button (pickup confirmed → go to dropoff) ─────────
  //
  /// The pickup-confirmation flow behind the on-sheet Start Ride button.
  void _startRideConfirmed() {
    Future.delayed(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      setState(() => _rideStarted = true);
      _onRideStartedMiniMap();
      _startDropoffProximityDetection();
      // Dropoff navigation opens only once the backend confirms in_trip —
      // navigation state never fakes trip state.
      final ok = await _updateTripInTrip();
      if (!mounted) return;
      // In nav mode the nav view re-aims itself at the dropoff (its
      // toPickup param flips with _rideStarted). From the sheet, Start Trip
      // runs the same mini-map morph entry as Continue / Directions.
      if (_navMode) return;
      if (ok) {
        _enterNavMode();
      } else {
        // No fake success: the sheet stays put and the driver retries with
        // Continue / Directions once the connection is back.
        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
          SnackBar(
            content: Text(S.of(context).connectionError),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    });
  }

  // Hand-built instead of an ElevatedButton so the press is felt: the button
  // sinks and its glow collapses under the thumb, then springs back. Material's
  // default is an ink ripple, which on a solid gold pill on a dark screen is
  // almost invisible — the driver got haptics and nothing to look at.
  Widget _buildSlideStartRide() {
    final done = _startRideSlidDone;
    final pressed = _startRidePressed && !done;
    // The 1.6 s breathing pulse that says "the rider is here — go".
    // _shimmerAnim already loops for the slide buttons, so it drives
    // this too: no extra ticker.
    return AnimatedBuilder(
      animation: _shimmerAnim,
      builder: (context, child) {
        final eligible = !done && _riderConfirmedPickup;
        final w = (math.sin(_shimmerAnim.value * math.pi * 2) + 1) / 2;
        final sc = eligible ? 1.0 + 0.018 * w : 1.0;
        return Transform.scale(scale: sc, child: child);
      },
      child: GestureDetector(
      key: const ValueKey('tap_start_ride'),
      behavior: HitTestBehavior.opaque,
      onTapDown: done ? null : (_) => setState(() => _startRidePressed = true),
      onTapCancel: () {
        if (_startRidePressed) setState(() => _startRidePressed = false);
      },
      onTapUp: done ? null : (_) {
        setState(() {
          _startRidePressed = false;
          _startRideSlidDone = true;
        });
        HapticService.heavyImpact();
        _startRideConfirmed();
      },
      child: AnimatedScale(
        scale: pressed ? 0.96 : 1.0,
        duration: Duration(milliseconds: pressed ? 90 : 260),
        // Overshoot on release only. Easing both ways makes the spring back
        // feel like the button is catching up rather than pushing off.
        curve: pressed ? Curves.easeOut : Curves.elasticOut,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          height: 62,
          width: double.infinity,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done ? _gold.withValues(alpha: 0.6) : _gold,
            borderRadius: BorderRadius.circular(31),
            boxShadow: pressed
                ? const []
                : [
                    BoxShadow(
                      color: _gold.withValues(alpha: 0.28),
                      blurRadius: 22,
                      spreadRadius: -4,
                      offset: const Offset(0, 8),
                    ),
                  ],
          ),
          child: Text(
            done ? S.of(context).startingLabel : S.of(context).startRideLabel,
            style: const TextStyle(
              color: Colors.black,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    ),
    );
  }

  // ── Slide-to-confirm "Finalizar Viaje" (near dropoff) ───────────────────
  Widget _buildSlideFinishTrip() {
    const height = 62.0;
    const thumbW = 62.0;
    return Container(
      key: const ValueKey('slide_finish_trip'),
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: _gold.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          final trackW = constraints.maxWidth;
          final maxDrag = trackW - thumbW - 4;
          return SizedBox(
            height: height,
            child: Stack(
              children: [
                // Fill
                Positioned(
                  left: 0, top: 0, bottom: 0,
                  width: (_finishSlideVal * maxDrag + thumbW).clamp(thumbW.toDouble(), trackW),
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.45),
                          _gold.withValues(alpha: 0.10),
                        ],
                      ),
                      borderRadius: BorderRadius.circular(height / 2),
                    ),
                  ),
                ),
                // Shimmer sweep hint
                _buildShimmerOverlay(height),
                // Label
                Center(
                  child: AnimatedOpacity(
                    opacity: 1.0 - _finishSlideVal,
                    duration: const Duration(milliseconds: 100),
                    child: Text(S.of(context).finishRide,
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 16, fontWeight: FontWeight.w700)),
                  ),
                ),
                // Thumb
                Positioned(
                  left: 2 + _finishSlideVal * maxDrag,
                  top: 3, bottom: 3,
                  child: GestureDetector(
                    onHorizontalDragUpdate: (d) {
                      if (_finishSlidDone) return;
                      setState(() {
                        _finishSlideVal = (_finishSlideVal + d.delta.dx / maxDrag)
                            .clamp(0.0, 1.0);
                      });
                      if (_finishSlideVal >= 0.88) {
                        setState(() => _finishSlidDone = true);
                        _finishTrip();
                      }
                    },
                    onHorizontalDragEnd: (_) {
                      if (!_finishSlidDone) setState(() => _finishSlideVal = 0);
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 80),
                      width: thumbW - 4,
                      decoration: BoxDecoration(
                        color: _finishSlidDone ? _gold.withValues(alpha: 0.8) : _gold,
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color: _gold.withValues(alpha: 0.5),
                            blurRadius: 12,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: Icon(
                        _finishSlidDone ? Icons.check_rounded : Icons.chevron_right_rounded,
                        color: Colors.black,
                        size: 28,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildSlideFinishTripLocked() {
    return Column(
      key: const ValueKey('slide_finish_trip_locked'),
      mainAxisSize: MainAxisSize.min,
      children: [
        _LockedSlideButton(label: S.of(context).finishRide),
        const SizedBox(height: 10),
        Text(
          S.of(context).finishButtonTooltip,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white54,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ],
    );
  }

  // ── Continue / Directions for DROPOFF (after ride started) ──────────────
  Widget _buildContinueDirectionsDropoff() {
    return Column(
      key: const ValueKey('continue_directions_dropoff'),
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: double.infinity,
          height: 56,
          child: ElevatedButton(
            onPressed: _enterNavMode,
            style: ElevatedButton.styleFrom(
              backgroundColor: _gold,
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              elevation: 0,
            ),
            child: Text(S.of(context).continueBtn,
              style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          height: 56,
          child: OutlinedButton(
            onPressed: _enterNavMode,
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: Colors.white24, width: 1.5),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(28),
              ),
              foregroundColor: Colors.white,
            ),
            child: Text(S.of(context).directions,
              style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800)),
          ),
        ),
      ],
    );
  }
}

// ─── Bottom-sheet item data class ─────────────────────────────────────────────
class _SheetItem {
  final IconData   icon;
  final String     label;
  final String     sub;
  final VoidCallback onTap;
  /// Destructive action — rendered in red so Cancel Trip does not read
  /// like the neutral options it now sits beside.
  final bool danger;
  const _SheetItem(this.icon, this.label, this.sub, this.onTap,
      {this.danger = false});
}

class _LockedSlideButton extends StatelessWidget {
  const _LockedSlideButton({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    const gold = Color(0xFFD4A843);
    const height = 62.0;
    const thumbW = 62.0;

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF111318),
        borderRadius: BorderRadius.circular(height / 2),
        border: Border.all(color: gold.withValues(alpha: 0.25)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: SizedBox(
        height: height,
        child: Stack(
          children: [
            Positioned(
              left: 0,
              top: 0,
              bottom: 0,
              width: thumbW,
              child: Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      gold.withValues(alpha: 0.45),
                      gold.withValues(alpha: 0.10),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(height / 2),
                ),
              ),
            ),
            Center(
              child: Text(
                label,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            Positioned(
              left: 2,
              top: 3,
              bottom: 3,
              child: Container(
                width: thumbW - 4,
                decoration: BoxDecoration(
                  color: gold.withValues(alpha: 0.75),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: gold.withValues(alpha: 0.35),
                      blurRadius: 10,
                      offset: const Offset(0, 3),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.lock_rounded,
                  color: Colors.black,
                  size: 24,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ═══════════════════════════════════════════════════════════════════
//  Fase 2 — address search sheet for the driver's route-change proposal.
//  Pops the picked PlaceDetails; the caller writes the Firestore
//  proposal. Same dark/gold idiom as every other sheet on this screen.
// ═══════════════════════════════════════════════════════════════════
class _ProposeSearchSheet extends StatefulWidget {
  final bool isStop;
  final LatLng near;
  const _ProposeSearchSheet({required this.isStop, required this.near});

  @override
  State<_ProposeSearchSheet> createState() => _ProposeSearchSheetState();
}

class _ProposeSearchSheetState extends State<_ProposeSearchSheet> {
  final TextEditingController _ctrl = TextEditingController();
  Timer? _debounce;
  List<PlaceSuggestion> _suggestions = [];
  bool _searching = false;
  bool _resolving = false;

  @override
  void dispose() {
    _debounce?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _onChanged(String q) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 420), () async {
      if (!mounted || q.trim().length < 3) return;
      setState(() => _searching = true);
      try {
        final res = await PlacesService(ApiKeys.webServices).autocomplete(
          q,
          latitude: widget.near.latitude,
          longitude: widget.near.longitude,
        );
        if (!mounted) return;
        setState(() {
          _suggestions = res;
          _searching = false;
        });
      } catch (e) {
        debugPrint('[Propose] autocomplete failed: $e');
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  Future<void> _pick(PlaceSuggestion sg) async {
    if (_resolving) return;
    setState(() => _resolving = true);
    try {
      PlaceDetails? det;
      if (sg.lat != null && sg.lng != null) {
        det = PlaceDetails(
            address: sg.description, lat: sg.lat!, lng: sg.lng!);
      } else {
        det = await PlacesService(ApiKeys.webServices).details(sg.placeId);
      }
      if (!mounted) return;
      if (det != null) {
        Navigator.of(context).pop(det);
        return;
      }
    } catch (e) {
      debugPrint('[Propose] details failed: $e');
    }
    if (mounted) setState(() => _resolving = false);
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final mq = MediaQuery.of(context);
    return Container(
      decoration: neuBox(radius: 24).copyWith(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(26)),
      ),
      padding: EdgeInsets.fromLTRB(
          18, 14, 18, mq.viewInsets.bottom + mq.padding.bottom + 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.18),
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          Text(
            widget.isStop ? s.addStopLabel : s.changeDestination,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 17,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            s.riderConfirmsAndPays,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 12.5,
            ),
          ),
          const SizedBox(height: 14),
          Container(
            decoration: neuBox(radius: 14, pressed: true),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: TextField(
              controller: _ctrl,
              autofocus: true,
              onChanged: _onChanged,
              style: const TextStyle(color: Colors.white, fontSize: 14.5),
              decoration: InputDecoration(
                border: InputBorder.none,
                icon: Icon(Icons.search_rounded,
                    color: Colors.white.withValues(alpha: 0.4), size: 20),
                hintText:
                    widget.isStop ? s.addStopHint : s.newDestinationHint,
                hintStyle:
                    TextStyle(color: Colors.white.withValues(alpha: 0.35)),
              ),
            ),
          ),
          if (_searching || _resolving) ...[
            const SizedBox(height: 8),
            const LinearProgressIndicator(
              minHeight: 2,
              color: Color(0xFFE8C547),
              backgroundColor: Colors.transparent,
            ),
          ],
          for (final sg in _suggestions.take(5))
            InkWell(
              onTap: () => _pick(sg),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 11),
                child: Row(
                  children: [
                    Icon(Icons.place_outlined,
                        color: Colors.white.withValues(alpha: 0.45),
                        size: 18),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        sg.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: Colors.white, fontSize: 13.5),
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}
