import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
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
import '../widgets/offline_banner.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:share_plus/share_plus.dart';
import 'package:url_launcher/url_launcher.dart';
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
import '../services/socket_service.dart';
import '../config/feature_flags.dart';

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
const int _maxPollFailsBeforeBanner = 15;

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
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _pointAnnotMgr;  // for pins (icon-anchor: bottom)
  mapbox.PointAnnotationManager? _carAnnotMgr;     // for car (icon-anchor: center)
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
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
  // REMOVED: _carUpdateInFlight guard was causing frame drops. The Ticker now
  // pushes every frame to Mapbox; the platform channel handles deduplication.
  // See _updateCarSmooth() in tracking_map_view.dart for details.
  LatLng? _directTargetPos; // for GPS fallback: lerp target when off-route
  double? _directTargetBearing; // RTDB bearing fallback when projection cannot be used

  // ── Animated route draw ──
  Ticker? _routeDrawTicker;
  bool _routeDrawDone = false;
  bool _dropoffPinAdded = false;

  _TrackPhase _phase = _TrackPhase.arriving;
  bool _greetingSent = false;
  bool _arrivedNotifSent = false;
  LatLng _driverPos = const LatLng(0, 0);
  LatLng _animPos = const LatLng(0, 0);
  double _driverBearing = 0;
  double _animBearing = 0;
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
  bool _cancelDialogShown = false; // guard: prevents duplicate cancel dialogs
  bool _confirmPickupShown = false; // guard: prevents double-push of confirm pickup
  bool _showPickupOverlay = false;  // inline overlay — set true when driver arrives
  bool _goingToRating = false;      // guard: prevents double navigation to rating screen

  // ── Pickup overlay slide-up entrance ──
  late AnimationController _pickupOverlayCtrl;
  late Animation<Offset> _pickupOverlaySlide;

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

  // ── Rerouting when driver deviates ──
  int _offRouteCount = 0; // consecutive off-route GPS updates
  bool _rerouteInProgress = false; // guard: prevents concurrent reroute fetches

  // ── Real-time tracking: Socket.io (primary) + Firestore/RTDB (backup) ──
  StreamSubscription<LatLng>? _driverLocSub;
  StreamSubscription<Map<String, dynamic>?>? _tripStatusSub;
  StreamSubscription<Map<String, dynamic>?>? _fallbackTripStatusSub;
  StreamSubscription? _rtdbDriverLocSub;
  StreamSubscription<Map<String, dynamic>>? _socketLocationSub;
  StreamSubscription<Map<String, dynamic>>? _socketStatusSub;
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
    // Pickup overlay slide-up entrance
    _pickupOverlayCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _pickupOverlaySlide = Tween<Offset>(
      begin: const Offset(0, 1.0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _pickupOverlayCtrl, curve: Curves.easeOutCubic));
    // Load car PNG based on ride type
    _loadCarIcon();
    _loadPins();
    // Await persistence before starting real-time tracking to prevent
    // race condition where backend poll resets phase/traveledM to 0.
    _initFromPersistence().then((_) {
      if (mounted) _startRealTimeTracking();
    }).catchError((e) {
      debugPrint('[RiderTracking] _initFromPersistence failed: $e');
      if (mounted) _startRealTimeTracking();
    });
    _interpTicker = createTicker((elapsed) => _interpolate(elapsed))..start();
    // Listen to chat messages so we can fire a local push whenever a
    // driver-sent message arrives while the app is not in the foreground
    // (or the rider is on a different screen). The in-card pill shimmer
    // already covers the in-app case.
    _initChatNotificationsListener();
    // Only send notifications on FRESH trip — not on app resume
    final isFreshTrip = widget.initialStatus == null || widget.initialStatus!.isEmpty;
    if (isFreshTrip) {
      Future.delayed(const Duration(seconds: 3), _sendDriverGreeting);
      _sendRideNotification(
        'Driver Assigned',
        '${widget.driverName.split(' ').first} is on the way in a ${widget.vehicleColor} ${widget.vehicleModel}',
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
      NotificationService.show(
        id: 7710 + (tripId % 1000),
        title: pushTitle,
        body: last.text,
        type: 'chat_message',
        payload: 'trip:$tripId',
      );
    });
  }

  @override
  void dispose() {
    if (_networkListener != null) {
      NetworkService().onlineNotifier.removeListener(_networkListener!);
      _networkListener = null;
    }
    _interpTicker?.dispose();
    _camTimer?.cancel();
    // car annotation cleaned up with pointAnnotMgr
    _routeDrawTicker?.dispose();
    _driverLocSub?.cancel();
    _rtdbDriverLocSub?.cancel();
    _socketLocationSub?.cancel();
    _socketStatusSub?.cancel();
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
    _tripStartedTimer?.cancel();
    _ratingNavTimer?.cancel();
    _rtdbReconnectTimer?.cancel();
    _staleDriverTimer?.cancel();
    _gpsFallbackTimer?.cancel();
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
  final bool _useNavCamera = true; // When true: follow driver at 45° pitch

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

  // Fallback: fetch approach route from backend if no RTDB GPS in 5s
  Timer? _gpsFallbackTimer;

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
              // LAYER 2: Back button
              _buildBackButton(topPad),
              // LAYER 3: Driver info card (top)
              Positioned(
                top: topPad + 10,
                left: 16,
                right: 16,
                child: KeyedSubtree(
                  key: _topCardKey,
                  child: _buildDriverCard(),
                ),
              ),
              // LAYER 4: Resume button + Destination box (bottom)
              Positioned(
                bottom: bottomPad + 16,
                left: 16,
                right: 16,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    KeyedSubtree(
                      key: _bottomCardKey,
                      child: _buildDestinationBox(),
                    ),
                  ],
                ),
              ),
              // Offline banner
              Positioned(
                top: topPad,
                left: 0,
                right: 0,
                child: const OfflineBanner(),
              ),
              // Connection lost banner
              if (_connectionLost)
                Positioned(
                  top: topPad + 36,
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
                _buildMoreMenuOverlay(topPad),
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
  /// Slides up from the bottom with a 380ms easeOutCubic entrance.
  Widget _buildInlinePickupOverlay() {
    final vehicleDesc =
        '${widget.vehicleColor} ${widget.vehicleMake} ${widget.vehicleModel}'.trim();
    return Positioned.fill(
      child: SlideTransition(
        position: _pickupOverlaySlide,
        child: RiderConfirmPickupScreen(
          driverName: widget.driverName,
          vehicleDesc: vehicleDesc,
          firestoreTripId: widget.firestoreTripId,
          tripId: widget.tripId,
          driverPhotoUrl: _driverPhotoUrl ?? _normalizeRemotePhotoUrl(widget.driverPhotoUrl),
          driverId: widget.driverId,
          driverRating: widget.driverRating,
          vehiclePlate: widget.vehiclePlate,
          onConfirmed: () {
            // NOTE: keep _confirmPickupShown = true so a late status=arrived
            // poll (driver hasn't tapped Start Ride yet) does NOT re-show the
            // overlay. The guard is reset inside _transitionToOnTrip() when
            // the backend flips to in_trip.
            if (mounted) {
              setState(() => _showPickupOverlay = false);
              // Pop out the pickup pin and reveal the illuminated route
              _popOutPickupPin();
              _restartRouteAnimation();
            }
          },
          onCancelled: () {
            // Trip was cancelled (e.g., auto-cancel due to wait timeout).
            // Navigate back to home screen.
            if (mounted) {
              Navigator.of(context).pushNamedAndRemoveUntil('/home', (route) => false);
            }
          },
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
