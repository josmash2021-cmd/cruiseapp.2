import 'dart:async';

import '../map/map_surface_coordinator.dart';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/scheduler.dart';
import '../services/haptic_service.dart';
import 'package:flutter/services.dart' show rootBundle, SystemUiOverlayStyle;
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../config/mapbox_config.dart';
import '../config/map_theme.dart';
import '../widgets/map/circular_pin_renderer.dart';

import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/analytics_service.dart';
import '../services/notification_service.dart';
import '../services/trip_firestore_service.dart';
import '../services/socket_service.dart';
import '../config/feature_flags.dart';
import '../widgets/offline_banner.dart';
import '../widgets/neu_style.dart';
import '../utils/mapbox_safe.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import '../utils/share_helper.dart';
import 'package:url_launcher/url_launcher.dart';
import '../services/masked_call_service.dart';
import '../config/api_keys.dart';
import 'chat_screen.dart';
import '../services/chat_service.dart';
import '../models/chat_message.dart';
import 'help_screen.dart';
import 'home_screen.dart';
import 'rider_confirm_pickup_screen.dart';
import 'rider_rating_screen.dart';
import '../l10n/app_localizations.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../widgets/verified_avatar.dart';
import '../utils/responsive.dart';
import '../utils/name_helper.dart' as nh;
import '../services/user_session.dart';
import '../services/network_service.dart';
import '../services/map_controller_cache.dart';
import '../services/firebase_auth_recovery.dart';
import '../utils/route_splice.dart';
import '../map/tracking_map_annotations.dart';
import '../map/tracking_map_route.dart';
import '../map/tracking_map_camera.dart';
import '../map/tracking_map_car.dart';
import '../map/web_map_view.dart';
import '../utils/smooth_motion.dart';

part '../controllers/rider_tracking_controller.dart';
part '../widgets/tracking/driver_info_card.dart';
part '../widgets/tracking/trip_phase_indicator.dart';
part '../widgets/tracking/trip_action_buttons.dart';
part '../widgets/tracking/eta_display.dart';
part '../widgets/tracking/tracking_map_view.dart';

class RiderTrackingScreen extends StatefulWidget {
  const RiderTrackingScreen({
    super.key,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    this.routePoints,
    this.driverName = 'Driver',
    this.driverPhone,
    this.driverRating = 4.9,
    this.vehicleMake = '',
    this.vehicleModel = '',
    this.vehicleColor = '',
    this.vehiclePlate = '',
    this.vehicleYear = '',
    this.rideName = 'Fusion',
    this.price = 0,
    this.pickupLabel = '',
    this.dropoffLabel = '',
    this.tripId,
    this.firestoreTripId,
    this.driverPhotoUrl,
    this.driverId,
    this.onTripComplete,
    this.initialStatus,
  });

  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final List<LatLng>? routePoints;
  final String driverName;
  final String? driverPhone;
  final double driverRating;
  final String vehicleMake;
  final String vehicleModel;
  final String vehicleColor;
  final String vehiclePlate;
  final String vehicleYear;
  final String rideName;
  final double price;
  final String pickupLabel;
  final String dropoffLabel;
  final int? tripId;
  final String? firestoreTripId;
  final String? driverPhotoUrl;
  final String? driverId;
  final VoidCallback? onTripComplete;
  /// Backend trip status used as fallback when local persistence is empty
  /// (e.g. after reinstall). Maps to _TrackPhase so the rider resumes
  /// at the correct state.
  final String? initialStatus;

  @override
  State<RiderTrackingScreen> createState() => _RiderTrackingScreenState();
}

enum _TrackPhase { arriving, arrived, onTrip, nearDestination, completed }
enum _PinIcon { house, store, airplane, person }

const double _kCarAnnotScale = 0.55;  // PointAnnotation icon scale (smaller for cleaner look)

/// How often the route line behind the car is trimmed. 66 ms ≈ 15 fps.
///
/// Was 500 ms — 2 fps — against a car that moves at 30 fps. The line
/// visibly trailed the car and then snapped forward to catch up. The
/// rider should see the road being consumed under the car, continuously.
/// Safe at this rate only because an in-flight guard skips frames instead
/// of queueing writes the SDK would drop (project rule 25).
const int _kRouteEraseIntervalMs = 66;

/// How long after the rider's last map drag the chase camera takes over
/// again. Without a resume the camera stayed parked wherever they left it
/// and the car simply drove off screen.
const int _kResumeFollowAfterPanMs = 8000;

/// Perpendicular distance from the active route polyline beyond which the
/// driver counts as off-route (meters).
const double _kOffRouteMeters = 45;

/// Back below this the driver counts as on-route again — the hysteresis
/// band that stops GPS noise around the threshold from flapping the state.
const double _kBackOnRouteMeters = 30;

/// How long the driver must stay off-route before a reroute fires. A red
/// light or a one-fix GPS spike never reaches this.
const int _kOffRouteSustainMs = 2500;

/// Minimum seconds between reroute fetches, so a long detour does not
/// hammer the directions API.
const int _kRerouteCooldownSec = 10;

