import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:geolocator/geolocator.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../config/mapbox_config.dart';
import '../config/map_theme.dart';
import '../services/preload_service.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../l10n/app_localizations.dart';
import '../config/page_transitions.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import '../services/places_service.dart';
import '../widgets/gold_location_dot.dart';
import 'airport_terminal_sheet.dart';
import 'credit_card_screen.dart';
import 'payment_accounts_screen.dart';
import 'ride_rating_screen.dart';
import 'schedule_booking_screen.dart';
import 'scheduled_rides_screen.dart';
import 'trip_receipt_screen.dart';
import 'driver_arrived_screen.dart';
import '../navigation/smooth_motion.dart';
import '../navigation/route_snapper.dart';
import '../services/api_service.dart';
import '../services/trip_firestore_service.dart';
import '../services/user_session.dart';
import '../widgets/bouncing_button.dart';
import '../widgets/map/circular_pin_renderer.dart';
import '../widgets/smart_map_pin.dart';
import '../widgets/verified_avatar.dart';
import 'pickup_dropoff_search_screen.dart';
import '../utils/responsive.dart';
import '../utils/name_helper.dart' as nh;

part 'map_screen_controller.dart';
part 'map_screen_map.dart';
part 'map_screen_widgets.dart';

enum RideStage {
  pin,
  plan,
  loading,
  options,
  confirmPickup,
  payment,
  matching,
  riding,
}

class RideOption {
  final String name;
  final String vehicle;
  final String price;
  final String eta;
  final bool promoted;

  const RideOption({
    required this.name,
    this.vehicle = '',
    required this.price,
    required this.eta,
    this.promoted = false,
  });
}

class MapScreen extends StatefulWidget {
  final bool openPlanOnStart;
  final String? initialDropoffQuery;
  final DateTime? scheduledDateTime;
  final int? preSelectedRideIndex;
  final bool applyPromoDiscount;

  const MapScreen({
    super.key,
    this.openPlanOnStart = false,
    this.initialDropoffQuery,
    this.scheduledDateTime,
    this.preSelectedRideIndex,
    this.applyPromoDiscount = false,
  });

  @override
  State<MapScreen> createState() => _MapScreenState();
}


