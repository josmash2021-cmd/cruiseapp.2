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
import '../widgets/verified_avatar.dart';
import 'scheduled_rides_screen.dart';
import 'searching_driver_screen.dart';

/// Main Uber-like ride request screen.
///
/// Flow:
///  1. Fullscreen map with "Where to?" pill  →  tap opens search
///  2. Route preview with polyline
///  3. Ride options bottom sheet
///  4. "Confirm Fusion" → searching animation
///  5. Driver matched → tracking screen
enum _PinIcon { none, person, house, store, airplane }

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

class _RideRequestScreenState extends State<RideRequestScreen>
    with TickerProviderStateMixin {
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
  bool _hasAppliedSelectionTilt = false;
  bool _labelsRevealed = false;
  AnimationController? _labelPopCtrl;
  Animation<double>? _labelPopAnim;
  LatLng? _center;
  LatLng? _userLocation;
  bool _mapReady = false;

  // ── Trip controller ──
  final RiderTripController _ctrl = RiderTripController();

  // ── Map elements (raw bytes) ──
  Uint8List? _goldPinIcon;

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

  // ── Bottom sheet ──
  late AnimationController _sheetCtrl;
  late Animation<double> _sheetSlide;

  // ── Current location address ──
  String _currentAddress = '';
  bool _fetchingLocation = true;

  // ── Guard: only navigate to tracking once ──
  bool _navigatingToTracking = false;

  // ── Payment state ──
  String _selectedPaymentMethod = Platform.isIOS ? 'apple_pay' : 'google_pay';
  Set<String> _linkedPaymentMethods = {};
  String? _savedCardLast4;
  String? _savedCardBrand;
  bool _isProcessingPayment = false;

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
        // Auto-geocode airport and set as pickup when airport selection provided
        if (widget.airportSelection != null) {
          _autoSetAirportPickup(widget.airportSelection!);
        }
        // Direct details available (e.g. from Choose on map) — use immediately
        if (widget.initialPickupDetails != null) {
          _ctrl.setPickup(
            widget.initialPickupDetails!,
            widget.initialPickupLabel ?? widget.initialPickupDetails!.address,
          );
        } else if (_userLocation != null && widget.initialDropoffDetails != null) {
          _ctrl.setPickup(
            PlaceDetails(
              address: _currentAddress,
              lat: _userLocation!.latitude,
              lng: _userLocation!.longitude,
            ),
            _currentAddress,
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
    _goldDot.build(() { if (mounted) _updateUserDotAnnotation(); });
    _loadLinkedPayments();
    _loadPinIcon();
  }

  Future<void> _loadPinIcon() async {
    _goldPinIcon = await _buildGoldPinBytes();
    if (mounted) setState(() {});
  }

  Future<Uint8List?> _buildGoldPinBytes() async {
    const double size = 120;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    _drawGoldPinAt(canvas, 0, 0, size, icon: _PinIcon.person, isPickup: true);
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  /// Geocode the airport name + terminal + zone into real coordinates,
  /// then auto-fill the pickup field so the rider sees the exact address.
  Future<void> _autoSetAirportPickup(AirportSelection sel) async {
    final places = PlacesService(ApiKeys.webServices);
    final ap = sel.airport;
    // Build a descriptive search query that includes terminal & zone
    final terminalPart = sel.terminal != null ? ', ${sel.terminal}' : '';
    final zonePart = sel.pickupZone != null ? ' — ${sel.pickupZone}' : '';
    final query = '${ap.name}$terminalPart';

    try {
      // Search via Places autocomplete
      final results = await places.autocomplete(query);
      if (!mounted) return;
      if (results.isNotEmpty) {
        final first = results.first;
        final details = await places.details(first.placeId);
        if (!mounted) return;
        if (details != null) {
          // Build the display label: "Terminal S — Arrivals Level 1 - Door 5"
          final label = '${ap.code} · ${sel.terminal ?? ap.name}$zonePart';
          _ctrl.setPickup(details, label);
          // Animate map camera to airport
          final target = LatLng(details.lat, details.lng);
          _mapCtrl?.flyTo(
            mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(target.longitude, target.latitude)), zoom: 17.0),
            mapbox.MapAnimationOptions(duration: 800),
          );
          return;
        }
      }
    } catch (_) {}

    // Fallback: use airport name as manual label with no coords
    // (rider must confirm/adjust pickup on map)
    final terminalLabel = sel.terminal != null
        ? '${ap.code} · ${sel.terminal}$zonePart'
        : ap.name;
    // Try a direct text search as second fallback
    try {
      final results = await places.autocomplete(ap.name);
      if (!mounted) return;
      if (results.isNotEmpty) {
        final details = await places.details(results.first.placeId);
        if (!mounted || details == null) return;
        _ctrl.setPickup(details, terminalLabel);
      }
    } catch (_) {}
  }

  /// Auto-geocode a dropoff address string (from Quick Access) and set it.
  Future<void> _autoSetDropoff(String address) async {
    final places = PlacesService(ApiKeys.webServices);
    try {
      final results = await places.autocomplete(address);
      if (!mounted || results.isEmpty) return;
      final details = await places.details(results.first.placeId);
      if (!mounted || details == null) return;

      // Use current location as pickup if available
      if (_userLocation != null) {
        _ctrl.setPickup(
          PlaceDetails(
            address: _currentAddress,
            lat: _userLocation!.latitude,
            lng: _userLocation!.longitude,
          ),
          _currentAddress,
        );
      }
      _ctrl.setDropoff(details, address);
    } catch (_) {}
  }

  static const _gold = Color(0xFFE8C547);

  /// Detect what icon to show on the dropoff pin based on address text.
  static _PinIcon _detectDropoffType(String address) {
    final lower = address.toLowerCase();
    // Airport keywords
    if (lower.contains('airport') ||
        lower.contains('aeropuerto') ||
        lower.contains(' mia ') ||
        lower.contains(' jfk ') ||
        lower.contains(' lax ') ||
        lower.contains(' ord ') ||
        lower.contains(' atl ') ||
        lower.contains(' sfo ') ||
        lower.contains(' dfw ') ||
        lower.contains('intl') ||
        lower.contains('terminal') ||
        lower.contains('aviation')) {
      return _PinIcon.airplane;
    }
    // Commerce / business keywords
    if (lower.contains('mall') ||
        lower.contains('plaza') ||
        lower.contains('store') ||
        lower.contains('shop') ||
        lower.contains('market') ||
        lower.contains('restaurant') ||
        lower.contains('hotel') ||
        lower.contains('hospital') ||
        lower.contains('clinic') ||
        lower.contains('center') ||
        lower.contains('centre') ||
        lower.contains('office') ||
        lower.contains('building') ||
        lower.contains('tower') ||
        lower.contains('suite') ||
        lower.contains('ste ') ||
        lower.contains('walmart') ||
        lower.contains('target') ||
        lower.contains('costco') ||
        lower.contains('starbucks') ||
        lower.contains('mcdonalds') ||
        lower.contains("mcdonald's") ||
        lower.contains('gym') ||
        lower.contains('fitness') ||
        lower.contains('church') ||
        lower.contains('school') ||
        lower.contains('university') ||
        lower.contains('college') ||
        lower.contains('stadium') ||
        lower.contains('arena') ||
        lower.contains('museum') ||
        lower.contains('cinema') ||
        lower.contains('theater') ||
        lower.contains('theatre') ||
        lower.contains('park ') ||
        lower.contains('banco') ||
        lower.contains('bank') ||
        lower.contains('station')) {
      return _PinIcon.store;
    }
    // Default: house / residential
    return _PinIcon.house;
  }

  Future<Uint8List> _buildGoldPin({
    _PinIcon icon = _PinIcon.none,
    bool isPickup = true,
  }) async {
    const double size = 115;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    _drawGoldPinAt(canvas, 0, 0, size, icon: icon, isPickup: isPickup);
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Render a combined pin + label bitmap as a single image.
  /// When [labelOnLeft] is false: pin on LEFT, label on RIGHT (pickup default).
  /// When [labelOnLeft] is true:  label on LEFT, pin on RIGHT (dropoff default).
  /// The canvas is padded so the pin tip is at exact bottom-center,
  /// allowing `iconAnchor: BOTTOM` with zero offset.
  Future<(Uint8List, Offset, Uint8List)> _buildPinWithLabel({
    required String text,
    bool isPickup = true,
    String? etaText,
    _PinIcon icon = _PinIcon.none,
    bool labelOnLeft = false,
  }) async {
    final label = _truncateHalf(text);
    final showEta = etaText != null && etaText.isNotEmpty;

    // ── Pin dimensions ──
    const pinSize = 158.0;

    // ── Measure label text ──
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          fontSize: 34,
          fontWeight: FontWeight.w600,
          color: Colors.white,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 550);

    TextPainter? etaPainter;
    if (showEta) {
      etaPainter = TextPainter(
        text: TextSpan(
          text: etaText,
          style: const TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: Colors.white,
            letterSpacing: 0.3,
          ),
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout(maxWidth: 300);
    }

    // ── Label box sizing ──
    const hPad = 18.0;
    const gap = 10.0;
    const dotSize = 12.0;
    const etaBoxPad = 10.0;
    final etaW = etaPainter != null
        ? etaPainter.width + etaBoxPad * 2 + gap
        : 0.0;
    final labelW = hPad + dotSize + gap + textPainter.width + etaW + hPad + 10;
    const labelH = 95.0;
    const pinLabelGap = 12.0;

    // ── Unpadded layout ──
    final rawW = pinSize + pinLabelGap + labelW;
    final totalH = math.max(pinSize, labelH);

    double pinX, labelX;
    if (labelOnLeft) {
      labelX = 0;
      pinX = labelW + pinLabelGap;
    } else {
      pinX = 0;
      labelX = pinSize + pinLabelGap;
    }
    final double pinY = (totalH - pinSize) / 2;
    final double labelY = (totalH - labelH) / 2;

    // ── Pad canvas so pin tip is at bottom-center ──
    final pinTipX = pinX + pinSize / 2;
    final leftMargin = pinTipX;
    final rightMargin = rawW - pinTipX;
    final maxM = math.max(leftMargin, rightMargin);
    final leftPad = maxM - leftMargin;
    final paddedW = 2 * maxM;

    // Shift drawing positions by leftPad
    final adjPinX = pinX + leftPad;
    final adjLabelX = labelX + leftPad;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, paddedW, totalH));

    // ── Draw pin (airport uses special rendering in _buildStandalonePin) ──
    _drawGoldPinAt(canvas, adjPinX, pinY, pinSize, icon: icon, isPickup: isPickup);

    // If airport, overlay a golden departure icon on the pin head
    if (icon == _PinIcon.airplane) {
      final iconTp = TextPainter(
        text: TextSpan(
          text: String.fromCharCode(Icons.flight_takeoff_rounded.codePoint),
          style: TextStyle(
            fontSize: pinSize * 0.34,
            fontFamily: Icons.flight_takeoff_rounded.fontFamily,
            package: Icons.flight_takeoff_rounded.fontPackage,
            color: Colors.white,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      final headCY = pinY + pinSize * 0.32 + pinSize * 0.04;
      iconTp.paint(
        canvas,
        Offset(
          adjPinX + pinSize / 2 - iconTp.width / 2,
          headCY - iconTp.height / 2,
        ),
      );
    }

    // ── Draw label box ──
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(adjLabelX, labelY, labelW, labelH),
      const Radius.circular(12),
    );
    canvas.drawRRect(bgRect, Paint()..color = const Color(0xF01A1A1A));
    canvas.drawRRect(
      bgRect,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.10)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );

    double x = adjLabelX + hPad;

    // ETA badge
    if (showEta && etaPainter != null) {
      final etaBoxW = etaPainter.width + etaBoxPad * 2;
      final etaRect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, labelY + (labelH - 28) / 2, etaBoxW, 28),
        const Radius.circular(8),
      );
      canvas.drawRRect(
        etaRect,
        Paint()..color = Colors.white.withValues(alpha: 0.14),
      );
      etaPainter.paint(
        canvas,
        Offset(x + etaBoxPad, labelY + (labelH - etaPainter.height) / 2),
      );
      x += etaBoxW + gap;
    }

    // Color dot
    canvas.drawCircle(
      Offset(x + dotSize / 2, labelY + labelH / 2),
      dotSize / 2,
      Paint()..color = isPickup ? Colors.green : _gold,
    );
    x += dotSize + gap;

    // Address text
    textPainter.paint(
      canvas,
      Offset(x, labelY + (labelH - textPainter.height) / 2),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(paddedW.ceil(), totalH.ceil());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);

    // Anchor: pin tip is now at bottom-center by construction
    const anchorOffset = Offset(0.5, 1.0);

    final rawBytes = bytes!.buffer.asUint8List();
    return (rawBytes, anchorOffset, rawBytes);
  }

  /// Render a standalone gold pin (no label) as raw bytes.
  Future<(Uint8List, Uint8List)> _buildStandalonePin({
    _PinIcon icon = _PinIcon.none,
    bool isPickup = true,
  }) async {
    // Airport: clean departure icon only — no teardrop
    if (icon == _PinIcon.airplane) {
      final bytes = await _buildAirportIconBytes(100);
      return (bytes, bytes);
    }
    const double size = 120;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    _drawGoldPinAt(canvas, 0, 0, size, icon: icon, isPickup: isPickup);
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    final bytes = byteData!.buffer.asUint8List();
    return (bytes, bytes);
  }

  /// Render a clean golden flight_takeoff icon (no background shape).
  static Future<Uint8List> _buildAirportIconBytes(double dim) async {
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, dim, dim));

    // Drop shadow behind the icon for map contrast
    final shadow = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.flight_takeoff_rounded.codePoint),
        style: TextStyle(
          fontSize: dim * 0.72,
          fontFamily: Icons.flight_takeoff_rounded.fontFamily,
          package: Icons.flight_takeoff_rounded.fontPackage,
          color: Colors.black.withValues(alpha: 0.45),
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    shadow.paint(
      canvas,
      Offset((dim - shadow.width) / 2 + 1, (dim - shadow.height) / 2 + 2),
    );

    // Golden departure icon
    final tp = TextPainter(
      text: TextSpan(
        text: String.fromCharCode(Icons.flight_takeoff_rounded.codePoint),
        style: TextStyle(
          fontSize: dim * 0.72,
          fontFamily: Icons.flight_takeoff_rounded.fontFamily,
          package: Icons.flight_takeoff_rounded.fontPackage,
          color: _gold,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    tp.paint(
      canvas,
      Offset((dim - tp.width) / 2, (dim - tp.height) / 2),
    );

    final picture = recorder.endRecording();
    final img = await picture.toImage(dim.toInt(), dim.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Draw a teardrop location pin.
  /// The tip points DOWN and sits at (ox + size/2, oy + size) — the coordinate.
  /// A fade gradient blends the tip into the route-line colour.
  void _drawGoldPinAt(
    Canvas canvas,
    double ox,
    double oy,
    double size, {
    _PinIcon icon = _PinIcon.none,
    bool isPickup = true,
  }) {
    final cx = ox + size / 2;      // horizontal center
    final tipY = oy + size;         // tip of the pin = coordinate point
    final r = size * 0.32;          // radius of the round head
    final headCY = oy + r + size * 0.04; // vertical center of the round head

    // ── Build teardrop path ──
    // Round head (top) + two bezier curves tapering to a tip (bottom).
    final path = Path();
    // Start at the left side of the head at its vertical center
    path.moveTo(cx - r, headCY);
    // Arc the top half of the head
    path.arcTo(
      Rect.fromCircle(center: Offset(cx, headCY), radius: r),
      math.pi,        // start: left
      -math.pi,       // sweep: counter-clockwise top
      false,
    );
    // Right side bezier curving to the tip
    path.cubicTo(
      cx + r,       headCY + r * 1.0,
      cx + r * 0.22, tipY - size * 0.04,
      cx,            tipY,
    );
    // Left side bezier back to start
    path.cubicTo(
      cx - r * 0.22, tipY - size * 0.04,
      cx - r,        headCY + r * 1.0,
      cx - r,        headCY,
    );
    path.close();

    // ── Drop shadow ──
    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.32)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );

    // ── Fill teardrop with gold ──
    canvas.drawPath(path, Paint()..color = _gold);

    // ── White inner stroke ──
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.0
        ..color = Colors.white.withValues(alpha: 0.22),
    );

    // ── Subtle highlight on top-left ──
    canvas.drawCircle(
      Offset(cx - r * 0.25, headCY - r * 0.25),
      r * 0.42,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.18)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // ── Fade blend at tip: vertical gradient transparent→route-blue ──
    // Covers roughly the bottom 35% of the pin area, softening the tip.
    final fadeTop = headCY + r * 0.8;
    canvas.drawRect(
      Rect.fromLTRB(cx - r, fadeTop, cx + r, tipY),
      Paint()
        ..shader = ui.Gradient.linear(
          Offset(cx, fadeTop),
          Offset(cx, tipY),
          [Colors.transparent, const Color(0x885BA3F5)],
        )
        ..blendMode = BlendMode.srcATop,
    );

    // Icon center = center of the round head
    final cy = headCY; // alias so icon drawing code below still works

    // Draw icon directly on pin — modern filled style
    const iconColor = Color(0xFFFFFFFF);
    final iconPaint = Paint()
      ..color = iconColor
      ..isAntiAlias = true;
    final iconStrokePaint = Paint()
      ..color = iconColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = size * 0.025
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..isAntiAlias = true;

    switch (icon) {
      case _PinIcon.person:
        final s = size * 0.12;
        // Head — filled circle
        canvas.drawCircle(Offset(cx, cy - s * 0.65), s * 0.52, iconPaint);
        // Body — filled rounded shoulders
        final body = RRect.fromRectAndCorners(
          Rect.fromLTRB(
            cx - s * 0.9,
            cy + s * 0.15,
            cx + s * 0.9,
            cy + s * 1.05,
          ),
          topLeft: Radius.circular(s * 0.9),
          topRight: Radius.circular(s * 0.9),
          bottomLeft: Radius.circular(s * 0.2),
          bottomRight: Radius.circular(s * 0.2),
        );
        canvas.drawRRect(body, iconPaint);
        break;

      case _PinIcon.house:
        final s = size * 0.12;
        // Roof (filled triangle)
        final roof = Path()
          ..moveTo(cx, cy - s * 1.25)
          ..lineTo(cx - s * 1.15, cy - s * 0.1)
          ..lineTo(cx + s * 1.15, cy - s * 0.1)
          ..close();
        canvas.drawPath(roof, iconPaint);
        // House body (filled rect)
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - s * 0.8,
              cy - s * 0.1,
              cx + s * 0.8,
              cy + s * 0.9,
            ),
            Radius.circular(s * 0.08),
          ),
          iconPaint,
        );
        // Door cutout (dark)
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - s * 0.22,
              cy + s * 0.3,
              cx + s * 0.22,
              cy + s * 0.9,
            ),
            Radius.circular(s * 0.15),
          ),
          Paint()..color = _gold,
        );
        break;

      case _PinIcon.store:
        final s = size * 0.12;
        // Store body (filled)
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - s * 1.0,
              cy - s * 0.3,
              cx + s * 1.0,
              cy + s * 1.0,
            ),
            Radius.circular(s * 0.1),
          ),
          iconPaint,
        );
        // Awning (filled with scallops)
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(
              cx - s * 1.1,
              cy - s * 1.0,
              cx + s * 1.1,
              cy - s * 0.3,
            ),
            topLeft: Radius.circular(s * 0.2),
            topRight: Radius.circular(s * 0.2),
          ),
          iconPaint,
        );
        // Scallop cutouts
        for (double dx = -0.7; dx <= 0.71; dx += 0.7) {
          canvas.drawCircle(
            Offset(cx + s * dx, cy - s * 0.3),
            s * 0.24,
            Paint()..color = _gold,
          );
        }
        // Window cutout
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - s * 0.7,
              cy - s * 0.05,
              cx - s * 0.1,
              cy + s * 0.5,
            ),
            Radius.circular(s * 0.08),
          ),
          Paint()..color = _gold,
        );
        // Door cutout
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx + s * 0.1,
              cy - s * 0.05,
              cx + s * 0.75,
              cy + s * 1.0,
            ),
            Radius.circular(s * 0.08),
          ),
          Paint()..color = _gold,
        );
        break;

      case _PinIcon.airplane:
        // Handled externally — standalone pins use _buildAirportIconBytes,
        // pin-with-label overlays the icon after drawing the teardrop.
        break;

      case _PinIcon.none:
        break;
    }
  }

  Future<void> _loadLinkedPayments() async {
    final linked = await LocalDataService.getLinkedPaymentMethods();
    final last4 = await LocalDataService.getCreditCardLast4();
    final brand = await LocalDataService.getCreditCardBrand();
    if (!mounted) return;
    setState(() {
      _linkedPaymentMethods = linked;
      _savedCardLast4 = last4;
      _savedCardBrand = brand;
    });
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

  // ── User location dot — hidden on ride request map ──
  Future<void> _updateUserDotAnnotation() async {
    // No GPS dot shown on this screen — pickup pin already marks the user's location
  }

  // ── Location ──

  Future<void> _initLocation() async {
    try {
      bool svc = await Geolocator.isLocationServiceEnabled();
      if (!svc) {
        setState(() => _fetchingLocation = false);
        return;
      }
      LocationPermission perm = await Geolocator.checkPermission();
      if (perm == LocationPermission.denied) {
        perm = await Geolocator.requestPermission();
      }
      if (perm == LocationPermission.deniedForever) {
        if (mounted) {
          setState(() => _fetchingLocation = false);
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
      if (perm == LocationPermission.denied) {
        setState(() => _fetchingLocation = false);
        return;
      }

      // Fast path: use last known position immediately while waiting for fresh fix
      try {
        final lastPos = await Geolocator.getLastKnownPosition();
        if (lastPos != null && mounted) {
          final lastLl = LatLng(lastPos.latitude, lastPos.longitude);
          setState(() {
            _userLocation = lastLl;
            _center = lastLl;
          });
          _mapCtrl?.setCamera(mapbox.CameraOptions(
            center: mapbox.Point(coordinates: mapbox.Position(lastLl.longitude, lastLl.latitude)),
            zoom: 15.5,
          ));
        }
      } catch (_) {}

      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 10),
        ),
      );
      if (!mounted) return;

      final ll = LatLng(pos.latitude, pos.longitude);
      setState(() {
        _userLocation = ll;
        _center = ll;
        _fetchingLocation = false;
      });
      _mapCtrl?.flyTo(
        mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(ll.longitude, ll.latitude)), zoom: 15.5),
        mapbox.MapAnimationOptions(duration: 800),
      );

      // Reverse geocode for address
      final places = PlacesService(ApiKeys.webServices);
      final addr = await places.reverseGeocode(
        lat: pos.latitude,
        lng: pos.longitude,
      );
      if (addr != null && mounted) {
        setState(() => _currentAddress = addr);
      }
    } catch (_) {
      if (mounted) setState(() => _fetchingLocation = false);
    }
  }

  // ── State updates from controller ──

  bool _didAutoSelectRide = false;

  void _onStateChange() {
    if (!mounted) return;
    final s = _ctrl.state;

    switch (s.phase) {
      case RiderPhase.previewRoute:
      case RiderPhase.selectingRide:
        // Show bottom sheet immediately
        _sheetCtrl.forward();
        // Place markers immediately (no polyline until real route)
        if (s.pickup != null && s.dropoff != null) {
          _placeMarkersOnly();
        }
        // Draw polyline + cinematic only when REAL route arrives (once)
        if (s.route != null && s.route!.points.length > 2) {
          _fetchingRoute = false;
          if (!_cinematicDone) {
            _drawRoute();
          }
        }
        // Mark options as loaded when rideOptions arrive
        if (s.rideOptions.isNotEmpty && !_optionsLoaded) {
          _shimmerTimeoutTimer?.cancel();
          setState(() => _optionsLoaded = true);
        }
        // Auto-select ride option from home screen card tap
        if (!_didAutoSelectRide &&
            widget.initialRideId != null &&
            s.rideOptions.isNotEmpty) {
          _didAutoSelectRide = true;
          final match = s.rideOptions.cast<RideOption?>().firstWhere(
            (o) => o!.id == widget.initialRideId,
            orElse: () => null,
          );
          if (match != null) {
            _ctrl.selectRideOption(match);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) setState(() => _rideOptionsExpanded = false);
            });
          }
        }
        break;
      case RiderPhase.requesting:
      case RiderPhase.searchingDriver:
        // Show map with bottom card immediately — no splash
        if (!_searchingShowMap) {
          _searchMapTimer?.cancel();
          _searchingSplash = false;
          _searchingShowMap = true;
          // Start cycling status messages
          _searchStatusIdx = 0;
          _searchElapsedSec = 0;
          _searchStatusTimer?.cancel();
          _searchStatusTimer = Timer.periodic(const Duration(seconds: 3), (_) {
            if (mounted) {
              setState(() => _searchStatusIdx++);
            }
          });
          _searchElapsedTimer?.cancel();
          _searchElapsedTimer = Timer.periodic(const Duration(seconds: 1), (_) {
            if (mounted) setState(() => _searchElapsedSec++);
          });
          // Trigger cinematic sequence on searching phase open
          _replayCinematicIfRouteAvailable();
        }
        break;
      case RiderPhase.driverAssigned:
        // Show premium "Driver Found" overlay, then auto-navigate after 4s
        if (!_driverFoundVisible && !_navigatingToTracking) {
          _driverFoundVisible = true;
          HapticFeedback.heavyImpact();

          // Init animation controllers
          _dfCheckCtrl?.dispose();
          _dfCheckCtrl = AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 900),
          )..forward();
          _dfStaggerCtrl?.dispose();
          _dfStaggerCtrl = AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 1400),
          )..forward();
          _dfShimmerCtrl?.dispose();
          _dfShimmerCtrl = AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 2000),
          )..repeat();
          _dfMsgIndex = 0;
          _dfMsgTimer?.cancel();
          _dfMsgTimer = Timer.periodic(
            const Duration(milliseconds: 1200),
            (_) {
              if (mounted) setState(() => _dfMsgIndex = (_dfMsgIndex + 1) % 3);
            },
          );

          _driverFoundTimer?.cancel();
          _driverFoundTimer = Timer(const Duration(milliseconds: 4000), () {
            if (!mounted) return;
            _ctrl.transitionToArriving();
          });
        }
        break;
      case RiderPhase.driverArriving:
        if (!_navigatingToTracking) {
          _navigatingToTracking = true;
          _driverFoundVisible = false;
          _driverFoundTimer?.cancel();
          _goToTracking();
        }
        break;
      case RiderPhase.cancelled:
        _searchingShowMap = false;
        _searchingSplash = false;
        _searchMapTimer?.cancel();
        _searchMapTimer = null;
        _splashTimer?.cancel();
        _splashTimer = null;
        // Clean up route/pins immediately on cancellation
        _cleanupMapAnnotations();
        // Only show cancel dialog if there's a specific cancel reason from dispatch
        // (not just "no drivers available" which is automatic)
        if (s.cancelReason != null && s.cancelReason!.isNotEmpty) {
          final reason = s.cancelReason!;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!mounted) return;
            showDialog(
              context: context,
              barrierDismissible: false,
              builder: (_) => AlertDialog(
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                title: Row(
                  children: [
                    Icon(Icons.info_outline, color: Colors.orange, size: 28),
                    SizedBox(width: 10),
                    Text(S.of(context).tripCancelled),
                  ],
                ),
                content: Text(reason, style: const TextStyle(fontSize: 15)),
                actions: [
                  TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _ctrl.reset();
                    },
                    child: Text(S.of(context).okBtn),
                  ),
                ],
              ),
            );
          });
        } else {
          // No cancel reason from dispatch - just reset silently
          _ctrl.reset();
        }
        break;
      default:
        _fetchingRoute = false;
        _searchingShowMap = false;
        _searchingSplash = false;
        _searchMapTimer?.cancel();
        _searchMapTimer = null;
        _splashTimer?.cancel();
        _splashTimer = null;
        break;
    }
    setState(() {});
  }

  void _drawRoute() {
    final s = _ctrl.state;
    if (s.route == null) return;
    _showPinLabels = true;
    // Force polyline endpoints to land exactly on the pickup/dropoff pins
    final pts = List<LatLng>.from(s.route!.points);
    if (pts.isNotEmpty && s.pickup != null) pts[0] = LatLng(s.pickup!.lat, s.pickup!.lng);
    if (pts.isNotEmpty && s.dropoff != null) pts[pts.length - 1] = LatLng(s.dropoff!.lat, s.dropoff!.lng);
    _buildRouteMarkers();
    // Always replay cinematic — reset state and re-trigger
    _resetCinematic();
    _startCinematicSequence(pts);
  }

  /// Reset all cinematic animation state so sequence can replay from scratch.
  Future<void> _resetCinematic() async {
    _cinematicDone = false;
    _hasAppliedSelectionTilt = false;
    _labelsRevealed = false;

    // Stop running controllers
    _tiltCtrl?.stop();
    _bearingCtrl?.stop();
    _pinPopCtrl?.stop();
    _labelPopCtrl?.stop();
    _routeDrawTicker?.stop();

    // Clear existing route annotations so they redraw fresh
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr != null) {
      if (_routeAnnot != null) { try { await polyMgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }
    }

    // Reset camera to flat so tilt animates from 0°
    if (_mapCtrl != null) {
      _mapCtrl!.setCamera(mapbox.CameraOptions(pitch: 0, bearing: 0));
    }
  }

  /// Replay cinematic if route data is available (used by searching phase).
  /// Only triggers if cinematic hasn't already played.
  void _replayCinematicIfRouteAvailable() {
    if (_cinematicDone) return;
    final route = _ctrl.state.route;
    if (route == null || route.points.isEmpty) return;
    final pts = List<LatLng>.from(route.points);
    final s = _ctrl.state;
    if (pts.isNotEmpty && s.pickup != null) pts[0] = LatLng(s.pickup!.lat, s.pickup!.lng);
    if (pts.isNotEmpty && s.dropoff != null) pts[pts.length - 1] = LatLng(s.dropoff!.lat, s.dropoff!.lng);
    _showPinLabels = true;
    _buildRouteMarkers();
    _resetCinematic();
    _startCinematicSequence(pts);
  }

  /// Cinematic map animation: fit → tilt 55° + random bearing → pin pop → gold route draw → glow
  Future<void> _startCinematicSequence(List<LatLng> pts) async {
    if (!mounted || _mapCtrl == null) return;

    // Generate random bearing 5-15° left or right
    final rng = math.Random();
    final degrees = 5.0 + rng.nextDouble() * 10.0;
    _randomBearing = degrees * (rng.nextBool() ? 1.0 : -1.0);

    // 1. Fit camera to full route (flat, no tilt yet)
    _fitRoute(pts);
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;

    // 2. Tilt 0° → 55° + bearing 0° → random, simultaneously (1200ms)
    _tiltCtrl?.dispose();
    _tiltCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _tiltAnim = Tween<double>(begin: 0.0, end: 55.0).animate(
      CurvedAnimation(parent: _tiltCtrl!, curve: Curves.easeInOutCubic),
    );
    _bearingCtrl?.dispose();
    _bearingCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _bearingAnim = Tween<double>(begin: 0.0, end: _randomBearing).animate(
      CurvedAnimation(parent: _bearingCtrl!, curve: Curves.easeInOutCubic),
    );
    _tiltAnim!.addListener(_applyMapCamera);
    _tiltCtrl!.forward(from: 0);
    _bearingCtrl!.forward(from: 0);

    // 3. Pin pop at 500ms into tilt
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    _startPinPop();

    // 3b. Label bubbles unroll 400ms after pin pop starts
    await Future.delayed(const Duration(milliseconds: 400));
    if (!mounted) return;
    _unrollLabels();

    // 4. Gold route draws at 200ms after labels start
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    await _animateGoldRoute(pts, const Duration(milliseconds: 1000));
    if (!mounted) return;

    _cinematicDone = true;
  }

  void _applyMapCamera() {
    if (_mapCtrl == null || !mounted) return;
    _mapCtrl!.setCamera(mapbox.CameraOptions(
      pitch: _tiltAnim?.value,
      bearing: _bearingAnim?.value,
    ));
  }

  void _startPinPop() {
    _pinPopCtrl?.dispose();
    _pinPopCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 500));
    _pinPopAnim = TweenSequence<double>([
      TweenSequenceItem(
        tween: Tween(begin: 0.01, end: 1.15).chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 60,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 1.15, end: 0.95).chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      TweenSequenceItem(
        tween: Tween(begin: 0.95, end: 1.0).chain(CurveTween(curve: Curves.elasticOut)),
        weight: 20,
      ),
    ]).animate(_pinPopCtrl!);
    _pinPopAnim!.addListener(_updatePinScales);
    _pinPopCtrl!.forward(from: 0);
  }

  void _updatePinScales() {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    final s = _pinPopAnim?.value ?? 1.0;
    if (_pickupAnnot != null) {
      _pickupAnnot!.iconSize = s * 0.85;
      mgr.update(_pickupAnnot!);
    }
    if (_dropoffAnnot != null) {
      _dropoffAnnot!.iconSize = s * 0.85;
      mgr.update(_dropoffAnnot!);
    }
  }

  /// Swap pin-only bitmaps to pin+label bitmaps with a spring scale animation.
  /// Creates the effect of address labels "unrolling" from the pin.
  void _unrollLabels() {
    if (_labelsRevealed) return;
    _labelsRevealed = true;

    // Swap annotations to pin+label bitmaps
    _swapToLabelBitmaps();

    // Spring animation: shrink slightly then pop to full size
    _labelPopCtrl?.dispose();
    _labelPopCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _labelPopAnim = TweenSequence<double>([
      // Shrink from current scale to accommodate wider bitmap
      TweenSequenceItem(
        tween: Tween(begin: 0.40, end: 0.92)
            .chain(CurveTween(curve: Curves.easeOutCubic)),
        weight: 55,
      ),
      // Overshoot
      TweenSequenceItem(
        tween: Tween(begin: 0.92, end: 0.82)
            .chain(CurveTween(curve: Curves.easeInOut)),
        weight: 20,
      ),
      // Settle
      TweenSequenceItem(
        tween: Tween(begin: 0.82, end: 0.85)
            .chain(CurveTween(curve: Curves.elasticOut)),
        weight: 25,
      ),
    ]).animate(_labelPopCtrl!);
    _labelPopAnim!.addListener(_updateLabelScales);
    _labelPopCtrl!.forward(from: 0);
  }

  void _updateLabelScales() {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    final s = _labelPopAnim?.value ?? 0.85;
    if (_pickupAnnot != null) {
      _pickupAnnot!.iconSize = s;
      mgr.update(_pickupAnnot!);
    }
    if (_dropoffAnnot != null) {
      _dropoffAnnot!.iconSize = s;
      mgr.update(_dropoffAnnot!);
    }
  }

  Future<void> _swapToLabelBitmaps() async {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;

    // Swap pickup to pin+label
    if (_pickupAnnot != null && _showPinLabels && _pickupPinWithLabel != null) {
      _pickupAnnot!.image = _pickupPinWithLabel!.$1;
      mgr.update(_pickupAnnot!);
    }

    // Swap dropoff to pin+label (200ms later for staggered effect)
    await Future.delayed(const Duration(milliseconds: 200));
    if (!mounted) return;
    if (_dropoffAnnot != null && _showPinLabels && _dropoffPinWithLabel != null) {
      _dropoffAnnot!.image = _dropoffPinWithLabel!.$1;
      mgr.update(_dropoffAnnot!);
    }
  }

  /// Animate 4-layer gold gloss route draw at 60fps
  Future<void> _animateGoldRoute(List<LatLng> points, Duration duration) async {
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null || points.length < 2) return;

    // Clear old single-color route if present
    if (_routeAnnot != null) { try { await polyMgr.delete(_routeAnnot!); } catch (_) {} _routeAnnot = null; }

    final completer = Completer<void>();
    final stopwatch = Stopwatch()..start();
    final totalMs = duration.inMilliseconds;
    int lastCount = 0;

    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = createTicker((_) async {
      if (!mounted) {
        _routeDrawTicker?.stop();
        if (!completer.isCompleted) completer.complete();
        return;
      }
      final elapsed = stopwatch.elapsedMilliseconds;
      final progress = (elapsed / totalMs).clamp(0.0, 1.0);
      final eased = Curves.easeInOutSine.transform(progress);
      final count = (eased * points.length).round().clamp(2, points.length);

      if (count != lastCount) {
        lastCount = count;
        final subset = points.sublist(0, count);
        final coords = subset.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final geo = mapbox.LineString(coordinates: coords);

        if (_routeAnnot == null) {
          _routeAnnot = await polyMgr.create(mapbox.PolylineAnnotationOptions(
            geometry: geo, lineColor: const Color(0xFFFFD700).toARGB32(), lineWidth: 5.0, lineJoin: mapbox.LineJoin.ROUND,
          ));
        } else {
          _routeAnnot!.geometry = geo; await polyMgr.update(_routeAnnot!);
        }
      }
      if (progress >= 1.0) {
        _routeDrawTicker?.stop();
        final fullCoords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
        final fullGeo = mapbox.LineString(coordinates: fullCoords);
        if (_routeAnnot != null) { _routeAnnot!.geometry = fullGeo; await polyMgr.update(_routeAnnot!); }
        if (!completer.isCompleted) completer.complete();
      }
    });
    _routeDrawTicker!.start();
    return completer.future;
  }

  Future<void> _updateRouteAnnotation(List<LatLng> points) async {
    final mgr = _polylineAnnotMgr;
    if (mgr == null) return;
    // Update single gold line if it exists
    if (_routeAnnot != null) {
      if (points.isEmpty) return;
      final coords = points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
      final geo = mapbox.LineString(coordinates: coords);
      _routeAnnot!.geometry = geo; await mgr.update(_routeAnnot!);
      return;
    }
    // Fallback: create new single-line route
    if (points.isEmpty) return;
    _routeAnnot = await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: mapbox.LineString(coordinates: points.map((p) => mapbox.Position(p.longitude, p.latitude)).toList()),
      lineColor: const Color(0xFFFFD700).toARGB32(),
      lineWidth: 5.0,
    ));
  }

  /// Place pickup/dropoff markers immediately and fit camera, even before route loads.
  Future<void> _placeMarkersOnly() async {
    final s = _ctrl.state;
    if (s.pickup == null || s.dropoff == null) return;
    final mgr = _pointAnnotMgr;
    if (mgr == null || _goldPinIcon == null) return;

    // Simple gold pin for pickup
    _pickupAnnot ??= await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(s.pickup!.lng, s.pickup!.lat)),
      image: _goldPinIcon!,
      iconSize: 0.85,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
    // Simple gold pin for dropoff
    _dropoffAnnot ??= await mgr.create(mapbox.PointAnnotationOptions(
      geometry: mapbox.Point(coordinates: mapbox.Position(s.dropoff!.lng, s.dropoff!.lat)),
      image: _goldPinIcon!,
      iconSize: 0.85,
      iconAnchor: mapbox.IconAnchor.BOTTOM,
    ));
    // Fit camera to show both markers
    _fitRoute([
      LatLng(s.pickup!.lat, s.pickup!.lng),
      LatLng(s.dropoff!.lat, s.dropoff!.lng),
    ]);
    if (mounted) setState(() {});
  }

  Future<void> _buildRouteMarkers() async {
    final s = _ctrl.state;
    if (s.route == null) return;

    // Detect dropoff type from address
    final dropoffIcon = _detectDropoffType(s.dropoffLabel);

    // Build all 4 variants: pin-only and pin+label for pickup and dropoff
    _pickupPinOnly = await _buildStandalonePin(
      icon: _PinIcon.person,
      isPickup: true,
    );
    _pickupPinWithLabel = await _buildPinWithLabel(
      text: s.pickupLabel.isNotEmpty ? s.pickupLabel : 'Pickup',
      isPickup: true,
      icon: _PinIcon.person,
      labelOnLeft: false, // label on RIGHT of pickup pin
    );
    _dropoffPinOnly = await _buildStandalonePin(
      icon: dropoffIcon,
      isPickup: false,
    );
    _dropoffPinWithLabel = await _buildPinWithLabel(
      text: s.dropoffLabel.isNotEmpty ? s.dropoffLabel : 'Dropoff',
      isPickup: false,
      etaText: s.route!.durationText,
      icon: dropoffIcon,
      labelOnLeft: true, // label on LEFT of dropoff pin
    );

    if (!mounted) return;
    _rebuildMarkers();
  }

  Future<void> _rebuildMarkers() async {
    final s = _ctrl.state;
    if (s.route == null) return;
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;

    // During cinematic, pins start tiny and use pin-ONLY bitmaps (labels animate in later)
    final scale = (!_cinematicDone || (_pinPopCtrl?.isAnimating ?? false)) ? 0.01 : 0.85;
    final useLabels = _labelsRevealed;

    // Pickup marker
    if (_pickupAnnot != null) { try { await mgr.delete(_pickupAnnot!); } catch (_) {} _pickupAnnot = null; }
    if (s.pickup != null) {
      Uint8List? bytes;
      if (useLabels && _showPinLabels && _pickupPinWithLabel != null) {
        bytes = _pickupPinWithLabel!.$1;
      } else if (_pickupPinOnly != null) {
        bytes = _pickupPinOnly!.$1;
      } else {
        bytes = _goldPinIcon;
      }
      if (bytes != null) {
        _pickupAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(s.pickup!.lng, s.pickup!.lat)),
          image: bytes,
          iconSize: scale,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
    }

    // Dropoff marker
    if (_dropoffAnnot != null) { try { await mgr.delete(_dropoffAnnot!); } catch (_) {} _dropoffAnnot = null; }
    if (s.dropoff != null) {
      Uint8List? bytes;
      if (useLabels && _showPinLabels && _dropoffPinWithLabel != null) {
        bytes = _dropoffPinWithLabel!.$1;
      } else if (_dropoffPinOnly != null) {
        bytes = _dropoffPinOnly!.$1;
      } else {
        bytes = _goldPinIcon;
      }
      if (bytes != null) {
        _dropoffAnnot = await mgr.create(mapbox.PointAnnotationOptions(
          geometry: mapbox.Point(coordinates: mapbox.Position(s.dropoff!.lng, s.dropoff!.lat)),
          image: bytes,
          iconSize: scale,
          iconAnchor: mapbox.IconAnchor.BOTTOM,
          iconOffset: [0, 0],
        ));
      }
    }
    if (mounted) setState(() {});
  }

  // Labels always visible — no toggle behavior
  void _togglePinLabels() {}

  void _fitRoute(List<LatLng> pts, {bool preserveCamera = false}) {
    if (pts.isEmpty || _mapCtrl == null) return;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    final screenH = MediaQuery.of(context).size.height;
    final botPad = MediaQuery.of(context).padding.bottom;
    final phase = _ctrl.state.phase;
    // Bottom padding must account for full panel height + safe area + margin
    final double bottomPad;
    if (phase == RiderPhase.requesting || phase == RiderPhase.searchingDriver) {
      bottomPad = 180 + botPad + 20;
    } else {
      // Route preview sheet: 45% of screen (clamped 320-420) + safe area + margin
      final sheetH = (screenH * 0.45).clamp(320.0, 420.0) + botPad;
      bottomPad = sheetH + 20;
    }
    _mapCtrl!.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(minLng, minLat)),
       mapbox.Point(coordinates: mapbox.Position(maxLng, maxLat))],
      mapbox.CameraOptions(
        pitch: preserveCamera ? 55.0 : null,
        bearing: preserveCamera ? _randomBearing : null,
      ),
      mapbox.MbxEdgeInsets(top: 80, left: 60, bottom: bottomPad, right: 60),
      null, null,
    ).then((cam) {
      _mapCtrl?.flyTo(cam, mapbox.MapAnimationOptions(duration: 900));
    });
  }

  void _goToTracking() {
    final s = _ctrl.state;
    if (s.pickup == null || s.dropoff == null) {
      _navigatingToTracking = false;
      return;
    }

    // Persist active ride so home screen can show "Resume" banner
    final routePts =
        s.route?.points.map((p) => [p.latitude, p.longitude]).toList() ?? [];
    LocalDataService.setActiveRide(
      ActiveRideInfo(
        pickupLat: s.pickup!.lat,
        pickupLng: s.pickup!.lng,
        dropoffLat: s.dropoff!.lat,
        dropoffLng: s.dropoff!.lng,
        pickupLabel: s.pickupLabel,
        dropoffLabel: s.dropoffLabel,
        driverName: s.driver?.name ?? 'Driver',
        driverRating: s.driver?.rating ?? 4.9,
        vehicleMake: s.driver?.vehicleMake ?? 'Toyota',
        vehicleModel: s.driver?.vehicleModel ?? 'Camry',
        vehicleColor: s.driver?.vehicleColor ?? 'White',
        vehiclePlate: s.driver?.vehiclePlate ?? 'ABC-1234',
        vehicleYear: s.driver?.vehicleYear ?? '2022',
        rideName: s.selectedOption?.name ?? 'Fusion',
        price: s.selectedOption?.priceEstimate ?? 0,
        routePoints: routePts,
        tripId: s.tripId,
        firestoreTripId: s.firestoreTripId,
        driverPhotoUrl: s.driver?.photoUrl,
        etaMinutes: s.selectedOption?.etaMinutes,
      ),
    );

    Navigator.of(context).push(
      slideUpFadeRoute(
        RiderTrackingScreen(
          pickupLatLng: LatLng(s.pickup!.lat, s.pickup!.lng),
          dropoffLatLng: LatLng(s.dropoff!.lat, s.dropoff!.lng),
          routePoints: s.route?.points,
          driverName: s.driver?.name ?? 'Driver',
          driverRating: s.driver?.rating ?? 4.9,
          driverPhotoUrl: s.driver?.photoUrl,
          vehicleMake: s.driver?.vehicleMake ?? 'Toyota',
          vehicleModel: s.driver?.vehicleModel ?? 'Camry',
          vehicleColor: s.driver?.vehicleColor ?? 'White',
          vehiclePlate: s.driver?.vehiclePlate ?? 'ABC-1234',
          vehicleYear: s.driver?.vehicleYear ?? '2022',
          rideName: s.selectedOption?.name ?? 'Fusion',
          price: s.selectedOption?.priceEstimate ?? 0,
          pickupLabel: s.pickupLabel,
          dropoffLabel: s.dropoffLabel,
          tripId: s.tripId,
          firestoreTripId: s.firestoreTripId,
          onTripComplete: () {
            LocalDataService.clearActiveRide();
            // Pop RiderTrackingScreen, then pop RideRequestScreen
            // to return to HomeScreen (Where to? + car options)
            Navigator.of(context).pop(); // pop tracking
            Navigator.of(context).pop(); // pop ride request → back to home
          },
        ),
      ),
    );
  }

  // ── Search screen ──

  Future<void> _openSearch() async {
    final result = await Navigator.of(context).push<Map<String, dynamic>>(
      scaleExpandRoute(
        PickupDropoffSearchScreen(
          initialPickupText: _currentAddress,
          initialPickupLat: _userLocation?.latitude,
          initialPickupLng: _userLocation?.longitude,
        ),
      ),
    );

    if (result == null || !mounted) return;

    final pickupDetails = result['pickup'] as PlaceDetails?;
    final dropoffDetails = result['dropoff'] as PlaceDetails?;
    final pickupLabel = result['pickupLabel'] as String? ?? '';
    final dropoffLabel = result['dropoffLabel'] as String? ?? '';

    // Ensure loading overlay is up (already set by onWillReturn, but guard here too)
    if (!_fetchingRoute) setState(() => _fetchingRoute = true);

    if (pickupDetails != null) {
      _ctrl.setPickup(pickupDetails, pickupLabel);
    } else if (_userLocation != null) {
      // Use current location as pickup
      _ctrl.setPickup(
        PlaceDetails(
          address: _currentAddress,
          lat: _userLocation!.latitude,
          lng: _userLocation!.longitude,
        ),
        _currentAddress,
      );
    }

    if (dropoffDetails != null) {
      _ctrl.setDropoff(dropoffDetails, dropoffLabel);
    }
  }

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

    return AnnotatedRegion<SystemUiOverlayStyle>(
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
                    pitch: 0.0,
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
                    _updateUserDotAnnotation();
                    setState(() => _mapReady = true);
                  },
                  onStyleLoadedListener: (_) async {
                    if (_mapCtrl != null) await _applyDarkNavyGoldTheme(_mapCtrl!);
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
                  opacity: phase != RiderPhase.idle ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  child: IgnorePointer(
                    ignoring: phase == RiderPhase.idle,
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
    );
  }

  double _bottomSheetHeight(RiderPhase phase, double bottomPad) {
    switch (phase) {
      case RiderPhase.previewRoute:
      case RiderPhase.selectingRide:
        final screenH = MediaQuery.of(context).size.height;
        final h = (screenH * 0.45).clamp(320.0, 420.0);
        return h + bottomPad;
      case RiderPhase.requesting:
      case RiderPhase.searchingDriver:
        return 180 + bottomPad;
      default:
        return 0;
    }
  }

  // ── "Where to?" bar ──

  String get _rideBadgeLabel {
    if (widget.isAirportTrip) return S.of(context).airportLabel;
    if (widget.scheduledAt != null) return S.of(context).scheduleLabel;
    return S.of(context).nowLabel;
  }

  IconData get _rideBadgeIcon {
    if (widget.isAirportTrip) return Icons.flight_takeoff_rounded;
    if (widget.scheduledAt != null) return Icons.schedule_rounded;
    return Icons.access_time_rounded;
  }

  Widget _buildWhereToBar(AppColors c, double topPad, bool visible) {
    return Positioned(
      top: topPad + 12,
      left: 16,
      right: 16,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 250),
        curve: Curves.easeOutCubic,
        offset: visible ? Offset.zero : const Offset(0, -1.5),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 200),
          opacity: visible ? 1.0 : 0.0,
          child: IgnorePointer(
            ignoring: !visible,
            child: Row(
              children: [
                // ── Back arrow ──
                GestureDetector(
                  onTap: () => Navigator.of(context).pop(),
                  child: Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: const Color(0xFF1A1A1A),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.25),
                          blurRadius: 12,
                          offset: const Offset(0, 3),
                        ),
                      ],
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                    ),
                    child: const Icon(
                      Icons.arrow_back_ios_new_rounded,
                      color: Colors.white,
                      size: 18,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                // ── Search pill ──
                Expanded(
                  child: GestureDetector(
                    onTap: _openSearch,
                    child: Container(
                      height: 52,
                      decoration: BoxDecoration(
                        color: const Color(0xFF1A1A1A),
                        borderRadius: BorderRadius.circular(26),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.25),
                            blurRadius: 16,
                            offset: const Offset(0, 4),
                          ),
                        ],
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.06),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        children: [
                          const SizedBox(width: 16),
                          Icon(Icons.search_rounded, color: c.gold, size: 22),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              S.of(context).whereToQuestion,
                              style: TextStyle(
                                fontSize: 17,
                                fontWeight: FontWeight.w600,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                            ),
                          ),
                          // Dynamic badge: Now / Schedule / Airport
                          Container(
                            margin: const EdgeInsets.only(right: 6),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: c.gold.withValues(alpha: 0.12),
                              borderRadius: BorderRadius.circular(16),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(_rideBadgeIcon, color: c.gold, size: 16),
                                const SizedBox(width: 4),
                                Text(
                                  _rideBadgeLabel,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w600,
                                    color: c.gold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Route preview sheet ──

  Widget _buildRoutePreviewSheet(AppColors c, double bottomPad) {
    final s = _ctrl.state;

    // Fast ride: show only one "Comfort" option with express pricing (~$2.67/min ≈ $160/hr)
    List<RideOption> displayOptions = s.rideOptions;
    if (widget.fastRide && s.rideOptions.isNotEmpty) {
      final baseFusion = s.rideOptions.last; // Fusion = cheapest = base
      final expressPrice = (baseFusion.priceEstimate * 3.2)
          .roundToDouble(); // ~$160/hr rate
      displayOptions = [
        RideOption(
          id: 'comfort_express',
          name: 'Comfort',
          description: 'Express pickup · Premium',
          priceEstimate: expressPrice,
          etaMinutes: 2 + (baseFusion.etaMinutes ~/ 3),
          icon: '⚡',
          capacity: 4,
        ),
      ];
    }

    // Apply 10% promo discount
    if (widget.applyPromo) {
      displayOptions = displayOptions
          .map(
            (o) => RideOption(
              id: o.id,
              name: o.name,
              description: o.description,
              priceEstimate:
                  (o.priceEstimate * 0.9 * 100).roundToDouble() / 100,
              etaMinutes: o.etaMinutes,
              icon: o.icon,
              capacity: o.capacity,
            ),
          )
          .toList();
    }

    final option = widget.fastRide
        ? (displayOptions.isNotEmpty ? displayOptions.first : s.selectedOption)
        : s.selectedOption;
    final screenH = MediaQuery.of(context).size.height;
    final sheetH = (screenH * 0.45).clamp(320.0, 420.0) + bottomPad;

    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: AnimatedBuilder(
        animation: _sheetCtrl,
        builder: (context, child) {
          return Transform.translate(
            offset: Offset(0, _sheetSlide.value * sheetH),
            child: child,
          );
        },
        child: Container(
          constraints: BoxConstraints(maxHeight: sheetH),
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            color: const Color(0xFF1A1A1A),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: SafeArea(
            top: false,
            child: SingleChildScrollView(
              physics: const ClampingScrollPhysics(),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Drag handle
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Title — tappable to collapse/expand
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 18),
                    child: GestureDetector(
                      onTap: () => setState(
                        () => _rideOptionsExpanded = !_rideOptionsExpanded,
                      ),
                      behavior: HitTestBehavior.opaque,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Spacer(),
                          Text(
                            widget.fastRide
                                ? S.of(context).fastRideLabel
                                : S.of(context).chooseARide,
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w800,
                              color: Colors.white.withValues(alpha: 0.9),
                              letterSpacing: -0.3,
                            ),
                          ),
                          if (_ctrl.state.isAirportTrip) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFF4285F4,
                                ).withValues(alpha: 0.15),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(
                                    Icons.flight_rounded,
                                    size: 12,
                                    color: Color(0xFF4285F4),
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    S.of(context).airportLabel,
                                    style: TextStyle(
                                      color: Color(0xFF4285F4),
                                      fontSize: 11,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (widget.applyPromo) ...[
                            const SizedBox(width: 8),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFE8C547,
                                ).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: const Text(
                                '10% OFF',
                                style: TextStyle(
                                  color: Color(0xFFE8C547),
                                  fontSize: 11,
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                          ],
                          const Spacer(),
                          if (!widget.fastRide)
                            AnimatedRotation(
                              turns: _rideOptionsExpanded ? 0.0 : -0.25,
                              duration: const Duration(milliseconds: 250),
                              curve: Curves.easeInOut,
                              child: Icon(
                                Icons.keyboard_arrow_down_rounded,
                                color: Colors.white.withValues(alpha: 0.5),
                                size: 22,
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // Ride options list — collapsible
                  AnimatedCrossFade(
                    firstChild: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Route failed → show retry
                          if (_ctrl.state.routeFetchFailed && displayOptions.isEmpty)
                            _buildRouteFailedRetry()
                          // Loading → shimmer placeholders
                          else if (displayOptions.isEmpty)
                            for (int i = 0; i < 3; i++) ...[
                              _buildShimmerCard(),
                              if (i < 2) const SizedBox(height: 6),
                            ]
                          // Real options — staggered slide-up entrance
                          else
                            for (int i = 0; i < displayOptions.length; i++) ...[
                              TweenAnimationBuilder<double>(
                                key: ValueKey('ride_opt_${displayOptions[i].id}'),
                                tween: Tween(begin: 0.0, end: 1.0),
                                duration: const Duration(milliseconds: 350),
                                curve: Curves.easeOutCubic,
                                builder: (context, val, child) {
                                  // Stagger: each card waits 80ms * index
                                  final delay = i * 0.15; // 0.15 of total duration per card
                                  final progress = ((val - delay) / (1.0 - delay)).clamp(0.0, 1.0);
                                  return Transform.translate(
                                    offset: Offset(0, 20 * (1.0 - progress)),
                                    child: Opacity(
                                      opacity: progress,
                                      child: child,
                                    ),
                                  );
                                },
                                child: GestureDetector(
                                  onTap: () {
                                    _ctrl.selectRideOption(displayOptions[i]);
                                    // Auto-collapse immediately after selecting
                                    setState(
                                      () => _rideOptionsExpanded = false,
                                    );
                                    // Single gentle 15° tilt — only once
                                    if (!_hasAppliedSelectionTilt && _mapCtrl != null) {
                                      _hasAppliedSelectionTilt = true;
                                      _mapCtrl!.flyTo(
                                        mapbox.CameraOptions(pitch: 15.0),
                                        mapbox.MapAnimationOptions(duration: 800),
                                      );
                                    }
                                  },
                                  child: _buildRideOptionCard(
                                    c,
                                    displayOptions[i],
                                    option?.id == displayOptions[i].id,
                                  ),
                                ),
                              ),
                              if (i < displayOptions.length - 1)
                                const SizedBox(height: 6),
                            ],
                        ],
                      ),
                    ),
                    secondChild: option != null
                        ? GestureDetector(
                            onTap: () =>
                                setState(() => _rideOptionsExpanded = true),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 16,
                              ),
                              child: _buildRideOptionCard(c, option, true),
                            ),
                          )
                        : const SizedBox.shrink(),
                    crossFadeState: _rideOptionsExpanded
                        ? CrossFadeState.showFirst
                        : CrossFadeState.showSecond,
                    duration: const Duration(milliseconds: 300),
                    sizeCurve: Curves.easeInOutCubic,
                  ),

                  const SizedBox(height: 6),
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  const SizedBox(height: 6),

                  // Payment Method + Request Ride buttons — hidden during shimmer, fade in when ready
                  AnimatedOpacity(
                    opacity: _optionsLoaded ? 1.0 : 0.0,
                    duration: const Duration(milliseconds: 300),
                    curve: Curves.easeInOut,
                    child: AnimatedSize(
                      duration: const Duration(milliseconds: 300),
                      curve: Curves.easeInOut,
                      child: _optionsLoaded
                          ? Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Payment Method — dark gray fill
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20),
                                  child: GestureDetector(
                                    onTap: () => _showPaymentMethodPicker(c, option),
                                    child: Container(
                                      width: double.infinity,
                                      height: 52,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFF2A2A2A),
                                        borderRadius: BorderRadius.circular(14),
                                      ),
                                      child: const Row(
                                        mainAxisAlignment: MainAxisAlignment.center,
                                        children: [
                                          Text(
                                            'Payment Method',
                                            style: TextStyle(
                                              color: Colors.white,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                              letterSpacing: 0.2,
                                            ),
                                          ),
                                          SizedBox(width: 6),
                                          Icon(
                                            Icons.chevron_right,
                                            color: Colors.white,
                                            size: 18,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),

                                // Request Ride button — flat 2D, gold border
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20),
                                  child: AnimatedBuilder(
                                    animation: _shakeAnim,
                                    builder: (_, child) => Transform.translate(
                                      offset: Offset(_shakeAnim.value, 0),
                                      child: child,
                                    ),
                                    child: GestureDetector(
                                      onTap: option != null && !_isProcessingPayment
                                          ? () => _startRideDirectly(c, option)
                                          : option == null && !_isProcessingPayment
                                              ? () => _shakeCtrl.forward(from: 0)
                                              : null,
                                      child: Container(
                                        width: double.infinity,
                                        height: 56,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF0D0D0D),
                                          borderRadius: BorderRadius.circular(14),
                                          border: Border.all(
                                            color: option != null
                                                ? const Color(0xFFFFD700)
                                                : const Color(0xFFFFD700).withValues(alpha: 0.3),
                                            width: 1.5,
                                          ),
                                        ),
                                        child: _isProcessingPayment
                                            ? const Center(
                                                child: SizedBox(
                                                  width: 24,
                                                  height: 24,
                                                  child: CircularProgressIndicator(
                                                    strokeWidth: 2.5,
                                                    color: Colors.white70,
                                                  ),
                                                ),
                                              )
                                            : Padding(
                                                padding: const EdgeInsets.symmetric(horizontal: 20),
                                                child: Row(
                                                  children: [
                                                    _buildPaymentLogo(),
                                                    const SizedBox(width: 8),
                                                    Expanded(
                                                      child: AnimatedSwitcher(
                                                        duration: const Duration(milliseconds: 300),
                                                        child: Text(
                                                          option != null
                                                              ? 'Pay · \$${option.priceEstimate.toStringAsFixed(2)}'
                                                              : S.of(context).pickYourOption,
                                                          key: ValueKey(option?.id),
                                                          maxLines: 1,
                                                          overflow: TextOverflow.ellipsis,
                                                          style: TextStyle(
                                                            color: option != null
                                                                ? Colors.white
                                                                : Colors.white38,
                                                            fontSize: 16,
                                                            fontWeight: FontWeight.w700,
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
                              ],
                            )
                          : const SizedBox.shrink(),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  static const _cardGold = Color(0xFFE8C547);

  static int _parseDurationMins(String text) {
    final parts = text.split(RegExp(r'\s+'));
    int total = 0;
    for (int i = 0; i < parts.length; i++) {
      final n = int.tryParse(parts[i]);
      if (n != null && i + 1 < parts.length) {
        if (parts[i + 1].startsWith('h')) {
          total += n * 60;
        } else {
          total += n;
        }
      }
    }
    return total > 0 ? total : 10;
  }

  static String _carAssetForOption(String name) {
    final key = name.trim().toLowerCase();
    if (key.contains('vip') || key.contains('suburban')) return 'assets/images/cruise_3.png';
    if (key.contains('sedan') || key.contains('camry')) return 'assets/images/cruise_7.png';
    return 'assets/images/cruise_6.png';
  }

  Widget _buildRideOptionCard(AppColors c, RideOption opt, bool selected) {
    final isSuv = opt.id == 'suburban';
    final isFusion = opt.id == 'fusion';

    // Tier styling — match home_screen badge colors exactly
    final bool isVIP = isSuv;
    final bool isPremium = !isSuv && !isFusion;
    final bool isComfort = isFusion;
    final String tierLabel = isVIP ? 'VIP' : isPremium ? 'PREMIUM' : 'COMFORT';
    final List<Color> gradient = isVIP
        ? const [Color(0xFFE8C547), Color(0xFFD4A574)]
        : isPremium
            ? const [Color(0xFFE8E8E8), Color(0xFFB0B0B0)]
            : const [Color(0xFF66BB6A), Color(0xFF388E3C)];
    final Color accent = gradient[0];
    final IconData tierIcon = isVIP
        ? Icons.star_rounded
        : isPremium
            ? Icons.diamond_rounded
            : Icons.eco_rounded;
    final Color tierTextColor = isVIP ? Colors.white : Colors.black87;
    final AnimationController badgeAnim = isVIP
        ? _shimmerCtrl
        : isPremium
            ? _badgePremiumCtrl
            : _badgeComfortCtrl;

    return AnimatedScale(
      scale: selected ? 1.0 : 0.97,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutBack,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: selected
            ? Colors.white.withValues(alpha: 0.08)
            : const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: selected
              ? _cardGold.withValues(alpha: 0.55)
              : Colors.white.withValues(alpha: 0.06),
          width: selected ? 1.5 : 1.0,
        ),
        boxShadow: selected
            ? [
                BoxShadow(
                  color: _cardGold.withValues(alpha: 0.15),
                  blurRadius: 20,
                  offset: const Offset(0, 4),
                ),
              ]
            : [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.20),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
      ),
      child: Row(
        children: [
          // Car image — HD crisp rendering
          SizedBox(
            width: 108,
            height: 72,
            child: Image.asset(
              _carAssetForOption(opt.name),
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              isAntiAlias: true,
              alignment: Alignment.center,
              cacheWidth: 216,
              errorBuilder: (_, e, s) => Icon(
                Icons.directions_car_rounded,
                size: 36,
                color: Colors.white.withValues(alpha: 0.5),
              ),
            ),
          ),
          const SizedBox(width: 10),

          // Info column
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Tier badge — animated gradient pill (matches home_screen)
                AnimatedBuilder(
                  animation: badgeAnim,
                  builder: (_, __) {
                    final t = badgeAnim.value;
                    return Stack(
                      alignment: Alignment.center,
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
                          decoration: BoxDecoration(
                            gradient: LinearGradient(colors: gradient),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.45),
                                blurRadius: 14,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(tierIcon, color: tierTextColor, size: 12),
                              const SizedBox(width: 5),
                              Text(
                                tierLabel,
                                style: TextStyle(
                                  color: tierTextColor,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                        // VIP: diagonal shimmer sweep
                        if (isVIP)
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: IgnorePointer(
                                child: Transform.translate(
                                  offset: Offset(160 * (t * 2.4 - 0.8), 0),
                                  child: Transform.rotate(
                                    angle: 0.4,
                                    child: Container(
                                      width: 28,
                                      decoration: BoxDecoration(
                                        gradient: LinearGradient(colors: [
                                          Colors.transparent,
                                          Colors.white.withValues(alpha: 0.55),
                                          Colors.transparent,
                                        ]),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        // Premium: white flash pulse
                        if (isPremium)
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: (() {
                                    final d = (t - 0.5).abs();
                                    return (1.0 - d * 5.5).clamp(0.0, 0.35);
                                  })(),
                                  child: Container(color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                        // Comfort: green glow pulse
                        if (isComfort)
                          Positioned.fill(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(20),
                              child: IgnorePointer(
                                child: Opacity(
                                  opacity: (0.12 + 0.18 * math.sin(t * 2 * math.pi)).clamp(0.0, 0.35),
                                  child: Container(color: accent),
                                ),
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 2),
                // Description
                Text(
                  opt.description,
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.45),
                    fontWeight: FontWeight.w400,
                  ),
                ),
                const SizedBox(height: 4),
                // Trip time + arrival time
                Builder(
                  builder: (_) {
                    final routeMins = _ctrl.state.route != null
                        ? _parseDurationMins(_ctrl.state.route!.durationText)
                        : 0;
                    final arrival = DateTime.now().add(
                      Duration(minutes: opt.etaMinutes + routeMins),
                    );
                    final h = arrival.hour;
                    final m = arrival.minute;
                    final ampm = h >= 12 ? 'PM' : 'AM';
                    final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
                    final arrivalStr =
                        '$h12:${m.toString().padLeft(2, '0')} $ampm';
                    return Row(
                      children: [
                        _chipWidget(
                          Icons.schedule_rounded,
                          '${opt.etaMinutes} min',
                        ),
                        const SizedBox(width: 6),
                        _chipWidget(
                          Icons.access_time_filled_rounded,
                          arrivalStr,
                        ),
                        const SizedBox(width: 6),
                        _chipWidget(Icons.person_rounded, '${opt.capacity}'),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),

          // Price column
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              if (_ctrl.state.route == null || _ctrl.state.rideOptions.isEmpty)
                _buildPriceShimmer(width: 54, height: 18)
              else
                Text(
                  '\$${opt.priceEstimate.toStringAsFixed(2)}',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w900,
                    color: selected ? _cardGold : Colors.white,
                    letterSpacing: -0.3,
                  ),
                ),
              const SizedBox(height: 2),
              Text(
                'est. fare',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withValues(alpha: 0.35),
                  fontWeight: FontWeight.w500,
                ),
              ),
              if (selected) ...[
                const SizedBox(height: 6),
                Container(
                  width: 20,
                  height: 20,
                  decoration: const BoxDecoration(
                    color: _cardGold,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: Colors.white,
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    ),   // ← closes AnimatedContainer
    );   // ← closes AnimatedScale
  }

  Widget _chipWidget(IconData icon, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: Colors.white.withValues(alpha: 0.40)),
          const SizedBox(width: 3),
          Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: Colors.white.withValues(alpha: 0.50),
            ),
          ),
        ],
      ),
    );
  }

  /// Animated shimmer placeholder for price while loading.
  Widget _buildPriceShimmer({required double width, required double height}) {
    return AnimatedBuilder(
      animation: _priceShimmerCtrl,
      builder: (context, _) {
        return Container(
          width: width,
          height: height,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(4),
            gradient: LinearGradient(
              begin: Alignment(-1.0 + 2.0 * _priceShimmerCtrl.value, 0),
              end: Alignment(1.0 + 2.0 * _priceShimmerCtrl.value, 0),
              colors: const [
                Color(0xFF2A2A2A),
                Color(0xFF3A3A3A),
                Color(0xFF2A2A2A),
              ],
              stops: const [0.0, 0.5, 1.0],
            ),
          ),
        );
      },
    );
  }

  /// Shimmer placeholder card mimicking a ride option while loading.
  Widget _buildShimmerCard() {
    return AnimatedBuilder(
      animation: _priceShimmerCtrl,
      builder: (context, _) {
        final gradient = LinearGradient(
          begin: Alignment(-1.0 + 2.0 * _priceShimmerCtrl.value, 0),
          end: Alignment(1.0 + 2.0 * _priceShimmerCtrl.value, 0),
          colors: const [
            Color(0xFF2A2A2A),
            Color(0xFF3A3A3A),
            Color(0xFF2A2A2A),
          ],
          stops: const [0.0, 0.5, 1.0],
        );
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E1E),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
          ),
          child: Row(
            children: [
              // Icon placeholder
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  gradient: gradient,
                ),
              ),
              const SizedBox(width: 10),
              // Text placeholders
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(width: 80, height: 14, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: gradient)),
                    const SizedBox(height: 6),
                    Container(width: 120, height: 10, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: gradient)),
                    const SizedBox(height: 6),
                    Container(width: 100, height: 10, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: gradient)),
                  ],
                ),
              ),
              // Price placeholder
              Container(width: 54, height: 18, decoration: BoxDecoration(borderRadius: BorderRadius.circular(4), gradient: gradient)),
            ],
          ),
        );
      },
    );
  }

  /// "Could not load route" card with retry button.
  Widget _buildRouteFailedRetry() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 18),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        children: [
          Text(
            'Could not load route',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          GestureDetector(
            onTap: () {
              setState(() {});
              _ctrl.retryFetchRoute();
            },
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFFE8C547)),
              ),
              child: const Text(
                'Tap to retry',
                style: TextStyle(
                  color: Color(0xFFE8C547),
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Truncate address to roughly the first half (cut at nearest space/comma).
  String _truncateHalf(String s) {
    if (s.length <= 20) return s;
    final half = (s.length * 0.5).round();
    // cut at last separator within the first half
    int cut = half;
    for (int i = half; i >= 0; i--) {
      if (s[i] == ',' || s[i] == ' ') {
        cut = i;
        break;
      }
    }
    return '${s.substring(0, cut).trimRight()}…';
  }

  // ── Searching bottom card — premium animated "Looking for ride" ──

  static const List<String> _searchStatusMessages = [
    'Looking for your driver…',
    'Connecting to nearby drivers…',
    'Almost there…',
    'Confirming your ride…',
  ];

  Widget _buildLocationInfo(IconData icon, String text, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
        ),
      ],
    );
  }

  // ── Premium "Looking for ride" bottom card ──

  Widget _buildSearchingBottomCard(AppColors c) {
    final s = _ctrl.state;
    final statusMsg = _searchStatusMessages[
        _searchStatusIdx % _searchStatusMessages.length];
    final pickupText = s.pickupLabel.isNotEmpty
        ? s.pickupLabel
        : S.of(context).currentLocation;
    final dropoffText = s.dropoffLabel.isNotEmpty
        ? _truncateHalf(s.dropoffLabel)
        : S.of(context).destination;

    return Positioned(
      left: 16,
      right: 16,
      bottom: 24,
      child: AnimatedSlide(
        duration: const Duration(milliseconds: 420),
        curve: Curves.easeOutCubic,
        offset: _searchingShowMap ? Offset.zero : const Offset(0, 1.2),
        child: AnimatedOpacity(
          duration: const Duration(milliseconds: 320),
          opacity: _searchingShowMap ? 1.0 : 0.0,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(28),
              // 3D fade shadow — layered for depth
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.65),
                  blurRadius: 40,
                  spreadRadius: 4,
                  offset: const Offset(0, 12),
                ),
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.30),
                  blurRadius: 16,
                  spreadRadius: 0,
                  offset: const Offset(0, 4),
                ),
                BoxShadow(
                  color: const Color(0xFFE8C547).withValues(alpha: 0.06),
                  blurRadius: 48,
                  spreadRadius: 0,
                  offset: Offset.zero,
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(28),
              child: Container(
                decoration: const BoxDecoration(
                  color: Color(0xFF0F0F14),
                ),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 20),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // ── Drag handle ──
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                        const SizedBox(height: 20),

                        // ── Radar animation + car + route info row ──
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.center,
                          children: [
                            // Radar pulse stack
                            SizedBox(
                              width: 80,
                              height: 80,
                              child: AnimatedBuilder(
                                animation: _radarCtrl,
                                builder: (context, _) {
                                  return Stack(
                                    alignment: Alignment.center,
                                    children: [
                                      // 3 expanding rings
                                      ...List.generate(3, (i) {
                                        final offset = i / 3.0;
                                        final t = (_radarCtrl.value + offset) % 1.0;
                                        final size = 28.0 + t * 60.0;
                                        final alpha = (1.0 - t) * 0.45;
                                        return Container(
                                          width: size,
                                          height: size,
                                          decoration: BoxDecoration(
                                            shape: BoxShape.circle,
                                            border: Border.all(
                                              color: const Color(0xFFE8C547)
                                                  .withValues(alpha: alpha),
                                              width: 1.5,
                                            ),
                                          ),
                                        );
                                      }),
                                      // Gold glow core
                                      Container(
                                        width: 50,
                                        height: 50,
                                        decoration: BoxDecoration(
                                          shape: BoxShape.circle,
                                          gradient: RadialGradient(
                                            colors: [
                                              const Color(0xFFE8C547)
                                                  .withValues(alpha: 0.25),
                                              const Color(0xFFE8C547)
                                                  .withValues(alpha: 0.0),
                                            ],
                                          ),
                                        ),
                                      ),
                                      // Car icon circle
                                      Container(
                                        width: 42,
                                        height: 42,
                                        decoration: BoxDecoration(
                                          color: const Color(0xFF1C1C24),
                                          shape: BoxShape.circle,
                                          border: Border.all(
                                            color: const Color(0xFFE8C547)
                                                .withValues(alpha: 0.55),
                                            width: 1.5,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(0xFFE8C547)
                                                  .withValues(alpha: 0.30),
                                              blurRadius: 16,
                                              spreadRadius: 2,
                                            ),
                                          ],
                                        ),
                                        child: const Icon(
                                          Icons.local_taxi_rounded,
                                          color: Color(0xFFE8C547),
                                          size: 20,
                                        ),
                                      ),
                                    ],
                                  );
                                },
                              ),
                            ),
                            const SizedBox(width: 18),

                            // ── Status + route ──
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  // Animated status message
                                  AnimatedSwitcher(
                                    duration: const Duration(milliseconds: 280),
                                    transitionBuilder: (child, anim) =>
                                        FadeTransition(
                                      opacity: CurvedAnimation(
                                        parent: anim,
                                        curve: Curves.easeInOut,
                                      ),
                                      child: child,
                                    ),
                                    child: Text(
                                      statusMsg,
                                      key: ValueKey(statusMsg),
                                      style: const TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                        letterSpacing: -0.2,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 6),

                                  // Route pill
                                  Row(
                                    children: [
                                      Container(
                                        width: 6,
                                        height: 6,
                                        decoration: const BoxDecoration(
                                          color: Color(0xFF4ADE80),
                                          shape: BoxShape.circle,
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Expanded(
                                        child: Text(
                                          pickupText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.white
                                                .withValues(alpha: 0.50),
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 5),
                                        child: Icon(
                                          Icons.arrow_forward_rounded,
                                          size: 11,
                                          color: Colors.white
                                              .withValues(alpha: 0.30),
                                        ),
                                      ),
                                      Expanded(
                                        child: Text(
                                          dropoffText,
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Colors.white
                                                .withValues(alpha: 0.50),
                                            fontWeight: FontWeight.w500,
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

                        const SizedBox(height: 20),

                        // ── Shimmer progress bar ──
                        AnimatedBuilder(
                          animation: _shimmerCtrl,
                          builder: (context, _) {
                            return Container(
                              height: 3,
                              decoration: BoxDecoration(
                                color:
                                    Colors.white.withValues(alpha: 0.07),
                                borderRadius: BorderRadius.circular(2),
                              ),
                              child: FractionallySizedBox(
                                alignment: Alignment.centerLeft,
                                widthFactor: 1.0,
                                child: ShaderMask(
                                  shaderCallback: (bounds) =>
                                      LinearGradient(
                                    begin: Alignment.centerLeft,
                                    end: Alignment.centerRight,
                                    stops: [
                                      (_shimmerCtrl.value - 0.3)
                                          .clamp(0.0, 1.0),
                                      _shimmerCtrl.value.clamp(0.0, 1.0),
                                      (_shimmerCtrl.value + 0.3)
                                          .clamp(0.0, 1.0),
                                    ],
                                    colors: const [
                                      Color(0xFFE8C547),
                                      Colors.white,
                                      Color(0xFFE8C547),
                                    ],
                                  ).createShader(bounds),
                                  child: Container(
                                    decoration: BoxDecoration(
                                      color: const Color(0xFFE8C547),
                                      borderRadius: BorderRadius.circular(2),
                                    ),
                                  ),
                                ),
                              ),
                            );
                          },
                        ),

                        const SizedBox(height: 20),

                        // ── Cancel button ──
                        SizedBox(
                          width: double.infinity,
                          height: 50,
                          child: TextButton(
                            onPressed: _confirmCancelSearching,
                            style: TextButton.styleFrom(
                              backgroundColor:
                                  Colors.white.withValues(alpha: 0.06),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.10),
                                ),
                              ),
                            ),
                            child: Text(
                              S.of(context).cancel,
                              style: const TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                                color: Colors.white60,
                                letterSpacing: 0.2,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                    ),
                  ),
                ),
            ),
          ),
        ),
      ),
    );
  }

  // ── Payment sheet ──────────────────────────────────────────

  void _showPaymentSheet(AppColors c, RideOption? option) {
    final price = option != null
        ? '\$${option.priceEstimate.toStringAsFixed(2)}'
        : '';

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setSheetState) {
            return Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
              decoration: const BoxDecoration(
                color: Color(0xFF1A1A1A),
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: SafeArea(
                top: false,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Drag handle
                    Center(
                      child: Container(
                        width: 40,
                        height: 4.5,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(40),
                        ),
                      ),
                    ),
                    const SizedBox(height: 18),
                    Text(
                      S.of(context).paymentLabel,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.3,
                      ),
                    ),
                    const SizedBox(height: 16),

                    // Ride summary
                    if (option != null)
                      Container(
                        padding: const EdgeInsets.all(14),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(16),
                        ),
                        child: Row(
                          children: [
                            Builder(
                              builder: (_) {
                                final optName = (option.name).toLowerCase();
                                String asset = 'assets/images/fusion.png';
                                if (optName.contains('suburban')) {
                                  asset = 'assets/images/suburban.png';
                                } else if (optName.contains('camry')) {
                                  asset = 'assets/images/camry.png';
                                }
                                return Image.asset(
                                  asset,
                                  width: 40,
                                  height: 40,
                                  fit: BoxFit.contain,
                                  filterQuality: FilterQuality.high,
                                  isAntiAlias: true,
                                  cacheWidth: 256,
                                  errorBuilder: (_, __, ___) => Icon(
                                    Icons.directions_car_rounded,
                                    color: c.gold,
                                    size: 28,
                                  ),
                                );
                              },
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    option.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 3),
                                  Text(
                                    _ctrl.state.route?.distanceText ?? '',
                                    style: TextStyle(
                                      color: Colors.white.withValues(
                                        alpha: 0.5,
                                      ),
                                      fontSize: 13,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Text(
                              price,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ],
                        ),
                      ),
                    const SizedBox(height: 12),

                    // Payment method selector — gray "Payment Method" button
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _showPaymentMethodPicker(c, option);
                      },
                      child: Container(
                        width: double.infinity,
                        height: 52,
                        decoration: BoxDecoration(
                          color: const Color(0xFF2A2A2A),
                          borderRadius: BorderRadius.circular(14),
                        ),
                        child: const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Text(
                              'Payment Method',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.2,
                              ),
                            ),
                            SizedBox(width: 6),
                            Icon(
                              Icons.chevron_right,
                              color: Colors.white,
                              size: 18,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Pay button — black with gold border, [logo] Pay · $X.XX
                    SizedBox(
                      width: double.infinity,
                      height: 56,
                      child: GestureDetector(
                        onTap: _isProcessingPayment
                            ? null
                            : () => _processPayment(
                                ctx,
                                c,
                                option,
                                setSheetState,
                              ),
                        child: Container(
                          decoration: BoxDecoration(
                            color: const Color(0xFF0D0D0D),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: _isProcessingPayment
                                  ? const Color(0xFFFFD700).withValues(alpha: 0.3)
                                  : const Color(0xFFFFD700),
                              width: 1.5,
                            ),
                          ),
                          child: _isProcessingPayment
                              ? const Center(
                                  child: SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.white70,
                                    ),
                                  ),
                                )
                              : Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 20),
                                  child: Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      _buildPaymentLogo(),
                                      const SizedBox(width: 8),
                                      Text(
                                        'Pay · $price',
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 16,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Processes payment: verifies linked method, checks Stripe PM ID for cards,
  /// charges payment. If anything fails → shows Declined dialog, stays on sheet.
  /// In DEBUG mode, payment is always simulated successfully for testing.
  Future<void> _processPayment(
    BuildContext ctx,
    AppColors c,
    RideOption? option,
    void Function(void Function()) setSheetState,
  ) async {
    setSheetState(() => _isProcessingPayment = true);
    setState(() => _isProcessingPayment = true);

    try {
      final success = await _confirmNativePayment(option);
      if (!mounted) return;
      if (!success) {
        setSheetState(() => _isProcessingPayment = false);
        setState(() => _isProcessingPayment = false);
        return; // User cancelled — stay on sheet
      }
    } catch (e) {
      if (!mounted) return;
      setSheetState(() => _isProcessingPayment = false);
      setState(() => _isProcessingPayment = false);
      debugPrint('Payment error: $e');
      _showDeclinedDialog(
        title: S.of(context).paymentDeclined,
        message: 'Payment could not be processed. Please try again or use a different payment method.',
      );
      return;
    }

    if (!mounted) return;
    setSheetState(() => _isProcessingPayment = false);
    setState(() => _isProcessingPayment = false);
    Navigator.of(context).pop();
    if (widget.applyPromo) await LocalDataService.setPromoUsed();
    AnalyticsService.instance.logRideRequested(option?.name ?? 'unknown', option?.priceEstimate ?? 0);

    if (_ctrl.state.scheduledAt != null) {
      await _createScheduledTrip();
      return;
    }
    _ctrl.requestRide();
  }

  /// Processes payment directly from the route preview sheet.
  Future<void> _startRideDirectly(AppColors c, RideOption? option) async {
    final nav = Navigator.of(context);
    setState(() => _isProcessingPayment = true);

    try {
      final success = await _confirmNativePayment(option);
      if (!mounted) return;
      if (!success) {
        setState(() => _isProcessingPayment = false);
        return; // User cancelled — stay on screen
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessingPayment = false);
      debugPrint('Payment error: $e');
      _showDeclinedDialog(
        title: S.of(context).paymentDeclined,
        message: 'Payment could not be processed. Please try again or use a different payment method.',
      );
      return;
    }

    if (!mounted) return;
    setState(() => _isProcessingPayment = false);
    if (widget.applyPromo) await LocalDataService.setPromoUsed();
    AnalyticsService.instance.logRideRequested(option?.name ?? 'unknown', option?.priceEstimate ?? 0);

    if (_ctrl.state.scheduledAt != null) {
      await _createScheduledTrip();
      return;
    }

    // Show premium "Searching" animation before requesting the ride
    await nav.push(searchingDriverRoute());
    if (!mounted) return;

    _ctrl.requestRide();
  }

  /// Triggers the native payment confirmation for the selected payment method.
  /// Returns true if payment was authorized, false if user cancelled.
  /// Throws on failure.
  Future<bool> _confirmNativePayment(RideOption? option) async {
    if (option == null) return false;
    final amountCents = (option.priceEstimate * 100).round();
    final label = 'Cruise · ${option.name}';

    // Sandbox mode: simulate successful payment with brief delay
    if (AppConfig.sandboxPayments) {
      await Future.delayed(const Duration(milliseconds: 800));
      return true;
    }

    switch (_selectedPaymentMethod) {
      case 'apple_pay':
        return _confirmApplePay(amountCents, label);
      case 'google_pay':
        return _confirmGooglePay(amountCents, label);
      case 'paypal':
        return _confirmPayPal(amountCents);
      case 'credit_card':
        return _confirmCard(amountCents);
      default:
        return true;
    }
  }

  /// Apple Pay: present native Apple Pay sheet via Stripe.
  Future<bool> _confirmApplePay(int amountCents, String label) async {
    try {
      final piResult = await ApiService.createPaymentIntent(amountCents: amountCents);
      final clientSecret = piResult['client_secret'] as String?;
      if (clientSecret == null || clientSecret.startsWith('mock_')) return true;

      await stripe.Stripe.instance.confirmPlatformPayPaymentIntent(
        clientSecret: clientSecret,
        confirmParams: stripe.PlatformPayConfirmParams.applePay(
          applePay: stripe.ApplePayParams(
            cartItems: [
              stripe.ApplePayCartSummaryItem.immediate(
                label: label,
                amount: (amountCents / 100).toStringAsFixed(2),
              ),
            ],
            merchantCountryCode: 'US',
            currencyCode: 'USD',
          ),
        ),
      );
      return true;
    } on stripe.StripeException catch (e) {
      if (e.error.code == stripe.FailureCode.Canceled) return false;
      rethrow;
    }
  }

  /// Google Pay: present native Google Pay sheet via Stripe.
  Future<bool> _confirmGooglePay(int amountCents, String label) async {
    try {
      final piResult = await ApiService.createPaymentIntent(amountCents: amountCents);
      final clientSecret = piResult['client_secret'] as String?;
      if (clientSecret == null || clientSecret.startsWith('mock_')) return true;

      await stripe.Stripe.instance.confirmPlatformPayPaymentIntent(
        clientSecret: clientSecret,
        confirmParams: stripe.PlatformPayConfirmParams.googlePay(
          googlePay: stripe.GooglePayParams(
            testEnv: kDebugMode,
            merchantName: 'Cruise',
            merchantCountryCode: 'US',
            currencyCode: 'USD',
          ),
        ),
      );
      return true;
    } on stripe.StripeException catch (e) {
      if (e.error.code == stripe.FailureCode.Canceled) return false;
      rethrow;
    }
  }

  /// PayPal: open PayPal checkout screen.
  Future<bool> _confirmPayPal(int amountCents) async {
    final result = await Navigator.of(context).push<bool>(
      slideFromRightRoute(
        PayPalCheckoutScreen(
          amount: (amountCents / 100).toStringAsFixed(2),
          currency: 'USD',
        ),
      ),
    );
    return result == true;
  }

  /// Credit/debit card: charge saved card via Stripe PaymentIntent.
  Future<bool> _confirmCard(int amountCents) async {
    final pmId = await LocalDataService.getStripePaymentMethodId();
    if (pmId == null || pmId.isEmpty) {
      throw Exception(S.of(context).pleaseAddPaymentFirst);
    }

    final piResult = await ApiService.createPaymentIntent(
      amountCents: amountCents,
      paymentMethodId: pmId,
    );
    final clientSecret = piResult['client_secret'] as String?;
    final status = piResult['status'] as String?;
    if (clientSecret == null || clientSecret.startsWith('mock_')) return true;

    // If already succeeded (confirmed server-side), done
    if (status == 'succeeded') return true;

    // If requires_action (3D Secure), handle it client-side
    if (status == 'requires_action') {
      try {
        await stripe.Stripe.instance.handleNextAction(clientSecret);
        return true;
      } on stripe.StripeException catch (e) {
        if (e.error.code == stripe.FailureCode.Canceled) return false;
        rethrow;
      }
    }

    return true;
  }

  /// Creates a scheduled trip via the backend API and navigates to the scheduled rides list.
  Future<void> _createScheduledTrip() async {
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId == null || !mounted) return;

      final state = _ctrl.state;
      
      // Validar que scheduledAt no sea null
      if (state.scheduledAt == null) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).pleaseSelectDateTime),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      // Validar que no sea en el pasado
      final now = DateTime.now();
      if (state.scheduledAt!.isBefore(now)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).cannotSchedulePast),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      // Validar que sea al menos 30 minutos en el futuro
      final minAdvance = now.add(const Duration(minutes: 30));
      if (state.scheduledAt!.isBefore(minAdvance)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).schedule30MinAdvance),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      
      // Validar que no sea más de 30 días en el futuro
      final maxAdvance = now.add(const Duration(days: 30));
      if (state.scheduledAt!.isAfter(maxAdvance)) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(S.of(context).scheduleMax30Days),
            backgroundColor: Colors.red,
          ),
        );
        return;
      }
      await ApiService.createTrip(
        riderId: userId,
        pickupAddress: state.pickupLabel,
        dropoffAddress: state.dropoffLabel,
        pickupLat: state.pickup?.lat ?? 0,
        pickupLng: state.pickup?.lng ?? 0,
        dropoffLat: state.dropoff?.lat ?? 0,
        dropoffLng: state.dropoff?.lng ?? 0,
        fare: state.selectedOption?.priceEstimate,
        vehicleType: state.selectedOption?.name,
        scheduledAt: state.scheduledAt,
        isAirport: state.isAirportTrip,
      );

      if (!mounted) return;

      // Show success and navigate to scheduled rides
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFE8C547),
          content: Text(
            S.of(context).rideScheduledSuccess,
            style: const TextStyle(
              color: Colors.black,
              fontWeight: FontWeight.w700,
            ),
          ),
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      );

      // Pop back to home, then push scheduled rides
      Navigator.of(context).pop();
      Navigator.of(
        context,
      ).push(slideFromRightRoute(const ScheduledRidesScreen()));
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFFFF5252),
          content: Text(
            S.of(context).failedToScheduleRide(e.toString()),
            style: const TextStyle(color: Colors.white),
          ),
        ),
      );
    }
  }

  /// Shows a "Payment Declined" or error dialog that blocks the user from
  /// proceeding. They must dismiss it and fix their payment method.
  void _showDeclinedDialog({required String title, required String message}) {
    final c = AppColors.of(context);
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  color: const Color(0xFFEF4444).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.credit_card_off_rounded,
                  color: Color(0xFFEF4444),
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
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
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: c.gold,
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  onPressed: () => Navigator.pop(ctx),
                  child: Text(
                    S.of(context).tryAgain,
                    style: const TextStyle(
                      fontSize: 16,
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
  }

  void _showPaymentMethodPicker(AppColors c, RideOption? option) {
    final loc = S.of(context);
    final methods = [
      if (Platform.isIOS) ('apple_pay', 'Apple Pay'),
      if (!Platform.isIOS) ('google_pay', 'Google Pay'),
      (
        'credit_card',
        _savedCardBrand != null && _savedCardLast4 != null
            ? '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4'
            : loc.creditOrDebitCard,
      ),
      ('paypal', 'PayPal'),
    ];

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (ctx) {
        return Container(
          padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
          decoration: const BoxDecoration(
            color: Color(0xFF1A1A1A),
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
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
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(40),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text(
                  loc.paymentMethodLabel,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    letterSpacing: -0.3,
                  ),
                ),
                const SizedBox(height: 16),
                ...methods.map((m) {
                  final (id, label) = m;
                  final selected = id == _selectedPaymentMethod;
                  return GestureDetector(
                    onTap: () {
                      setState(() => _selectedPaymentMethod = id);
                      Navigator.pop(ctx);
                      _showPaymentSheet(c, option);
                    },
                    child: Container(
                      margin: const EdgeInsets.only(bottom: 6),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 14,
                      ),
                      decoration: BoxDecoration(
                        color: selected
                            ? c.gold.withValues(alpha: 0.08)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(14),
                        border: selected
                            ? Border.all(
                                color: c.gold.withValues(alpha: 0.4),
                                width: 1.2,
                              )
                            : null,
                      ),
                      child: Row(
                        children: [
                          if (id == 'apple_pay' || id == 'google_pay')
                            Expanded(child: _nativePayLogoWide(id))
                          else ...[    
                            _paymentLogoWidget(id, 36),
                            const SizedBox(width: 14),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    label,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          if (selected)
                            Icon(
                              Icons.check_circle_rounded,
                              color: c.gold,
                              size: 22,
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: c.gold.withValues(alpha: 0.12),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                loc.added,
                                style: TextStyle(
                                  color: c.gold,
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
                    await _loadLinkedPayments();
                    if (mounted) _showPaymentSheet(c, option);
                  },
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.settings_rounded, color: c.gold, size: 18),
                      const SizedBox(width: 6),
                      Text(
                        loc.managePaymentAccounts,
                        style: TextStyle(
                          color: c.gold,
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

  Future<void> _openCreditCardScreen(AppColors c, RideOption? option) async {
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
      await LocalDataService.saveCreditCardLast4(last4);
      await LocalDataService.saveCreditCardBrand(brand);
      await LocalDataService.linkPaymentMethod('credit_card');
    }
    await _loadLinkedPayments();
    if (mounted) _showPaymentSheet(c, option);
  }

  // ── Payment logo for Request Ride button ──

  Widget _buildPaymentLogo() {
    switch (_selectedPaymentMethod) {
      case 'apple_pay':
        return const Icon(Icons.apple, color: Colors.white, size: 22);
      case 'google_pay':
        return RichText(
          text: const TextSpan(
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
            children: [
              TextSpan(text: 'G', style: TextStyle(color: Color(0xFF4285F4))),
            ],
          ),
        );
      case 'paypal':
        return const Text(
          'P',
          style: TextStyle(
            color: Color(0xFF003087),
            fontSize: 18,
            fontWeight: FontWeight.w800,
            fontStyle: FontStyle.italic,
          ),
        );
      case 'credit_card':
        return const Text('\u{1F4B3}', style: TextStyle(fontSize: 18));
      default:
        return const Icon(
          Icons.payment_rounded,
          color: Colors.white38,
          size: 22,
        );
    }
  }

  Future<void> _openPaymentAccountsAndReturn(
    AppColors c,
    RideOption? option,
  ) async {
    await Navigator.of(
      context,
    ).push(slideFromRightRoute(const PaymentAccountsScreen()));
    await _loadLinkedPayments();
    if (mounted) _showPaymentSheet(c, option);
  }

  // ── Payment helpers ──

  String _paymentLabel(String id) {
    final loc = S.of(context);
    switch (id) {
      case 'apple_pay':
        return 'Apple Pay';
      case 'google_pay':
        return 'Google Pay';
      case 'credit_card':
        if (_savedCardLast4 != null && _savedCardBrand != null) {
          return '${_capitalizedBrand(_savedCardBrand)} •••• $_savedCardLast4';
        }
        return loc.creditOrDebitCard;
      case 'paypal':
        return 'PayPal';
      default:
        return Platform.isIOS ? 'Apple Pay' : 'Google Pay';
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

  Widget _paymentLogoWidget(String id, double size) {
    switch (id) {
      case 'apple_pay':
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: Colors.black,
            borderRadius: BorderRadius.circular(10),
          ),
          child: Center(
            child: Icon(Icons.apple, color: Colors.white, size: size * 0.55),
          ),
        );
      case 'google_pay':
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
            child: Image.asset(
              'assets/images/google_g.png',
              fit: BoxFit.contain,
              cacheWidth: 80,
            ),
          ),
        );
      case 'paypal':
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
              cacheWidth: 80,
            ),
          ),
        );
      case 'credit_card':
        if (_savedCardBrand != null && _savedCardBrand != 'visa') {
          final Map<String, ({String letter, Color color, bool italic})>
          brands = {
            'mastercard': (
              letter: 'M',
              color: const Color(0xFFEB001B),
              italic: false,
            ),
            'amex': (
              letter: 'A',
              color: const Color(0xFF006FCF),
              italic: false,
            ),
            'discover': (
              letter: 'D',
              color: const Color(0xFFFF6000),
              italic: false,
            ),
          };
          final info = brands[_savedCardBrand];
          if (info != null) {
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
                    fontStyle: info.italic
                        ? FontStyle.italic
                        : FontStyle.normal,
                    fontFamily: 'Roboto',
                  ),
                ),
              ),
            );
          }
        }
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0xFF6B7280).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Center(
            child: Icon(
              Icons.credit_card_rounded,
              color: Color(0xFF6B7280),
              size: 20,
            ),
          ),
        );
      default:
        return Container(
          width: size,
          height: size,
          decoration: BoxDecoration(
            color: const Color(0xFF6B7280).withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Center(
            child: Icon(
              Icons.payment_rounded,
              color: Color(0xFF6B7280),
              size: 20,
            ),
          ),
        );
    }
  }

  /// Official Apple Pay / Google Pay wide logo button (no extra text).
  Widget _nativePayLogoWide(String id) {
    if (id == 'apple_pay') {
      return Container(
        height: 44,
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
        ),
        child: const Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.apple, color: Colors.white, size: 28),
              SizedBox(width: 6),
              Text('Apple Pay', style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w500, letterSpacing: -0.3)),
            ],
          ),
        ),
      );
    }
    return Container(
      height: 44,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.15)),
      ),
      child: Center(
        child: RichText(
          text: const TextSpan(
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
            children: [
              TextSpan(text: 'G', style: TextStyle(color: Color(0xFF4285F4))),
              TextSpan(text: 'o', style: TextStyle(color: Color(0xFFEA4335))),
              TextSpan(text: 'o', style: TextStyle(color: Color(0xFFFBBC05))),
              TextSpan(text: 'g', style: TextStyle(color: Color(0xFF4285F4))),
              TextSpan(text: 'le ', style: TextStyle(color: Color(0xFF34A853))),
              TextSpan(text: 'Pay', style: TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDriverFoundOverlay(AppColors c) {
    final driver = _ctrl.state.driver!;
    final firstName = driver.name.split(' ').first;
    const gold = Color(0xFFC8973A);
    final stagger = _dfStaggerCtrl;
    final checkCtrl = _dfCheckCtrl;
    final shimmer = _dfShimmerCtrl;
    if (stagger == null || checkCtrl == null || shimmer == null) {
      return const SizedBox.shrink();
    }

    final messages = [
      '${driver.vehicleColor} ${driver.vehicleMake} ${driver.vehicleModel}',
      '⭐ ${driver.rating.toStringAsFixed(1)} · ${driver.vehiclePlate}',
      '$firstName ${S.of(context).isOnTheWay}',
    ];

    final pickup = _ctrl.state.pickup;

    return Positioned.fill(
      child: IgnorePointer(
        ignoring: false,
        child: AnimatedOpacity(
          opacity: _driverFoundVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 400),
          child: Stack(
            fit: StackFit.expand,
            children: [
              // Real Mapbox map background
              if (pickup != null)
                IgnorePointer(
                  child: RepaintBoundary(
                    child: mapbox.MapWidget(
                      styleUri: MapboxConfig.styleDark,
                      cameraOptions: mapbox.CameraOptions(
                        center: mapbox.Point(
                          coordinates: mapbox.Position(
                            pickup.lng,
                            pickup.lat,
                          ),
                        ),
                        zoom: 14.5,
                        pitch: 0.0,
                      ),
                      onMapCreated: (ctrl) async {
                        ctrl.scaleBar.updateSettings(
                            mapbox.ScaleBarSettings(enabled: false));
                        ctrl.compass.updateSettings(
                            mapbox.CompassSettings(enabled: false));
                        ctrl.attribution.updateSettings(
                            mapbox.AttributionSettings(enabled: false));
                        ctrl.logo.updateSettings(
                            mapbox.LogoSettings(enabled: false));
                      },
                    ),
                  ),
                )
              else
                const ColoredBox(color: Color(0xFF0A0A1A)),
              // Blur overlay
              Positioned.fill(
                child: BackdropFilter(
                  filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(color: Colors.transparent),
                ),
              ),
              // Dark overlay
              Positioned.fill(
                child: Container(color: Colors.black.withValues(alpha: 0.55)),
              ),
              // Content
              SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 2),

                  // ── Animated checkmark with gold glow ──
                  AnimatedBuilder(
                    animation: checkCtrl,
                    builder: (_, __) {
                      return Transform.scale(
                        scale: Curves.elasticOut.transform(
                          checkCtrl.value.clamp(0.0, 1.0),
                        ),
                        child: Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            boxShadow: [
                              BoxShadow(
                                color: gold.withValues(alpha: 0.35 * checkCtrl.value),
                                blurRadius: 28,
                                spreadRadius: 6,
                              ),
                            ],
                          ),
                          child: CustomPaint(
                            size: const Size(72, 72),
                            painter: _CheckmarkPainter(
                              progress: checkCtrl.value,
                              color: gold,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                  const SizedBox(height: 24),

                  // ── "Driver Found!" with shimmer ──
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: stagger,
                      curve: const Interval(0.15, 0.45),
                    ),
                    child: AnimatedBuilder(
                      animation: shimmer,
                      builder: (_, child) => ShaderMask(
                        shaderCallback: (bounds) => LinearGradient(
                          colors: const [gold, Colors.white, gold],
                          stops: [
                            (shimmer.value - 0.3).clamp(0.0, 1.0),
                            shimmer.value,
                            (shimmer.value + 0.3).clamp(0.0, 1.0),
                          ],
                        ).createShader(bounds),
                        blendMode: BlendMode.srcIn,
                        child: child,
                      ),
                      child: Text(
                        S.of(context).driverFound,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),

                  // ── Subtitle ──
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: stagger,
                      curve: const Interval(0.2, 0.5),
                    ),
                    child: Text(
                      '$firstName ${S.of(context).isOnTheWay}',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                    ),
                  ),

                  const Spacer(),

                  // ── Driver info card ──
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: stagger,
                      curve: const Interval(0.3, 0.6),
                    ),
                    child: Container(
                        margin: const EdgeInsets.symmetric(horizontal: 28),
                        padding: const EdgeInsets.all(22),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.05),
                          borderRadius: BorderRadius.circular(22),
                          border: Border.all(
                            color: gold.withValues(alpha: 0.25),
                          ),
                        ),
                        child: Row(
                          children: [
                            // Driver avatar
                            VerifiedAvatar(
                              uid: driver.id,
                              fallbackName: firstName,
                              photoUrl: driver.photoUrl,
                              radius: 30,
                            ),
                            const SizedBox(width: 16),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    driver.name,
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Row(
                                    children: [
                                      const Icon(Icons.star_rounded,
                                          color: gold, size: 15),
                                      const SizedBox(width: 3),
                                      Text(
                                        driver.rating.toStringAsFixed(1),
                                        style: const TextStyle(
                                          color: Colors.white,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w700,
                                        ),
                                      ),
                                      if (driver.totalTrips > 0) ...[
                                        const SizedBox(width: 10),
                                        Text(
                                          '${driver.totalTrips} trips',
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.5),
                                            fontSize: 12,
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                  const SizedBox(height: 8),
                                  // Vehicle info
                                  Text(
                                    '${driver.vehicleColor} ${driver.vehicleMake} ${driver.vehicleModel}',
                                    style: TextStyle(
                                      color: Colors.white.withValues(alpha: 0.55),
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  // License plate pill
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 10,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(alpha: 0.08),
                                      borderRadius: BorderRadius.circular(6),
                                      border: Border.all(
                                        color: Colors.white.withValues(alpha: 0.15),
                                      ),
                                    ),
                                    child: Text(
                                      driver.vehiclePlate,
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w700,
                                        letterSpacing: 1.8,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                    ),
                  ),

                  const SizedBox(height: 18),

                  // ── ETA pill (fade in) ──
                  FadeTransition(
                    opacity: CurvedAnimation(
                      parent: stagger,
                      curve: const Interval(0.5, 0.75),
                    ),
                    child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: gold.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(30),
                          border: Border.all(
                            color: gold.withValues(alpha: 0.35),
                          ),
                        ),
                        child: AnimatedSwitcher(
                          duration: const Duration(milliseconds: 350),
                          child: Text(
                            messages[_dfMsgIndex],
                            key: ValueKey(_dfMsgIndex),
                            style: const TextStyle(
                              color: gold,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                    ),
                  ),

                  const Spacer(),

                  // ── Gold progress bar ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 64),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween(begin: 0.0, end: 1.0),
                      duration: const Duration(milliseconds: 3800),
                      curve: Curves.easeInOut,
                      builder: (_, value, __) => ClipRRect(
                        borderRadius: BorderRadius.circular(2),
                        child: LinearProgressIndicator(
                          value: value,
                          backgroundColor: Colors.white10,
                          valueColor: const AlwaysStoppedAnimation(gold),
                          minHeight: 2,
                        ),
                      ),
                    ),
                  ),

                  const Spacer(flex: 2),
                ],
              ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _cancelSearching() {
    _searchMapTimer?.cancel();
    _searchMapTimer = null;
    _splashTimer?.cancel();
    _splashTimer = null;
    _driverFoundTimer?.cancel();
    _driverFoundTimer = null;
    _dfCheckCtrl?.dispose();
    _dfCheckCtrl = null;
    _dfStaggerCtrl?.dispose();
    _dfStaggerCtrl = null;
    _dfShimmerCtrl?.dispose();
    _dfShimmerCtrl = null;
    _dfMsgTimer?.cancel();
    _dfMsgTimer = null;
    _searchStatusTimer?.cancel();
    _searchStatusTimer = null;
    _searchElapsedTimer?.cancel();
    _searchElapsedTimer = null;
    _searchingShowMap = false;
    _searchingSplash = false;
    _driverFoundVisible = false;
    // Clean up map annotations so route/pins don't persist
    _cleanupMapAnnotations();
    _ctrl.cancelRide();
    _ctrl.reset();
    _navigatingToTracking = false;
  }

  /// Removes all trip-related polyline and pin annotations from the map.
  Future<void> _cleanupMapAnnotations() async {
    _routeDrawTicker?.stop();
    _routeDrawTicker?.dispose();
    _routeDrawTicker = null;
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr != null) {
      if (_routeAnnot != null) {
        try { await polyMgr.delete(_routeAnnot!); } catch (_) {}
        _routeAnnot = null;
      }
    }
    final ptMgr = _pointAnnotMgr;
    if (ptMgr != null) {
      if (_pickupAnnot != null) {
        try { await ptMgr.delete(_pickupAnnot!); } catch (_) {}
        _pickupAnnot = null;
      }
      if (_dropoffAnnot != null) {
        try { await ptMgr.delete(_dropoffAnnot!); } catch (_) {}
        _dropoffAnnot = null;
      }
    }
    _showPinLabels = false;
    _labelsRevealed = false;
  }

  /// Shows a confirmation dialog before canceling the ride search.
  void _confirmCancelSearching() {
    final c = AppColors.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF1C1C24),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          S.of(context).cancelRideQuestion,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        content: Text(
          S.of(context).cancelRideMsg,
          style: const TextStyle(
            color: Colors.white70,
            fontSize: 14,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(
              S.of(context).keepWaiting,
              style: TextStyle(color: c.gold, fontWeight: FontWeight.w600),
            ),
          ),
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              _cancelSearching();
            },
            child: Text(
              S.of(context).yesCancelBtn,
              style: const TextStyle(
                color: Colors.redAccent,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }


  Future<void> _applyDarkNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
  }

  Future<void> _recenterMap() async {
    _programmaticCam = true;
    setState(() => _userMovedMap = false);
    final s = _ctrl.state;
    // If we have pickup+dropoff, fit both in view
    if (s.pickup != null && s.dropoff != null) {
      final bounds = LatLngBounds(
        southwest: LatLng(
          math.min(s.pickup!.lat, s.dropoff!.lat),
          math.min(s.pickup!.lng, s.dropoff!.lng),
        ),
        northeast: LatLng(
          math.max(s.pickup!.lat, s.dropoff!.lat),
          math.max(s.pickup!.lng, s.dropoff!.lng),
        ),
      );
      final coords = [
        mapbox.Point(coordinates: mapbox.Position(bounds.southwest.longitude, bounds.southwest.latitude)),
        mapbox.Point(coordinates: mapbox.Position(bounds.northeast.longitude, bounds.northeast.latitude)),
      ];
      final screenH = MediaQuery.of(context).size.height;
      final bottomPad = screenH * 0.52;
      final cam = await _mapCtrl?.cameraForCoordinatesPadding(
        coords, mapbox.CameraOptions(),
        mapbox.MbxEdgeInsets(top: 80, left: 60, bottom: bottomPad, right: 60), null, null,
      );
      if (cam != null) _mapCtrl?.flyTo(cam, mapbox.MapAnimationOptions(duration: 700));
    } else if (_userLocation != null) {
      _mapCtrl?.flyTo(
        mapbox.CameraOptions(center: mapbox.Point(coordinates: mapbox.Position(_userLocation!.longitude, _userLocation!.latitude)), zoom: 15.5),
        mapbox.MapAnimationOptions(duration: 500),
      );
    }
  }

  // ── Helpers ──

  Widget _circleButton({
    required IconData icon,
    required VoidCallback onTap,
    required AppColors c,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Icon(icon, size: 24, color: Colors.white),
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
