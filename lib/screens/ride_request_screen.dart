import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as amap;
import 'package:geolocator/geolocator.dart';

import '../navigation/car_icon_loader.dart';
import '../config/api_keys.dart';
import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/places_service.dart';
import '../state/rider_trip_controller.dart';
import 'credit_card_screen.dart';
import 'payment_accounts_screen.dart';
import 'pickup_dropoff_search_screen.dart';
import 'ride_options_sheet.dart';
import 'rider_tracking_screen.dart';
import 'airport_terminal_sheet.dart';
import '../l10n/app_localizations.dart';
import 'scheduled_rides_screen.dart';

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
  const RideRequestScreen({
    super.key,
    this.fastRide = false,
    this.applyPromo = false,
    this.isAirportTrip = false,
    this.scheduledAt,
    this.airportSelection,
    this.initialDropoffAddress,
  });

  @override
  State<RideRequestScreen> createState() => _RideRequestScreenState();
}

class _RideRequestScreenState extends State<RideRequestScreen>
    with TickerProviderStateMixin {
  // ── Map ──
  GoogleMapController? _mapCtrl;
  amap.AppleMapController? _appleMapCtrl;
  LatLng _center = const LatLng(25.7617, -80.1918); // Miami default
  LatLng? _userLocation;
  bool _mapReady = false;

  // ── Trip controller ──
  final RiderTripController _ctrl = RiderTripController();

  // ── Map elements ──
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  BitmapDescriptor? _goldPinIcon;

  // ── Searching animation ──
  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  // ── Bottom sheet ──
  late AnimationController _sheetCtrl;
  late Animation<double> _sheetSlide;

  // ── Current location address ──
  String _currentAddress = '';
  bool _fetchingLocation = true;

  // ── Guard: only navigate to tracking once ──
  bool _navigatingToTracking = false;

  // ── Payment state ──
  String _selectedPaymentMethod = 'google_pay';
  Set<String> _linkedPaymentMethods = {};
  String? _savedCardLast4;
  String? _savedCardBrand;
  bool _isProcessingPayment = false;

  // ── Map interaction state ──
  bool _userMovedMap = false;
  bool _rideOptionsExpanded = true;
  bool _programmaticCam = false;

  // ── Searching overlay: splash first, then map with address bars ──
  bool _searchingShowMap = false;
  bool _searchingSplash = false;
  Timer? _searchMapTimer;
  Timer? _splashTimer;

  // Combined pin+label bitmaps (pin and label in one image, always aligned)
  bool _showPinLabels = true;
  BitmapDescriptor? _pickupPinOnly;
  BitmapDescriptor? _dropoffPinOnly;
  // Pin+label combined: (bitmap, anchor) — anchor places pin tip at the LatLng
  (BitmapDescriptor, Offset)? _pickupPinWithLabel;
  (BitmapDescriptor, Offset)? _dropoffPinWithLabel;

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

    _sheetCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _sheetSlide = Tween<double>(
      begin: 1.0,
      end: 0.0,
    ).animate(CurvedAnimation(parent: _sheetCtrl, curve: Curves.easeOutCubic));

    _ctrl.addListener(_onStateChange);
    // Wire in scheduled/airport params from widget
    if (widget.isAirportTrip) {
      _ctrl.setAirportTrip(true);
    }
    if (widget.scheduledAt != null) {
      _ctrl.setSchedule(widget.scheduledAt);
    }
    _initLocation().then((_) {
      // Auto-geocode airport and set as pickup when airport selection provided
      if (widget.airportSelection != null) {
        _autoSetAirportPickup(widget.airportSelection!);
      }
      // Auto-set dropoff from Quick Access address
      if (widget.initialDropoffAddress != null) {
        _autoSetDropoff(widget.initialDropoffAddress!);
      }
    });
    _loadLinkedPayments();
    _loadPinIcon();
  }

  Future<void> _loadPinIcon() async {
    _goldPinIcon = await _buildGoldPin();
    if (mounted) setState(() {});
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
          _mapCtrl?.animateCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(target: target, zoom: 17),
            ),
          );
          _appleMapCtrl?.animateCamera(
            amap.CameraUpdate.newCameraPosition(
              amap.CameraPosition(
                target: amap.LatLng(details.lat, details.lng),
                zoom: 17,
              ),
            ),
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

  Future<BitmapDescriptor> _buildGoldPin({
    _PinIcon icon = _PinIcon.none,
    bool isPickup = true,
  }) async {
    const double size = 90;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    _drawGoldPinAt(canvas, 0, 0, size, icon: icon, isPickup: isPickup);
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    // ignore: deprecated_member_use
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  }

  /// Render a combined pin + label bitmap as a single image.
  /// The pin appears on the left and the label box on the right, vertically centered.
  /// [labelOnLeft] places the label to the left of the pin instead.
  Future<(BitmapDescriptor, Offset)> _buildPinWithLabel({
    required String text,
    bool isPickup = true,
    String? etaText,
    _PinIcon icon = _PinIcon.none,
    bool labelOnLeft = false,
  }) async {
    final label = _truncateHalf(text);
    final showEta = etaText != null && etaText.isNotEmpty;

    // ── Pin dimensions ──
    const pinSize = 130.0;

    // ── Measure label text ──
    final textPainter = TextPainter(
      text: TextSpan(
        text: label,
        style: const TextStyle(
          fontSize: 30,
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
            fontSize: 24,
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
    const labelH = 78.0;
    const pinLabelGap = 4.0;

    // ── Total canvas ──
    final totalW = pinSize + pinLabelGap + labelW;
    final totalH = math.max(pinSize, labelH);

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, totalW, totalH));

    // Determine positions
    final double pinX = labelOnLeft ? labelW + pinLabelGap : 0;
    final double labelX = labelOnLeft ? 0 : pinSize + pinLabelGap;
    final double pinY = totalH - pinSize;
    final double labelY = (totalH - labelH) / 2;

    // ── Draw pin ──
    _drawGoldPinAt(canvas, pinX, pinY, pinSize, icon: icon, isPickup: isPickup);

    // ── Draw label box ──
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(labelX, labelY, labelW, labelH),
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

    double x = labelX + hPad;

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
    final img = await picture.toImage(totalW.ceil(), totalH.ceil());
    final bytes = await img.toByteData(format: ui.ImageByteFormat.png);

    // Anchor: pin tip is at (pinX + pinSize/2, totalH) — normalized to image dims
    final anchorX = (pinX + pinSize / 2) / totalW;
    const anchorY = 1.0;

    // ignore: deprecated_member_use
    final bitmap = BitmapDescriptor.fromBytes(bytes!.buffer.asUint8List());
    return (bitmap, Offset(anchorX, anchorY));
  }

  /// Render a standalone gold pin (no label) as BitmapDescriptor.
  Future<BitmapDescriptor> _buildStandalonePin({
    _PinIcon icon = _PinIcon.none,
    bool isPickup = true,
  }) async {
    const double size = 120;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    _drawGoldPinAt(canvas, 0, 0, size, icon: icon, isPickup: isPickup);
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    // ignore: deprecated_member_use
    return BitmapDescriptor.fromBytes(byteData!.buffer.asUint8List());
  }

  /// Draw a gold pin at a specific position on a canvas.
  /// [isPickup] = true → circle; false → rounded square.
  void _drawGoldPinAt(
    Canvas canvas,
    double ox,
    double oy,
    double size, {
    _PinIcon icon = _PinIcon.none,
    bool isPickup = true,
  }) {
    final cx = ox + size / 2;
    final cy = oy + size / 2; // center of the shape
    final r = size * 0.38;

    // Shadow
    canvas.drawCircle(
      Offset(cx, cy + 2),
      r + 2,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

    if (isPickup) {
      // ── Circle shape for pickup ──
      canvas.drawCircle(Offset(cx, cy), r, Paint()..color = _gold);
      canvas.drawCircle(
        Offset(cx, cy),
        r,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white.withValues(alpha: 0.25),
      );
    } else {
      // ── Rounded square shape for dropoff ──
      final rect = RRect.fromRectAndRadius(
        Rect.fromCenter(center: Offset(cx, cy), width: r * 2, height: r * 2),
        Radius.circular(r * 0.28),
      );
      canvas.drawRRect(rect, Paint()..color = _gold);
      canvas.drawRRect(
        rect,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.5
          ..color = Colors.white.withValues(alpha: 0.25),
      );
    }

    // Subtle inner highlight on top-left for modern 3D feel
    canvas.drawCircle(
      Offset(cx - r * 0.2, cy - r * 0.2),
      r * 0.5,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.15)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );

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
        final s = size * 0.12;
        // Fuselage (filled oval)
        canvas.drawOval(
          Rect.fromCenter(
            center: Offset(cx, cy),
            width: s * 0.55,
            height: s * 2.0,
          ),
          iconPaint,
        );
        // Wings (filled)
        final wings = Path()
          ..moveTo(cx, cy - s * 0.05)
          ..lineTo(cx - s * 1.2, cy + s * 0.35)
          ..lineTo(cx - s * 1.2, cy + s * 0.5)
          ..lineTo(cx, cy + s * 0.18)
          ..lineTo(cx + s * 1.2, cy + s * 0.5)
          ..lineTo(cx + s * 1.2, cy + s * 0.35)
          ..close();
        canvas.drawPath(wings, iconPaint);
        // Tail fins (filled)
        final tail = Path()
          ..moveTo(cx, cy + s * 0.65)
          ..lineTo(cx - s * 0.5, cy + s * 1.0)
          ..lineTo(cx - s * 0.5, cy + s * 1.1)
          ..lineTo(cx, cy + s * 0.85)
          ..lineTo(cx + s * 0.5, cy + s * 1.1)
          ..lineTo(cx + s * 0.5, cy + s * 1.0)
          ..close();
        canvas.drawPath(tail, iconPaint);
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
    _searchMapTimer?.cancel();
    _splashTimer?.cancel();
    _ctrl.removeListener(_onStateChange);
    _ctrl.dispose();
    _pulseCtrl.dispose();
    _sheetCtrl.dispose();
    super.dispose();
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
      if (perm == LocationPermission.denied ||
          perm == LocationPermission.deniedForever) {
        setState(() => _fetchingLocation = false);
        return;
      }

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
      _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(ll, 15.5));
      _appleMapCtrl?.animateCamera(
        amap.CameraUpdate.newCameraPosition(
          amap.CameraPosition(
            target: amap.LatLng(ll.latitude, ll.longitude),
            zoom: 15.5,
          ),
        ),
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

  void _onStateChange() {
    if (!mounted) return;
    final s = _ctrl.state;

    switch (s.phase) {
      case RiderPhase.previewRoute:
      case RiderPhase.selectingRide:
        _drawRoute();
        _sheetCtrl.forward();
        break;
      case RiderPhase.requesting:
      case RiderPhase.searchingDriver:
        // Show map with bottom card immediately — no splash
        if (!_searchingShowMap) {
          _searchMapTimer?.cancel();
          _searchingSplash = false;
          _searchingShowMap = true;
          // Fit route so user sees pickup → dropoff
          if (_ctrl.state.route != null) {
            _fitRoute(_ctrl.state.route!.points);
          }
        }
        break;
      case RiderPhase.driverAssigned:
        // Show matched state but don't navigate yet — wait for driverArriving
        break;
      case RiderPhase.driverArriving:
        if (!_navigatingToTracking) {
          _navigatingToTracking = true;
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
        // Show cancel reason dialog
        final reason = s.cancelReason ?? S.of(context).noDriversAvailable;
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
        break;
      default:
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

    // Set polyline immediately
    _polylines = {
      Polyline(
        polylineId: const PolylineId('route'),
        points: s.route!.points,
        color: const Color(0xFF4285F4),
        width: 3,
        geodesic: true,
      ),
    };
    _showPinLabels = true;

    // Build bitmap labels asynchronously, then set markers
    _buildRouteMarkers();

    // Fit the route
    _fitRoute(s.route!.points);
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

  void _rebuildMarkers() {
    final s = _ctrl.state;
    if (s.route == null) return;

    final fallback = _goldPinIcon ?? BitmapDescriptor.defaultMarker;
    final markers = <Marker>{};

    // Pickup: one single marker, swaps between pin-only and pin+label
    if (s.pickup != null) {
      final showLabel = _showPinLabels && _pickupPinWithLabel != null;
      final BitmapDescriptor icon;
      final Offset anchor;
      if (showLabel) {
        final (bmp, anc) = _pickupPinWithLabel!;
        icon = bmp;
        anchor = anc;
      } else {
        icon = _pickupPinOnly ?? fallback;
        anchor = const Offset(0.5, 1.0);
      }
      markers.add(
        Marker(
          markerId: const MarkerId('pickup'),
          position: LatLng(s.pickup!.lat, s.pickup!.lng),
          icon: icon,
          anchor: anchor,
          zIndexInt: 2,
          onTap: _togglePinLabels,
        ),
      );
    }

    // Dropoff: one single marker, swaps between pin-only and pin+label
    if (s.dropoff != null) {
      final showLabel = _showPinLabels && _dropoffPinWithLabel != null;
      final BitmapDescriptor icon;
      final Offset anchor;
      if (showLabel) {
        final (bmp, anc) = _dropoffPinWithLabel!;
        icon = bmp;
        anchor = anc;
      } else {
        icon = _dropoffPinOnly ?? fallback;
        anchor = const Offset(0.5, 1.0);
      }
      markers.add(
        Marker(
          markerId: const MarkerId('dropoff'),
          position: LatLng(s.dropoff!.lat, s.dropoff!.lng),
          icon: icon,
          anchor: anchor,
          zIndexInt: 2,
          onTap: _togglePinLabels,
        ),
      );
    }

    setState(() {
      _markers = markers;
    });
  }

  // Labels always visible — no toggle behavior
  void _togglePinLabels() {}

  void _fitRoute(List<LatLng> pts) {
    if (pts.isEmpty) return;
    final hasCtrl = Platform.isIOS ? _appleMapCtrl != null : _mapCtrl != null;
    if (!hasCtrl) return;
    double minLat = 90, maxLat = -90, minLng = 180, maxLng = -180;
    for (final p in pts) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    if (Platform.isIOS) {
      _appleMapCtrl!.animateCamera(
        amap.CameraUpdate.newLatLngBounds(
          amap.LatLngBounds(
            southwest: amap.LatLng(minLat, minLng),
            northeast: amap.LatLng(maxLat, maxLng),
          ),
          80,
        ),
      );
    } else {
      _mapCtrl!.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat, minLng),
            northeast: LatLng(maxLat, maxLng),
          ),
          80,
        ),
      );
    }
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
  //  APPLE MAPS CONVERTERS
  // ═══════════════════════════════════════════════════════

  Set<amap.Annotation> get _appleAnnotations {
    return _markers.map((m) {
      return amap.Annotation(
        annotationId: amap.AnnotationId(m.markerId.value),
        position: amap.LatLng(m.position.latitude, m.position.longitude),
        icon: amap.BitmapDescriptor.defaultAnnotation,
      );
    }).toSet();
  }

  Set<amap.Polyline> get _applePolylines {
    return _polylines.map((p) {
      return amap.Polyline(
        polylineId: amap.PolylineId(p.polylineId.value),
        points: p.points
            .map((ll) => amap.LatLng(ll.latitude, ll.longitude))
            .toList(),
        color: p.color,
        width: p.width,
      );
    }).toSet();
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
            RepaintBoundary(
              child: Platform.isIOS
                  ? amap.AppleMap(
                      initialCameraPosition: amap.CameraPosition(
                        target: amap.LatLng(
                          _center.latitude,
                          _center.longitude,
                        ),
                        zoom: 15.5,
                      ),
                      mapType: amap.MapType.standard,
                      onMapCreated: (ctrl) {
                        _appleMapCtrl = ctrl;
                        setState(() => _mapReady = true);
                        if (_userLocation != null) {
                          ctrl.animateCamera(
                            amap.CameraUpdate.newCameraPosition(
                              amap.CameraPosition(
                                target: amap.LatLng(
                                  _userLocation!.latitude,
                                  _userLocation!.longitude,
                                ),
                                zoom: 15.5,
                              ),
                            ),
                          );
                        }
                      },
                      myLocationEnabled: true,
                      myLocationButtonEnabled: false,
                      zoomGesturesEnabled: true,
                      scrollGesturesEnabled: true,
                      pitchGesturesEnabled: true,
                      compassEnabled: false,
                      padding: EdgeInsets.only(
                        bottom: _bottomSheetHeight(phase, bottomPad),
                      ),
                      annotations: _appleAnnotations,
                      polylines: _applePolylines,
                    )
                  : GoogleMap(
                      style: MapStyles.dark,
                      initialCameraPosition: CameraPosition(
                        target: _center,
                        zoom: 15.5,
                      ),
                      onMapCreated: (ctrl) {
                        _mapCtrl = ctrl;
                        setState(() => _mapReady = true);
                        if (_userLocation != null) {
                          ctrl.animateCamera(
                            CameraUpdate.newLatLngZoom(_userLocation!, 15.5),
                          );
                        }
                      },
                      onCameraMoveStarted: () {
                        if (!_programmaticCam) {
                          setState(() => _userMovedMap = true);
                        }
                      },
                      onCameraMove: (_) {},
                      onCameraIdle: () => _programmaticCam = false,
                      markers: _markers,
                      polylines: _polylines,
                      myLocationEnabled: true,
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: false,
                      zoomGesturesEnabled: true,
                      scrollGesturesEnabled: true,
                      compassEnabled: false,
                      mapToolbarEnabled: false,
                      buildingsEnabled: false,
                      trafficEnabled: false,
                      liteModeEnabled: false,
                      padding: EdgeInsets.only(
                        bottom: _bottomSheetHeight(phase, bottomPad),
                      ),
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
                        _ctrl.reset();
                        _navigatingToTracking = false;
                        setState(() {
                          _markers = {};
                          _polylines = {};
                        });
                        _sheetCtrl.reverse();
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

            // ── "Where to?" pill (idle) ──
            _buildWhereToBar(c, topPad, phase == RiderPhase.idle),

            // ── Route preview sheet ──
            if (phase == RiderPhase.previewRoute ||
                phase == RiderPhase.selectingRide)
              _buildRoutePreviewSheet(c, bottomPad),

            // ── Searching bottom card (map visible behind) ──
            if ((phase == RiderPhase.requesting ||
                    phase == RiderPhase.searchingDriver) &&
                _searchingShowMap)
              _buildSearchingBottomCard(c),
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
        final h = (screenH * 0.60).clamp(340.0, 480.0);
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
    final sheetH = (screenH * 0.60).clamp(340.0, 480.0) + bottomPad;

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
                        children: [
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
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (int i = 0; i < displayOptions.length; i++) ...[
                            GestureDetector(
                              onTap: () {
                                _ctrl.selectRideOption(displayOptions[i]);
                                // Auto-collapse after selecting to show pay button
                                Future.delayed(
                                  const Duration(milliseconds: 250),
                                  () {
                                    if (mounted) {
                                      setState(
                                        () => _rideOptionsExpanded = false,
                                      );
                                    }
                                  },
                                );
                              },
                              child: _buildRideOptionCard(
                                c,
                                displayOptions[i],
                                option?.id == displayOptions[i].id,
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
                                horizontal: 14,
                              ),
                              child: _buildRideOptionCard(c, option, true),
                            ),
                          )
                        : const SizedBox.shrink(),
                    crossFadeState: _rideOptionsExpanded
                        ? CrossFadeState.showFirst
                        : CrossFadeState.showSecond,
                    duration: const Duration(milliseconds: 200),
                    sizeCurve: Curves.easeInOut,
                  ),

                  const SizedBox(height: 6),
                  Divider(
                    height: 1,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  const SizedBox(height: 6),

                  // Inline payment method row
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: GestureDetector(
                      onTap: () => _showPaymentMethodPicker(c, option),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 10,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: c.gold.withValues(alpha: 0.15),
                          ),
                        ),
                        child: Row(
                          children: [
                            _paymentLogoWidget(_selectedPaymentMethod, 28),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Text(
                                _paymentLabel(_selectedPaymentMethod),
                                style: const TextStyle(
                                  color: Colors.white,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: Colors.white.withValues(alpha: 0.4),
                              size: 20,
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),

                  // Start Ride button — processes payment directly
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: SizedBox(
                      width: double.infinity,
                      height: 52,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: _isProcessingPayment
                              ? LinearGradient(
                                  colors: [
                                    c.gold.withValues(alpha: 0.5),
                                    c.goldLight.withValues(alpha: 0.5),
                                  ],
                                )
                              : LinearGradient(colors: [c.gold, c.goldLight]),
                          borderRadius: BorderRadius.circular(26),
                        ),
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: Colors.transparent,
                            shadowColor: Colors.transparent,
                            foregroundColor: Colors.black,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(26),
                            ),
                          ),
                          onPressed: _isProcessingPayment
                              ? null
                              : () => _startRideDirectly(c, option),
                          child: _isProcessingPayment
                              ? const SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2.5,
                                    color: Colors.black54,
                                  ),
                                )
                              : Text(
                                  option != null
                                      ? S
                                            .of(context)
                                            .requestRideWithPrice(
                                              option.priceEstimate
                                                  .toStringAsFixed(2),
                                            )
                                      : S.of(context).requestRide,
                                  style: const TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                        ),
                      ),
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
    if (key.contains('suburban')) return 'assets/images/suburban.png';
    if (key.contains('camry')) return 'assets/images/camry.png';
    return 'assets/images/fusion.png';
  }

  Widget _buildRideOptionCard(AppColors c, RideOption opt, bool selected) {
    final isSuv = opt.id == 'suburban';
    final isFusion = opt.id == 'fusion';

    // Tier styling
    final Color tierColor;
    final String tierLabel;
    if (isSuv) {
      tierColor = const Color(0xFFE8C547);
      tierLabel = 'PREMIUM';
    } else if (isFusion) {
      tierColor = const Color(0xFF4A9EFF);
      tierLabel = 'ECONOMY';
    } else {
      tierColor = const Color(0xFF6FCF97);
      tierLabel = 'COMFORT';
    }

    return AnimatedContainer(
      duration: const Duration(milliseconds: 150),
      curve: Curves.easeOut,
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
            width: 64,
            height: 48,
            child: Image.asset(
              _carAssetForOption(opt.name),
              width: 64,
              height: 48,
              fit: BoxFit.contain,
              filterQuality: FilterQuality.high,
              isAntiAlias: true,
              cacheWidth: 256,
              errorBuilder: (_, e, s) => Icon(
                Icons.directions_car_rounded,
                size: 32,
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
                // Name + tier badge
                Row(
                  children: [
                    Text(
                      opt.name,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                        letterSpacing: -0.2,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: tierColor.withValues(alpha: 0.14),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
                        tierLabel,
                        style: TextStyle(
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          color: tierColor,
                          letterSpacing: 0.8,
                        ),
                      ),
                    ),
                  ],
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
    );
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

  // ── Searching splash (Phase 1) ──

  Widget _buildSearchingSplash(AppColors c) {
    return AnimatedOpacity(
      opacity: _searchingSplash ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 500),
      child: Container(
        color: const Color(0xFF1A1E23),
        child: Stack(
          children: [
            // Pulsing circle + dot in center of screen
            Center(
              child: AnimatedBuilder(
                animation: _pulseAnim,
                builder: (context, child) {
                  // _pulseAnim goes 0.9→1.1, map to 0→1 for the ring
                  final t = (_pulseAnim.value - 0.9) / 0.2; // 0..1
                  final ringSize = 60.0 + t * 180.0; // 60→240
                  final ringAlpha = (1.0 - t).clamp(0.0, 1.0) * 0.35;
                  return SizedBox(
                    width: 280,
                    height: 280,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        // Expanding ring
                        Container(
                          width: ringSize,
                          height: ringSize,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(
                              color: Colors.white.withValues(alpha: ringAlpha),
                              width: 2.0,
                            ),
                          ),
                        ),
                        // Static subtle fill circle
                        Container(
                          width: 60,
                          height: 60,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white.withValues(alpha: 0.05),
                          ),
                        ),
                        // Center dot
                        Container(
                          width: 10,
                          height: 10,
                          decoration: const BoxDecoration(
                            shape: BoxShape.circle,
                            color: Colors.white,
                          ),
                        ),
                      ],
                    ),
                  );
                },
              ),
            ),
            // Bottom info
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // "Looking for ride" text + progress
                      Text(
                        S.of(context).lookingForRide,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                          color: Colors.white.withValues(alpha: 0.9),
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _ctrl.state.selectedOption?.name ?? '',
                        style: TextStyle(
                          fontSize: 14,
                          color: Colors.white.withValues(alpha: 0.45),
                        ),
                      ),
                      const SizedBox(height: 16),
                      SizedBox(
                        width: 200,
                        child: LinearProgressIndicator(
                          backgroundColor: Colors.white.withValues(alpha: 0.08),
                          valueColor: AlwaysStoppedAnimation(c.gold),
                        ),
                      ),
                      const SizedBox(height: 16),
                      TextButton(
                        onPressed: _confirmCancelSearching,
                        child: Text(
                          S.of(context).cancel,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.45),
                          ),
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
            final linked = _linkedPaymentMethods.contains(
              _selectedPaymentMethod,
            );
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
                                  errorBuilder: (_, _, _) => Icon(
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

                    // Payment method selector
                    GestureDetector(
                      onTap: () {
                        Navigator.pop(ctx);
                        _showPaymentMethodPicker(c, option);
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.06),
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: c.gold.withValues(alpha: 0.25),
                            width: 1,
                          ),
                        ),
                        child: Row(
                          children: [
                            _paymentLogoWidget(_selectedPaymentMethod, 36),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    _paymentLabel(_selectedPaymentMethod),
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 15,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                  const SizedBox(height: 1),
                                  Text(
                                    linked
                                        ? S.of(context).tapToChange
                                        : S.of(context).notAddedTapToSetUp,
                                    style: TextStyle(
                                      color: linked
                                          ? Colors.white.withValues(alpha: 0.4)
                                          : Colors.white,
                                      fontSize: 12,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            Icon(
                              Icons.chevron_right_rounded,
                              color: Colors.white.withValues(alpha: 0.4),
                              size: 22,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),

                    // Pay / Add-method button
                    if (!linked)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            backgroundColor: c.gold,
                            foregroundColor: Colors.black,
                            elevation: 0,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(16),
                            ),
                            padding: const EdgeInsets.symmetric(vertical: 16),
                          ),
                          onPressed: () async {
                            Navigator.pop(ctx);
                            await Navigator.of(context).push(
                              slideFromRightRoute(
                                const PaymentAccountsScreen(),
                              ),
                            );
                            await _loadLinkedPayments();
                            if (mounted) _showPaymentSheet(c, option);
                          },
                          child: Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(Icons.link_rounded, size: 18),
                              SizedBox(width: 8),
                              Text(
                                S.of(context).addPaymentMethod,
                                style: const TextStyle(
                                  fontSize: 17,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: -0.2,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      SizedBox(
                        width: double.infinity,
                        height: 54,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: _isProcessingPayment
                                ? LinearGradient(
                                    colors: [
                                      c.gold.withValues(alpha: 0.5),
                                      c.goldLight.withValues(alpha: 0.5),
                                    ],
                                  )
                                : LinearGradient(colors: [c.gold, c.goldLight]),
                            borderRadius: BorderRadius.circular(16),
                          ),
                          child: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.transparent,
                              shadowColor: Colors.transparent,
                              foregroundColor: Colors.black,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(16),
                              ),
                              padding: const EdgeInsets.symmetric(vertical: 16),
                            ),
                            onPressed: _isProcessingPayment
                                ? null
                                : () => _processPayment(
                                    ctx,
                                    c,
                                    option,
                                    setSheetState,
                                  ),
                            child: _isProcessingPayment
                                ? const SizedBox(
                                    width: 24,
                                    height: 24,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2.5,
                                      color: Colors.black54,
                                    ),
                                  )
                                : Row(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    children: [
                                      const Icon(Icons.lock_rounded, size: 16),
                                      const SizedBox(width: 8),
                                      Text(
                                        S.of(context).payPrice(price),
                                        style: const TextStyle(
                                          fontSize: 17,
                                          fontWeight: FontWeight.w800,
                                          letterSpacing: -0.2,
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
            );
          },
        );
      },
    );
  }

  /// Processes payment: verifies linked method, checks Stripe PM ID for cards,
  /// charges payment. If anything fails → shows Declined dialog, stays on sheet.
  Future<void> _processPayment(
    BuildContext ctx,
    AppColors c,
    RideOption? option,
    void Function(void Function()) setSheetState,
  ) async {
    // 1. Double-check the method is actually linked
    if (!_linkedPaymentMethods.contains(_selectedPaymentMethod)) {
      _showDeclinedDialog(
        title: S.of(context).noPaymentMethod,
        message: S.of(context).addPaymentMethodMsg,
      );
      return;
    }

    // 2. For credit/debit card — verify a Stripe PaymentMethod ID exists
    if (_selectedPaymentMethod == 'credit_card') {
      final pmId = await LocalDataService.getStripePaymentMethodId();
      if (pmId == null || pmId.isEmpty) {
        _showDeclinedDialog(
          title: S.of(context).cardNotValid,
          message: S.of(context).cardNotValidMsg,
        );
        return;
      }
    }

    // 3. Show loading spinner
    setSheetState(() => _isProcessingPayment = true);
    setState(() => _isProcessingPayment = true);

    try {
      // Process payment (Stripe integration pending — validates linked method)
      await Future.delayed(const Duration(seconds: 2));

      // ── Check if payment was "approved" ──
      // For now we accept all linked methods. When you add real Stripe
      // charging, replace this with the charge result.
      // final bool paymentApproved = chargeResult.success;

      if (!mounted) return;

      // Success — close sheet and start ride search
      setSheetState(() => _isProcessingPayment = false);
      setState(() => _isProcessingPayment = false);
      Navigator.of(context).pop();
      if (widget.applyPromo) await LocalDataService.setPromoUsed();

      // If this is a scheduled trip, create via API and navigate to scheduled rides
      if (_ctrl.state.scheduledAt != null) {
        await _createScheduledTrip();
        return;
      }
      _ctrl.requestRide();
    } catch (e) {
      if (!mounted) return;
      setSheetState(() => _isProcessingPayment = false);
      setState(() => _isProcessingPayment = false);
      Navigator.of(context).pop();
      _showDeclinedDialog(
        title: S.of(context).paymentDeclined,
        message: S.of(context).paymentDeclinedMsg,
      );
    }
  }

  /// Processes payment directly from the route preview sheet (no popup).
  Future<void> _startRideDirectly(AppColors c, RideOption? option) async {
    // 1. Check linked payment method
    if (!_linkedPaymentMethods.contains(_selectedPaymentMethod)) {
      _showDeclinedDialog(
        title: S.of(context).noPaymentMethod,
        message: S.of(context).addPaymentMethodMsg,
      );
      return;
    }

    // 2. For credit/debit card — verify Stripe PM ID
    if (_selectedPaymentMethod == 'credit_card') {
      final pmId = await LocalDataService.getStripePaymentMethodId();
      if (pmId == null || pmId.isEmpty) {
        _showDeclinedDialog(
          title: S.of(context).cardNotValid,
          message: S.of(context).cardNotValidMsg,
        );
        return;
      }
    }

    // 3. Show loading
    setState(() => _isProcessingPayment = true);

    try {
      await Future.delayed(const Duration(seconds: 2));
      if (!mounted) return;
      setState(() => _isProcessingPayment = false);
      if (widget.applyPromo) await LocalDataService.setPromoUsed();

      // If this is a scheduled trip, create via API and navigate to scheduled rides
      if (_ctrl.state.scheduledAt != null) {
        await _createScheduledTrip();
        return;
      }
      _ctrl.requestRide();
    } catch (e) {
      if (!mounted) return;
      setState(() => _isProcessingPayment = false);
      _showDeclinedDialog(
        title: S.of(context).paymentDeclined,
        message: S.of(context).paymentDeclinedMsg,
      );
    }
  }

  /// Creates a scheduled trip via the backend API and navigates to the scheduled rides list.
  Future<void> _createScheduledTrip() async {
    try {
      final userId = await ApiService.getCurrentUserId();
      if (userId == null || !mounted) return;

      final state = _ctrl.state;
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
      ('google_pay', 'Google Pay'),
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
                  final linked = _linkedPaymentMethods.contains(id);
                  return GestureDetector(
                    onTap: () {
                      setState(() => _selectedPaymentMethod = id);
                      Navigator.pop(ctx);
                      // If not linked and it's credit card, open credit card screen
                      if (!linked && id == 'credit_card') {
                        _openCreditCardScreen(c, option);
                        return;
                      }
                      if (!linked) {
                        _openPaymentAccountsAndReturn(c, option);
                        return;
                      }
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
                                if (!linked)
                                  Text(
                                    loc.notAdded,
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
                              color: c.gold,
                              size: 22,
                            )
                          else if (linked)
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
                            )
                          else
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: c.gold,
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                loc.addBtn,
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
        return 'Google Pay';
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
            ),
          ),
        );
      case 'credit_card':
        if (_savedCardBrand != null) {
          final Map<String, ({String letter, Color color, bool italic})>
          brands = {
            'visa': (letter: 'V', color: const Color(0xFF1A1F71), italic: true),
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

  void _cancelSearching() {
    _searchMapTimer?.cancel();
    _searchMapTimer = null;
    _splashTimer?.cancel();
    _splashTimer = null;
    _searchingShowMap = false;
    _searchingSplash = false;
    _ctrl.cancelRide();
    _ctrl.reset();
    _navigatingToTracking = false;
    setState(() {
      _markers = {};
      _polylines = {};
    });
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

  /// Bottom card shown after 4 seconds — map is visible behind
  Widget _buildSearchingBottomCard(AppColors c) {
    final option = _ctrl.state.selectedOption;
    final s = _ctrl.state;
    final pickupAddr = s.pickupLabel.isNotEmpty
        ? s.pickupLabel
        : S.of(context).pickupLocation;
    final dropoffAddr = s.dropoffLabel.isNotEmpty
        ? s.dropoffLabel
        : S.of(context).destination;
    // Parse ETA from route durationText (e.g. "12 mins") or fallback to option
    int etaMin = option?.etaMinutes ?? 0;
    if (s.route != null && s.route!.durationText.isNotEmpty) {
      final m = RegExp(r'(\d+)').firstMatch(s.route!.durationText);
      if (m != null) etaMin = int.tryParse(m.group(1)!) ?? etaMin;
    }
    final distMi = s.route != null ? (s.route!.distanceMeters / 1609.34) : null;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: Container(
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A1A),
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
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
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                const SizedBox(height: 14),

                // "Looking for ride" with progress bar
                Row(
                  children: [
                    SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: c.gold,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      S.of(context).lookingForRide,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),

                // Progress bar
                ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: SizedBox(
                    height: 3,
                    child: LinearProgressIndicator(
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      valueColor: AlwaysStoppedAnimation(c.gold),
                    ),
                  ),
                ),
                const SizedBox(height: 14),

                // Cancel button
                SizedBox(
                  width: double.infinity,
                  height: 48,
                  child: TextButton(
                    onPressed: _confirmCancelSearching,
                    style: TextButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.06),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                    child: Text(
                      S.of(context).cancel,
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                        color: Colors.white.withValues(alpha: 0.6),
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
    );
  }

  void _recenterMap() {
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
      _mapCtrl?.animateCamera(CameraUpdate.newLatLngBounds(bounds, 80));
      _appleMapCtrl?.animateCamera(
        amap.CameraUpdate.newLatLngBounds(
          amap.LatLngBounds(
            southwest: amap.LatLng(
              bounds.southwest.latitude,
              bounds.southwest.longitude,
            ),
            northeast: amap.LatLng(
              bounds.northeast.latitude,
              bounds.northeast.longitude,
            ),
          ),
          80,
        ),
      );
    } else if (_userLocation != null) {
      _mapCtrl?.animateCamera(CameraUpdate.newLatLngZoom(_userLocation!, 15.5));
      _appleMapCtrl?.animateCamera(
        amap.CameraUpdate.newCameraPosition(
          amap.CameraPosition(
            target: amap.LatLng(
              _userLocation!.latitude,
              _userLocation!.longitude,
            ),
            zoom: 15.5,
          ),
        ),
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