const _gold = Color(0xFFE8C547);
const _pinColor = Color(0xFFE8C547);
const _birminghamDefault = LatLng(33.5186, -86.8104);
const double _defaultMapZoom = 13.7;
const double _goldPinHue = 0.0;
const double _zoomInCloseLevel = 17.5;
const double _zoomOutLevel = 10.5; // ignore: unused_field
const double _carHeight = 28.0;

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
  void _setState(VoidCallback fn) { if (mounted) setState(fn); }

  /// Handles ride cancellation after the user confirms in the dialog.
  /// Extracted into a separate method so the analyzer recognises the
  /// mounted guard as a proper async-gap guard clause.
  void _handleRideCancellation() {
    if (!mounted) return;
    _rideLifecycleTimer?.cancel();
    _tripPollTimer?.cancel();
    setState(() {
      _showDriverArrivedScreen = false;
      _rideProgress = 0;
      _clearRouteAnnotation();
      _activeRoutePoints = [];
      _driverRoutePoints = [];
    });
    if (!mounted) return;
    Navigator.of(context).maybePop();
  }
  // Theme-aware colors – _c is set at the top of build()
  late AppColors _c;
  bool? _lastIsDark; // tracks theme so we can re-style the map
  Color get _bgBlack => _c.bg;
  Color get _panelBlack => _c.mapPanel;
  Color get _softBlack => _c.mapSurface;
  List<Shadow> get _thinWhiteOutline {
    final c = _c.isDark ? const Color(0xCCFFFFFF) : const Color(0x44000000);
    return [
      Shadow(color: c, offset: const Offset(0.35, 0), blurRadius: 0),
      Shadow(color: c, offset: const Offset(-0.35, 0), blurRadius: 0),
      Shadow(color: c, offset: const Offset(0, 0.35), blurRadius: 0),
      Shadow(color: c, offset: const Offset(0, -0.35), blurRadius: 0),
    ];
  }


  /// Picks the Mapbox style URI based on the current stage/theme.
  String get _mapStyleUri {
    if (_stage == RideStage.riding) return MapboxConfig.styleNavigation;
    return _c.isDark ? MapboxConfig.styleDark : MapboxConfig.styleLight;
  }


  // Marker icon bytes (Mapbox uses raw Uint8List)
  Uint8List? _goldPinIconBytes;
  Uint8List? _dropoffPinIconBytes;

  // ── Floating label chip screen-space positions (updated on map idle) ────
  Offset? _pickupLabelOffset;
  Offset? _dropoffLabelOffset;

  // Mapbox controller & annotation managers
  mapbox.MapboxMap? _mapController;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  // Active annotations
  mapbox.PointAnnotation? _goldDotAnnot;
  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;
  mapbox.PointAnnotation? _driverCarAnnot;
  mapbox.PolylineAnnotation? _routeAnnot;

  // ── Cinematic animation ──
  AnimationController? _tiltCtrl;
  Animation<double>? _tiltAnim;
  AnimationController? _bearingCtrl;
  Animation<double>? _bearingAnim;
  AnimationController? _pinPopCtrl;
  Animation<double>? _pinPopAnim;
  double _cinematicPitch = 0;
  double _cinematicBearing = 0;
  bool _cinematicDone = false;
  Ticker? _routeDrawTicker;

  /// True when the Mapbox controller is ready.
  bool get _hasMapController => _mapController != null;
  LatLng? _currentPosition;
  LatLng? _cameraTarget;

  final _pickupCtrl = TextEditingController();
  final _dropoffCtrl = TextEditingController();
  final _pickupFocus = FocusNode();
  final _dropoffFocus = FocusNode();

  final _directions = DirectionsService(ApiKeys.webServices);
  final _places = PlacesService(ApiKeys.webServices);

  Timer? _liveLocationTimer;
  StreamSubscription<Position>? _livePositionSub;
  StreamSubscription<String>? _fcmTokenRefreshSub;
  Timer? _searchDebounce;
  Timer? _cameraIdleDebounce;
  LatLng? _lastReverseGeocodedTarget;
  LatLng? _lastLiveAddressTarget;
  int _reverseGeocodeTicket = 0;

  RideStage _stage = RideStage.plan;
  bool _isSearching = false;
  bool _searchingPickup = false;
  String? _searchError;
  List<PlaceSuggestion> _suggestions = [];

  // Pickup/dropoff positions (replace old Marker objects)
  LatLng? _dropoffPosition;
  List<LatLng> _activeRoutePoints = [];

  // Gold animated location dot
  final GoldLocationDot _goldDot = GoldLocationDot();

  /// Toggle state for the recenter (my_location) button.
  /// false = next tap centers on pickup at default zoom
  /// true  = next tap zooms IN close to pickup
  bool _isCenteredOnPickup = false;

  String _pickupAddress = '';
  String _dropoffAddress = '';
  String _tripMiles = '-- mi';
  String _tripDuration = '-- min';
  bool _hasPreparedRoute = false;
  bool _pickupNow = true;
  DateTime? _scheduledDate;
  TimeOfDay? _scheduledTime;
  AirportSelection? _airportSelection;
  int _routeAnimationTicket = 0;
  AnimationController? _routeShimmerCtrl;
  bool _isCancelling = false;
  bool _planBodyVisible = false;
  double? _panelDragHeight;
  bool _isPanelDragging = false;
  double _lastPanelVelocity = 0;
  bool _optionsExpanded = true;
  bool _isAddressFieldFocused = false;
  bool _isResolvingLocation = false;
  bool _isRecentering = false;
  bool _autoProgressingToOptions = false;
  Timer? _rideLifecycleTimer;
  Timer? _tripPollTimer;
  int? _currentTripId;
  int? _currentDriverId;
  String? _firestoreTripId;
  double _rideProgress = 0;
  double _carImageAspectRatio = 2.0; // default 2:1 until loaded
  LatLng? _driverPosition;
  LatLng? _prevDriverPosition; // for smooth interpolation
  double _driverBearing = 0; // bearing toward destination
  DateTime? _lastDriverMarkerRebuild;
  // LegacySmoothMotion replaces the old AnimationController approach
  LegacySmoothMotion? _driverMotion;
  int _driverSnapIdx = 0;
  List<LatLng> _driverRoutePoints = [];
  String _lastDriverRoutePhase = ''; // 'driver_en_route' or 'in_trip'
  String _driverName = 'Searching...';
  String _driverCar = '';
  String _driverPlate = '';
  String _driverPhotoUrl = '';
  double _driverRating = 4.9;
  String _driverEta = '...';
  String _driverPhone = '';
  String _tripStatus =
      'driver_en_route'; // tracks current trip phase for rider UI
  bool _showDriverArrivedScreen = false; // true when driver arrived overlay is showing

  String _driverNote = '';

  int _selectedRide = 0;
  int? _preSelectedRideIndex;
  bool _promoActive = false;
  int _promoDiscountPercent = 0;
  String _selectedPaymentMethod =
      Platform.isIOS ? 'apple_pay' : 'google_pay';
  Set<String> _linkedPaymentMethods = {}; // persisted linked methods
  String? _savedCardLast4;
  String? _savedCardBrand;

  List<RideOption> _rides = [
    RideOption(
      name: 'VIP',
      vehicle: 'Suburban',
      price: '\$24.50',
      eta: '12:02 AM · 13 min',
      promoted: true,
    ),
    RideOption(
      name: 'Premium',
      vehicle: 'Camry',
      price: '\$15.88',
      eta: '12:01 AM · 10 min',
    ),
    RideOption(
      name: 'Comfort',
      vehicle: 'Fusion',
      price: '\$9.76',
      eta: '12:10 AM · 14-23 min',
    ),
  ];


  Future<void> _setPickupAnnotation(LatLng position) async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    if (_pickupAnnot != null) { try { await mgr.delete(_pickupAnnot!); } catch (_) {} _pickupAnnot = null; }
    _pickupAnnot = await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(position.longitude, position.latitude)),
      image: _goldPinIconBytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM, // pin tip sits on the coordinate
      iconOffset: [0, 0],
    ));
    _refreshPinLabelOffsets();
  }

  Future<void> _setDropoffAnnotation(LatLng position) async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    if (_dropoffAnnot != null) { try { await mgr.delete(_dropoffAnnot!); } catch (_) {} _dropoffAnnot = null; }
    _dropoffAnnot = await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(position.longitude, position.latitude)),
      image: _dropoffPinIconBytes ?? _goldPinIconBytes,
      iconSize: 1.0,
      iconAnchor: mapbox.IconAnchor.BOTTOM, // pin tip sits on the coordinate
      iconOffset: [0, 0],
    ));
    _refreshPinLabelOffsets();
  }

  @override
  void initState() {
    super.initState();
    // Don't pre-set Birmingham — let GPS resolve before centering map
    _pickupAddress = '';
    _pickupCtrl.text = '';
    // Pickup annotation set after map is created
    _pickupFocus.addListener(_handleAddressFocusChange);
    _dropoffFocus.addListener(_handleAddressFocusChange);
    _driverMotion = LegacySmoothMotion(
      onTick: _onDriverMotionTick,
      lerpFactor: 0.10,
      enablePrediction: false,
    );
    _driverMotion!.start(this);
    _loadPinIcons();
    // Car icon loading removed - no car markers on rider map
    _goldDot.build(this, () { if (mounted) _updateGoldDotAnnotation(); });
    // Precache car images for the ride progress bar
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      for (final a in [
        'assets/images/cruise_3.png',
        'assets/images/cruise_6.png',
        'assets/images/cruise_7.png',
      ]) {
        precacheImage(AssetImage(a), context);
      }
    });
    _initLocation();
    _applyStartupIntent();
    _loadLinkedPayments();
    _loadPromoState();
    _registerFcmToken();
    // Start with plan body visible immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && _stage == RideStage.plan) {
        setState(() => _planBodyVisible = true);
      }
    });
  }

  Future<void> _registerFcmToken() async {
    try {
      final messaging = FirebaseMessaging.instance;
      await messaging.requestPermission(alert: true, badge: true, sound: true);
      final token = await messaging.getToken();
      if (token != null) ApiService.saveFcmToken(token);
      _fcmTokenRefreshSub?.cancel();
      _fcmTokenRefreshSub = messaging.onTokenRefresh.listen((t) => ApiService.saveFcmToken(t));
    } catch (_) {}
  }

  Future<void> _loadLinkedPayments() async {
    final linked = await LocalDataService.getLinkedPaymentMethods();
    final cardLast4 = await LocalDataService.getCreditCardLast4();
    final cardBrand = await LocalDataService.getCreditCardBrand();
    if (!mounted) return;
    setState(() {
      _linkedPaymentMethods = linked;
      _savedCardLast4 = cardLast4;
      _savedCardBrand = cardBrand;
    });
  }

  Future<void> _loadPromoState() async {
    if (widget.applyPromoDiscount) {
      final percent = await LocalDataService.getPromoDiscountPercent();
      if (percent > 0 && mounted) {
        setState(() {
          _promoActive = true;
          _promoDiscountPercent = percent;
        });
      }
    }
  }

  Future<void> _loadPinIcons() async {
    // Golden teardrop pins for pickup (person) and dropoff (home).
    // These pins use iconAnchor.BOTTOM so the tip sits exactly on the coordinate.
    _goldPinIconBytes    = await _buildRouteDotPin(isPickup: true);
    _dropoffPinIconBytes = await _buildRouteDotPin(isPickup: false);
    if (!mounted) return;
    if (_currentPosition != null) _setPickupAnnotation(_currentPosition!);
  }

  /// Convert pickup/dropoff coordinates to screen pixels so the floating label
  /// chips can be placed at the exact pin positions via Positioned widgets.
  /// Called on map-idle and after any annotation geometry change.
  Future<void> _refreshPinLabelOffsets() async {
    final mc = _mapController;
    if (mc == null || !mounted) return;
    Offset? pOff, dOff;
    if (_currentPosition != null) {
      try {
        final px = await mc.pixelForCoordinate(mapbox.Point(
            coordinates: mapbox.Position(
              _currentPosition!.longitude, _currentPosition!.latitude)));
        pOff = Offset(px.x.toDouble(), px.y.toDouble());
      } catch (_) {}
    }
    if (_dropoffPosition != null) {
      try {
        final px = await mc.pixelForCoordinate(mapbox.Point(
            coordinates: mapbox.Position(
              _dropoffPosition!.longitude, _dropoffPosition!.latitude)));
        dOff = Offset(px.x.toDouble(), px.y.toDouble());
      } catch (_) {}
    }
    if (!mounted) return;
    setState(() {
      _pickupLabelOffset  = pOff;
      _dropoffLabelOffset = dOff;
    });
  }

  Future<void> _applyStartupIntent() async {
    if (widget.preSelectedRideIndex != null) {
      _preSelectedRideIndex = widget.preSelectedRideIndex;
      _selectedRide = widget.preSelectedRideIndex!.clamp(0, _rides.length - 1);
    }
    final initialDropoff = widget.initialDropoffQuery?.trim() ?? '';
    if (!widget.openPlanOnStart && initialDropoff.isEmpty) return;

    // Open WhereTo after first frame renders
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      await _openWhereTo();
      if (!mounted) return;
      if (initialDropoff.isNotEmpty) {
        _dropoffCtrl.text = initialDropoff;
        await _onDropoffSubmitted(initialDropoff);
      }
    });
  }

  @override
  void dispose() {
    _fcmTokenRefreshSub?.cancel();
    _goldDot.dispose();
    _liveLocationTimer?.cancel();
    _livePositionSub?.cancel();
    _searchDebounce?.cancel();
    _cameraIdleDebounce?.cancel();
    _rideLifecycleTimer?.cancel();
    _tripPollTimer?.cancel();
    _driverMotion?.dispose();
    _routeShimmerCtrl?.removeListener(_onRouteShimmerTick);
    _routeShimmerCtrl?.dispose();
    _routeDrawTicker?.dispose();
    _tiltCtrl?.dispose();
    _bearingCtrl?.dispose();
    _pinPopCtrl?.dispose();
    _pickupFocus.removeListener(_handleAddressFocusChange);
    _dropoffFocus.removeListener(_handleAddressFocusChange);
    _pickupCtrl.dispose();
    _dropoffCtrl.dispose();
    _pickupFocus.dispose();
    _dropoffFocus.dispose();
    super.dispose();
  }

  Future<void> _maybeAutoRouteFromInputs() async {
    if (!mounted ||
        _stage != RideStage.plan ||
        _autoProgressingToOptions ||
        _isSearching) {
      return;
    }

    final pickupText = _pickupCtrl.text.trim();
    final dropoffText = _dropoffCtrl.text.trim();
    if (pickupText.isEmpty || dropoffText.isEmpty) return;

    if (_currentPosition == null) {
      await _syncPickupFromInputIfNeeded();
      if (!mounted) return;
    }

    final sameDropoffText =
        _dropoffAddress.trim().toLowerCase() == dropoffText.toLowerCase();
    if (_dropoffPosition == null || !sameDropoffText) {
      await _onDropoffSubmitted(dropoffText);
      return;
    }

    if (_currentPosition != null && _dropoffPosition != null) {
      await _autoAdvanceToOptions();
    }
  }

  Future<void> _initLocation() async {
    if (mounted) {
      setState(() {
        _isResolvingLocation = true;
      });
    }

    // Use pre-loaded GPS from splash for instant first fix
    final preloaded = PreloadService.initialPosition;
    if (preloaded != null && mounted) {
      final latLng = LatLng(preloaded.latitude, preloaded.longitude);
      _setInitialPickup(latLng, S.of(context).currentLocation);
      _centerMapOn(latLng, zoom: _defaultMapZoom);
      _refreshPickupAddress(latLng);
      setState(() => _isResolvingLocation = false);
      // Still start location stream for updates
      _startLiveLocationUpdates();
      return;
    }

    final enabled = await Geolocator.isLocationServiceEnabled();
    if (!enabled) {
      _setDefaultBirminghamPickup();
      if (mounted) setState(() => _isResolvingLocation = false);
      return;
    }

    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        _setDefaultBirminghamPickup();
        if (mounted) setState(() => _isResolvingLocation = false);
        return;
      }
    }
    if (permission == LocationPermission.deniedForever) {
      _setDefaultBirminghamPickup();
      if (mounted) {
        setState(() => _isResolvingLocation = false);
        showDialog(
          context: context,
          builder: (ctx) => AlertDialog(
            title: Text(S.of(ctx).locationPermissionRequired),
            content: Text(S.of(ctx).locationPermissionPermanentlyDeniedMsg),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(S.of(ctx).cancel),
              ),
              TextButton(
                onPressed: () {
                  Navigator.pop(ctx);
                  openAppSettings();
                },
                child: Text(S.of(ctx).openSettings),
              ),
            ],
          ),
        );
      }
      return;
    }

    // 1) Instantly use last known position so pickup is ready immediately
    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && mounted) {
        final latLng = LatLng(lastKnown.latitude, lastKnown.longitude);
        _setInitialPickup(latLng, S.of(context).currentLocation);
        _centerMapOn(latLng, zoom: _defaultMapZoom);
        // Start reverse geocode in background, don't wait
        _refreshPickupAddress(latLng);
      }
    } catch (_) {}

    // 2) Get fresh high-accuracy position in background to refine
    try {
      final current = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 8),
        ),
      );
      if (!mounted) return;
      final latLng = LatLng(current.latitude, current.longitude);
      _setInitialPickup(latLng, _pickupAddress);
      _centerMapOn(latLng, zoom: _defaultMapZoom);
      await _refreshPickupAddress(latLng);
      _startLiveLocationUpdates();
    } catch (_) {
      // If fresh position failed but we already have lastKnown, that's fine
      if (_currentPosition != null && _currentPosition != _birminghamDefault) {
        _startLiveLocationUpdates();
      } else {
        _setDefaultBirminghamPickup();
      }
    } finally {
      if (mounted) setState(() => _isResolvingLocation = false);
    }
  }

  // ignore: unused_element – retained for future use
  Future<Position?> _resolvePreciseCurrentPosition() async {
    Position? best;

    try {
      final lastKnown = await Geolocator.getLastKnownPosition();
      if (lastKnown != null && _isPositionReliable(lastKnown)) {
        best = lastKnown;
      }
    } catch (_) {}

    try {
      final current = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.bestForNavigation,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (_isPositionReliable(current)) {
        best = _pickBetterPosition(best, current);
      }
    } catch (_) {}

    if (best != null) {
      return best;
    }

    for (var attempt = 0; attempt < 2; attempt++) {
      try {
        final current = await Geolocator.getCurrentPosition(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.high,
            timeLimit: Duration(seconds: 8),
          ),
        );
        if (_isPositionReliable(current)) {
          best = _pickBetterPosition(best, current);
          break;
        }
        best = _pickBetterPosition(best, current);
      } catch (_) {}

      if (attempt == 0) {
        await Future.delayed(const Duration(milliseconds: 650));
      }
    }

    return best;
  }

  void _onMapTap(LatLng latLng) async {
    // When user taps map during plan stage, set that location as dropoff
    if (_stage != RideStage.plan) return;

    setState(() {
      _dropoffCtrl.text = S.of(context).loadingAddress;
      _dropoffPosition = latLng;
      _setDropoffAnnotation(latLng);
    });

    try {
      final address = await _places.reverseGeocode(
        lat: latLng.latitude,
        lng: latLng.longitude,
      );
      if (!mounted) return;
      final resolved = (address == null || address.isEmpty)
          ? _coordinatesLabel(latLng)
          : address;
      setState(() {
        _dropoffAddress = resolved;
        _dropoffCtrl.text = resolved;
        _dropoffPosition = latLng;
        _setDropoffAnnotation(latLng);
      });
    } catch (_) {
      if (!mounted) return;
      final fallback = _coordinatesLabel(latLng);
      setState(() {
        _dropoffAddress = fallback;
        _dropoffCtrl.text = fallback;
        _dropoffPosition = latLng;
        _setDropoffAnnotation(latLng);
      });
    }
  }

  Future<void> _refreshPickupAddress(LatLng latLng) async {
    try {
      final address = await _places.reverseGeocode(
        lat: latLng.latitude,
        lng: latLng.longitude,
      );
      if (!mounted) return;
      final resolved = (address == null || address.isEmpty)
          ? _coordinatesLabel(latLng)
          : address;
      setState(() {
        _pickupAddress = resolved;
        _pickupCtrl.text = resolved;
        _setPickupAnnotation(latLng);
      });
    } catch (_) {
      if (!mounted) return;
      final fallback = _coordinatesLabel(latLng);
      setState(() {
        _pickupAddress = fallback;
        _pickupCtrl.text = fallback;
        _setPickupAnnotation(latLng);
      });
    }
  }

  Future<void> _openWhereTo() async {
    _setStage(RideStage.plan);
    setState(() {
      _suggestions = [];
      _searchError = null;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _dropoffFocus.requestFocus();
    });
  }

  /// Fit the camera to a list of points with [padding] (pixels) on all sides.
  Future<void> _fitBounds(List<LatLng> points, double padding) async {
    await _fitBoundsInsets(points, padding, padding, padding, padding);
  }

  Future<void> _fitRideBounds(List<LatLng> points) async {
    await _fitBoundsInsets(points, 90, 70, _panelBottomInset(), 70);
  }

  Future<double> _currentZoom() async {
    if (_mapController == null) return _defaultMapZoom;
    try {
      final state = await _mapController!.getCameraState();
      return state.zoom;
    } catch (_) {
      return _defaultMapZoom;
    }
  }

  // ──────────────────────────────────────────────────────────────────

  EdgeInsets _mapPaddingForContext(BuildContext context) {
    final media = MediaQuery.of(context);
    final topPadding = media.padding.top + (_stage == RideStage.pin ? 92 : 110);
    final bottomPadding =
        _currentPanelHeight(context) + media.padding.bottom + 24;
    return EdgeInsets.fromLTRB(20, topPadding, 20, bottomPadding);
  }

  /// Smooth multi-step camera transition that glides between zoom levels.
  /// For large zoom deltas, performs an intermediate step so the animation
  /// doesn't "jump" — mimicking the fluid feel of premium ride-hailing apps.
  Future<void> _smoothCameraTransition(LatLng target, double targetZoom) async {
    if (!_hasMapController) return;
    await _panTo(target, zoom: targetZoom);
  }

  /// Always centers on the pickup location.
  /// 1st tap â†’ center on pickup at default zoom.
  /// 2nd tap â†’ zoom IN close to pickup (street-level).
  /// Never moves or resets the pickup marker.
  Future<void> _recenterToMyLocation() async {
    if (!_hasMapController) return;
    final pickup = _currentPosition;
    if (pickup == null) return;

    // In confirmPickup the center pin IS the pickup — just re-center
    if (_stage == RideStage.confirmPickup) {
      _isRecentering = true;
      _cameraIdleDebounce?.cancel();
      await _centerMapOn(pickup, zoom: _defaultMapZoom);
      _isCenteredOnPickup = true;
      return;
    }

    if (_isCenteredOnPickup) {
      // Already centered â†’ zoom IN closer to pickup
      _isCenteredOnPickup = true; // keep flag so next tap zooms in again
      await _centerMapOn(pickup, zoom: _zoomInCloseLevel);
    } else {
      // First tap â†’ center on pickup at comfortable default zoom
      _isCenteredOnPickup = true;
      await _centerMapOn(pickup, zoom: _defaultMapZoom);
    }
  }

  Future<void> _onDropoffSubmitted(String value) async {
    final query = value.trim();
    if (query.isEmpty) return;

    await _syncPickupFromInputIfNeeded();

    if (mounted) {
      FocusScope.of(context).unfocus();
      setState(() {
        _isAddressFieldFocused = false;
        _panelDragHeight = null;
      });
    }

    setState(() {
      _isSearching = true;
      _searchingPickup = false;
      _searchError = null;
    });

    try {
      final origin = _currentPosition;
      // Use autocomplete (which runs Nominatim + Photon in parallel)
      // to get results with coordinates — avoids double Nominatim calls.
      final results = await _places.autocomplete(
        query,
        latitude: origin?.latitude,
        longitude: origin?.longitude,
      );

      if (results.isNotEmpty && mounted) {
        await _selectSuggestion(results.first, pickup: false);
        if (!mounted) return;
        setState(() {
          _isSearching = false;
        });
        return;
      }

      // Fallback: direct geocode if autocomplete returned nothing
      final exact = await _places.geocodeAddress(
        query,
        latitude: origin?.latitude,
        longitude: origin?.longitude,
      );

      if (exact != null && mounted) {
        final exactSuggestion = PlaceSuggestion(
          description: exact.address.isEmpty ? query : exact.address,
          placeId: 'exact:${exact.lat},${exact.lng}',
          lat: exact.lat,
          lng: exact.lng,
        );
        await _selectSuggestion(exactSuggestion, pickup: false);
        if (!mounted) return;
        setState(() {
          _isSearching = false;
        });
        return;
      }

      if (!mounted) return;
      setState(() {
        _isSearching = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
        _searchError = error.toString();
      });
    }
  }

  Future<void> _syncPickupFromInputIfNeeded() async {
    final input = _pickupCtrl.text.trim();
    if (input.isEmpty) return;

    final normalizedInput = input.toLowerCase();
    final normalizedCurrent = _pickupAddress.trim().toLowerCase();
    if (normalizedInput == normalizedCurrent && _currentPosition != null) return;

    final bias = _currentPosition;
    try {
      final exactPickup = await _places.geocodeAddress(
        input,
        latitude: bias?.latitude,
        longitude: bias?.longitude,
      );
      if (!mounted || exactPickup == null) return;

      final position = LatLng(exactPickup.lat, exactPickup.lng);
      setState(() {
        _currentPosition = position;
        _pickupAddress = exactPickup.address.isEmpty
            ? input
            : exactPickup.address;
        _pickupCtrl.text = _pickupAddress;
        _hasPreparedRoute = false;
      });
    } catch (_) {}
  }

  Future<void> _autoAdvanceToOptions() async {
    if (_autoProgressingToOptions) return;
    if (_currentPosition == null || _dropoffPosition == null) return;

    _autoProgressingToOptions = true;
    try {
      if (mounted) {
        FocusScope.of(context).unfocus();
        setState(() {
          _isAddressFieldFocused = false;
          _panelDragHeight = null;
          _planBodyVisible = false; // fade out plan panel content
        });
      }

      // Brief map-reveal moment: fit both pins while panel fades
      await _fitBoundsInsets(
        [_currentPosition!, _dropoffPosition!],
        90, 60, 220, 60,
      );
      await Future.delayed(const Duration(milliseconds: 480));
      if (!mounted) return;

      _setStage(RideStage.loading);
      final ok = await _prepareRoutePreview(returnToPin: false);
      if (!mounted) return;

      if (!ok) {
        _setStage(RideStage.plan);
        return;
      }

      await Future.delayed(const Duration(milliseconds: 200));
      if (!mounted) return;

      // If a ride was pre-selected from home screen, skip options â†’ go to confirmPickup
      if (_preSelectedRideIndex != null) {
        _selectedRide = _preSelectedRideIndex!.clamp(0, _rides.length - 1);
        _preSelectedRideIndex = null; // consume it once
        _beginRideRequestFromOptions();
        return;
      }

      _setStage(RideStage.options);
    } finally {
      _autoProgressingToOptions = false;
    }
  }

  // ignore: unused_element – retained for future use
  Future<void> _onRequestRide() async {
    if (mounted) {
      FocusScope.of(context).unfocus();
      setState(() {
        _isAddressFieldFocused = false;
        _panelDragHeight = null;
      });
    }

    if (_currentPosition == null) {
      // nothing to do; position will be set by location stream
    }

    if (_dropoffPosition == null &&
        _suggestions.isNotEmpty &&
        !_searchingPickup) {
      await _selectSuggestion(_suggestions.first, pickup: false);
    }

    if (_dropoffPosition == null && _dropoffCtrl.text.trim().isNotEmpty) {
      await _onDropoffSubmitted(_dropoffCtrl.text);
    }

    if (_currentPosition == null || _dropoffPosition == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(S.of(context).selectValidDestination),
          duration: const Duration(milliseconds: 1800),
        ),
      );
      return;
    }

    if (!_hasPreparedRoute) {
      final ok = await _prepareRoutePreview(returnToPin: false);
      if (!ok || !mounted) return;
    }

    if (!mounted) return;

    _setStage(RideStage.loading);

    // Transition to options immediately
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _setStage(RideStage.options);
    });
  }

  String get _rideTimeBadgeText {
    if (_pickupNow) return S.of(context).pickupNow;
    if (_scheduledDate != null && _scheduledTime != null) {
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      final d = _scheduledDate!;
      final t = _scheduledTime!;
      final month = months[d.month - 1];
      final hour = t.hourOfPeriod == 0 ? 12 : t.hourOfPeriod;
      final min = t.minute.toString().padLeft(2, '0');
      final amPm = t.period == DayPeriod.am ? 'AM' : 'PM';
      return '$month ${d.day} · $hour:$min $amPm';
    }
    return S.of(context).pickupLater;
  }

  Future<void> _showRideTimeSheet() async {
    var tempPickupNow = _pickupNow;
    var step = 0; // 0 = now/later, 1 = calendar, 2 = time
    DateTime tempDate =
        _scheduledDate ?? DateTime.now().add(const Duration(hours: 24));
    TimeOfDay tempTime =
        _scheduledTime ??
        TimeOfDay(hour: (TimeOfDay.now().hour + 1) % 24, minute: 0);

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setModalState) {
            Widget stepContent;

            if (step == 0) {
              // â”€â”€ Step 0: Now / Later â”€â”€
              stepContent = Column(
                key: const ValueKey(0),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    S.of(context).whenNeedRide,
                    style: TextStyle(
                      color: _c.textPrimary,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 14),
                  Divider(color: _c.divider, height: 1),
                  _rideTimeOption(
                    icon: Icons.watch_later_outlined,
                    title: S.of(context).nowLabel,
                    subtitle: S.of(context).nowSubtitle,
                    selected: tempPickupNow,
                    onTap: () => setModalState(() => tempPickupNow = true),
                  ),
                  Divider(color: _c.divider, height: 1),
                  _rideTimeOption(
                    icon: Icons.calendar_today_outlined,
                    title: S.of(context).laterLabel,
                    subtitle: S.of(context).laterSubtitle,
                    selected: !tempPickupNow,
                    onTap: () => setModalState(() => tempPickupNow = false),
                  ),
                  const SizedBox(height: 14),
                  _sheetButton(
                    label: S.of(context).nextButton,
                    onPressed: () {
                      if (tempPickupNow) {
                        Navigator.of(ctx).pop();
                        if (!mounted) return;
                        setState(() {
                          _pickupNow = true;
                          _scheduledDate = null;
                          _scheduledTime = null;
                        });
                      } else {
                        setModalState(() => step = 1);
                      }
                    },
                  ),
                ],
              );
            } else if (step == 1) {
              // â”€â”€ Step 1: Calendar â”€â”€
              stepContent = Column(
                key: const ValueKey(1),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => setModalState(() => step = 0),
                        child: Icon(
                          Icons.arrow_back_ios_new,
                          color: _c.textSecondary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        S.of(context).pickDate,
                        style: TextStyle(
                          color: _c.textPrimary,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Theme(
                    data: Theme.of(context).copyWith(
                      colorScheme: ColorScheme.dark(
                        primary: const Color(0xFFE8C547),
                        onPrimary: Colors.black,
                        surface: _c.mapPanel,
                        onSurface: _c.textPrimary,
                      ),
                      textButtonTheme: TextButtonThemeData(
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFFE8C547),
                        ),
                      ),
                    ),
                    child: CalendarDatePicker(
                      initialDate: tempDate.isBefore(DateTime.now())
                          ? DateTime.now()
                          : tempDate,
                      firstDate: DateTime.now(),
                      lastDate: DateTime.now().add(const Duration(days: 30)),
                      onDateChanged: (d) => tempDate = d,
                    ),
                  ),
                  _sheetButton(
                    label: S.of(context).nextButton,
                    onPressed: () => setModalState(() => step = 2),
                  ),
                ],
              );
            } else {
              // â”€â”€ Step 2: Time picker â”€â”€
              stepContent = Column(
                key: const ValueKey(2),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      GestureDetector(
                        onTap: () => setModalState(() => step = 1),
                        child: Icon(
                          Icons.arrow_back_ios_new,
                          color: _c.textSecondary,
                          size: 20,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        S.of(context).pickTime,
                        style: TextStyle(
                          color: _c.textPrimary,
                          fontSize: 19,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    height: 200,
                    child: CupertinoTheme(
                      data: CupertinoThemeData(
                        brightness: Brightness.dark,
                        primaryColor: const Color(0xFFE8C547),
                        textTheme: CupertinoTextThemeData(
                          dateTimePickerTextStyle: TextStyle(
                            color: _c.textPrimary,
                            fontSize: 22,
                          ),
                        ),
                      ),
                      child: CupertinoDatePicker(
                        mode: CupertinoDatePickerMode.time,
                        initialDateTime: DateTime(
                          2024,
                          1,
                          1,
                          tempTime.hour,
                          tempTime.minute,
                        ),
                        use24hFormat: false,
                        onDateTimeChanged: (dt) {
                          tempTime = TimeOfDay.fromDateTime(dt);
                        },
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  _sheetButton(
                    label: S.of(context).confirmButton,
                    onPressed: () {
                      final dt = DateTime(
                        tempDate.year,
                        tempDate.month,
                        tempDate.day,
                        tempTime.hour,
                        tempTime.minute,
                      );
                      // Must be at least 30 min in the future
                      if (dt.isBefore(
                        DateTime.now().add(const Duration(minutes: 30)),
                      )) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text(S.of(context).scheduleTooSoon),
                            backgroundColor: Colors.redAccent,
                          ),
                        );
                        return;
                      }
                      Navigator.of(ctx).pop();
                      if (!mounted) return;
                      Navigator.of(context).push(
                        slideFromRightRoute(
                            ScheduleBookingScreen(scheduledAt: dt)),
                      );
                    },
                  ),
                ],
              );
            }

            return SafeArea(
              top: false,
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(ctx).size.height * 0.8,
                ),
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: _c.mapPanel,
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
                    physics: const BouncingScrollPhysics(
                      parent: AlwaysScrollableScrollPhysics(),
                    ),
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 350),
                      curve: Curves.easeInOutCubicEmphasized,
                      child: AnimatedSwitcher(
                        duration: const Duration(milliseconds: 350),
                        layoutBuilder: (currentChild, previousChildren) =>
                            currentChild!,
                        transitionBuilder: (child, animation) {
                          return FadeTransition(
                            opacity: animation,
                            child: child,
                          );
                        },
                        child: stepContent,
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Combines [_scheduledDate] and [_scheduledTime] into a single [DateTime].
  DateTime? _buildScheduledAt() {
    if (_scheduledDate == null || _scheduledTime == null) return null;
    return DateTime(
      _scheduledDate!.year,
      _scheduledDate!.month,
      _scheduledDate!.day,
      _scheduledTime!.hour,
      _scheduledTime!.minute,
    );
  }

  /// Opens the [AirportTerminalSheet] and stores the result in [_airportSelection].
  Future<void> _showAirportSheet() async {
    // Tapping again when already set → clear the selection (deselect)
    if (_airportSelection != null) {
      setState(() {
        _airportSelection = null;
      });
      return;
    }
    final isDark = _c.isDark;
    final result = await showModalBottomSheet<AirportSelection>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => AirportTerminalSheet(isDark: isDark),
    );
    if (!mounted) return;
    if (result != null) {
      setState(() {
        _airportSelection = result;
        // Pre-fill dropoff with airport name
        _dropoffAddress = result.airport.name;
        _dropoffCtrl.text = result.airport.name;
      });
      _onDropoffSubmitted(_dropoffAddress);
    }
  }

  Future<void> _fitMapToRoute() async {
    if (!_hasMapController) return;
    final pts = _activeRoutePoints.isNotEmpty
        ? _activeRoutePoints
        : [if (_currentPosition != null) _currentPosition!];
    if (pts.isEmpty) return;
    await _fitBoundsInsets(pts, 90, 70, _panelBottomInset(), 70);
  }

  Future<void> _applyRouteVerticalBias(List<LatLng> points) async {
    if (!_hasMapController || points.isEmpty) return;
    await _fitBoundsInsets(points, 90, 70, _panelBottomInset(), 70);
  }

  // _boundsFromPoints removed — use _fitBounds(List<LatLng>, padding) directly

  Future<void> _animateCameraToSelection(LatLng target) async {
    if (!_hasMapController) return;
    await _smoothCameraTransition(target, 16.4);
  }

  Future<void> _startCinematicRouteReveal(List<LatLng> points, int ticket) async {
    if (!mounted || points.isEmpty || ticket != _routeAnimationTicket) return;

    // Stop previous shimmer
    _stopRouteShimmer();

    // 1. Fit camera flat first
    await _fitBoundsInsets(points, 90, 70, _panelBottomInset(), 70);
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted || ticket != _routeAnimationTicket) return;

    // 2. Tilt 0° → 55° + random bearing (1200ms)
    final rng = math.Random();
    final degrees = 5.0 + rng.nextDouble() * 10.0;
    final randomBearing = degrees * (rng.nextBool() ? 1.0 : -1.0);

    _tiltCtrl?.dispose();
    _tiltCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _tiltAnim = Tween<double>(begin: 0.0, end: 55.0).animate(
      CurvedAnimation(parent: _tiltCtrl!, curve: Curves.easeInOutCubic),
    );
    _bearingCtrl?.dispose();
    _bearingCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _bearingAnim = Tween<double>(begin: 0.0, end: randomBearing).animate(
      CurvedAnimation(parent: _bearingCtrl!, curve: Curves.easeInOutCubic),
    );
    _tiltAnim!.addListener(_applyCinematicCamera);
    _tiltCtrl!.forward(from: 0);
    _bearingCtrl!.forward(from: 0);

    // 3. Pin pop at 500ms into tilt
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted || ticket != _routeAnimationTicket) return;
    _startPinPop();

    // 4. Wait for tilt/bearing to finish, then draw the gold route
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted || ticket != _routeAnimationTicket) return;
    await _animateGoldRoute(points);
    if (!mounted || ticket != _routeAnimationTicket) return;

    // 5. Save final camera values
    _cinematicPitch = 55.0;
    _cinematicBearing = randomBearing;
    _cinematicDone = true;
  }

  Future<void> _animateGoldRoute(List<LatLng> points, [Duration? duration]) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) return;

    // Clear old single-color route
    if (_routeAnnot != null) { try { await polyMgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }

    // Pre-create annotation before ticker to avoid async frame skipping
    final initCoords = points.sublist(0, 2).map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: initCoords),
      lineColor: const Color(0xFFFFD700).toARGB32(), lineWidth: 5.0, lineJoin: mapbox.LineJoin.ROUND,
    ));
    if (!mounted || _routeAnnot == null) return;

    final totalMs = duration?.inMilliseconds ?? (points.length * 10).clamp(1800, 3500);
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    int lastCount = 2;
    bool updating = false;

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
      final eased = Curves.easeOutCubic.transform(progress);
      final count = (eased * points.length).round().clamp(2, points.length);

      if (count != lastCount) {
        lastCount = count;
        final subset = points.sublist(0, count);
        final coords = subset.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        _routeAnnot!.geometry = mapbox.LineString(coordinates: coords);
        updating = true;
        polyMgr.update(_routeAnnot!).then((_) => updating = false).catchError((_) => updating = false);
      }
      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        _routeAnnot?.geometry = mapbox.LineString(coordinates: fullCoords);
        if (_routeAnnot != null) polyMgr.update(_routeAnnot!);
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  Future<void> _animateRoutePolyline(List<LatLng> points, int ticket) async {
    if (!mounted || points.isEmpty) return;
    if (ticket != _routeAnimationTicket) return;

    // Stop any previous shimmer
    _routeShimmerCtrl?.dispose();
    _routeShimmerCtrl = null;

    // Clear old annotation for fresh progressive draw
    if (_routeAnnot != null) {
      try { await _polylineAnnotMgr?.delete(_routeAnnot!); } catch (_) {}
      _routeAnnot = null;
    }

    // Pre-create annotation before ticker to avoid async frame skipping
    final initCoords = points.sublist(0, 2).map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    try { _routeAnnot = await _polylineAnnotMgr?.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: initCoords),
      lineColor: _routeColor.toARGB32(), lineWidth: 5.0, lineJoin: mapbox.LineJoin.ROUND,
    )); } catch (_) {}
    if (!mounted || _routeAnnot == null || ticket != _routeAnimationTicket) return;

    final totalMs = (points.length * 10).clamp(1800, 3500);
    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    int lastCount = 2;
    bool updating = false;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) {
      if (!mounted || ticket != _routeAnimationTicket) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      if (updating) return;
      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final eased = Curves.easeOutCubic.transform(progress);
      final count = (eased * points.length).round().clamp(2, points.length);

      if (count != lastCount) {
        lastCount = count;
        final subset = points.sublist(0, count);
        final coords = subset.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        _routeAnnot!.geometry = mapbox.LineString(coordinates: coords);
        updating = true;
        _polylineAnnotMgr?.update(_routeAnnot!).then((_) => updating = false).catchError((_) => updating = false);
      }
      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    await completer.future;
    // Start shimmer after draw completes
    if (mounted && ticket == _routeAnimationTicket) {
      _startRouteShimmer();
    }
  }

  // Route line color: always gold for brand consistency
  Color get _routeColor => const Color(0xFFE8C547);

  Future<void> _setRouteAnnotation(List<LatLng> points) async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || points.length < 2) return;
    final coords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    final geo = mapbox.LineString(coordinates: coords);
    if (_routeAnnot != null) {
      _routeAnnot!.geometry = geo;
      try { await mgr.update(_routeAnnot!); } catch (_) {}
    } else {
      _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
        geometry: geo,
        lineColor: _routeColor.toARGB32(),
        lineWidth: 5.0,
        lineJoin: mapbox.LineJoin.ROUND,
      ));
    }
  }

  Future<void> _clearRouteAnnotation() async {
    _stopRouteShimmer();
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;
    final mgr = _polylineAnnotMgr;
    if (mgr != null) {
      if (_routeAnnot != null) { try { await mgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }
    }
    // Also clear the driver car marker
    _clearDriverCarMarker();
    // Reset cinematic state so next route gets a fresh animation
    _cinematicDone = false;
    _cinematicPitch = 0;
    _cinematicBearing = 0;
    // Reset camera to flat
    _mapController?.setCamera(mapbox.CameraOptions(pitch: 0, bearing: 0));
  }

  Future<void> _cancelMatchingRide() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _c.mapSurface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(20),
        ),
        title: Text(
          S.of(context).stopSearchingQuestion,
          style: TextStyle(
            color: _c.textPrimary,
            fontWeight: FontWeight.w800,
          ),
        ),
        content: Text(
          S.of(context).stopSearchingConfirmation,
          style: TextStyle(color: _c.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              S.of(context).keepRide,
              style: TextStyle(color: _gold, fontWeight: FontWeight.w700),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              S.of(context).cancelButton,
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted) return;

    setState(() => _isCancelling = true);

    // Cancel on backend
    final tripId = _currentTripId;
    if (tripId != null) {
      try {
        await ApiService.cancelTrip(tripId);
      } catch (e) {
        debugPrint('[MapScreen] cancelTrip($tripId) failed: $e');
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(S.of(context).cancelOnServerFailedActive),
              backgroundColor: Colors.red.shade700,
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 4),
            ),
          );
        }
      }
    }

    // Cancel timers and listeners
    _rideLifecycleTimer?.cancel();
    _tripPollTimer?.cancel();

    // Clean up map: route line and annotations
    _stopRouteShimmer();
    ++_routeAnimationTicket; // invalidate any in-progress drawing
    await _clearRouteAnnotation();

    if (!mounted) return;

    setState(() {
      _activeRoutePoints = [];
      _rideProgress = 0;
      _currentTripId = null;
      _currentDriverId = null;
      _isCancelling = false;
    });

    // Pop back to HomeScreen (MapScreen was pushed from HomeScreen)
    Navigator.of(context).maybePop();
  }

  final int _glowFrameSkip = 0;

  @override
  Widget build(BuildContext context) {
    _c = AppColors.of(context);

    _lastIsDark = _c.isDark;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: _bgBlack,
      body: Stack(
        children: [
          RepaintBoundary(
            child: mapbox.MapWidget(
              textureView: true,
              styleUri: _mapStyleUri,
              onMapLoadErrorListener: (err) => debugPrint('[MapScreen] Load error: ${err.message} (type: ${err.type})'),
              cameraOptions: mapbox.CameraOptions(
                center: mapbox.Point(coordinates: mapbox.Position(
                  _currentPosition?.longitude ?? -86.8104,
                  _currentPosition?.latitude ?? 33.5186,
                )),
                zoom: _currentPosition != null ? 14 : 3,
              ),
              onMapCreated: _onMapCreated,
              onStyleLoadedListener: _onStyleLoaded,
              onScrollListener: (_) => _onCameraMoveStarted(),
              onMapIdleListener: (_) => _refreshPinLabelOffsets(),
              onTapListener: (mapbox.MapContentGestureContext ctx) {
                _onMapTap(LatLng(ctx.point.coordinates.lat.toDouble(), ctx.point.coordinates.lng.toDouble()));
              },
            ),
          ),
          if (_stage == RideStage.pin && !_hasPreparedRoute)
            Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.location_pin, color: _c.textPrimary, size: 42),
                  const SizedBox(height: 2),
                  const CircleAvatar(radius: 4, backgroundColor: _gold),
                ],
              ),
            ),

          Positioned(top: 48, right: 14, child: _backButton()),
          Positioned(
            right: 14,
            bottom:
                _currentPanelHeight(context) +
                MediaQuery.of(context).padding.bottom +
                16,
            child: Material(
              color: _panelBlack.withValues(alpha: 0.90),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: _recenterToMyLocation,
                child: SizedBox(
                  width: 46,
                  height: 46,
                  child: Icon(
                    Icons.my_location,
                    color: _gold.withValues(alpha: 0.95),
                    size: 21,
                  ),
                ),
              ),
            ),
          ),
          if (_stage != RideStage.pin &&
              _stage != RideStage.confirmPickup &&
              _stage != RideStage.payment &&
              _pickupAddress.isNotEmpty &&
              _stage != RideStage.riding)
            Positioned(
              top: 50,
              left: 16,
              right: 74,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _panelBlack.withValues(alpha: 0.55),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _gold.withValues(alpha: 0.50)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.my_location, color: _gold, size: 14),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _pickupAddress,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: _c.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // â”€â”€ Rider Navigation Header (shown during riding stage) â”€â”€
          if (_stage == RideStage.riding)
            Positioned(
              top: MediaQuery.of(context).padding.top + 8,
              left: 0,
              right: 0,
              child: _buildRiderNavHeader(),
            ),

          // â”€â”€ Bottom Status Bar (shown during riding stage) â”€â”€
          if (_stage == RideStage.riding)
            Positioned(
              left: 0,
              right: 0,
              bottom: MediaQuery.of(context).padding.bottom + 16,
              child: _buildBottomStatusBar(),
            ),

          // â”€â”€ Driver Arrived overlay (semi-transparent over map) â”€â”€
          if (_stage == RideStage.riding && _tripStatus == 'arrived' && _showDriverArrivedScreen)
            Positioned.fill(
              child: DriverArrivedOverlay(
                driverName: _driverName,
                driverPhotoUrl: _driverPhotoUrl.isNotEmpty ? _driverPhotoUrl : null,
                driverCar: _driverCar,
                driverPlate: _driverPlate,
                driverRating: _driverRating,
                driverPhone: _driverPhone.isNotEmpty ? _driverPhone : null,
                freeWaitMinutes: 2,
                onDismiss: () {
                  setState(() => _showDriverArrivedScreen = false);
                  // Fit the FULL route (pickup â†’ dropoff) into view
                  WidgetsBinding.instance.addPostFrameCallback((_) async {
                    if (!mounted) return;
                    await _fitFullRouteVisible();
                  });
                },
                onCancel: () async {
                  final confirm = await showDialog<bool>(
                    context: context,
                    builder: (dialogCtx) => AlertDialog(
                      backgroundColor: _c.mapSurface,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(20),
                      ),
                      title: Text(
                        S.of(context).cancelRide,
                        style: TextStyle(
                          color: _c.textPrimary,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      content: Text(
                        S.of(context).cancelRideConfirmation,
                        style: TextStyle(color: _c.textSecondary),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(dialogCtx, false),
                          child: Text(
                            S.of(context).keepRide,
                            style: TextStyle(color: _gold),
                          ),
                        ),
                        TextButton(
                          onPressed: () => Navigator.pop(dialogCtx, true),
                          child: Text(
                            S.of(context).cancelButton,
                            style: const TextStyle(color: Colors.redAccent),
                          ),
                        ),
                      ],
                    ),
                  );
                  if (confirm == true) _handleRideCancellation();
                },
              ),
            ),

          // Floating pin label chips at the exact route endpoint positions.
          // Visible during loading / options stages when both pins are on screen.
          if (_dropoffPosition != null &&
              _dropoffLabelOffset != null &&
              _dropoffLabelOffset!.dx > 30 &&
              (_stage == RideStage.options || _stage == RideStage.loading))
            Positioned(
              left: _dropoffLabelOffset!.dx + 20,
              top:  _dropoffLabelOffset!.dy - 14,
              child: _PinInfoChip(
                text: _tripDuration != '-- min' && _dropoffAddress.isNotEmpty
                    ? '$_tripDuration \u00b7 ${_dropoffAddress.length > 20 ? "${_dropoffAddress.substring(0, 20)}\u2026" : _dropoffAddress}'
                    : (_dropoffAddress.length > 22
                        ? '${_dropoffAddress.substring(0, 22)}\u2026'
                        : _dropoffAddress),
              ),
            ),
          if (_currentPosition != null &&
              _pickupLabelOffset != null &&
              _pickupLabelOffset!.dx > 30 &&
              (_stage == RideStage.options || _stage == RideStage.loading))
            Positioned(
              left: _pickupLabelOffset!.dx + 20,
              top:  _pickupLabelOffset!.dy - 14,
              child: const _PinInfoChip(text: '\u2022 Current location'),
            ),

          Positioned(
            left: 10,
            right: 10,
            bottom: 8,
            child: GestureDetector(
              behavior: HitTestBehavior.translucent,
              onVerticalDragStart: (_) {
                setState(() {
                  _isPanelDragging = true;
                  _panelDragHeight ??= _panelHeightForStage(context);
                });
              },
              onVerticalDragUpdate: (details) {
                final minHeight = _panelMinHeight(context);
                final maxHeight = _panelMaxHeight(context);
                final nextHeight =
                    (_panelDragHeight ?? _panelHeightForStage(context)) -
                    details.delta.dy;
                setState(() {
                  _panelDragHeight = nextHeight.clamp(minHeight, maxHeight);
                });
              },
              onVerticalDragEnd: (details) {
                _handlePanelDragEnd(context, details.primaryVelocity ?? 0);
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: AnimatedContainer(
                  duration: _panelDurationForStage(velocity: _lastPanelVelocity),
                  curve: Curves.easeOut,
                  height: _currentPanelHeight(context),
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 280),
                    switchInCurve: Curves.easeOutCubic,
                    switchOutCurve: Curves.easeInCubic,
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: CurvedAnimation(
                          parent: animation,
                          curve: const Interval(
                            0.0,
                            0.85,
                            curve: Curves.easeOut,
                          ),
                        ),
                        child: child,
                      );
                    },
                    child: _buildPanel(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Duration _panelDurationForStage({double velocity = 0}) {
    if (_isPanelDragging) {
      return Duration.zero;
    }

    // Velocity-aware: faster fling → shorter animation
    if (velocity.abs() > 1500) return const Duration(milliseconds: 150);
    if (velocity.abs() > 700) return const Duration(milliseconds: 220);

    switch (_stage) {
      case RideStage.pin:
        return const Duration(milliseconds: 280);
      case RideStage.plan:
        return const Duration(milliseconds: 320);
      case RideStage.loading:
      case RideStage.options:
      case RideStage.confirmPickup:
      case RideStage.payment:
      case RideStage.riding:
        return const Duration(milliseconds: 300);
      case RideStage.matching:
        return const Duration(milliseconds: 350);
    }
  }

  BoxDecoration get _panelDecoration => BoxDecoration(
    color: _c.mapSurface,
    borderRadius: const BorderRadius.all(Radius.circular(28)),
    border: Border.fromBorderSide(BorderSide(color: _c.border, width: 1)),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.35),
        blurRadius: 30,
        offset: const Offset(0, -2),
      ),
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.15),
        blurRadius: 8,
        offset: const Offset(0, -1),
      )
    ],
  );

  BoxDecoration get _skeleton => BoxDecoration(
    color: _c.iconMuted,
    borderRadius: const BorderRadius.all(Radius.circular(8)),
  );

  BoxDecoration get _skeletonLight => BoxDecoration(
    color: _c.divider,
    borderRadius: const BorderRadius.all(Radius.circular(8)),
  );

  Future<void> _beginRideRequestFromOptions() async {
    if (!mounted) return;
    _rideLifecycleTimer?.cancel();
    _tripPollTimer?.cancel();

    setState(() {
      _driverName = 'Searching...';
      _driverCar = '';
      _driverPlate = '';
      _driverPhotoUrl = '';
      _driverEta = '...';
      _rideProgress = 0;
      // driver annotation cleared via manager
      _driverNote = '';
      _currentTripId = null;
    });

    _setStage(RideStage.confirmPickup);

    // Refresh pickup annotation for confirmPickup stage
    if (_currentPosition != null) _setPickupAnnotation(_currentPosition!);

    // Zoom into current location for precise pickup selection
    _isRecentering = true;
    final myPos = _currentPosition;
    if (myPos != null && _hasMapController) {
      await _panTo(myPos, zoom: 17.5);
    }
  }

  Future<void> _confirmPickupAndRequestRide() async {
    if (!mounted) return;
    // Go to payment screen instead of directly matching
    _setStage(RideStage.payment);
  }

  Future<void> _processPaymentAndRequestRide() async {
    if (!mounted) return;

    // Mark promo as used if it was applied
    if (_promoActive) {
      await LocalDataService.usePromo();
    }

    final scheduledAt = _buildScheduledAt();
    final isScheduled = !_pickupNow && scheduledAt != null;
    final isAirport = _airportSelection != null;
    final airportNotes = _airportSelection?.flightNumber != null
        ? 'Flight: ${_airportSelection!.flightNumber}'
        : null;

    // ── SCHEDULED trip: use createTrip, show confirmation, go to plan ──
    if (isScheduled) {
      try {
        final riderId = await ApiService.getCurrentUserId();
        final pickupPos = _currentPosition;
        final dropoffPos = _dropoffPosition;

        // Guard: require both addresses before saving
        if (riderId == null) throw Exception('Not logged in');
        if (pickupPos == null) throw Exception('Pickup location not set');
        if (dropoffPos == null || _dropoffAddress.isEmpty) {
          if (mounted) {
            _setStage(RideStage.plan);
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                backgroundColor: const Color(0xFFFF5252),
                content: Text(
                  S.of(context).enterAddressesFirst,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                behavior: SnackBarBehavior.floating,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            );
          }
          return;
        }

        {
          final fareStr = _rides[_selectedRide].price
              .replaceAll('\$', '')
              .replaceAll(',', '');
          final fare = double.tryParse(fareStr) ?? 0;
          final vehicleType = _rides[_selectedRide].name;
          final tripData = await ApiService.createTrip(
            riderId: riderId,
            pickupAddress: _pickupAddress,
            dropoffAddress: _dropoffAddress,
            pickupLat: pickupPos.latitude,
            pickupLng: pickupPos.longitude,
            dropoffLat: dropoffPos.latitude,
            dropoffLng: dropoffPos.longitude,
            fare: fare,
            vehicleType: vehicleType,
            scheduledAt: scheduledAt,
            isAirport: isAirport,
            airportCode: _airportSelection?.airport.code,
            terminal: _airportSelection?.terminal?.name,
            pickupZone: _airportSelection?.arrivalDoor ?? _airportSelection?.airline,
            notes: airportNotes,
          );
          _currentTripId = tripData['id'] as int?;
          debugPrint('\u2705 Scheduled trip created: $_currentTripId');
          // Schedule 1-hour-before local notification
          if (_currentTripId != null) {
            try {
              await NotificationService.scheduleRideReminder(
                tripId: _currentTripId!,
                rideTime: scheduledAt,
                pickup: _pickupAddress,
                dropoff: _dropoffAddress,
              );
            } catch (_) {}
          }
          // Mirror to Firestore for dispatch admin
          try {
            final session = await UserSession.getUser();
            final milesStr = _tripMiles.replaceAll(RegExp(r'[^\d.]'), '');
            final km = (double.tryParse(milesStr) ?? 0.0) * 1.60934;
            final durStr = _tripDuration.replaceAll(RegExp(r'[^\d]'), '');
            final durMin = int.tryParse(durStr) ?? 0;
            final name =
                '${session?['firstName'] ?? ''} ${session?['lastName'] ?? ''}'
                    .trim();
            _firestoreTripId = await TripFirestoreService.submitRideRequest(
              passengerName: name.isEmpty ? 'Passenger' : name,
              passengerPhone: session?['phone'] ?? '',
              pickupAddress: _pickupAddress,
              dropoffAddress: _dropoffAddress,
              pickupLat: pickupPos.latitude,
              pickupLng: pickupPos.longitude,
              dropoffLat: dropoffPos.latitude,
              dropoffLng: dropoffPos.longitude,
              fare: fare,
              distanceKm: km,
              durationMin: durMin,
              vehicleType: vehicleType,
              paymentMethod: _selectedPaymentMethod,
              scheduledAt: scheduledAt,
              isAirportTrip: isAirport,
            );
          } catch (_) {}
        }
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              backgroundColor: const Color(0xFFFF5252),
              content: Text(
                S.of(context).failedToScheduleRide(e.toString()),
                style: const TextStyle(color: Colors.white),
              ),
              behavior: SnackBarBehavior.floating,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          );
          _setStage(RideStage.payment);
        }
        return;
      }
      if (!mounted) return;
      final scheduleLabel = _rideTimeBadgeText;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: _gold,
          content: Text(
            S.of(context).rideScheduledFor(scheduleLabel),
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w700,
            ),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      await LocalDataService.addNotification(
        title: S.of(context).rideScheduledTitle,
        message: S.of(context).rideScheduledMessage(scheduleLabel),
        type: 'ride',
      );
      _setStage(RideStage.plan);
      if (mounted) {
        Navigator.push(
          context,
          slideFromRightRoute(const ScheduledRidesScreen()),
        );
      }
      return;
    }

    // ── IMMEDIATE ride ──
    _setStage(RideStage.matching);
    if (!mounted) return;
    final srchTitle = S.of(context).searchingDriverTitle;
    final srchMsg = S.of(context).searchingDriverMessage(_rides[_selectedRide].name);
    await LocalDataService.addNotification(
      title: srchTitle,
      message: srchMsg,
      type: 'ride',
    );

    // â”€â”€ Write to Firestore so Dispatch Admin sees the trip in real time â”€â”€
    try {
      final session = await UserSession.getUser();
      final pickupPos = _currentPosition;
      final dropoffPos = _dropoffPosition;
      if (pickupPos != null && dropoffPos != null) {
        final fareStr = _rides[_selectedRide].price.replaceAll(
          RegExp(r'[^\d.]'),
          '',
        );
        final fare = double.tryParse(fareStr) ?? 0.0;
        final milesStr = _tripMiles.replaceAll(RegExp(r'[^\d.]'), '');
        final km = (double.tryParse(milesStr) ?? 0.0) * 1.60934;
        final durStr = _tripDuration.replaceAll(RegExp(r'[^\d]'), '');
        final durMin = int.tryParse(durStr) ?? 0;
        final name =
            '${session?['firstName'] ?? ''} ${session?['lastName'] ?? ''}'
                .trim();
        _firestoreTripId = await TripFirestoreService.submitRideRequest(
          passengerName: name.isEmpty ? 'Passenger' : name,
          passengerPhone: session?['phone'] ?? '',
          pickupAddress: _pickupAddress,
          dropoffAddress: _dropoffAddress,
          pickupLat: pickupPos.latitude,
          pickupLng: pickupPos.longitude,
          dropoffLat: dropoffPos.latitude,
          dropoffLng: dropoffPos.longitude,
          fare: fare,
          distanceKm: km,
          durationMin: durMin,
          vehicleType: _rides[_selectedRide].name,
          paymentMethod: _selectedPaymentMethod,
          isAirportTrip: isAirport,
        );
      }
    } catch (e) {
      debugPrint('âš ï¸ Firestore write failed: $e');
    }

    // â”€â”€ Create ride request via dispatch system â”€â”€
    try {
      final riderId = await ApiService.getCurrentUserId();
      final pickupPos = _currentPosition;
      final dropoffPos = _dropoffPosition;

      if (riderId != null && pickupPos != null && dropoffPos != null) {
        // Parse fare from price string like "\$25.50"
        final fareStr = _rides[_selectedRide].price
            .replaceAll('\$', '')
            .replaceAll(',', '');
        final fare = double.tryParse(fareStr) ?? 0;
        final vehicleType = _rides[_selectedRide].name;

        final tripData = await ApiService.dispatchRideRequest(
          riderId: riderId,
          pickupAddress: _pickupAddress,
          dropoffAddress: _dropoffAddress,
          pickupLat: pickupPos.latitude,
          pickupLng: pickupPos.longitude,
          dropoffLat: dropoffPos.latitude,
          dropoffLng: dropoffPos.longitude,
          fare: fare,
          vehicleType: vehicleType,
          isAirport: isAirport,
          airportCode: _airportSelection?.airport.code,
          terminal: _airportSelection?.terminal?.name,
          pickupZone: _airportSelection?.arrivalDoor ?? _airportSelection?.airline,
          notes: airportNotes,
        );

        _currentTripId = tripData['id'] as int?;
        debugPrint('\u2705 Trip dispatched: \$_currentTripId');
      }
    } catch (e) {
      debugPrint(
        '\u26a0\ufe0f Dispatch failed: \$e (continuing with local flow)',
      );
    }

    if (!mounted || _stage != RideStage.matching) return;

    // â”€â”€ Poll dispatch status for driver assignment â”€â”€
    int noDriverCount = 0;
    _tripPollTimer?.cancel();
    _tripPollTimer = Timer.periodic(const Duration(seconds: 2), (timer) async {
      if (!mounted || _stage != RideStage.matching) {
        timer.cancel();
        return;
      }

      if (_currentTripId != null) {
        try {
          final dispatch = await ApiService.getDispatchStatus(_currentTripId!);
          final status = dispatch['status']?.toString() ?? '';

          if (status == 'driver_assigned' ||
              status == 'driver_en_route' ||
              status == 'arrived' ||
              status == 'in_trip') {
            // Driver found!
            timer.cancel();
            if (!mounted || _stage != RideStage.matching) return;

            _currentDriverId = dispatch['driver_id'] as int?;
            final driverLat = (dispatch['driver_lat'] as num?)?.toDouble();
            final driverLng = (dispatch['driver_lng'] as num?)?.toDouble();
            if (driverLat != null && driverLng != null) {
              _driverPosition = LatLng(driverLat, driverLng);
            }

            setState(() {
              _driverName =
                  dispatch['driver_name']?.toString() ?? 'Your Driver';
              _driverCar = dispatch['vehicle_type']?.toString() ?? '';
              _driverPlate = dispatch['driver_plate']?.toString() ?? '';
              _driverPhone = dispatch['driver_phone']?.toString() ?? '';
              final rawPhoto = dispatch['driver_photo_url']?.toString() ?? '';
              _driverPhotoUrl = (rawPhoto.isNotEmpty && rawPhoto != 'null' && rawPhoto != 'None' && rawPhoto != 'undefined')
                  ? (rawPhoto.startsWith('http') ? rawPhoto : '${ApiService.publicBaseUrl}${rawPhoto.startsWith('/') ? '' : '/'}$rawPhoto')
                  : '';
              _driverRating =
                  (dispatch['driver_rating'] as num?)?.toDouble() ?? 4.9;
              // Calculate real initial ETA from driver distance
              if (_driverPosition != null) {
                final pickupPos = _currentPosition;
                if (pickupPos != null) {
                  final distKm =
                      Geolocator.distanceBetween(
                        _driverPosition!.latitude,
                        _driverPosition!.longitude,
                        pickupPos.latitude,
                        pickupPos.longitude,
                      ) /
                      1000;
                  final etaMin = (distKm * 1000 / 17.88 / 60).ceil().clamp(
                    1,
                    99,
                  );
                  _driverEta = '$etaMin min';
                } else {
                  _driverEta = '2 min';
                }
              } else {
                _driverEta = '2 min';
              }
            });

            _setStage(RideStage.riding);
            // Load car image dimensions for progress bar
            if (_rides.isNotEmpty && _selectedRide < _rides.length) {
              _loadCarImageInfo(_rideCarAsset(_rides[_selectedRide].name));
            }
            await LocalDataService.addNotification(
              title: S.of(context).driverAssignedTitle,
              message: S
                  .of(context)
                  .driverAssignedMessage(_driverName, _driverEta),
              type: 'ride',
            );

            // â”€â”€ Sync driver assignment to Firestore for Dispatch Admin â”€â”€
            if (_firestoreTripId != null) {
              TripFirestoreService.syncDriverAssigned(
                _firestoreTripId!,
                driverName: _driverName,
                driverId: _currentDriverId?.toString(),
              );
            }

            if (_driverPosition != null) _animateDriverTo(_driverPosition!);
            _startRideProgressTracking();
            return;
          } else if (status == 'canceled' || status == 'cancelled') {
            timer.cancel();
            if (!mounted) return;
            _rideLifecycleTimer?.cancel();
            setState(() {
              _rideProgress = 0;
              _clearRouteAnnotation();
              _activeRoutePoints = [];
              _driverRoutePoints = [];
              // driver annotation cleared via manager
              _dropoffPosition = null;
            });
            // Only show cancelled dialog if a human (dispatch/admin) cancelled.
            // If auto-cancelled due to no drivers, go back silently.
            final reason =
                (dispatch['cancel_reason'] ??
                        dispatch['cancellation_reason'] ??
                        dispatch['reason'] ??
                        '')
                    .toString()
                    .toLowerCase();
            final isNoDrivers =
                reason.contains('no_driver') ||
                reason.contains('no driver') ||
                reason.contains('timeout') ||
                reason.contains('expired') ||
                reason.isEmpty;
            if (isNoDrivers) {
              _setStage(RideStage.options);
            } else {
              _setStage(RideStage.plan);
              _showTripCancelledDialog();
            }
            return;
          } else if (status == 'no_drivers') {
            noDriverCount++;
            if (noDriverCount >= 10) {
              // After 30s of no drivers, notify rider
              timer.cancel();
              if (!mounted) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(S.of(context).noDriversAvailable),
                  duration: Duration(seconds: 3),
                ),
              );
              _setStage(RideStage.options);
            }
          } else {
            noDriverCount = 0; // reset if searching
          }
        } catch (e) {
          debugPrint('\u26a0\ufe0f Poll dispatch status: \$e');
        }
      }
    });
  }

  /// Draw the real driving route from driver to destination on the rider's map.
  /// During driver_en_route/driver_assigned: driver â†’ pickup + pickup â†’ dropoff
  /// During in_trip: driver â†’ dropoff
  Future<void> _updateDriverRoute(String status) async {
    if (!mounted || _driverPosition == null) return;

    final pickupPos = _currentPosition;
    final dropoffPos = _activeRoutePoints.isNotEmpty ? _activeRoutePoints.last : null;
    if (pickupPos == null || dropoffPos == null) return;

    // Determine route phase
    final isEnRoute =
        (status == 'driver_en_route' ||
        status == 'driver_assigned' ||
        status == 'arrived');
    final routePhase = isEnRoute ? 'en_route' : 'in_trip';

    // Redraw route when phase changes or first draw
    bool needsRedraw =
        routePhase != _lastDriverRoutePhase || _driverRoutePoints.isEmpty;
    if (!needsRedraw && _driverRoutePoints.isNotEmpty) {
      // Trim route behind driver locally instead of re-fetching from API
      _trimRiderRoute(_driverPosition!);
      return;
    }

    _lastDriverRoutePhase = routePhase;
    _driverSnapIdx = 0; // reset snap cursor for the new route segment

    if (isEnRoute) {
      // Draw: driver â†’ pickup (green) + pickup â†’ dropoff (gold)
      final driverToPickup = await _fetchDrivingRoute(
        _driverPosition!,
        pickupPos,
      );
      final pickupToDropoff = _activeRoutePoints.isNotEmpty
          ? _activeRoutePoints
          : (await _fetchDrivingRoute(pickupPos, dropoffPos));

      if (!mounted) return;

      if (driverToPickup.isNotEmpty) {
        // Cap endpoint to exact pickup pin coordinate
        driverToPickup[driverToPickup.length - 1] = pickupPos;
        _driverRoutePoints = driverToPickup;
        await _setRouteAnnotation(driverToPickup);
      }
      if (pickupToDropoff.isNotEmpty) {
        // Cap endpoints to exact pickup/dropoff pin coordinates
        pickupToDropoff[0] = pickupPos;
        pickupToDropoff[pickupToDropoff.length - 1] = dropoffPos;
        await _setRouteAnnotation(pickupToDropoff);
      }
      // Fit bounds to show driver + pickup + dropoff
      _fitRideBounds([_driverPosition!, pickupPos, dropoffPos]);
    } else {
      // in_trip: draw driver â†’ dropoff
      final driverToDropoff = await _fetchDrivingRoute(
        _driverPosition!,
        dropoffPos,
      );
      if (!mounted) return;

      if (driverToDropoff.isNotEmpty) {
        // Cap endpoint to exact dropoff pin coordinate
        driverToDropoff[driverToDropoff.length - 1] = dropoffPos;
        _driverRoutePoints = driverToDropoff;
        await _setRouteAnnotation(driverToDropoff);
      }

      // Fit bounds to show driver + dropoff
      _fitRideBounds([_driverPosition!, dropoffPos]);
    }
  }

  /// Fetch a driving route between two points using Google Directions API / OSRM.
  Future<List<LatLng>> _fetchDrivingRoute(LatLng origin, LatLng dest) async {
    // Try Google Directions API
    try {
      final uri =
          Uri.https('maps.googleapis.com', '/maps/api/directions/json', {
            'origin': '${origin.latitude},${origin.longitude}',
            'destination': '${dest.latitude},${dest.longitude}',
            'key': ApiKeys.webServices,
            'mode': 'driving',
          });
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body);
        if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
          final route = data['routes'][0];
          return _decodePolyline(
            route['overview_polyline']['points'] as String,
          );
        }
      }
    } catch (_) {}

    // Fallback: OSRM
    try {
      final path =
          '/route/v1/driving/${origin.longitude},${origin.latitude};${dest.longitude},${dest.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 8));
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic> &&
          data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          return _decodePolyline(routes[0]['geometry'] as String);
        }
      }
    } catch (_) {}

    // Mapbox Directions API fallback
    try {
      final mbxUrl = Uri.parse(
        'https://api.mapbox.com/directions/v5/mapbox/driving/'
        '${origin.longitude},${origin.latitude};${dest.longitude},${dest.latitude}'
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
            return coords
                .map((c) => LatLng((c[1] as num).toDouble(), (c[0] as num).toDouble()))
                .toList();
          }
        }
      }
    } catch (_) {}

    // Last resort: straight line
    return List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        origin.latitude + (dest.latitude - origin.latitude) * t,
        origin.longitude + (dest.longitude - origin.longitude) * t,
      );
    });
  }

  // _fitRideBounds is defined earlier — see above

  Future<void> _completeRide() async {
    if (!mounted) return;
    _driverSnapIdx = 0; // reset snap cursor on ride complete

    // Resolve pickup address if it's a placeholder
    var resolvedPickup = _pickupAddress;
    if (resolvedPickup.isEmpty ||
        resolvedPickup == 'Current location' ||
        resolvedPickup.startsWith('--')) {
      if (_currentPosition != null) {
        try {
          final addr = await _places.reverseGeocode(
            lat: _currentPosition!.latitude,
            lng: _currentPosition!.longitude,
          );
          if (addr != null && addr.isNotEmpty) resolvedPickup = addr;
        } catch (_) {}
      }
    }

    final completedRide = _rides[_selectedRide];
    final completedTrip = TripHistoryItem(
      pickup: resolvedPickup,
      dropoff: _dropoffAddress,
      rideName: completedRide.name,
      price: completedRide.price,
      miles: _tripMiles,
      duration: _tripDuration,
      createdAt: DateTime.now(),
    );
    await LocalDataService.addTrip(completedTrip);
    final doneTitle = mounted ? S.of(context).tripCompletedTitle : '';
    final doneMsg = mounted ? '${S.of(context).arrivedAtDestination} (${completedRide.name})' : '';
    await LocalDataService.addNotification(
      title: doneTitle,
      message: doneMsg,
      type: 'ride',
    );

    // Decrement promo trip counter — unlocks 10% off after 3 trips
    final prefs = await SharedPreferences.getInstance();
    final tripsLeft = prefs.getInt('promo_trips_left') ?? 0;
    if (tripsLeft > 0) {
      final newLeft = tripsLeft - 1;
      await prefs.setInt('promo_trips_left', newLeft);
      if (newLeft == 0) {
        // Unlock promo again
        await prefs.setBool('first_ride_promo_used', false);
      }
    }

    if (!mounted) return;

    setState(() {
      _rideProgress = 0;
      _tripDuration = '-- min';
      _clearRouteAnnotation();
      _activeRoutePoints = [];
      _driverRoutePoints = [];
      _driverPosition = null;
      _currentDriverId = null;
      _lastDriverRoutePhase = '';
      // driver annotation cleared via manager
      _dropoffPosition = null;
      _dropoffAddress = '';
      _dropoffCtrl.clear();
      _hasPreparedRoute = false;
    });

    _setStage(RideStage.plan);
    if (!mounted) return;

    // â”€â”€ Show rating + tip screen first â”€â”€
    await Navigator.of(context).push(
      sharedAxisVerticalRoute(
        RideRatingScreen(
          driverName: _driverName,
          rideName: completedRide.name,
          price: completedRide.price,
        ),
      ),
    );

    if (!mounted) return;
    await Navigator.of(
      context,
    ).push(sharedAxisVerticalRoute(TripReceiptScreen(trip: completedTrip)));
  }

  Future<void> _updateGoldDotAnnotation() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;

    // Feed latest GPS position into the dot's lerp target
    final pos = _currentPosition;
    if (pos != null) {
      _goldDot.setTarget(pos.latitude, pos.longitude);
    }

    // Use the interpolated (lerped) position for smooth movement
    final lat = _goldDot.lat;
    final lng = _goldDot.lng;
    if (lat == null || lng == null) return;

    final bytes = _goldDot.currentBytes;
    if (bytes == null) return;

    if (_goldDotAnnot != null) {
      try {
        _goldDotAnnot!.geometry = mapbox.Point(
          coordinates: mapbox.Position(lng, lat));
        _goldDotAnnot!.image = bytes;
        await mgr.update(_goldDotAnnot!);
        return;
      } catch (_) { _goldDotAnnot = null; }
    }
    _goldDotAnnot = await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(lng, lat)),
      image: bytes,
      iconSize: 1.0,  // Match driver screen gold dot size
      iconAnchor: mapbox.IconAnchor.CENTER,
      iconOffset: [0, 0],
    ));
  }

  /// Recalculate route polyline without moving the camera.
  /// Shows the new line instantly (no animation) to stay snappy while
  /// the user is panning to adjust the pickup spot.
  Future<void> _silentRouteRecalculate() async {
    if (_currentPosition == null || _dropoffPosition == null) return;
    final ticket = ++_routeAnimationTicket;
    final origin = _currentPosition!;
    final destination = _dropoffPosition!;
    final route = await _directions.getRoute(
      origin: origin,
      destination: destination,
    );
    if (!mounted || ticket != _routeAnimationTicket) return;
    if (route != null) {
      // Use road-snapped route points directly — do NOT cap with raw coords
      _activeRoutePoints = route.points;
      setState(() {
        _tripMiles = _formatMiles(route.distanceMeters);
        _tripDuration = route.durationText;
        _updateRidePricingFromDuration(_tripDuration);
      });
      await _setRouteAnnotation(_activeRoutePoints);
    }
  }

  // â”€â”€ Payment method helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Returns display info for a payment method id.
  ({String label, Widget logoWidget}) _paymentMethodInfo(String id) {
    // On iOS show Apple Pay, on Android show Google Pay
    final isIOS = Platform.isIOS;
    final walletLabel = isIOS ? 'Apple Pay' : 'Google Pay';
    final walletLogo = isIOS ? _applePayLogoWidget(36) : _googlePayLogoWidget(36);
    switch (id) {
      case 'apple_pay':
        return (label: 'Apple Pay', logoWidget: _applePayLogoWidget(36));
      case 'google_pay':
        return (label: 'Google Pay', logoWidget: _googlePayLogoWidget(36));
      case 'credit_card':
        if (_savedCardLast4 != null && _savedCardBrand != null) {
          return (
            label:
                '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4',
            logoWidget: _cardBrandLogoWidget(_savedCardBrand, 36),
          );
        }
        return (
          label: S.of(context).creditOrDebitCard,
          logoWidget: _brandLogo(
            null,
            const Color(0xFF6B7280),
            icon: Icons.credit_card_rounded,
          ),
        );
      case 'paypal':
        return (label: 'PayPal', logoWidget: _paypalLogoWidget(36));
      default:
        return (label: walletLabel, logoWidget: walletLogo);
    }
  }

  /// Called when the user picks a payment method.
  void _onPaymentMethodSelected(String id) async {
    setState(() => _selectedPaymentMethod = id);

    final linked = _linkedPaymentMethods.contains(id);

    if (!linked) {
      // Not connected — for Google Pay and PayPal, open their apps directly
      if (id == 'google_pay') {
        await _launchGooglePayFromMap();
        if (!mounted) return;
        _loadLinkedPayments();
        return;
      }
      if (id == 'paypal') {
        await _launchPayPalFromMap();
        if (!mounted) return;
        _loadLinkedPayments();
        return;
      }
      if (id == 'credit_card') {
        if (!mounted) return;
        final result = await Navigator.of(
          context,
        ).push<String>(slideFromRightRoute(const CreditCardScreen()));
        if (result != null && result.isNotEmpty) {
          String brand = 'card';
          String last4 = result;
          if (result.contains(':')) {
            final parts = result.split(':');
            brand = parts[0];
            last4 = parts[1];
          }
          await LocalDataService.linkPaymentMethod('credit_card');
          await LocalDataService.saveCreditCardLast4(last4);
          await LocalDataService.saveCreditCardBrand(brand);
          _loadLinkedPayments();
        }
        return;
      }
      // Fallback: send to PaymentAccountsScreen
      if (!mounted) return;
      await Navigator.of(
        context,
      ).push(slideFromRightRoute(const PaymentAccountsScreen()));
      _loadLinkedPayments();
      return;
    }

    // Already linked — for credit_card, only open card entry if user explicitly
    // wants to change (weâ€™re just selecting it here, not re-entering).
    // Google Pay and PayPal: just selecting is enough.
    // No additional action needed.
  }

  /// Launch Google Pay / Google Wallet app.
  Future<void> _launchGooglePayFromMap() async {
    const walletIntentUri =
        'intent://pay.google.com/#Intent;scheme=https;package=com.google.android.apps.walletnfcrel;end';
    const gpayAppUri = 'https://pay.google.com/gp/w/home';
    const playStoreUri =
        'https://play.google.com/store/apps/details?id=com.google.android.apps.walletnfcrel';
    try {
      final launched = await launchUrl(
        Uri.parse(walletIntentUri),
        mode: LaunchMode.externalApplication,
      );
      if (launched) {
        await _confirmExternalLink('Google Pay', 'google_pay');
        return;
      }
    } catch (_) {}
    try {
      final launched = await launchUrl(
        Uri.parse(gpayAppUri),
        mode: LaunchMode.externalApplication,
      );
      if (launched) {
        await _confirmExternalLink('Google Pay', 'google_pay');
        return;
      }
    } catch (_) {}
    try {
      await launchUrl(
        Uri.parse(playStoreUri),
        mode: LaunchMode.externalApplication,
      );
      await _confirmExternalLink('Google Pay', 'google_pay');
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).googlePayNotAvailable),
            // Uses global snackBarTheme
          ),
        );
      }
    }
  }

  /// Launch PayPal app or website.
  Future<void> _launchPayPalFromMap() async {
    try {
      final launched = await launchUrl(
        Uri.parse('paypal://home'),
        mode: LaunchMode.externalApplication,
      );
      if (!launched) {
        await launchUrl(
          Uri.parse('https://www.paypal.com/signin'),
          mode: LaunchMode.externalApplication,
        );
      }
    } catch (_) {
      await launchUrl(
        Uri.parse('https://www.paypal.com/signin'),
        mode: LaunchMode.externalApplication,
      );
    }
    await _confirmExternalLink('PayPal', 'paypal');
  }

  /// After returning from an external app, ask user if they linked successfully.
  Future<void> _confirmExternalLink(String name, String id) async {
    if (!mounted) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: _c.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: Text(
          S.of(context).completeSetupQuestion,
          style: TextStyle(
            color: _c.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          S.of(context).confirmLinkedAccount(name),
          style: TextStyle(color: _c.textSecondary, fontSize: 15),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              S.of(context).notYet,
              style: TextStyle(
                color: _c.textTertiary,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(
              S.of(context).yesLinked,
              style: const TextStyle(color: _gold, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await LocalDataService.linkPaymentMethod(id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: _gold,
            content: Text(
              S.of(context).linkedSuccessfully(name),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
          ),
        );
      }
    }
  }

  /// Load actual pixel dimensions of car image and compute aspect ratio.
  Future<void> _loadCarImageInfo(String assetPath) async {
    final provider = AssetImage(assetPath);
    final stream = provider.resolve(
      ImageConfiguration(devicePixelRatio: MediaQuery.of(context).devicePixelRatio),
    );
    final completer = Completer<ui.Image>();
    late ImageStreamListener listener;
    listener = ImageStreamListener((ImageInfo info, bool _) {
      completer.complete(info.image);
      stream.removeListener(listener);
    });
    stream.addListener(listener);
    final img = await completer.future;
    if (mounted) {
      setState(() {
        _carImageAspectRatio = img.width / img.height;
      });
    }
  }

  // ── Progress bar constants ──

  /// Badge info: (label, icon, bgColor, textColor)
  (String, IconData, Color, Color) _rideBadgeInfo(String name) {
    final n = name.toLowerCase();
    if (n.contains('vip')) return ('VIP', Icons.star_rounded, const Color(0xFFD4AF37), Colors.black);
    if (n.contains('comfort')) return ('COMFORT', Icons.eco_rounded, const Color(0xFF1A3A2A), const Color(0xFF2ECC71));
    return ('PREMIUM', Icons.diamond_rounded, const Color(0xFF2A2F45), Colors.white);
  }
}

class _Badge extends StatelessWidget {
  final IconData icon;
  final String text;
  final VoidCallback? onTap;

  const _Badge({required this.icon, required this.text, this.onTap});

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(99),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: c.surface,
          borderRadius: BorderRadius.circular(99),
          border: Border.all(color: const Color(0xFFD8A84E), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: c.iconDefault),
            const SizedBox(width: 6),
            Text(
              text,
              style: TextStyle(
                color: c.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 14,
                shadows: _thinWhiteOutlineFor(c),
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.keyboard_arrow_down, size: 16, color: c.iconDefault),
          ],
        ),
      ),
    );
  }

  List<Shadow> _thinWhiteOutlineFor(AppColors ac) {
    final sc = ac.isDark ? const Color(0xCCFFFFFF) : const Color(0x44000000);
    return [
      Shadow(color: sc, offset: const Offset(0.35, 0), blurRadius: 0),
      Shadow(color: sc, offset: const Offset(-0.35, 0), blurRadius: 0),
      Shadow(color: sc, offset: const Offset(0, 0.35), blurRadius: 0),
      Shadow(color: sc, offset: const Offset(0, -0.35), blurRadius: 0),
    ];
  }
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//  Uber-style pulsing radar for matching screen
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
class _MatchingRadar extends StatefulWidget {
  final Color color;
  final bool isSearching;
  const _MatchingRadar({required this.color, required this.isSearching});

