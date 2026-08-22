import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../../map/web_map_view.dart';
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import '../../services/haptic_service.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../../models/lat_lng.dart';
import '../../config/mapbox_config.dart';
import '../../config/map_theme.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:http/http.dart' as http;
import '../../services/masked_call_service.dart';
import '../../config/page_transitions.dart';
import '../../services/api_service.dart';
import '../../services/navigation_service.dart';
import '../../widgets/verified_avatar.dart';
import '../../widgets/neu_style.dart';
import '../../widgets/offer_countdown_ring.dart';
import '../../widgets/route_connector_line.dart';
import '../../widgets/map/circular_pin_renderer.dart';
import '../../widgets/map/route_endpoint_markers.dart';
import '../../services/gps_service.dart';
import '../../services/heading_service.dart';
import '../../services/earnings_privacy.dart';
import '../../services/trip_firestore_service.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../../services/map_cache_service.dart';
import '../../utils/mapbox_safe.dart';
import '../../utils/route_splice.dart';
import '../../services/local_cache.dart';
import '../../services/firebase_auth_recovery.dart';
import '../../services/analytics_service.dart';
import '../../services/chat_service.dart';
import '../../widgets/offline_banner.dart';
import '../../widgets/gold_location_dot.dart';
import '../../widgets/static_map_snapshot.dart';
import '../../utils/smooth_motion.dart';
import '../../config/api_keys.dart';
import '../../config/map_styles.dart';
import '../../l10n/app_localizations.dart';
import '../../map/flat_map_projection.dart';
import '../../map/map_surface_coordinator.dart';
import '../../services/resilient_position_stream.dart';
import '../../utils/driver_location_settings.dart';
import '../chat_screen.dart';
import '../safety_screen.dart';
import '../../navigation/car_icon_loader.dart';
import 'driver_info_pages.dart';
import 'driver_earnings_screen.dart';
import 'driver_promos_screen.dart';
import 'driver_analytics_screen.dart';
import 'driver_inbox_screen.dart';
import '../home_screen.dart';
import 'driver_home_screen.dart';
import '../../services/map_launcher_service.dart';
import '../../services/preload_service.dart';
import '../../services/user_session.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../services/prefs_cache.dart';
import 'driver_trip_accept_screen.dart';
import 'trip_accepted_overlay.dart';
import 'scheduled_rides_screen.dart';
import '../../services/live_activity_service.dart';
import '../../services/network_service.dart';
import '../../services/notification_service.dart';
import '../../services/socket_service.dart';
import '../../services/background_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../../widgets/tier_badge.dart';
import '../../services/map_controller_cache.dart';

part 'driver_online_controller.dart';
part 'driver_online_map.dart';
part 'driver_online_widgets.dart';

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//  CRUISE DRIVER — ONLINE SCREEN
//  Uber Driver–style: Finding trips bar, trip request card,
//  real-time driver movement, smooth transitions, all backend
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class DriverOnlineScreen extends StatefulWidget {
  /// How many instances are mounted right now.
  ///
  /// The offer notification a warm app taps is drawn BY this screen (see the
  /// background branch of `_applyOffers`), so by construction this screen is
  /// already on the stack when that tap happens. Pushing another one buried
  /// the live instance — with its SSE, its poll and its map — under a second
  /// copy that had to stand everything up again, on a 45-second clock.
  static int mountedCount = 0;

  final LatLng? initialPos;
  final double initialHeading;
  final String? photoUrl;

  /// When true, the screen opens already showing the centred "Viaje
  /// cancelado" notice: the trip screen hands back a cancelled trip this
  /// way, because the notice lives here and a pushAndRemoveUntil cannot
  /// carry state over.
  final bool showCancelledNotice;

  /// The driver never went offline — they just stepped back to the home
  /// screen and are coming straight back. The whole go-online handshake
  /// (approval check + register online + the "GOING ONLINE" state) is for
  /// a driver who is offline; replaying it here made returning to a shift
  /// already in progress look like starting one, and told the backend to
  /// go online for a driver who never stopped being online.
  final bool resuming;

  /// The offer a notification tap was about, already fetched by the push
  /// handler in main.dart and handed over whole. The screen puts its card up
  /// on the first frame instead of waiting for its own stream to rediscover
  /// the ride: a tap can land forty seconds into a forty-five second window,
  /// and what is left of it is not enough for another round trip.
  final Map<String, dynamic>? deepLinkOffer;

  /// Injection bridge for notification taps that land while THIS screen is
  /// already on the stack. main.dart used to drop those taps ("the stream
  /// has it") — true on Android, false on iOS, where the stream is dead in
  /// the background: the driver opened Cruise to an empty "You're online"
  /// and watched the offer arrive seconds later by poll. The tap now sets
  /// this notifier and the mounted screen applies the offer at once.
  static final ValueNotifier<Map<String, dynamic>?> deepLinkOfferNotifier =
      ValueNotifier(null);

  /// A chained ride whose CURRENT trip was cancelled out from under it.
  ///
  /// The accept already committed on the backend (the trip screen locked it
  /// inside its countdown window), so it cannot simply be dropped with the
  /// trip: the cancel exits set this before building the fresh online
  /// screen, and the screen runs the normal accept flow on it with
  /// `alreadyAcceptedOnBackend: true` — the same route _handoffChainedOffer
  /// takes when a trip completes inside the online screen itself.
  static Map<String, dynamic>? chainedHandoffOffer;

  /// The removal half of the instant-tap flow (2026-08-09): the card goes
  /// up from the push payload before the server answers, and when the
  /// reconcile says the ride already went to the next driver, this is how
  /// the provisional card comes back down. Carries the offer id to remove.
  static final ValueNotifier<int?> removeOfferNotifier = ValueNotifier(null);

  const DriverOnlineScreen({
    super.key,
    this.initialPos,
    this.initialHeading = 0,
    this.photoUrl,
    this.showCancelledNotice = false,
    this.resuming = false,
    this.deepLinkOffer,
  });
  @override
  State<DriverOnlineScreen> createState() => _DriverOnlineScreenState();
}

/// Card accept animation states.
enum _OfferAcceptState { normal, routing }

enum _Phase {
  searching,
  rideRequest,
  enRouteToPickup,
  arrivedAtPickup,
  routeSummary, // Google Maps-style route overview before navigation
  inTrip,
  completed,
}

// How long the "viaje aceptado" celebration stays up before the trip screen
// takes over. Top-level, not a class static: part files can't use a class
// static inside a const expression without the compiler choking on iOS.
const Duration _acceptedOverlayDuration = Duration(seconds: 3);

// Brand colors (top-level for extension access)
const _gold = Color(0xFFD4A843);
const _goldLight = Color(0xFFF5D990);
const _navyRoute = Color(0xFF5BA3F5);
const _navyGlow = Color(0x405BA3F5);

// ── Auto-rerouting when the driver leaves the route ──
/// Perpendicular distance from the active polyline that counts as off-route.
const double _kOffRouteMeters = 45;

/// Back below this the driver counts as on-route again (hysteresis band, so
/// GPS noise around the threshold never flaps the state).
const double _kBackOnRouteMeters = 30;

/// How long the driver must stay off-route before a reroute fires — a red
/// light or a one-fix GPS spike never reaches this.
const int _kOffRouteSustainMs = 2500;

/// Minimum seconds between reroute fetches, so a prolonged detour does not
/// hammer the directions APIs.
const int _kRerouteCooldownSec = 10;

/// Cross-fade duration (ms) when a re-routed line replaces the old one.
const int _kRerouteFadeMs = 350;

