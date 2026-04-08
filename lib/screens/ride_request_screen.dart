import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter_stripe/flutter_stripe.dart' as stripe;
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
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/payment_service.dart';
import '../services/analytics_service.dart';
import '../services/places_service.dart';
import '../state/rider_trip_controller.dart';
import 'credit_card_screen.dart';
import 'payment_accounts_screen.dart';
import 'paypal_checkout_screen.dart';
import 'pickup_dropoff_search_screen.dart';
import 'ride_options_sheet.dart';
import 'rider_tracking_screen.dart';
import 'airport_terminal_sheet.dart';
import '../l10n/app_localizations.dart';
import '../widgets/gold_location_dot.dart';
import '../widgets/gold_pin_renderer.dart';

import '../widgets/map/circular_pin_renderer.dart';
import '../widgets/verified_avatar.dart';
import 'ride_booking_confirmed_screen.dart';
import 'scheduled_rides_screen.dart';
import 'searching_driver_screen.dart';
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
  final String? initialPickupLabel;
  final String? initialDropoffLabel;
  final RouteResult? preloadedRoute;
  final String? initialRideId;
  const RideRequestScreen({
    super.key,
    this.fastRide = false,
    this.applyPromo = false,
    this.isAirportTrip = false,
    this.scheduledAt,
    this.airportSelection,
    this.initialDropoffAddress,
    this.initialPickupDetails,
    this.initialDropoffDetails,
    this.initialPickupLabel,
    this.initialDropoffLabel,
    this.preloadedRoute,
    this.initialRideId,
  });

  @override
  State<RideRequestScreen> createState() => _RideRequestScreenState();
}


const _gold = Color(0xFFE8C547);
const _cardGold = Color(0xFFE8C547);
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
const List<(double, double)> _searchCameraAngles = [
  (55.0, 12.0),   // Looking for your driver — subtle right
  (45.0, -30.0),  // Connecting — wider left turn
  (60.0, 25.0),   // Almost there — tighter, right
  (50.0, -10.0),  // Confirming — settling back center-left
];

