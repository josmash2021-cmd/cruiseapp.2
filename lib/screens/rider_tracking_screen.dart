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

const double _kCarAnnotScale = 0.85;  // PointAnnotation icon scale
const int _maxPollFailsBeforeBanner = 3;

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
  void _setState(VoidCallback fn) { setState(fn); }
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

  // ── Car marker using PointAnnotation (reliable, same as pins) ──
  Uint8List? _carPngBytes;       // PNG bytes for PointAnnotation image
  mapbox.PointAnnotation? _carAnnot;  // The car annotation on the map
  bool _carAnnotCreating = false; // guard: prevents async race
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

  // ── More-menu dropdown & cancel overlay ──
  bool _showMoreMenu = false;
  int _cancelOverlayPhase = 0; // 0=hidden, 1=cancelling(spinner), 2=done(checkmark)

  // ── Mutable driver photo URL (updated from Firestore) ──
  String? _driverPhotoUrl;

  // ── Bottom bar phase transition state ──
  bool _tripJustStarted = false; // brief "Your trip has started" message
  Timer? _tripStartedTimer;

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

  // ── Rerouting when driver deviates ──
  int _offRouteCount = 0; // consecutive off-route GPS updates
  bool _rerouteInProgress = false; // guard: prevents concurrent reroute fetches

  // ── Real-time tracking via Firestore ──
  StreamSubscription<LatLng>? _driverLocSub;
  StreamSubscription<Map<String, dynamic>?>? _tripStatusSub;
  StreamSubscription<Map<String, dynamic>?>? _fallbackTripStatusSub;
  StreamSubscription? _rtdbDriverLocSub;
  String? _rtdbDriverId;
  Timer? _statusPollTimer;
  Timer? _rideSaveTimer;

  // ── Rider own location dot (uses Mapbox native location puck — no drift on zoom) ──
  StreamSubscription<Position>? _riderLocSub;

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
    // Load car PNG based on ride type
    _loadCarIcon();
    _loadPins();
    _initFromPersistence();
    _interpTicker = createTicker((_) => _interpolate())..start();
    _startRealTimeTracking();
    _startRiderLocationTracking();
    // Send greeting notification after 3 seconds
    Future.delayed(const Duration(seconds: 3), _sendDriverGreeting);
    // Notify rider that a driver was assigned
    _sendRideNotification(
      'Driver Assigned',
      '${widget.driverName.split(' ').first} is on the way in a ${widget.vehicleColor} ${widget.vehicleModel}',
    );
    // Save state periodically for resume support
    _saveStateTimer = Timer.periodic(const Duration(seconds: 5), (_) => _saveRideState());
  }

  @override
  void dispose() {
    _interpTicker?.dispose();
    _camTimer?.cancel();
    // car annotation cleaned up with pointAnnotMgr
    _routeDrawTicker?.dispose();
    _driverLocSub?.cancel();
    _rtdbDriverLocSub?.cancel();
    _tripStatusSub?.cancel();
    _fallbackTripStatusSub?.cancel();
    _statusPollTimer?.cancel();
    _rideSaveTimer?.cancel();
    _saveStateTimer?.cancel();
    _riderLocSub?.cancel();
    _etaPulse.dispose();
    _arrivedDotPulse.dispose();
    _routeFadeTimer?.cancel();
    _startRidePhaseTimer?.cancel();
    _markerAnimTicker?.dispose();
    _cameraFollowTimer?.cancel();
    _tripStartedTimer?.cancel();
    _staleDriverTimer?.cancel();
    _labelAnimTimer?.cancel();
    _dropoffPopTimer?.cancel();
    _pickupPopOutTimer?.cancel();
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
  Timer? _routeFadeTimer;
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

  // Smooth car marker animation (Ticker-based for vsync 60fps)
  LatLng _markerLastPos = const LatLng(0, 0);
  LatLng _markerTargetPos = const LatLng(0, 0);
  Ticker? _markerAnimTicker;
  Duration _markerAnimStart = Duration.zero;
  bool _markerAnimNeedsRestart = false;
  bool _markAnimatingToTarget = false;
  double? _markerTargetBearing;
  static const int _markerAnimDurationMs = 1000; // 1s smooth glide between updates

  // Periodic state save timer
  Timer? _saveStateTimer;

  // Smooth camera follow (for real-time tracking after animation)
  final bool _shouldFollowDriver = true;
  Timer? _cameraFollowTimer;
  final bool _useNavCamera = true; // When true: follow driver at 45° pitch

  // Safety net: detect stale driver location (trip may have ended)
  Timer? _staleDriverTimer;
  Timer? _labelAnimTimer;
  Timer? _dropoffPopTimer;
  Timer? _pickupPopOutTimer;
  bool _completionCheckInFlight = false;

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
            ],
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
}