  @override
  State<_MatchingRadar> createState() => _MatchingRadarState();
}

class _MatchingRadarState extends State<_MatchingRadar>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2200),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.isSearching) {
      return TweenAnimationBuilder<double>(
        tween: Tween(begin: 0.8, end: 1.0),
        duration: const Duration(milliseconds: 300),
        curve: Curves.elasticOut,
        builder: (_, scale, child) =>
            Transform.scale(scale: scale, child: child),
        child: Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.4),
                blurRadius: 20,
                spreadRadius: 4,
              ),
            ],
          ),
          child: const Icon(Icons.check_rounded, color: Colors.black, size: 40),
        ),
      );
    }

    return Stack(
      alignment: Alignment.center,
      children: [
        // Pulse rings
        ListenableBuilder(
          listenable: _ctrl,
          builder: (_, __) => CustomPaint(
            painter: _RadarPainter(
              progress: _ctrl.value,
              color: widget.color,
            ),
          ),
        ),
        // Center car icon
        Container(
          width: 54,
          height: 54,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: widget.color,
            boxShadow: [
              BoxShadow(
                color: widget.color.withValues(alpha: 0.45),
                blurRadius: 18,
                spreadRadius: 3,
              ),
            ],
          ),
          child: const Icon(
            Icons.directions_car_rounded,
            color: Colors.black,
            size: 28,
          ),
        ),
      ],
    );
  }
}

