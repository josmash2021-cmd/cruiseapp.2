import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
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
import '../services/places_service.dart';
import 'airport_terminal_sheet.dart';
import 'credit_card_screen.dart';
import 'payment_accounts_screen.dart';
import 'ride_rating_screen.dart';
import 'schedule_booking_screen.dart';
import 'scheduled_rides_screen.dart';
import 'trip_receipt_screen.dart';
import '../navigation/car_icon_loader.dart';
import '../services/api_service.dart';
import '../services/trip_firestore_service.dart';
import '../services/user_session.dart';
import 'pickup_dropoff_search_screen.dart';

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

class _MapScreenState extends State<MapScreen> with TickerProviderStateMixin {
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

  static const _gold = Color(0xFFE8C547);
  static const _pinColor = Color(0xFFE8C547);
  static const _birminghamDefault = LatLng(33.5186, -86.8104);

  /// Picks the right JSON map style based on the system theme (light phone = light map).
  String get _mapStyle => _c.isDark ? MapStyles.darkIOS : MapStyles.lightIOS;

  static final _usBounds = LatLngBounds(
    southwest: LatLng(24.396308, -124.848974),
    northeast: LatLng(49.384358, -66.885444),
  );
  static const double _defaultMapZoom = 13.7;
  static const double _goldPinHue = 0.0;

  BitmapDescriptor? _goldPinIcon;
  BitmapDescriptor? _dropoffPinIcon;
  // Raw bytes for the gold pins — used by Apple Maps on iOS.
  Uint8List? _goldPinIconBytes;
  Uint8List? _dropoffPinIconBytes;
  Uint8List? _driverCarIconBytes;

  GoogleMapController? _mapController;

  /// True when the Google Maps controller is ready.
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

  Marker? _pickupMarker;
  Marker? _dropoffMarker;
  Marker? _driverMarker;
  Set<Polyline> _polylines = {};
  List<LatLng> _activeRoutePoints = [];

  AnimationController? _glowController;
  double _routeGlowPhase = 0.0;

  /// Toggle state for the recenter (my_location) button.
  /// false = next tap centers on pickup at default zoom
  /// true  = next tap zooms IN close to pickup
  bool _isCenteredOnPickup = false;
  static const double _zoomInCloseLevel = 17.5;
  static const double _zoomOutLevel = 10.5; // ignore: unused_field

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
  bool _planBodyVisible = false;
  double? _panelDragHeight;
  bool _isPanelDragging = false;
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
  LatLng? _driverPosition;
  LatLng? _prevDriverPosition; // for smooth interpolation
  double _driverBearing = 0; // bearing toward destination
  BitmapDescriptor? _driverCarIcon; // canvas-painted car icon
  DateTime? _lastDriverMarkerRebuild;
  AnimationController? _riderDriverAnim; // 60fps smooth driver animation
  LatLng _riderAnimFrom = _birminghamDefault;
  LatLng _riderAnimTo = _birminghamDefault;
  double _riderTargetBearing = 0;
  List<LatLng> _driverRoutePoints = [];
  String _lastDriverRoutePhase = ''; // 'driver_en_route' or 'in_trip'
  String _driverName = 'Searching...';
  String _driverCar = '';
  String _driverPlate = '';
  double _driverRating = 4.9;
  String _driverEta = '...';
  String _driverPhone = '';
  String _tripStatus =
      'driver_en_route'; // tracks current trip phase for rider UI

  String _driverNote = '';

  int _selectedRide = 0;
  int? _preSelectedRideIndex;
  bool _promoActive = false;
  int _promoDiscountPercent = 0;
  String _selectedPaymentMethod =
      'google_pay'; // id: google_pay, credit_card, paypal
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