class _RideRequestScreenState extends State<RideRequestScreen>
    with TickerProviderStateMixin {
  void _setState(VoidCallback fn) { setState(fn); }
  // ── Map ──
  mapbox.MapboxMap? _mapCtrl;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;
  mapbox.PointAnnotation? _goldDotAnnot;
  mapbox.PointAnnotation? _userDotAnnot;
  mapbox.PolylineAnnotation? _routeAnnot;
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
  AnimationController? _labelPopCtrl;
  Animation<double>? _labelPopAnim;
  LatLng? _center;
  LatLng? _userLocation;
  bool _mapReady = false;

  // ── Trip controller ──
  final RiderTripController _ctrl = RiderTripController();

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

  // ── Search camera cycling (synced with status text) ──
  AnimationController? _searchCamCtrl;
  Animation<double>? _searchPitchAnim;
  Animation<double>? _searchBearingAnim;

  // ── Bottom sheet ──
  late AnimationController _sheetCtrl;
  late Animation<double> _sheetSlide;

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
  String _selectedPaymentMethod = Platform.isIOS ? 'apple_pay' : 'google_pay';
  Set<String> _linkedPaymentMethods = {};
  String? _savedCardLast4;
  String? _savedCardBrand;
  bool _isProcessingPayment = false;
  bool _rideFlowLocked = false;
  bool _showPaymentDeclinedBanner = false;
  String? _heldPaymentIntentId;

  // ── Map interaction state ──
  bool _userMovedMap = false;

  // ── Shake animation (disabled request button) ──
  late AnimationController _shakeCtrl;
  late Animation<double> _shakeAnim;
  bool _rideOptionsExpanded = true;
  bool _programmaticCam = false;
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

  // ── Driver Found overlay ──
  bool _driverFoundVisible = false;
  Timer? _driverFoundTimer;
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
      duration: const Duration(milliseconds: 400),
    );
    _sheetSlide = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _sheetCtrl, curve: Curves.easeOutBack));

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

    _ctrl.addListener(_onStateChange);
    // Wire in scheduled/airport params from widget
    if (widget.isAirportTrip) {
      _ctrl.setAirportTrip(true);
    }
    if (widget.scheduledAt != null) {
      _ctrl.setSchedule(widget.scheduledAt);
    }

    // ── Pre-populate map center from initial details so map renders instantly ──
    if (widget.initialPickupDetails != null) {
      _center = LatLng(widget.initialPickupDetails!.lat, widget.initialPickupDetails!.lng);
    } else if (widget.initialDropoffDetails != null) {
      _center = LatLng(widget.initialDropoffDetails!.lat, widget.initialDropoffDetails!.lng);
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
      _initLocation();
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
      _initLocation();
    } else {
      _initLocation().then((_) {
        // Auto-geocode airport and apply as pickup or dropoff based on direction
        if (widget.airportSelection != null) {
          _autoApplyAirportSelection(widget.airportSelection!);
        }
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
    _loadPinIcon();
  }


  @override
  void dispose() {
    _shimmerTimeoutTimer?.cancel();
    _searchMapTimer?.cancel();
    _splashTimer?.cancel();
    _driverFoundTimer?.cancel();
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
    _shakeCtrl.dispose();
    _tiltCtrl?.dispose();
    _bearingCtrl?.dispose();
    _pinPopCtrl?.dispose();
    _labelPopCtrl?.dispose();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
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
            else
              RepaintBoundary(
                child: mapbox.MapWidget(
                  styleUri: MapboxConfig.styleDark,
                  cameraOptions: mapbox.CameraOptions(
                    center: mapbox.Point(coordinates: mapbox.Position(_center!.longitude, _center!.latitude)),
                    zoom: 15.5,
                    pitch: 45.0,
                  ),
                  onMapCreated: (ctrl) async {
                    _mapCtrl = ctrl;
                    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
                    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
                    ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
                    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
                    // Polyline below labels, points always on top
                    _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
                      below: "road-label",
                    );
                    _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
                    try {
                      final lid = _pointAnnotMgr!.id;
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-pitch-alignment', 'viewport');
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-rotation-alignment', 'viewport');
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-anchor', 'bottom');
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-allow-overlap', true);
                      await ctrl.style.setStyleLayerProperty(lid, 'icon-ignore-placement', true);
                    } catch (_) {}
                    setState(() => _mapReady = true);
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
                      try {
                        const size = 24.0;
                        final recorder = ui.PictureRecorder();
                        final canvas = Canvas(recorder);
                        final center = Offset(size / 2, size / 2);
                        canvas.drawCircle(center, size / 2, Paint()..color = Colors.white);
                        canvas.drawCircle(center, size / 2 - 3, Paint()..color = const Color(0xFFE8C547));
                        final picture = recorder.endRecording();
                        final img = await picture.toImage(size.toInt(), size.toInt());
                        final bytes = await img.toByteData(format: ui.ImageByteFormat.png);
                        final puckImg = bytes!.buffer.asUint8List();
                        await _mapCtrl!.location.updateSettings(mapbox.LocationComponentSettings(
                          enabled: true,
                          pulsingEnabled: true,
                          pulsingColor: const Color(0xFFE8C547).toARGB32(),
                          pulsingMaxRadius: 20.0,
                          locationPuck: mapbox.LocationPuck(
                            locationPuck2D: mapbox.LocationPuck2D(topImage: puckImg),
                          ),
                        ));
                      } catch (_) {}
                    }
                  },
                  onScrollListener: (_) {
                    if (!_programmaticCam) setState(() => _userMovedMap = true);
                  },
                ),
              ),

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
                        Navigator.of(context).pop();
                      },
                      c: c,
                    ),
                  ),
                ),
              ),
            ),

            // ── Recenter button — visible when user zoomed/panned ──
            if (_userMovedMap && phase != RiderPhase.idle)
              Positioned(
                top: topPad + 8,
                right: 12,
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