class _RadarPainter extends CustomPainter {
  final double progress;
  final Color color;

  _RadarPainter({required this.progress, required this.color});

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final maxRadius = size.width / 2;

    // 4 concentric expanding rings — staggered phase, quadratic fade
    for (int i = 0; i < 4; i++) {
      final phase = (progress + i * 0.25) % 1.0;
      final radius = maxRadius * 0.34 + maxRadius * 0.66 * phase;
      final alpha = ((1.0 - phase) * (1.0 - phase)).clamp(0.0, 1.0) * 0.55;
      if (alpha < 0.01) continue;

      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5 + (1.0 - phase) * 1.5;

      canvas.drawCircle(center, radius, paint);
    }

    // Rotating sweep arc — 60° arc spinning around the inner ring
    final arcPaint = Paint()
      ..color = color.withValues(alpha: 0.30)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..strokeCap = StrokeCap.round;
    final arcStart = progress * math.pi * 2 - math.pi / 2;
    canvas.drawArc(
      Rect.fromCircle(center: center, radius: maxRadius * 0.68),
      arcStart,
      math.pi / 3,
      false,
      arcPaint,
    );

    // Inner glow fill — subtle pulsing disk
    final glowRadius = maxRadius * 0.34 + 4 * math.sin(progress * math.pi * 2);
    final glowPaint = Paint()
      ..color = color.withValues(alpha: 0.10)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(center, glowRadius, glowPaint);
  }

  @override
  bool shouldRepaint(_RadarPainter old) => old.progress != progress;
}

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//  Animated "Looking for your driver..." with dots
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
class _AnimatedSearchText extends StatefulWidget {
  final String text;
  final TextStyle style;
  const _AnimatedSearchText({required this.text, required this.style});