  Future<BitmapDescriptor> _buildGoldPin({
    bool withHouse = false,
    bool isPickup = true,
  }) async {
    const double size = 80;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));

    const cx = size / 2;
    const cy = size / 2;
    const r = size * 0.38;

    // Drop shadow
    canvas.drawCircle(
      const Offset(cx, cy + 2),
      r + 2,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    if (isPickup) {
      // ── Circle shape for pickup ──
      canvas.drawCircle(const Offset(cx, cy), r, Paint()..color = _pinColor);
      canvas.drawCircle(
        const Offset(cx, cy),
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white.withValues(alpha: 0.25),
      );
    } else {
      // ── Rounded square shape for dropoff ──
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: const Offset(cx, cy),
          width: r * 2,
          height: r * 2,
        ),
        Radius.circular(r * 0.28),
      );
      canvas.drawRRect(rect, Paint()..color = _pinColor);
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white.withValues(alpha: 0.25),
      );
    }

    // Inner highlight
    canvas.drawCircle(
      Offset(cx - r * 0.2, cy - r * 0.2),
      r * 0.5,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    // White icon on gold pin
    final iconPaint = Paint()
      ..color = Colors.white
      ..isAntiAlias = true;

    if (withHouse) {
      // House icon
      final hs = size * 0.10;
      final roof = Path()
        ..moveTo(cx, cy - hs * 1.1)
        ..lineTo(cx - hs * 1.0, cy - hs * 0.1)
        ..lineTo(cx + hs * 1.0, cy - hs * 0.1)
        ..close();
      canvas.drawPath(roof, iconPaint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            cx - hs * 0.7,
            cy - hs * 0.1,
            cx + hs * 0.7,
            cy + hs * 0.8,
          ),
          Radius.circular(hs * 0.08),
        ),
        iconPaint,
      );
    } else {
      // Person icon (for pickup)
      final s = size * 0.10;
      canvas.drawCircle(Offset(cx, cy - s * 0.6), s * 0.5, iconPaint);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(cx - s * 0.8, cy + s * 0.1, cx + s * 0.8, cy + s * 0.9),
          topLeft: Radius.circular(s * 0.8),
          topRight: Radius.circular(s * 0.8),
          bottomLeft: Radius.circular(s * 0.15),
          bottomRight: Radius.circular(s * 0.15),
        ),
        iconPaint,
      );
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    final rawBytes = byteData!.buffer.asUint8List();
    // ignore: deprecated_member_use
    return BitmapDescriptor.fromBytes(rawBytes);
  }

  /// Renders the gold pin as raw PNG bytes (for Apple Maps on iOS).
  Future<Uint8List> _buildGoldPinBytes({
    bool withHouse = false,
    bool isPickup = true,
  }) async {
    // Re-use the BitmapDescriptor builder; extract bytes from it.
    final byteRecorder = ui.PictureRecorder();
    const double size = 80;
    final canvas = Canvas(byteRecorder, const Rect.fromLTWH(0, 0, size, size));

    const cx = size / 2;
    const cy = size / 2;
    const r = size * 0.38;

    // Drop shadow
    canvas.drawCircle(
      const Offset(cx, cy + 2),
      r + 2,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    if (isPickup && !withHouse) {
      canvas.drawCircle(const Offset(cx, cy), r, Paint()..color = _pinColor);
      canvas.drawCircle(
        const Offset(cx, cy),
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white.withValues(alpha: 0.25),
      );
    } else {
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: const Offset(cx, cy),
          width: r * 2,
          height: r * 2,
        ),
        Radius.circular(r * 0.28),
      );
      canvas.drawRRect(rect, Paint()..color = _pinColor);
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white.withValues(alpha: 0.25),
      );
    }

    canvas.drawCircle(
      Offset(cx - r * 0.2, cy - r * 0.2),
      r * 0.5,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    final iconPaint = Paint()
      ..color = Colors.white
      ..isAntiAlias = true;

    if (withHouse) {
      final hs = size * 0.10;
      final roof = Path()
        ..moveTo(cx, cy - hs * 1.1)
        ..lineTo(cx - hs * 1.0, cy - hs * 0.1)
        ..lineTo(cx + hs * 1.0, cy - hs * 0.1)
        ..close();
      canvas.drawPath(roof, iconPaint);
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTRB(
            cx - hs * 0.7,
            cy - hs * 0.1,
            cx + hs * 0.7,
            cy + hs * 0.8,
          ),
          Radius.circular(hs * 0.08),
        ),
        iconPaint,
      );
    } else {
      final s = size * 0.10;
      canvas.drawCircle(Offset(cx, cy - s * 0.6), s * 0.5, iconPaint);
      canvas.drawRRect(
        RRect.fromRectAndCorners(
          Rect.fromLTRB(cx - s * 0.8, cy + s * 0.1, cx + s * 0.8, cy + s * 0.9),
          topLeft: Radius.circular(s * 0.8),
          topRight: Radius.circular(s * 0.8),
          bottomLeft: Radius.circular(s * 0.15),
          bottomRight: Radius.circular(s * 0.15),
        ),
        iconPaint,
      );
    }

    final pic = byteRecorder.endRecording();
    final img = await pic.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  Marker _pickupMapMarker(LatLng position, {String? snippet}) {
    return Marker(
      markerId: const MarkerId('pickup'),
      position: position,
      draggable: _stage == RideStage.confirmPickup,
      icon: _goldPinIcon ?? BitmapDescriptor.defaultMarkerWithHue(_goldPinHue),
      infoWindow: InfoWindow(
        title: S.of(context).pickupLabel,
        snippet: snippet,
      ),
      onDragEnd: _stage == RideStage.confirmPickup
          ? _onPickupMarkerDragEnd
          : null,
    );
  }

  Marker _dropoffMapMarker(LatLng position, {String? snippet}) {
    return Marker(
      markerId: const MarkerId('dropoff'),
      position: position,
      icon:
          _dropoffPinIcon ??
          _goldPinIcon ??
          BitmapDescriptor.defaultMarkerWithHue(_goldPinHue),
      infoWindow: InfoWindow(
        title: S.of(context).dropoffLabel,
        snippet: snippet,
      ),
    );
  }

  @override
  void initState() {
    super.initState();
    _currentPosition = _birminghamDefault;
    _cameraTarget = _birminghamDefault;
    _pickupAddress = 'Birmingham, AL';
    _pickupCtrl.text = _pickupAddress;
    _pickupMarker = _pickupMapMarker(_birminghamDefault);
    _pickupFocus.addListener(_handleAddressFocusChange);
    _dropoffFocus.addListener(_handleAddressFocusChange);
    _glowController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..addListener(_onGlowTick);
    _riderDriverAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    )..addListener(_onRiderDriverAnimTick);
    _loadPinIcons();
    _buildDriverCarIcon();
    _initLocation();
    _applyStartupIntent();
    _loadLinkedPayments();
    _loadPromoState();
    // Start with plan body visible since we begin at plan stage
    Future.delayed(const Duration(milliseconds: 40), () {
      if (mounted && _stage == RideStage.plan) {
        setState(() => _planBodyVisible = true);
      }
    });
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
    _goldPinIconBytes = await _buildGoldPinBytes(isPickup: true);
    _goldPinIcon = BitmapDescriptor.bytes(_goldPinIconBytes!);
    _dropoffPinIconBytes = await _buildGoldPinBytes(
      withHouse: true,
      isPickup: false,
    );
    _dropoffPinIcon = BitmapDescriptor.bytes(_dropoffPinIconBytes!);
    if (!mounted) return;
    setState(() {
      _pickupMarker = _pickupMapMarker(
        _pickupMarker?.position ?? _birminghamDefault,
        snippet: _pickupAddress,
      );
      if (_dropoffMarker != null) {
        _dropoffMarker = _dropoffMapMarker(
          _dropoffMarker!.position,
          snippet: _dropoffAddress,
        );
      }
    });
  }

  Future<void> _applyStartupIntent() async {
    if (widget.preSelectedRideIndex != null) {
      _preSelectedRideIndex = widget.preSelectedRideIndex;
      _selectedRide = widget.preSelectedRideIndex!.clamp(0, _rides.length - 1);
    }
    final initialDropoff = widget.initialDropoffQuery?.trim() ?? '';
    if (!widget.openPlanOnStart && initialDropoff.isEmpty) return;

    await Future.delayed(const Duration(milliseconds: 280));
    if (!mounted) return;

    await _openWhereTo();
    if (!mounted) return;

    if (initialDropoff.isNotEmpty) {
      _dropoffCtrl.text = initialDropoff;
      await _onDropoffSubmitted(initialDropoff);
    }
  }

  @override
  void dispose() {
    _liveLocationTimer?.cancel();
    _livePositionSub?.cancel();
    _searchDebounce?.cancel();
    _cameraIdleDebounce?.cancel();
    _rideLifecycleTimer?.cancel();
    _tripPollTimer?.cancel();
    _riderDriverAnim?.removeListener(_onRiderDriverAnimTick);
    _riderDriverAnim?.dispose();
    _glowController?.removeListener(_onGlowTick);
    _glowController?.dispose();
    _pickupFocus.removeListener(_handleAddressFocusChange);
    _dropoffFocus.removeListener(_handleAddressFocusChange);
    _pickupCtrl.dispose();
    _dropoffCtrl.dispose();
    _pickupFocus.dispose();
    _dropoffFocus.dispose();
    super.dispose();
  }

  void _handleAddressFocusChange() {
    if (!mounted || _stage != RideStage.plan) return;
    final focused = _pickupFocus.hasFocus || _dropoffFocus.hasFocus;
    if (_isAddressFieldFocused == focused) return;
    setState(() {
      _isAddressFieldFocused = focused;
      _panelDragHeight = focused ? _panelMaxHeight(context) : null;
      _isPanelDragging = false;
    });

    if (!focused) {
      Future.microtask(() async {
        await _maybeAutoRouteFromInputs();
      });
    }
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

    if (_pickupMarker == null) {
      await _syncPickupFromInputIfNeeded();
      if (!mounted) return;
    }

    final sameDropoffText =
        _dropoffAddress.trim().toLowerCase() == dropoffText.toLowerCase();
    if (_dropoffMarker == null || !sameDropoffText) {
      await _onDropoffSubmitted(dropoffText);
      return;
    }

    if (_pickupMarker != null && _dropoffMarker != null) {
      await _autoAdvanceToOptions();
    }
  }

  int _durationTextToMinutes(String value) {
    final lower = value.toLowerCase();
    final hoursMatch = RegExp(
      r'(\d+)\s*(h|hr|hrs|hour|hours)',
    ).firstMatch(lower);
    final minsMatches = RegExp(
      r'(\d+)\s*(m|min|mins|minute|minutes)',
    ).allMatches(lower).toList();

    var minutes = 0;
    if (hoursMatch != null) {
      minutes += (int.tryParse(hoursMatch.group(1) ?? '') ?? 0) * 60;
    }

    if (minsMatches.isNotEmpty) {
      final mins = int.tryParse(minsMatches.first.group(1) ?? '') ?? 0;
      minutes += mins;
    } else {
      final numberMatch = RegExp(r'(\d+)').firstMatch(lower);
      if (numberMatch != null) {
        minutes += int.tryParse(numberMatch.group(1) ?? '') ?? 0;
      }
    }

    return minutes.clamp(1, 300);
  }

  String _priceFromMinutes(int minutes, {double multiplier = 1.0}) {
    final hourlyTarget = 120.0;
    var computed = (minutes / 60.0) * hourlyTarget * multiplier;
    // Apply promo discount if active
    if (_promoActive && _promoDiscountPercent > 0) {
      computed = computed * (1 - _promoDiscountPercent / 100.0);
    }
    final rounded = (computed * 100).roundToDouble() / 100;
    return '\$${rounded.toStringAsFixed(2)}';
  }

  void _updateRidePricingFromDuration(String durationText) {
    final baseMinutes = _durationTextToMinutes(durationText);
    final vipMinutes = (baseMinutes * 0.85).ceil().clamp(1, 300);
    final premiumMinutes = baseMinutes;
    final comfortMin = (baseMinutes * 1.10).ceil().clamp(1, 300);
    final comfortMax = (baseMinutes * 1.45).ceil().clamp(comfortMin, 300);

    final vipEta = '$vipMinutes min';
    final premiumEta = '$premiumMinutes min';
    final comfortEta = '$comfortMin-$comfortMax min';

    _rides = [
      RideOption(
        name: 'VIP',
        vehicle: 'Suburban',
        price: _priceFromMinutes(vipMinutes, multiplier: 2.2),
        eta: vipEta,
        promoted: true,
      ),
      RideOption(
        name: 'Premium',
        vehicle: 'Camry',
        price: _priceFromMinutes(premiumMinutes, multiplier: 1.35),
        eta: premiumEta,
      ),
      RideOption(
        name: 'Comfort',
        vehicle: 'Fusion',
        price: _priceFromMinutes(comfortMax, multiplier: 0.92),
        eta: comfortEta,
      ),
    ];
    if (_selectedRide >= _rides.length) {
      _selectedRide = 0;
    }
  }

  Future<void> _initLocation() async {
    if (mounted) {
      setState(() {
        _isResolvingLocation = true;
      });
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

  Position _pickBetterPosition(Position? current, Position candidate) {
    if (current == null) return candidate;
    return candidate.accuracy < current.accuracy ? candidate : current;
  }

  bool _isPositionReliable(Position position) {
    final age = DateTime.now().difference(position.timestamp);
    final freshEnough = age.inMinutes <= 3;
    final preciseEnough = position.accuracy <= 35;
    return freshEnough && preciseEnough;
  }

  void _startLiveLocationUpdates() {
    _liveLocationTimer?.cancel();
    _livePositionSub?.cancel();

    // Use real-time GPS position stream for instant blue-dot tracking
    _livePositionSub =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 1, // update every 1 meter for ultra-smooth tracking
          ),
        ).listen((position) {
          if (!mounted) return;

          final live = LatLng(position.latitude, position.longitude);
          // Always keep _currentPosition fresh for blue dot
          _currentPosition = live;

          if (_hasPreparedRoute && _dropoffMarker != null) return;
          // Skip pickup marker updates during active ride stages
          if (_stage == RideStage.confirmPickup ||
              _stage == RideStage.payment ||
              _stage == RideStage.matching ||
              _stage == RideStage.riding) {
            return;
          }

          final currentPickup = _pickupMarker?.position;
          if (currentPickup != null) {
            final movedMeters = Geolocator.distanceBetween(
              currentPickup.latitude,
              currentPickup.longitude,
              live.latitude,
              live.longitude,
            );
            if (movedMeters < 3) return;
          }

          if (_stage != RideStage.pin && _stage != RideStage.plan) return;

          setState(() {
            _cameraTarget = live;
            _pickupMarker = _pickupMapMarker(live, snippet: _pickupAddress);
            _tripMiles = '-- mi';
            _tripDuration = '-- min';
            _polylines = {};
            _hasPreparedRoute = false;
          });

          _centerMapOn(live, zoom: _defaultMapZoom);

          final lastAddressTarget = _lastLiveAddressTarget;
          if (lastAddressTarget != null) {
            final addressMoved = Geolocator.distanceBetween(
              lastAddressTarget.latitude,
              lastAddressTarget.longitude,
              live.latitude,
              live.longitude,
            );
            if (addressMoved < 20) return;
          }

          _lastLiveAddressTarget = live;
          _refreshPickupAddress(live);
        });
  }

  void _setDefaultBirminghamPickup() {
    _setInitialPickup(_birminghamDefault, 'Birmingham, AL');
  }

  void _setInitialPickup(LatLng latLng, String initialAddress) {
    if (!mounted) return;

    setState(() {
      _currentPosition = latLng;
      _cameraTarget = latLng;
      _pickupMarker = _pickupMapMarker(latLng, snippet: initialAddress);
      _pickupAddress = initialAddress;
      _pickupCtrl.text = initialAddress;
    });
  }

  void _onCameraMove(CameraPosition position) {
    _cameraTarget = position.target;
    // Any manual gesture resets the zoom toggle so next tap centers first.
    if (!_isRecentering) _isCenteredOnPickup = false;
  }

  void _onCameraIdle() {
    if (_isResolvingLocation) return;
    if (_stage == RideStage.confirmPickup) {
      _isRecentering = false;
      return; // pickup is a real marker now, not screen-center
    }
    if (_stage != RideStage.pin) return;
    if (_hasPreparedRoute && _dropoffMarker != null) return;
    final target = _cameraTarget;
    if (target == null) return;

    _cameraIdleDebounce?.cancel();
    _cameraIdleDebounce = Timer(const Duration(milliseconds: 150), () async {
      if (!mounted || _stage != RideStage.pin) return;

      final last = _lastReverseGeocodedTarget;
      if (last != null) {
        final movedMeters = Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          target.latitude,
          target.longitude,
        );
        if (movedMeters < 25) {
          return;
        }
      }

      if (_pickupMarker != null) {
        final markerDistance = Geolocator.distanceBetween(
          _pickupMarker!.position.latitude,
          _pickupMarker!.position.longitude,
          target.latitude,
          target.longitude,
        );
        if (markerDistance < 2) {
          return;
        }
      }

      setState(() {
        _pickupMarker = _pickupMapMarker(target, snippet: _pickupAddress);
        _tripMiles = '-- mi';
        _tripDuration = '-- min';
        _polylines = {};
        _hasPreparedRoute = false;
      });

      final requestTicket = ++_reverseGeocodeTicket;
      try {
        final address = await _places.reverseGeocode(
          lat: target.latitude,
          lng: target.longitude,
        );
        if (!mounted || requestTicket != _reverseGeocodeTicket) return;
        final resolved = (address == null || address.isEmpty)
            ? _coordinatesLabel(target)
            : address;
        _lastReverseGeocodedTarget = target;
        setState(() {
          _pickupAddress = resolved;
          _pickupCtrl.text = resolved;
          _pickupMarker = _pickupMapMarker(target, snippet: resolved);
        });
      } catch (_) {
        if (!mounted || requestTicket != _reverseGeocodeTicket) return;
        final fallback = _coordinatesLabel(target);
        setState(() {
          _pickupAddress = fallback;
          _pickupCtrl.text = fallback;
          _pickupMarker = _pickupMapMarker(target, snippet: fallback);
        });
      }
    });
  }

  void _onMapTap(LatLng latLng) async {
    // When user taps map during plan stage, set that location as dropoff
    if (_stage != RideStage.plan) return;

    setState(() {
      _dropoffCtrl.text = S.of(context).loadingAddress;
      _dropoffMarker = _dropoffMapMarker(
        latLng,
        snippet: S.of(context).loadingAddress,
      );
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
        _dropoffMarker = _dropoffMapMarker(latLng, snippet: resolved);
      });
    } catch (_) {
      if (!mounted) return;
      final fallback = _coordinatesLabel(latLng);
      setState(() {
        _dropoffAddress = fallback;
        _dropoffCtrl.text = fallback;
        _dropoffMarker = _dropoffMapMarker(latLng, snippet: fallback);
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
        _pickupMarker = _pickupMapMarker(latLng, snippet: resolved);
      });
    } catch (_) {
      if (!mounted) return;
      final fallback = _coordinatesLabel(latLng);
      setState(() {
        _pickupAddress = fallback;
        _pickupCtrl.text = fallback;
        _pickupMarker = _pickupMapMarker(latLng, snippet: fallback);
      });
    }
  }

  String _coordinatesLabel(LatLng point) {
    return '${point.latitude.toStringAsFixed(6)}, ${point.longitude.toStringAsFixed(6)}';
  }

  Future<void> _openWhereTo() async {
    _setStage(RideStage.plan);
    setState(() {
      _suggestions = [];
      _searchError = null;
    });
    await Future.delayed(const Duration(milliseconds: 60));
    if (mounted) _dropoffFocus.requestFocus();
  }

  void _onMapCreated(GoogleMapController controller) {
    _mapController = controller;
    if (_currentPosition != null) {
      _centerMapOn(_currentPosition!, zoom: _defaultMapZoom);
    }
  }

  // ── Platform-aware camera helpers ─────────────────────────────────────

  /// Pan the camera to [target] with optional zoom/bearing/tilt.
  /// Works for both Google Maps (Android) and Apple Maps (iOS).
  Future<void> _panTo(
    LatLng target, {
    double? zoom,
    double bearing = 0,
    double tilt = 0,
  }) async {
    final z = zoom ?? await _currentZoom();
    await _mapController?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: target, zoom: z, bearing: bearing, tilt: tilt),
      ),
    );
  }

  /// Fit the camera to [bounds] with [padding] (pixels) on all sides.
  Future<void> _fitBounds(LatLngBounds bounds, double padding) async {
    await _mapController?.animateCamera(
      CameraUpdate.newLatLngBounds(bounds, padding),
    );
  }

  /// Returns the current map zoom level on whichever platform is active.
  Future<double> _currentZoom() async {
    try {
      return await _mapController?.getZoomLevel() ?? _defaultMapZoom;
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

  Future<void> _centerMapOn(LatLng target, {double zoom = 15.5}) async {
    if (!_hasMapController) return;
    await _smoothCameraTransition(target, zoom);
  }

  /// Smooth multi-step camera transition that glides between zoom levels.
  /// For large zoom deltas, performs an intermediate step so the animation
  /// doesn't "jump" — mimicking the fluid feel of premium ride-hailing apps.
  Future<void> _smoothCameraTransition(LatLng target, double targetZoom) async {
    if (!_hasMapController) return;
    final currentZoom = await _currentZoom();
    final zoomDelta = (targetZoom - currentZoom).abs();

    if (zoomDelta > 4.0) {
      // Large zoom change â†’ 2-step glide via midpoint zoom
      final midZoom = currentZoom + (targetZoom - currentZoom) * 0.5;
      await _panTo(target, zoom: midZoom);
      await Future.delayed(const Duration(milliseconds: 120));
      await _panTo(target, zoom: targetZoom);
    } else {
      // Normal zoom change â†’ single smooth animation
      await _panTo(target, zoom: targetZoom);
    }
  }

  /// Always centers on the pickup location.
  /// 1st tap â†’ center on pickup at default zoom.
  /// 2nd tap â†’ zoom IN close to pickup (street-level).
  /// Never moves or resets the pickup marker.
  Future<void> _recenterToMyLocation() async {
    if (!_hasMapController) return;
    final pickup = _pickupMarker?.position ?? _currentPosition;
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

  void _onAddressChanged(String value, {required bool pickup}) {
    _searchDebounce?.cancel();
    final query = value.trim();
    if (query.isEmpty) {
      setState(() {
        _isSearching = false;
        _searchError = null;
        _suggestions = [];
      });
      return;
    }

    final debounceMs = kIsWeb ? 250 : 200;
    _searchDebounce = Timer(Duration(milliseconds: debounceMs), () async {
      if (!mounted) return;
      setState(() {
        _isSearching = true;
        _searchingPickup = pickup;
        _searchError = null;
      });

      try {
        final origin = _pickupMarker?.position;
        final raw = await _places.autocomplete(
          query,
          latitude: origin?.latitude,
          longitude: origin?.longitude,
        );
        final topSuggestions = raw.take(25).toList();
        final enriched = !pickup
            ? await _enrichSuggestionsWithDistance(topSuggestions)
            : topSuggestions;
        if (!mounted) return;

        setState(() {
          _isSearching = false;
          _suggestions = enriched;
        });
      } catch (error) {
        if (!mounted) return;
        try {
          final origin = _pickupMarker?.position;
          final exact = await _places.geocodeAddress(
            query,
            latitude: origin?.latitude,
            longitude: origin?.longitude,
          );
          if (!mounted) return;
          if (exact != null) {
            setState(() {
              _isSearching = false;
              _searchError = null;
              _suggestions = [
                PlaceSuggestion(
                  description: exact.address,
                  placeId: 'exact:${exact.lat},${exact.lng}',
                  lat: exact.lat,
                  lng: exact.lng,
                ),
              ];
            });
            return;
          }
        } catch (_) {}

        setState(() {
          _isSearching = false;
          _suggestions = [];
          _searchError = null;
        });
      }
    });
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
      final origin = _pickupMarker?.position;
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
    if (normalizedInput == normalizedCurrent && _pickupMarker != null) return;

    final bias = _pickupMarker?.position;
    try {
      final exactPickup = await _places.geocodeAddress(
        input,
        latitude: bias?.latitude,
        longitude: bias?.longitude,
      );
      if (!mounted || exactPickup == null) return;

      final position = LatLng(exactPickup.lat, exactPickup.lng);
      setState(() {
        _pickupMarker = _pickupMapMarker(
          position,
          snippet: exactPickup.address,
        );
        _pickupAddress = exactPickup.address.isEmpty
            ? input
            : exactPickup.address;
        _pickupCtrl.text = _pickupAddress;
        _hasPreparedRoute = false;
      });
    } catch (_) {}
  }

  Future<List<PlaceSuggestion>> _enrichSuggestionsWithDistance(
    List<PlaceSuggestion> input,
  ) async {
    final origin = _pickupMarker?.position;
    if (origin == null) return input;

    // Fast path: compute straight-line distance for items that already have coords
    // Skip expensive details() + matrix API calls — use haversine estimate instead
    final enriched = input.map((item) {
      if (item.lat != null && item.lng != null) {
        final meters = Geolocator.distanceBetween(
          origin.latitude,
          origin.longitude,
          item.lat!,
          item.lng!,
        );
        final miles = meters / 1609.344;
        final etaMinutes = ((miles / 25.0) * 60).ceil(); // ~25mph avg estimate
        return item.copyWith(distanceMiles: miles, etaText: '$etaMinutes min');
      }
      return item;
    }).toList();

    return enriched;
  }

  String _etaFromMiles(double? miles) {
    if (miles == null) return '-- min';
    final minutes = ((miles / 22.0) * 60).ceil();
    return '$minutes min';
  }

  Future<void> _selectSuggestion(
    PlaceSuggestion suggestion, {
    required bool pickup,
  }) async {
    // Immediately dismiss suggestions for snappy feel
    setState(() {
      _suggestions = [];
      _searchError = null;
      _isSearching = false;
      // Show the suggestion description immediately as preview
      if (pickup) {
        _pickupCtrl.text = suggestion.description;
      } else {
        _dropoffCtrl.text = suggestion.description;
      }
    });

    PlaceDetails? details;
    if (suggestion.lat != null && suggestion.lng != null) {
      details = PlaceDetails(
        address: suggestion.description,
        lat: suggestion.lat!,
        lng: suggestion.lng!,
      );
    }
    details ??= await _places.details(suggestion.placeId);
    if (details == null || !mounted) return;

    if (!_isValidCoordinate(details.lat, details.lng)) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).invalidCoordinatesError),
          duration: const Duration(milliseconds: 1600),
        ),
      );
      return;
    }

    // Use formatted_address from Google (precise street address like Shopify widget)
    String resolvedAddress = details.address.trim();
    if (resolvedAddress.isEmpty) {
      // Fall back to reverse geocode to get precise address
      try {
        final reverse = await _places.reverseGeocode(
          lat: details.lat,
          lng: details.lng,
        );
        if (reverse != null && reverse.trim().isNotEmpty) {
          resolvedAddress = reverse.trim();
        }
      } catch (_) {}
    }
    if (resolvedAddress.isEmpty) {
      resolvedAddress = suggestion.description.trim();
    }

    final marker = pickup
        ? _pickupMapMarker(
            LatLng(details.lat, details.lng),
            snippet: resolvedAddress,
          )
        : _dropoffMapMarker(
            LatLng(details.lat, details.lng),
            snippet: resolvedAddress,
          );

    setState(() {
      if (pickup) {
        _pickupMarker = marker;
        _pickupAddress = resolvedAddress;
        _pickupCtrl.text = resolvedAddress;
      } else {
        _dropoffMarker = marker;
        _dropoffAddress = resolvedAddress;
        _dropoffCtrl.text = resolvedAddress;
      }
      _hasPreparedRoute = false;
    });

    await _animateCameraToSelection(marker.position);

    if (_pickupMarker != null && _dropoffMarker != null) {
      if (_stage == RideStage.plan) {
        await _autoAdvanceToOptions();
      } else {
        await _prepareRoutePreview();
      }
    } else {
      if (!mounted) return;
      setState(() {
        _tripMiles = '-- mi';
        _tripDuration = '-- min';
        _polylines = {};
      });
    }
  }

  bool _isValidCoordinate(double lat, double lng) {
    if (lat.isNaN || lng.isNaN) return false;
    if (!lat.isFinite || !lng.isFinite) return false;
    if (lat < -90 || lat > 90) return false;
    if (lng < -180 || lng > 180) return false;
    return true;
  }

  Future<void> _autoAdvanceToOptions() async {
    if (_autoProgressingToOptions) return;
    if (_pickupMarker == null || _dropoffMarker == null) return;

    _autoProgressingToOptions = true;
    try {
      if (mounted) {
        FocusScope.of(context).unfocus();
        setState(() {
          _isAddressFieldFocused = false;
          _panelDragHeight = null;
        });
      }

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

  Future<bool> _prepareRoutePreview({bool returnToPin = true}) async {
    if (_pickupMarker == null || _dropoffMarker == null) return false;

    final animationTicket = ++_routeAnimationTicket;

    final origin = _pickupMarker!.position;
    final destination = _dropoffMarker!.position;
    final route = await _directions.getRoute(
      origin: origin,
      destination: destination,
    );

    if (!mounted) return false;

    if (route != null) {
      _activeRoutePoints = route.points;
      setState(() {
        _tripMiles = _formatMiles(route.distanceMeters);
        _tripDuration = route.durationText;
        _updateRidePricingFromDuration(_tripDuration);
        if (_pickupAddress.isEmpty) _pickupAddress = route.startAddress;
        _dropoffAddress = route.endAddress.isEmpty
            ? _dropoffAddress
            : route.endAddress;
        _dropoffCtrl.text = _dropoffAddress;
        _hasPreparedRoute = true;
        _polylines = {};
      });

      await _animateRoutePolyline(route.points, animationTicket);
    } else {
      _activeRoutePoints = [];
      DistanceEstimate? estimate;
      try {
        final matrix = await _directions.getDistanceEstimates(
          origin: origin,
          destinations: [destination],
        );
        final key =
            '${destination.latitude.toStringAsFixed(6)},${destination.longitude.toStringAsFixed(6)}';
        estimate = matrix[key];
      } catch (_) {}

      if (!mounted) return false;
      setState(() {
        _tripMiles = estimate == null
            ? '-- mi'
            : '${estimate.miles.toStringAsFixed(2)} mi';
        _tripDuration = estimate?.durationText ?? '-- min';
        _updateRidePricingFromDuration(_tripDuration);
        _hasPreparedRoute = false;
        _polylines = {};
      });

      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(
          content: Text(S.of(context).routeNotFoundError),
          duration: const Duration(milliseconds: 1800),
        ),
      );
      return false;
    }

    await _fitMapToRoute();

    if (!mounted) return false;
    FocusScope.of(context).unfocus();
    if (returnToPin) {
      _setStage(RideStage.plan);
    }
    return true;
  }

  String _formatMiles(int meters) {
    final miles = meters / 1609.344;
    return '${miles.toStringAsFixed(2)} mi';
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

    if (_pickupMarker == null) {
      final current = _currentPosition;
      if (current != null) {
        setState(() {
          _pickupMarker = _pickupMapMarker(current);
        });
      }
    }

    if (_dropoffMarker == null &&
        _suggestions.isNotEmpty &&
        !_searchingPickup) {
      await _selectSuggestion(_suggestions.first, pickup: false);
    }

    if (_dropoffMarker == null && _dropoffCtrl.text.trim().isNotEmpty) {
      await _onDropoffSubmitted(_dropoffCtrl.text);
    }

    if (_pickupMarker == null || _dropoffMarker == null) {
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

    await Future.delayed(const Duration(milliseconds: 250));
    if (!mounted) return;
    _setStage(RideStage.options);
  }

  void _showTripCancelledDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        icon: const Icon(
          Icons.cancel_outlined,
          color: Color(0xFFFF453A),
          size: 48,
        ),
        title: Text(
          S.of(context).tripCancelled,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          S.of(context).tripCancelledByOperator,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 15,
            height: 1.4,
          ),
        ),
        actionsAlignment: MainAxisAlignment.center,
        actions: [
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFE8C547),
                foregroundColor: Colors.black,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
                padding: const EdgeInsets.symmetric(vertical: 14),
              ),
              child: Text(
                S.of(context).okButton,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 16,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _setStage(RideStage stage) {
    setState(() {
      _stage = stage;
      _panelDragHeight = null;
      _isPanelDragging = false;
      if (stage == RideStage.options) {
        _optionsExpanded = true;
      }
      if (stage != RideStage.plan) {
        _planBodyVisible = false;
      }
      // Rebuild pickup marker so draggable flag matches current stage
      final pos = _pickupMarker?.position;
      if (pos != null) {
        _pickupMarker = _pickupMapMarker(pos, snippet: _pickupAddress);
      }
    });

    if (stage == RideStage.plan) {
      Future.delayed(const Duration(milliseconds: 40), () {
        if (!mounted || _stage != RideStage.plan) return;
        setState(() {
          _planBodyVisible = true;
        });
      });
    }

    // Start/stop glow animation based on stage
    if (stage == RideStage.options ||
        stage == RideStage.confirmPickup ||
        stage == RideStage.payment ||
        stage == RideStage.matching ||
        stage == RideStage.riding) {
      _startRouteGlowAnimation();
    } else {
      _stopRouteGlowAnimation();
    }

    WidgetsBinding.instance.addPostFrameCallback((_) async {
      if (!mounted) return;
      // Small delay so panel animation settles before camera moves
      await Future.delayed(const Duration(milliseconds: 80));
      if (!mounted) return;
      // Only fit map when route is visible and it's a stage that should show the full route
      if (_pickupMarker != null &&
          _dropoffMarker != null &&
          (stage == RideStage.options ||
              stage == RideStage.matching ||
              stage == RideStage.riding ||
              stage == RideStage.payment)) {
        if (stage == RideStage.matching) {
          // Moderate overview: center on midpoint so user sees the distance
          // without the map being too zoomed-in or fully fitted.
          _isCenteredOnPickup =
              false; // first compass tap will center on pickup
          final p = _pickupMarker!.position;
          final d = _dropoffMarker!.position;
          final mid = LatLng(
            (p.latitude + d.latitude) / 2,
            (p.longitude + d.longitude) / 2,
          );
          // Pick a zoom that keeps both points roughly visible
          final latSpan = (p.latitude - d.latitude).abs();
          final lngSpan = (p.longitude - d.longitude).abs();
          final maxSpan = math.max(latSpan, lngSpan);
          // log2(180/span) gives a rough zoom for the span; pull back 0.6
          final zoom = maxSpan > 0
              ? ((math.log(180.0 / maxSpan) / math.ln2) - 0.6).clamp(10.0, 14.5)
              : 13.0;
          await _centerMapOn(mid, zoom: zoom);
        } else {
          await _fitMapToRoute();
        }
      }
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

  Widget _rideTimeOption({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            Icon(icon, color: _c.iconDefault, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      color: _c.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle,
                    style: TextStyle(color: _c.iconDefault, fontSize: 13),
                  ),
                ],
              ),
            ),
            Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: _c.textSecondary, width: 2),
                color: selected ? _c.textPrimary : Colors.transparent,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sheetButton({
    required String label,
    required VoidCallback onPressed,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        style: ElevatedButton.styleFrom(
          backgroundColor: _c.mapSurface,
          foregroundColor: _c.textPrimary,
          side: BorderSide(color: _c.textSecondary, width: 1.2),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(14),
          ),
          padding: const EdgeInsets.symmetric(vertical: 13),
        ),
        onPressed: onPressed,
        child: Text(
          label,
          style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
        ),
      ),
    );
  }

  Future<void> _fitMapToRoute() async {
    if (!_hasMapController || _pickupMarker == null || _dropoffMarker == null) {
      return;
    }

    final origin = _pickupMarker!.position;
    final destination = _dropoffMarker!.position;

    final points = <LatLng>[origin, destination];
    for (final polyline in _polylines) {
      points.addAll(polyline.points);
    }

    final bounds = _boundsFromPoints(points);

    try {
      // The GoogleMap widget already has padding from _mapPaddingForContext
      // that accounts for the top bar and bottom panel.
      // So newLatLngBounds with a small extra padding will center the route
      // perfectly in the visible area between the UI elements.
      await _fitBounds(bounds, 50);

      // Wait for animation to settle, then clamp zoom
      await Future.delayed(const Duration(milliseconds: 250));
      if (!mounted || !_hasMapController) return;

      final currentZoom = await _currentZoom();
      // Min 12.0 (not too zoomed out), Max 15.5 (keeps context)
      final clampedZoom = currentZoom.clamp(12.0, 15.5);
      if ((clampedZoom - currentZoom).abs() > 0.2) {
        // Need to adjust zoom — recenter with clamped zoom
        final midLat =
            (bounds.northeast.latitude + bounds.southwest.latitude) / 2;
        final midLng =
            (bounds.northeast.longitude + bounds.southwest.longitude) / 2;
        await _panTo(LatLng(midLat, midLng), zoom: clampedZoom);
      }
    } catch (_) {
      final center = LatLng(
        (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
        (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
      );
      await _panTo(center, zoom: 13.0);
      await _applyRouteVerticalBias(bounds);
    }
  }

  Future<void> _applyRouteVerticalBias(LatLngBounds bounds) async {
    if (!_hasMapController) return;

    final latSpan = (bounds.northeast.latitude - bounds.southwest.latitude)
        .abs();
    if (latSpan <= 0) return;

    final shiftFactor = _routeVerticalShiftFactor();
    if (shiftFactor <= 0) return;

    final center = LatLng(
      (bounds.southwest.latitude + bounds.northeast.latitude) / 2,
      (bounds.southwest.longitude + bounds.northeast.longitude) / 2,
    );

    final shiftedLat = center.latitude + (latSpan * shiftFactor);
    final boundedLat = shiftedLat.clamp(
      _usBounds.southwest.latitude,
      _usBounds.northeast.latitude,
    );

    final zoom = await _currentZoom().catchError((_) => 13.8);
    await _panTo(LatLng(boundedLat, center.longitude), zoom: zoom);
  }

  double _routeVerticalShiftFactor() {
    switch (_stage) {
      case RideStage.options:
        return 0.16;
      case RideStage.loading:
        return 0.14;
      case RideStage.confirmPickup:
        return 0.12;
      case RideStage.payment:
        return 0.14;
      case RideStage.matching:
        return 0.15;
      case RideStage.riding:
        return 0.15;
      case RideStage.plan:
        return 0.1;
      case RideStage.pin:
        return 0.0;
    }
  }

  LatLngBounds _boundsFromPoints(List<LatLng> points) {
    if (points.isEmpty) {
      return LatLngBounds(
        southwest: _birminghamDefault,
        northeast: _birminghamDefault,
      );
    }

    var minLat = points.first.latitude;
    var maxLat = points.first.latitude;
    var minLng = points.first.longitude;
    var maxLng = points.first.longitude;

    for (final point in points.skip(1)) {
      if (point.latitude < minLat) minLat = point.latitude;
      if (point.latitude > maxLat) maxLat = point.latitude;
      if (point.longitude < minLng) minLng = point.longitude;
      if (point.longitude > maxLng) maxLng = point.longitude;
    }

    const minSpan = 0.0008;
    if ((maxLat - minLat).abs() < minSpan) {
      final adjust = (minSpan - (maxLat - minLat).abs()) / 2;
      minLat -= adjust;
      maxLat += adjust;
    }
    if ((maxLng - minLng).abs() < minSpan) {
      final adjust = (minSpan - (maxLng - minLng).abs()) / 2;
      minLng -= adjust;
      maxLng += adjust;
    }

    return LatLngBounds(
      southwest: LatLng(minLat, minLng),
      northeast: LatLng(maxLat, maxLng),
    );
  }

  Future<void> _animateCameraToSelection(LatLng target) async {
    if (!_hasMapController) return;
    await _smoothCameraTransition(target, 16.4);
  }

  Future<void> _animateRoutePolyline(List<LatLng> points, int ticket) async {
    if (!mounted || points.isEmpty) return;

    // For short routes, just show immediately
    if (points.length < 6) {
      if (!mounted || ticket != _routeAnimationTicket) return;
      setState(() {
        _polylines = _buildRoutePolylines(points);
      });
      return;
    }

    // Smooth 5-frame progressive draw for elegant route appearance
    const frames = 5;
    final chunk = (points.length / frames).ceil();
    for (var index = chunk; index <= points.length; index += chunk) {
      if (!mounted || ticket != _routeAnimationTicket) return;
      final currentPoints = points.take(index).toList();
      final newPolylines = _buildRoutePolylines(currentPoints);
      setState(() {
        _polylines = newPolylines;
      });
      await Future.delayed(const Duration(milliseconds: 20));
    }

    if (!mounted || ticket != _routeAnimationTicket) return;
    final finalPolylines = _buildRoutePolylines(points);
    setState(() {
      _polylines = finalPolylines;
    });
  }

  // Route line color: always gold for brand consistency
  Color get _routeColor => const Color(0xFFE8C547);

  Set<Polyline> _buildRoutePolylines(List<LatLng> points) {
    final baseColor = _routeColor;
    // Animated glow: oscillate alpha between 0.5 and 1.0 using sin wave
    final sinVal = math.sin(_routeGlowPhase);
    final glowAlpha = 0.5 + 0.5 * sinVal.abs();
    final glowColor = baseColor.withValues(alpha: glowAlpha);
    return {
      // Outer glow layer
      Polyline(
        polylineId: const PolylineId('ride_route_glow'),
        points: points,
        color: baseColor.withValues(alpha: 0.14),
        width: 8,
        zIndex: 0,
        jointType: JointType.round,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
      ),
      // Base shadow
      Polyline(
        polylineId: const PolylineId('ride_route_base'),
        points: points,
        color: _c.isDark
            ? _panelBlack.withValues(alpha: 0.35)
            : Colors.black.withValues(alpha: 0.10),
        width: 4,
        zIndex: 1,
        jointType: JointType.round,
      ),
      // Main line with animated glow
      Polyline(
        polylineId: const PolylineId('ride_route'),
        points: points,
        color: glowColor,
        width: 4,
        zIndex: 2,
        startCap: Cap.roundCap,
        endCap: Cap.roundCap,
        jointType: JointType.round,
      ),
    };
  }

  int _glowFrameSkip = 0;

  void _onGlowTick() {
    if (!mounted || _activeRoutePoints.isEmpty) return;
    // Only rebuild polylines every 5th frame (~12 fps) to reduce jank
    _glowFrameSkip++;
    if (_glowFrameSkip < 5) return;
    _glowFrameSkip = 0;
    _routeGlowPhase = (_glowController!.value) * math.pi * 2;
    final newPolylines = _buildRoutePolylines(_activeRoutePoints);
    setState(() {
      _polylines = newPolylines;
    });
  }

  void _startRouteGlowAnimation() {
    _glowController?.repeat();
  }

  void _stopRouteGlowAnimation() {
    _glowController?.stop();
    _glowController?.reset();
  }

  @override
  Widget build(BuildContext context) {
    _c = AppColors.of(context);

    // When the theme flips between light â†” dark, re-apply the map JSON style
    if (_lastIsDark != null &&
        _lastIsDark != _c.isDark &&
        _mapController != null) {
      final style = _mapStyle;
      // ignore: deprecated_member_use
      _mapController!.setMapStyle(style);
    }
    _lastIsDark = _c.isDark;

    return Scaffold(
      resizeToAvoidBottomInset: false,
      backgroundColor: _bgBlack,
      body: Stack(
        children: [
          RepaintBoundary(
            child: GoogleMap(
              style: _mapStyle,
              onMapCreated: _onMapCreated,
              onCameraMove: _onCameraMove,
              onCameraIdle: _onCameraIdle,
              onTap: _onMapTap,
              initialCameraPosition: CameraPosition(
                target: _currentPosition!,
                zoom: 14,
              ),
              cameraTargetBounds: CameraTargetBounds(_usBounds),
              padding: _mapPaddingForContext(context),
              myLocationEnabled: true,
              myLocationButtonEnabled: false,
              zoomControlsEnabled: false,
              zoomGesturesEnabled: true,
              rotateGesturesEnabled: true,
              scrollGesturesEnabled: true,
              tiltGesturesEnabled: false,
              compassEnabled: true,
              mapToolbarEnabled: false,
              buildingsEnabled: false,
              liteModeEnabled: false,
              markers: {
                if (_pickupMarker != null && _tripStatus != 'in_trip')
                  _pickupMarker!,
                if (_dropoffMarker != null) _dropoffMarker!,
                if (_driverMarker != null) _driverMarker!,
              },
              polylines: _polylines,
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

          Positioned(top: 48, left: 14, child: _backButton()),
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
              left: 74,
              right: 16,
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
              left: 60,
              right: 16,
              child: _buildRiderNavHeader(),
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
              onVerticalDragEnd: (_) {
                _handlePanelDragEnd(context);
              },
              child: ClipRRect(
                borderRadius: BorderRadius.circular(26),
                child: AnimatedContainer(
                  duration: _panelDurationForStage(),
                  curve: Curves.easeInOutCubicEmphasized,
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
                        child: SlideTransition(
                          position:
                              Tween<Offset>(
                                begin: const Offset(0, 0.015),
                                end: Offset.zero,
                              ).animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutCubic,
                                ),
                              ),
                          child: child,
                        ),
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

  Duration _panelDurationForStage() {
    if (_isPanelDragging) {
      return Duration.zero;
    }

    switch (_stage) {
      case RideStage.pin:
        return const Duration(milliseconds: 320);
      case RideStage.plan:
        return const Duration(milliseconds: 380);
      case RideStage.loading:
      case RideStage.options:
      case RideStage.confirmPickup:
      case RideStage.payment:
      case RideStage.matching:
      case RideStage.riding:
        return const Duration(milliseconds: 340);
    }
  }

  void _handlePanelDragEnd(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final draggedHeight = _panelDragHeight ?? _panelHeightForStage(context);

    if (_stage == RideStage.pin) {
      final openThreshold = screenHeight * 0.40;
      if (draggedHeight >= openThreshold) {
        _setStage(RideStage.plan);
        return;
      }
    }

    if (_stage == RideStage.plan) {
      final collapseThreshold = screenHeight * 0.33;
      if (draggedHeight <= collapseThreshold) {
        Navigator.of(context).maybePop();
        return;
      }
    }

    if (_stage == RideStage.options) {
      final bottomInset = MediaQuery.of(context).padding.bottom;
      final expandedH = (442 + bottomInset).clamp(390.0, screenHeight * 0.62);
      final collapsedH = (270 + bottomInset).clamp(240.0, screenHeight * 0.45);
      final midpoint = (expandedH + collapsedH) / 2;
      setState(() {
        _optionsExpanded = draggedHeight >= midpoint;
        _isPanelDragging = false;
        _panelDragHeight = null;
      });
      return;
    }

    setState(() {
      _isPanelDragging = false;
      _panelDragHeight = null;
    });
  }

  double _currentPanelHeight(BuildContext context) {
    if (_stage == RideStage.plan &&
        (_isAddressFieldFocused || _suggestions.isNotEmpty || _isSearching)) {
      return _panelMaxHeight(context);
    }
    final minH = _panelMinHeight(context);
    final maxH = math.max(minH, _panelMaxHeight(context));
    return (_panelDragHeight ?? _panelHeightForStage(context)).clamp(
      minH,
      maxH,
    );
  }

  double _panelMinHeight(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    if (_stage == RideStage.pin) {
      return 228 + bottomInset;
    }
    if (_stage == RideStage.plan) {
      if (_isAddressFieldFocused) {
        final maxH = _panelMaxHeight(context);
        final minH = math.min(420.0, maxH);
        return (MediaQuery.of(context).size.height * 0.82).clamp(minH, maxH);
      }
      return 310 + bottomInset;
    }
    if (_stage == RideStage.options) {
      return 240 + bottomInset;
    }
    if (_stage == RideStage.confirmPickup) {
      return 270 + bottomInset;
    }
    if (_stage == RideStage.payment) {
      return 360 + bottomInset;
    }
    if (_stage == RideStage.matching || _stage == RideStage.riding) {
      return 300 + bottomInset;
    }
    return 170 + bottomInset;
  }

  double _panelMaxHeight(BuildContext context) {
    final screenHeight = MediaQuery.of(context).size.height;
    final topPadding = MediaQuery.of(context).padding.top;
    return (screenHeight - topPadding - 14).clamp(260, screenHeight * 0.95);
  }

  double _panelHeightForStage(BuildContext context) {
    final bottomInset = MediaQuery.of(context).padding.bottom;
    final screenHeight = MediaQuery.of(context).size.height;
    // Helper: safe clamp that guards against max < min on small screens.
    double safeClamp(double value, double minVal, double maxFraction) {
      final maxVal = math.max(minVal, screenHeight * maxFraction);
      return value.clamp(minVal, maxVal).toDouble();
    }

    switch (_stage) {
      case RideStage.pin:
        return 214 + bottomInset;
      case RideStage.plan:
        return safeClamp(320 + bottomInset, 290.0, 0.46);
      case RideStage.loading:
        return safeClamp(340 + bottomInset, 310.0, 0.46);
      case RideStage.options:
        if (_optionsExpanded) {
          return safeClamp(442 + bottomInset, 390.0, 0.62);
        } else {
          return safeClamp(270 + bottomInset, 240.0, 0.45);
        }
      case RideStage.confirmPickup:
        return safeClamp(340 + bottomInset, 300.0, 0.50);
      case RideStage.payment:
        final promoExtra = _promoActive ? 44.0 : 0.0;
        final payH =
            (_linkedPaymentMethods.contains(_selectedPaymentMethod)
                ? 440
                : 480) +
            promoExtra;
        return safeClamp(payH + bottomInset, 400.0, 0.72);
      case RideStage.matching:
        return safeClamp(360 + bottomInset, 320.0, 0.56);
      case RideStage.riding:
        return safeClamp(310 + bottomInset, 280.0, 0.50);
    }
  }

  Widget _buildPanel() {
    final panel = switch (_stage) {
      RideStage.pin => _pinPanel(),
      RideStage.plan => _planPanel(),
      RideStage.loading => _loadingPanel(),
      RideStage.options => _optionsPanel(),
      RideStage.confirmPickup => _confirmPickupPanel(),
      RideStage.payment => _paymentPanel(),
      RideStage.matching => _matchingPanel(),
      RideStage.riding => _ridingPanel(),
    };
    return RepaintBoundary(child: panel);
  }

  Widget _pinPanel() {
    return Container(
      height: double.infinity,
      key: const ValueKey('pin'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _handle(),
            const SizedBox(height: 12),
            Text(
              S.of(context).planYourDestination,
              style: TextStyle(
                color: _c.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 30,
              ),
            ),
            Text(
              S.of(context).moveMapChooseDestination,
              style: TextStyle(color: _c.textTertiary, fontSize: 14),
            ),
            const SizedBox(height: 12),
            InkWell(
              onTap: _openWhereTo,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 13,
                ),
                decoration: BoxDecoration(
                  color: _softBlack,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: _gold.withValues(alpha: 0.45),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(Icons.crop_square, color: _gold, size: 18),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        S.of(context).whereToQuestion,
                        style: TextStyle(
                          color: _c.textPrimary,
                          fontSize: 21,
                          fontWeight: FontWeight.w600,
                          shadows: _thinWhiteOutline,
                        ),
                      ),
                    ),
                    Icon(Icons.search, color: _gold),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _planPanel() {
    return Container(
      height: double.infinity,
      key: const ValueKey('plan'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: AnimatedSlide(
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOutCubic,
          offset: _planBodyVisible ? Offset.zero : const Offset(0, 0.04),
          child: AnimatedOpacity(
            duration: const Duration(milliseconds: 280),
            curve: Curves.easeOut,
            opacity: _planBodyVisible ? 1 : 0,
            child: Column(
              mainAxisSize: MainAxisSize.max,
              children: [
                _handle(),
                const SizedBox(height: 8),
                Text(
                  S.of(context).planYourRide,
                  style: TextStyle(
                    color: _c.textPrimary,
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    _Badge(
                      icon: _pickupNow
                          ? Icons.watch_later_outlined
                          : Icons.calendar_today_outlined,
                      text: _rideTimeBadgeText,
                      onTap: _showRideTimeSheet,
                    ),
                    const SizedBox(width: 8),
                    _Badge(
                      icon: Icons.person_outline,
                      text: S.of(context).forMe,
                    ),
                    const SizedBox(width: 8),
                    _Badge(
                      icon: _airportSelection != null
                          ? Icons.flight_rounded
                          : Icons.flight_outlined,
                      text: _airportSelection != null
                          ? _airportSelection!.airport.code
                          : S.of(context).airportLabel,
                      onTap: _showAirportSheet,
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                _addressBox(),
                const SizedBox(height: 6),
                Expanded(child: _suggestionsView()),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _addressBox() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: _gold, width: 1.1),
      ),
      child: Column(
        children: [
          _addressInput(
            controller: _pickupCtrl,
            focusNode: _pickupFocus,
            icon: Icons.radio_button_checked,
            hint: S.of(context).pickupHint,
            textInputAction: TextInputAction.next,
            onChanged: (value) => _onAddressChanged(value, pickup: true),
            onSubmitted: (_) => _dropoffFocus.requestFocus(),
            onClear: () => _clearAddressInput(pickup: true),
          ),
          Divider(height: 1, color: _c.border),
          _addressInput(
            controller: _dropoffCtrl,
            focusNode: _dropoffFocus,
            icon: Icons.crop_square,
            hint: S.of(context).whereToQuestion,
            textInputAction: TextInputAction.done,
            onChanged: (value) => _onAddressChanged(value, pickup: false),
            onSubmitted: _onDropoffSubmitted,
            onClear: () => _clearAddressInput(pickup: false),
          ),
        ],
      ),
    );
  }

  void _clearAddressInput({required bool pickup}) {
    _searchDebounce?.cancel();

    setState(() {
      if (pickup) {
        _pickupCtrl.clear();
      } else {
        _dropoffCtrl.clear();
        _dropoffAddress = '';
        _dropoffMarker = null;
        _tripMiles = '-- mi';
        _tripDuration = '-- min';
        _polylines = {};
      }

      _suggestions = [];
      _searchError = null;
      _isSearching = false;
      _hasPreparedRoute = false;
    });
  }

  Widget _suggestionsView() {
    if (_isSearching) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 18),
        child: CircularProgressIndicator(color: _gold, strokeWidth: 2),
      );
    }

    if (_searchError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 10),
        child: Text(
          S.of(context).addressResultsError,
          style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
        ),
      );
    }

    if (_suggestions.isEmpty) {
      return const SizedBox.shrink();
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      cacheExtent: 400,
      itemCount: _suggestions.length,
      separatorBuilder: (_, index) => Divider(height: 1, color: _c.divider),
      itemBuilder: (context, index) {
        final s = _suggestions[index];
        final hasCoords = s.lat != null && s.lng != null;
        final isLocal =
            s.placeId.startsWith('exact:') ||
            s.placeId.startsWith('osm:') ||
            s.placeId.startsWith('photon:');
        final isGoogle = !isLocal && !hasCoords;

        // Choose icon based on result type
        IconData icon;
        if (isLocal) {
          icon = Icons.location_on;
        } else if (isGoogle) {
          icon = Icons.place;
        } else {
          icon = Icons.place_outlined;
        }

        // Build subtitle
        String? subtitle;
        if (!_searchingPickup &&
            _pickupMarker != null &&
            s.distanceMiles != null) {
          final miles = '${s.distanceMiles!.toStringAsFixed(1)} mi';
          final eta = s.etaText ?? _etaFromMiles(s.distanceMiles);
          subtitle = '$eta · $miles';
        }

        return ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          leading: Icon(
            icon,
            color: isLocal ? _gold : _c.textTertiary,
            size: 18,
          ),
          title: Text(
            s.description,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: _c.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
          subtitle: subtitle != null
              ? Text(
                  subtitle,
                  style: TextStyle(color: _c.textTertiary, fontSize: 12),
                )
              : null,
          onTap: () => _selectSuggestion(s, pickup: _searchingPickup),
        );
      },
    );
  }

  Widget _loadingPanel() {
    return Container(
      key: const ValueKey('loading'),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _handle(),
            const SizedBox(height: 10),
            Text(
              S.of(context).gatheringOptions,
              style: TextStyle(
                color: _c.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 32,
              ),
            ),
            const SizedBox(height: 8),
            LinearProgressIndicator(
              minHeight: 3,
              color: _gold,
              backgroundColor: _c.border,
              borderRadius: BorderRadius.circular(99),
            ),
            const SizedBox(height: 14),
            ...List.generate(
              3,
              (index) => Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    Container(width: 48, height: 24, decoration: _skeleton),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            width: 130,
                            height: 10,
                            decoration: _skeleton,
                          ),
                          const SizedBox(height: 8),
                          Container(
                            width: 94,
                            height: 10,
                            decoration: _skeletonLight,
                          ),
                        ],
                      ),
                    ),
                    Container(width: 60, height: 10, decoration: _skeleton),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _optionsPanel() {
    return Container(
      height: double.infinity,
      key: const ValueKey('options'),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 10),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.max,
          children: [
            _handle(),
            GestureDetector(
              onTap: () => setState(() {
                _optionsExpanded = !_optionsExpanded;
                _panelDragHeight = null;
              }),
              child: AnimatedRotation(
                turns: _optionsExpanded ? 0.0 : 0.5,
                duration: const Duration(milliseconds: 250),
                child: Icon(
                  Icons.keyboard_arrow_up,
                  color: _c.textTertiary,
                  size: 20,
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.local_offer, color: _gold, size: 15),
                SizedBox(width: 6),
                Text(
                  _promoActive
                      ? S.of(context).discountApplied(_promoDiscountPercent)
                      : S.of(context).selectYourRide,
                  style: TextStyle(
                    color: _promoActive ? _gold : _c.textSecondary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.route, color: _c.iconDefault, size: 15),
                const SizedBox(width: 6),
                Text(
                  '$_tripMiles · $_tripDuration',
                  style: TextStyle(color: _c.textSecondary, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Flexible(
              fit: FlexFit.loose,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 320),
                curve: Curves.easeInOutCubicEmphasized,
                alignment: Alignment.topCenter,
                child: ListView.builder(
                  padding: EdgeInsets.zero,
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  itemCount: _optionsExpanded ? _rides.length : 1,
                  itemBuilder: (context, i) {
                    final ride = _rides[i];
                    final selected = i == _selectedRide;
                    return InkWell(
                      onTap: () => setState(() => _selectedRide = i),
                      borderRadius: BorderRadius.circular(14),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOutCubic,
                        margin: const EdgeInsets.only(bottom: 7),
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: selected ? _c.surface : Colors.transparent,
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: selected ? _gold : _c.border,
                          ),
                        ),
                        child: Row(
                          children: [
                            SizedBox(
                              width: 80,
                              height: 48,
                              child: DecoratedBox(
                                decoration: BoxDecoration(
                                  gradient: _c.isDark
                                      ? RadialGradient(
                                          colors: [
                                            Colors.white.withValues(
                                              alpha: 0.12,
                                            ),
                                            Colors.white.withValues(
                                              alpha: 0.04,
                                            ),
                                            Colors.transparent,
                                          ],
                                          stops: const [0.0, 0.55, 1.0],
                                          radius: 0.8,
                                        )
                                      : null,
                                ),
                                child: Image.asset(
                                  'assets/images/${ride.vehicle.toLowerCase()}.png',
                                  fit: BoxFit.contain,
                                  filterQuality: FilterQuality.high,
                                  errorBuilder: (ctx, err, st) => Center(
                                    child: Text(
                                      ride.vehicle,
                                      style: TextStyle(
                                        color: _c.textSecondary,
                                        fontSize: 9,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        ride.name,
                                        style: TextStyle(
                                          color: _c.textPrimary,
                                          fontWeight: FontWeight.w700,
                                          fontSize: 18,
                                        ),
                                      ),
                                      if (ride.promoted) ...[
                                        const SizedBox(width: 6),
                                        Container(
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 6,
                                            vertical: 1,
                                          ),
                                          decoration: BoxDecoration(
                                            color: _gold.withValues(alpha: 0.2),
                                            borderRadius: BorderRadius.circular(
                                              20,
                                            ),
                                          ),
                                          child: Text(
                                            S.of(context).fasterTag,
                                            style: const TextStyle(
                                              color: _gold,
                                              fontSize: 10,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  Text(
                                    ride.eta,
                                    style: TextStyle(
                                      color: _c.textSecondary,
                                      fontSize: 14,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              ride.price,
                              style: TextStyle(
                                color: _c.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 21,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
            const SizedBox(height: 5),
            Row(
              children: [
                Expanded(
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _c.mapSurface,
                      foregroundColor: _c.textPrimary,
                      side: BorderSide(color: _c.textSecondary, width: 1.2),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                      padding: const EdgeInsets.symmetric(vertical: 13),
                    ),
                    onPressed: _beginRideRequestFromOptions,
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        S.of(context).chooseRide(_rides[_selectedRide].name),
                        maxLines: 1,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 18,
                          shadows: _thinWhiteOutline,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: _showRideTimeSheet,
                  child: Container(
                    width: 52,
                    height: 48,
                    decoration: BoxDecoration(
                      color: _softBlack,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Icon(Icons.calendar_month, color: _c.textPrimary),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _addressInput({
    required TextEditingController controller,
    required FocusNode focusNode,
    required IconData icon,
    required String hint,
    required ValueChanged<String> onChanged,
    TextInputAction textInputAction = TextInputAction.done,
    ValueChanged<String>? onSubmitted,
    required VoidCallback onClear,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          Icon(
            icon,
            color: icon == Icons.crop_square ? _gold : _c.iconDefault,
            size: 16,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: controller,
              focusNode: focusNode,
              onChanged: onChanged,
              onSubmitted: onSubmitted,
              textInputAction: textInputAction,
              style: TextStyle(
                color: _c.textPrimary,
                fontWeight: FontWeight.w600,
                fontSize: 18,
              ),
              decoration: InputDecoration(
                border: InputBorder.none,
                hintText: hint,
                hintStyle: TextStyle(color: _c.textTertiary),
              ),
            ),
          ),
          InkWell(
            onTap: onClear,
            borderRadius: BorderRadius.circular(30),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(
                Icons.cancel_outlined,
                color: _c.textTertiary,
                size: 16,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _backButton() {
    return GestureDetector(
      onTap: () async {
        if (_stage == RideStage.riding || _stage == RideStage.matching) {
          final confirm = await showDialog<bool>(
            context: context,
            builder: (ctx) => AlertDialog(
              backgroundColor: _c.mapSurface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              title: Text(
                _stage == RideStage.riding
                    ? S.of(context).cancelRide
                    : S.of(context).stopSearchingQuestion,
                style: TextStyle(
                  color: _c.textPrimary,
                  fontWeight: FontWeight.w800,
                ),
              ),
              content: Text(
                _stage == RideStage.riding
                    ? S.of(context).cancelRideConfirmation
                    : S.of(context).stopSearchingConfirmation,
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
          _rideLifecycleTimer?.cancel();
          _tripPollTimer?.cancel();
          setState(() {
            _driverMarker = null;
            _rideProgress = 0;
          });
          Navigator.of(context).maybePop();
          return;
        }
        if (_stage == RideStage.payment) {
          _setStage(RideStage.confirmPickup);
          return;
        }
        if (_stage == RideStage.confirmPickup) {
          _setStage(RideStage.options);
          return;
        }
        if (_stage == RideStage.options) {
          _setStage(RideStage.plan);
          return;
        }
        if (_stage == RideStage.plan || _stage == RideStage.loading) {
          Navigator.of(context).maybePop();
          return;
        }
        Navigator.of(context).maybePop();
      },
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF2A2A2A),
          shape: BoxShape.circle,
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 8,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Icon(Icons.arrow_back, color: _c.textPrimary, size: 20),
      ),
    );
  }

  BoxDecoration get _panelDecoration => BoxDecoration(
    color: _c.mapSurface,
    borderRadius: const BorderRadius.all(Radius.circular(26)),
    border: Border.fromBorderSide(BorderSide(color: _c.border, width: 1)),
  );

  BoxDecoration get _skeleton => BoxDecoration(
    color: _c.iconMuted,
    borderRadius: const BorderRadius.all(Radius.circular(8)),
  );

  BoxDecoration get _skeletonLight => BoxDecoration(
    color: _c.divider,
    borderRadius: const BorderRadius.all(Radius.circular(8)),
  );

  Widget _handle() => Container(
    width: 44,
    height: 5,
    decoration: BoxDecoration(
      color: _c.iconMuted,
      borderRadius: BorderRadius.circular(40),
    ),
  );

  Future<void> _beginRideRequestFromOptions() async {
    if (!mounted) return;
    _rideLifecycleTimer?.cancel();
    _tripPollTimer?.cancel();

    setState(() {
      _driverName = 'Searching...';
      _driverCar = '';
      _driverPlate = '';
      _driverEta = '...';
      _rideProgress = 0;
      _driverMarker = null;
      _driverNote = '';
      _currentTripId = null;
    });

    _setStage(RideStage.confirmPickup);

    // Rebuild pickup marker as draggable for this stage
    final pos = _pickupMarker?.position ?? _currentPosition;
    if (pos != null) {
      setState(() {
        _pickupMarker = _pickupMapMarker(pos, snippet: _pickupAddress);
      });
    }

    // Zoom into current location for precise pickup selection
    _isRecentering = true;
    final myPos = _currentPosition ?? _pickupMarker?.position;
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
        final pickupPos = _pickupMarker?.position ?? _currentPosition;
        final dropoffPos = _dropoffMarker?.position;

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
            terminal: _airportSelection?.terminal,
            pickupZone: _airportSelection?.pickupZone,
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
                'Failed to schedule ride: $e',
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
    await LocalDataService.addNotification(
      title: S.of(context).searchingDriverTitle,
      message: S.of(context).searchingDriverMessage(_rides[_selectedRide].name),
      type: 'ride',
    );

    // â”€â”€ Write to Firestore so Dispatch Admin sees the trip in real time â”€â”€
    try {
      final session = await UserSession.getUser();
      final pickupPos = _pickupMarker?.position ?? _currentPosition;
      final dropoffPos = _dropoffMarker?.position;
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
      final pickupPos = _pickupMarker?.position ?? _currentPosition;
      final dropoffPos = _dropoffMarker?.position;

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
          terminal: _airportSelection?.terminal,
          pickupZone: _airportSelection?.pickupZone,
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
    _tripPollTimer = Timer.periodic(const Duration(seconds: 3), (timer) async {
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
              _driverRating =
                  (dispatch['driver_rating'] as num?)?.toDouble() ?? 4.9;
              // Calculate real initial ETA from driver distance
              if (_driverPosition != null) {
                final pickupPos = _pickupMarker?.position ?? _currentPosition;
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

            _updateDriverMarkerFromPosition();
            _startRideProgressTracking();
            return;
          } else if (status == 'canceled' || status == 'cancelled') {
            timer.cancel();
            if (!mounted) return;
            _rideLifecycleTimer?.cancel();
            setState(() {
              _rideProgress = 0;
              _polylines = {};
              _activeRoutePoints = [];
              _driverRoutePoints = [];
              _driverMarker = null;
              _dropoffMarker = null;
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

  void _startRideProgressTracking() {
    var tripStartedNotified = false;
    var arrivedNotified = false;
    var fsSyncedArrived = false;
    var fsSyncedInTrip = false;
    _rideLifecycleTimer?.cancel();
    _rideLifecycleTimer = Timer.periodic(const Duration(milliseconds: 750), (
      timer,
    ) async {
      if (!mounted || _stage != RideStage.riding) {
        timer.cancel();
        return;
      }

      // Poll real status + driver position from backend
      if (_currentTripId != null) {
        try {
          final trip = await ApiService.getTrip(_currentTripId!);
          final status = trip['status']?.toString() ?? '';

          // Extract real driver GPS position
          final dLat = (trip['driver_lat'] as num?)?.toDouble();
          final dLng = (trip['driver_lng'] as num?)?.toDouble();
          if (dLat != null && dLng != null) {
            final newPos = LatLng(dLat, dLng);
            // Only animate if driver actually moved (>2m)
            final moved = _driverPosition != null
                ? Geolocator.distanceBetween(
                    _driverPosition!.latitude,
                    _driverPosition!.longitude,
                    newPos.latitude,
                    newPos.longitude,
                  )
                : 999.0;
            if (moved > 2) {
              _animateDriverTo(newPos);
            }
          }

          if (status == 'completed') {
            timer.cancel();
            // â”€â”€ Sync completed to Firestore for Dispatch Admin â”€â”€
            if (_firestoreTripId != null) {
              TripFirestoreService.syncTripCompleted(_firestoreTripId!);
            }
            await LocalDataService.addNotification(
              title: S.of(context).tripCompletedTitle,
              message: S.of(context).arrivedAtDestination,
              type: 'ride',
            );
            // â”€â”€ Show payment confirmation â”€â”€
            if (mounted) {
              final payStatus = trip['payment_status']?.toString() ?? 'unpaid';
              final fare = (trip['fare'] as num?)?.toDouble() ?? 0.0;
              final fareStr = fare > 0 ? '\$${fare.toStringAsFixed(2)}' : '';
              String payMsg;
              Color payColor;
              if (payStatus == 'paid') {
                payMsg = fareStr.isNotEmpty
                    ? '✓ Payment of $fareStr processed'
                    : '✓ Payment processed';
                payColor = const Color(0xFF4CAF50);
              } else if (payStatus == 'failed') {
                payMsg = 'Payment could not be processed. Please update your payment method.';
                payColor = const Color(0xFFF44336);
              } else {
                payMsg = fareStr.isNotEmpty ? 'Trip fare: $fareStr' : 'Trip completed';
                payColor = const Color(0xFFE8C547);
              }
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(payMsg, style: const TextStyle(fontWeight: FontWeight.w600)),
                  backgroundColor: payColor,
                  duration: const Duration(seconds: 5),
                ),
              );
            }
            _completeRide();
            return;
          } else if (status == 'in_trip') {
            if (!tripStartedNotified) {
              tripStartedNotified = true;
              // â”€â”€ Sync in_progress to Firestore for Dispatch Admin â”€â”€
              if (_firestoreTripId != null && !fsSyncedInTrip) {
                fsSyncedInTrip = true;
                TripFirestoreService.syncTripStarted(_firestoreTripId!);
              }
              LocalDataService.addNotification(
                title: S.of(context).tripStartedTitle,
                message: S.of(context).headingToDestination(_dropoffAddress),
                type: 'ride',
              );
            }
            final dropoffPos = _dropoffMarker?.position;
            if (mounted) {
              // Calculate progress based on driver distance to dropoff
              double progress = 0;
              if (dropoffPos != null && _driverPosition != null) {
                final pickupPos = _pickupMarker?.position;
                if (pickupPos != null) {
                  final totalDist = Geolocator.distanceBetween(
                    pickupPos.latitude,
                    pickupPos.longitude,
                    dropoffPos.latitude,
                    dropoffPos.longitude,
                  );
                  final remaining = Geolocator.distanceBetween(
                    _driverPosition!.latitude,
                    _driverPosition!.longitude,
                    dropoffPos.latitude,
                    dropoffPos.longitude,
                  );
                  progress = totalDist > 0
                      ? (1.0 - remaining / totalDist).clamp(0.0, 1.0)
                      : 0.0;
                }
                // Calculate real ETA
                final distKm =
                    Geolocator.distanceBetween(
                      _driverPosition!.latitude,
                      _driverPosition!.longitude,
                      dropoffPos.latitude,
                      dropoffPos.longitude,
                    ) /
                    1000;
                final etaMin = (distKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);
                setState(() {
                  _tripStatus = 'in_trip';
                  _rideProgress = progress;
                  _driverEta = '$etaMin min';
                });
              } else {
                setState(() => _tripStatus = 'in_trip');
              }
            }
            // 3D Chase-cam follows driver every frame via _onRiderDriverAnimTick
            // Only set fallback camera here if animation is not running
            if (_driverPosition != null &&
                mounted &&
                !(_riderDriverAnim?.isAnimating ?? false)) {
              // Calculate bearing from driver to dropoff
              double tripBearing = _driverBearing;
              if (tripBearing == 0 && dropoffPos != null) {
                final dLng =
                    (dropoffPos.longitude - _driverPosition!.longitude) *
                    math.pi /
                    180;
                final aLat = _driverPosition!.latitude * math.pi / 180;
                final bLat = dropoffPos.latitude * math.pi / 180;
                final x = math.sin(dLng) * math.cos(bLat);
                final y =
                    math.cos(aLat) * math.sin(bLat) -
                    math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
                tripBearing = (math.atan2(x, y) * 180 / math.pi + 360) % 360;
              }
              _panTo(
                _driverPosition!,
                zoom: 18.5,
                bearing: tripBearing,
                tilt: 45,
              );
            }
            // Draw/update route from driver â†’ dropoff
            await _updateDriverRoute(status);
          } else if (status == 'arrived') {
            if (!arrivedNotified) {
              arrivedNotified = true;
              // â”€â”€ Sync driver_arrived to Firestore for Dispatch Admin â”€â”€
              if (_firestoreTripId != null && !fsSyncedArrived) {
                fsSyncedArrived = true;
                TripFirestoreService.syncDriverArrived(_firestoreTripId!);
              }
              LocalDataService.addNotification(
                title: S.of(context).driverArrivedTitle,
                message: S.of(context).driverArrivedMessage(_driverName),
                type: 'ride',
              );
            }
            if (mounted) {
              setState(() {
                _driverEta = 'Arrived';
                _tripStatus = 'arrived';
              });
            }
            await _updateDriverRoute(status);
          } else if (status == 'driver_en_route' ||
              status == 'driver_assigned') {
            final pickupPos = _pickupMarker?.position;
            if (mounted) {
              // Calculate ETA to pickup
              if (pickupPos != null && _driverPosition != null) {
                final distKm =
                    Geolocator.distanceBetween(
                      _driverPosition!.latitude,
                      _driverPosition!.longitude,
                      pickupPos.latitude,
                      pickupPos.longitude,
                    ) /
                    1000;
                final etaMin = (distKm * 1000 / 17.88 / 60).ceil().clamp(1, 99);
                setState(() {
                  _tripStatus = status;
                  _driverEta = '$etaMin min';
                });
              } else {
                setState(() => _tripStatus = status);
              }
            }
            // 3D Chase-cam follows driver on map during en route
            if (_driverPosition != null &&
                mounted &&
                !(_riderDriverAnim?.isAnimating ?? false)) {
              // Calculate bearing from driver to pickup
              double pickupBearing = _driverBearing;
              if (pickupBearing == 0 && pickupPos != null) {
                final dLng =
                    (pickupPos.longitude - _driverPosition!.longitude) *
                    math.pi /
                    180;
                final aLat = _driverPosition!.latitude * math.pi / 180;
                final bLat = pickupPos.latitude * math.pi / 180;
                final x = math.sin(dLng) * math.cos(bLat);
                final y =
                    math.cos(aLat) * math.sin(bLat) -
                    math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
                pickupBearing = (math.atan2(x, y) * 180 / math.pi + 360) % 360;
              }
              _panTo(
                _driverPosition!,
                zoom: 18.5,
                bearing: pickupBearing,
                tilt: 45,
              );
            }
            // Draw/update route from driver â†’ pickup
            await _updateDriverRoute(status);
          } else if (status == 'canceled' || status == 'cancelled') {
            timer.cancel();
            _rideLifecycleTimer?.cancel();
            final reason =
                (trip['cancel_reason'] ??
                        trip['cancellation_reason'] ??
                        trip['reason'] ??
                        '')
                    .toString()
                    .toLowerCase();
            final isNoDrivers =
                reason.contains('no_driver') ||
                reason.contains('no driver') ||
                reason.contains('timeout') ||
                reason.contains('expired') ||
                reason.isEmpty;
            if (_firestoreTripId != null) {
              TripFirestoreService.syncTripCancelled(
                _firestoreTripId!,
                reason: isNoDrivers
                    ? 'No drivers available'
                    : 'Cancelled by dispatch',
              );
            }
            if (mounted) {
              setState(() {
                _rideProgress = 0;
                _polylines = {};
                _activeRoutePoints = [];
                _driverRoutePoints = [];
                _driverMarker = null;
                _dropoffMarker = null;
              });
              if (isNoDrivers) {
                _setStage(RideStage.options);
              } else {
                _setStage(RideStage.plan);
                _showTripCancelledDialog();
              }
            }
            return;
          }
          _updateDriverMarkerFromPosition();
        } catch (e) {
          debugPrint('âš ï¸ Ride tracking: $e');
        }
      }
    });
  }

  /// Trim the rider-side route behind the driver marker (Google Maps style)
  void _trimRiderRoute(LatLng driverPos) {
    if (_driverRoutePoints.length < 3) return;
    int closestIdx = 0;
    double closestDist = double.infinity;
    for (int i = 0; i < _driverRoutePoints.length; i++) {
      final d = Geolocator.distanceBetween(
        driverPos.latitude,
        driverPos.longitude,
        _driverRoutePoints[i].latitude,
        _driverRoutePoints[i].longitude,
      );
      if (d < closestDist) {
        closestDist = d;
        closestIdx = i;
      }
    }
    if (closestIdx > 0) {
      _driverRoutePoints = _driverRoutePoints.sublist(closestIdx);
    }
    if (_driverRoutePoints.isNotEmpty) {
      _driverRoutePoints[0] = driverPos;
    }
    // Rebuild polylines with trimmed points
    final isInTrip = _lastDriverRoutePhase == 'in_trip';
    final color = isInTrip ? const Color(0xFFE8C547) : Colors.greenAccent;
    final id = isInTrip ? 'driver_to_dropoff' : 'driver_to_pickup';
    setState(() {
      // Keep existing pickupâ†’dropoff polyline if en_route, just update driver polyline
      _polylines.removeWhere(
        (p) => p.polylineId.value.startsWith('driver_to_'),
      );
      _polylines.addAll({
        Polyline(
          polylineId: PolylineId('${id}_glow'),
          points: List.from(_driverRoutePoints),
          color: color.withValues(alpha: 0.15),
          width: 12,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
        Polyline(
          polylineId: PolylineId(id),
          points: List.from(_driverRoutePoints),
          color: color,
          width: 5,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      });
    });
  }

  /// Draw the real driving route from driver to destination on the rider's map.
  /// During driver_en_route/driver_assigned: driver â†’ pickup + pickup â†’ dropoff
  /// During in_trip: driver â†’ dropoff
  Future<void> _updateDriverRoute(String status) async {
    if (!mounted || _driverPosition == null) return;

    final pickupPos = _pickupMarker?.position ?? _currentPosition;
    final dropoffPos = _dropoffMarker?.position;
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

      final Set<Polyline> polys = {};
      if (driverToPickup.isNotEmpty) {
        _driverRoutePoints = driverToPickup;
        polys.addAll({
          Polyline(
            polylineId: const PolylineId('driver_to_pickup_glow'),
            points: driverToPickup,
            color: Colors.greenAccent.withValues(alpha: 0.15),
            width: 12,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
          Polyline(
            polylineId: const PolylineId('driver_to_pickup'),
            points: driverToPickup,
            color: Colors.greenAccent,
            width: 4,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
        });
      }
      if (pickupToDropoff.isNotEmpty) {
        polys.addAll({
          Polyline(
            polylineId: const PolylineId('pickup_to_dropoff_glow'),
            points: pickupToDropoff,
            color: const Color(0xFFE8C547).withValues(alpha: 0.15),
            width: 12,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
          Polyline(
            polylineId: const PolylineId('pickup_to_dropoff'),
            points: pickupToDropoff,
            color: const Color(0xFFE8C547),
            width: 4,
            startCap: Cap.roundCap,
            endCap: Cap.roundCap,
          ),
        });
      }
      setState(() => _polylines = polys);

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
        _driverRoutePoints = driverToDropoff;
        setState(() {
          _polylines = {
            Polyline(
              polylineId: const PolylineId('driver_to_dropoff_glow'),
              points: driverToDropoff,
              color: const Color(0xFFE8C547).withValues(alpha: 0.15),
              width: 12,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
            ),
            Polyline(
              polylineId: const PolylineId('driver_to_dropoff'),
              points: driverToDropoff,
              color: const Color(0xFFE8C547),
              width: 4,
              startCap: Cap.roundCap,
              endCap: Cap.roundCap,
            ),
          };
        });
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

    // Last resort: straight line
    return List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        origin.latitude + (dest.latitude - origin.latitude) * t,
        origin.longitude + (dest.longitude - origin.longitude) * t,
      );
    });
  }

  /// Decode an encoded polyline string into a list of LatLng points.
  List<LatLng> _decodePolyline(String enc) {
    final pts = <LatLng>[];
    int i = 0, lat = 0, lng = 0;
    while (i < enc.length) {
      int s = 0, r = 0, b;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lat += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      s = 0;
      r = 0;
      do {
        b = enc.codeUnitAt(i++) - 63;
        r |= (b & 0x1F) << s;
        s += 5;
      } while (b >= 0x20);
      lng += (r & 1) != 0 ? ~(r >> 1) : (r >> 1);
      pts.add(LatLng(lat / 1E5, lng / 1E5));
    }
    return pts;
  }

  /// Fit the map to show all the given points with padding.
  void _fitRideBounds(List<LatLng> points) {
    if (points.isEmpty || !_hasMapController) return;
    double minLat = points.first.latitude, maxLat = minLat;
    double minLng = points.first.longitude, maxLng = minLng;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    const minSpan = 0.004;
    if ((maxLat - minLat) < minSpan) {
      final adj = (minSpan - (maxLat - minLat)) / 2;
      minLat -= adj;
      maxLat += adj;
    }
    if ((maxLng - minLng) < minSpan) {
      final adj = (minSpan - (maxLng - minLng)) / 2;
      minLng -= adj;
      maxLng += adj;
    }
    _fitBounds(
      LatLngBounds(
        southwest: LatLng(minLat - 0.003, minLng - 0.003),
        northeast: LatLng(maxLat + 0.003, maxLng + 0.003),
      ),
      80,
    );
  }

  Future<void> _completeRide() async {
    if (!mounted) return;
    _riderDriverAnim?.reset();

    final completedRide = _rides[_selectedRide];
    final completedTrip = TripHistoryItem(
      pickup: _pickupAddress,
      dropoff: _dropoffAddress,
      rideName: completedRide.name,
      price: completedRide.price,
      miles: _tripMiles,
      duration: _tripDuration,
      createdAt: DateTime.now(),
    );
    await LocalDataService.addTrip(completedTrip);
    await LocalDataService.addNotification(
      title: S.of(context).tripCompletedTitle,
      message: '${S.of(context).arrivedAtDestination} (${completedRide.name})',
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
      _polylines = {};
      _activeRoutePoints = [];
      _driverRoutePoints = [];
      _driverPosition = null;
      _currentDriverId = null;
      _lastDriverRoutePhase = '';
      _driverMarker = null;
      _dropoffMarker = null;
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

  void _updateDriverMarkerFromPosition({bool force = false}) {
    if (!mounted || _driverPosition == null) return;

    // Calculate bearing from previous position
    if (_prevDriverPosition != null) {
      _driverBearing = _calcBearing(_prevDriverPosition!, _driverPosition!);
    }

    // Throttle marker rebuild to ~10 Hz — balances smooth motion vs flicker.
    final now = DateTime.now();
    if (!force &&
        _lastDriverMarkerRebuild != null &&
        now.difference(_lastDriverMarkerRebuild!).inMilliseconds < 100) {
      return;
    }
    _lastDriverMarkerRebuild = now;

    _driverMarker = Marker(
      markerId: const MarkerId('driver'),
      position: _driverPosition!,
      icon:
          _driverCarIcon ??
          BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueAzure),
      rotation: _driverBearing,
      anchor: const Offset(0.5, 0.5),
      flat: true,
      zIndexInt: 100,
      infoWindow: InfoWindow(title: _driverName, snippet: _driverCar),
    );
    setState(() {});
  }

  double _calcBearing(LatLng a, LatLng b) {
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final aLat = a.latitude * math.pi / 180;
    final bLat = b.latitude * math.pi / 180;
    final x = math.sin(dLng) * math.cos(bLat);
    final y =
        math.cos(aLat) * math.sin(bLat) -
        math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
    return (math.atan2(x, y) * 180 / math.pi + 360) % 360;
  }

  /// Smooth heading interpolation (avoids 360→0 jumps)
  double _lerpAngle(double from, double to, double t) {
    double diff = (to - from) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return (from + diff * t) % 360;
  }

  /// Smoothly animate driver position using AnimationController (60fps)
  void _animateDriverTo(LatLng newPos) {
    final from = _driverPosition ?? newPos;
    _riderAnimFrom = from;
    _riderAnimTo = newPos;
    _prevDriverPosition = from;

    // Calculate smooth bearing toward new position
    final rawBearing = _calcBearing(from, newPos);
    _riderTargetBearing = rawBearing;

    // Start 60fps animation
    _riderDriverAnim?.forward(from: 0.0);
  }

  /// Called on every vsync frame during driver animation (60fps)
  void _onRiderDriverAnimTick() {
    if (!mounted) return;
    final raw = _riderDriverAnim?.value ?? 1.0;
    final t = Curves.easeOutCubic.transform(raw);

    final lat =
        _riderAnimFrom.latitude +
        (_riderAnimTo.latitude - _riderAnimFrom.latitude) * t;
    final lng =
        _riderAnimFrom.longitude +
        (_riderAnimTo.longitude - _riderAnimFrom.longitude) * t;
    _driverPosition = LatLng(lat, lng);

    // Smooth bearing interpolation
    _driverBearing = _lerpAngle(
      _driverBearing,
      _riderTargetBearing,
      t.clamp(0.0, 0.5),
    );

    _updateDriverMarkerFromPosition();

    // ── 3D Chase-Cam: follow driver every frame for game-like feel ──
    if (_stage == RideStage.riding && _driverPosition != null) {
      _panTo(_driverPosition!, zoom: 18.5, bearing: _driverBearing, tilt: 45);
    }

    // Trim route behind driver on every frame for seamless visual
    if (_driverRoutePoints.length > 2) {
      _trimRiderRoute(_driverPosition!);
    }
  }

  /// Uber-style driver car icon (delegates to CarIconLoader).
  Future<void> _buildDriverCarIcon() async {
    // Use ride-specific car: Suburban→SUV, Fusion→black sedan, default→white sedan
    final rideName = _rides.isNotEmpty ? _rides[_selectedRide].vehicle : '';
    _driverCarIconBytes =
        await CarIconLoader.loadForRideBytes(rideName) ??
        await CarIconLoader.loadUberBytes();
    final icon = _driverCarIconBytes != null
        ? BitmapDescriptor.bytes(_driverCarIconBytes!)
        : await CarIconLoader.loadUber();
    if (mounted) setState(() => _driverCarIcon = icon);
  }

  // Keep legacy method for compatibility
  void _updateDriverMarkerByProgress() {
    // Now delegates to real GPS position
    _updateDriverMarkerFromPosition();
  }

  /// Recalculate route polyline without moving the camera.
  /// Shows the new line instantly (no animation) to stay snappy while
  /// the user is panning to adjust the pickup spot.
  Future<void> _silentRouteRecalculate() async {
    if (_pickupMarker == null || _dropoffMarker == null) return;
    final ticket = ++_routeAnimationTicket;
    final origin = _pickupMarker!.position;
    final destination = _dropoffMarker!.position;
    final route = await _directions.getRoute(
      origin: origin,
      destination: destination,
    );
    if (!mounted || ticket != _routeAnimationTicket) return;
    if (route != null) {
      _activeRoutePoints = route.points;
      final newPolylines = _buildRoutePolylines(route.points);
      setState(() {
        _tripMiles = _formatMiles(route.distanceMeters);
        _tripDuration = route.durationText;
        _updateRidePricingFromDuration(_tripDuration);
        _polylines = newPolylines;
      });
    }
  }

  // ignore: unused_element – retained for future use
  void _onConfirmPickupCameraIdle() {
    final target = _cameraTarget;
    if (target == null) return;

    _cameraIdleDebounce?.cancel();
    _cameraIdleDebounce = Timer(const Duration(milliseconds: 150), () async {
      if (!mounted || _stage != RideStage.confirmPickup || _isRecentering) {
        return;
      }

      final last = _lastReverseGeocodedTarget;
      if (last != null) {
        final movedMeters = Geolocator.distanceBetween(
          last.latitude,
          last.longitude,
          target.latitude,
          target.longitude,
        );
        if (movedMeters < 15) return;
      }

      setState(() {
        _pickupMarker = _pickupMapMarker(target, snippet: _pickupAddress);
      });

      final requestTicket = ++_reverseGeocodeTicket;
      try {
        final address = await _places.reverseGeocode(
          lat: target.latitude,
          lng: target.longitude,
        );
        if (!mounted ||
            requestTicket != _reverseGeocodeTicket ||
            _stage != RideStage.confirmPickup) {
          return;
        }
        final resolved = (address == null || address.isEmpty)
            ? _coordinatesLabel(target)
            : address;
        _lastReverseGeocodedTarget = target;
        setState(() {
          _pickupAddress = resolved;
          _pickupCtrl.text = resolved;
          _pickupMarker = _pickupMapMarker(target, snippet: resolved);
          _currentPosition = target;
        });
        // Silently recalculate route without moving camera
        _silentRouteRecalculate();
      } catch (_) {
        if (!mounted || requestTicket != _reverseGeocodeTicket) return;
        final fallback = _coordinatesLabel(target);
        setState(() {
          _pickupAddress = fallback;
          _pickupCtrl.text = fallback;
          _pickupMarker = _pickupMapMarker(target, snippet: fallback);
          _currentPosition = target;
        });
        // Silently recalculate route without moving camera
        _silentRouteRecalculate();
      }
    });
  }

  /// Called when user drags the pickup marker to a new position in confirmPickup stage.
  void _onPickupMarkerDragEnd(LatLng newPosition) {
    setState(() {
      _pickupMarker = _pickupMapMarker(newPosition, snippet: _pickupAddress);
    });

    final requestTicket = ++_reverseGeocodeTicket;
    _places
        .reverseGeocode(lat: newPosition.latitude, lng: newPosition.longitude)
        .then((address) {
          if (!mounted ||
              requestTicket != _reverseGeocodeTicket ||
              _stage != RideStage.confirmPickup) {
            return;
          }
          final resolved = (address == null || address.isEmpty)
              ? _coordinatesLabel(newPosition)
              : address;
          _lastReverseGeocodedTarget = newPosition;
          setState(() {
            _pickupAddress = resolved;
            _pickupCtrl.text = resolved;
            _pickupMarker = _pickupMapMarker(newPosition, snippet: resolved);
            _currentPosition = newPosition;
          });
          _silentRouteRecalculate();
        })
        .catchError((_) {
          if (!mounted || requestTicket != _reverseGeocodeTicket) return;
          final fallback = _coordinatesLabel(newPosition);
          setState(() {
            _pickupAddress = fallback;
            _pickupCtrl.text = fallback;
            _pickupMarker = _pickupMapMarker(newPosition, snippet: fallback);
            _currentPosition = newPosition;
          });
          _silentRouteRecalculate();
        });
  }

  void _showDriverNoteSheet() {
    final noteCtrl = TextEditingController(text: _driverNote);
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (context) {
        return Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.of(context).viewInsets.bottom,
          ),
          child: SafeArea(
            top: false,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: _c.mapPanel,
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    S.of(context).noteForDriver,
                    style: TextStyle(
                      color: _c.textPrimary,
                      fontSize: 19,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: noteCtrl,
                    autofocus: true,
                    maxLines: 3,
                    style: TextStyle(color: _c.textPrimary, fontSize: 16),
                    decoration: InputDecoration(
                      hintText: S.of(context).noteHint,
                      hintStyle: TextStyle(color: _c.textTertiary),
                      filled: true,
                      fillColor: _c.mapSurface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide.none,
                      ),
                    ),
                  ),
                  const SizedBox(height: 14),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: _panelBlack,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 13),
                      ),
                      onPressed: () {
                        setState(() => _driverNote = noteCtrl.text.trim());
                        Navigator.of(context).pop();
                      },
                      child: Text(
                        S.of(context).saveButton,
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _confirmPickupPanel() {
    return Container(
      key: const ValueKey('confirmPickup'),
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: BoxDecoration(
        color: _c.mapPanel,
        borderRadius: const BorderRadius.all(Radius.circular(28)),
        border: Border.all(color: _c.border, width: 1.2),
        boxShadow: [
          BoxShadow(
            color: _c.shadow,
            blurRadius: 32,
            offset: const Offset(0, -8),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4.5,
                decoration: BoxDecoration(
                  color: _c.iconMuted,
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              S.of(context).confirmPickupSpot,
              style: TextStyle(
                color: _c.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 5),
            Text(
              S.of(context).moveMapAdjustPickup,
              style: TextStyle(
                color: _c.textTertiary,
                fontSize: 13.5,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(height: 18),
            // Schedule banner
            if (!_pickupNow) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _gold.withValues(alpha: 0.30)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.calendar_today_rounded,
                      color: _gold,
                      size: 16,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        S.of(context).scheduledFor(_rideTimeBadgeText),
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ],
            // --- Pickup address card ---
            Container(
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: _c.border,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(
                  color: _gold.withValues(alpha: 0.30),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(
                      Icons.my_location_rounded,
                      color: _gold,
                      size: 18,
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          S.of(context).pickupLabel.toUpperCase(),
                          style: TextStyle(
                            color: _gold.withValues(alpha: 0.8),
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 1.2,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          _pickupAddress,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: _c.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            // --- Driver note ---
            InkWell(
              onTap: _showDriverNoteSheet,
              borderRadius: BorderRadius.circular(12),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  vertical: 10,
                  horizontal: 14,
                ),
                decoration: BoxDecoration(
                  color: _c.border,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.edit_note_rounded,
                      color: _gold.withValues(alpha: 0.8),
                      size: 20,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        _driverNote.isEmpty
                            ? S.of(context).addNoteForDriver
                            : _driverNote,
                        style: TextStyle(
                          color: _driverNote.isEmpty
                              ? _gold.withValues(alpha: 0.75)
                              : _c.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          fontStyle: _driverNote.isEmpty
                              ? FontStyle.normal
                              : FontStyle.italic,
                        ),
                      ),
                    ),
                    Icon(
                      Icons.chevron_right_rounded,
                      color: _c.iconMuted,
                      size: 20,
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            // --- Confirm button ---
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _gold,
                  foregroundColor: Colors.black,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                ),
                onPressed: _confirmPickupAndRequestRide,
                child: Text(
                  S.of(context).selectPayment,
                  style: const TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.2,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // â”€â”€ Payment method helpers â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€

  /// Returns display info for a payment method id.
  ({String label, Widget logoWidget}) _paymentMethodInfo(String id) {
    switch (id) {
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
        return (label: 'Google Pay', logoWidget: _googlePayLogoWidget(36));
    }
  }

  String _capitalizedBrand(String? brand) {
    switch (brand) {
      case 'visa':
        return 'Visa';
      case 'mastercard':
        return 'Mastercard';
      case 'amex':
        return 'Amex';
      case 'discover':
        return 'Discover';
      case 'diners':
        return 'Diners Club';
      case 'jcb':
        return 'JCB';
      default:
        return 'Card';
    }
  }

  Widget _cardBrandLogoWidget(String? brand, double size) {
    final Map<String, ({String letter, Color color, bool italic})> brands = {
      'visa': (letter: 'V', color: const Color(0xFF1A1F71), italic: true),
      'mastercard': (
        letter: 'M',
        color: const Color(0xFFEB001B),
        italic: false,
      ),
      'amex': (letter: 'A', color: const Color(0xFF006FCF), italic: false),
      'discover': (letter: 'D', color: const Color(0xFFFF6000), italic: false),
      'diners': (letter: 'D', color: const Color(0xFF0079BE), italic: false),
      'jcb': (letter: 'J', color: const Color(0xFF0B7CBE), italic: false),
    };
    final info = brands[brand];
    if (info == null) {
      return _brandLogo(
        null,
        const Color(0xFF6B7280),
        icon: Icons.credit_card_rounded,
      );
    }
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Center(
        child: Text(
          info.letter,
          style: TextStyle(
            color: info.color,
            fontSize: size * 0.56,
            fontWeight: FontWeight.w900,
            fontStyle: info.italic ? FontStyle.italic : FontStyle.normal,
            fontFamily: 'Roboto',
          ),
        ),
      ),
    );
  }

  Widget _brandLogo(
    String? letter,
    Color color, {
    Color? bg,
    bool bordered = false,
    bool italic = false,
    IconData? icon,
  }) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: bg ?? color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: bordered
            ? Border.all(color: Colors.grey.shade300, width: 0.5)
            : null,
      ),
      child: Center(
        child: icon != null
            ? Icon(icon, color: color, size: 20)
            : Text(
                letter!,
                style: TextStyle(
                  color: color,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  fontStyle: italic ? FontStyle.italic : FontStyle.normal,
                  fontFamily: 'Roboto',
                ),
              ),
      ),
    );
  }

  /// Google Pay logo using the real multicolor "G" image asset.
  Widget _googlePayLogoWidget(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(6),
        child: Image.asset('assets/images/google_g.png', fit: BoxFit.contain),
      ),
    );
  }

  /// PayPal logo using the real double-P image asset.
  Widget _paypalLogoWidget(double size) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.grey.shade300, width: 0.5),
      ),
      child: Padding(
        padding: const EdgeInsets.all(5),
        child: Image.asset(
          'assets/images/paypal_logo.png',
          fit: BoxFit.contain,
        ),
      ),
    );
  }

  /// Opens the payment-method bottom sheet and lets the user pick one.
  void _showPaymentMethodSelector() {
    final creditLabel = (_savedCardBrand != null && _savedCardLast4 != null)
        ? '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4'
        : S.of(context).creditOrDebitCard;
    final methods = [
      ('google_pay', 'Google Pay'),
      ('credit_card', creditLabel),
      ('paypal', 'PayPal'),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          decoration: BoxDecoration(
            color: _c.mapPanel,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // drag handle
                Center(
                  child: Container(
                    width: 40,
                    height: 4.5,
                    decoration: BoxDecoration(
                      color: _c.iconMuted,
                      borderRadius: BorderRadius.circular(40),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    S.of(context).paymentMethodTitle,
                    style: TextStyle(
                      color: _c.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                ...methods.map((m) {
                  final (id, label) = m;
                  final info = _paymentMethodInfo(id);
                  final selected = id == _selectedPaymentMethod;
                  final linked = _linkedPaymentMethods.contains(id);
                  return GestureDetector(
                    onTap: () {
                      Navigator.pop(ctx);
                      _onPaymentMethodSelected(id);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? _gold.withValues(alpha: 0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: selected
                            ? Border.all(
                                color: _gold.withValues(alpha: 0.4),
                                width: 1.2,
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          info.logoWidget,
                          const SizedBox(width: 14),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  style: TextStyle(
                                    color: _c.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (!linked)
                                  Text(
                                    S.of(context).notAdded,
                                    style: const TextStyle(
                                      color: Colors.white54,
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          if (linked && selected)
                            Icon(
                              Icons.check_circle_rounded,
                              color: _gold,
                              size: 22,
                            )
                          else if (linked)
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: _gold.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                S.of(context).addedLabel,
                                style: TextStyle(
                                  color: _gold,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: _gold,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                S.of(context).addButton,
                                style: const TextStyle(
                                  color: Colors.black,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  );
                }),
                const SizedBox(height: 8),
                // Manage payment accounts link
                GestureDetector(
                  onTap: () async {
                    Navigator.pop(ctx);
                    await Navigator.of(
                      context,
                    ).push(slideFromRightRoute(const PaymentAccountsScreen()));
                    _loadLinkedPayments(); // refresh linked state on return
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.settings_rounded, color: _gold, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        S.of(context).managePaymentAccounts,
                        style: TextStyle(
                          color: _gold,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
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
            backgroundColor: _c.surface,
            behavior: SnackBarBehavior.floating,
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

  Widget _paymentPanel() {
    final ride = _rides[_selectedRide];
    return Container(
      key: const ValueKey('payment'),
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4.5,
                decoration: BoxDecoration(
                  color: _c.iconMuted,
                  borderRadius: BorderRadius.circular(40),
                ),
              ),
            ),
            const SizedBox(height: 18),
            Text(
              S.of(context).paymentLabel,
              style: TextStyle(
                color: _c.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.3,
              ),
            ),
            const SizedBox(height: 16),
            // Schedule banner for payment panel
            if (!_pickupNow) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: _gold.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: _gold.withValues(alpha: 0.30)),
                ),
                child: Row(
                  children: [
                    const Icon(
                      Icons.calendar_today_rounded,
                      color: _gold,
                      size: 16,
                    ),
                    const SizedBox(width: 10),
                    Text(
                      _rideTimeBadgeText,
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
            ],
            // --- Scrollable content area ---
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // --- Ride summary card ---
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _c.border,
                        borderRadius: BorderRadius.circular(16),
                        border: Border.all(color: _c.border, width: 1),
                      ),
                      child: Row(
                        children: [
                          Container(
                            width: 56,
                            height: 44,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(12),
                            ),
                            clipBehavior: Clip.antiAlias,
                            child: Image.asset(
                              'assets/images/${ride.vehicle.toLowerCase()}.png',
                              fit: BoxFit.contain,
                              filterQuality: FilterQuality.high,
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  '${ride.name} • ${ride.vehicle}',
                                  style: TextStyle(
                                    color: _c.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Text(
                                  '$_tripMiles • $_tripDuration',
                                  style: TextStyle(
                                    color: _c.textTertiary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          Text(
                            ride.price,
                            style: TextStyle(
                              color: _c.textPrimary,
                              fontSize: 20,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (_promoActive) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          children: [
                            Icon(
                              Icons.local_offer_rounded,
                              color: _gold,
                              size: 16,
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text(
                                S
                                    .of(context)
                                    .promoDiscountApplied(
                                      _promoDiscountPercent,
                                    ),
                                style: TextStyle(
                                  color: _gold,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    // --- Route summary ---
                    Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: _c.border,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: _gold,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _pickupAddress,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _c.textPrimary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          Padding(
                            padding: const EdgeInsets.only(left: 4),
                            child: Align(
                              alignment: Alignment.centerLeft,
                              child: Container(
                                width: 2,
                                height: 20,
                                color: _c.textTertiary,
                              ),
                            ),
                          ),
                          Row(
                            children: [
                              Container(
                                width: 10,
                                height: 10,
                                decoration: BoxDecoration(
                                  color: _c.iconDefault,
                                  borderRadius: BorderRadius.circular(5),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Text(
                                  _dropoffAddress,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: _c.textSecondary,
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 12),
                    // --- Payment method selector ---
                    GestureDetector(
                      onTap: _showPaymentMethodSelector,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: _c.border,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.25),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            _paymentMethodInfo(
                              _selectedPaymentMethod,
                            ).logoWidget,
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _paymentMethodInfo(
                                      _selectedPaymentMethod,
                                    ).label,
                                    style: TextStyle(
                                      color: _c.textPrimary,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    _linkedPaymentMethods.contains(
                                          _selectedPaymentMethod,
                                        )
                                        ? S.of(context).tapToChange
                                        : S.of(context).notAddedTapSetup,
                                    style: TextStyle(
                                      color:
                                          _linkedPaymentMethods.contains(
                                            _selectedPaymentMethod,
                                          )
                                          ? _c.textTertiary
                                          : Colors.white,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: _c.textTertiary,
                              size: 22,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 10),
            // --- Pay button ---
            if (!_linkedPaymentMethods.contains(_selectedPaymentMethod))
              // Unlinked — connect button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: () async {
                    await Navigator.of(
                      context,
                    ).push(slideFromRightRoute(const PaymentAccountsScreen()));
                    _loadLinkedPayments();
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.link_rounded, size: 18),
                      SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          S.of(context).addPaymentMethod,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            else
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _gold,
                    foregroundColor: Colors.black,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(16),
                    ),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                  onPressed: _processPaymentAndRequestRide,
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _pickupNow
                            ? Icons.lock_rounded
                            : Icons.calendar_month_rounded,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _pickupNow
                              ? S.of(context).payAmount(ride.price)
                              : S
                                    .of(context)
                                    .bookScheduledRidePrice(ride.price),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.2,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 8),
            // ── TEST MODE: Skip payment ──
            SizedBox(
              width: double.infinity,
              child: OutlinedButton.icon(
                style: OutlinedButton.styleFrom(
                  foregroundColor: _c.textTertiary,
                  side: BorderSide(
                    color: _c.textTertiary.withValues(alpha: 0.35),
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 13),
                ),
                onPressed: _processPaymentAndRequestRide,
                icon: const Icon(Icons.science_rounded, size: 16),
                label: const Text(
                  'Skip Payment (Test)',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _matchingPanel() {
    final ride = _rides[_selectedRide];
    final isSearching = _driverName == 'Searching...';

    return Container(
      key: const ValueKey('matching'),
      height: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          children: [
            _handle(),
            const SizedBox(height: 16),

            // â”€â”€ Pulsing radar animation â”€â”€
            SizedBox(
              height: 100,
              width: 100,
              child: _MatchingRadar(color: _gold, isSearching: isSearching),
            ),
            const SizedBox(height: 16),

            // â”€â”€ Title with animated dots â”€â”€
            isSearching
                ? _AnimatedSearchText(
                    text: S.of(context).lookingForDriver,
                    style: TextStyle(
                      color: _c.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  )
                : Text(
                    S.of(context).driverFound,
                    style: TextStyle(
                      color: _gold,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.3,
                    ),
                  ),
            const SizedBox(height: 6),

            // â”€â”€ Subtitle: vehicle + ETA â”€â”€
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 250),
              child: Text(
                isSearching
                    ? S.of(context).findingBestNearby(ride.name)
                    : S.of(context).arrivingIn(ride.name, _driverEta),
                key: ValueKey(isSearching),
                style: TextStyle(color: _c.textSecondary, fontSize: 14),
              ),
            ),
            const SizedBox(height: 18),

            // â”€â”€ Progress bar â”€â”€
            ClipRRect(
              borderRadius: BorderRadius.circular(99),
              child: isSearching
                  ? SizedBox(
                      height: 3,
                      child: LinearProgressIndicator(
                        color: _gold,
                        backgroundColor: _c.border,
                      ),
                    )
                  : SizedBox(
                      height: 3,
                      child: LinearProgressIndicator(
                        value: 1.0,
                        color: _gold,
                        backgroundColor: _c.border,
                      ),
                    ),
            ),
            const SizedBox(height: 18),

            // â”€â”€ Driver info card â”€â”€
            AnimatedSwitcher(
              duration: const Duration(milliseconds: 300),
              switchInCurve: Curves.easeOutCubic,
              child: isSearching
                  ? _matchingSkeletonCard()
                  : _matchingDriverCard(),
            ),

            const Spacer(),

            // â”€â”€ Route summary row â”€â”€
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: _c.border),
              ),
              child: Row(
                children: [
                  Container(
                    width: 8,
                    height: 8,
                    decoration: const BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.greenAccent,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _pickupAddress.isNotEmpty
                          ? _pickupAddress
                          : S.of(context).pickupLabel,
                      style: TextStyle(
                        color: _c.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Icon(
                    Icons.arrow_forward_rounded,
                    color: _c.textTertiary,
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Container(
                    width: 8,
                    height: 8,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: _c.textTertiary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      _dropoffAddress.isNotEmpty
                          ? _dropoffAddress
                          : S.of(context).dropoffLabel,
                      style: TextStyle(
                        color: _c.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // â”€â”€ Action buttons â”€â”€
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 50,
                    child: OutlinedButton(
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: _c.border),
                        foregroundColor: _c.textPrimary,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () {
                        _rideLifecycleTimer?.cancel();
                        _tripPollTimer?.cancel();
                        _setStage(RideStage.options);
                      },
                      child: Text(
                        S.of(context).cancelRide,
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 50,
                    child: ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: _panelBlack,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                      onPressed: () {
                        ScaffoldMessenger.maybeOf(context)?.showSnackBar(
                          SnackBar(
                            content: Text(S.of(context).driverContacted),
                          ),
                        );
                      },
                      icon: const Icon(Icons.phone_rounded, size: 18),
                      label: Flexible(
                        child: Text(
                          isSearching
                              ? S.of(context).contactSupport
                              : S.of(context).callDriver,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
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

  /// Skeleton loading card shown while searching for driver
  Widget _matchingSkeletonCard() {
    return Container(
      key: const ValueKey('skeleton'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _c.border),
      ),
      child: Row(
        children: [
          // Skeleton avatar
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: Colors.white.withValues(alpha: 0.06),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(width: 120, height: 14, decoration: _skeleton),
                const SizedBox(height: 8),
                Container(width: 80, height: 11, decoration: _skeletonLight),
              ],
            ),
          ),
          Container(width: 60, height: 14, decoration: _skeleton),
        ],
      ),
    );
  }

  /// Driver info card shown when driver is found
  Widget _matchingDriverCard() {
    return Container(
      key: const ValueKey('driver'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: _gold.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: _gold.withValues(alpha: 0.15)),
      ),
      child: Row(
        children: [
          // Driver avatar
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: LinearGradient(
                colors: [_gold, _gold.withValues(alpha: 0.6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
            ),
            child: Center(
              child: Text(
                _driverName.isNotEmpty ? _driverName[0].toUpperCase() : '?',
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 20,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Flexible(
                      child: Text(
                        _driverName,
                        style: TextStyle(
                          color: _c.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.star_rounded, color: _gold, size: 14),
                          const SizedBox(width: 2),
                          Text(
                            _driverRating.toStringAsFixed(1),
                            style: TextStyle(
                              color: _gold,
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  _driverCar.isNotEmpty
                      ? _driverCar
                      : _rides[_selectedRide].name,
                  style: TextStyle(
                    color: _gold,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          if (_driverPlate.isNotEmpty)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                _driverPlate,
                style: TextStyle(
                  color: _c.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.5,
                ),
              ),
            ),
        ],
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  RIDER NAVIGATION HEADER (Uber-style turn card)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _buildRiderNavHeader() {
    final isInTrip = _tripStatus == 'in_trip';
    final isArrived = _tripStatus == 'arrived';

    // Compute arrival time chip
    String chipLabel;
    IconData chipIcon;
    Color chipColor;
    Color iconColor;

    if (isInTrip) {
      // Show estimated arrival time
      final now = DateTime.now();
      // Parse ETA string (e.g. "8 min") to get minutes
      final etaNum =
          int.tryParse(_driverEta.replaceAll(RegExp(r'[^0-9]'), '')) ?? 0;
      final arrival = now.add(Duration(minutes: etaNum));
      final h = arrival.hour % 12 == 0 ? 12 : arrival.hour % 12;
      final m = arrival.minute.toString().padLeft(2, '0');
      final period = arrival.hour < 12 ? 'am' : 'pm';
      chipLabel = S.of(context).arrivalTime('$h:$m$period');
      chipIcon = Icons.access_time_rounded;
      chipColor = Colors.white;
      iconColor = Colors.black87;
    } else if (isArrived) {
      chipLabel = S.of(context).driverArrived;
      chipIcon = Icons.place_rounded;
      chipColor = const Color(0xFF4FC3F7);
      iconColor = Colors.black87;
    } else {
      chipLabel = _driverEta.isNotEmpty
          ? S.of(context).etaLabel(_driverEta)
          : S.of(context).driverEnRoute;
      chipIcon = Icons.directions_car_rounded;
      chipColor = Colors.white;
      iconColor = Colors.black87;
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: chipColor,
        borderRadius: BorderRadius.circular(20),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.18),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(chipIcon, size: 15, color: iconColor),
          const SizedBox(width: 5),
          Text(
            chipLabel,
            style: TextStyle(
              color: iconColor,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  Widget _ridingPanel() {
    final isInTrip = _tripStatus == 'in_trip';
    final isArrived = _tripStatus == 'arrived';
    final price = (_rides.isNotEmpty && _selectedRide < _rides.length)
        ? _rides[_selectedRide].price
        : '';
    final rideName = (_rides.isNotEmpty && _selectedRide < _rides.length)
        ? _rides[_selectedRide].name
        : 'CRUISE';

    return Container(
      key: const ValueKey('riding'),
      height: double.infinity,
      decoration: _panelDecoration,
      child: SafeArea(
        top: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _handle(),
            const SizedBox(height: 12),

            // Route visual row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 18,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 12,
                          height: 12,
                          decoration: const BoxDecoration(
                            color: Color(0xFF00C853),
                            shape: BoxShape.circle,
                          ),
                        ),
                        Container(
                          width: 2,
                          height: 22,
                          color: const Color(0xFF9E9E9E),
                        ),
                        const Icon(
                          Icons.location_on,
                          color: Color(0xFF1565C0),
                          size: 18,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          _pickupAddress.isNotEmpty
                              ? _pickupAddress
                              : S.of(context).yourLocation,
                          style: TextStyle(
                            color: _c.textSecondary,
                            fontSize: 12,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 14),
                        Text(
                          _dropoffAddress.isNotEmpty
                              ? _dropoffAddress
                              : S.of(context).destinationLabel,
                          style: TextStyle(
                            color: _c.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: () async {
                      final result = await Navigator.of(context)
                          .push<Map<String, dynamic>>(
                            slideFromRightRoute(PickupDropoffSearchScreen(
                              initialPickupText: _pickupAddress,
                            )),
                          );
                      if (result != null &&
                          result['dropoffLabel'] != null &&
                          mounted) {
                        setState(() {
                          _dropoffAddress = result['dropoffLabel'] as String;
                        });
                      }
                    },
                    style: TextButton.styleFrom(
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(60, 44),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      S.of(context).addOrChange,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        color: _c.isDark ? _gold : const Color(0xFF1565C0),
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        height: 1.3,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 12),
            Divider(height: 1, color: _c.border),
            const SizedBox(height: 10),

            // Driver row
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: _gold.withValues(alpha: 0.2),
                    child: Text(
                      _driverName.isNotEmpty
                          ? _driverName[0].toUpperCase()
                          : '?',
                      style: const TextStyle(
                        color: _gold,
                        fontWeight: FontWeight.w800,
                        fontSize: 18,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              _driverName,
                              style: TextStyle(
                                color: _c.textPrimary,
                                fontWeight: FontWeight.w700,
                                fontSize: 15,
                              ),
                            ),
                            const SizedBox(width: 6),
                            const Icon(
                              Icons.star_rounded,
                              color: _gold,
                              size: 13,
                            ),
                            Text(
                              ' 4.9',
                              style: TextStyle(
                                color: _c.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        if (_driverCar.isNotEmpty || _driverPlate.isNotEmpty)
                          Text(
                            [
                              if (_driverCar.isNotEmpty) _driverCar,
                              if (_driverPlate.isNotEmpty) _driverPlate,
                            ].join(' \u2022 '),
                            style: TextStyle(
                              color: _c.textSecondary,
                              fontSize: 12,
                            ),
                          ),
                      ],
                    ),
                  ),
                  GestureDetector(
                    onTap: () async {
                      if (_driverPhone.isNotEmpty) {
                        final uri = Uri(scheme: 'tel', path: _driverPhone);
                        if (await canLaunchUrl(uri)) {
                          await launchUrl(uri);
                        }
                      }
                    },
                    child: Container(
                      width: 42,
                      height: 42,
                      decoration: BoxDecoration(
                        color: _c.isDark
                            ? const Color(0xFF2A2A2A)
                            : const Color(0xFF1C1E24),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        Icons.phone_rounded,
                        size: 18,
                        color: _c.textPrimary,
                      ),
                    ),
                  ),
                ],
              ),
            ),

            const SizedBox(height: 10),
            Divider(height: 1, color: _c.border),

            // Rate row (in_trip only)
            if (isInTrip) ...[
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Text(
                      S.of(context).howsYourRide,
                      style: TextStyle(
                        color: _c.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: () {
                        Navigator.of(context).push(
                          sharedAxisVerticalRoute(
                            RideRatingScreen(
                              driverName: _driverName,
                              rideName: rideName,
                              price: price.isNotEmpty ? price : r'$0.00',
                            ),
                          ),
                        );
                      },
                      child: Row(
                        children: [
                          Text(
                            S.of(context).rateOrTip,
                            style: TextStyle(
                              color: _c.isDark
                                  ? _gold
                                  : const Color(0xFF1565C0),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          Icon(
                            Icons.chevron_right_rounded,
                            size: 18,
                            color: _c.isDark ? _gold : const Color(0xFF1565C0),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: _c.border),
            ],

            const Spacer(),

            // Bottom: price/ETA + cancel
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  if (isInTrip && price.isNotEmpty) ...[
                    Text(
                      price,
                      style: TextStyle(
                        color: _c.textPrimary,
                        fontSize: 28,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_tripMiles.isNotEmpty || _tripDuration.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: _c.border,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          [
                            if (_tripMiles.isNotEmpty) _tripMiles,
                            if (_tripDuration.isNotEmpty) _tripDuration,
                          ].join(' \u2022 '),
                          style: TextStyle(
                            color: _c.textSecondary,
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                  ] else ...[
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isArrived
                                ? S.of(context).driverAtPickup(_driverName)
                                : S.of(context).etaLabel(_driverEta),
                            style: TextStyle(
                              color: _c.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (!isArrived)
                            Text(
                              S.of(context).driverOnTheWay(_driverName),
                              style: TextStyle(
                                color: _c.textSecondary,
                                fontSize: 12,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                  const Spacer(),
                  TextButton(
                    onPressed: () async {
                      final confirm = await showDialog<bool>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          title: Text(S.of(context).cancelRide),
                          content: Text(S.of(context).cancelRideConfirmation),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, false),
                              child: Text(
                                S.of(context).keepRide,
                                style: TextStyle(color: _gold),
                              ),
                            ),
                            TextButton(
                              onPressed: () => Navigator.pop(ctx, true),
                              child: Text(
                                S.of(context).cancelButton,
                                style: const TextStyle(color: Colors.redAccent),
                              ),
                            ),
                          ],
                        ),
                      );
                      if (confirm != true || !mounted) return;
                      _rideLifecycleTimer?.cancel();
                      _tripPollTimer?.cancel();
                      setState(() {
                        _driverMarker = null;
                        _rideProgress = 0;
                      });
                      Navigator.of(context).maybePop();
                    },
                    child: Text(
                      S.of(context).cancelButton,
                      style: TextStyle(color: _c.textSecondary, fontSize: 14),
                    ),
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

    return ListenableBuilder(
      listenable: _ctrl,
      builder: (_, __) {
        return CustomPaint(
          size: const Size(100, 100),
          painter: _RadarPainter(progress: _ctrl.value, color: widget.color),
        );
      },
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

    // 3 concentric expanding rings
    for (int i = 0; i < 3; i++) {
      final phase = (progress + i * 0.33) % 1.0;
      final radius = maxRadius * 0.3 + maxRadius * 0.7 * phase;
      final alpha = (1.0 - phase).clamp(0.0, 1.0) * 0.35;

      final paint = Paint()
        ..color = color.withValues(alpha: alpha)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0;

      canvas.drawCircle(center, radius, paint);
    }

    // Center gold dot
    final dotPaint = Paint()..color = color;
    canvas.drawCircle(center, 10, dotPaint);

    // Inner shimmer
    final shimmer = Paint()
      ..color = color.withValues(alpha: 0.15)
      ..style = PaintingStyle.fill;
    canvas.drawCircle(
      center,
      20 + 6 * math.sin(progress * math.pi * 2),
      shimmer,
    );
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
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
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

// Map styles are now in config/map_styles.dart (MapStyles.dark / MapStyles.light)
