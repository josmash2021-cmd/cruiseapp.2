import 'dart:async';
import 'dart:convert';
import '../utils/app_platform.dart';
import '../config/route_observers.dart';
import '../map/map_surface_coordinator.dart';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import '../map/web_map_view.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
import 'package:firebase_crashlytics/firebase_crashlytics.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../config/mapbox_config.dart';
import '../config/map_theme.dart';
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;

import '../navigation/car_icon_loader.dart';
import '../config/api_keys.dart';
import '../config/app_config.dart';
import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/driver_wait_estimate.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/user_session.dart';
import '../services/local_cache.dart';
import '../services/payment_service.dart';
import '../services/analytics_service.dart';
import '../services/haptic_service.dart';
import '../services/places_service.dart';
import '../services/map_controller_cache.dart';
import '../state/rider_trip_controller.dart';
import 'credit_card_screen.dart';
import 'payment_accounts_screen.dart';
import '../widgets/tier_detail_sheet.dart';
import 'paypal_checkout_screen.dart';
import 'pickup_dropoff_search_screen.dart';
import 'ride_options_sheet.dart';
import 'rider_tracking_screen.dart';
import 'airport_terminal_sheet.dart';
import '../l10n/app_localizations.dart';
import '../widgets/car_image_3d.dart';
import '../widgets/neu_style.dart';
import '../widgets/gold_location_dot.dart';
import '../widgets/gold_pin_renderer.dart';
import '../widgets/map/animated_map_label.dart';

import '../widgets/map/circular_pin_renderer.dart';
import '../widgets/tier_badge.dart';
import '../widgets/verified_avatar.dart';
import 'schedule_datetime_screen.dart';
import 'set_pickup_location_screen.dart';
import '../utils/mapbox_safe.dart';
import 'ride_booking_confirmed_screen.dart';
import 'ride_payment_method_screen.dart';
import 'tap_to_pay_screen.dart';
import 'searching_driver_screen.dart';
import 'waiting_for_driver_screen.dart';
import 'home_screen.dart';

part 'ride_request_controller.dart';
part 'ride_request_map.dart';
part 'ride_request_widgets.dart';

/// Main Uber-like ride request screen.
///
/// Flow:
///  1. Fullscreen map with "Where to?" pill  →  tap opens search
///  2. Route preview with polyline
///  3. Ride options bottom sheet
///  4. "Confirm Fusion" → searching animation
///  5. Driver matched → tracking screen
enum _PinIcon { none, person, house, store, airplane }

/// Convert old _PinIcon enum to new CircularPinIcon
CircularPinIcon _pinIconToCircular(_PinIcon icon) {
  switch (icon) {
    case _PinIcon.person:
      return CircularPinIcon.person;
    case _PinIcon.house:
      return CircularPinIcon.home;
    case _PinIcon.store:
      return CircularPinIcon.store;
    case _PinIcon.airplane:
      return CircularPinIcon.airplane;
    case _PinIcon.none:
      return CircularPinIcon.dot;
  }
}

class RideRequestScreen extends StatefulWidget {
  final bool fastRide;
  final bool applyPromo;
  final bool isAirportTrip;
  final DateTime? scheduledAt;
  final AirportSelection? airportSelection;
  final String? initialDropoffAddress;
  final PlaceDetails? initialPickupDetails;
  final PlaceDetails? initialDropoffDetails;
  /// The intermediate stop chosen on the addresses page ("+"). Travels in
  /// the booking notes ("Stop: …") — the create endpoint takes no stop field.
  final String? initialStopAddress;
  final String? initialPickupLabel;
  final String? initialDropoffLabel;
  final RouteResult? preloadedRoute;
  final String? initialRideId;
  /// When the previous screen was a full-screen map, passing its final
  /// camera state lets this screen boot the map at exactly the same
  /// center/zoom/bearing/pitch so the transition reads as one smooth
  /// fade between two identical views (no teleport, no reset).
  final double? handoffLat;
  final double? handoffLng;
  final double? handoffZoom;
  final double? handoffBearing;
  final double? handoffPitch;
  /// When true, boots in the in-place map picker mode (RiderPhase.pickingLocation).
  /// The same Mapbox canvas stays alive through picker → confirm → route preview
  /// so there's no visible handoff between two separate maps (matches the
  /// Shopify widget's behavior).
  final bool pickerMode;
  final bool pickerIsPickup;
  const RideRequestScreen({
    super.key,
    this.fastRide = false,
    this.applyPromo = false,
    this.isAirportTrip = false,
    this.scheduledAt,
    this.airportSelection,
    this.initialDropoffAddress,
    this.initialStopAddress,
    this.initialPickupDetails,
    this.initialDropoffDetails,
    this.initialPickupLabel,
    this.initialDropoffLabel,
    this.preloadedRoute,
    this.initialRideId,
    this.handoffLat,
    this.handoffLng,
    this.handoffZoom,
    this.handoffBearing,
    this.handoffPitch,
    this.pickerMode = false,
    this.pickerIsPickup = false,
  });

  @override
  State<RideRequestScreen> createState() => _RideRequestScreenState();
}


const _gold = Color(0xFFE8C547);
const _cardGold = Color(0xFFE8C547);
const double _pickerRippleDurationMs = 1200.0;
const int _pickerRippleWaveCount = 3;
List<String> _getSearchStatusMessages(BuildContext context) {
  final s = S.of(context);
  return [
    s.searchStatusMsg1,
    s.searchStatusMsg2,
    s.searchStatusMsg3,
    s.searchStatusMsg4,
  ];
}

/// Camera angle presets synced with each status message.
/// Each entry: (pitch°, bearing°)
///
/// All zero on purpose: the searching camera used to tilt and rotate
/// through these, and the rider read it as the map "snapping" out of the
/// calm top-down overview. The map stays flat and north-up while the
/// status messages cycle.
const List<(double, double)> _searchCameraAngles = [
  (0.0, 0.0),   // Looking for your driver
  (0.0, 0.0),   // Connecting
  (0.0, 0.0),   // Almost there
  (0.0, 0.0),   // Confirming
];

/// Enum for payment retry actions
enum _RetryAction { retrySame, tryDifferentMethod, addNewCard, cancel }

/// Helper function to get display name for payment methods
String _getMethodDisplayName(String method, S s) {
  switch (method) {
    case 'apple_pay':
      return 'Apple Pay';
    case 'google_pay':
      return 'Google Pay';
    case 'credit_card':
      return s.creditOrDebitCard;
    case 'paypal':
      return 'PayPal';
    default:
      return s.creditOrDebitCard;
  }
}

/// Smart payment retry dialog that adapts based on available methods and error type
class _PaymentRetryDialog extends StatelessWidget {
  final String title;
  final String message;
  final String errorCode;
  final bool hasAlternativeMethod;
  final bool hasSavedCard;
  final String originalMethod;

  const _PaymentRetryDialog({
    required this.title,
    required this.message,
    required this.errorCode,
    required this.hasAlternativeMethod,
    required this.hasSavedCard,
    required this.originalMethod,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context);
    final isNetworkError = errorCode == 'network_error';
    final methodName = _getMethodDisplayName(originalMethod, s);

    return Dialog(
      backgroundColor: const Color(0xFF1E1E1E),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Error icon
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: isNetworkError
                    ? const Color(0xFFF59E0B).withValues(alpha: 0.12)
                    : const Color(0xFFEF4444).withValues(alpha: 0.12),
                shape: BoxShape.circle,
              ),
              child: Icon(
                isNetworkError ? Icons.wifi_off_rounded : Icons.credit_card_off_rounded,
                color: isNetworkError ? const Color(0xFFF59E0B) : const Color(0xFFEF4444),
                size: 28,
              ),
            ),
            const SizedBox(height: 16),
            
            // Title
            Text(
              title,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 20,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 10),
            