  @override
  State<_AnimatedSearchText> createState() => _AnimatedSearchTextState();
}

class _AnimatedSearchTextState extends State<_AnimatedSearchText> {
  int _dotCount = 0;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 800), (_) {
      if (mounted) setState(() => _dotCount = (_dotCount + 1) % 4);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final dots = '.' * _dotCount;
    return Text(
      '${widget.text}$dots',
      style: widget.style,
      textAlign: TextAlign.center,
    );
  }
}

// Map styles are now in config/map_styles.dart (MapStyles.dark / MapStyles.ligh

/// 3D perspective road painted under ride card car images.
class _RoadPerspectivePainter extends CustomPainter {
  final Color color;
  final bool isSelected;

  _RoadPerspectivePainter({required this.color, required this.isSelected});

  @override
  void paint(Canvas canvas, Size size) {
    // Road surface (trapezoid)
    final roadPaint = Paint()
      ..shader = LinearGradient(
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
        colors: [
          const Color(0xFF1A1A2E).withValues(alpha: 0.0),
          const Color(0xFF0D0D1A).withValues(alpha: 0.8),
        ],
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));

    final roadPath = Path()
      ..moveTo(size.width * 0.2, size.height * 0.3)
      ..lineTo(size.width * 0.8, size.height * 0.3)
      ..lineTo(size.width, size.height)
      ..lineTo(0, size.height)
      ..close();
    canvas.drawPath(roadPath, roadPaint);