/// Cross-fade duration (ms) when a re-routed line replaces the old one.
const int _kRerouteFadeMs = 350;
const int _maxPollFailsBeforeBanner = 15;

/// How long every channel must stay silent before the rider is told the
/// connection is lost. Failures alone are not enough — a channel can error
/// on repeat while the others keep the screen fully up to date.
const int _kNoDataBannerMs = 20000;

String? _normalizeRemotePhotoUrl(String? rawUrl) {
  var raw = (rawUrl ?? '').trim();
  if (raw.isEmpty) return null;
  if (raw == 'null' || raw == 'None' || raw == 'none' || raw == 'undefined') return null;
  if ((raw.startsWith('"') && raw.endsWith('"')) ||
      (raw.startsWith("'") && raw.endsWith("'"))) {
    raw = raw.substring(1, raw.length - 1).trim();
  }
  if (raw.isEmpty) return null;
  if (raw.startsWith('http://') || raw.startsWith('https://')) return raw;
  if (raw.startsWith('/')) return '${ApiService.publicBaseUrl}$raw';
  return '${ApiService.publicBaseUrl}/$raw';
}

class _RiderTrackingScreenState extends State<RiderTrackingScreen>
    with TickerProviderStateMixin {
  void _setState(VoidCallback fn) { if (mounted) setState(fn); }

  /// Identifies this screen to [MapSurfaceCoordinator].
  ///
  /// This is pushed on top of the booking screen, which keeps its own
  /// full-screen map — two live Mapbox surfaces, which closes the app on
  /// iOS right at the moment the rider is matched with a driver. Claiming
  /// the surface revokes the one underneath and waits for it to be gone.
  static const String _mapSurfaceOwner = 'RiderTracking';
  bool _mapMounted = false;

  /// Claim the one live Mapbox surface before mounting the map.
  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_mapMounted) return;
        _setState(() => _mapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    _setState(() => _mapMounted = true);
  }

  mapbox.MapboxMap? _map;
  /// Web (Mapbox GL JS) controller — used instead of [_map] when kIsWeb.
  /// Every map entry point branches to this before touching the native
  /// controller, so `_map` stays null on web and nothing native runs.
  WebMapController? _webMapCtrl;
  /// Window during which camera moves are treated as programmatic (ours),
  /// not user pans. Mirrors ride_request_screen's `_webAutoCameraUntil`.
  DateTime _webAutoCameraUntil = DateTime(2000);
  DateTime _lastWebCamMove = DateTime(2000);
  /// True once the web chase has flown in behind the car for this trip;
  /// reset whenever the phase leaves onTrip so a re-entry glides again.
  bool _webChaseEntered = false;
  /// Last bearing pushed to the web car marker; < 0 = not created yet.
  double _webCarBearing = -1;
  mapbox.PointAnnotationManager? _pointAnnotMgr;  // for pins (icon-anchor: bottom)
  mapbox.PointAnnotationManager? _carAnnotMgr;     // for car (icon-anchor: center)
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  
  // New modular map components (gradual migration)
  TrackingMapAnnotations? _mapAnnotations;
  TrackingMapRoute? _mapRoute;
  TrackingMapCamera? _mapCamera;
  TrackingMapCar? _mapCar;
  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;
  mapbox.PolylineAnnotation? _remainingRouteAnnot;  // single gloss gold line (5px)
  mapbox.PolylineAnnotation? _dimmedRouteAnnot; // dimmed full route (pickup→dropoff)
  mapbox.PolylineAnnotation? _approachAnnot; // dashed line driver→pickup
  final double _cameraBearing = 0;
  Uint8List? _pickupPinBytes;
  Uint8List? _dropoffPinBytes;
  Uint8List? _pickupPinWithLabelBytes;
  Uint8List? _dropoffPinWithLabelBytes;
  bool _pickupLabelRevealed = false;
  bool _dropoffLabelRevealed = false;
  bool _pickupPopping = false; // pickup pin pop-out in progress
  bool _showPickupPin = true; // hide after pop-out completes
  DateTime _lastRouteErase = DateTime(2000); // throttle route erase updates
  /// True while a route-erase update is still crossing the platform
  /// channel. See [_kRouteEraseIntervalMs].
  bool _routeEraseBusy = false;

  // ── Cinematic intro animation ──
  double _cinematicPitch = 0;
  double _cinematicBearing = 0;
  bool _cinematicDone = false;

  // ── Camera animation lock: prevents overlapping flyTo/easeTo ──
  bool _cameraAnimating = false;
  DateTime _cameraAnimEnd = DateTime(2000);

  // ── Car marker using PointAnnotation (reliable, same as pins) ──
  Uint8List? _carPngBytes;       // PNG bytes for PointAnnotation image
  mapbox.PointAnnotation? _carAnnot;  // The car annotation on the map
  bool _carAnnotCreating = false; // guard: prevents async race
  bool _carPopDone = false;      // true after first pop-in animation completes
  DateTime? _carFirstGpsTime; // when we first got driver GPS — used for heartbeat
  Timer? _carHeartbeatTimer;  // forces car recreation if it never appeared
  LatLng? _directTargetPos; // for GPS fallback: lerp target when off-route
  double? _directTargetBearing; // RTDB bearing fallback when projection cannot be used

  // ── Animated route draw ──
  Ticker? _routeDrawTicker;
  bool _routeDrawDone = false;

  /// Drives the reroute cross-fade between the old and the re-routed line
  /// (legacy annotation path — the modular component owns its own timer).
  Timer? _rerouteFadeTimer;
  bool _dropoffPinAdded = false;

  _TrackPhase _phase = _TrackPhase.arriving;
  bool _mapLoadError = false;
  String _mapErrorMessage = '';
  bool _greetingSent = false;
  bool _arrivedNotifSent = false;
  // Initialize to pickup location so the car appears immediately on the map
  // even before the first GPS packet arrives. Once real driver GPS comes in,
  // the interpolation ticker animates the car from pickup to real position.
  LatLng _driverPos = const LatLng(0, 0);
  LatLng _animPos = const LatLng(0, 0);
  double _driverBearing = 0;
  double _animBearing = 0;

  /// The car's motion engine — the same SmoothMotion the driver's own
  /// online/offline pages use. Fed by every driver GPS packet; the ticker
  /// only reads it. Constant-velocity glide while the driver rolls, and a
  /// standstill jitter hold while parked, so the pin no longer wanders when
  /// the driver is sitting still.
  final SmoothMotion _carMotion = SmoothMotion();
  int _etaMinutes = 2;
  double _distanceMiles = 0;
  List<LatLng> _routePts = [];
  int _ratingStars = 5;
  double _tipAmount = 0;
  bool _customTip = false;
  bool _saveDriver = false;
  final Set<String> _feedbackChips = {};
  String _anonymousFeedback = '';
  bool _connectionLost = false;
  int _pollFailCount = 0;
  /// When ANY live channel last delivered trip data.
  ///
  /// The "connection lost" banner is gated on this. Four independent
  /// channels share [_pollFailCount], so without it one permanently broken
  /// channel (RTDB rules rejecting, a fallback doc that was never created)
  /// accuses the rider's internet while the other three feed the screen
  /// perfectly well. Null = nothing received yet; never accuse then either.
  DateTime? _lastAnyDataAt;
  bool _cancelDialogShown = false; // guard: prevents duplicate cancel dialogs
  bool _confirmPickupShown = false; // guard: prevents double-push of confirm pickup

  /// The trip went back to the dispatch queue and we are waiting for a new
  /// driver. Set when a hand-back arrives, cleared when one is assigned.
  bool _backInQueueShown = false;
  bool _searchingNewDriver = false;
  bool _showPickupOverlay = false;  // inline overlay — set true when driver arrives
  bool _goingToRating = false;      // guard: prevents double navigation to rating screen

  // ── Pickup overlay slide-up entrance + fade ──
  late AnimationController _pickupOverlayCtrl;
  late Animation<Offset> _pickupOverlaySlide;
  late Animation<double> _pickupOverlayFade;

  // ── More-menu dropdown & cancel overlay ──
  bool _showMoreMenu = false;
  int _cancelOverlayPhase = 0; // 0=hidden, 1=cancelling(spinner), 2=done(checkmark)

  // ── Mutable driver photo URL (updated from Firestore) ──
  String? _driverPhotoUrl;

  // ── Bottom bar phase transition state ──
  bool _tripJustStarted = false; // brief "Your trip has started" message
  Timer? _tripStartedTimer;
  Timer? _ratingNavTimer;    // cancellable delay before navigating to rating

  int _pickupIdx = 0;

  /// Cumulative distance array — _segDist[i] = total meters from start to point i.
  List<double> _segDist = [];

  /// Current traveled distance in meters along the route.
  double _traveledM = 0;

  /// Ticks once per animation frame so the Flutter-painted car repaints
  /// with the motion.
  ///
  /// Nothing in this screen's GPS path calls setState per frame — the
  /// annotations were written straight to the map, which needs no rebuild,
  /// and the widget tree is deliberately rebuilt at about three times a
  /// second so the cards stay cheap. A CustomPaint or an Image drawn on top
  /// only redraws when something tells it to, so without this the car would
  /// have been repainted three times a second while claiming sixty. That
  /// exact mistake shipped twice on the driver screens today.
  ///
  /// A notifier and not setState: this repaints one 88-pixel image, where
  /// setState would rebuild the map, both cards and the chat pill sixty
  /// times a second.
  final ValueNotifier<int> _carFrame = ValueNotifier<int>(0);

  Ticker? _interpTicker;
  /// True when animation has converged — ticker is paused to save CPU/battery.
  /// Restarted automatically when new GPS data arrives.
  bool _interpIdle = false;

  /// Target traveled distance (set by sim timer, approached smoothly by interp ticker)
  double _tgtTraveledM = 0;
  final double _tgtBrg = 0;
  Timer? _camTimer;

  /// Velocity tracking for smooth prediction between GPS updates
  double _velocityMps = 0; // meters per second along route
  DateTime _lastGpsTime = DateTime.now();

  /// Route duration in seconds from the directions API (traffic-aware).
  /// Used for ETA when driver velocity is unavailable.
  int? _routeDurationSec;

  /// Delta-time tracking for frame-rate independent interpolation
  Duration _lastInterpElapsed = Duration.zero;

  /// Throttle UI rebuilds — car annotation updates don't need setState
  DateTime _lastUiRebuild = DateTime(2000);

  /// Throttle car annotation updates so we don't pound the Mapbox SDK at 60fps.
  /// 30fps is plenty smooth and avoids native-thread stutter.
  DateTime _lastCarUpdate = DateTime(2000);
  static const int _minCarUpdateMs = 33;

  // ── Rerouting when driver deviates ──
  /// First moment the driver was seen beyond [_kOffRouteMeters] from the
  /// active polyline; null while on-route. Sustained presence past
  /// [_kOffRouteSustainMs] is what fires the reroute — a single noisy fix
  /// or a red-light stop never does.
  DateTime? _offRouteSince;
  DateTime? _lastRerouteAt; // cooldown clock between reroute fetches
  bool _rerouteInProgress = false; // guard: prevents concurrent reroute fetches

  // ── Real-time tracking: SSE (primary) + Socket.io (GPS) + Firestore/RTDB (backup) ──
  StreamSubscription<LatLng>? _driverLocSub;
  StreamSubscription<Map<String, dynamic>?>? _tripStatusSub;
  StreamSubscription<Map<String, dynamic>?>? _fallbackTripStatusSub;
  StreamSubscription? _rtdbDriverLocSub;
  StreamSubscription<Map<String, dynamic>>? _socketLocationSub;
  StreamSubscription<Map<String, dynamic>>? _socketStatusSub;
  StreamSubscription<Map<String, dynamic>>? _sseTripSub;  // SSE primary channel
  StreamSubscription<bool>? _socketHealthSub;
  Timer? _rtdbNullRetryTimer;
  bool _sseActive = false;
  String? _rtdbDriverId;
  Timer? _statusPollTimer;
  Timer? _rideSaveTimer;
  VoidCallback? _networkListener; // proactive reconnect on network recovery

  // ── Rider own location dot (uses Mapbox native location puck — no drift on zoom) ──
  StreamSubscription<Position>? _riderLocSub;

  // ── Chat: local-notification fallback ──
  // Listens to RTDB chat messages and fires a flutter_local_notification
  // when a driver message arrives while the rider is not viewing the
  // tracking screen in foreground. Avoids needing a server-side FCM
  // round-trip for the local push case.
  StreamSubscription<List<ChatMessage>>? _chatMsgsSub;
  int _lastSeenChatTs = 0;

  late AnimationController _etaPulse;

  @override
  void initState() {
    super.initState();
    unawaited(_acquireMapSurface());
    _driverPhotoUrl = _normalizeRemotePhotoUrl(widget.driverPhotoUrl);
    // If no photo URL from dispatch, proactively fetch from Firestore user doc.
    if ((_driverPhotoUrl == null || _driverPhotoUrl!.isEmpty) &&
        widget.driverId != null &&
        widget.driverId!.isNotEmpty) {
      Future.microtask(() => _fetchDriverPhotoFromUserDoc(widget.driverId!));
    }
    _etaPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _arrivedDotPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    // Pickup overlay slide-up + fade entrance
    _pickupOverlayCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _pickupOverlaySlide = Tween<Offset>(
      begin: const Offset(0, 0.15),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _pickupOverlayCtrl, curve: Curves.easeOutCubic));
    _pickupOverlayFade = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pickupOverlayCtrl, curve: Curves.easeOutCubic));
    // Load car PNG based on ride type
    _loadCarIcon();
    _loadPins();
    // NOTE: the modular car icon is NOT loaded on a timer any more. It is
    // loaded when the map is created, and _updateCarSmooth passes rideName
    // on every frame so TrackingMapCar can load it itself if that missed.
    // A single delayed attempt used to decide whether the rider saw a car
    // at all — it ran at 500 ms, before a cold-started map existed.
    // Await persistence before starting real-time tracking to prevent
    // race condition where backend poll resets phase/traveledM to 0.
    _initFromPersistence().then((_) {
      if (mounted) _startRealTimeTracking();
    }).catchError((e) {
      debugPrint('[RiderTracking] _initFromPersistence failed: $e');
      if (mounted) _startRealTimeTracking();
    });
    // One ticker for the car AND the camera — see _onAnimationFrame for why
    // they must not be two.
    // Lambda, not a tear-off: _onAnimationFrame lives in an extension, and
    // this matches how the file already called _interpolate.
    _interpTicker = createTicker((elapsed) => _onAnimationFrame(elapsed))
      ..start();
    // Listen to chat messages so we can fire a local push whenever a
    // driver-sent message arrives while the app is not in the foreground
    // (or the rider is on a different screen). The in-card pill shimmer
    // already covers the in-app case.
    _initChatNotificationsListener();
    // Only send notifications on FRESH trip — not on app resume
    final isFreshTrip = widget.initialStatus == null || widget.initialStatus!.isEmpty;
    if (isFreshTrip) {
      Future.delayed(const Duration(seconds: 3), _sendDriverGreeting);
      // Driver assigned notification is sent via FCM push from backend.
      // No local notification needed — rider is already on tracking screen.
      // Save to inbox for history only.
      LocalDataService.addNotification(
        title: 'Driver Assigned',
        message: '${widget.driverName.split(' ').first} is on the way in a ${widget.vehicleColor} ${widget.vehicleModel}',
        type: 'ride',
      );
    }
    // Save state is handled by _rideSaveTimer in the controller

    // Proactively reconnect RTDB + clear banner when network returns
    _networkListener = () {
      if (!mounted) return;
      final online = NetworkService().isOnline;
      if (online && _connectionLost) {
        debugPrint('[RiderTracking] Network recovered — clearing banner + reconnecting RTDB');
        setState(() {
          _connectionLost = false;
          _pollFailCount = 0;
        });
        // Reconnect RTDB driver listener if we have a driver ID
        if (_rtdbDriverId != null && _phase != _TrackPhase.completed) {
          _startRtdbDriverListener(_rtdbDriverId!);
        }
      }
    };
    NetworkService().onlineNotifier.addListener(_networkListener!);
  }

  /// Subscribe to RTDB chat for the active trip and fire a local
  /// notification ("New message from driver") for every fresh
  /// driver-sent message that lands while the rider is not actively
  /// looking at the chat in the foreground. The in-card pill shimmer
  /// already handles the foreground case via its own StreamBuilder.
  void _initChatNotificationsListener() {
    final tripId = widget.tripId;
    if (tripId == null) return;
    // Capture the localized title up-front; using S.of(context) inside
    // an async listener is unsafe across context lifecycle.
    final pushTitle = S.of(context).newMessageFromDriverPushTitle;
    _chatMsgsSub?.cancel();
    _chatMsgsSub =
        ChatService().messagesStream(tripId.toString()).listen((messages) {
      if (messages.isEmpty) return;
      final last = messages.last;
      final lastTs = last.timestamp;
      // Skip the initial dump on first subscribe so the rider doesn't
      // get a fake notification for chat history when they reopen.
      if (_lastSeenChatTs == 0) {
        _lastSeenChatTs = lastTs;
        return;
      }
      if (lastTs <= _lastSeenChatTs) return;
      _lastSeenChatTs = lastTs;
      // Only notify on driver-sent messages.
      if (last.senderRole == 'rider') return;
      // Chat notifications are sent via FCM push from backend.
      // No local notification needed — rider is already on tracking screen
      // and can see messages in the chat UI. The OS shows push when backgrounded.
    });
  }

  @override
  void dispose() {
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    if (_networkListener != null) {
      NetworkService().onlineNotifier.removeListener(_networkListener!);
      _networkListener = null;
    }
    // Ticker first, notifier second. Reversed, the ticker is still live
    // when the notifier dies and its very next frame writes to a disposed
    // ValueNotifier — which throws, out of dispose(), and takes the app
    // down every time the rider leaves this screen.
    _interpTicker?.dispose();
    _carFrame.dispose();
    _camTimer?.cancel();
    _carHeartbeatTimer?.cancel();
    // car annotation cleaned up with pointAnnotMgr
    _routeDrawTicker?.dispose();
    _rerouteFadeTimer?.cancel();
    _driverLocSub?.cancel();
    _rtdbDriverLocSub?.cancel();
    _socketLocationSub?.cancel();
    _socketStatusSub?.cancel();
    _sseTripSub?.cancel();  // Cancel SSE trip stream
    // Leave Socket.io trip room
    if (widget.tripId != null) {
      SocketService.leaveTrip(widget.tripId!);
    }
    _chatMsgsSub?.cancel();
    _tripStatusSub?.cancel();
    _fallbackTripStatusSub?.cancel();
    _statusPollTimer?.cancel();
    _rideSaveTimer?.cancel();
    _riderLocSub?.cancel();
    _etaPulse.dispose();
    _arrivedDotPulse.dispose();
    _pickupOverlayCtrl.dispose();
    _routeFadeJob?.cancel();
    _startRidePhaseTimer?.cancel();
    _cameraFollowTimer?.cancel();
    // No _stopCameraTicker() — the camera rides _interpTicker, disposed above.
    _tripStartedTimer?.cancel();
    _ratingNavTimer?.cancel();
    _socketHealthSub?.cancel();
    _rtdbNullRetryTimer?.cancel();
    _rtdbReconnectTimer?.cancel();
    _staleDriverTimer?.cancel();
    _gpsFallbackTimer?.cancel();
    _driverGpsWatchdog?.cancel();
    _approachRouteTimer?.cancel();
    _trafficRefreshTimer?.cancel();
    _labelAnimJob?.cancel();
    _dropoffPopJob?.cancel();
    _pickupPopOutJob?.cancel();
    _animScheduler.dispose();
    // Clean up map annotations so route/pins don't persist
    _cleanupMapAnnotations();
    super.dispose();
  }

  // ── Navigation arrow mode (unused for now, kept for future) ──
  final bool _navArrowMode = false;

  // ── Camera: fit bounds to show full route (throttled, not every frame) ──
  DateTime _lastBoundsFit = DateTime(2000);

  // ══════════════════════════════════════════════════════════════════════════
  // FIX 1: ROUTE FITTING BETWEEN CARDS
  // ══════════════════════════════════════════════════════════════════════════
  // GlobalKeys to measure card heights for map padding
  final GlobalKey _topCardKey = GlobalKey();
  final GlobalKey _bottomCardKey = GlobalKey();

  double get _topCardHeight {
    final box = _topCardKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size.height ?? 140.0;
  }

  double get _bottomCardHeight {
    final box = _bottomCardKey.currentContext?.findRenderObject() as RenderBox?;
    return box?.size.height ?? 80.0;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // FIX 2: DRIVER ARRIVED STATE
  // ══════════════════════════════════════════════════════════════════════════
  // Single shared vsync scheduler that drives every pin/route animation
  // on the tracking map. Replaces 4 separate wall-clock Timer.periodic
  // (16ms + 3× 33ms) that used to pile up during pickup/dropoff
  // transitions and spike CPU / heat. See [_AnimScheduler] below for the
  // job model. The scheduler auto-parks its ticker when no jobs are
  // active, so idle cost is zero.
  late final _AnimScheduler _animScheduler = _AnimScheduler(this);

  double _routeOpacity = 1.0;
  bool _arrivedStateInitialized = false;

  // Pulsing golden dot animation for "arrived" state
  late AnimationController _arrivedDotPulse;

  // ══════════════════════════════════════════════════════════════════════════
  // FIX 3 & 4: START RIDE ANIMATION & SMOOTH TRACKING
  // ══════════════════════════════════════════════════════════════════════════
  // Start ride animation phases
  Timer? _startRidePhaseTimer;
  int _startRidePhase = 0; // 0 = no animation, 1 = draw, 2 = zoom out, 3 = pause, 4 = zoom in, 5+ = follow mode
  bool _startRideAnimationDone = false;

  // Periodic state save handled by _rideSaveTimer in the controller

  // Smooth camera follow (for real-time tracking after animation)
  bool _shouldFollowDriver = true;
  Timer? _cameraFollowTimer;
  bool _useNavCamera = true; // When true: heading-up chase with a gentle 20° tilt

  /// Set when the chase camera is being handed back after a rider pan
  /// (auto-resume), so the next [startNavigationChase] keeps easing from
  /// its held state instead of replaying the full intro swing. The swing
  /// is for entrances (phase flip into onTrip), not resumes.
  bool _chaseResumedFromPan = false;

  /// True once the full intro swing has played for this trip. The swing is
  /// for the FIRST entry into the trip only: when the map surface is
  /// recreated mid-trip (fresh TrackingMapCamera, _navChaseActive = false)
  /// or the chase is handed back while already onTrip/nearDestination, the
  /// camera just keeps easing from its held state instead of swinging
  /// around again.
  bool _chaseIntroPlayedForTrip = false;

  // No camera Ticker of its own: the chase camera runs on _interpTicker,
  // the same frame that moves the car. Two tickers writing to one platform
  // channel with different backpressure made the marker oscillate around
  // its anchor on slow devices — see _onAnimationFrame.
  bool _userControllingCamera = false;
  DateTime? _lastUserCameraInteraction;

  // Safety net: detect stale driver location (trip may have ended)
  Timer? _staleDriverTimer;
  // Animation job handles — replaced individual Timer.periodic instances.
  // Calling .cancel() aborts the job on the shared scheduler.
  _AnimJob? _labelAnimJob;
  _AnimJob? _dropoffPopJob;
  _AnimJob? _pickupPopOutJob;
  _AnimJob? _routeFadeJob;
  bool _completionCheckInFlight = false;

  // RTDB auto-reconnect: retry when stream errors out
  Timer? _rtdbReconnectTimer;
  int _rtdbFailCount = 0;

  // Set every time the Firestore trip-status listener delivers fresh data.
  // The 1.5 s HTTP poll skips its tick when this is <700 ms old, avoiding
  // redundant network calls while Firestore is healthy. Null = never
  // heard from Firestore → poll runs normally (safe default).
  DateTime? _lastFirestoreEventAt;

  /// When a live push channel (SSE, Socket.io, Firestore) last delivered an
  /// actual trip status — not merely when it was connected.
  ///
  /// The poll used to stand down whenever Socket.io reported `isConnected`
  /// and Firestore had said anything recently. Connected is not the same as
  /// delivering: the backend runs several uvicorn workers and both the SSE
  /// event bus and the Socket.io rooms live in one process's memory, so a
  /// status pushed by the worker that handled the driver's request never
  /// reaches a rider parked on a different one. The rider's socket is
  /// perfectly connected and perfectly silent, and the one channel that
  /// would have caught it — this poll — was the thing being skipped.
  DateTime? _lastLiveStatusAt;

  /// When a driver position last arrived, from ANY channel.
  ///
  /// The one honest measure of whether the passenger is being told where
  /// their car is. Every other signal available here — socket connected,
  /// listener attached, Firestore responding — can be true while this stays
  /// null and the car sits frozen on the map.
  DateTime? _lastDriverGpsAt;

  /// Timestamp (ms epoch, payload time when the fix carries one, arrival
  /// time otherwise) of the last driver fix accepted into the motion
  /// engine. A fix older than this is stale — a delayed retry or a
  /// re-delivered socket frame — and feeding it would drag the car
  /// backwards across the map.
  double? _lastAcceptedFixAt;
  double? _lastAcceptedFixLat;
  double? _lastAcceptedFixLng;

  /// Re-arms the RTDB driver feed when [_lastDriverGpsAt] goes quiet.
  Timer? _driverGpsWatchdog;

  // Fallback: fetch approach route from backend if no RTDB GPS in 5s
  Timer? _gpsFallbackTimer;
  Timer? _approachRouteTimer;  // FIX: separate from _gpsFallbackTimer to avoid overwriting RTDB fallback
  Timer? _trafficRefreshTimer; // recalc route with live traffic every 2 min

  @override
  Widget build(BuildContext context) {
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _navigateToHome();
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: const Color(0xFF111318),
          body: Stack(
            children: [
              // LAYER 1: Full-screen map
              Positioned.fill(child: _buildFullScreenMap()),
              // LAYER 2: Status + ETA bar (top).
              //
              // No back button once a driver is assigned: the trip is the
              // only thing this screen is for, and leaving mid-ride only
              // ever meant losing sight of the car. The status bar spans
              // the full width again now that nothing sits beside it.
              //
              // _topCardKey stays on the top slot, not on a specific card —
              // every map padding calculation measures "whatever is on
              // top", so swapping the two cards needs no math changes.
              Positioned(
                top: topPad + 10,
                left: Responsive.w(16),
                right: 16,
                child: KeyedSubtree(
                  key: _topCardKey,
                  child: _buildDestinationBox(),
                ),
              ),
              // LAYER 4: Driver info card (bottom) — avatar, plate, chat,
              // call, share and the more menu, all within thumb reach.
              // Welded to the edges and the floor now, like the driver
              // app's own sheets — no floating margins, the card IS the
              // bottom of the screen.
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: KeyedSubtree(
                  key: _bottomCardKey,
                  // While the trip is back in the dispatch queue the old
                  // driver's card would still be showing their name, photo
                  // and plate for someone who handed the trip back. Show
                  // the search state instead until a new driver is assigned.
                  child: _searchingNewDriver
                      ? _buildSearchingDriverCard()
                      : _buildDriverCard(),
                ),
              ),
              // Offline banner
              Positioned(
                top: topPad,
                left: 0,
                right: 0,
                child: const OfflineBanner(),
              ),
              // Connection lost banner — sits under the top status bar
              // instead of on top of it.
              if (_connectionLost)
                Positioned(
                  top: topPad + 10 + _topCardHeight + 8,
                  left: 24,
                  right: 24,
                  child: _buildConnectionLostBanner(),
                ),
              // MORE menu overlay (tap-away dismisses)
              if (_showMoreMenu) ...[
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => setState(() => _showMoreMenu = false),
                    behavior: HitTestBehavior.opaque,
                    child: const ColoredBox(color: Colors.transparent),
                  ),
                ),
                _buildMoreMenuOverlay(bottomPad),
              ],
              // CANCEL overlay (blur + spinner / checkmark)
              if (_cancelOverlayPhase > 0) _buildCancelOverlay(),
              // CONFIRM PICKUP overlay — shown inline when driver arrives
              // (avoids Navigator.push fragility during animation transitions)
              if (_showPickupOverlay) _buildInlinePickupOverlay(),
            ],
          ),
        ),
      ),
    );
  }

  /// Full-screen confirm pickup overlay rendered inline in the Stack so it
  /// always appears — no Navigator.push fragility.
  /// Slides up from the bottom with a 450ms easeOutCubic entrance + fade.
  Widget _buildInlinePickupOverlay() {
    final vehicleDesc =
        '${widget.vehicleColor} ${widget.vehicleMake} ${widget.vehicleModel}'.trim();
    return Positioned.fill(
      child: FadeTransition(
        opacity: _pickupOverlayFade,
        child: SlideTransition(
          position: _pickupOverlaySlide,
          // The overlay slides over a live Mapbox texture. Given its own
          // layer, the entrance re-composites an already-rasterised screen;
          // without one, every frame of the slide re-rasterises this screen
          // and the map underneath together — which is what made the arrival
          // screen come in torn instead of gliding.
          child: RepaintBoundary(
          child: RiderConfirmPickupScreen(
            driverName: widget.driverName,
            vehicleDesc: vehicleDesc,
            firestoreTripId: widget.firestoreTripId,
            tripId: widget.tripId,
            driverPhotoUrl: _driverPhotoUrl ?? _normalizeRemotePhotoUrl(widget.driverPhotoUrl),
            driverId: widget.driverId,
            driverRating: widget.driverRating,
            vehiclePlate: widget.vehiclePlate,
            onConfirmed: () async {
              // NOTE: keep _confirmPickupShown = true so a late status=arrived
              // poll (driver hasn't tapped Start Ride yet) does NOT re-show the
              // overlay. The guard is reset inside _transitionToOnTrip() when
              // the backend flips to in_trip.
              if (mounted) {
                // Fade out smoothly before removing from tree
                await _pickupOverlayCtrl.reverse();
                if (!mounted) return;
                setState(() => _showPickupOverlay = false);
                // Pop out the pickup pin and reveal the illuminated route
                _popOutPickupPin();
                _restartRouteAnimation();
              }
            },
            onCancelled: () async {
              // Trip was cancelled (e.g., auto-cancel due to wait timeout).
              // Fade out smoothly before navigating.
              if (mounted) {
                await _pickupOverlayCtrl.reverse();
                if (!mounted) return;
                Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
              }
            },
          ),
        ),
        ),
      ),
    );
  }

  // ── Slow path: create pins + route polylines once when bytes are ready ──
  bool _staticAnnotsDone = false;

  /// Thin faint approach line from driver to pickup when phase = arriving
  /// and driver is more than 200m away. Removed on arrival.
  DateTime _lastApproachUpdate = DateTime(2000);
  bool _approachLineRemoved = false;

  // ── Approach route: driver→pickup (Uber-style) ──
  List<LatLng> _tripRoutePts = [];         // stored pickup→dropoff route (for after arriving)
  bool _approachRouteFetched = false;      // guard: approach route already obtained
  bool _approachRouteFetching = false;     // guard: fetch in progress
  /// True when the approach-route fetch failed even after the retry. The
  /// straight driver→pickup stopgap line is never drawn as a final state —
  /// no line (the dimmed trip route + pins stay) is better than a line that
  /// lies. Reset when the trip starts or a fresh fetch is allowed.
  bool _approachRouteFailed = false;
}