            // Message
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.6),
                fontSize: 14,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 24),
            
            // Action buttons
            Column(
              children: [
                // Primary: Retry with same method
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFE8C547),
                      foregroundColor: Colors.black,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    onPressed: () => Navigator.pop(context, _RetryAction.retrySame),
                    child: Text(
                      isNetworkError 
                          ? s.retryConnection
                          : s.retryWithSameMethod(methodName),
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                
                // Secondary: Try different method (if available)
                if (hasAlternativeMethod) ...[
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFFE8C547),
                        side: const BorderSide(color: Color(0xFFE8C547)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.pop(context, _RetryAction.tryDifferentMethod),
                      child: Text(
                        s.tryDifferentPaymentMethod,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                
                // Tertiary: Add new card
                if (!hasSavedCard || originalMethod == 'credit_card') ...[
                  SizedBox(
                    width: double.infinity,
                    height: 48,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        foregroundColor: Colors.white.withValues(alpha: 0.8),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () => Navigator.pop(context, _RetryAction.addNewCard),
                      child: Text(
                        s.addNewCard,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                
                // Cancel
                TextButton(
                  onPressed: () => Navigator.pop(context, _RetryAction.cancel),
                  child: Text(
                    s.cancelRide,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 15,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RideRequestScreenState extends State<RideRequestScreen>
    with TickerProviderStateMixin, WidgetsBindingObserver, RouteAware {
  void _setState(VoidCallback fn) { if (mounted) setState(fn); }

  /// Identifies this screen to [MapSurfaceCoordinator].
  ///
  /// Picking a spot on the map opens the location picker, which has a
  /// full-screen map of its own. Ours stayed mounted underneath — two live
  /// Mapbox surfaces, which closes the app on iOS. The picker now revokes
  /// this one and waits for it to be gone before it mounts, and we take the
  /// surface back when it pops.
  ///
  /// Per-INSTANCE, deliberately not per-type: the booking sheet and the map
  /// picker are BOTH RideRequestScreen, and the picker is pushed on top of
  /// the sheet (home → sheet → search → picker). A shared id made the
  /// coordinator read the picker's acquire as the same owner re-acquiring —
  /// `_owner == owner` skips the revoke — so the sheet's map stayed alive
  /// underneath with a live `_mapCtrl`, and its still-running `_initLocation`
  /// GPS writes (last-known setCamera + fresh-fix flyTo, top-down, the
  /// rider's own position, landing up to 10 s into a cold start) fired while
  /// the rider was dragging the picker: the "picker snaps back to my
  /// location right after login / app open" report. With a unique id the
  /// picker's acquire revokes the sheet for real, and didPopNext hands the
  /// surface back when the picker pops.
  static int _nextMapSurfaceId = 0;
  late final String _mapSurfaceOwner =
      'RideRequest-${++_nextMapSurfaceId}';
  bool _mapMounted = false;

  /// The camera as the rider last left it, fed by onCameraChangeListener.
  /// A recreated MapWidget boots from these (see cameraOptions) instead of
  /// from the handoff or the GPS fix — platform-view teardown can no longer
  /// "snap" the picker back to the rider's own location.
  LatLng? _lastCamCenter;
  double? _lastCamZoom;
  double? _lastCamPitch;
  double? _lastCamBearing;

  // ── Map ──
  mapbox.MapboxMap? _mapCtrl;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;
  mapbox.PointAnnotation? _goldDotAnnot;
  mapbox.PointAnnotation? _userDotAnnot;
  mapbox.PolylineAnnotation? _routeAnnot;
  /// Newest camera frame waiting for the channel, and whether one is
  /// already travelling. The animation listeners produce frames faster than
  /// the pigeon channel drains them, so frames are coalesced rather than
  /// queued — see `_pushCamera` in ride_request_map.dart.
  mapbox.CameraOptions? _pendingCam;
  bool _camWriteInFlight = false;
  // ── Cinematic animation ──
  AnimationController? _tiltCtrl;
  Animation<double>? _tiltAnim;
  AnimationController? _bearingCtrl;
  Animation<double>? _bearingAnim;
  AnimationController? _pinPopCtrl;
  Animation<double>? _pinPopAnim;
  Ticker? _routeDrawTicker;
  double _randomBearing = 0;
  bool _cinematicDone = false;
  bool _cinematicRunning = false;
  bool _hasAppliedSelectionTilt = false;
  bool _labelsRevealed = false;
  bool _placingMarkers = false; // guard against concurrent pin duplication
  // Choose-a-vehicle sheet (2026-08-22 redesign, Lyft-style vertical tier
  // list): two snapped states — expanded (every tier listed, the selected
  // one grown open) and collapsed (only the selected tier's card plus the
  // action panel, so the map and the route stay in view). Driven by the
  // drag handle's vertical gesture; the height change animates through
  // AnimatedSize and the map refits off _sheetHeightPx as always.
  bool _sheetCollapsed = false;
  // How many tier rows the sheet is showing right now — the synced camera
  // fit needs it to compute the collapsed/expanded height delta (see
  // _syncCameraWithSheetToggle). Set on every _buildRoutePreviewSheet.
  int _displayTierCount = 0;
  AnimationController? _labelPopCtrl;
  Animation<double>? _labelPopAnim;
  LatLng? _center;
  LatLng? _userLocation;
  // In-flight _initLocation() future — lets the map picker await a pending
  // GPS fix (on web the browser permission prompt can take several seconds)
  // instead of bouncing back to search with _userLocation still null.
  Future<void>? _locationReadyFuture;
  bool _mapReady = false;

  // ── Trip controller ──
  final RiderTripController _ctrl = RiderTripController();

  // ── Cruise Cash (referral credit) ──
  // Loaded once when ride_request opens. Displayed on the picked
  // vehicle horizontal card as a discount badge ("-$10.00 Cruise
  // Cash") when > 0. Backend applies it for real at dispatch time;
  // this is just the visible preview for the rider.
  int _cruiseCashCents = 0;

  // ── Map elements (raw bytes) ──
  Uint8List? _goldPinIcon;
  Uint8List? _goldDropoffPinIcon;

  // ── Searching animation ──
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // ── Searching card: radar rings + cycling text + shimmer ──
  late AnimationController _radarCtrl;
  late AnimationController _shimmerCtrl;
  int _searchStatusIdx = 0;
  Timer? _searchStatusTimer;
  int _searchElapsedSec = 0;
  Timer? _searchElapsedTimer;

  // ── Search camera (fixed full-route frame — no rotation) ──
  AnimationController? _searchCamCtrl;

  // ── Bottom sheet ──
  //
  // _sheetCtrl drives a FADE-ONLY entrance for the choose-a-ride panel.
  // The controller runs 0 → 1 over ~900 ms and the panel + each of the
  // three ride option rows pull their opacity from staggered Intervals
  // on it, so the container fades in first and the rows fade in after,
  // one by one, in quick succession. No slide, no scale — pure fade.
  late AnimationController _sheetCtrl;
  late Animation<double> _sheetOpacity;
  late Animation<double> _rowOpacity0;
  late Animation<double> _rowOpacity1;
  late Animation<double> _rowOpacity2;

  // ── Current location address ──
  String _currentAddress = '';
  bool _fetchingLocation = true;

  // ── Guard: only navigate to tracking once ──
  bool _navigatingToTracking = false;
  // ── Guard: rider initiated the cancel (skip redundant dialog) ──
  bool _riderInitiatedCancel = false;
  // ── Guard: cancel dialog already shown (prevents duplicate dialogs) ──
  bool _cancelDialogShown = false;

  // ── Payment state ──
  /// Nothing chosen until the rider chooses, or until a default they saved
  /// on purpose is loaded.
  ///
  /// This used to open on Apple Pay or Google Pay depending on the phone.
  /// Nobody picked that — the platform did — and it sat there looking
  /// decided, so a rider who never opened the payment screen was one tap
  /// away from paying by a method they had not agreed to. An empty value
  /// makes the row read "Choose a payment method", which is the truth.
  String _selectedPaymentMethod = '';

  /// The one account allowed to pay with Test Mode: App Review needs a way
  /// to complete a ride without a real card on file, and no real rider
  /// should ever be offered a payment option that moves no money.
  static const String _kTestModeAccount = 'applereview@cruiseinride.com';

  /// True only while that account is signed in. Resolved once at init.
  ///
  /// Read this for anything the rider only looks at. Anything that decides
  /// whether money moves must go through [_isTestModeActive] instead: this
  /// field is still false while the resolution is in flight.
  bool _testModeAllowed = false;

  /// The one resolution, shared by every caller. Two unawaited copies used
  /// to settle in whatever order they liked.
  Future<bool>? _testModeGate;

  /// Never completes with an error: a gate that throws is a gate some
  /// caller's catch block turns into a free ride.
  Future<bool> _ensureTestModeResolved() =>
      _testModeGate ??= _resolveTestModeAccount().catchError((Object e) {
        debugPrint('[RideRequest] test mode gate threw — denied: $e');
        return false;
      });

  /// The single place that decides a ride may skip the charge. The backend
  /// has no test_mode branch at all, so nothing downstream re-checks this.
  Future<bool> _isTestModeActive() async {
    final allowed = await _ensureTestModeResolved();
    if (!mounted) return false;
    return allowed && _selectedPaymentMethod == 'test_mode';
  }

  Future<bool> _resolveTestModeAccount() async {
    bool allowed = false;
    try {
      final user = await UserSession.getUser();
      final email = (user?['email'] ?? '').trim().toLowerCase();
      allowed = email == _kTestModeAccount;
    } catch (e) {
      debugPrint('[RideRequest] test mode account unreadable — denied: $e');
    }
    if (!allowed) {
      // Clearing only the field left the key in prefs, so the selection came
      // back on the next launch and the gate had nothing to catch it.
      try {
        if (await LocalDataService.getDefaultPaymentMethod() == 'test_mode') {
          await LocalDataService.setDefaultPaymentMethod('');
        }
      } catch (e) {
        debugPrint('[RideRequest] stored test mode not cleared: $e');
      }
    }
    if (!mounted) return allowed;
    if (allowed != _testModeAllowed) _setState(() => _testModeAllowed = allowed);
    // Someone who had Test Mode selected before this gate existed would
    // keep a stored method the picker no longer offers, leaving Request
    // Ride pointed at a payment that cannot be charged.
    if (!allowed && _selectedPaymentMethod == 'test_mode') {
      _setState(() => _selectedPaymentMethod = '');
    }
    return allowed;
  }

  Future<void> _restoreDefaultPaymentMethod() async {
    String? stored;
    try {
      stored = await LocalDataService.getDefaultPaymentMethod();
    } catch (e) {
      debugPrint('[RideRequest] default payment method not restored: $e');
      return;
    }
    if (!mounted) return;
    final id = stored;
    if (id == null || id.isEmpty) {
      // iPhone with Apple Pay available: it is the preselected default
      // (2026-08-22 spec). Android and unsupported devices keep the old
      // "choose a method" empty state.
      if (AppPlatform.isIOS && !kIsWeb) {
        try {
          final supported =
              await stripe.Stripe.instance.isPlatformPaySupported(
            googlePay: const stripe.IsGooglePaySupportedParams(),
          );
          if (supported && mounted) {
            _setState(() => _selectedPaymentMethod = 'apple_pay');
          }
        } catch (_) {}
      }
      return;
    }
    // Ordered on purpose: this restore and the gate resolution were both
    // unawaited futures, so whichever landed last won, and a stored
    // 'test_mode' landing second put the free ride back on the button.
    if (id == 'test_mode') {
      final allowed = await _ensureTestModeResolved();
      if (!mounted || !allowed) return;
    }
    _setState(() => _selectedPaymentMethod = id);
  }

  Set<String> _linkedPaymentMethods = {};
  String? _savedCardLast4;
  String? _savedCardBrand;
  String? _savedBankLast4; // linked bank account (ACH) last 4
  bool _isProcessingPayment = false;
  // Hard timeout that frees the Request Ride / Pay button if the payment
  // pipeline hangs (Stripe SDK never returns, OS sheet stuck, network
  // blip mid-IPC). Cancelled by the try/finally in the payment flow.
  Timer? _stuckPaymentFuse;
  bool _rideFlowLocked = false;
  bool _showPaymentDeclinedBanner = false;
  String? _heldPaymentIntentId;

  // ── Shake animation (disabled request button) ──
  late AnimationController _shakeCtrl;
  late Animation<double> _shakeAnim;
  final GoldLocationDot _goldDot = GoldLocationDot();

  // ── Searching overlay: splash first, then map with address bars ──
  bool _searchingShowMap = false;
  /// True while SearchingDriverScreen is on the navigator stack.
  /// Blocks _onStateChange from navigating away while the screen is visible.
  bool _searchingScreenShowing = false;
  bool _searchingSplash = false;
  Timer? _searchMapTimer;
  Timer? _splashTimer;

  // ── Route loading: hide idle state while route is being fetched ──
  bool _fetchingRoute = false;

  // ── Options loaded: tracks when ride options are ready (max 1s shimmer) ──
  bool _optionsLoaded = false;
  Timer? _shimmerTimeoutTimer;

  // ── Price shimmer while waiting for real route ──
  late AnimationController _priceShimmerCtrl;

  // ── Badge animation controllers (match home_screen style) ──
  late AnimationController _badgePremiumCtrl;
  late AnimationController _badgeComfortCtrl;

  // ── Active ride-card glow pulse (matches vipRide rideGlow 2.8s) ──
  late AnimationController _activeCardGlowCtrl;

  // ── Floating map labels (Flutter overlay — not baked bitmap) ──
  // These are updated via pixelForCoordinate every camera tick so they
  // track the pin tip exactly as the map tilts/pans/zooms.
  Offset? _pickupScreenOffset;
  Offset? _dropoffScreenOffset;
  bool _pickupLabelRevealed = false;
  bool _dropoffLabelRevealed = false;

  /// Last time the camera listener re-projected the label offsets — the
  /// 66 ms throttle that keeps label glue from flooding the platform
  /// channel during camera animations.
  DateTime _lastLabelSync = DateTime(2000);

  /// Interruption token for the cinematic. _startCinematicSequence captures
  /// it at takeoff and refuses to write ANY state after its awaits if it
  /// changed — without this, a cancel (or the search-phase takeover) reset
  /// the flags, and 2 s later the suspended sequence's tail re-wrote
  /// _cinematicDone = true over them, so the NEXT ride never animated.
  int _cinematicGen = 0;

  /// The browser map's controller, when there is one.
  ///
  /// Everything downstream of the picker asks the NATIVE controller where
  /// the camera is, and on web that is null — so dragging the map moved the
  /// pin and told nobody, and Confirm had no coordinate to confirm.
  WebMapController? _webMapCtrl;

  /// Measured on-screen height (px) of the choose-a-vehicle sheet.
  ///
  /// The camera fit used to guess the sheet's height (35%/42% of the
  /// screen) and the guess broke whenever the sheet grew — pick a tier and
  /// the detail row, payment row and Request Ride button pushed the route
  /// behind the panel. The sheet now reports its real height and every
  /// camera fit + the address bar anchor to the measurement; 0 means "not
  /// laid out yet" and falls back to the old estimate.
  double _sheetHeightPx = 0;

  /// Web only: the route polyline + endpoint pins have been pushed to the
  /// browser map. Native draws through the cinematic instead.
  bool _webRouteDrawn = false;

  /// Web only: drives the progressive route draw (the browser equivalent of
  /// the native _animateGoldRoute ticker). Cancelled on cleanup/dispose.
  Timer? _webRouteAnimTimer;

  /// True once a REAL (≥3-point) route line has been drawn on the web map.
  /// Distinct from [_webRouteDrawn], which claims the whole first-draw
  /// cinematic: with the 2-point placeholder the cinematic runs but the
  /// line is skipped, and this flag is what lets the road-snapped route
  /// animate in when it lands.
  bool _webRouteLineDrawn = false;

  /// Identity of the route currently pushed to the web map — endpoint
  /// coords + length. The controller notifies for tier taps and surge
  /// updates too; this is how those no-op instead of re-pushing the line
  /// and re-flying the camera.
  int _webRouteSig = 0;

  /// True once the rider drags or zooms the map themselves — automatic
  /// camera fits stop fighting their frame until they tap recenter.
  bool _userTookCamera = false;

  /// Web only: our own flyTo/fitBounds fire onCameraMove too; until this
  /// moment those are ignored so they don't read as a rider gesture.
  DateTime _webAutoCameraUntil = DateTime.fromMillisecondsSinceEpoch(0);

  /// Debounce for sheet-height refits: the panel animates ~380 ms and
  /// reports a new size every frame; fitting on each report made the
  /// camera bounce nonstop and tore the rider's own zoom apart.
  Timer? _sheetFitDebounce;

  /// One-shot suppression for the measured refit above. A collapse/expand
  /// of the choose-a-vehicle sheet fires a SYNCHRONIZED fit (same instant
  /// as the gesture, final height computed up front, 300 ms like the
  /// sheet's own AnimatedSize) — the debounced "fit after re-measure" that
  /// follows would be a second flight to the same place, so the next one
  /// after a synced fit is skipped. It stays as the backup for every
  /// height change that did NOT come from the toggle (tier pick, panel
  /// appearing, banner).
  bool _skipNextSheetRefit = false;

  /// Periodic refresh of the driver-availability answers on the sheet.
  /// "No drivers available" cached an hour ago was still on screen until
  /// the rider force-closed the app — while the sheet is open the answer
  /// is re-asked every 20 seconds instead.
  Timer? _waitRefreshTimer;

  // ── In-place map picker state (RiderPhase.pickingLocation) ──
  // Mirrors the Shopify widget's drop-a-pin mode but inside the same
  // Mapbox canvas — no Navigator push, no second map instance.
  bool _pickerIsPickup = false;
  String _pickerAddress = '';
  bool _pickerAddressIsPlaceholder = true;
  bool _pickerGeocodeFailed = false;
  bool _pickerLoading = false;
  bool _pickerConfirming = false;
  int _pickerGeocodeGen = 0;
  Timer? _pickerDebounce;
  AnimationController? _pickerSettleCtrl;
  Animation<double>? _pickerSettleAnim;
  AnimationController? _pickerAnchorCtrl;
  Animation<double>? _pickerAnchorAnim;
  Ticker? _pickerRippleTicker;
  double _pickerRippleElapsed = 0.0;
  final _pickerPlaces = PlacesService(ApiKeys.webServices);

  // ── Driver Found overlay ──
  bool _driverFoundVisible = false;
  Timer? _driverFoundTimer;
  final ValueNotifier<bool> _driverMatchedNotifier = ValueNotifier(false);
  AnimationController? _dfCheckCtrl;
  AnimationController? _dfStaggerCtrl;
  AnimationController? _dfShimmerCtrl;
  int _dfMsgIndex = 0;
  Timer? _dfMsgTimer;

  // ── Driver Found map (tilt + route + pins) ──
  mapbox.MapboxMap? _dfMapCtrl;
  AnimationController? _dfTiltCtrl;
  Animation<double>? _dfTiltAnim;

  // Combined pin+label bitmaps (raw bytes + anchor offset)
  bool _showPinLabels = true;
  (Uint8List, Uint8List)? _pickupPinOnly;
  (Uint8List, Uint8List)? _dropoffPinOnly;
  // Pin+label combined: (rawBytes, anchor, rawBytes) — anchor places pin tip at the LatLng
  (Uint8List, Offset, Uint8List)? _pickupPinWithLabel;
  (Uint8List, Offset, Uint8List)? _dropoffPinWithLabel;

  // Raw PNG bytes + anchor for each marker
  final Map<String, (Uint8List bytes, Offset anchor)> _markerBitmapData = {};

  @override
  void initState() {
    super.initState();
    // Seed the last-known camera from the SAME values the MapWidget boots
    // from. _lastCam* is otherwise null until the first onCameraChange event
    // — and if that listener does not fire for user gestures on iOS, it stays
    // null forever. Any platform-view recreation (cold start: covers and
    // transitions still settling) then boots from the handoff seed instead of
    // the live frame: the rider drags the picker to a street and the map snaps
    // back to the seed address. Seeded here, a recreation before any camera
    // event boots where the map already is (invisible) and a recreation after
    // a drag boots where the rider left it.
    //
    // In picker mode the handoff IS the selected prediction. Keep the map
    // center on that prediction too, so every fallback path (MapWidget
    // cameraOptions, WebMapView initial center, etc.) opens on the chosen
    // address and never silently falls back to the rider's live GPS.
    LatLng? handoffCenter;
    if (widget.pickerMode) {
      if (widget.handoffLat != null && widget.handoffLng != null) {
        handoffCenter = LatLng(widget.handoffLat!, widget.handoffLng!);
      } else if (!widget.pickerIsPickup && widget.initialDropoffDetails != null) {
        handoffCenter = LatLng(
          widget.initialDropoffDetails!.lat,
          widget.initialDropoffDetails!.lng,
        );
      } else if (widget.pickerIsPickup && widget.initialPickupDetails != null) {
        handoffCenter = LatLng(
          widget.initialPickupDetails!.lat,
          widget.initialPickupDetails!.lng,
        );
      }
    } else if (widget.handoffLat != null && widget.handoffLng != null) {
      handoffCenter = LatLng(widget.handoffLat!, widget.handoffLng!);
    }

    if (handoffCenter != null) {
      _lastCamCenter = handoffCenter;
      if (widget.pickerMode) _center = handoffCenter;
    } else if (_center != null) {
      _lastCamCenter = _center;
    }
    _lastCamZoom = widget.handoffZoom ?? 15.5;
    _lastCamPitch = widget.handoffPitch ?? 45.0;
    _lastCamBearing = widget.handoffBearing ?? 0.0;
    if (widget.pickerMode) {
      debugPrint('[PickerBoot] pickerMode handoff=${widget.handoffLat},${widget.handoffLng} '
          'pickerIsPickup=${widget.pickerIsPickup} '
          'lastCam=${_lastCamCenter?.latitude},${_lastCamCenter?.longitude} '
          'center=${_center?.latitude},${_center?.longitude}');
    }
    unawaited(_acquireMapSurface());

    // Restore the method the rider chose to keep, if they ever chose one.
    //
    // Only a deliberate "set as default" writes that value, so anything
    // found here was asked for. Nothing found means nothing preselected,
    // and the row says "Choose a payment method" — which is the honest
    // state for a rider who has never told us how they want to pay.
    unawaited(_restoreDefaultPaymentMethod());

    // Load Cruise Cash balance once so the picked vehicle card can show
    // the discount preview. Fire-and-forget — failure is silent (the
    // backend still applies it at dispatch time regardless).
    _loadCruiseCashBalance();

    _pulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _pulseAnim = Tween<double>(
      begin: 0.6,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _radarCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2400),
    )..repeat();
    _shimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();

    _sheetCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    _sheetOpacity = CurvedAnimation(
      parent: _sheetCtrl,
      curve: const Interval(0.0, 0.45, curve: Curves.easeInOutCubic),
    );
    // Row stagger — row 0 starts first, row 2 last.
    _rowOpacity0 = CurvedAnimation(
      parent: _sheetCtrl,
      curve: const Interval(0.35, 0.72, curve: Curves.easeOutCubic),
    );
    _rowOpacity1 = CurvedAnimation(
      parent: _sheetCtrl,
      curve: const Interval(0.48, 0.85, curve: Curves.easeOutCubic),
    );
    _rowOpacity2 = CurvedAnimation(
      parent: _sheetCtrl,
      curve: const Interval(0.60, 0.97, curve: Curves.easeOutCubic),
    );

    _priceShimmerCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();

    _badgePremiumCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1800),
    )..repeat();
    _badgeComfortCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat();

    // Pulsing gold glow on the active ride card (matches .vipRide
    // rideGlow CSS keyframes: 2.8s ease-in-out infinite).
    _activeCardGlowCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2800),
    )..repeat(reverse: true);

    // Max 1 second shimmer timeout — force show options after 1s
    _shimmerTimeoutTimer = Timer(const Duration(seconds: 1), () {
      if (mounted && !_optionsLoaded) {
        setState(() => _optionsLoaded = true);
      }
    });

    _shakeCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _shakeAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 0.0, end: -8.0), weight: 1),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: 8.0, end: -8.0), weight: 2),
      TweenSequenceItem(tween: Tween(begin: -8.0, end: 0.0), weight: 1),
    ]).animate(_shakeCtrl);

    // Enter the picker phase SYNCHRONOUSLY — before the state listener is
    // wired and before the setPickup/setDropoff calls further down. Those
    // fire _tryFetchRoute, whose "keep the picker phase" guard only holds
    // if the phase already IS pickingLocation. The old post-frame-only
    // entry left a pre-first-frame window in which the estimated route
    // published phase=previewRoute: the typed-dropoff path (search passes
    // BOTH endpoints) armed the route-preview machinery underneath the
    // picker, and the first frame rendered the wrong UI. The post-frame
    // call below stays as an idempotent backstop.
    if (widget.pickerMode) {
      _ctrl.startPickingLocation();
    }
    _ctrl.addListener(_onStateChange);
    // Wire in scheduled/airport params from widget
    if (widget.isAirportTrip) {
      _ctrl.setAirportTrip(true);
    }
    if (widget.scheduledAt != null) {
      _ctrl.setSchedule(widget.scheduledAt);
    }
    if ((widget.initialStopAddress ?? '').isNotEmpty) {
      _ctrl.setStopAddress(widget.initialStopAddress);
    }

    // ── Pre-populate map center from initial details so map renders instantly ──
    // In picker mode the center is already seeded to the selected prediction
    // (handoff) above. Do not override it with the rider's live pickup/GPS
    // here, or the map opens on the wrong location even though the handoff
    // coordinates were passed correctly.
    if (!widget.pickerMode) {
      if (widget.initialPickupDetails != null) {
        _center = LatLng(widget.initialPickupDetails!.lat, widget.initialPickupDetails!.lng);
      } else if (widget.initialDropoffDetails != null) {
        _center = LatLng(widget.initialDropoffDetails!.lat, widget.initialDropoffDetails!.lng);
      }
    } else if (_center == null) {
      // Absolute fallback: if the handoff seeding above somehow missed,
      // prefer the prediction we are about to pick.
      if (widget.pickerIsPickup && widget.initialPickupDetails != null) {
        _center = LatLng(widget.initialPickupDetails!.lat, widget.initialPickupDetails!.lng);
      } else if (!widget.pickerIsPickup && widget.initialDropoffDetails != null) {
        _center = LatLng(widget.initialDropoffDetails!.lat, widget.initialDropoffDetails!.lng);
      }
      // _initLocation no longer back-fills _center in picker mode (the GPS
      // overwrite was the snap-back), so it MUST be non-null here or the
      // map never mounts.
      _center ??= const LatLng(33.5186, -86.8104);
    }

    // ── Airport selection always takes priority ──
    // Applied after the first frame so the RiderTripController has a
    // chance to finish its initial state emission. Previously this was
    // nested inside an else-branch and could be skipped entirely when
    // the caller also passed initialPickupDetails / initialDropoffDetails.
    if (widget.airportSelection != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _autoApplyAirportSelection(widget.airportSelection!);
      });
    } else {
      // No airport — wipe any metadata carried over from a previous
      // airport trip so the dispatch payload doesn't leak.
      _ctrl.clearAirportMetadata();
    }

    // ── Pre-loaded route: skip the network fetch entirely ──
    if (widget.preloadedRoute != null &&
        widget.initialPickupDetails != null &&
        widget.initialDropoffDetails != null) {
      _ctrl.setPreloadedRoute(
        pickup: widget.initialPickupDetails!,
        pickupLabel: widget.initialPickupLabel ??
            widget.initialPickupDetails!.address,
        dropoff: widget.initialDropoffDetails!,
        dropoffLabel: widget.initialDropoffLabel ??
            widget.initialDropoffDetails!.address,
        route: widget.preloadedRoute!,
      );
      // Still resolve GPS for the user-dot overlay
      _locationReadyFuture = _initLocation();
    } else if (widget.initialPickupDetails != null && widget.initialDropoffDetails != null) {
      // Both locations already known — set immediately, don't wait for GPS
      _ctrl.setPickup(
        widget.initialPickupDetails!,
        widget.initialPickupLabel ?? widget.initialPickupDetails!.address,
      );
      _ctrl.setDropoff(
        widget.initialDropoffDetails!,
        widget.initialDropoffLabel ?? widget.initialDropoffDetails!.address,
      );
      // Resolve GPS in parallel for user-dot overlay only
      _locationReadyFuture = _initLocation();
    } else {
      _locationReadyFuture = _initLocation().then((_) {
        // Airport selection already handled above via post-frame callback.
        // Direct details available (e.g. from Choose on map) — use immediately
        if (widget.initialPickupDetails != null) {
          _ctrl.setPickup(
            widget.initialPickupDetails!,
            widget.initialPickupLabel ?? widget.initialPickupDetails!.address,
          );
        } else if (_userLocation != null && widget.initialDropoffDetails != null) {
          final curLabel = _currentAddress.isNotEmpty ? _currentAddress : 'current location';
          _ctrl.setPickup(
            PlaceDetails(
              address: curLabel,
              lat: _userLocation!.latitude,
              lng: _userLocation!.longitude,
            ),
            curLabel,
          );
        }
        if (widget.initialDropoffDetails != null) {
          _ctrl.setDropoff(
            widget.initialDropoffDetails!,
            widget.initialDropoffLabel ?? widget.initialDropoffDetails!.address,
          );
        } else if (widget.initialDropoffAddress != null) {
          // Fallback: re-geocode from address string
          _autoSetDropoff(widget.initialDropoffAddress!);
        }
      });
    }
    // GoldLocationDot replaced by LocationPuck — no dot annotation needed
    _loadLinkedPayments();
    unawaited(_ensureTestModeResolved());
    _loadPinIcon();

    // ── In-place map picker bootstrap ─────────────────────────────────
    // When pickerMode is true, arrive straight in the picking-location
    // phase so the same Mapbox canvas drives both the pin-drop UX and
    // the route preview — matching the Shopify widget's single-canvas
    // behavior.
    _pickerIsPickup = widget.pickerIsPickup;
    _pickerSettleCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _pickerSettleAnim = TweenSequence<double>([
      TweenSequenceItem(tween: Tween(begin: 1.0, end: 1.05), weight: 50),
      TweenSequenceItem(tween: Tween(begin: 1.05, end: 1.0), weight: 50),
    ]).animate(
      CurvedAnimation(parent: _pickerSettleCtrl!, curve: Curves.easeOut),
    );
    if (widget.pickerMode) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _ctrl.startPickingLocation();
        // Kick off a first geocode after the map has a moment to settle.
        Future.delayed(const Duration(milliseconds: 800), () {
          if (mounted) _pickerOnCameraIdle();
        });
      });
    }
  }


  /// Fetch the rider's Cruise Cash balance so the picked vehicle card
  /// can show "-$X.XX Cruise Cash" preview. Silent on failure — the
  /// backend still applies it at dispatch time regardless of the UI.
  Future<void> _loadCruiseCashBalance() async {
    try {
      // Always the real balance: since 2026-08-04 the sheet's toggle
      // selects Cruise Cash as the PAYMENT METHOD (exclusive with the
      // other rows), and the Request button needs the true balance to
      // decide whether it covers the fare.
      final res = await ApiService.getMyReferralInfo();
      final cents = (res['balance_cents'] as num?)?.toInt() ?? 0;
      if (mounted && cents != _cruiseCashCents) {
        setState(() => _cruiseCashCents = cents);
      }
    } catch (_) {/* silent — display only */}
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused) {
      _pulseCtrl.stop();
      _radarCtrl.stop();
      _shimmerCtrl.stop();
      _priceShimmerCtrl.stop();
      _badgePremiumCtrl.stop();
    } else if (state == AppLifecycleState.resumed) {
      final searching = _ctrl.state.phase == RiderPhase.searchingDriver;
      if (searching) _pulseCtrl.repeat();
      if (searching) _radarCtrl.repeat();
      _shimmerCtrl.repeat();
      _priceShimmerCtrl.repeat();
      _badgePremiumCtrl.repeat();
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) mapRouteObserver.subscribe(this, route);
  }

  /// Claim the one live Mapbox surface before mounting the map.
  Future<void> _acquireMapSurface() async {
    await MapSurfaceCoordinator.instance.acquire(
      owner: _mapSurfaceOwner,
      onRevoke: () async {
        if (!mounted || !_mapMounted) return;
        debugPrint('[CamSnap] SURFACE REVOKED — map will rebuild at initial camera');
        // Every annotation handle belongs to the PlatformView being
        // destroyed, so they all go with it — nulling them here (mirror of
        // driver_online_controller._releaseMapSurface) is what stops later
        // writes from poking a dead native channel. onMapCreated re-seeds
        // them against the fresh map on remount.
        _mapCtrl = null;
        _polylineAnnotMgr = null;
        _pointAnnotMgr = null;
        _pickupAnnot = null;
        _dropoffAnnot = null;
        _routeAnnot = null;
        _setState(() => _mapMounted = false);
        await surfaceRemoved();
      },
    );
    if (!mounted) {
      MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
      return;
    }
    debugPrint('[CamSnap] acquire ok (mapMounted=true)');
    _setState(() => _mapMounted = true);
  }

  /// Back from the picker (or anything else that took the surface) — take
  /// it back. The camera handoff below restores the spot the rider picked,
  /// so a fresh mount lands where they left off.
  @override
  void didPopNext() {
    if (!mounted || _mapMounted) return;
    unawaited(_acquireMapSurface());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    mapRouteObserver.unsubscribe(this);
    MapSurfaceCoordinator.instance.release(_mapSurfaceOwner);
    _shimmerTimeoutTimer?.cancel();
    _stuckPaymentFuse?.cancel();
    _waitRefreshTimer?.cancel();
    _webRouteAnimTimer?.cancel();
    _searchMapTimer?.cancel();
    _splashTimer?.cancel();
    _driverFoundTimer?.cancel();
    _driverMatchedNotifier.dispose();
    _dfCheckCtrl?.dispose();
    _dfStaggerCtrl?.dispose();
    _dfShimmerCtrl?.dispose();
    _dfTiltCtrl?.dispose();
    _dfMsgTimer?.cancel();
    _goldDot.dispose();
    _ctrl.removeListener(_onStateChange);
    _ctrl.dispose();
    _pulseCtrl.dispose();
    _radarCtrl.dispose();
    _shimmerCtrl.dispose();
    _searchStatusTimer?.cancel();
    _searchElapsedTimer?.cancel();
    _sheetCtrl.dispose();
    _priceShimmerCtrl.dispose();
    _badgePremiumCtrl.dispose();
    _badgeComfortCtrl.dispose();
    _activeCardGlowCtrl.dispose();
    _pickerDebounce?.cancel();
    _pickerSettleCtrl?.dispose();
    _pickerAnchorCtrl?.dispose();
    _pickerRippleTicker?.dispose();
    _shakeCtrl.dispose();
    // Nulled the instant they're disposed, and BEFORE _cleanupMapAnnotations()
    // runs seven lines down. That cleanup does `_tiltCtrl?.stop()`, and
    // `_resetCinematic()` stops all four in a row — `?.` guards a null FIELD,
    // not a DEAD controller. `AnimationController.stop()` is
    // `assert(_ticker != null, 'stop() called after dispose'); _ticker!.stop()`,
    // and the assert is compiled out of release, so the bare `!` threw
    // "Null check operator used on a null value" on every rider who left this
    // screen with a route drawn (top Crashlytics crash on 1.0.9; AOT inlined
    // stop() so the report blamed this file, not the framework). With the
    // fields null the `?.` short-circuits and there is nothing left to deref.
    // Same shape _cancelSearching() already uses for _dfCheckCtrl/_searchCamCtrl.
    _searchCamCtrl?.dispose();
    _searchCamCtrl = null;
    _tiltCtrl?.dispose();
    _tiltCtrl = null;
    _bearingCtrl?.dispose();
    _bearingCtrl = null;
    _pinPopCtrl?.dispose();
    _pinPopCtrl = null;
    _labelPopCtrl?.dispose();
    _labelPopCtrl = null;
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;
    // Clean up map annotations on dispose to prevent ghost routes
    _cleanupMapAnnotations();
    super.dispose();
  }

  // ── State updates from controller ──

  bool _didAutoSelectRide = false;

  // ═══════════════════════════════════════════════════════
  //  BUILD
  // ═══════════════════════════════════════════════════════

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final isDark = c.isDark;
    final topPad = MediaQuery.of(context).padding.top;
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final phase = _ctrl.state.phase;

    // Block system back button while ride is being confirmed / searching for driver
    final blockBack = phase == RiderPhase.requesting ||
        phase == RiderPhase.searchingDriver ||
        phase == RiderPhase.driverAssigned;

    return PopScope(
      canPop: !blockBack,
      child: AnnotatedRegion<SystemUiOverlayStyle>(
      value: isDark ? SystemUiOverlayStyle.light : SystemUiOverlayStyle.dark,
      child: Scaffold(
        body: Stack(
          children: [
            // ── Map ──
            if (_center == null)
              Container(
                color: const Color(0xFF07080D),
                child: const Center(
                  child: CircularProgressIndicator(color: Color(0xFFE8C547), strokeWidth: 2),
                ),
              )
            // The Driver Found overlay used to bring its OWN full-screen
            // map, and the base map was swapped for this black box to
            // avoid two live Mapbox surfaces (the iOS crash). The overlay
            // map took longer to init than the overlay lived, so the
            // rider saw a BLACK SCREEN instead of "driver found" (user
            // report 2026-08-04). The overlay now draws its scrim over
            // THIS live map (one surface, no black window) — only a real
            // unmount blacks the slot.
            else if (!_mapMounted)
              const ColoredBox(color: Color(0xFF07080D))
            // Same reason as the driver's online screen: Mapbox GL JS in the
            // browser, the native SDK everywhere else.
            else if (kIsWeb)
              WebMapView(
                // Same boot frame as native: the handoff camera from the
                // previous map when there is one, otherwise the rider at
                // 15.5 with the 45° house tilt — never a flat zoom-14
                // teleport.
                initialLng: widget.handoffLng ?? _center!.longitude,
                initialLat: widget.handoffLat ?? _center!.latitude,
                initialZoom: widget.handoffZoom ?? 15.5,
                initialBearing: widget.handoffBearing ?? 0.0,
                initialPitch: widget.handoffPitch ?? 45.0,
                styleUri: MapboxConfig.styleDark,
                onControllerCreated: (c) {
                  _webMapCtrl = c;
                  // The same navy/gold the native map gets in
                  // _applyDarkNavyGoldTheme — raw dark-v11 is grey, not ours.
                  c.applyNavyGoldTheme();
                  // Streets + our pins only, same as the native path's
                  // MapTheme.hidePoiLayers after the theme.
                  c.hidePoiLayers();
                  // The ONLY trustworthy "rider took the camera" signal —
                  // GL JS 'move' also fires for our own flights and even
                  // for resize, which used to poison _userTookCamera and
                  // silently kill every later auto-frame.
                  c.onUserGesture = () {
                    if (mounted) _userTookCamera = true;
                  };
                  // The preloaded-route notify fires in initState, before
                  // this controller exists — without this catch-up the two
                  // main entry paths left the browser map empty.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted) return;
                    if (_ctrl.state.route != null) {
                      unawaited(_drawWebRouteOnce());
                    }
                  });
                  // The same two hooks the native map wires below, so the
                  // pin under the finger geocodes as the map is dragged.
                  c.onCameraMove = (_, __, ___) {
                    if (!mounted) return;
                    // _userTookCamera moved to onUserGesture above: this
                    // event also fires for our own flights and resizes.
                    if (_ctrl.state.phase == RiderPhase.pickingLocation) {
                      _pickerScheduleGeocode();
                    }
                    // Keep the floating pickup/dropoff labels glued to
                    // their pins while the camera moves — the same job the
                    // native onCameraChangeListener does. Synchronous GL JS
                    // projection, so per-frame is cheap.
                    if (_pickupLabelRevealed || _dropoffLabelRevealed) {
                      unawaited(_syncLabelOffsets());
                    }
                  };
                  c.onReady = () {
                    if (!mounted) return;
                    if (_ctrl.state.phase == RiderPhase.pickingLocation) {
                      _pickerScheduleGeocode();
                    }
                  };
                },
              )
            else
              RepaintBoundary(
                child: mapbox.MapWidget(
                  textureView: true,
                  styleUri: MapboxConfig.styleDark,
                  onMapLoadErrorListener: (err) => debugPrint('[RideRequest] Load error: ${err.message} (type: ${err.type})'),
                  // Boot camera: the LAST place the rider left the map, not
                  // the handoff or the GPS fix. PlatformViews get destroyed
                  // and recreated (GPU pressure, the coordinator's handoff)
                  // and a fresh map boots from cameraOptions — the picker's
                  // "snap back to my location" was exactly that reset. With
                  // the last known frame as the boot frame, a rebuild is
                  // invisible no matter what causes it.
                  //
                  // Picker mode goes through the SAME chain (2026-08-11).
                  // Build 575 special-cased it to the handoff seed, which
                  // re-opened the cold-start bug the chain exists to close:
                  // every recreation UNDID the rider's drag and re-centered
                  // the pin on the seed — for "Choose on map" the seed is
                  // the rider's own location, hence "the pin keeps snapping
                  // to me and only right after app open" (recreations are a
                  // cold-start thing; a warm session has none). The fear
                  // behind 575 — GPS leaking into the boot frame — is now
                  // structurally impossible: initState seeds _lastCam* from
                  // the handoff, onCameraChange feeds it real frames only,
                  // and in picker mode GPS never writes _center (1870dfeb)
                  // nor the camera (_gpsMayMoveCamera hard-closes).
                  cameraOptions: mapbox.CameraOptions(
                    center: mapbox.Point(
                      coordinates: mapbox.Position(
                        _lastCamCenter?.longitude ??
                            widget.handoffLng ?? _center!.longitude,
                        _lastCamCenter?.latitude ??
                            widget.handoffLat ?? _center!.latitude,
                      ),
                    ),
                    zoom: _lastCamZoom ?? widget.handoffZoom ?? 15.5,
                    bearing: _lastCamBearing ?? widget.handoffBearing ?? 0.0,
                    pitch: _lastCamPitch ?? widget.handoffPitch ?? 45.0,
                  ),
                  onMapCreated: (ctrl) async {
                    // [CamSnap] hunt: a SECOND onMapCreated on this screen
                    // means the platform view was destroyed and rebuilt —
                    // which is exactly what resets the camera to the initial
                    // frame (the rider's own location, tilt gone) and reads
                    // as "the picker snapped back".
                    debugPrint('[CamSnap] onMapCreated phase=${_ctrl.state.phase} '
                        'pickerMode=${widget.pickerMode} mountedWas=$_mapMounted');
                    _mapCtrl = ctrl;
                    // A fresh surface starts with a clean write gate. The
                    // old one may have been revoked mid-write, leaving
                    // `_camWriteInFlight` true and a stale frame pending —
                    // which would make the new map ignore every camera
                    // push it ever receives.
                    _camWriteInFlight = false;
                    _pendingCam = null;
                    // Cache controller for reuse across rider screens
                    MapControllerCache.instance.cache(ctrl);
                    try {
                      ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
                      ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
                      ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
                      ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
                    } catch (_) {}
                    // Polyline below labels, points always on top.
                    //
                    // Guarded across the awaits: the rider can pop this sheet
                    // or pick a vehicle and be pushed onward before the
                    // managers land, and finishing the setup against a map
                    // that has been torn down is a native crash, not an
                    // exception.
                    final poly = await ctrl.annotations.createPolylineAnnotationManager(
                      below: "road-label",
                    );
                    if (!mounted || !identical(_mapCtrl, ctrl)) return;
                    _polylineAnnotMgr = poly;
                    final point = await ctrl.annotations.createPointAnnotationManager();
                    if (!mounted || !identical(_mapCtrl, ctrl)) return;
                    _pointAnnotMgr = point;
                    // Retry _drawRoute now that managers are ready. If the
                    // controller fired previewRoute before the map finished
                    // loading, _drawRoute bailed early — this is our catch-up.
                    // Not in the map picker: a route draw here also starts the
                    // route-fit flight, which is the picker's snap-back.
                    if (mounted) {
                      final s = _ctrl.state;
                      if (s.route != null &&
                          s.pickup != null &&
                          s.dropoff != null &&
                          !widget.pickerMode &&
                          s.phase != RiderPhase.pickingLocation) {
                        if (s.phase == RiderPhase.requesting ||
                            s.phase == RiderPhase.searchingDriver) {
                          // Surface remounted after the pickup pin page was
                          // popped: the old native view took the pins/route
                          // with it — redraw directly, no cinematic replay.
                          unawaited(_updateRouteAnnotation(
                              List<LatLng>.from(s.route!.points)));
                          unawaited(_buildRouteMarkers());
                        } else if (!_cinematicDone && !_cinematicRunning) {
                          _drawRoute();
                        }
                      }
                    }
                    try {
                      final lid = _pointAnnotMgr!.id;
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-pitch-alignment', 'viewport');
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-rotation-alignment', 'viewport');
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-anchor', 'bottom');
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-ignore-placement', true);
                    } catch (_) {}
                    if (mounted) setState(() => _mapReady = true);
                  },
                  onStyleLoadedListener: (_) async {
                    if (_mapCtrl != null) {
                      await _applyDarkNavyGoldTheme(_mapCtrl!);
                      if (_pointAnnotMgr != null) {
                        try {
                          final lid = _pointAnnotMgr!.id;
                          await _mapCtrl!.style.setStyleLayerProperty(lid, 'icon-pitch-alignment', 'viewport');
                          await _mapCtrl!.style.setStyleLayerProperty(lid, 'icon-rotation-alignment', 'viewport');
                          await _mapCtrl!.style.setStyleLayerProperty(lid, 'icon-anchor', 'bottom');
                          await _mapCtrl!.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
                          await _mapCtrl!.style.setStyleLayerProperty(lid, 'icon-ignore-placement', true);
                        } catch (_) {}
                      }
                      // Gold dot puck disabled — user asked for it to
                      // be removed from this page. The pickup/dropoff
                      // pins already show the rider's position clearly.
                      try {
                        await _mapCtrl!.location.updateSettings(
                          mapbox.LocationComponentSettings(enabled: false),
                        );
                      } catch (_) {}
                    }
                  },
                  onCameraChangeListener: (cam) {
                    // Track the last live frame so a recreated MapWidget
                    // boots HERE instead of at the handoff/GPS frame (the
                    // picker's snap-back). Cheap: four assignments, no IPC.
                    final c = cam.cameraState.center.coordinates;
                    _lastCamCenter =
                        LatLng(c.lat.toDouble(), c.lng.toDouble());
                    _lastCamZoom = cam.cameraState.zoom;
                    _lastCamPitch = cam.cameraState.pitch;
                    _lastCamBearing = cam.cameraState.bearing;
                    // Throttled: this fires per camera frame, and each sync
                    // is two awaited pixelForCoordinate IPCs. Unthrottled it
                    // pushed ~120 round-trips/s into the channel DURING the
                    // cinematic (whose own setCamera writes share it) —
                    // visible stutter on iOS ProMotion. 66 ms ≈ 15 fps is
                    // plenty for label glue, and while no label is revealed
                    // there is nothing to glue at all.
                    if (_pickupLabelRevealed || _dropoffLabelRevealed) {
                      final now = DateTime.now();
                      if (now.difference(_lastLabelSync).inMilliseconds >= 66) {
                        _lastLabelSync = now;
                        _syncLabelOffsets();
                      }
                    }
                    if (_ctrl.state.phase == RiderPhase.pickingLocation) {
                      _pickerScheduleGeocode();
                    }
                  },
                  // The rider took the camera — stop auto-fitting over
                  // their own pan/zoom until they tap recenter.
                  onScrollListener: (_) => _userTookCamera = true,
                  onZoomListener: (_) => _userTookCamera = true,
                  onMapIdleListener: (_) {
                    if (_ctrl.state.phase == RiderPhase.pickingLocation) {
                      _pickerSettleCtrl?.forward(from: 0);
                      _pickerScheduleGeocode();
                    }
                  },
                ),
              ),

            // ── Floating animated map labels (RECOGIDA / DESTINO) ──
            // Sit directly over the pin tips via pixelForCoordinate.
            // Shown during preview, ride selection AND while searching
            // for a driver — keeps the map readable instead of leaving
            // bare pins floating with no context.
            if (phase == RiderPhase.previewRoute ||
                phase == RiderPhase.selectingRide ||
                phase == RiderPhase.searchingDriver)
              ..._buildFloatingLabels(),

            // ── In-place map picker overlays ──
            if (phase == RiderPhase.pickingLocation) ...[
              // Centered teardrop pin with settle bounce + drop anchor.
              Center(
                child: Transform.translate(
                  offset: Offset(
                    0,
                    -(46 * 1.0 / 2) + (_pickerAnchorAnim?.value ?? 0.0),
                  ),
                  child: ScaleTransition(
                    scale: _pickerSettleAnim ??
                        const AlwaysStoppedAnimation(1.0),
                    child: CircularMapPin(
                      size: 46,
                      icon: _pickerIsPickup
                          ? CircularPinIcon.person
                          : CircularPinIcon.flag,
                      isPickup: _pickerIsPickup,
                    ),
                  ),
                ),
              ),
              // Top pill: "Move map to set dropoff/pickup location".
              Positioned(
                top: topPad + 10,
                left: 0,
                right: 0,
                child: Row(
                  children: [
                    const SizedBox(width: 54),
                    Expanded(
                      child: Center(
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 16, vertical: 10),
                          constraints: BoxConstraints(
                            maxWidth:
                                MediaQuery.of(context).size.width * 0.72,
                          ),
                          decoration: neuBox(radius: 100),
                          child: Text(
                            _pickerIsPickup
                                ? S.of(context).moveMapToSetPickup
                                : S.of(context).moveMapToSetDropoff,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              fontFamily: 'Poppins',
                              color: Colors.white.withValues(alpha: 0.78),
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 54),
                  ],
                ),
              ),
              // Bottom floating "Set your drop-off" card — lifted a touch
              // off the edge so it floats over the map like the rest of
              // the panels instead of hugging the bezel.
              //
              // The recenter button is REMOVED from the picker (2026-08-09):
              // the rider is dragging a pin to a destination, and a tap on
              // "center on my location" flies the camera back to their GPS
              // mid-drag — the exact snap-back they report. The button stays
              // in route preview and searching, where re-centering makes sense.
              Positioned(
                left: 10,
                right: 10,
                bottom: 28,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    _buildPickerFooter(),
                  ],
                ),
              ),
            ],

            // ── Back button ──
            Positioned(
              top: topPad + 8,
              left: 12,
              child: AnimatedScale(
                scale: phase != RiderPhase.idle ? 1.0 : 0.0,
                duration: const Duration(milliseconds: 250),
                curve: Curves.easeOutBack,
                child: AnimatedOpacity(
                  opacity: (phase != RiderPhase.idle && !blockBack) ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: phase == RiderPhase.idle || blockBack,
                    child: _circleButton(
                      icon: Icons.arrow_back,
                      onTap: () {
                        _cleanupMapAnnotations();
                        // Back out of the pin-drop step without wiping the
                        // trip: the search screen this returns to still
                        // holds the addresses the rider typed, and
                        // _ctrl.reset() would drop them on the floor.
                        // Every other phase is a committed step, so those
                        // do reset before leaving to keep a fresh search
                        // from inheriting stale route state.
                        if (phase != RiderPhase.pickingLocation) {
                          _ctrl.reset();
                        }
                        _nav?.pop();
                      },
                      c: c,
                    ),
                  ),
                ),
              ),
            ),

            // ── Recenter button — always available while a route/pin is
            // on screen, so the rider can re-frame as many times as they
            // like. It used to be gated on _userMovedMap, which the
            // recenter itself cleared, so it vanished on first tap.
            //
            // Right edge, riding just ABOVE the bottom sheet (user spec
            // 2026-08-04 — was top-right). AnimatedPositioned so it
            // travels with the sheet's own 380ms grow/shrink instead of
            // teleporting when a tier is picked.
            //
            // Only for the phases whose panel actually reports its height.
            // The picker and the searching card carry their own copy of
            // this button, welded above their own card: anchoring them to
            // _sheetHeightPx left the button floating in the middle of the
            // map (stale height) or sitting on top of the card (no report
            // at all).
            if (phase != RiderPhase.idle &&
                phase != RiderPhase.pickingLocation &&
                phase != RiderPhase.requesting &&
                phase != RiderPhase.searchingDriver &&
                phase != RiderPhase.driverAssigned)
              AnimatedPositioned(
                duration: const Duration(milliseconds: 380),
                curve: Curves.easeInOutCubicEmphasized,
                right: 12,
                bottom:
                    (_sheetHeightPx > 0 ? _sheetHeightPx + _sheetScreenGap : 160) +
                        14,
                child: AnimatedScale(
                  scale: 1.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeOutBack,
                  child: _circleButton(
                    icon: Icons.my_location_rounded,
                    onTap: _recenterMap,
                    c: c,
                  ),
                ),
              ),

            // ── Route loading indicator: subtle pill while route is fetching ──
            if (_fetchingRoute && !_ctrl.state.routeFetchFailed)
              Positioned(
                top: topPad + 60,
                left: 0,
                right: 0,
                child: IgnorePointer(
                  child: Center(
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                      decoration: BoxDecoration(
                        color: const Color(0xFF07080D).withValues(alpha: 0.85),
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SizedBox(
                            width: 16, height: 16,
                            child: CircularProgressIndicator(
                              color: Color(0xFFE8C547),
                              strokeWidth: 2,
                            ),
                          ),
                          SizedBox(width: 10),
                          Text(
                            'Finding best route…',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),

            // ── "Where to?" pill (idle, hidden while fetching route) ──
            _buildWhereToBar(c, topPad, phase == RiderPhase.idle && !_fetchingRoute),

            // ── Route preview sheet ──
            if (phase == RiderPhase.previewRoute ||
                phase == RiderPhase.selectingRide)
              _buildRoutePreviewSheet(c, bottomPad),

            // ── Searching bottom card (map visible behind) ──
            if ((phase == RiderPhase.requesting ||
                    phase == RiderPhase.searchingDriver ||
                    phase == RiderPhase.driverAssigned) &&
                _searchingShowMap)
              _buildSearchingBottomCard(c),

            // ── Driver Found overlay ──
            if (_driverFoundVisible && _ctrl.state.driver != null)
              _buildDriverFoundOverlay(c),
          ],
        ),
      ),
    ),
    );
  }


  // ── Searching bottom card — premium animated "Looking for ride" ──

  // ── In-place map picker footer — same layout as the old MapPickerScreen
  //    footer, now living inside RideRequestScreen so the map stays alive.
  Widget _buildPickerFooter() {
    final s = S.of(context);
    final canConfirm = !_pickerLoading &&
        !_pickerConfirming &&
        !_pickerAddressIsPlaceholder &&
        _pickerAddress.isNotEmpty;
    return Container(
      padding: EdgeInsets.fromLTRB(
          20, 22, 20, 22 + MediaQuery.of(context).padding.bottom),
      decoration: neuBox(radius: 22),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            _pickerIsPickup ? s.setYourPickup : s.setYourDropoff,
            style: const TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.4,
              height: 1.1,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            _pickerIsPickup
                ? s.moveMapToPreferredPickup
                : s.moveMapToPreferredDropoff,
            style: TextStyle(
              fontFamily: 'Poppins',
              color: Colors.white.withValues(alpha: 0.5),
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 14),
          GestureDetector(
            onTap: _pickerGeocodeFailed ? _pickerOnCameraIdle : null,
            child: Container(
              padding: const EdgeInsets.all(14),
              decoration: neuBox(radius: 14, pressed: true),
              child: Row(
                children: [
                  Container(
                    width: 32,
                    height: 32,
                    alignment: Alignment.center,
                    decoration: neuBox(radius: 11),
                    child: const Icon(Icons.search_rounded,
                        color: Color(0xFFE8C547), size: 16),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.locationCaps,
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: const Color(0xFFE8C547)
                                .withValues(alpha: 0.75),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.4,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          _pickerAddressIsPlaceholder || _pickerAddress.isEmpty
                              ? (_pickerLoading
                                  ? s.findingAddress
                                  : s.pinnedLocation)
                              : _pickerAddress,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: 'Poppins',
                            color: Colors.white.withValues(
                                alpha: (_pickerAddressIsPlaceholder ||
                                        _pickerAddress.isEmpty)
                                    ? 0.45
                                    : 1.0),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_pickerGeocodeFailed)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.refresh_rounded,
                          color: Color(0xFFE8C547), size: 18),
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: canConfirm ? _pickerConfirm : null,
            child: AnimatedOpacity(
              duration: const Duration(milliseconds: 160),
              opacity: canConfirm ? 1.0 : 0.35,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 18),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFFF5DC7A),
                      Color(0xFFE8C547),
                      Color(0xFFD4A800),
                    ],
                  ),
                  borderRadius: BorderRadius.circular(100),
                  boxShadow: const [
                    BoxShadow(
                      color: Color(0x40E8C547),
                      blurRadius: 16,
                      offset: Offset(0, 4),
                    ),
                  ],
                ),
                alignment: Alignment.center,
                child: Text(
                  s.confirmLabel,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    color: Color(0xFF0A0E1A),
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Draws a gold circle + animated checkmark tick.
class _CheckmarkPainter extends CustomPainter {
  final double progress;
  final Color color;
  _CheckmarkPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final r = size.width / 2;

    // Circle fill
    final circlePaint = Paint()..color = color.withValues(alpha: 0.12);
    canvas.drawCircle(center, r * progress.clamp(0.0, 1.0), circlePaint);

    // Circle border
    final borderPaint = Paint()
      ..color = color.withValues(alpha: (progress * 0.6).clamp(0.0, 0.6))
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(center, r, borderPaint);

    // Checkmark (draws after first 35% of animation)
    final checkProgress = ((progress - 0.35) / 0.65).clamp(0.0, 1.0);
    if (checkProgress > 0) {
      final path = Path();
      final p1 = Offset(size.width * 0.28, size.height * 0.52);
      final p2 = Offset(size.width * 0.44, size.height * 0.68);
      final p3 = Offset(size.width * 0.72, size.height * 0.35);

      // First leg
      final leg1 = ((checkProgress) / 0.5).clamp(0.0, 1.0);
      path.moveTo(p1.dx, p1.dy);
      path.lineTo(
        p1.dx + (p2.dx - p1.dx) * leg1,
        p1.dy + (p2.dy - p1.dy) * leg1,
      );

      // Second leg
      if (checkProgress > 0.5) {
        final leg2 = ((checkProgress - 0.5) / 0.5).clamp(0.0, 1.0);
        path.lineTo(
          p2.dx + (p3.dx - p2.dx) * leg2,
          p2.dy + (p3.dy - p2.dy) * leg2,
        );
      }

      final checkPaint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      canvas.drawPath(path, checkPaint);
    }
  }

  @override
  bool shouldRepaint(_CheckmarkPainter old) =>
      old.progress != progress || old.color != color;
}