    // Center dashes (perspective)
    final dashPaint = Paint()
      ..color = color.withValues(alpha: isSelected ? 0.4 : 0.15)
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;

    for (int i = 0; i < 4; i++) {
      final t = i / 4.0;
      final nextT = (i + 0.5) / 4.0;
      final y1 = size.height * 0.35 + (size.height * 0.65 * t);
      final y2 = size.height * 0.35 + (size.height * 0.65 * nextT);
      canvas.drawLine(Offset(size.width * 0.5, y1), Offset(size.width * 0.5, y2), dashPaint);
    }

    // Edge lines
    final edgePaint = Paint()
      ..color = color.withValues(alpha: isSelected ? 0.3 : 0.1)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    canvas.drawLine(Offset(size.width * 0.1, size.height * 0.3), Offset(0, size.height), edgePaint);
    canvas.drawLine(Offset(size.width * 0.9, size.height * 0.3), Offset(size.width, size.height), edgePaint);

    // Glow when selected
    if (isSelected) {
      final glowPaint = Paint()
        ..shader = RadialGradient(
          center: const Alignment(0, 0.5),
          radius: 0.8,
          colors: [color.withValues(alpha: 0.15), color.withValues(alpha: 0.0)],
        ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
      canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), glowPaint);
    }
  }

  @override
  bool shouldRepaint(_RoadPerspectivePainter old) => old.isSelected != isSelected || old.color != color;
}