// ════════════════════════════════════════════════════════════
//  Shared animation scheduler for the tracking map
// ════════════════════════════════════════════════════════════
//
//  One vsync Ticker drives up to N concurrent short-lived animation
//  jobs (pin pops, label springs, route fades). Replaces the old model
//  where each animation owned a wall-clock Timer.periodic — that
//  stacked 4 timers at 30-60 FPS during the pickup/dropoff transition
//  and was the #1 source of CPU heat on both rider and driver phones.
//
//  The ticker auto-parks when jobs.isEmpty, so the idle cost is zero.
//  Each [_AnimJob] completes once its elapsed time reaches its
//  duration; [onDone] is invoked with [mounted] already validated.

typedef _AnimTick = void Function(double t);

class _AnimJob {
  _AnimJob._(this._scheduler, this.durationMs, this.onTick, this.onDone) {
    _startedAt = DateTime.now();
  }

  final _AnimScheduler _scheduler;
  final int durationMs;
  final _AnimTick onTick;
  final VoidCallback? onDone;

  late final DateTime _startedAt;
  bool _cancelled = false;
  bool _done = false;

  bool get isActive => !_cancelled && !_done;

  void cancel() {
    if (_cancelled || _done) return;
    _cancelled = true;
    _scheduler._remove(this);
  }