class _DriverOnlineScreenState extends State<DriverOnlineScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver {
  void _setState(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  static final _usSuffixRe = RegExp(r',\s*United States$');
  static final _prSuffixRe = RegExp(r',\s*Puerto Rico$');

  /// Sync the search-pulse animation to the current phase.
  /// Call this immediately after any setState block that changes _phase.
  void _syncSearchPulse() {
    if (_phase == _Phase.searching) {
      if (!_searchPulse.isAnimating) _searchPulse.repeat();
    } else {
      if (_searchPulse.isAnimating) _searchPulse.stop();
    }
  }

  // ── Map ──
  final _mapKey = GlobalKey();
  mapbox.MapboxMap? _map;
  // Web only: GL JS controller handed over by WebMapView. Every camera,
  // route and pin call on this screen targets `_map`, which stays null in
  // the browser — without this handle the offer preview silently drew
  // nothing on localhost:8080.
  WebMapController? _webMap;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PointAnnotationManager?
      _pinAnnotMgr; // teardrop pins (icon-anchor: bottom)
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  // Active annotations
  mapbox.PointAnnotation? _carAnnot;
  mapbox.PointAnnotation? _goldDotAnnot;
  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;
  mapbox.PointAnnotation? _prevDriverAnnot;
  mapbox.PointAnnotation? _prevPickupAnnot;
  mapbox.PointAnnotation? _prevDropoffAnnot;
  mapbox.PolylineAnnotation? _routeAnnot;
  mapbox.PolylineAnnotation? _previewPickupAnnot;
  mapbox.PolylineAnnotation? _previewDropoffAnnot;
  LatLng? _pos;
  ResilientPositionStream? _posStream;
  final _gpsService = GpsService();
  DateTime _lastNavSetState = DateTime(0);
  DateTime _lastBackendLocSend = DateTime(0);
  bool _lastStyleDark = true;
  // One-shot re-apply of the navy/gold theme after onMapCreated. On a fresh
  // install onStyleLoaded can fire before `_map` is stored (or not reach the
  // listener at all), and the screen stays on the raw grey dark-v11.
  Timer? _navyGoldRetryTimer;
  // Monotonically incremented every time onMapCreated fires. Guards against
  // stale annotation refs surviving a PlatformView recreation.
  int _mapGeneration = 0;
  // Cache: offerId → Future<String> static map URL (with real routed polyline)
  final Map<String, Future<String>> _offerMapUrlCache = {};

  void _animateToPosition(
    LatLng pos, {
    double zoom = 15.5,
    double bearing = 0,
    double tilt = 0,
  }) {
    // Guarded, and gated on the surface still being ours.
    //
    // This was a bare `_map?.flyTo(...)`: no mounted check, no catch, and
    // the returned Future dropped on the floor. `_map` is only null once
    // _releaseMapSurface has run, so between the coordinator revoking us
    // and that teardown finishing — and again while a remount is in
    // flight — the handle is non-null and points at a native view that is
    // going away. Recentring in that window called into a dead Mapbox
    // object, which is not a Dart exception to be caught: it takes the
    // process down. Tapping recenter closed the app.
    if (kIsWeb) {
      // GL JS has no dead-native-view hazard; a stale handle simply draws
      // on the map that is still on screen.
      _webMap?.flyTo(
        lng: pos.longitude,
        lat: pos.latitude,
        zoom: zoom,
        bearing: bearing,
        pitch: tilt,
        durationMs: _kRecenterFlightMs,
      );
      return;
    }
    if (!mounted || !_mapMounted) return;
    final map = _map;
    if (map == null) return;
    try {
      map
          .flyTo(
        mapbox.CameraOptions(
          center: mapbox.Point(
              coordinates: mapbox.Position(pos.longitude, pos.latitude)),
          zoom: zoom,
          bearing: bearing,
          pitch: tilt,
        ),
        mapbox.MapAnimationOptions(duration: _kRecenterFlightMs),
      )
          // The native side rejects asynchronously when the view is torn
          // down mid-animation; the try/catch only sees synchronous throws.
          .catchError((Object e) {
        debugPrint('[DriverOnline] flyTo rejected: $e');
      });
    } catch (e) {
      debugPrint('[DriverOnline] flyTo failed: $e');
    }
  }

  void _moveToLatLng(LatLng pos) {
    _animateToPosition(pos);
  }

  // â”€â”€ Trip â”€â”€
  _Phase _phase = _Phase.searching;
  int? _tripId;
  int? _driverId;
  int? _currentOfferId;

  // â”€â”€ Pending ride offers (stacked cards, Spark-style) â”€â”€
  List<Map<String, dynamic>> _pendingOffers = [];
  // _offersExpanded removed — cards always visible via PageView

  /// True once the "you are online" indicators are up — the iOS Live
  /// Activity and the persistent notification. Both used to hang off the
  /// `.then` of the go-online network call, so any path that did not reach
  /// it left the driver with nothing on either platform.
  bool _presenceShown = false;

  /// What the iOS Live Activity is currently showing: `offer:<id>`,
  /// `on_trip`, `online`, or null while there is no activity at all.
  /// Compared by _syncOfferLiveActivity against the state derived from
  /// [_pendingOffers] and [_phase], so the island follows from those two
  /// rather than from each path remembering to update it.
  String? _islandState;

  /// A ride accepted while still driving the current trip (chaining) —
  /// it starts when this trip wraps up. See _acceptChainedOffer.
  Map<String, dynamic>? _chainedNextOffer;

  // ── Route preview for a tapped offer ──
  Map<String, dynamic>? _previewingOffer;

  /// True while a ride offer card is on screen. The top row hides behind
  /// this, and the X that replaces it appears on the same condition, so
  /// the two can never both be showing or both be gone.
  ///
  /// Any phase, not just searching: outside searching the only offers
  /// that can be pending are chained ones (the controllers filter), and
  /// their card shows over the trip UI.
  bool get _offerOnScreen => _pendingOffers.isNotEmpty;
  bool _offerRouteShown = false; // true after route draw completes
  AnimationController? _routePulseCtrl;
  bool _isPollingOffers = false;

  // ── Pulse animation on card tap ──
  AnimationController? _pulseCtrl;
  Animation<double>? _pulseAnim;
  bool _isCardAnimating = false;

  // ── Scheduled rides badge ──
  int _scheduledAvailCount = 0;

  /// Notifications the driver has not opened. This is what the bell's
  /// badge counts — it used to show _scheduledAvailCount, so the number on
  /// the bell was how many reservations were up for grabs, not how many
  /// things were waiting to be read. Home already counted it this way.
  int _unreadCount = 0;
  int _prevScheduledCount = 0;
  Timer? _scheduledPollTimer;
  AnimationController? _scheduledBounceCtrl;
  Animation<double>? _scheduledBounceAnim;
  bool _showScheduledToast = false;
  String? _animatingOfferId; // which card is pulsing
  bool _offerDetailsVisible = false;

  // ── Reject slide-down animation ──
  String? _rejectingOfferId;
  AnimationController? _rejectSlideCtrl;

  // ── "Viaje aceptado" celebration ──
  // Rendered as an overlay on THIS screen's map. It used to be
  // TripAcceptedScreen, a pushed route carrying its own MapWidget, which
  // meant every accept briefly held two native Mapbox surfaces alive at
  // once. Non-null while the celebration is on screen.
  _AcceptedOverlayData? _acceptedOverlay;

  // ── "Viaje cancelado" notice ──
  // Centred, semi-dark, never tappable: the driver is already back to
  // searching the moment it appears. ~5 s up, then a fluid fade.
  bool _cancelledNoticeVisible = false;
  Timer? _cancelledNoticeTimer;
  AnimationController? _cancelledNoticeCtrl;
  Animation<double>? _cancelledNoticeFade;

  // ── Accept card animation state ──
  _OfferAcceptState _offerAcceptState = _OfferAcceptState.normal;
  String? _acceptingCardId;
  final Set<String> _tappedCardIds = {};
  final Set<int> _rejectedOfferIds = {}; // locally rejected — filter from polls
  String? _lastAutoTriggeredOfferId; // prevent duplicate auto-trigger

  /// Where the previewed offer's driver leg was last fetched from, and
  /// when. The baseline is set when the preview opens; the refresh lives
  /// in driver_online_map.dart but fields cannot, because these files are
  /// extensions of the State, not mixins.
  LatLng? _offerRouteAnchor;
  DateTime _lastOfferRouteFetch = DateTime(0);
  bool _offerRouteFetchBusy = false;

  /// When each on-screen offer was first shown.
  ///
  /// SSE and the poll do not always agree for a moment: one of them answers
  /// without an offer the other has already sent, and taking the card away
  /// on that single answer is what made it flash up and vanish — then come
  /// back with a fresh twenty-second ring, so it never timed out. An offer
  /// is held through those disagreements until its countdown window closes;
  /// what removes it at the end is the ring firing, a real reject.
  final Map<String, DateTime> _offerFirstSeenAt = {};

  /// Real laid-out height of each offer card, reported by the card itself.
  ///
  /// The PageView around the cards needs a number up front, so it starts at
  /// the `_offerCardHeight` estimate and animates to the measured value a
  /// frame later. Hand-computed heights drift a few points off the real
  /// font — on web a few points per row — and every point lands as an
  /// overflow stripe across the addresses and the Accept button.
  final Map<String, double> _offerCardHeights = {};
  bool _isAcceptPressed = false;

  // ── Smooth route draw ──
  List<LatLng> _fullSegOne = [];
  List<LatLng> _fullSegTwo = [];
  Ticker? _routeDrawTicker;
  Ticker? _pinPopTicker;

  // ── Cinematic camera tilt/bearing for offer preview ──
  AnimationController? _offerTiltCtrl;
  Animation<double>? _offerTiltAnim;
  AnimationController? _offerBearingCtrl;
  Animation<double>? _offerBearingAnim;
  double _offerRandomBearing = 0;

  // ── Pre-fetched route cache (offerId → segments) ──
  final Map<String, _CachedOfferRoute> _routeCache = {};

  // ── Reverse-geocoded pickup addresses for generic labels ──
  final Map<String, String> _resolvedAddressCache = {};

  // â”€â”€ Request data (for active trip after acceptance) â”€â”€
  Timer? _pollT;
  StreamSubscription<List<Map<String, dynamic>>>? _offerSseSub;
  // Top-level Firestore watcher that fires when the active trip is
  // cancelled externally (dispatch, guardian ghost cleanup, auto-cancel).
  // Required because DriverTripAcceptScreen usually leaves via
  // pushAndRemoveUntil instead of popping a result, so the route future
  // _acceptOffer awaits resolves with null and the controller would never
  // learn of the cancel — leaving the trip visually active.
  // See _startActiveTripCancelWatcher().
  StreamSubscription<DocumentSnapshot<Map<String, dynamic>>>?
      _activeTripCancelWatcher;
  int? _watchedCancelTripId;
  Timer? _sseReconnectTimer; // retries SSE after drop
  bool _sseActive = false;
  // C4 fix: monotonic generation counter for SSE streams. Any event arriving
  // from a stream whose generation no longer matches `_currentSseGeneration`
  // is dropped. This prevents two concurrent streams (from accidental
  // reconnects) from both delivering the same offer.
  int _currentSseGeneration = 0;
  // C5 fix: offers we have already accepted (or are in the process of
  // accepting). Prevents double-accept when an offer is delivered twice by
  // the SSE layer or re-emitted by a stale stream.
  final Set<int> _acceptedOfferIds = {};
  VoidCallback? _networkListener; // NetworkService online/offline callback
  String _riderName = '';
  String _riderInit = '';
  String _riderPhotoUrl = '';
  String _riderPhone = '';
  String _riderId = '';
  String _pickupAddr = '';
  String _dropoffAddr = '';

  /// Free text the passenger left when booking (Trip.notes). Carried through
  /// the accept so DriverTripAcceptScreen can show it — it used to stop here,
  /// so the instructions card on that screen could never appear on this path.
  String _riderNotes = '';
  double _fare = 0;
  double _distToPickup = 0;
  int _etaToPickup = 0; // ignore: unused_field
  double _tripDist = 0;
  int _tripEta = 0; // ignore: unused_field
  String _vehicleType = '';
  LatLng _pickupLL = const LatLng(0, 0);
  LatLng _dropoffLL = const LatLng(0, 0);

  // â”€â”€ Navigation â”€â”€
  double _navDist = 0;
  int _navEta = 0;
  String _navInstruct = '';
  double _navProgress = 0;
  List<LatLng> _routePts = [];

  /// The same route as [_routePts] but with its head left alone.
  ///
  /// _trimRouteBehindDriver rewrites `_routePts[0]` to the driver's own
  /// position on every fix so the line starts exactly under the car. That
  /// makes `_routePts` useless for measuring how far off-route the driver
  /// is — the polyline passes through them by construction, so the distance
  /// is always ~0 and no deviation would ever be detected. This copy keeps
  /// the road geometry: same length, same vertices, index-aligned (both get
  /// the identical sublist when the head is trimmed), only [0] differs.
  List<LatLng> _plannedRoutePts = [];
  Timer? _navTimer;
  bool _isPickupSummary = false;

  // â”€â”€ Session â”€â”€
  double _earnings = 0;

  /// Which local day [_earnings] belongs to, as yyyymmdd.
  ///
  /// Today's total is only ever allowed to climb, so that a fare added the
  /// instant a trip ends is not wiped by the next poll arriving before the
  /// server has counted it. That guard has no idea when the day ends, so at
  /// midnight it kept yesterday's figure: the server started answering 0 for
  /// today and 0 is never greater. Stamping the day is what tells the guard
  /// the difference between "stale, ignore it" and "new day, start over".
  int _earningsDay = 0;
  int _trips = 0;
  Duration _online = Duration.zero;
  Timer? _clock;

  // -- Driver smooth animation --
  // Constant-velocity Google-Maps-style smoother. Set the latest GPS fix
  // via _motion.setTarget() in _smoothMoveTo(), then on every tick the
  // smoother advances _pos at the measured velocity. Feels like real
  // navigation instead of the old exponential "catch-up-then-stall" lerp.
  late AnimationController _driverAnim;
  Ticker? _smoothTicker;
  Duration _lastTickElapsed = Duration.zero;
  final SmoothMotion _motion = SmoothMotion();
  double _heading = 0;
  double _smoothedBearing = 0;

  /// Where the phone is pointing, from the compass — see [HeadingService].
  ///
  /// _smoothedBearing above is fed from this now instead of straight from
  /// the GPS course, so the arrow keeps turning while the car is stopped.
  final HeadingService _headingSource = HeadingService();
  StreamSubscription<double>? _headingSub;
  Uint8List? _arrowIconBytes;

  // -- 3D nav car bytes --
  Uint8List? _navCarIconBytes;

  // -- Multi-angle 3D car sprites (8 directions) --
  List<Uint8List>? _navCarSprites;
  double _cameraBearing = 0;
  final int _lastSpriteIdx = -1;

  // -- Vehicle-based markers (asset images) --
  Uint8List? _suvIconBytes;
  Uint8List? _sedanIconBytes;
  final String _activeVehicleAsset = 'suburban';

  // -- Golden animated dot --
  final GoldLocationDot _goldDot = GoldLocationDot(heading: true);
  Uint8List? _goldPinBytes;
  bool _dotPopDone = false; // true after first-appearance pop completes
  double _dotPopScale = 0.0; // 0→1.15→1.0 during pop, then 1.0
  // Route-snap state (see _snapToRoute in driver_online_map.dart): hysteresis
  // on the snap boundary and continuity on the polyline segment, so the
  // marker never flickers between the lane and raw GPS.
  bool _routeSnapActive = false;
  int _snapSegIdx = -1;
  // Re-asserts the dot annotation while the smooth ticker is parked (driver
  // stationary). Without it a dot that failed to appear — or whose final
  // pop-scale flush was dropped mid-IPC — stays wrong until the driver moves.
  Timer? _dotWatchdog;
  bool _smoothTickerStarted = false; // first start is deferred, restarts aren't
  bool _annotUpdateBusy =
      false; // prevents overlapping annotation update() IPC calls

  /// True once the native gold dot has been flushed to invisible, so the
  /// per-frame path can stop re-sending the same hide.
  bool _goldDotHidden = false;

  /// True only on the deliberate go-offline exit, so dispose() can tell it
  /// apart from every other way this screen is left. See dispose().
  bool _leavingOffline = false;

  /// A camera write is crossing the platform channel. See _writeCamera.
  bool _camWriteBusy = false;

  /// The newest camera frame waiting for the channel. See _writeCamera —
  /// coalescing keeps this to one pending frame, never a queue. Lives here
  /// and not in the controller extension because extensions cannot declare
  /// instance fields (web build caught it).
  mapbox.CameraOptions? _pendingCamWrite;

  /// The camera as Mapbox last reported it, pushed to us by
  /// onCameraChangeListener so the projection never has to ask for it.
  mapbox.CameraState? _onlineCamState;

  /// Size of the map box, measured from its own layout.
  Size? _onlineMapSize;

  /// Ticks once per animation frame so the Flutter marker repaints with the
  /// motion. The screen's own setState is throttled to ~15 fps to keep the
  /// panels responsive — right for panels, far too slow for an arrow
  /// turning through a bend. This repaints only the marker.
  final ValueNotifier<int> _markerFrame = ValueNotifier<int>(0);

  // ── Diagnóstico de movimiento (panel oculto; long-press en la zona del
  // chip de earnings). Los 4 eslabones de la cadena por segundo: fixes
  // GPS, ticks del motor, escrituras de cámara, flushes de anotación. El
  // número lento señala el eslabón roto: GPS ~1 = feed del teléfono; tick
  // bajo = ticker muerto; cam/anot bajas con tick alto = canal nativo.
  int _diagFixes = 0, _diagTicks = 0, _diagCamWrites = 0, _diagAnnotUpdates = 0;
  final ValueNotifier<String> motionDiag = ValueNotifier<String>('');
  bool motionDiagVisible = false;
  Timer? _diagTimer;
  LatLng? _diagLastFixLL;
  DateTime? _diagLastFixAt;
  double _diagLastFixDistM = 0;
  int _diagLastFixDtMs = 0;

  bool _annotCreateBusy =
      false; // prevents parallel create/delete (stricter than update)
  bool _isClearingAnnotations = false; // prevents create during clear
  // Monotonically incremented generation counter captured when each
  // annotation is created. If _mapGeneration has moved on, the annotation
  // is stale (native map was recreated) and must NOT be touched.
  int _goldDotAnnotGen = 0;
  int _carAnnotGen = 0;

  // -- Turn-by-turn navigation --
  final NavigationService _navService = NavigationService();
  NavRoute? _currentNavRoute;
  NavigationState? _navState;
  bool _isRerouting = false;
  int _rerouteCount = 0;
  DateTime? _lastRerouteTime;

  /// First moment the smoothed position was seen beyond [_kOffRouteMeters]
  /// from the active polyline; null while on-route. Sustained presence past
  /// [_kOffRouteSustainMs] is what fires the reroute — one noisy fix never
  /// does.
  DateTime? _offRouteSince;

  /// Drives the reroute cross-fade between the old and new route lines.
  Timer? _rerouteFadeTimer;
  // â”€â”€ UI animations â”€â”€
  // Deferred to post-frame callback — nullable to guard early dispose.
  AnimationController? _reqCtrl;
  Animation<Offset>? _reqSlide; // ignore: unused_field
  AnimationController? _doneCtrl;
  Animation<double>? _doneScale;
  late AnimationController _searchPulse;
  late Animation<double> _searchPulseVal;

  // ── Entrance choreography (home → online unified transition) ──
  // Drives the staggered fade/slide of the top pill, side FABs and the
  // "Finding trips" bar when the screen first appears. Purely visual.
  late AnimationController _enterCtrl;
  late Animation<double> _enterTop;
  late Animation<double> _enterBar;
  final List<Animation<double>> _enterFabs = [];

  // First-tick zoom ease: camera opens at zoom 16 (same as home) and
  // glides to the working 15.5 over ~750ms — no zoom "pop" on entry.
  int? _zoomEaseStartMs;
  bool _zoomEaseDone = false;

  // â”€â”€ Slide confirm â”€â”€
  double _slideVal = 0;
  bool _slid = false;
  int _stars = 5;

  // -- Camera follow mode --
  bool _cameraFollowing = true;

  /// Hands the overlay back to centred mode once a recentre has landed.
  /// See _recenterCamera — set while the camera is in flight, cancelled if
  /// the driver takes hold of the map again.
  Timer? _followResumeTimer;

  /// When the driver last dragged the map. The auto-recentre is scheduled
  /// from this, so it lands ten seconds after they stop, not ten seconds
  /// after they start.
  DateTime? _lastMapPanAt;
  Timer? _reFollowTimer;

  // â”€â”€ Draggable panel â”€â”€
  bool _panelOpen = false;
  double _panelFrac = 0.0; // 0 = collapsed pill, 1 = fully expanded
  AnimationController? _panelAnimCtrl;
  Animation<double>? _panelAnim;

  // ── Finding trips bar visibility ──
  bool _hideFindingBar = false;

  // ── Offer PageView swipe state ──
  final _offerPageCtrl = PageController(viewportFraction: 0.92);
  int _currentOfferIndex = 0;
  final Set<String> _expandedOfferIds = {};

  // -- Driver profile photo --
  String? _driverPhotoUrl;

  // -- Earnings pill swipe --
  double _weeklyEarnings = 0;
  double _lastTripEarnings = 0;
  int _earningsPage = 1; // 0=weekly, 1=today, 2=last trip
  double _currentSpeedMph = 0.0;

  // -- Earnings refresh timer --
  Timer? _earningsRefreshTimer;
  // Track previous amounts for smooth TweenAnimationBuilder transitions
  double _prevEarnings = 0;
  double _prevWeeklyEarnings = 0;
  double _monthlyEarnings = 0;
  double _prevMonthlyEarnings = 0;

  // ── What the expanded panel shows, same figures as the home sheet ──
  int _tripsToday = 0;
  double _hoursToday = 0;

  /// 24 buckets, local hours. Empty until the first fetch lands.
  List<double> _hourlySeries = const [];

  /// Seven days, oldest first, paired with [_daySeriesLabels].
  List<double> _daySeries = const [];
  List<String> _daySeriesLabels = const [];
  bool _panelWeekTab = false;

  /// The searching label alternates between two lines every five seconds.
  /// 0 = "Finding trips", 1 = "You're online".
  /// The panel body: false = earnings, true = the reserved-rides view.
  /// Reset to earnings every time the panel closes.
  bool _panelShowsReserve = false;

  int _statusLine = 0;
  Timer? _statusLineTimer;
  double _prevLastTripEarnings = 0;

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  LIFECYCLE
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  /// Bounce non-driver users back to the rider home screen.
  void _enforceDriverRole() {
    // The browser build has no login, so the stored mode is never 'driver'
    // and both driver screens used to eject to the rider home a few
    // milliseconds after mounting — two of the four screens worth reviewing,
    // unreachable.
    if (kIsWeb) return;

    UserSession.getMode().then((mode) {
      if (mode != 'driver' && mounted) {
        Navigator.of(context, rootNavigator: true).pushAndRemoveUntil(
          fadeThroughRoute(const HomeScreen()),
          (_) => false,
        );
      }
    });
  }

  @override
  void initState() {
    super.initState();
    DriverOnlineScreen.mountedCount++;
    _enforceDriverRole();
    WidgetsBinding.instance.addObserver(this);
    _startMotionDiag();
    // The trip screen handed us a cancelled trip: show the notice as soon
    // as the first frame is down, not from inside initState.
    if (widget.showCancelledNotice) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showCancelledNotice();
      });
    }
    // The offer the driver tapped in the notification, down the same path SSE
    // and the poll use: the card, the alert and the route preview then behave
    // exactly as if the stream had delivered it, and the offer the tap was
    // about is the one on screen — not whatever dispatch has by the time this
    // screen gets around to asking.
    final linked = widget.deepLinkOffer;
    if (linked != null) {
      // After the transition, not on the first frame.
      //
      // _applyOffers treats this as a new leading offer, which means
      // playOfferSound() plus three heavyImpact haptics — four platform-
      // channel round-trips. Fired from the first post-frame callback they
      // land while the route transition (420 ms) and this screen's Mapbox
      // PlatformView are both competing for the platform thread, which is
      // the exact stall that got the go-online chime removed three times.
      //
      // Half a second is invisible against a 45-second offer window and it
      // is the whole difference between the card appearing and the app
      // locking up as the driver opens it.
      Future.delayed(const Duration(milliseconds: 500), () {
        if (mounted) _applyOffers([linked]);
      });
    }
    // Taps that arrive while this screen is already alive (the iOS case —
    // the SSE stream is dead in the background, so without this the offer
    // only shows up when the poll happens to run).
    DriverOnlineScreen.deepLinkOfferNotifier.addListener(_applyInjectedOffer);
    DriverOnlineScreen.removeOfferNotifier
        .addListener(_applyRemoveInjectedOffer);
    // A chained ride handed over by a cancelled trip: already locked on the
    // backend, so it runs the accept flow without re-locking — the same
    // route _handoffChainedOffer takes. Consumed once, never replayed.
    final chainedHandoff = DriverOnlineScreen.chainedHandoffOffer;
    if (chainedHandoff != null) {
      DriverOnlineScreen.chainedHandoffOffer = null;
      Future.delayed(const Duration(milliseconds: 600), () {
        if (mounted) {
          _acceptOffer(chainedHandoff, alreadyAcceptedOnBackend: true);
        }
      });
    }
    // Once, here — not in the resume branch, which would stack another
    // listener on every return from the background.
    EarningsPrivacy.load();
    EarningsPrivacy.hidden.addListener(_onEarningsPrivacyChanged);
    // Apply initial position from home screen (avoids white flash)
    if (widget.initialPos != null) {
      _pos = widget.initialPos!;
      _heading = widget.initialHeading;
    }

    // ── Essential controllers needed for the first build frame ──
    _driverAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    // Continuous 60fps ticker for ultra-smooth exponential decay movement.
    // Started lazily on first GPS update (_smoothMoveTo) to avoid burning CPU
    // before any position is available.
    _smoothTicker = createTicker(_onSmoothTick);

    _searchPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 3000),
    );
    // Start search pulse immediately — the gold border animation on the
    // "Finding trips" bar. This is cheap (just a CustomPaint) and gives
    // instant visual feedback that the driver is online and searching.
    _searchPulse.repeat();
    // Swap the searching label every five seconds. A single line that never
    // changes stops being read after the first glance; two that trade places
    // keep saying "this is live" without the driver having to look for a
    // spinner.
    //
    // Only while searching, for the same reason _syncSearchPulse stops the
    // border pulse off that phase: during a trip this label is not on
    // screen, and an unconditional setState every five seconds rebuilt the
    // whole screen — live map included — to change something nobody could
    // see.
    _statusLineTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || _phase != _Phase.searching) return;
      _setState(() => _statusLine = _statusLine == 0 ? 1 : 0);
    });
    _searchPulseVal = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _searchPulse, curve: Curves.linear),
    );

    // ── Entrance choreography — staggered fade/slide of chrome UI ──
    _enterCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 850),
    );
    _enterTop = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.0, 0.55, curve: Curves.easeOutCubic),
    );
    _enterBar = CurvedAnimation(
      parent: _enterCtrl,
      curve: const Interval(0.30, 1.0, curve: Curves.easeOutBack),
    );
    for (var i = 0; i < 4; i++) {
      _enterFabs.add(
        CurvedAnimation(
          parent: _enterCtrl,
          curve: Interval(
            0.15 + 0.08 * i,
            0.60 + 0.08 * i,
            curve: Curves.easeOutCubic,
          ),
        ),
      );
    }

    // Show offer details immediately — no delay
    _offerDetailsVisible = true;

    // ── Deferred controllers — not needed until an offer arrives ──
    // Creating these after the first frame avoids jank during the
    // 400ms fade+scale transition animation.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;

      // Entrance choreography starts once the first frame is on screen.
      _enterCtrl.forward();

      _reqCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 450),
      );
      _reqSlide = Tween<Offset>(
        begin: const Offset(0, 1),
        end: Offset.zero,
      ).animate(CurvedAnimation(parent: _reqCtrl!, curve: Curves.easeOutCubic));

      _doneCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      );
      _doneScale = Tween<double>(
        begin: 0.0,
        end: 1.0,
      ).animate(CurvedAnimation(parent: _doneCtrl!, curve: Curves.elasticOut));

      // Pulse + ripple for offer card tap (tap-down scale)
      _pulseCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 100),
      );
      _pulseAnim = Tween<double>(begin: 1.0, end: 0.97).animate(
        CurvedAnimation(parent: _pulseCtrl!, curve: Curves.easeOut),
      );

      // Reject slide-down animation
      _rejectSlideCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 300),
      );

      // Scheduled badge bounce animation
      _scheduledBounceCtrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      );
      _scheduledBounceAnim = TweenSequence<double>([
        TweenSequenceItem(
            tween: Tween(begin: 1.0, end: 1.25)
                .chain(CurveTween(curve: Curves.easeOut)),
            weight: 30),
        TweenSequenceItem(
            tween: Tween(begin: 1.25, end: 0.9)
                .chain(CurveTween(curve: Curves.easeInOut)),
            weight: 25),
        TweenSequenceItem(
            tween: Tween(begin: 0.9, end: 1.1)
                .chain(CurveTween(curve: Curves.easeInOut)),
            weight: 25),
        TweenSequenceItem(
            tween: Tween(begin: 1.1, end: 1.0)
                .chain(CurveTween(curve: Curves.easeOut)),
            weight: 20),
      ]).animate(_scheduledBounceCtrl!);
    });

    _boot();

    // Mount the MapWidget as soon as the surface is ours. It used to be set
    // true right here — but this screen is entered from the home screen,
    // which still has its own map up, and from the trip screen, which is
    // tearing one down. Claiming through the coordinator keeps the tiles
    // essentially as immediate (the home map releases in a couple of
    // frames) without ever overlapping the map we are replacing.
    // And not until the route transition has finished.
    //
    // Claiming the surface tears the home map down and stands a native
    // PlatformView up, and both of those run on the UI thread. Doing it
    // while the 420 ms push is mid-flight is what made Go Online hitch for
    // a few frames right as the new screen slid in. Waiting for the
    // animation to settle costs nothing the driver can perceive — the map
    // was going to take longer than that to load its tiles anyway — and
    // the transition itself stays smooth.
    //
    // Waiting for the transition is an optimisation. It must never be the
    // only way in.
    //
    // This used to hang the claim off `AnimationStatus.completed` and
    // nothing else. That status is not guaranteed to arrive: interrupt the
    // push — a back swipe part-way, a second route on top, a pop and a
    // re-push — and the animation goes forward, reverse, dismissed, and
    // never completes. The listener then sits there for the life of the
    // screen and _mapMounted stays false, which is a driver looking at a
    // black rectangle with a spinner on it for the whole shift while the
    // app keeps telling them they are online.
    //
    // So the deadline below is what actually guarantees the map, and the
    // animation is only allowed to make it happen sooner. Whichever fires
    // first wins; claim() is idempotent.
    bool claimed = false;
    void claim() {
      if (claimed || !mounted) return;
      claimed = true;
      unawaited(_acquireMapSurface().then((_) {
        if (mounted && !_mapMounted) _setState(() => _mapMounted = true);
        _armOnlineChime();
      }).catchError((Object e) {
        // Even a failed handoff must not leave the screen mapless — the
        // coordinator already serialises us, so mounting here is the same
        // risk the timeout path takes, against a certain blank map.
        debugPrint('[DriverOnline] map surface claim failed: $e');
        if (mounted && !_mapMounted) _setState(() => _mapMounted = true);
        _armOnlineChime();
      }));
    }

    // The deadline. 420 ms of push plus a frame of slack.
    Timer(const Duration(milliseconds: 520), claim);

    // Post-frame, because this runs from initState and ModalRoute.of walks
    // the inherited widgets — which is not allowed until the first build
    // has happened.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final anim = ModalRoute.of(context)?.animation;
      if (anim == null || anim.isCompleted) {
        claim();
        return;
      }
      void onStatus(AnimationStatus status) {
        if (status != AnimationStatus.completed) return;
        anim.removeStatusListener(onStatus);
        claim();
      }

      anim.addStatusListener(onStatus);
    });
  }

  bool _appInForeground = true;

  // ── Defer Mapbox mount to eliminate the ~1s entry freeze ──
  // Mounting MapWidget creates a native PlatformView (SurfaceView on
  // Android, native view on iOS) synchronously, which blocks the UI
  // thread for several hundred ms. If that happens during the 400ms
  // page transition, the driver sees a hard freeze the moment they
  // tap "Go Online". We render a dark placeholder during the transition
  // and mount the real map a few frames after it ends.
  bool _mapMounted = false;

  // ── Go-online chime ──
  Timer? _onlineChimeTimer;
  bool _onlineChimeFired = false;

  /// Sound the go-online confirmation, once the map surface is ours.
  ///
  /// It plays from this screen and not from the GO button on purpose. Three
  /// rounds fired it over there — after the push, deferred 300 ms, then as
  /// resume() on a pre-warmed player — and all three stalled, because the
  /// audio engine does its work on the platform thread and that is the thread
  /// running the route transition and standing this screen's Mapbox
  /// PlatformView up. The note where the button used to call it is worth
  /// reading before moving this.
  ///
  /// Called from the surface claim, which resolves after the transition has
  /// ended; the delay then lets the PlatformView come up on the frame the
  /// _mapMounted flip schedules. A confirmation is allowed to be late — the
  /// haptic already answered the tap the instant it happened — it is not
  /// allowed to be early.
  ///
  /// Nothing on the resume path: the driver never went offline, so there is
  /// no state change to confirm, and returning to a shift already running is
  /// precisely when a waiting offer sounds its own cue a second later.
  ///
  /// Idempotent. Both branches of the claim call it, the claim can be raced
  /// by its own deadline, and the chime is one per go-online.
  void _armOnlineChime() {
    if (!mounted ||
        widget.resuming ||
        // Arriving by tapping an offer notification. The driver already knows
        // they are online — they are here to answer a ride, and the offer
        // card plays its own cue. A "you are online" chime on top of that is
        // the app talking over itself at the one moment attention matters.
        widget.deepLinkOffer != null ||
        _onlineChimeFired ||
        _onlineChimeTimer != null) {
      return;
    }
    // 1200 ms, not 600. The timer is armed in the same microtask that flips
    // `_mapMounted`, so it starts BEFORE the MapWidget builds — and mounting
    // that widget creates a native PlatformView synchronously, blocking the
    // UI thread for several hundred ms (see the comment on _mapMounted). At
    // 600 ms the chime could land inside exactly that window on a slow phone,
    // which is the stall this whole approach exists to avoid. Nobody notices
    // half a second on a confirmation tone; everybody notices a freeze.
    _onlineChimeTimer = Timer(const Duration(milliseconds: 1200), () {
      _onlineChimeTimer = null;
      // An offer that arrived in the meantime has taken the screen over and
      // is playing its own cue; the driver does not need to be told they are
      // online while a ride request is on top of it.
      if (!mounted || _onlineChimeFired || _phase != _Phase.searching) return;
      _onlineChimeFired = true;
      NotificationService.playOnlineChime();
    });
  }

  /// The offer a notification tap is about, arriving while this screen is
  /// already mounted. Consumed once and cleared, so a stale offer cannot
  /// replay on a later rebuild.
  void _applyInjectedOffer() {
    final offer = DriverOnlineScreen.deepLinkOfferNotifier.value;
    if (offer == null) return;
    DriverOnlineScreen.deepLinkOfferNotifier.value = null;
    if (!mounted) return;
    // The route preview's animation flag can be stuck true from a sequence
    // the background paused mid-stroke — and while it is true every route
    // draw is vetoed, so the injected card would come up WITHOUT its route.
    // A tap is an explicit restart: clear it.
    _isCardAnimating = false;
    _applyOffers([offer]);
  }

  /// The reconcile half of the instant-tap flow: the card went up from the
  /// push payload, and the server now says the ride is no longer pending —
  /// take it down the same way the expiry pass would, unless the driver
  /// already beat the reconcile to the Accept button.
  void _applyRemoveInjectedOffer() {
    final oid = DriverOnlineScreen.removeOfferNotifier.value;
    if (oid == null) return;
    DriverOnlineScreen.removeOfferNotifier.value = null;
    if (!mounted) return;
    // An accept in flight (or already committed) outranks the reconcile:
    // the offer leaves the pending list BECAUSE the driver took it.
    if (_acceptedOfferIds.contains(oid) ||
        _offerAcceptState != _OfferAcceptState.normal) {
      return;
    }
    _offerFirstSeenAt.remove(oid.toString());
    // Filtered out of every later _applyOffers, so the next poll cannot
    // resurrect a card the server just told us is gone.
    _rejectedOfferIds.add(oid);
    _setState(() {
      _pendingOffers.removeWhere(
          (o) => (o['offer_id'] as num?)?.toInt() == oid);
      if (_pendingOffers.isEmpty) _hideFindingBar = false;
    });
    final previewing = _previewingOffer;
    if (previewing != null &&
        (previewing['offer_id'] as num?)?.toInt() == oid) {
      _previewingOffer = null;
      _offerRouteShown = false;
      _fullSegOne = [];
      _fullSegTwo = [];
      unawaited(_clearAllAnnotations().catchError((_) {}));
    }
    _syncOfferLiveActivity();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!mounted) return;
    if (state == AppLifecycleState.paused) {
      _appInForeground = false;
      // Keep SSE alive in background so driver still receives offers.
      // Only cancel polling timer (REST fallback) — SSE is more efficient.
      _pollT?.cancel();
      _clock?.cancel();
      _earningsRefreshTimer?.cancel();
      _dotWatchdog?.cancel();
      _goldDot.dispose();
      // The compass goes with it. There is no marker to turn behind a locked
      // screen, and the magnetometer is not free. _boot's _startHeadingSource
      // runs again on resume.
      _headingSource.stop();
      // Start background heartbeat to keep driver "online" in backend
      _startBackgroundHeartbeat();
      // Start Android foreground service so the OS doesn't kill us
      DriverBackgroundService().start();
    } else if (state == AppLifecycleState.resumed) {
      _appInForeground = true;
      // Before anything else: the location stream may not have survived the
      // background. Everything on this screen — the dot, the heartbeat that
      // keeps the driver online, the offers that depend on being findable —
      // is downstream of it.
      _posStream?.onAppResumed();
      _stopBackgroundHeartbeat();
      DriverBackgroundService().stop();
      // Reset sound guards so offer sounds play correctly after app resumes
      NotificationService.resetSoundGuards();
      // The offer route is redrawn AFTER the annotation wipe below, not
      // here. Clearing the latch at this point looked right and was the
      // reason the route vanished on every return to the app: the poll
      // started by `_startPolling` brought the offer straight back,
      // `_autoTriggerRoutePreview` drew the route and re-armed the latch,
      // and 800 ms later `_clearAllAnnotations` erased it — reinstating only
      // the driver dot. With the latch armed nothing ever drew it again, so
      // the driver watched the route disappear seconds after coming back.
      _startPolling(force: true); // _startPolling already calls _connectSse()
      _startClock();
      _startEarningsRefresh();
      // Re-attach the compass dropped on pause, so the arrow is already
      // pointing the right way by the time the driver has looked at it.
      _startHeadingSource();
      // On Android the PlatformView is destroyed in background and recreated
      // on resume. onMapCreated resets annotation managers, but if the map
      // was NOT recreated (warm resume), old annotations may still exist.
      // Clear everything after a short delay so the map is ready, then redraw
      // the driver dot. This prevents duplicate gold dots after resume.
      Future.delayed(const Duration(milliseconds: 800), () {
        if (!mounted) return;
        _clearAllAnnotations().then((_) {
          if (!mounted) return;
          _updateDriverAnnotation();
          _startDotWatchdog();
          // The wipe took the offer route with it, so this is the first
          // moment the latch can be cleared without the redraw being erased
          // a moment later.
          //
          // The progressive draw is an animation, and backgrounding stops it
          // mid-stroke — what survives is a fraction of a line that follows
          // no road and reaches neither pin. Redrawing from here gives the
          // whole route back. Per-offer, so it cannot loop: the redraw arms
          // the latch again.
          _lastAutoTriggeredOfferId = null;
          _offerRouteShown = false;
          if (_phase == _Phase.searching && _pendingOffers.isNotEmpty) {
            final current = _previewingOffer;
            if (current != null) {
              // The offer card never closed, so _autoTriggerRoutePreview
              // dedups on it ("already previewing") and draws NOTHING —
              // the driver came back to a card with no route. Redraw the
              // same offer directly. _isCardAnimating can be stuck true if
              // the app was backgrounded mid-sequence (its ticker paused
              // with the awaits), which would veto the redraw — reset it.
              _isCardAnimating = false;
              _onOfferCardTap(current);
            } else {
              _autoTriggerRoutePreview(_pendingOffers.first);
            }
          }
        });
      });
    }
  }

  @override
  void dispose() {
    DriverOnlineScreen.mountedCount--;
    WidgetsBinding.instance.removeObserver(this);
    _diagTimer?.cancel();
    motionDiag.dispose();
    DriverOnlineScreen.deepLinkOfferNotifier.removeListener(_applyInjectedOffer);
    DriverOnlineScreen.removeOfferNotifier
        .removeListener(_applyRemoveInjectedOffer);
    if (_networkListener != null) {
      NetworkService().onlineNotifier.removeListener(_networkListener!);
      _networkListener = null;
    }
    _smoothTicker?.stop();
    _smoothTicker?.dispose();
    _enterCtrl.dispose();
    _driverAnim.dispose();
    _reqCtrl?.dispose();
    _doneCtrl?.dispose();
    _statusLineTimer?.cancel();
    _navyGoldRetryTimer?.cancel();
    _onlineChimeTimer?.cancel();
    _searchPulse.dispose();
    _pollT?.cancel();
    _offerSseSub?.cancel();
    _activeTripCancelWatcher?.cancel();
    _sseReconnectTimer?.cancel();
    _scheduledPollTimer?.cancel();
    _clock?.cancel();
    _navTimer?.cancel();
    _dotWatchdog?.cancel();
    _goldDot.dispose();
    _headingSub?.cancel();
    _headingSource.dispose();
    EarningsPrivacy.hidden.removeListener(_onEarningsPrivacyChanged);
    _driverPhotoImage?.dispose();
    _markerFrame.dispose();
    _cancelledNoticeTimer?.cancel();
    _cancelledNoticeCtrl?.dispose();
    MapSurfaceCoordinator.instance.release(_kMapSurfaceOwner);
    unawaited(_posStream?.stop());
    // Only when the driver actually went offline.
    //
    // This ran unconditionally, so tapping Home — which pops with
    // stillOnline: true and is meant to change nothing — silenced the
    // position uploads on the way out. The backend still counted the driver
    // as online, riders would have watched a car that never moved again, and
    // the ghost agent would have forced them offline for going quiet. Going
    // to look at your home screen is not going off shift.
    if (_leavingOffline) _gpsService.stopTracking();
    _reFollowTimer?.cancel();
    _followResumeTimer?.cancel();
    _earningsRefreshTimer?.cancel();
    _bgHeartbeatTimer?.cancel();
    _panelAnimCtrl?.dispose();
    _offerPageCtrl.dispose();
    _routePulseCtrl?.dispose();
    _pulseCtrl?.dispose();
    _rejectSlideCtrl?.dispose();
    _rejectSlideCtrl = null;
    _scheduledBounceCtrl?.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _rerouteFadeTimer?.cancel();
    _pinPopTicker?.stop();
    _pinPopTicker?.dispose();
    _offerTiltCtrl?.dispose();
    _offerBearingCtrl?.dispose();
    _pauseTimer?.cancel();
    // NOTE: Intentionally do NOT dispose the map here.
    // The MapControllerCache owns the map lifecycle for reuse across screens.
    if (_map != null) MapControllerCache.instance.cache(_map!);
    super.dispose();
  }

  // â”€â”€ Build Uber-style 3D car marker sprites at runtime â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  ui.Image? _driverPhotoImage; // decoded driver photo for marker

  /// Get the correct vehicle icon bytes based on the vehicle type.
  Uint8List? get _vehicleIconBytes {
    final vt = _vehicleType.trim().toLowerCase();
    if (vt.contains('suburban') || vt.contains('suv')) return _suvIconBytes;
    if (vt.contains('fusion') || vt.contains('camry') || vt.contains('sedan')) {
      return _sedanIconBytes;
    }
    if (vt.contains('cruisex') || vt.contains('cruise')) return _sedanIconBytes;
    return _suvIconBytes;
  }

  bool _approvalGatePassed = false;
  bool _isGoingOnline = false; // prevents duplicate go-online calls

  bool _nearPickupNotified = false;
  bool _nearDropoffNotified = false;

  int _lastUiRebuildMs = 0; // throttle: only rebuild widget tree at ~15fps

  /// Pre-fetch routes for incoming offers so they are cached before card tap.
  void _preFetchOfferRoutes(List<Map<String, dynamic>> offers) {
    if (_pos == null) return;
    // Auto-evict entries older than 10 minutes
    final now = DateTime.now();
    _routeCache
        .removeWhere((_, v) => now.difference(v.cachedAt).inMinutes > 10);
    for (final offer in offers) {
      // Pre-warm rider photo so it's instant when card shows
      final photoUrl =
          (offer['rider_photo_url'] ?? offer['photo_url'] ?? '') as String;
      if (photoUrl.isNotEmpty) {
        CachedNetworkImageProvider(photoUrl)
            .resolve(const ImageConfiguration());
      }
      final oid = (offer['offer_id'] ?? offer['id'] ?? '').toString();
      if (oid.isEmpty || _routeCache.containsKey(oid)) continue;
      final pLat = _safeDouble(offer['pickup_lat']);
      final pLng = _safeDouble(offer['pickup_lng']);
      final dLat = _safeDouble(offer['dropoff_lat']);
      final dLng = _safeDouble(offer['dropoff_lng']);
      if (pLat == 0 || pLng == 0 || dLat == 0 || dLng == 0) continue;
      final pickupLL = LatLng(pLat, pLng);
      final dropoffLL = LatLng(dLat, dLng);
      // Pre-cache map tiles for pickup + dropoff areas (silent background)
      MapCacheService().precacheRoute(
        offerId: oid,
        pickupLat: pLat,
        pickupLng: pLng,
        dropoffLat: dLat,
        dropoffLng: dLng,
      );

      // Pre-detect dropoff place type from address
      final dropoffAddr = (offer['dropoff_address'] ?? '') as String;
      final placeType = _detectPlaceType(dropoffAddr);

      // Pre-build unified gold pins + fetch routes in parallel
      Future.wait<Object?>([
        _fetchRouteWithMetrics(_pos!, pickupLL), // [0] segOne + metrics
        _fetchRouteWithMetrics(pickupLL, dropoffLL), // [1] segTwo + metrics
        renderCircularPinBytes(
            icon: CircularPinIcon.person,
            isPickup: true,
            radius: 32), // [2] pickup pin
        renderCircularPinBytes(
            icon: _goldPinIconFor(placeType),
            isPickup: false,
            radius: 32), // [3] dropoff pin
      ]).then((results) {
        if (!mounted) return;
        final seg1 =
            results[0] as ({List<LatLng> pts, double? durSec, double? distM});
        final seg2 =
            results[1] as ({List<LatLng> pts, double? durSec, double? distM});
        // A failed fetch returns EMPTY points. Caching that would pin the
        // failure for the offer's whole lifetime — line 1073 skips any oid
        // already cached and the tap path trusts the cache — so a 1-second
        // network blip meant a permanently lineless preview. No entry means
        // the next prefetch pass (or the tap itself) fetches fresh.
        if (seg1.pts.length < 2 || seg2.pts.length < 2) {
          debugPrint('[OfferRoute] prefetch incomplete for $oid — not cached');
          return;
        }
        _routeCache[oid] = _CachedOfferRoute(
          segOne: seg1.pts,
          segTwo: seg2.pts,
          cachedAt: DateTime.now(),
          dropoffPlaceType: placeType,
          pickupPin: results[2] as Uint8List?,
          dropoffPin: results[3] as Uint8List?,
          driverToPickupMin: seg1.durSec != null ? seg1.durSec! / 60.0 : null,
          driverToPickupKm: seg1.distM != null ? seg1.distM! / 1000.0 : null,
          pickupToDropoffMin: seg2.durSec != null ? seg2.durSec! / 60.0 : null,
          pickupToDropoffKm: seg2.distM != null ? seg2.distM! / 1000.0 : null,
        );
        // The lock-screen card was drawn from the haversine fallback while
        // this was in flight — straight-line miles run 20-40% short, which
        // inflates the hourly rate. Now that the road numbers are in, send
        // them, or the island and the card quote different pay for the same
        // ride for as long as the offer stands.
        if (_headOfferId == oid) _syncOfferLiveActivity(force: true);
        if (_pendingOffers.isNotEmpty) setState(() {});
      }).catchError((_) {});

      // Reverse-geocode generic pickup addresses
      final rawPickupAddr = (offer['pickup_address'] ?? '') as String;
      final addrKey = '${pLat}_$pLng';
      if (!_resolvedAddressCache.containsKey(addrKey) &&
          _isGenericAddress(rawPickupAddr)) {
        _reverseGeocode(pLat, pLng).then((resolved) {
          if (resolved != null && mounted) {
            _resolvedAddressCache[addrKey] = resolved;
            if (_pendingOffers.isNotEmpty) setState(() {});
          }
        });
      }
    }
  }

  /// Whether an address string is generic / placeholder and needs reverse geocoding.
  bool _isGenericAddress(String addr) {
    if (addr.isEmpty) return true;
    final lower = addr.toLowerCase().trim();
    return lower == 'current location' ||
        lower == 'ubicación actual' ||
        lower == 'pickup' ||
        lower == 'mi ubicación';
  }

  /// Reverse-geocode coordinates → street address via Mapbox Geocoding API.
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

  /// Fetch route points + duration/distance from Directions APIs.
  /// Returns (points, durationSeconds, distanceMeters).
  ///
  /// Retried once after a short backoff. When every provider still fails the
  /// result is an EMPTY point list — never a straight-line stand-in. A line
  /// that cuts across blocks lies to the driver (it was the line in the bug
  /// report photo); no line at all is the honest failure, and the pins stay.
  Future<({List<LatLng> pts, double? durSec, double? distM})>
      _fetchRouteWithMetrics(LatLng o, LatLng d) async {
    for (var attempt = 0; attempt < 2; attempt++) {
      if (attempt > 0) {
        await Future.delayed(const Duration(milliseconds: 600));
        if (!mounted) break;
      }
      final r = await _fetchRouteWithMetricsOnce(o, d);
      if (r.pts.length >= 2) return r;
    }
    debugPrint('[Route] _fetchRouteWithMetrics: all providers failed — no line');
    return (pts: const <LatLng>[], durSec: null, distM: null);
  }

  /// One pass over the providers: Google → OSRM → Mapbox.
  Future<({List<LatLng> pts, double? durSec, double? distM})>
      _fetchRouteWithMetricsOnce(LatLng o, LatLng d) async {
    // Google Directions API
    try {
      final uri =
          Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          final pts =
              _decodePoly(route['overview_polyline']['points'] as String);
          final leg = (route['legs'] as List?)?.firstOrNull;
          final dur = (leg?['duration']?['value'] as num?)?.toDouble();
          final dist = (leg?['distance']?['value'] as num?)?.toDouble();
          return (pts: pts, durSec: dur, distM: dist);
        }
      }
    } catch (_) {}
    // OSRM fallback
    try {
      final path =
          '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic> &&
          data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final r = routes[0];
          final pts = _decodePoly(r['geometry'] as String);
          final dur = (r['duration'] as num?)?.toDouble();
          final dist = (r['distance'] as num?)?.toDouble();
          return (pts: pts, durSec: dur, distM: dist);
        }
      }
    } catch (_) {}
    // Mapbox Directions API fallback
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
          final r = mbxRoutes[0];
          final coords = r['geometry']?['coordinates'] as List?;
          if (coords != null && coords.isNotEmpty) {
            final pts = coords
                .map((c) =>
                    LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
            final dur = (r['duration'] as num?)?.toDouble();
            final dist = (r['distance'] as num?)?.toDouble();
            return (pts: pts, durSec: dur, distM: dist);
          }
        }
      }
    } catch (_) {}
    // No straight-line fallback here: the caller decides what an empty
    // route means (draw nothing, keep markers).
    return (pts: const <LatLng>[], durSec: null, distM: null);
  }

  String get _timeStr {
    final h = _online.inHours,
        m = _online.inMinutes.remainder(60),
        s = _online.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  /// Pause availability temporarily — driver stays online but won't receive offers.
  bool _isPaused = false;
  Timer? _pauseTimer;

  /// Background heartbeat timer — keeps driver "online" in backend when app is backgrounded.
  Timer? _bgHeartbeatTimer;

  /// Set the moment the driver goes offline. The 30s background heartbeat
  /// writes isOnline:true — one already in flight (or one tick queued
  /// behind the offline PATCH) used to land AFTER the offline write and
  /// silently flip the driver back online in the DB, so offers kept
  /// arriving. Checked by every isOnline:true writer; cleared on the next
  /// explicit go-online.
  bool _wentOffline = false;

  /// Dynamic bottom padding for the GoogleMap based on active overlays
  double get _mapBottomPadding {
    final screenH = MediaQuery.of(context).size.height;
    if (_previewingOffer != null) return screenH * 0.48;
    if (_phase == _Phase.searching && _pendingOffers.isNotEmpty) {
      return screenH * 0.48;
    }
    if (_phase == _Phase.enRouteToPickup) return 270;
    if (_phase == _Phase.arrivedAtPickup) return 290;
    if (_phase == _Phase.routeSummary) return 330;
    if (_phase == _Phase.inTrip) return 270;
    return 200;
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BUILD
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bot = MediaQuery.of(context).padding.bottom;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Adapt status bar icons — always light (white) during navigation so they show over dark teal header
    final isNav = _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarIconBrightness: isNav
            ? Brightness.light
            : (isDark ? Brightness.light : Brightness.dark),
      ),
    );

    // Live-switch map style
    _applyMapStyle(isDark);

    // Theme-aware colors — pure black bg, grey-black widgets/cards,
    // gold icons (driver brand pass 2026-04-26).
    final bg = isDark ? Colors.black : const Color(0xFFF2F2F7);
    final surface = isDark ? Colors.black : Colors.white;
    final card = isDark ? Colors.black : Colors.white;
    // FABs use a slight transparency so the underlying map / particle
    // field still shows through subtly behind the gold icon.
    final fabBg = isDark
        ? Colors.black.withValues(alpha: 0.88)
        : Colors.white.withValues(alpha: 0.85);
    final fabBorder = isDark
        ? const Color(0xFFE8C547).withValues(alpha: 0.18)
        : Colors.black.withValues(alpha: 0.06);
    // Same colour the home screen's top buttons use.
    //
    // These were gold, which on this screen put them in direct competition
    // with the things that actually mean something in gold: the driver's
    // own arrow, the route, the GO button, an offer arriving. Controls are
    // not events. Neutral here, gold reserved for what is happening.
    final fabIcon =
        isDark ? Colors.white : Colors.black.withValues(alpha: 0.65);
    final textPrimary = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final textMuted = isDark
        ? Colors.white.withValues(alpha: 0.45)
        : Colors.black.withValues(alpha: 0.35);
    final borderC = fabBorder;
    final overlayBg = isDark
        ? Colors.black.withValues(alpha: 0.75)
        : Colors.black.withValues(alpha: 0.45);
    final shadowC = isDark
        ? Colors.black.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.08);

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _goBack();
      },
      child: Scaffold(
        backgroundColor: bg,
        body: Stack(
          clipBehavior: Clip.none,
          children: [
            // Offline connectivity banner
            const Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(child: OfflineBanner()),
            ),

            // â”€â”€ Map â”€â”€
            _mapW(isDark),

            // While an offer is up, the three top buttons step aside and
            // the X takes the notification slot: the only two answers to a
            // ride offer are Accept and dismiss, and Home / Earnings /
            // Notifications beside them are three ways to lose it.
            // â”€â”€ Nav header (during navigation phases) â”€â”€
            if (isNav)
              Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: _navHeader(),
              ),

            // â”€â”€ Top-left: Home button (hidden during nav — nav header has its own back) â”€â”€
            // Also hidden while the accepted celebration is up: with a trip
            // taken, Home / Earnings / Notifications are three ways to walk
            // away from it, same as with an offer.
            if (!isNav && !_offerOnScreen && _acceptedOverlay == null)
              Positioned(
                top: top + 10,
                left: 16,
                child: _enterTopWrap(
                  _fab(
                    // A house, not a back arrow. The driver is not undoing a
                    // step — they are going to look at the home screen while
                    // staying exactly as online as they were. _goBack pops
                    // with stillOnline: true and stops nothing: not the GPS,
                    // not the marker, not the shift.
                    Icons.home_rounded,
                    48,
                    fabBg,
                    fabBorder,
                    fabIcon,
                    _goBack,
                  ),
                ),
              ),

            // â”€â”€ Top-center: Earnings pill + TODAY (hidden during nav) â”€â”€
            if (!isNav && !_offerOnScreen && _acceptedOverlay == null)
              Positioned(
                top: top + 10,
                left: 0,
                right: 0,
                child: _enterTopWrap(
                  Column(
                    children: [
                      // Long-press en el chip: muestra/oculta el panel de
                      // diagnóstico de movimiento (GPS/tick/cam/anot).
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPress: toggleMotionDiag,
                        child: Center(child: _earningsPill(isDark)),
                      ),
                    ],
                  ),
                ),
              ),

            // â”€â”€ Side floating buttons (only when searching with no offers) â”€â”€
            // ── Scheduled rides badge (top-right, always visible, hidden during nav) ──
            if (!isNav && !_offerOnScreen && _acceptedOverlay == null)
              Positioned(
                top: top + 10,
                right: 16,
                child: _enterTopWrap(
                  ScaleTransition(
                    scale: _scheduledBounceAnim ??
                        const AlwaysStoppedAnimation(1.0),
                    child: GestureDetector(
                      onTap: () {
                        HapticService.mediumImpact();
                        _setState(() => _showScheduledToast = false);
                        Navigator.push(
                          context,
                          slideFromRightRoute(const DriverInboxScreen()),
                        );
                      },
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: isDark && _unreadCount == 0
                            ? neuBox(radius: 24, borderColor: fabBorder)
                            : BoxDecoration(
                                color: fabBg,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: _unreadCount > 0
                                      ? const Color(0xFFE8C547)
                                          .withValues(alpha: 0.6)
                                      : fabBorder,
                                  width: 1,
                                ),
                                boxShadow: _unreadCount > 0
                                    ? [
                                        BoxShadow(
                                          color: const Color(0xFFE8C547)
                                              .withValues(alpha: 0.25),
                                          blurRadius: 10,
                                          spreadRadius: 1,
                                        ),
                                      ]
                                    : null,
                              ),
                        child: Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Center(
                              child: Icon(
                                Icons.notifications_none_rounded,
                                size: 22,
                                color: fabIcon,
                              ),
                            ),
                            if (_unreadCount > 0)
                              Positioned(
                                top: -4,
                                right: -4,
                                child: Container(
                                  padding: const EdgeInsets.all(4),
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFE8C547),
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                        color: Colors.black, width: 1.5),
                                  ),
                                  child: Text(
                                    '$_unreadCount',
                                    style: const TextStyle(
                                      color: Colors.black,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
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

            // ── Scheduled rides toast notification ──
            if (!isNav && _showScheduledToast && _scheduledAvailCount > 0)
              Positioned(
                top: top + 68,
                right: 16,
                child: TweenAnimationBuilder<double>(
                  tween: Tween(begin: 0.0, end: 1.0),
                  duration: const Duration(milliseconds: 400),
                  curve: Curves.easeOutBack,
                  builder: (context, value, child) => Transform.scale(
                    scale: value,
                    alignment: Alignment.topRight,
                    child:
                        Opacity(opacity: value.clamp(0.0, 1.0), child: child),
                  ),
                  child: GestureDetector(
                    onTap: () {
                      HapticService.selectionClick();
                      _setState(() => _showScheduledToast = false);
                      Navigator.push(
                        context,
                        slideFromRightRoute(
                            const ScheduledRidesScreen(initialTab: 0)),
                      ).then((_) => _fetchScheduledCount());
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 14, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1D24),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: const Color(0xFFE8C547).withValues(alpha: 0.4),
                          width: 1,
                        ),
                        boxShadow: [
                          BoxShadow(
                            color:
                                const Color(0xFFE8C547).withValues(alpha: 0.15),
                            blurRadius: 12,
                            spreadRadius: 1,
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.calendar_today_rounded,
                            color: Color(0xFFE8C547),
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _scheduledAvailCount == 1
                                ? '1 scheduled ride available'
                                : '$_scheduledAvailCount scheduled rides available',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const SizedBox(width: 6),
                          const Icon(
                            Icons.chevron_right_rounded,
                            color: Color(0xFFE8C547),
                            size: 16,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            if (_phase == _Phase.searching && _pendingOffers.isEmpty) ...[
              Positioned(
                // Just clear of the panel. The panel is 78 + inset tall now
                // (it was 54 when this constant last moved), and 54 + 14 sat
                // the clusters 10 pt INSIDE its top edge — the "glued to the
                // Finding trips bar" look. 78 + 14 lifts them properly above
                // it with the same gap that was always intended.
                bottom: 78 + bot + 14,
                left: 16,
                child: Column(
                  children: [
                    _fab(
                      Icons.calendar_today_rounded,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        slideFromRightRoute(
                          const ScheduledRidesScreen(initialTab: 0),
                        ),
                      ).then((_) => _fetchScheduledCount()),
                      stagger: 0,
                    ),
                  ],
                ),
              ),
              Positioned(
                // Same lift as the calendar cluster on the left: the panel
                // is 78 + inset tall, not 54 — anything less sank these two
                // into its top edge.
                bottom: 78 + bot + 14,
                right: 16,
                child: Column(
                  children: [
                    // Safety, where promotions used to be. The chat button
                    // that led this column is gone — it opened the same inbox
                    // the notifications button at the top now owns, and one
                    // destination does not need two doors on one screen.
                    _fab(
                      Icons.health_and_safety_outlined,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        slideFromRightRoute(const SafetyScreen()),
                      ),
                      stagger: 1,
                    ),
                    const SizedBox(height: 10),
                    // Recentre, where analytics used to be.
                    //
                    // The map lets the driver drag it away and hands the
                    // camera back after ten seconds of stillness — but ten
                    // seconds is a long time to wait for your own position,
                    // and there was no way to ask for it. Now there is.
                    _fab(
                      Icons.gps_fixed_rounded,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () {
                        HapticService.selectionClick();
                        _recenterCamera();
                      },
                      stagger: 2,
                    ),
                  ],
                ),
              ),
            ],

            // â”€â”€ Re-center button during navigation (inTrip / routeSummary) â”€â”€
            // -- Re-center FAB: appears when user pans away during navigation --
            if (!_cameraFollowing &&
                (_phase == _Phase.enRouteToPickup ||
                    _phase == _Phase.inTrip ||
                    _phase == _Phase.routeSummary))
              Positioned(
                bottom: _mapBottomPadding + 12,
                right: 16,
                child: _fab(
                  Icons.navigation_rounded,
                  48,
                  fabBg,
                  fabBorder,
                  const Color(0xFF4285F4),
                  () {
                    HapticService.mediumImpact();
                    _recenterCamera();
                  },
                ),
              ),

            // â”€â”€ Completed overlay â”€â”€
            if (_phase == _Phase.completed)
              Positioned.fill(
                child: _completedOverlay(
                  isDark,
                  overlayBg,
                  card,
                  textPrimary,
                  borderC,
                  shadowC,
                ),
              ),

            // â”€â”€ Stacked Ride Offer Cards (Spark-style) â”€â”€
            if (_pendingOffers.isNotEmpty)
              Positioned(
                // Flush with the bottom edge while searching. This was -30,
                // which hid the dead space under the old shorter card and
                // now eats the real one — the card's own padding does that
                // job. Outside searching the only pending offers are
                // chained ones, and the card rides above the nav panel
                // instead of covering it.
                bottom: _phase == _Phase.searching ? 0 : _mapBottomPadding,
                left: 0,
                right: 0,
                child: _rideOfferCards(
                  isDark,
                  card,
                  textPrimary,
                  textMuted,
                  borderC,
                  shadowC,
                ),
              ),

            // â”€â”€ Dismiss the offer — top-right, where the bell was â”€â”€
            if (_offerOnScreen || _previewingOffer != null)
              Positioned(
                top: top + 10,
                right: 16,
                child: _fab(
                  Icons.close_rounded,
                  48,
                  fabBg,
                  const Color(0x66E8C547),
                  const Color(0xFFE8C547),
                  () {
                    HapticService.lightImpact();
                    // With an offer up this rejects it; with only a preview
                    // left there is nothing to reject, so it just closes.
                    if (_pendingOffers.isEmpty) {
                      _closePreview();
                      return;
                    }
                    final idx =
                        _currentOfferIndex.clamp(0, _pendingOffers.length - 1);
                    _rejectOffer(_pendingOffers[idx]);
                  },
                ),
              ),

            // â”€â”€ Bottom: Phase-specific panel â”€â”€
            if (_phase == _Phase.searching)
              Positioned.fill(
                child: AnimatedSlide(
                  offset: _pendingOffers.isNotEmpty
                      ? const Offset(0, 1)
                      : Offset.zero,
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  child: AnimatedOpacity(
                    opacity: _pendingOffers.isNotEmpty ? 0.0 : 1.0,
                    duration: const Duration(milliseconds: 300),
                    child: IgnorePointer(
                      ignoring: _pendingOffers.isNotEmpty,
                      child: Stack(
                        children: [
                          _floatingPanel(
                            isDark,
                            surface,
                            textMuted,
                            borderC,
                            textPrimary,
                            shadowC,
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              )
            else if (_phase != _Phase.searching || _pendingOffers.isEmpty)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _bottomArea(
                  isDark,
                  bg,
                  surface,
                  textPrimary,
                  textMuted,
                  borderC,
                  shadowC,
                ),
              ),

            // ── "Viaje cancelado" notice ──
            // Centred on a semi-dark wash, ~5 s, fluid fade both ways. It
            // never absorbs a tap: the driver is already back to searching
            // the moment it shows.
            if (_cancelledNoticeVisible && _cancelledNoticeFade != null)
              Positioned.fill(
                child: IgnorePointer(
                  child: FadeTransition(
                    opacity: _cancelledNoticeFade!,
                    child: ColoredBox(
                      color: Colors.black.withValues(alpha: 0.55),
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 28, vertical: 20),
                          decoration: BoxDecoration(
                            color: neuSurface,
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: const Color(0xFFE8C547)
                                  .withValues(alpha: 0.35),
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.5),
                                blurRadius: 24,
                                offset: const Offset(0, 10),
                                spreadRadius: -6,
                              ),
                            ],
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 56,
                                height: 56,
                                decoration: BoxDecoration(
                                  shape: BoxShape.circle,
                                  color: const Color(0xFFE8C547)
                                      .withValues(alpha: 0.12),
                                  border: Border.all(
                                    color: const Color(0xFFE8C547),
                                    width: 1.5,
                                  ),
                                ),
                                child: const Icon(
                                  Icons.cancel_outlined,
                                  color: Color(0xFFE8C547),
                                  size: 30,
                                ),
                              ),
                              const SizedBox(height: 14),
                              Text(
                                S.of(context).tripCancelled,
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                S.of(context).driverTripCancelledReturning,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  color:
                                      Colors.white.withValues(alpha: 0.55),
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),

            // ── "Viaje aceptado" celebration ──
            // Topmost layer, drawn over the map this screen already owns.
            // Absorbs taps so the offer cards underneath can't be hit while
            // the accept is still settling.
            if (_acceptedOverlay != null)
              Positioned.fill(
                child: AbsorbPointer(
                  child: TripAcceptedOverlay(
                    key: ValueKey('accepted-$_tripId'),
                    riderName: _acceptedOverlay!.riderName,
                    riderInitials: _acceptedOverlay!.riderInitials,
                    riderPhotoUrl: _acceptedOverlay!.riderPhotoUrl,
                    riderRating: _acceptedOverlay!.riderRating,
                    riderIsNew: _acceptedOverlay!.riderIsNew,
                    riderId: _acceptedOverlay!.riderId,
                    pickupAddress: _acceptedOverlay!.pickupAddress,
                    distToPickupKm: _acceptedOverlay!.distToPickupKm,
                    etaMinutes: _acceptedOverlay!.etaMinutes,
                    duration: _acceptedOverlayDuration,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//  NAV HEADER (Google Maps–style full-width turn bar)
// ═══════════════════════════════════════════════════════════════════════════════
  Widget _navHeader() {
    final toPickup = _phase == _Phase.enRouteToPickup;
    final maneuverStr = _navState?.currentManeuver ?? 'straight';
    final maneuverInfo = NavigationService.getManeuverIcon(maneuverStr);
    final distToTurn = _navState?.distanceToTurnText ?? '';
    final isOffRoute = _navState?.isOffRoute ?? false;
    final topPad = MediaQuery.of(context).padding.top;

    // Google Maps–style dark teal (matches Google nav header closely)
    const Color navBg = Color(0xFF1C3F5E);
    const Color navBgSub = Color(0xFF162F46);
    final Color bg = isOffRoute ? const Color(0xFFC0392B) : navBg;
    final Color bgSub = isOffRoute ? const Color(0xFFA93226) : navBgSub;

    return Material(
      color: Colors.transparent,
      child: Container(
        color: bg,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status bar safe area — same dark colour
            SizedBox(height: topPad),
            // ── Main turn instruction row ──────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 10, 16, 10),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Turn arrow box
                  Container(
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      maneuverInfo.icon,
                      color: Colors.white,
                      size: 36,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isOffRoute && distToTurn.isNotEmpty)
                          Text(
                            distToTurn,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 30,
                              fontWeight: FontWeight.w900,
                              height: 1.0,
                            ),
                          ),
                        if (isOffRoute)
                          Text(
                            S.of(context).rerouting,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 22,
                              fontWeight: FontWeight.w900,
                              height: 1.1,
                            ),
                          ),
                        const SizedBox(height: 2),
                        Text(
                          isOffRoute ? S.of(context).offRoute : _navInstruct,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.9),
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  // Cancel policy 2026-04-11: the driver can no longer
                  // directly cancel an active trip. The close button on
                  // the pickup-nav row is removed; if the driver needs
                  // to abort they must contact support (or the trip will
                  // eventually be dispatch-cancelled which resets the
                  // controller via _resetToSearchingOnRemoteCancel).
                ],
              ),
            ),
            // ── "Then" next-maneuver sub-row ───────────────────────
            if (_navState?.nextStep != null && !isOffRoute)
              Container(
                color: bgSub,
                padding: const EdgeInsets.fromLTRB(16, 7, 16, 7),
                child: Row(
                  children: [
                    Text(
                      S.of(context).thenLabel,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.55),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Icon(
                      NavigationService.getManeuverIcon(
                        _navState!.nextStep!.maneuver,
                      ).icon,
                      color: Colors.white.withValues(alpha: 0.75),
                      size: 17,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        _navState!.nextStep!.instruction,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    // Progress + ETA compact row
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          '$_navEta min  ·  ${(_navDist * 0.621371).toStringAsFixed(1)} mi',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.6),
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 8),
                        SizedBox(
                          width: 40,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(2),
                            child: LinearProgressIndicator(
                              value: _navProgress,
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.15),
                              valueColor:
                                  const AlwaysStoppedAnimation(Colors.white),
                              minHeight: 3,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}

// ──────────────────────────────────────────────────
//  Pulsing radar for driver searching panel
// ──────────────────────────────────────────────────
class _DriverRadar extends StatefulWidget {
  final Color color;
  const _DriverRadar({required this.color});
  @override
  State<_DriverRadar> createState() => _DriverRadarState();
}

class _DriverRadarState extends State<_DriverRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _ctrl,
      builder: (_, __) => CustomPaint(
        painter: _DriverRadarPainter(
          progress: _ctrl.value,
          color: widget.color,
        ),
      ),
    );
  }
}

class _DriverRadarPainter extends CustomPainter {
  final double progress;
  final Color color;
  _DriverRadarPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxR = size.width / 2;

    for (int i = 0; i < 3; i++) {
      final wave = ((progress + i / 3.0) % 1.0);
      final radius = maxR * wave;
      final opacity = (1.0 - wave) * 0.6;
      final paint = Paint()
        ..color = color.withValues(alpha: opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5;
      canvas.drawCircle(center, radius, paint);
    }

    // Center dot
    canvas.drawCircle(
      center,
      6,
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(_DriverRadarPainter old) => old.progress != progress;
}

/// Cached route segments for a pending offer.
class _CachedOfferRoute {
  final List<LatLng> segOne;
  final List<LatLng> segTwo;
  final DateTime cachedAt;
  final _PlaceType dropoffPlaceType;
  final Uint8List? pickupPin;
  final Uint8List? dropoffPin;
  final double? driverToPickupMin;
  final double? driverToPickupKm;
  final double? pickupToDropoffMin;
  final double? pickupToDropoffKm;
  const _CachedOfferRoute({
    required this.segOne,
    required this.segTwo,
    required this.cachedAt,
    this.dropoffPlaceType = _PlaceType.home,
    this.pickupPin,
    this.dropoffPin,
    this.driverToPickupMin,
    this.driverToPickupKm,
    this.pickupToDropoffMin,
    this.pickupToDropoffKm,
  });
}

/// Rider data shown by the "viaje aceptado" celebration overlay.
class _AcceptedOverlayData {
  final String riderName;
  final String riderInitials;
  final String? riderPhotoUrl;
  final double riderRating;
  final bool riderIsNew;
  final int? riderId;
  final String pickupAddress;
  final double distToPickupKm;
  final int etaMinutes;
  const _AcceptedOverlayData({
    required this.riderName,
    required this.riderInitials,
    required this.riderRating,
    required this.riderIsNew,
    required this.pickupAddress,
    required this.distToPickupKm,
    required this.etaMinutes,
    this.riderPhotoUrl,
    this.riderId,
  });
}

/// Place type for smart dropoff icon detection.
enum _PlaceType { home, commerce, hotel, airport }

_PlaceType _detectPlaceType(String address) {
  final lower = address.toLowerCase();
  bool has(List<String> kw) => kw.any((k) => lower.contains(k));

  if (has(['airport', 'aeropuerto', 'intl', 'international', 'terminal'])) {
    return _PlaceType.airport;
  }
  if (has([
    'hotel',
    'inn',
    'suites',
    'resort',
    'marriott',
    'hilton',
    'hyatt',
    'holiday',
    'motel',
    'lodge'
  ])) {
    return _PlaceType.hotel;
  }
  if (has([
    'mall',
    'plaza',
    'center',
    'centre',
    'walmart',
    'target',
    'store',
    'market',
    'shop',
    'restaurant',
    'cafe',
    'bar',
    'gym',
    'clinic',
    'hospital',
    'school',
    'university'
  ])) {
    return _PlaceType.commerce;
  }
  return _PlaceType.home;
}

IconData _dropoffIconFor(_PlaceType type) {
  switch (type) {
    case _PlaceType.airport:
      return Icons.local_airport_rounded;
    case _PlaceType.hotel:
      return Icons.apartment_rounded;
    case _PlaceType.commerce:
      return Icons.storefront_rounded;
    case _PlaceType.home:
      return Icons.home_rounded;
  }
}

/// Map _PlaceType to CircularPinIcon for unified circular pins.
CircularPinIcon _goldPinIconFor(_PlaceType type) {
  switch (type) {
    case _PlaceType.airport:
      return CircularPinIcon.airplane;
    case _PlaceType.hotel:
      return CircularPinIcon.home;
    case _PlaceType.commerce:
      return CircularPinIcon.store;
    case _PlaceType.home:
      return CircularPinIcon.home;
  }
}

/// Paints an animated gold glow segment around the "Finding trips" panel.
/// Uses 48 micro-segments for a smooth, fluid gradient — no pixelation.
/// The glow runs the full outline of a sheet that is welded to both sides
/// and to the bottom, so the shape is the same open or shut.
class _SearchingBorderPainter extends CustomPainter {
  final double progress; // 0.0 → 1.0, loops continuously

  /// How far the panel is open, 0 shut to 1 wide.
  ///
  /// The travelling light hands over as the sheet opens. Around the outline
  /// of a collapsed sheet it is a small bright circuit and reads as one
  /// object working; stretched around a sheet that fills most of the screen
  /// it is a light crawling the edge of the display, far from anything it
  /// could be describing. Open, the same light runs the divider under the
  /// header instead — see _SearchingDividerLine — which is short, straight,
  /// and next to the words it belongs to.
  final double expansion;

  static const Color _gold = Color(0xFFE8C547);
  static const Color _goldLight = Color(0xFFFBE47A);

  _SearchingBorderPainter({required this.progress, this.expansion = 0.0});

  @override
  void paint(Canvas canvas, Size size) {
    // Faded out well before the sheet is open, so the two never both run.
    final outlineAlpha = (1.0 - expansion / 0.35).clamp(0.0, 1.0);
    if (outlineAlpha <= 0.01) return;
    // One layer, so the whole circuit dims as a unit instead of the halo and
    // the line fading against each other.
    final rect = Offset.zero & size;
    if (outlineAlpha < 1.0) {
      canvas.saveLayer(
        rect.inflate(16),
        Paint()..color = Color.fromRGBO(0, 0, 0, outlineAlpha),
      );
    }
    _paintOutline(canvas, size);
    if (outlineAlpha < 1.0) canvas.restore();
  }

  void _paintOutline(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    // Fixed shape: the sheet is welded to both sides and to the bottom
    // whether it is open or shut, so only the top corners are round. There
    // used to be an `expansion` input that eased the bottom pair from 20 to
    // 0 while the panel floated; there is no floating state left to ease.
    final rrect = RRect.fromRectAndCorners(
      rect,
      topLeft: const Radius.circular(26),
      topRight: const Radius.circular(26),
    );

    // Subtle base border — always visible
    canvas.drawRRect(
      rrect,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2
        ..isAntiAlias = true
        ..color = _gold.withValues(alpha: 0.12),
    );

    // Build path from RRect — Flutter Bézier curves = mathematically smooth corners
    final borderPath = Path()..addRRect(rrect);
    final metricsList = borderPath.computeMetrics().toList();
    if (metricsList.isEmpty) return;
    final pm = metricsList.first;
    final total = pm.length;

    const glowFraction = 0.18;
    final glowLen = total * glowFraction;
    final headDist = (progress * total) % total;

    // One stroke, faded by a shader — not forty-eight strokes faded by hand.
    //
    // The old loop cut the arc into 48 pieces and drew each at its own alpha
    // with a round cap on both ends. That is what read as a string of beads:
    // every piece put a rounded bulge where the next one began, and the
    // semi-transparent ends overlapped, so each seam composited twice and
    // came out darker than the segment either side of it. More steps would
    // not have fixed it — it makes the beads smaller and the seams more
    // numerous.
    //
    // Drawn as a single path with a gradient along the head-to-tail vector,
    // there are no seams to see: the fade is one smooth ramp and the only
    // round cap in the picture is the head, where it belongs.
    final tailDist = (headDist - glowLen + total) % total;
    final headPt = pm.getTangentForOffset(headDist)?.position;
    final tailPt = pm.getTangentForOffset(tailDist)?.position;
    if (headPt == null || tailPt == null) return;
    // Degenerate on a shape too small to hold the arc: the two ends land on
    // the same pixel and a gradient between them has no direction.
    if ((headPt - tailPt).distance < 1.0) return;

    final Path arc;
    if (tailDist <= headDist) {
      arc = pm.extractPath(tailDist, headDist);
    } else {
      arc = pm.extractPath(tailDist, total)
        ..addPath(pm.extractPath(0, headDist), Offset.zero);
    }

    // Transparent at the tail, brightest at the head. The middle stop keeps
    // most of the light in the leading third, so the trail reads as
    // something moving rather than as a bar that happens to be lit.
    List<Color> ramp(double peak) => <Color>[
          _gold.withValues(alpha: 0.0),
          _gold.withValues(alpha: peak * 0.35),
          _goldLight.withValues(alpha: peak),
        ];
    const stops = <double>[0.0, 0.62, 1.0];

    // Soft halo under the line, so the glow spills onto the sheet.
    canvas.drawPath(
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 11
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8)
        ..shader = ui.Gradient.linear(tailPt, headPt, ramp(0.34), stops),
    );

    canvas.drawPath(
      arc,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..isAntiAlias = true
        ..shader = ui.Gradient.linear(tailPt, headPt, ramp(0.95), stops),
    );
  }

  @override
  bool shouldRepaint(_SearchingBorderPainter old) =>
      old.progress != progress || old.expansion != expansion;
}

/// The travelling light, on a straight rule instead of around a box.
///
/// This is what the searching pulse becomes once the panel is open: the
/// hairline that separates the header from the content, with the same gold
/// segment sliding along it. Same pulse, same colours, same fade at the
/// tail — a shorter track, next to the words it is about.
///
/// Drawn rather than composed out of widgets because the fade has to run
/// along the segment, and a gradient inside a Positioned box would fade
/// against the box rather than along the travel.
class _SearchingDividerLine extends StatelessWidget {
  const _SearchingDividerLine({
    required this.progress,
    required this.baseColor,
    this.height = 1.0,
  });

  /// 0 → 1, loops. The same pulse the border used.
  final double progress;

  /// The rule itself, under the moving light.
  final Color baseColor;

  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _DividerLinePainter(progress: progress, base: baseColor),
      ),
    );
  }
}

class _DividerLinePainter extends CustomPainter {
  _DividerLinePainter({required this.progress, required this.base});

  final double progress;
  final Color base;

  static const Color _gold = Color(0xFFE8C547);
  static const Color _goldLight = Color(0xFFFBE47A);

  /// The lit run, as a fraction of the width.
  static const double _glowFraction = 0.28;

  @override
  void paint(Canvas canvas, Size size) {
    final y = size.height / 2;
    canvas.drawLine(
      Offset(0, y),
      Offset(size.width, y),
      Paint()
        ..color = base
        ..strokeWidth = size.height,
    );

    final glowW = size.width * _glowFraction;
    // Eased, and travelling from off one edge to off the other.
    //
    // Linear travel with a hard wrap put the head back at the left in the
    // same frame it left the right — a snap once per lap. Starting and
    // ending outside the rule means the segment is already gone before it
    // restarts, so there is nothing to see at the seam.
    final eased = Curves.easeInOutSine.transform(progress);
    final head = -glowW + (size.width + glowW * 2) * eased;
    final tail = head - glowW;
    if (head <= 0 || tail >= size.width) return;

    final from = Offset(tail, y);
    final to = Offset(head, y);
    if ((to - from).distance < 1.0) return;

    void run(double width, double peak, double? blur) {
      final p = Paint()
        ..strokeWidth = width
        ..strokeCap = StrokeCap.round
        ..isAntiAlias = true
        ..shader = ui.Gradient.linear(
          from,
          to,
          <Color>[
            _gold.withValues(alpha: 0.0),
            _gold.withValues(alpha: peak * 0.35),
            _goldLight.withValues(alpha: peak),
          ],
          const <double>[0.0, 0.62, 1.0],
        );
      if (blur != null) {
        p.maskFilter = MaskFilter.blur(BlurStyle.normal, blur);
      }
      canvas.drawLine(from, to, p);
    }

    run(7, 0.30, 5); // halo
    run(size.height * 1.6, 0.95, null); // the line
  }

  @override
  bool shouldRepaint(_DividerLinePainter old) =>
      old.progress != progress || old.base != base;
}