  /// Returns true if the job has finished and should be removed.
  bool _advance(State hostState) {
    if (_cancelled || _done) return true;
    final elapsed = DateTime.now().difference(_startedAt).inMilliseconds;
    final t = (elapsed / durationMs).clamp(0.0, 1.0);
    if (hostState.mounted) {
      onTick(t);
    } else {
      // Host unmounted — stop silently, skip onDone.
      _done = true;
      return true;
    }
    if (t >= 1.0) {
      _done = true;
      if (hostState.mounted) onDone?.call();
      return true;
    }
    return false;
  }
}

class _AnimScheduler {
  _AnimScheduler(this._vsync);

  final TickerProvider _vsync;
  final List<_AnimJob> _jobs = [];
  Ticker? _ticker;
  bool _disposed = false;

  _AnimJob schedule({
    required int durationMs,
    required _AnimTick onTick,
    VoidCallback? onDone,
  }) {
    final job = _AnimJob._(this, durationMs, onTick, onDone);
    if (_disposed) return job;
    _jobs.add(job);
    _ensureTickerRunning();
    return job;
  }

  void _remove(_AnimJob job) {
    _jobs.remove(job);
    if (_jobs.isEmpty) _ticker?.stop();
  }

  void _ensureTickerRunning() {
    // Lazy-create so we don't spin a ticker until the first job arrives.
    _ticker ??= _vsync.createTicker(_onFrame);
    if (!_ticker!.isActive) _ticker!.start();
  }

  void _onFrame(Duration _) {
    // Iterate over a copy so jobs can cancel() themselves inside onTick
    // without blowing up the iteration.
    if (_jobs.isEmpty) {
      _ticker?.stop();
      return;
    }
    if (_vsync is! State) return;
    final host = _vsync as State;
    final done = <_AnimJob>[];
    for (final job in List<_AnimJob>.from(_jobs)) {
      if (job._advance(host)) done.add(job);
    }
    for (final j in done) {
      _jobs.remove(j);
    }
    if (_jobs.isEmpty) _ticker?.stop();
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    for (final j in _jobs) {
      j._cancelled = true;
    }
    _jobs.clear();
    _ticker?.dispose();
    _ticker = null;
  }
}
