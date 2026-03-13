import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as amap;
import 'package:geolocator/geolocator.dart';
import 'package:permission_handler/permission_handler.dart'
    show openAppSettings;
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import '../../services/api_service.dart';
import '../../services/navigation_service.dart';
import '../../services/trip_firestore_service.dart';
import '../../config/api_keys.dart';
import '../../config/map_styles.dart';
import '../../l10n/app_localizations.dart';
import '../chat_screen.dart';
import '../safety_screen.dart';
import '../../navigation/car_icon_loader.dart';
import 'driver_info_pages.dart';
import 'driver_earnings_screen.dart';
import 'driver_promos_screen.dart';
import 'driver_analytics_screen.dart';
import 'driver_inbox_screen.dart';
import '../../services/map_launcher_service.dart';

// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
//  CRUISE DRIVER — ONLINE SCREEN
//  Uber Driver–style: Finding trips bar, trip request card,
//  real-time driver movement, smooth transitions, all backend
// â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•

class DriverOnlineScreen extends StatefulWidget {
  final LatLng? initialPos;
  final double initialHeading;
  final String? photoUrl;
  const DriverOnlineScreen({
    super.key,
    this.initialPos,
    this.initialHeading = 0,
    this.photoUrl,
  });
  @override
  State<DriverOnlineScreen> createState() => _DriverOnlineScreenState();
}

enum _Phase {
  searching,
  rideRequest,
  enRouteToPickup,
  arrivedAtPickup,
  routeSummary, // Google Maps-style route overview before navigation
  inTrip,
  completed,
}

class _DriverOnlineScreenState extends State<DriverOnlineScreen>
    with TickerProviderStateMixin {
  // â”€â”€ Brand â”€â”€
  static const _gold = Color(0xFFD4A843);
  static const _goldLight = Color(0xFFF5D990);

  // —— Map ——
  GoogleMapController? _map;
  amap.AppleMapController? _appleMap;
  LatLng _pos = const LatLng(25.7617, -80.1918);
  Set<Marker> _markers = {};
  Set<Polyline> _polylines = {};
  StreamSubscription<Position>? _posStream;
  bool _lastStyleDark = true;

  /// Animate camera on both platforms.
  void _animateToPosition(
    LatLng pos, {
    double zoom = 15.5,
    double bearing = 0,
    double tilt = 0,
  }) {
    if (Platform.isIOS) {
      _appleMap?.moveCamera(
        amap.CameraUpdate.newCameraPosition(
          amap.CameraPosition(
            target: amap.LatLng(pos.latitude, pos.longitude),
            zoom: zoom,
            heading: bearing,
            pitch: tilt,
          ),
        ),
      );
    } else {
      _map?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: pos, zoom: zoom, bearing: bearing, tilt: tilt),
        ),
      );
    }
  }

  void _moveToLatLng(LatLng pos) {
    if (Platform.isIOS) {
      _appleMap?.moveCamera(
        amap.CameraUpdate.newLatLng(
          amap.LatLng(pos.latitude, pos.longitude),
        ),
      );
    } else {
      _map?.animateCamera(CameraUpdate.newLatLng(pos));
    }
  }

  // â”€â”€ Trip â”€â”€
  _Phase _phase = _Phase.searching;
  int? _tripId;
  int? _driverId;
  int? _currentOfferId;

  // â”€â”€ Pending ride offers (stacked cards, Spark-style) â”€â”€
  List<Map<String, dynamic>> _pendingOffers = [];
  bool _offersExpanded = true;

  // â”€â”€ Simulation Mode â”€â”€
  bool _isSimulationMode = false;
  int _simulatedTripCounter = 0;

  // â”€â”€ Route preview for a tapped offer â”€â”€
  Map<String, dynamic>? _previewingOffer;
  Set<Polyline> _savedPolylines = {};
  Set<Marker> _savedMarkers = {};

  // â”€â”€ Request data (for active trip after acceptance) â”€â”€
  Timer? _pollT;
  String _riderName = '';
  String _riderInit = '';
  String _riderPhone = '';
  String _pickupAddr = '';
  String _dropoffAddr = '';
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
  Timer? _navTimer;

  // â”€â”€ Session â”€â”€
  double _earnings = 0;
  int _trips = 0;
  Duration _online = Duration.zero;
  Timer? _clock;

  // â”€â”€ Driver smooth animation â”€â”€
  late AnimationController _driverAnim;
  LatLng _animFrom = const LatLng(0, 0);
  LatLng _animTo = const LatLng(0, 0);
  double _heading = 0;
  double _smoothedBearing = 0;
  BitmapDescriptor? _arrowIcon;

  // -- Vehicle-based markers (asset images) --
  BitmapDescriptor? _suvIcon; // Suburban
  BitmapDescriptor? _sedanIcon; // Fusion / Camry
  final String _activeVehicleAsset = 'suburban'; // which asset to use

  // -- Golden animated dot (Apple Maps-style, gold) --
  List<BitmapDescriptor> _goldenDotFrames = [];
  int _goldenDotFrame = 0;
  Timer? _goldenDotTimer;

  // -- Turn-by-turn navigation --
  final NavigationService _navService = NavigationService();
  NavRoute? _currentNavRoute;
  NavigationState? _navState;
  bool _isRerouting = false;
  int _rerouteCount = 0;
  DateTime? _lastRerouteTime;
  // â”€â”€ UI animations â”€â”€
  late AnimationController _reqCtrl;
  late Animation<Offset> _reqSlide; // ignore: unused_field
  late AnimationController _doneCtrl;
  late Animation<double> _doneScale;
  late AnimationController _searchPulse;
  late Animation<double> _searchPulseVal;

  // â”€â”€ Slide confirm â”€â”€
  double _slideVal = 0;
  bool _slid = false;
  int _stars = 5;

  // â”€â”€ GPS simulation (dev) â”€â”€
  Ticker? _simTicker;
  double _simTraveledM = 0;
  double _simTotalM = 0;
  List<double> _simCumDist = [];
  double _simPrevBearing = 0;
  DateTime? _simLastBackend;
  DateTime? _simLastCamera;
  DateTime? _simLastTrim;

  // -- Camera follow mode --
  bool _cameraFollowing = true;
  Timer? _reFollowTimer;

  // â”€â”€ Draggable panel â”€â”€
  bool _panelOpen = false;
  final _panelSheetCtrl = DraggableScrollableController();

  // -- Earnings pill swipe --
  double _weeklyEarnings = 0;
  double _lastTripEarnings = 0;
  final _earningsPageCtrl = PageController(initialPage: 1);
  int _earningsPage = 1; // 0=weekly, 1=today, 2=last trip

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  LIFECYCLE
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  @override
  void initState() {
    super.initState();
    // Apply initial position from home screen (avoids white flash)
    if (widget.initialPos != null) {
      _pos = widget.initialPos!;
      _heading = widget.initialHeading;
    }

    _driverAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 500),
    );
    _driverAnim.addListener(_onDriverAnimTick);

    _reqCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
    );
    _reqSlide = Tween<Offset>(
      begin: const Offset(0, 1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _reqCtrl, curve: Curves.easeOutCubic));

    _doneCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _doneScale = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _doneCtrl, curve: Curves.elasticOut));

    _searchPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _searchPulseVal = Tween<double>(begin: 0.0, end: 1.0).animate(_searchPulse);

    _boot();
  }

  @override
  void dispose() {
    _driverAnim.removeListener(_onDriverAnimTick);
    _driverAnim.dispose();
    _reqCtrl.dispose();
    _doneCtrl.dispose();
    _searchPulse.dispose();
    _pollT?.cancel();
    _clock?.cancel();
    _navTimer?.cancel();
    _goldenDotTimer?.cancel();
    _driverPhotoImage?.dispose();
    _simTicker?.stop();
    _simTicker?.dispose();
    _posStream?.cancel();
    _reFollowTimer?.cancel();
    _panelSheetCtrl.dispose();
    _earningsPageCtrl.dispose();
    _map?.dispose();
    super.dispose();
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BOOT
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _boot() async {
    // Retry getting driver ID up to 3 times (critical for dispatch)
    for (int attempt = 1; attempt <= 3; attempt++) {
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('âœ… Got driverId=$_driverId on attempt $attempt');
          break;
        }
      } catch (e) {
        debugPrint('âš ï¸ getCurrentUserId attempt $attempt failed: $e');
      }
      if (attempt < 3) await Future.delayed(const Duration(seconds: 1));
    }
    if (_driverId == null) {
      debugPrint('âŒ Could not get driver ID after 3 attempts');
    }
    await _locate();
    await _buildVehicleIcons();
    _goOnlineBackend();
    _startClock();
    _startPolling();
    _startPosStream();
    _loadWeeklyEarnings();
  }

  Future<void> _loadWeeklyEarnings() async {
    try {
      final data = await ApiService.getDriverEarnings(period: 'week');
      if (mounted) {
        setState(() {
          _weeklyEarnings = (data['total'] as num?)?.toDouble() ?? 0;
        });
      }
    } catch (_) {}
  }

  Future<void> _locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationServicesDisabledMsg),
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
      var p = await Geolocator.checkPermission();
      if (p == LocationPermission.denied) {
        p = await Geolocator.requestPermission();
        if (p == LocationPermission.denied) return;
      }
      if (p == LocationPermission.deniedForever) {
        if (mounted) {
          showDialog(
            context: context,
            builder: (ctx) => AlertDialog(
              title: Text(S.of(ctx).locationPermissionRequired),
              content: Text(S.of(ctx).locationRequiredForDriver),
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
      final pos = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
          timeLimit: Duration(seconds: 15),
        ),
      );
      if (!mounted) return;
      setState(() => _pos = LatLng(pos.latitude, pos.longitude));
      _moveToLatLng(_pos);
    } catch (_) {}
  }

  // â”€â”€ Build Uber-style 3D car marker sprites at runtime â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€â”€
  ui.Image? _driverPhotoImage; // decoded driver photo for marker

  Future<void> _buildVehicleIcons() async {
    _suvIcon = await CarIconLoader.loadForRide('Suburban');
    _sedanIcon = await CarIconLoader.loadForRide('Camry');
    _arrowIcon = _suvIcon;
    await _loadDriverPhoto();
    await _buildGoldenDotFrames();
    _startGoldenDotAnimation();
    if (mounted) setState(() {});
  }

  /// Download and decode the driver's profile photo for the map marker.
  Future<void> _loadDriverPhoto() async {
    final url = widget.photoUrl;
    if (url == null || url.isEmpty) return;
    try {
      final resp = await http.get(Uri.parse(url));
      if (resp.statusCode == 200) {
        final codec = await ui.instantiateImageCodec(resp.bodyBytes);
        final frame = await codec.getNextFrame();
        _driverPhotoImage = frame.image;
      }
    } catch (_) {
      // fallback to golden dot
    }
  }

  /// Pre-render 12 frames of the driver marker.
  /// If a photo is available: circular photo with gold border + pulsing ring.
  /// Otherwise: pulsing golden dot (Apple Maps blue dot style).
  Future<void> _buildGoldenDotFrames() async {
    const int frameCount = 12;
    const double canvasSize = 160.0;
    const double photoRadius = 28.0;
    const double borderWidth = 4.0;
    final frames = <BitmapDescriptor>[];
    final hasPhoto = _driverPhotoImage != null;

    for (int i = 0; i < frameCount; i++) {
      final t = i / frameCount;
      final pulseRadius = 48.0 + 24.0 * t;
      final pulseAlpha = (0.35 * (1.0 - t)).clamp(0.0, 1.0);

      final recorder = ui.PictureRecorder();
      final canvas = Canvas(
        recorder,
        const Rect.fromLTWH(0, 0, canvasSize, canvasSize),
      );
      final center = const Offset(canvasSize / 2, canvasSize / 2);

      // Outer pulse ring (fading gold ring)
      canvas.drawCircle(
        center,
        pulseRadius,
        Paint()
          ..color = const Color(0xFFE8C547).withValues(alpha: pulseAlpha * 0.5)
          ..style = PaintingStyle.fill,
      );
      canvas.drawCircle(
        center,
        pulseRadius,
        Paint()
          ..color = const Color(0xFFE8C547).withValues(alpha: pulseAlpha)
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3,
      );

      if (hasPhoto) {
        // Shadow under photo circle
        canvas.drawCircle(
          center.translate(0, 2),
          photoRadius + borderWidth / 2,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.3)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );

        // Gold border
        canvas.drawCircle(
          center,
          photoRadius + borderWidth / 2,
          Paint()
            ..shader =
                const RadialGradient(
                  colors: [Color(0xFFF5D990), Color(0xFFD4A843)],
                ).createShader(
                  Rect.fromCircle(
                    center: center,
                    radius: photoRadius + borderWidth,
                  ),
                ),
        );

        // Clip and draw photo
        canvas.save();
        canvas.clipPath(
          Path()..addOval(Rect.fromCircle(center: center, radius: photoRadius)),
        );
        final src = Rect.fromLTWH(
          0,
          0,
          _driverPhotoImage!.width.toDouble(),
          _driverPhotoImage!.height.toDouble(),
        );
        final dst = Rect.fromCircle(center: center, radius: photoRadius);
        canvas.drawImageRect(_driverPhotoImage!, src, dst, Paint());
        canvas.restore();

        // White inner border for polish
        canvas.drawCircle(
          center,
          photoRadius,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2,
        );
      } else {
        // Fallback: golden dot
        canvas.drawCircle(
          center.translate(0, 2),
          22,
          Paint()
            ..color = Colors.black.withValues(alpha: 0.25)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
        );
        canvas.drawCircle(
          center,
          20,
          Paint()
            ..shader = const RadialGradient(
              colors: [Color(0xFFF5D990), Color(0xFFD4A843)],
            ).createShader(Rect.fromCircle(center: center, radius: 20)),
        );
        canvas.drawCircle(
          center,
          20,
          Paint()
            ..color = Colors.white
            ..style = PaintingStyle.stroke
            ..strokeWidth = 4,
        );
        canvas.drawCircle(
          center.translate(-4, -4),
          7,
          Paint()
            ..color = Colors.white.withValues(alpha: 0.45)
            ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
        );
      }

      final picture = recorder.endRecording();
      final image = await picture.toImage(
        canvasSize.toInt(),
        canvasSize.toInt(),
      );
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      if (byteData != null) {
        frames.add(
          BitmapDescriptor.bytes(
            byteData.buffer.asUint8List(),
            width: 56,
            height: 56,
          ),
        );
      }
    }
    _goldenDotFrames = frames;
  }

  void _startGoldenDotAnimation() {
    _goldenDotTimer?.cancel();
    _goldenDotTimer = Timer.periodic(const Duration(milliseconds: 130), (_) {
      if (!mounted || _goldenDotFrames.isEmpty) return;
      setState(() {
        _goldenDotFrame = (_goldenDotFrame + 1) % _goldenDotFrames.length;
      });
    });
  }

  /// Renders a single car marker sprite using Canvas.
  ///  - Car points UP (north) so `rotation = bearing` works correctly.
  ///  - Isometric 3/4 top-down view with 3D depth.
  ///  - Transparent background + soft shadow.
  Future<BitmapDescriptor> _paintCarSprite({
    required Color bodyColor,
    required Color bodyHighlight,
    required Color windowColor,
    required Color windowShine,
    required Color trimColor,
    required Color wheelColor,
    required Color shadowColor,
    required Color headlightColor,
    required Color taillightColor,
    required double widthRatio,
    required double heightRatio,
    required double roofHeightRatio,
  }) async {
    // Canvas — front of car = TOP, rear = BOTTOM
    // Proportions matched to reference photos: wide body, circular wheels, large cabin
    const double cW = 200.0;
    const double cH = 300.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, cW, cH));

    final double cx = cW / 2;
    final double cy = cH / 2;

    // Body half-extents (slightly wider ratio like the reference)
    final double bW = 78.0 * widthRatio; // half-width  → full = 156px
    final double bH = 110.0 * heightRatio; // half-height → full = 220px

    // ── 1. DROP SHADOW ───────────────────────────────────────────────────
    canvas.drawOval(
      Rect.fromCenter(
        center: Offset(cx + 3, cy + 5),
        width: (bW + 22) * 2,
        height: (bH + 16) * 2,
      ),
      Paint()
        ..color = shadowColor
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 18),
    );

    // ── 2. WHEELS (drawn BEFORE body so edges peek out from under it) ────
    // Wheel radius: near-circular, slightly taller than wide (top-down view)
    final double wW = 34.0 * widthRatio; // wheel width
    final double wH = 42.0 * heightRatio; // wheel height
    final wheelPositions = <Offset>[
      Offset(cx - bW * 0.88, cy - bH * 0.62), // front-left
      Offset(cx + bW * 0.88, cy - bH * 0.62), // front-right
      Offset(cx - bW * 0.88, cy + bH * 0.60), // rear-left
      Offset(cx + bW * 0.88, cy + bH * 0.60), // rear-right
    ];
    for (final wp in wheelPositions) {
      // Dark tyre
      canvas.drawOval(
        Rect.fromCenter(center: wp, width: wW, height: wH),
        Paint()..color = wheelColor,
      );
      // Small rim highlight
      canvas.drawOval(
        Rect.fromCenter(center: wp, width: wW * 0.44, height: wH * 0.44),
        Paint()..color = const Color(0xFF888888),
      );
    }

    // ── 3. BODY ──────────────────────────────────────────────────────────
    // Front (top): very round nose — matches photo's pointed oval front
    // Rear (bottom): slightly less rounded
    final bodyRect = Rect.fromCenter(
      center: Offset(cx, cy),
      width: bW * 2,
      height: bH * 2,
    );
    final bodyRRect = RRect.fromRectAndCorners(
      bodyRect,
      topLeft: Radius.circular(bW * 0.72),
      topRight: Radius.circular(bW * 0.72),
      bottomLeft: Radius.circular(bW * 0.40),
      bottomRight: Radius.circular(bW * 0.40),
    );
    // Solid base color + very subtle top highlight (flat look)
    canvas.drawRRect(bodyRRect, Paint()..color = bodyColor);
    // Soft highlight sweep on upper-left (light source top-left)
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..shader = RadialGradient(
          center: const Alignment(-0.3, -0.55),
          radius: 0.85,
          colors: [bodyHighlight, bodyColor],
        ).createShader(bodyRect),
    );

    // ── 4. BODY BORDER (thin dark outline matching photos) ───────────────
    canvas.drawRRect(
      bodyRRect,
      Paint()
        ..color = const Color(0xFFBBBBBB)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5,
    );

    // ── 5. CABIN / GREENHOUSE ────────────────────────────────────────────
    // 3D DEPTH PANELS — dark side/bottom strips visible under camera tilt.
    // With flat:false billboard mode at 55° tilt these strips simulate the
    // extruded side-panels and bumper thickness of a real car body.
    // Left side strip
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(cx - bW - 14, cy - bH * 0.72, 14, bH * 1.60),
        bottomLeft: Radius.circular(bW * 0.38),
      ),
      Paint()..color = const Color(0x50000000),
    );
    // Right side strip
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(cx + bW, cy - bH * 0.72, 14, bH * 1.60),
        bottomRight: Radius.circular(bW * 0.38),
      ),
      Paint()..color = const Color(0x3A000000),
    );
    // Bottom face strip — bumper thickness (rear of car, visible when tilted)
    canvas.drawRRect(
      RRect.fromRectAndCorners(
        Rect.fromLTWH(cx - bW + 5, cy + bH + 1, bW * 2 - 10, 18),
        bottomLeft: Radius.circular(bW * 0.38),
        bottomRight: Radius.circular(bW * 0.38),
      ),
      Paint()..color = const Color(0x5A000000),
    );

    // In the reference photos the cabin is a large dark rounded rectangle
    // spanning ~52% of body height, centered slightly toward the front
    final double cabinH = bH * 1.04; // total cabin height
    final double cabinCy = cy - bH * 0.04; // center slightly forward
    final cabinRRect = RRect.fromRectAndCorners(
      Rect.fromCenter(
        center: Offset(cx, cabinCy),
        width: bW * 1.28,
        height: cabinH,
      ),
      topLeft: Radius.circular(bW * 0.48),
      topRight: Radius.circular(bW * 0.48),
      bottomLeft: Radius.circular(bW * 0.22),
      bottomRight: Radius.circular(bW * 0.22),
    );
    canvas.drawRRect(cabinRRect, Paint()..color = windowColor);

    // Gloss sheen — left side streak seen in photo 2
    final sheen = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Rect.fromLTWH(
            cx - bW * 0.56,
            cabinCy - cabinH / 2 + 6,
            bW * 0.22,
            cabinH * 0.50,
          ),
          const Radius.circular(8),
        ),
      );
    canvas.drawPath(
      sheen,
      Paint()..color = windowShine.withValues(alpha: 0.18),
    );

    // ── 6. HEADLIGHTS — two small white/yellow rectangles at front corners ─
    final double hlY = cy - bH * 0.88;
    for (final sign in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + sign * bW * 0.46, hlY),
            width: bW * 0.38,
            height: 9,
          ),
          const Radius.circular(4),
        ),
        Paint()..color = headlightColor,
      );
    }

    // ── 7. TAILLIGHTS — thin red bars at rear corners ────────────────────
    final double tlY = cy + bH * 0.88;
    for (final sign in [-1.0, 1.0]) {
      canvas.drawRRect(
        RRect.fromRectAndRadius(
          Rect.fromCenter(
            center: Offset(cx + sign * bW * 0.44, tlY),
            width: bW * 0.36,
            height: 7,
          ),
          const Radius.circular(3),
        ),
        Paint()..color = taillightColor,
      );
    }

    // ── 8. ENCODE ────────────────────────────────────────────────────────
    final picture = recorder.endRecording();
    final image = await picture.toImage(cW.toInt(), cH.toInt());
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    if (byteData == null) return BitmapDescriptor.defaultMarker;
    return BitmapDescriptor.bytes(
      byteData.buffer.asUint8List(),
      width: 40,
      height: 60,
    );
  }

  /// Get the correct vehicle icon based on the vehicle type of the active trip.
  /// Robust mapping: trim + toLowerCase, handles "CruiseX" and unknown types.
  BitmapDescriptor? get _vehicleIcon {
    final vt = _vehicleType.trim().toLowerCase();
    // Suburban / SUV → black SUV sprite
    if (vt.contains('suburban') || vt.contains('suv')) {
      return _suvIcon;
    }
    // Fusion / Camry / sedan → white sedan sprite
    if (vt.contains('fusion') || vt.contains('camry') || vt.contains('sedan')) {
      return _sedanIcon;
    }
    // Explicit mapping for known brand names
    if (vt.contains('cruisex') || vt.contains('cruise')) {
      return _sedanIcon; // CruiseX = sedan class
    }
    // Default: use SUV icon when searching (no active trip) or unknown type
    return _suvIcon;
  }

  void _goOnlineBackend() {
    if (_driverId == null) {
      debugPrint('âš ï¸ _goOnlineBackend: _driverId is null, skipping');
      return;
    }
    debugPrint(
      'ðŸŸ¢ Going online: driverId=$_driverId lat=${_pos.latitude} lng=${_pos.longitude}',
    );
    ApiService.updateDriverLocation(
          driverId: _driverId!,
          lat: _pos.latitude,
          lng: _pos.longitude,
          isOnline: true,
        )
        .then((_) {
          debugPrint('âœ… Driver online successfully');
        })
        .catchError((e) {
          debugPrint('âŒ Failed to go online: $e');
        });
  }

  void _goOfflineBackend() {
    if (_driverId == null) return;
    ApiService.updateDriverLocation(
      driverId: _driverId!,
      lat: _pos.latitude,
      lng: _pos.longitude,
      isOnline: false,
    ).catchError((_) => <String, dynamic>{});
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  DRIVER POSITION STREAM (smooth movement on map)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startPosStream() {
    _posStream =
        Geolocator.getPositionStream(
          locationSettings: const LocationSettings(
            accuracy: LocationAccuracy.bestForNavigation,
            distanceFilter: 1,
          ),
        ).listen((pos) {
          if (!mounted) return;
          final newLL = LatLng(pos.latitude, pos.longitude);
          _smoothedBearing = _lerpAngle(_smoothedBearing, pos.heading, 0.15);
          // Snap to route polyline — prevents GPS drift off-road
          final snappedLL = _snapToRoute(newLL);
          _smoothMoveTo(snappedLL, _smoothedBearing);

          // â”€â”€ Trim route behind driver (Google Maps style) â”€â”€
          _trimRouteBehindDriver(snappedLL);

          // â”€â”€ Phase-aware camera following â”€â”€
          if (_phase == _Phase.searching) {
            // IDLE: stable top-down view, no tilt, no bearing follow (Uber style)
            if (Platform.isIOS) {
              _appleMap?.moveCamera(
                amap.CameraUpdate.newCameraPosition(
                  amap.CameraPosition(
                    target: amap.LatLng(newLL.latitude, newLL.longitude),
                    zoom: 15.5,
                  ),
                ),
              );
            } else {
              _map?.animateCamera(
                CameraUpdate.newCameraPosition(
                  CameraPosition(
                    target: newLL,
                    zoom: 15.5,
                    bearing: 0,
                    tilt: 0,
                  ),
                ),
              );
            }
          } else if (_phase == _Phase.routeSummary) {
            // Route summary: keep overview, don't follow driver
            // Just update position & nav stats silently
            final dist = _hav(newLL, _dropoffLL);
            final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
            setState(() {
              _navDist = dist;
              _navEta = eta;
            });
          } else if (_phase == _Phase.enRouteToPickup) {
            // TRIP: Uber-style 2.5D follow — tilt 55, zoom 17.5
            if (_cameraFollowing) {
              _animateToPosition(newLL, zoom: 17.5, bearing: _smoothedBearing, tilt: 55);
            }
            // Update turn-by-turn nav state
            _updateNavState(newLL);
            // Update nav stats
            final dist = _hav(newLL, _pickupLL);
            final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
            final progress = _distToPickup > 0
                ? (1.0 - dist / _distToPickup).clamp(0.0, 1.0)
                : 0.0;
            setState(() {
              _navDist = dist;
              _navEta = eta;
              _navProgress = progress;
            });
            // â”€â”€ Proximity detection: auto-arrive at pickup â”€â”€
            if (dist < 0.05) {
              // ~50 meters
              _onNearPickup();
            }
          } else if (_phase == _Phase.inTrip) {
            // TRIP: Uber-style 2.5D follow — tilt 55, zoom 17.5
            if (_cameraFollowing) {
              _animateToPosition(newLL, zoom: 17.5, bearing: _smoothedBearing, tilt: 55);
            }
            // Update turn-by-turn nav state
            _updateNavState(newLL);
            // Update nav stats
            final dist = _hav(newLL, _dropoffLL);
            final eta = (dist * 1000 / 17.88 / 60).ceil().clamp(0, 99);
            final progress = _tripDist > 0
                ? (1.0 - dist / _tripDist).clamp(0.0, 1.0)
                : 0.0;
            setState(() {
              _navDist = dist;
              _navEta = eta;
              _navProgress = progress;
            });
            // â”€â”€ Proximity detection: auto-complete near dropoff â”€â”€
            if (dist < 0.05) {
              // ~50 meters
              _onNearDropoff();
            }
          }

          // Always update driver location to backend
          if (_driverId != null) {
            ApiService.updateDriverLocation(
              driverId: _driverId!,
              lat: pos.latitude,
              lng: pos.longitude,
            ).catchError((_) => <String, dynamic>{});
          }
          // Sync driver GPS to Firestore so rider tracking gets real position
          if (_tripId != null) {
            TripFirestoreService.syncDriverLocation(
              _tripId!.toString(),
              pos.latitude,
              pos.longitude,
              _smoothedBearing,
            );
          }
        }, onError: (_) {});
  }

  /// Update turn-by-turn navigation state from GPS position.
  void _updateNavState(LatLng pos) {
    if (!_navService.isNavigating) return;
    final state = _navService.updatePosition(pos);
    if (state == null) return;

    _navState = state;

    // Update displayed instruction & distance from NavigationService
    if (state.currentInstruction.isNotEmpty) {
      _navInstruct = state.currentInstruction;
    }
    _navEta = state.etaMinutes;
    _navDist = state.distanceRemainingMiles;
    _navProgress = state.progress;

    // Off-route detection & auto-reroute
    if (state.isOffRoute && !_isRerouting) {
      final now = DateTime.now();
      final canReroute =
          _lastRerouteTime == null ||
          now.difference(_lastRerouteTime!).inSeconds > 10;
      if (canReroute && _rerouteCount < 5) {
        _triggerReroute(pos);
      }
    }
  }

  /// Reroute from current position to the active destination.
  Future<void> _triggerReroute(LatLng from) async {
    if (_isRerouting) return;
    _isRerouting = true;
    _lastRerouteTime = DateTime.now();
    _rerouteCount++;
    debugPrint('Rerouting (#$_rerouteCount)');
    HapticFeedback.mediumImpact();

    final dest = _phase == _Phase.enRouteToPickup ? _pickupLL : _dropoffLL;
    final routeId = _phase == _Phase.enRouteToPickup ? 'pickup' : 'trip';
    final routeColor = _phase == _Phase.enRouteToPickup ? _goldLight : _gold;

    await _drawRoute(from, dest, routeId, routeColor);
    _isRerouting = false;
  }

  bool _nearPickupNotified = false;
  bool _nearDropoffNotified = false;

  void _onNearPickup() {
    if (_nearPickupNotified || _phase != _Phase.enRouteToPickup) return;
    _nearPickupNotified = true;
    _simTicker?.stop();
    HapticFeedback.heavyImpact();
    // Send final position to backend so rider sees driver at pickup
    if (_driverId != null) {
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _pickupLL.latitude,
        lng: _pickupLL.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    // Show ARRIVED button
    setState(() {});
  }

  void _onNearDropoff() {
    if (_nearDropoffNotified || _phase != _Phase.inTrip) return;
    _nearDropoffNotified = true;
    _simTicker?.stop();
    HapticFeedback.heavyImpact();
    // Send final position to backend so rider sees driver at dropoff
    if (_driverId != null) {
      ApiService.updateDriverLocation(
        driverId: _driverId!,
        lat: _dropoffLL.latitude,
        lng: _dropoffLL.longitude,
      ).catchError((_) => <String, dynamic>{});
    }
    // Show FINISH TRIP button in panel
    setState(() {});
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  GPS SIMULATION — realistic speed drive along route
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  List<LatLng> _simRouteCopy = []; // immutable copy for simulation

  /// Catmull-Rom spline interpolation for smooth curves at turns
  LatLng _catmullRom(LatLng p0, LatLng p1, LatLng p2, LatLng p3, double t) {
    final t2 = t * t;
    final t3 = t2 * t;
    double cr(double a, double b, double c, double d) =>
        0.5 *
        ((2 * b) +
            (-a + c) * t +
            (2 * a - 5 * b + 4 * c - d) * t2 +
            (-a + 3 * b - 3 * c + d) * t3);
    return LatLng(
      cr(p0.latitude, p1.latitude, p2.latitude, p3.latitude),
      cr(p0.longitude, p1.longitude, p2.longitude, p3.longitude),
    );
  }

  /// Smooth heading interpolation (avoids 360â†’ 0 jumps)
  double _lerpAngle(double from, double to, double t) {
    double diff = (to - from) % 360;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return (from + diff * t) % 360;
  }

  void _startSimulation() {
    _simTicker?.stop();
    _simTicker?.dispose();
    if (_routePts.length < 2) return;

    _simRouteCopy = List<LatLng>.from(_routePts);
    _simCumDist = [0.0];
    for (int i = 1; i < _simRouteCopy.length; i++) {
      _simCumDist.add(
        _simCumDist.last + _hav(_simRouteCopy[i - 1], _simRouteCopy[i]) * 1000,
      );
    }
    _simTotalM = _simCumDist.last;
    if (_simTotalM < 5) return;

    _simTraveledM = 0;
    _simPrevBearing = _heading;
    _simLastBackend = null;
    _simLastCamera = null;
    _simLastTrim = null;

    const double speedMps = 17.88;
    final estSecs = (_simTotalM / speedMps).round();
    debugPrint(
      '\u{1F697} Simulation: ${_simTotalM.round()} m, ETA ${estSecs}s @ 40 mph, ${_simRouteCopy.length} pts',
    );

    _simTicker = createTicker(_onSimTick);
    _simTicker!.start();
  }

  /// 60fps vsync-driven simulation - buttery smooth, zero ticks
  void _onSimTick(Duration elapsed) {
    if (!mounted) {
      _simTicker?.stop();
      return;
    }

    const double speedMps = 17.88;
    _simTraveledM = elapsed.inMicroseconds / 1e6 * speedMps;
    if (_simTraveledM >= _simTotalM) {
      _simTraveledM = _simTotalM;
      _simTicker?.stop();
    }

    // Binary-search for current segment
    int lo = 0, hi = _simCumDist.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (_simCumDist[mid] <= _simTraveledM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }
    final seg = lo;
    final segStart = _simCumDist[seg];
    final segEnd = _simCumDist[math.min(seg + 1, _simCumDist.length - 1)];
    final segLen = segEnd - segStart;
    final t = segLen > 0
        ? ((_simTraveledM - segStart) / segLen).clamp(0.0, 1.0)
        : 1.0;

    // Catmull-Rom spline for smooth curves
    final n = _simRouteCopy.length;
    final p0 = _simRouteCopy[(seg - 1).clamp(0, n - 1)];
    final p1 = _simRouteCopy[seg];
    final p2 = _simRouteCopy[math.min(seg + 1, n - 1)];
    final p3 = _simRouteCopy[math.min(seg + 2, n - 1)];
    final pt = _catmullRom(p0, p1, p2, p3, t);

    // Cross-segment look-ahead: peek 8m ahead even across segment boundaries
    const double lookAheadM = 8.0;
    final aheadDist = _simTraveledM + lookAheadM;
    LatLng ptAhead;
    if (aheadDist < _simTotalM) {
      // Find the segment that contains the look-ahead point
      int alo = 0, ahi = _simCumDist.length - 1;
      while (alo < ahi - 1) {
        final am = (alo + ahi) >> 1;
        if (_simCumDist[am] <= aheadDist) {
          alo = am;
        } else {
          ahi = am;
        }
      }
      final aSeg = alo;
      final aSegStart = _simCumDist[aSeg];
      final aSegEnd = _simCumDist[math.min(aSeg + 1, _simCumDist.length - 1)];
      final aSegLen = aSegEnd - aSegStart;
      final aT = aSegLen > 0
          ? ((aheadDist - aSegStart) / aSegLen).clamp(0.0, 1.0)
          : 1.0;
      final ap0 = _simRouteCopy[(aSeg - 1).clamp(0, n - 1)];
      final ap1 = _simRouteCopy[aSeg];
      final ap2 = _simRouteCopy[math.min(aSeg + 1, n - 1)];
      final ap3 = _simRouteCopy[math.min(aSeg + 2, n - 1)];
      ptAhead = _catmullRom(ap0, ap1, ap2, ap3, aT);
    } else {
      ptAhead = _simRouteCopy.last;
    }
    final rawBearing = _bearingBetween(pt, ptAhead);
    _simPrevBearing = _lerpAngle(_simPrevBearing, rawBearing, 0.22);
    final bearing = _simPrevBearing;

    // Direct position update - no intermediate animation at 60fps
    _pos = pt;
    _heading = bearing;
    setState(() {});

    final now = DateTime.now();

    // Trim route polyline (10 Hz)
    if (_simLastTrim == null ||
        now.difference(_simLastTrim!).inMilliseconds > 100) {
      _simLastTrim = now;
      _trimRouteBehindDriver(pt);
    }

    // Camera follows (20 Hz - moveCamera for zero lag)
    if (_cameraFollowing &&
        (_simLastCamera == null ||
            now.difference(_simLastCamera!).inMilliseconds > 33)) {
      _simLastCamera = now;
      _map?.moveCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: pt, zoom: 17.5, bearing: bearing, tilt: 55),
        ),
      );
    }

    // Nav stats + proximity checks
    // Update turn-by-turn navigation state
    _updateNavState(pt);
    final remainM = _simTotalM - _simTraveledM;
    final remainMin = (remainM / speedMps / 60).ceil().clamp(0, 99);
    if (_phase == _Phase.enRouteToPickup) {
      final dist = _hav(pt, _pickupLL);
      final progress = _distToPickup > 0
          ? (1.0 - dist / _distToPickup).clamp(0.0, 1.0)
          : 0.0;
      _navDist = dist;
      _navEta = remainMin;
      _navProgress = progress;
      if (dist < 0.05) _onNearPickup();
    } else if (_phase == _Phase.inTrip) {
      final dist = _hav(pt, _dropoffLL);
      final progress = _tripDist > 0
          ? (1.0 - dist / _tripDist).clamp(0.0, 1.0)
          : 0.0;
      _navDist = dist;
      _navEta = remainMin;
      _navProgress = progress;
      if (dist < 0.05) _onNearDropoff();
    }

    // Backend update (~2.5 Hz)
    if (_simLastBackend == null ||
        now.difference(_simLastBackend!).inMilliseconds > 400) {
      _simLastBackend = now;
      if (_driverId != null) {
        ApiService.updateDriverLocation(
          driverId: _driverId!,
          lat: pt.latitude,
          lng: pt.longitude,
        ).catchError((_) => <String, dynamic>{});
      }
    }
  }

  void _stopSimulation() {
    _simTicker?.stop();
    _simTicker?.dispose();
    _simTicker = null;
  }

  void _smoothMoveTo(LatLng target, double heading) {
    _animFrom = _pos;
    _animTo = target;
    _heading = heading;
    _driverAnim.forward(from: 0);
  }

  /// Trim the route polyline behind the driver so only upcoming road is shown.
  /// Google Maps navigation style — route "disappears" behind the car.
  void _trimRouteBehindDriver(LatLng driverPos) {
    if (_routePts.length < 3) return;
    if (_phase != _Phase.enRouteToPickup && _phase != _Phase.inTrip) return;

    // Find the closest point on the DISPLAY route (not the simulation copy)
    int closestIdx = 0;
    double closestDist = double.infinity;
    for (int i = 0; i < _routePts.length; i++) {
      final d = _hav(driverPos, _routePts[i]) * 1000; // meters
      if (d < closestDist) {
        closestDist = d;
        closestIdx = i;
      }
    }

    // Only trim if we've passed at least 1 point
    if (closestIdx > 0) {
      _routePts = _routePts.sublist(closestIdx);
    }
    // Always put driver at front for seamless line
    if (_routePts.isNotEmpty) {
      _routePts[0] = driverPos;
    }

    // Rebuild polylines with trimmed route
    final routeId = _phase == _Phase.enRouteToPickup ? 'pickup' : 'trip';
    final routeColor = _phase == _Phase.enRouteToPickup ? _goldLight : _gold;
    setState(() {
      _polylines = {
        Polyline(
          polylineId: PolylineId('${routeId}_g'),
          points: List.from(_routePts),
          color: routeColor.withValues(alpha: 0.12),
          width: 14,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
        Polyline(
          polylineId: PolylineId(routeId),
          points: List.from(_routePts),
          color: routeColor,
          width: 5,
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      };
    });
  }

  void _onDriverAnimTick() {
    if (!mounted) return;
    final t = Curves.easeOutCubic.transform(_driverAnim.value);
    final lat =
        _animFrom.latitude + (_animTo.latitude - _animFrom.latitude) * t;
    final lng =
        _animFrom.longitude + (_animTo.longitude - _animFrom.longitude) * t;
    _pos = LatLng(lat, lng);
    // Only rebuild marker set — minimal setState for performance
    setState(() {});
  }

  Set<Marker> get _allMarkers {
    // Only trip-specific markers (pickup, dropoff) — driver location
    // is shown via the native blue tracking circle (myLocationEnabled: true)
    return {..._markers};
  }

  Set<amap.Annotation> get _appleAnnotations {
    return _allMarkers
        .map(
          (m) => amap.Annotation(
            annotationId: amap.AnnotationId(m.markerId.value),
            position: amap.LatLng(m.position.latitude, m.position.longitude),
            anchor: m.anchor,
          ),
        )
        .toSet();
  }

  Set<amap.Polyline> get _applePolylines {
    return _polylines
        .map(
          (p) => amap.Polyline(
            polylineId: amap.PolylineId(p.polylineId.value),
            points: p.points
                .map((ll) => amap.LatLng(ll.latitude, ll.longitude))
                .toList(),
            color: p.color,
            width: p.width,
          ),
        )
        .toSet();
  }

  /// Snap a raw GPS coordinate to the nearest point on the active route polyline.
  /// Only snaps within 40 m — beyond that threshold the raw GPS is authoritative.
  LatLng _snapToRoute(LatLng raw) {
    if (_routePts.length < 2 ||
        (_phase != _Phase.enRouteToPickup && _phase != _Phase.inTrip)) {
      return raw;
    }
    double bestDist = double.infinity;
    LatLng best = raw;
    for (int i = 0; i < _routePts.length - 1; i++) {
      final candidate = _closestPointOnSegment(
        raw,
        _routePts[i],
        _routePts[i + 1],
      );
      final d = _hav(raw, candidate);
      if (d < bestDist) {
        bestDist = d;
        best = candidate;
      }
    }
    return bestDist <= 0.040 ? best : raw; // 40 m snap radius
  }

  /// Closest point on segment [a→b] to point [p] (flat lat/lng approximation).
  LatLng _closestPointOnSegment(LatLng p, LatLng a, LatLng b) {
    final dx = b.longitude - a.longitude;
    final dy = b.latitude - a.latitude;
    final len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return a;
    final t =
        ((p.longitude - a.longitude) * dx + (p.latitude - a.latitude) * dy) /
        len2;
    final tc = t.clamp(0.0, 1.0);
    return LatLng(a.latitude + tc * dy, a.longitude + tc * dx);
  }

  double _bearingBetween(LatLng a, LatLng b) {
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final aLat = a.latitude * math.pi / 180;
    final bLat = b.latitude * math.pi / 180;
    final x = math.sin(dLng) * math.cos(bLat);
    final y =
        math.cos(aLat) * math.sin(bLat) -
        math.sin(aLat) * math.cos(bLat) * math.cos(dLng);
    return (math.atan2(x, y) * 180 / math.pi + 360) % 360;
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  POLLING & CLOCK
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _startPolling() {
    _pollT?.cancel();
    _pollT = Timer.periodic(const Duration(seconds: 3), (_) {
      if (!mounted || _phase != _Phase.searching) return;
      _poll();
    });
  }

  Future<void> _poll() async {
    // SIMULATION MODE: Generate fake ride offers for practice
    if (_isSimulationMode) {
      _generateSimulatedOffer();
      return;
    }

    if (_driverId == null) {
      debugPrint(
        'âš ï¸ _poll: _driverId is null, retrying getCurrentUserId...',
      );
      try {
        final id = await ApiService.getCurrentUserId();
        if (id != null) {
          _driverId = id;
          debugPrint('âœ… Recovered driverId=$_driverId during polling');
          _goOnlineBackend(); // Re-establish online status
        }
      } catch (_) {}
      if (_driverId == null) return;
    }
    try {
      final offers = await ApiService.getDriverPendingOffers(_driverId!);
      debugPrint('ðŸ“¡ Poll result: ${offers.length} offer(s)');
      if (!mounted || _phase != _Phase.searching) return;
      if (offers.isNotEmpty && _pendingOffers.isEmpty) {
        HapticFeedback.heavyImpact();
      }
      setState(() => _pendingOffers = offers);
    } catch (e) {
      debugPrint('âŒ Poll error: $e');
    }
  }

  /// Generate a simulated ride offer for practice mode
  void _generateSimulatedOffer() {
    if (!mounted || _phase != _Phase.searching) return;
    
    // Don't generate if we already have pending offers
    if (_pendingOffers.isNotEmpty) return;
    
    _simulatedTripCounter++;
    
    // Generate random pickup location near current position (0.5-2km away)
    final random = math.Random();
    final distanceKm = 0.5 + random.nextDouble() * 1.5;
    final angle = random.nextDouble() * 2 * math.pi;
    final pickupLat = _pos.latitude + (distanceKm / 111) * math.cos(angle);
    final pickupLng = _pos.longitude + (distanceKm / (111 * math.cos(_pos.latitude * math.pi / 180))) * math.sin(angle);
    
    // Generate dropoff location 2-5km from pickup
    final tripDistanceKm = 2.0 + random.nextDouble() * 3.0;
    final tripAngle = random.nextDouble() * 2 * math.pi;
    final dropoffLat = pickupLat + (tripDistanceKm / 111) * math.cos(tripAngle);
    final dropoffLng = pickupLng + (tripDistanceKm / (111 * math.cos(pickupLat * math.pi / 180))) * math.sin(tripAngle);
    
    // Calculate fare (base $3 + $1.50 per km)
    final fare = 3.0 + (tripDistanceKm * 1.5);
    
    // Random rider names for simulation
    final firstNames = ['Alex', 'Jordan', 'Casey', 'Taylor', 'Morgan', 'Riley', 'Quinn', 'Avery', 'Sam', 'Drew'];
    final lastNames = ['Smith', 'Johnson', 'Williams', 'Brown', 'Jones', 'Garcia', 'Miller', 'Davis', 'Rodriguez', 'Martinez'];
    final riderName = '${firstNames[random.nextInt(firstNames.length)]} ${lastNames[random.nextInt(lastNames.length)]}';
    
    // Random addresses
    final streetNames = ['Main St', 'Oak Ave', 'Park Blvd', 'Cedar Ln', 'Elm St', 'Maple Dr', 'Washington Ave', 'Lake St'];
    final pickupAddr = '${random.nextInt(9999) + 1} ${streetNames[random.nextInt(streetNames.length)]}';
    final dropoffAddr = '${random.nextInt(9999) + 1} ${streetNames[random.nextInt(streetNames.length)]}';
    
    final simulatedOffer = {
      'offer_id': 100000 + _simulatedTripCounter, // High ID to avoid conflicts
      'trip_id': 100000 + _simulatedTripCounter,
      'rider_name': riderName,
      'rider_phone': '(555) ${random.nextInt(899) + 100}-${random.nextInt(8999) + 1000}',
      'pickup_address': pickupAddr,
      'dropoff_address': dropoffAddr,
      'pickup_lat': pickupLat,
      'pickup_lng': pickupLng,
      'dropoff_lat': dropoffLat,
      'dropoff_lng': dropoffLng,
      'fare': fare,
      'vehicle_type': 'CruiseX',
      'status': 'pending',
      'is_simulated': true, // Flag to identify simulated offers
    };
    
    debugPrint('🎮 SIMULATION: Generated trip #$_simulatedTripCounter - $riderName');
    
    HapticFeedback.heavyImpact();
    setState(() => _pendingOffers = [simulatedOffer]);
  }

  void _startClock() {
    _clock = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _online += const Duration(seconds: 1));
    });
  }

  String get _timeStr {
    final h = _online.inHours,
        m = _online.inMinutes.remainder(60),
        s = _online.inSeconds.remainder(60);
    if (h > 0) return '${h}h ${m.toString().padLeft(2, '0')}m';
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  RIDE OFFER ACTIONS (Spark-style: persistent cards)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _acceptOffer(Map<String, dynamic> r) async {
    HapticFeedback.heavyImpact();
    final offerId = r['offer_id'] as int?;
    final tripId = r['trip_id'] as int? ?? r['id'] as int?;

    // Accept this offer via API (skip for simulated offers)
    if (!_isSimulationMode) {
      if (offerId != null && _driverId != null) {
        try {
          await ApiService.acceptRideOffer(
            offerId: offerId,
            driverId: _driverId!,
          );
        } catch (e) {
          _snack(S.of(context).tripNoLongerAvailable);
          setState(
            () => _pendingOffers.removeWhere((o) => o['offer_id'] == offerId),
          );
          return;
        }
      } else if (tripId != null && _driverId != null) {
        try {
          await ApiService.acceptTrip(tripId: tripId, driverId: _driverId!);
        } catch (e) {
          _snack(S.of(context).tripNoLongerAvailable);
          setState(
            () => _pendingOffers.removeWhere((o) => o['trip_id'] == tripId),
          );
          return;
        }
      }
    }

    // Reject all other pending offers silently
    for (final other in _pendingOffers) {
      final otherId = other['offer_id'] as int?;
      if (otherId != null && otherId != offerId && _driverId != null) {
        ApiService.rejectRideOffer(
          offerId: otherId,
          driverId: _driverId!,
        ).catchError((_) => <String, dynamic>{});
      }
    }

    // Populate active trip data from the accepted offer
    final name = (r['rider_name'] ?? 'Rider') as String;
    _pickupLL = LatLng(
      (r['pickup_lat'] as num).toDouble(),
      (r['pickup_lng'] as num).toDouble(),
    );
    _dropoffLL = LatLng(
      (r['dropoff_lat'] as num).toDouble(),
      (r['dropoff_lng'] as num).toDouble(),
    );

    _currentOfferId = offerId;
    _tripId = tripId;
    _riderName = name;
    _riderInit = name.isNotEmpty ? name[0].toUpperCase() : '?';
    _riderPhone = (r['rider_phone'] ?? '') as String;
    _pickupAddr = r['pickup_address'] ?? 'Pickup';
    _dropoffAddr = r['dropoff_address'] ?? 'Drop-off';
    _fare = (r['fare'] as num?)?.toDouble() ?? 0;
    _vehicleType = r['vehicle_type'] ?? 'CruiseX';
    _distToPickup = _hav(_pos, _pickupLL);
    _etaToPickup = (_distToPickup * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    _tripDist = _hav(_pickupLL, _dropoffLL);
    _tripEta = (_tripDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);

    setState(() => _pendingOffers = []);
    _pollT?.cancel();
    _nearPickupNotified = false;
    _nearDropoffNotified = false;

    // Go straight to pickup
    _toPickup();
  }

  Future<void> _rejectOffer(Map<String, dynamic> r) async {
    HapticFeedback.mediumImpact();
    final offerId = r['offer_id'] as int?;

    // Reject via API so the trip cascades to next driver
    if (offerId != null && _driverId != null) {
      ApiService.rejectRideOffer(
        offerId: offerId,
        driverId: _driverId!,
      ).catchError((_) => <String, dynamic>{});
    }

    setState(() {
      _pendingOffers.removeWhere((o) => o['offer_id'] == offerId);
    });
  }

  // â”€â”€ _accept and _decline removed — now using _acceptOffer / _rejectOffer â”€â”€

  Future<void> _toPickup() async {
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(
          tripId: _tripId!,
          status: 'driver_en_route',
        );
      } catch (_) {}
    }
    setState(() {
      _phase = _Phase.enRouteToPickup;
      _cameraFollowing = true;
      _reFollowTimer?.cancel();
      _navDist = _hav(_pos, _pickupLL);
      _navEta = (_navDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _navInstruct = S.of(context).headToPickup;
      _navProgress = 0;
      _slideVal = 0;
      _slid = false;
      _markers = {
        Marker(
          markerId: const MarkerId('pickup'),
          position: _pickupLL,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
          infoWindow: InfoWindow(
            title: S.of(context).pickupLabel,
            snippet: _pickupAddr,
          ),
        ),
      };
    });
    await _drawRoute(_pos, _pickupLL, 'pickup', _goldLight);
    // Wait for frame with updated map padding, then center on both points
    await Future.delayed(const Duration(milliseconds: 150));
    _fitBounds(_pos, _pickupLL);
  }

  Future<void> _arrivePickup() async {
    _stopSimulation();
    HapticFeedback.mediumImpact();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(tripId: _tripId!, status: 'arrived');
      } catch (_) {}
    }
    setState(() {
      _phase = _Phase.arrivedAtPickup;
      _slideVal = 0;
      _slid = false;
      _polylines = {};
      _markers = {
        Marker(
          markerId: const MarkerId('drop'),
          position: _dropoffLL,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      };
    });
    _map?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _pickupLL, zoom: 17),
      ),
    );
  }

  Future<void> _startTrip() async {
    HapticFeedback.heavyImpact();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(tripId: _tripId!, status: 'in_trip');
      } catch (_) {}
    }
    // Show route summary with Start Navigation button
    setState(() {
      _phase = _Phase.routeSummary;
      _cameraFollowing = true;
      _reFollowTimer?.cancel();
      _navDist = _hav(_pos, _dropoffLL);
      _navEta = (_navDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);
      _navInstruct = S.of(context).headToDropOff;
      _navProgress = 0;
      _slideVal = 0;
      _slid = false;
      _markers = {
        Marker(
          markerId: const MarkerId('drop'),
          position: _dropoffLL,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: S.of(context).dropOffLabel,
            snippet: _dropoffAddr,
          ),
        ),
      };
    });
    await _drawRoute(_pos, _dropoffLL, 'trip', _gold);
    await Future.delayed(const Duration(milliseconds: 150));
    _nearDropoffNotified = false;
    // Start navigation camera (Uber 2.5D style)
    _map?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _pos, zoom: 17.5, bearing: _heading, tilt: 55),
      ),
    );
  }

  /// User pressed "Start Navigation" from the route summary — begin actual nav
  void _beginNavigation() {
    HapticFeedback.heavyImpact();
    setState(() {
      _phase = _Phase.inTrip;
      _cameraFollowing = true;
      _reFollowTimer?.cancel();
      _slideVal = 0;
      _slid = false;
      _markers = {
        Marker(
          markerId: const MarkerId('drop'),
          position: _dropoffLL,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
        ),
      };
    });
    // Switch to Uber 2.5D navigation camera
    _map?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _pos, zoom: 17.5, bearing: _heading, tilt: 55),
      ),
    );
    // Also launch external map app if user prefers one
    MapLauncherService.prefersInApp().then((inApp) {
      if (!inApp) {
        MapLauncherService.navigate(
          destLat: _dropoffLL.latitude,
          destLng: _dropoffLL.longitude,
        );
      }
    });
  }

  void _decline() {
    // Reject all pending offers if any
    for (final offer in _pendingOffers) {
      final oid = offer['offer_id'] as int?;
      if (oid != null && _driverId != null) {
        ApiService.rejectRideOffer(
          offerId: oid,
          driverId: _driverId!,
        ).catchError((_) => <String, dynamic>{});
      }
    }
    if (_currentOfferId != null && _driverId != null) {
      ApiService.rejectRideOffer(
        offerId: _currentOfferId!,
        driverId: _driverId!,
      ).catchError((_) => <String, dynamic>{});
    }
    _stopSimulation();
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _markers = {};
      _polylines = {};
      _pendingOffers = [];
    });
    _map?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _pos, zoom: 15.5, bearing: 0, tilt: 0),
      ),
    );
    _startPolling();
  }

  Future<void> _complete() async {
    _stopSimulation();
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    HapticFeedback.heavyImpact();
    _navTimer?.cancel();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(
          tripId: _tripId!,
          status: 'completed',
        );
      } catch (_) {}
    }
    setState(() {
      _trips++;
      _earnings += _fare;
      _lastTripEarnings = _fare;
      _phase = _Phase.completed;
      _stars = 5;
    });
    _doneCtrl.forward(from: 0);
  }

  void _afterComplete() {
    // Submit the driver's rating for this rider
    if (_tripId != null) {
      ApiService.rateTrip(
        tripId: _tripId!,
        stars: _stars,
      ).catchError((_) => <String, dynamic>{});
    }
    _doneCtrl.reverse();
    Future.delayed(const Duration(milliseconds: 350), () {
      if (!mounted) return;
      setState(() {
        _phase = _Phase.searching;
        _tripId = null;
        _currentOfferId = null;
        _markers = {};
        _polylines = {};
        _routePts = [];
        _pendingOffers = [];
      });
      _map?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _pos, zoom: 15.5, bearing: 0, tilt: 0),
        ),
      );
      _startPolling();
    });
  }

  void _goOffline() {
    HapticFeedback.mediumImpact();
    _goOfflineBackend();
    Navigator.of(context).pop<Map<String, dynamic>>({
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': false,
    });
  }

  /// Go back to home without going offline — driver stays connected.
  void _goBack() {
    HapticFeedback.lightImpact();
    Navigator.of(context).pop<Map<String, dynamic>>({
      'earnings': _earnings,
      'trips': _trips,
      'hours': _online.inMinutes / 60.0,
      'stillOnline': true,
    });
  }

  Future<void> _cancel() async {
    _stopSimulation();
    _navService.stopNavigation();
    _navState = null;
    _currentNavRoute = null;
    _navTimer?.cancel();
    if (_tripId != null) {
      try {
        await ApiService.updateTripStatus(tripId: _tripId!, status: 'canceled');
      } catch (_) {}
    }
    setState(() {
      _phase = _Phase.searching;
      _tripId = null;
      _currentOfferId = null;
      _markers = {};
      _polylines = {};
      _routePts = [];
      _pendingOffers = [];
    });
    _map?.animateCamera(
      CameraUpdate.newCameraPosition(
        CameraPosition(target: _pos, zoom: 15.5, bearing: 0, tilt: 0),
      ),
    );
    _startPolling();
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  NAV — Real GPS drives the navigation now.
  //  _simNav is kept as a no-op for backward compat.
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _simNav() {
    // No-op: real GPS position stream handles all nav updates
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  DIRECTIONS API
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Future<void> _drawRoute(LatLng o, LatLng d, String id, Color c) async {
    debugPrint(
      'ðŸ—ºï¸ _drawRoute: ${o.latitude},${o.longitude} â†’ ${d.latitude},${d.longitude}',
    );

    // Try Google Directions API with multiple parameter variants
    final variants = <Map<String, String>>[
      {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
        'alternatives': 'true',
      },
      {
        'origin': '${o.latitude},${o.longitude}',
        'destination': '${d.latitude},${d.longitude}',
        'key': ApiKeys.webServices,
        'mode': 'driving',
      },
    ];

    for (final query in variants) {
      try {
        final uri = Uri.https(
          'maps.googleapis.com',
          '/maps/api/directions/json',
          query,
        );
        final res = await http.get(uri).timeout(const Duration(seconds: 10));
        debugPrint('ðŸ—ºï¸ Directions API status: ${res.statusCode}');
        if (res.statusCode == 200) {
          final data = jsonDecode(res.body);
          debugPrint(
            'ðŸ—ºï¸ Directions API response status: ${data['status']}',
          );
          if (data['status'] == 'OK' && (data['routes'] as List).isNotEmpty) {
            final route = data['routes'][0];
            final pts = _decodePoly(
              route['overview_polyline']['points'] as String,
            );
            final leg = route['legs'][0];
            final steps = leg['steps'] as List;
            String instr = S.of(context).headToDestination;
            if (steps.isNotEmpty) {
              instr = (steps[0]['html_instructions']?.toString() ?? '')
                  .replaceAll(RegExp(r'<[^>]*>'), '');
            }

            // Parse turn-by-turn NavRoute for live navigation
            final navRoute = NavigationService.fromDirectionsResponse(data);
            if (navRoute != null) {
              _currentNavRoute = navRoute;
              _navService.startNavigation(navRoute);
              _rerouteCount = 0;
              debugPrint('Nav: ${navRoute.steps.length} steps parsed');
            }

            debugPrint('ðŸ—ºï¸ Google route OK: ${pts.length} points');
            setState(() {
              _routePts = pts;
              _navDist = (leg['distance']['value'] as int) / 1609.34;
              _navEta = ((leg['duration']['value'] as int) / 60).ceil();
              _navInstruct = instr;
              _polylines = {
                Polyline(
                  polylineId: PolylineId('${id}_g'),
                  points: pts,
                  color: c.withValues(alpha: 0.1),
                  width: 14,
                  startCap: Cap.roundCap,
                  endCap: Cap.roundCap,
                ),
                Polyline(
                  polylineId: PolylineId(id),
                  points: pts,
                  color: c,
                  width: 4,
                  startCap: Cap.roundCap,
                  endCap: Cap.roundCap,
                ),
              };
            });
            return;
          }
        }
      } catch (e) {
        debugPrint('ðŸ—ºï¸ Google Directions attempt failed: $e');
      }
    }

    // Fallback: OSRM (free, no API key needed)
    debugPrint('ðŸ—ºï¸ Trying OSRM fallback...');
    try {
      final path =
          '/route/v1/driving/${o.longitude},${o.latitude};${d.longitude},${d.latitude}';
      final uri = Uri.https('router.project-osrm.org', path, {
        'overview': 'full',
        'steps': 'true',
        'geometries': 'polyline',
      });
      final res = await http.get(uri).timeout(const Duration(seconds: 10));
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic> &&
          data['code']?.toString().toUpperCase() == 'OK') {
        final routes = data['routes'] as List?;
        if (routes != null && routes.isNotEmpty) {
          final route = routes[0];
          final pts = _decodePoly(route['geometry'] as String);
          final distM = (route['distance'] as num?)?.toInt() ?? 0;
          final durS = (route['duration'] as num?)?.toInt() ?? 0;
          String instr = S.of(context).headToDestination;
          final legs = route['legs'] as List?;
          if (legs != null && legs.isNotEmpty) {
            final steps = legs[0]['steps'] as List?;
            if (steps != null && steps.isNotEmpty) {
              instr = steps[0]['name']?.toString() ?? instr;
            }
          }
          debugPrint('ðŸ—ºï¸ OSRM route OK: ${pts.length} points');
          setState(() {
            _routePts = pts;
            _navDist = distM / 1609.34;
            _navEta = (durS / 60).ceil().clamp(1, 999);
            _navInstruct = instr;
            _polylines = {
              Polyline(
                polylineId: PolylineId('${id}_g'),
                points: pts,
                color: c.withValues(alpha: 0.1),
                width: 14,
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
              ),
              Polyline(
                polylineId: PolylineId(id),
                points: pts,
                color: c,
                width: 4,
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
              ),
            };
          });
          return;
        }
      }
    } catch (e) {
      debugPrint('ðŸ—ºï¸ OSRM fallback failed: $e');
    }

    // Last resort: straight line
    debugPrint('ðŸ—ºï¸ Using straight-line fallback');
    _fallbackRoute(o, d, id, c);
  }

  List<LatLng> _decodePoly(String enc) {
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

  void _fallbackRoute(LatLng a, LatLng b, String id, Color c) {
    final pts = List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        a.latitude + (b.latitude - a.latitude) * t,
        a.longitude + (b.longitude - a.longitude) * t,
      );
    });
    setState(() {
      _routePts = pts;
      _polylines = {
        Polyline(
          polylineId: PolylineId(id),
          points: pts,
          color: c,
          width: 3,
          patterns: [PatternItem.dot, PatternItem.gap(10)],
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      };
    });
  }

  double _hav(LatLng a, LatLng b) {
    const R = 6371.0;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLng = (b.longitude - a.longitude) * math.pi / 180;
    final x =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(a.latitude * math.pi / 180) *
            math.cos(b.latitude * math.pi / 180) *
            math.sin(dLng / 2) *
            math.sin(dLng / 2);
    return R * 2 * math.atan2(math.sqrt(x), math.sqrt(1 - x));
  }

  /// Dynamic bottom padding for the GoogleMap based on active overlays
  double get _mapBottomPadding {
    if (_previewingOffer != null) return 380;
    if (_phase == _Phase.searching && _pendingOffers.isNotEmpty) return 340;
    if (_phase == _Phase.enRouteToPickup) return 270;
    if (_phase == _Phase.arrivedAtPickup) return 290;
    if (_phase == _Phase.routeSummary) return 330;
    if (_phase == _Phase.inTrip) return 270;
    return 200;
  }

  void _fitBounds(LatLng a, LatLng b) {
    double minLat = math.min(a.latitude, b.latitude);
    double maxLat = math.max(a.latitude, b.latitude);
    double minLng = math.min(a.longitude, b.longitude);
    double maxLng = math.max(a.longitude, b.longitude);
    // Ensure minimum span so the map doesn't over-zoom for nearby points
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
    if (Platform.isIOS) {
      _appleMap?.moveCamera(
        amap.CameraUpdate.newLatLngBounds(
          amap.LatLngBounds(
            southwest: amap.LatLng(minLat - 0.004, minLng - 0.004),
            northeast: amap.LatLng(maxLat + 0.004, maxLng + 0.004),
          ),
          70,
        ),
      );
    } else {
      _map?.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat - 0.004, minLng - 0.004),
            northeast: LatLng(maxLat + 0.004, maxLng + 0.004),
          ),
          70,
        ),
      );
    }
  }

  void _fitBoundsMulti(List<LatLng> points) {
    if (points.isEmpty) return;
    double minLat = points.first.latitude, maxLat = minLat;
    double minLng = points.first.longitude, maxLng = minLng;
    for (final p in points) {
      if (p.latitude < minLat) minLat = p.latitude;
      if (p.latitude > maxLat) maxLat = p.latitude;
      if (p.longitude < minLng) minLng = p.longitude;
      if (p.longitude > maxLng) maxLng = p.longitude;
    }
    // Ensure minimum span so the map doesn't over-zoom
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
    if (Platform.isIOS) {
      _appleMap?.moveCamera(
        amap.CameraUpdate.newLatLngBounds(
          amap.LatLngBounds(
            southwest: amap.LatLng(minLat - 0.004, minLng - 0.004),
            northeast: amap.LatLng(maxLat + 0.004, maxLng + 0.004),
          ),
          70,
        ),
      );
    } else {
      _map?.animateCamera(
        CameraUpdate.newLatLngBounds(
          LatLngBounds(
            southwest: LatLng(minLat - 0.004, minLng - 0.004),
            northeast: LatLng(maxLat + 0.004, maxLng + 0.004),
          ),
          70,
        ),
      );
    }
  }

  // â"€â"€ Preview offer route on map â"€â"€
  Future<void> _previewOfferRoute(Map<String, dynamic> offer) async {
    final pickupLat = (offer['pickup_lat'] as num?)?.toDouble() ?? 0;
    final pickupLng = (offer['pickup_lng'] as num?)?.toDouble() ?? 0;
    final dropoffLat = (offer['dropoff_lat'] as num?)?.toDouble() ?? 0;
    final dropoffLng = (offer['dropoff_lng'] as num?)?.toDouble() ?? 0;
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);

    // Save current state
    _savedPolylines = Set.from(_polylines);
    _savedMarkers = Set.from(_markers);

    setState(() {
      _previewingOffer = offer;
      _markers = {
        Marker(
          markerId: const MarkerId('prev_driver'),
          position: _pos,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueBlue),
          infoWindow: InfoWindow(title: S.of(context).yourLocation),
        ),
        Marker(
          markerId: const MarkerId('prev_pickup'),
          position: pickupLL,
          icon: BitmapDescriptor.defaultMarkerWithHue(
            BitmapDescriptor.hueGreen,
          ),
          infoWindow: InfoWindow(
            title: S.of(context).pickupLabel,
            snippet: offer['pickup_address'] as String?,
          ),
        ),
        Marker(
          markerId: const MarkerId('prev_dropoff'),
          position: dropoffLL,
          icon: BitmapDescriptor.defaultMarkerWithHue(BitmapDescriptor.hueRed),
          infoWindow: InfoWindow(
            title: S.of(context).dropOffLabel,
            snippet: offer['dropoff_address'] as String?,
          ),
        ),
      };
      _polylines = {};
    });

    // Draw driver â†’ pickup route (green-ish)
    await _drawPreviewRoute(
      _pos,
      pickupLL,
      'prev_to_pickup',
      Colors.greenAccent,
    );
    // Draw pickup â†’ dropoff route (gold)
    await _drawPreviewRoute(pickupLL, dropoffLL, 'prev_trip', _gold);

    // Wait for frame to render with updated map padding, then fit bounds
    if (!mounted) return;
    await Future.delayed(const Duration(milliseconds: 150));
    _fitBoundsMulti([_pos, pickupLL, dropoffLL]);

    // Re-fit after animation settles for pixel-perfect centering
    await Future.delayed(const Duration(milliseconds: 500));
    if (mounted && _previewingOffer != null) {
      _fitBoundsMulti([_pos, pickupLL, dropoffLL]);
    }
  }

  Future<void> _drawPreviewRoute(LatLng o, LatLng d, String id, Color c) async {
    // Try Google Directions API
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
          final pts = _decodePoly(
            data['routes'][0]['overview_polyline']['points'] as String,
          );
          setState(() {
            _polylines = {
              ..._polylines,
              Polyline(
                polylineId: PolylineId('${id}_g'),
                points: pts,
                color: c.withValues(alpha: 0.12),
                width: 12,
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
              ),
              Polyline(
                polylineId: PolylineId(id),
                points: pts,
                color: c,
                width: 4,
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
              ),
            };
          });
          return;
        }
      }
    } catch (_) {}

    // Fallback: OSRM
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
          final pts = _decodePoly(routes[0]['geometry'] as String);
          setState(() {
            _polylines = {
              ..._polylines,
              Polyline(
                polylineId: PolylineId('${id}_g'),
                points: pts,
                color: c.withValues(alpha: 0.12),
                width: 12,
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
              ),
              Polyline(
                polylineId: PolylineId(id),
                points: pts,
                color: c,
                width: 4,
                startCap: Cap.roundCap,
                endCap: Cap.roundCap,
              ),
            };
          });
          return;
        }
      }
    } catch (_) {}

    // Last resort: straight line
    final pts = List.generate(21, (i) {
      final t = i / 20;
      return LatLng(
        o.latitude + (d.latitude - o.latitude) * t,
        o.longitude + (d.longitude - o.longitude) * t,
      );
    });
    setState(() {
      _polylines = {
        ..._polylines,
        Polyline(
          polylineId: PolylineId(id),
          points: pts,
          color: c,
          width: 3,
          patterns: [PatternItem.dot, PatternItem.gap(10)],
          startCap: Cap.roundCap,
          endCap: Cap.roundCap,
        ),
      };
    });
  }

  void _closePreview() {
    setState(() {
      _previewingOffer = null;
      _polylines = _savedPolylines;
      _markers = _savedMarkers;
      _savedPolylines = {};
      _savedMarkers = {};
    });
    if (Platform.isIOS) {
      _appleMap?.moveCamera(
        amap.CameraUpdate.newCameraPosition(
          amap.CameraPosition(
            target: amap.LatLng(_pos.latitude, _pos.longitude),
            zoom: 15.5,
          ),
        ),
      );
    } else {
      _map?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _pos, zoom: 15.5, bearing: 0, tilt: 0),
        ),
      );
    }
  }

  void _snack(String s) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          s,
          style: const TextStyle(
            color: Colors.black,
            fontWeight: FontWeight.w700,
          ),
        ),
        backgroundColor: _gold,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: const Duration(seconds: 2),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BUILD
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  @override
  Widget build(BuildContext context) {
    final top = MediaQuery.of(context).padding.top;
    final bot = MediaQuery.of(context).padding.bottom;
    final isDark = Theme.of(context).brightness == Brightness.dark;

    // Adapt status bar icons
    SystemChrome.setSystemUIOverlayStyle(
      SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        statusBarIconBrightness: isDark ? Brightness.light : Brightness.dark,
      ),
    );

    // Live-switch map style
    _applyMapStyle(isDark);

    // Theme-aware colors
    final bg = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF2F2F7);
    final surface = isDark ? const Color(0xFF111111) : Colors.white;
    final card = isDark ? const Color(0xFF1C1C1E) : Colors.white;
    final fabBg = isDark
        ? const Color(0xFF1A1A1A).withValues(alpha: 0.75)
        : Colors.white.withValues(alpha: 0.85);
    final fabBorder = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final fabIcon = isDark
        ? Colors.white.withValues(alpha: 0.8)
        : Colors.black.withValues(alpha: 0.65);
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
          children: [
            // â”€â”€ Map â”€â”€
            _mapW(isDark),

            // â”€â”€ Top-left: Home button â”€â”€
            Positioned(
              top: top + 10,
              left: 16,
              child: _fab(
                Icons.arrow_back_ios_new_rounded,
                48,
                fabBg,
                fabBorder,
                fabIcon,
                _goBack,
              ),
            ),

            // â”€â”€ Top-center: Earnings pill + TODAY â”€â”€
            Positioned(
              top: top + 10,
              left: 0,
              right: 0,
              child: Column(
                children: [
                  Center(child: _earningsPill(isDark)),
                  // Simulation mode indicator badge
                  if (_isSimulationMode)
                    Container(
                      margin: const EdgeInsets.only(top: 8),
                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: const Color(0xFFE8C547).withValues(alpha: 0.9),
                        borderRadius: BorderRadius.circular(20),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.3),
                            blurRadius: 8,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.videogame_asset_rounded,
                            color: Colors.black,
                            size: 14,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            'PRACTICE MODE',
                            style: TextStyle(
                              color: Colors.black,
                              fontSize: 11,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1,
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),

            // â”€â”€ Nav header (during navigation phases) â”€â”€
            if (_phase == _Phase.enRouteToPickup ||
                _phase == _Phase.inTrip ||
                _phase == _Phase.routeSummary)
              Positioned(
                top: top + 64,
                left: 16,
                right: 16,
                child: _navHeader(),
              ),

            // â”€â”€ Side floating buttons (only when searching with no offers) â”€â”€
            if (_phase == _Phase.searching && _pendingOffers.isEmpty) ...[
              Positioned(
                bottom: 54 + bot + 60,
                left: 16,
                child: Column(
                  children: [
                    _fab(
                      Icons.tune_rounded,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => _showOnlinePanel(),
                    ),
                    const SizedBox(height: 10),
                    _fab(
                      Icons.shield_outlined,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(builder: (_) => const SafetyScreen()),
                      ),
                    ),
                  ],
                ),
              ),
              Positioned(
                bottom: 54 + bot + 60,
                right: 16,
                child: Column(
                  children: [
                    _fab(
                      Icons.message_outlined,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DriverInboxScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _fab(
                      Icons.campaign_rounded,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DriverPromosScreen(),
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    _fab(
                      Icons.bar_chart_rounded,
                      44,
                      fabBg,
                      fabBorder,
                      fabIcon,
                      () => Navigator.push(
                        context,
                        MaterialPageRoute(
                          builder: (_) => const DriverAnalyticsScreen(),
                        ),
                      ),
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
                    HapticFeedback.mediumImpact();
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
            if (_phase == _Phase.searching &&
                _pendingOffers.isNotEmpty &&
                _previewingOffer == null)
              Positioned(
                bottom: 0,
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

            // â”€â”€ Route Preview Panel (when an offer is tapped) â”€â”€
            if (_previewingOffer != null)
              Positioned(
                bottom: 0,
                left: 0,
                right: 0,
                child: _routePreviewPanel(isDark),
              ),

            // â”€â”€ X button to close preview (top-right) â”€â”€
            if (_previewingOffer != null)
              Positioned(
                top: top + 10,
                right: 16,
                child: _fab(
                  Icons.close_rounded,
                  48,
                  fabBg,
                  fabBorder,
                  fabIcon,
                  _closePreview,
                ),
              ),

            // â”€â”€ Bottom: Phase-specific panel â”€â”€
            if (_phase == _Phase.searching && _pendingOffers.isEmpty)
              _draggablePanel(
                isDark,
                surface,
                textMuted,
                borderC,
                textPrimary,
                shadowC,
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
          ],
        ),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  MAP
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _applyMapStyle(bool isDark) {
    if (isDark == _lastStyleDark) return;
    _lastStyleDark = isDark;
    setState(() {}); // rebuild GoogleMap with new style: param
  }

  /// Called by GoogleMap when a camera movement is initiated.
  /// User gestures (pan/pinch) pause the auto-follow so the driver can
  /// freely explore the map.  A recenter FAB appears to resume following.
  void _onCameraMoveStarted() {
    // Only pause follow during active navigation phases
    final isNav =
        _phase == _Phase.enRouteToPickup ||
        _phase == _Phase.inTrip ||
        _phase == _Phase.routeSummary;
    if (!isNav) return;
    if (!_cameraFollowing) return; // already paused
    setState(() => _cameraFollowing = false);
    _reFollowTimer?.cancel();
    // Auto-resume after 8 seconds of inactivity
    _reFollowTimer = Timer(const Duration(seconds: 8), _recenterCamera);
  }

  /// Resume camera follow mode and snap back to driver position.
  void _recenterCamera() {
    if (!mounted) return;
    _reFollowTimer?.cancel();
    setState(() => _cameraFollowing = true);
    final bearing = _smoothedBearing;
    if (Platform.isIOS) {
      _appleMap?.moveCamera(
        amap.CameraUpdate.newCameraPosition(
          amap.CameraPosition(
            target: amap.LatLng(_pos.latitude, _pos.longitude),
            zoom: 17.5,
            heading: bearing,
            pitch: 55,
          ),
        ),
      );
    } else {
      _map?.animateCamera(
        CameraUpdate.newCameraPosition(
          CameraPosition(target: _pos, zoom: 17.5, bearing: bearing, tilt: 55),
        ),
      );
    }
  }

  Widget _mapW(bool isDark) {
    if (Platform.isIOS) {
      return RepaintBoundary(
        child: amap.AppleMap(
          initialCameraPosition: amap.CameraPosition(
            target: amap.LatLng(_pos.latitude, _pos.longitude),
            zoom: 15.5,
          ),
          mapType: amap.MapType.mutedStandard,
          onMapCreated: (c) {
            _appleMap = c;
            c.moveCamera(
              amap.CameraUpdate.newCameraPosition(
                amap.CameraPosition(
                  target: amap.LatLng(_pos.latitude, _pos.longitude),
                  zoom: 15.5,
                ),
              ),
            );
          },
          myLocationEnabled: true,
          myLocationButtonEnabled: false,
          zoomGesturesEnabled: true,
          scrollGesturesEnabled: true,
          rotateGesturesEnabled: true,
          compassEnabled: false,
          annotations: _appleAnnotations,
          polylines: _applePolylines,
          padding: EdgeInsets.only(
            top: MediaQuery.of(context).padding.top + 70,
            bottom: _mapBottomPadding,
          ),
        ),
      );
    }
    return RepaintBoundary(
      child: GoogleMap(
        style: isDark ? MapStyles.darkIOS : MapStyles.lightIOS,
        initialCameraPosition: CameraPosition(
          target: _pos,
          zoom: 15.5,
          bearing: 0,
          tilt: 0,
        ),
        onMapCreated: (c) {
          _map = c;
          _lastStyleDark = isDark;
          c.moveCamera(
            CameraUpdate.newCameraPosition(
              CameraPosition(
                target: _pos,
                zoom: 15.5,
                bearing: 0,
                tilt: 0,
              ),
            ),
          );
        },
        markers: _allMarkers,
        polylines: _polylines,
        onCameraMoveStarted: _onCameraMoveStarted,
        myLocationEnabled: true,
        myLocationButtonEnabled: false,
        zoomControlsEnabled: false,
        mapToolbarEnabled: false,
        compassEnabled: false,
        buildingsEnabled: true,
        trafficEnabled:
            _phase == _Phase.enRouteToPickup || _phase == _Phase.inTrip,
        indoorViewEnabled: false,
        liteModeEnabled: false,
        padding: EdgeInsets.only(
          top: MediaQuery.of(context).padding.top + 70,
          bottom: _mapBottomPadding,
        ),
      ),
    );
  }

  /// Convert Google Maps markers to Apple Maps annotations for iOS
  Set<amap.Annotation> get _appleAnnotations {
    final Set<amap.Annotation> annotations = {};
    for (final m in _allMarkers) {
      annotations.add(
        amap.Annotation(
          annotationId: amap.AnnotationId(m.markerId.value),
          position: amap.LatLng(m.position.latitude, m.position.longitude),
          infoWindow: m.infoWindow.title != null
              ? amap.InfoWindow(
                  title: m.infoWindow.title ?? '',
                  snippet: m.infoWindow.snippet,
                )
              : amap.InfoWindow.noText,
        ),
      );
    }
    return annotations;
  }

  /// Convert Google Maps polylines to Apple Maps polylines for iOS
  Set<amap.Polyline> get _applePolylines {
    final Set<amap.Polyline> result = {};
    for (final p in _polylines) {
      result.add(
        amap.Polyline(
          polylineId: amap.PolylineId(p.polylineId.value),
          points: p.points
              .map((pt) => amap.LatLng(pt.latitude, pt.longitude))
              .toList(),
          color: p.color,
          width: p.width,
        ),
      );
    }
    return result;
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  EARNINGS PILL (top center — Uber style)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _earningsPill(bool isDark) {
    final pillBg = isDark
        ? const Color(0xFF1A1A1A).withValues(alpha: 0.85)
        : Colors.white.withValues(alpha: 0.9);
    final pillBorder = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final pillText = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final pillSub = isDark ? Colors.white38 : Colors.black38;
    final dotActive = isDark ? Colors.white : const Color(0xFF1C1C1E);
    final dotInactive = isDark
        ? Colors.white.withValues(alpha: 0.2)
        : Colors.black.withValues(alpha: 0.15);

    Widget pillPage(String amount, String label) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(20),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
            decoration: BoxDecoration(
              color: pillBg,
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: pillBorder),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  amount,
                  style: TextStyle(
                    color: pillText,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
                const SizedBox(height: 1),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: pillSub,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5,
                      ),
                    ),
                    const SizedBox(width: 6),
                    for (int i = 0; i < 3; i++) ...[
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: i == _earningsPage ? dotActive : dotInactive,
                        ),
                      ),
                      if (i < 2) const SizedBox(width: 3),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: 160,
      height: 52,
      child: PageView(
        controller: _earningsPageCtrl,
        onPageChanged: (i) => setState(() => _earningsPage = i),
        children: [
          Center(
            child: pillPage(
              '\$${_weeklyEarnings.toStringAsFixed(2)}',
              S.of(context).thisWeek.toUpperCase(),
            ),
          ),
          Center(
            child: pillPage(
              '\$${_earnings.toStringAsFixed(2)}',
              S.of(context).today.toUpperCase(),
            ),
          ),
          Center(
            child: pillPage(
              '\$${_lastTripEarnings.toStringAsFixed(2)}',
              S.of(context).lastTripLabel.toUpperCase(),
            ),
          ),
        ],
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  NAV HEADER (Uber-style turn card)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _navHeader() {
    final toPickup = _phase == _Phase.enRouteToPickup;
    final accent = toPickup ? _goldLight : _gold;
    final title = toPickup
        ? S.of(context).pickupLabel.toUpperCase()
        : S.of(context).dropOffLabel.toUpperCase();

    // Get maneuver icon from NavigationService
    final maneuverStr = _navState?.currentManeuver ?? 'straight';
    final maneuverInfo = NavigationService.getManeuverIcon(maneuverStr);
    final distToTurn = _navState?.distanceToTurnText ?? '';
    final isOffRoute = _navState?.isOffRoute ?? false;

    return Container(
      decoration: BoxDecoration(
        color: isOffRoute ? const Color(0xFFFF6B35) : accent,
        borderRadius: BorderRadius.circular(18),
        boxShadow: [
          BoxShadow(
            color: (isOffRoute ? const Color(0xFFFF6B35) : accent).withValues(
              alpha: 0.3,
            ),
            blurRadius: 20,
            spreadRadius: 1,
          ),
        ],
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 10),
            child: Row(
              children: [
                // Maneuver icon (turn arrow)
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Icon(
                    IconData(
                      maneuverInfo.iconCodePoint,
                      fontFamily: 'MaterialIcons',
                    ),
                    color: Colors.black,
                    size: 26,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (distToTurn.isNotEmpty && !isOffRoute)
                        Text(
                          distToTurn,
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      if (isOffRoute)
                        Text(
                          S.of(context).rerouting,
                          style: const TextStyle(
                            color: Colors.black,
                            fontSize: 18,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      Text(
                        isOffRoute ? S.of(context).offRoute : _navInstruct,
                        style: TextStyle(
                          color: Colors.black.withValues(alpha: 0.7),
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                // Cancel button (pickup only)
                if (toPickup)
                  GestureDetector(
                    onTap: _cancel,
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: const Icon(
                        Icons.close_rounded,
                        color: Colors.black,
                        size: 17,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          // Next maneuver preview (if available)
          if (_navState?.nextStep != null && !isOffRoute)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.06),
              ),
              child: Row(
                children: [
                  Text(
                    S.of(context).thenLabel,
                    style: TextStyle(
                      color: Colors.black.withValues(alpha: 0.4),
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    IconData(
                      NavigationService.getManeuverIcon(
                        _navState!.nextStep!.maneuver,
                      ).iconCodePoint,
                      fontFamily: 'MaterialIcons',
                    ),
                    color: Colors.black.withValues(alpha: 0.5),
                    size: 16,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _navState!.nextStep!.instruction,
                      style: TextStyle(
                        color: Colors.black.withValues(alpha: 0.5),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.1),
              borderRadius: const BorderRadius.vertical(
                bottom: Radius.circular(18),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.timer_rounded,
                  color: Colors.black.withValues(alpha: 0.5),
                  size: 15,
                ),
                const SizedBox(width: 5),
                Text(
                  '$_navEta min',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(width: 16),
                Icon(
                  Icons.straighten_rounded,
                  color: Colors.black.withValues(alpha: 0.5),
                  size: 15,
                ),
                const SizedBox(width: 5),
                Text(
                  '${(_navDist * 0.621371).toStringAsFixed(1)} mi',
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Spacer(),
                // Heading to label
                Text(
                  S.of(context).toLabel(title),
                  style: TextStyle(
                    color: Colors.black.withValues(alpha: 0.4),
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.5,
                  ),
                ),
                const SizedBox(width: 8),
                SizedBox(
                  width: 50,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: _navProgress,
                      backgroundColor: Colors.black.withValues(alpha: 0.12),
                      valueColor: const AlwaysStoppedAnimation(Colors.black),
                      minHeight: 3,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  BOTTOM AREA (per phase)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _bottomArea(
    bool isDark,
    Color bg,
    Color surface,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    switch (_phase) {
      case _Phase.searching:
        return _searchingBar(isDark, surface, textMuted, borderC);
      case _Phase.rideRequest:
        return const SizedBox.shrink(); // handled by stacked cards overlay
      case _Phase.enRouteToPickup:
        return _pickupPanel(
          isDark,
          bg,
          textPrimary,
          textMuted,
          borderC,
          shadowC,
        );
      case _Phase.arrivedAtPickup:
        return _arrivedPanel(
          isDark,
          bg,
          textPrimary,
          textMuted,
          borderC,
          shadowC,
        );
      case _Phase.routeSummary:
        return _routeSummaryPanel(
          isDark,
          bg,
          textPrimary,
          textMuted,
          borderC,
          shadowC,
        );
      case _Phase.inTrip:
        return _tripPanel(isDark, bg, textPrimary, textMuted, borderC, shadowC);
      case _Phase.completed:
        return const SizedBox.shrink();
    }
  }

  // â”€â”€ SEARCHING: Uber-style "Finding trips" bar â”€â”€
  Widget _searchingBar(
    bool isDark,
    Color surface,
    Color textMuted,
    Color borderC,
  ) {
    return GestureDetector(
      onVerticalDragEnd: (d) {
        final v = d.primaryVelocity ?? 0;
        if (v < -200) _showOnlinePanel(); // swipe up → open panel
      },
      child: Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          border: Border(top: BorderSide(color: borderC)),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Progress indicator line
              ListenableBuilder(
                listenable: _searchPulseVal,
                builder: (_, __) {
                  return SizedBox(
                    height: 2,
                    child: LinearProgressIndicator(
                      value: null,
                      backgroundColor: Colors.transparent,
                      valueColor: AlwaysStoppedAnimation(
                        _gold.withValues(alpha: 0.5),
                      ),
                      minHeight: 2,
                    ),
                  );
                },
              ),
              // Drag handle
              Padding(
                padding: const EdgeInsets.only(top: 10, bottom: 4),
                child: Container(
                  width: 36,
                  height: 4,
                  decoration: BoxDecoration(
                    color: textMuted.withValues(alpha: 0.25),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              // Status bar
              GestureDetector(
                onTap: _showOnlinePanel,
                child: SizedBox(
                  height: 44,
                  child: Row(
                    children: [
                      const SizedBox(width: 16),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _showOnlinePanel();
                        },
                        child: Container(
                          width: 30,
                          height: 30,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            border: Border.all(color: _gold, width: 1.5),
                          ),
                          child: ClipOval(
                            child: _driverPhotoUrl != null && _driverPhotoUrl!.isNotEmpty
                                ? (_driverPhotoUrl!.startsWith('http')
                                    ? Image.network(
                                        _driverPhotoUrl!,
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Icon(
                                          Icons.person_rounded,
                                          color: textMuted,
                                          size: 18,
                                        ),
                                      )
                                    : Image.file(
                                        File(_driverPhotoUrl!),
                                        fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => Icon(
                                          Icons.person_rounded,
                                          color: textMuted,
                                          size: 18,
                                        ),
                                      ))
                                : Icon(
                                    Icons.person_rounded,
                                    color: textMuted,
                                    size: 18,
                                  ),
                          ),
                        ),
                      ),
                      const Spacer(),
                      Text(
                        S.of(context).findingTrips,
                        style: TextStyle(
                          color: textMuted,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const Spacer(),
                      GestureDetector(
                        onTap: () {
                          HapticFeedback.lightImpact();
                          _showOnlinePanel();
                        },
                        child: Icon(
                          Icons.format_list_bulleted_rounded,
                          color: textMuted,
                          size: 22,
                        ),
                      ),
                      const SizedBox(width: 16),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // â”€â”€ STACKED RIDE OFFER CARDS (Spark-style — persistent, no timeout) â”€â”€
  Widget _rideOfferCards(
    bool isDark,
    Color card,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    final bot = MediaQuery.of(context).padding.bottom;
    // â”€â”€ Always use dark styling for offer cards â”€â”€
    const cCardBg = Color(0xFF1A1A1A);
    final cCardBorder = _gold.withValues(alpha: 0.12);
    final cRejectBg = Colors.red.withValues(alpha: 0.08);
    const cRejectText = Color(0xFFFF6B6B);
    const cTextPrimary = Colors.white;
    final cTextMuted = Colors.white.withValues(alpha: 0.5);
    final cBorderC = Colors.white.withValues(alpha: 0.06);
    final acceptBg = _gold;

    return AnimatedContainer(
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
      constraints: BoxConstraints(
        maxHeight: _offersExpanded
            ? MediaQuery.of(context).size.height * 0.65
            : 64,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A).withValues(alpha: 0.95),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 12, sigmaY: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // â”€â”€ Tappable header: handle + title + chevron â”€â”€
              GestureDetector(
                onTap: () => setState(() => _offersExpanded = !_offersExpanded),
                behavior: HitTestBehavior.opaque,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Column(
                    children: [
                      const SizedBox(height: 10),
                      Container(
                        width: 36,
                        height: 4,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            S.of(context).ridesAvailable(_pendingOffers.length),
                            style: const TextStyle(
                              color: _gold,
                              fontSize: 14,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 0.5,
                            ),
                          ),
                          const SizedBox(width: 6),
                          AnimatedRotation(
                            turns: _offersExpanded ? 0.5 : 0,
                            duration: const Duration(milliseconds: 300),
                            child: const Icon(
                              Icons.keyboard_arrow_up_rounded,
                              color: _gold,
                              size: 20,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                    ],
                  ),
                ),
              ),
              // â”€â”€ Scrollable card list (hidden when collapsed) â”€â”€
              if (_offersExpanded)
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                    itemCount: _pendingOffers.length,
                    itemBuilder: (ctx, i) {
                      final offer = _pendingOffers[i];
                      return GestureDetector(
                        onTap: () => _previewOfferRoute(offer),
                        child: _offerCard(
                          offer,
                          true,
                          cCardBg,
                          cCardBorder,
                          cTextPrimary,
                          cTextMuted,
                          cRejectBg,
                          cRejectText,
                          acceptBg,
                          cBorderC,
                        ),
                      );
                    },
                  ),
                ),
              // â”€â”€ "Finding trips" bar at the bottom â”€â”€
              GestureDetector(
                onTap: _showGoOfflineSheet,
                onVerticalDragUpdate: (details) {
                  // Si arrastra hacia arriba (dy negativo), abre el sheet
                  if (details.delta.dy < -5) {
                    _showGoOfflineSheet();
                  }
                },
                behavior: HitTestBehavior.opaque,
                child: Container(
                  decoration: BoxDecoration(
                    color: const Color(0xFF111111),
                    border: Border(
                      top: BorderSide(
                        color: Colors.white.withValues(alpha: 0.06),
                      ),
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: SizedBox(
                      height: 52,
                      child: Row(
                        children: [
                          const SizedBox(width: 16),
                          Icon(
                            Icons.tune_rounded,
                            color: Colors.white.withValues(alpha: 0.5),
                            size: 22,
                          ),
                          const Spacer(),
                          Text(
                            S.of(context).findingTrips,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.5),
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          const Spacer(),
                          Icon(
                            Icons.format_list_bulleted_rounded,
                            color: Colors.white.withValues(alpha: 0.5),
                            size: 22,
                          ),
                          const SizedBox(width: 16),
                        ],
                      ),
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

  /// Shows the Go Offline bottom sheet (accessible from Finding trips bar)
  void _showGoOfflineSheet() {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final surface = isDark ? const Color(0xFF111111) : Colors.white;
    final textPrimary = isDark ? Colors.white : Colors.black;
    final textMuted = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.5);
    final borderC = isDark
        ? Colors.white.withValues(alpha: 0.06)
        : Colors.black.withValues(alpha: 0.06);
    final panelItemText = isDark
        ? Colors.white.withValues(alpha: 0.7)
        : Colors.black.withValues(alpha: 0.6);
    final panelItemIcon = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.4);
    final panelItemChevron = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.12);

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (_) => Container(
        decoration: BoxDecoration(
          color: surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          border: Border(top: BorderSide(color: _gold.withValues(alpha: 0.08))),
        ),
        child: SafeArea(
          top: false,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: textMuted.withValues(alpha: 0.3),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: 40,
                child: Row(
                  children: [
                    const SizedBox(width: 16),
                    Icon(Icons.tune_rounded, color: textMuted, size: 22),
                    const Spacer(),
                    Text(
                      S.of(context).findingTrips,
                      style: TextStyle(
                        color: textMuted,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Icon(
                      Icons.format_list_bulleted_rounded,
                      color: textMuted,
                      size: 22,
                    ),
                    const SizedBox(width: 16),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              Divider(height: 1, color: borderC),
              const SizedBox(height: 16),
              Text(
                S.of(context).recommendedForYou,
                style: TextStyle(
                  color: textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 16),
              _panelItem(
                Icons.bar_chart_rounded,
                S.of(context).seeEarningsTrends,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DriverEarningsScreen(),
                    ),
                  );
                },
              ),
              _panelItem(
                Icons.star_outline_rounded,
                S.of(context).seeUpcomingPromotions,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DriverPromosScreen(),
                    ),
                  );
                },
              ),
              _panelItem(
                Icons.access_time_rounded,
                S.of(context).seeDrivingTime,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.pop(context);
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DriverAnalyticsScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 12),
              // SIMULATION MODE toggle
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  setState(() => _isSimulationMode = !_isSimulationMode);
                  Navigator.pop(context);
                  _snack(_isSimulationMode 
                    ? '🔧 Practice Mode ON - Simulated rides will appear' 
                    : '🔧 Practice Mode OFF - Real rides only');
                },
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 16),
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
                  decoration: BoxDecoration(
                    color: _isSimulationMode 
                        ? const Color(0xFFE8C547).withValues(alpha: 0.15)
                        : Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: _isSimulationMode 
                          ? const Color(0xFFE8C547).withValues(alpha: 0.3)
                          : borderC,
                    ),
                  ),
                  child: Row(
                    children: [
                      Icon(
                        _isSimulationMode ? Icons.videogame_asset_rounded : Icons.videogame_asset_off_rounded,
                        color: _isSimulationMode ? const Color(0xFFE8C547) : panelItemIcon,
                        size: 22,
                      ),
                      const SizedBox(width: 14),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              'Practice Mode',
                              style: TextStyle(
                                color: _isSimulationMode ? Colors.white : panelItemText,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            Text(
                              _isSimulationMode ? 'Simulated rides active' : 'Toggle for practice rides',
                              style: TextStyle(
                                color: panelItemText.withValues(alpha: 0.7),
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        width: 48,
                        height: 26,
                        decoration: BoxDecoration(
                          color: _isSimulationMode ? const Color(0xFFE8C547) : Colors.grey.withValues(alpha: 0.3),
                          borderRadius: BorderRadius.circular(13),
                        ),
                        child: AnimatedAlign(
                          duration: const Duration(milliseconds: 200),
                          alignment: _isSimulationMode ? Alignment.centerRight : Alignment.centerLeft,
                          child: Container(
                            width: 22,
                            height: 22,
                            margin: const EdgeInsets.all(2),
                            decoration: const BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              // GO OFFLINE button
              Center(
                child: GestureDetector(
                  onTap: () {
                    Navigator.pop(context);
                    _goOffline();
                  },
                  child: Column(
                    children: [
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(
                            0xFFCC3333,
                          ).withValues(alpha: 0.15),
                          border: Border.all(
                            color: const Color(
                              0xFFCC3333,
                            ).withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.pan_tool_rounded,
                          color: Color(0xFFCC3333),
                          size: 26,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        S.of(context).goOffline.toUpperCase(),
                        style: const TextStyle(
                          color: Color(0xFFCC3333),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }

  Widget _offerCard(
    Map<String, dynamic> offer,
    bool isDark,
    Color cardBg,
    Color cardBorder,
    Color textPrimary,
    Color textMuted,
    Color rejectBg,
    Color rejectText,
    Color acceptBg,
    Color borderC,
  ) {
    // Parse offer data
    final name = (offer['rider_name'] ?? 'Rider') as String;
    final init = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final fare = (offer['fare'] as num?)?.toDouble() ?? 0;
    final pickupAddr = (offer['pickup_address'] ?? 'Pickup') as String;
    final dropoffAddr = (offer['dropoff_address'] ?? 'Drop-off') as String;
    final pickupLat = (offer['pickup_lat'] as num?)?.toDouble() ?? 0;
    final pickupLng = (offer['pickup_lng'] as num?)?.toDouble() ?? 0;
    final dropoffLat = (offer['dropoff_lat'] as num?)?.toDouble() ?? 0;
    final dropoffLng = (offer['dropoff_lng'] as num?)?.toDouble() ?? 0;
    final vehicleType = (offer['vehicle_type'] ?? 'CruiseX') as String;
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);

    final distToPickup = _hav(_pos, pickupLL);
    final etaToPickup = (distToPickup * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    final tripDist = _hav(pickupLL, dropoffLL);
    final tripEta = (tripDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);

    final circleFill = isDark ? Colors.white54 : Colors.white54;
    final chipBg = Colors.white.withValues(alpha: 0.04);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: cardBg,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: cardBorder),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // â”€â”€ Top row: Avatar + Name + Fare â”€â”€
            Row(
              children: [
                // Avatar with gold gradient
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: const LinearGradient(
                      colors: [_gold, _goldLight],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                  ),
                  child: Center(
                    child: Text(
                      init,
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 19,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Name + vehicle
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        name,
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        vehicleType,
                        style: TextStyle(
                          color: _gold,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ),
                // Fare badge
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _gold.withValues(alpha: 0.2)),
                  ),
                  child: Text(
                    '\$${fare.toStringAsFixed(2)}',
                    style: const TextStyle(
                      color: _gold,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 14),

            // â”€â”€ Info chips row: miles Â· pickup ETA Â· trip time â”€â”€
            Row(
              children: [
                _infoChip(
                  Icons.near_me_rounded,
                  '${(distToPickup * 0.621371).toStringAsFixed(1)} mi',
                  chipBg,
                  textMuted,
                ),
                const SizedBox(width: 8),
                _infoChip(
                  Icons.timer_rounded,
                  '$etaToPickup min',
                  chipBg,
                  textMuted,
                ),
                const SizedBox(width: 8),
                _infoChip(
                  Icons.route_rounded,
                  '${(tripDist * 0.621371).toStringAsFixed(1)} mi trip',
                  chipBg,
                  textMuted,
                ),
                const SizedBox(width: 8),
                _infoChip(
                  Icons.schedule_rounded,
                  '$tripEta min',
                  chipBg,
                  textMuted,
                ),
              ],
            ),
            const SizedBox(height: 14),

            // â”€â”€ Route: Pickup â†’ Dropoff â”€â”€
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.02),
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: borderC),
              ),
              child: Column(
                children: [
                  // Pickup
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Column(
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.greenAccent,
                                width: 2,
                              ),
                            ),
                          ),
                          Container(width: 1.5, height: 24, color: borderC),
                        ],
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              S.of(context).pickupLabel,
                              style: TextStyle(
                                color: textMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                            Text(
                              pickupAddr,
                              style: TextStyle(
                                color: textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                  // Dropoff
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        width: 10,
                        height: 10,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: circleFill,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              S.of(context).dropOffLabel,
                              style: TextStyle(
                                color: textMuted,
                                fontSize: 10,
                                fontWeight: FontWeight.w700,
                                letterSpacing: 0.5,
                              ),
                            ),
                            Text(
                              dropoffAddr,
                              style: TextStyle(
                                color: textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 14),

            // â”€â”€ Action buttons: Reject + Accept â”€â”€
            Row(
              children: [
                // Reject button
                Expanded(
                  child: SizedBox(
                    height: 48,
                    child: OutlinedButton.icon(
                      onPressed: () => _rejectOffer(offer),
                      icon: Icon(
                        Icons.close_rounded,
                        color: rejectText,
                        size: 18,
                      ),
                      label: Text(
                        S.of(context).reject,
                        style: TextStyle(
                          color: rejectText,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: rejectBg,
                        side: BorderSide(
                          color: rejectText.withValues(alpha: 0.2),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
                        ),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                // Accept button
                Expanded(
                  flex: 2,
                  child: SizedBox(
                    height: 48,
                    child: ElevatedButton.icon(
                      onPressed: () => _acceptOffer(offer),
                      icon: const Icon(
                        Icons.check_rounded,
                        color: Colors.black,
                        size: 18,
                      ),
                      label: Text(
                        S.of(context).accept,
                        style: TextStyle(
                          color: Colors.black,
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: acceptBg,
                        foregroundColor: Colors.black,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(14),
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

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  ROUTE PREVIEW PANEL (shown when tapping an offer card)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _routePreviewPanel(bool isDark) {
    final offer = _previewingOffer!;
    final name = (offer['rider_name'] ?? 'Rider') as String;
    final init = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final fare = (offer['fare'] as num?)?.toDouble() ?? 0;
    final pickupAddr = (offer['pickup_address'] ?? 'Pickup') as String;
    final dropoffAddr = (offer['dropoff_address'] ?? 'Drop-off') as String;
    final pickupLat = (offer['pickup_lat'] as num?)?.toDouble() ?? 0;
    final pickupLng = (offer['pickup_lng'] as num?)?.toDouble() ?? 0;
    final dropoffLat = (offer['dropoff_lat'] as num?)?.toDouble() ?? 0;
    final dropoffLng = (offer['dropoff_lng'] as num?)?.toDouble() ?? 0;
    final pickupLL = LatLng(pickupLat, pickupLng);
    final dropoffLL = LatLng(dropoffLat, dropoffLng);
    final vehicleType = (offer['vehicle_type'] ?? 'CruiseX') as String;
    final distToPickup = _hav(_pos, pickupLL);
    final etaToPickup = (distToPickup * 1000 / 17.88 / 60).ceil().clamp(1, 99);
    final tripDist = _hav(pickupLL, dropoffLL);
    final tripEta = (tripDist * 1000 / 17.88 / 60).ceil().clamp(1, 99);

    const cCardBg = Color(0xFF1A1A1A); // ignore: unused_local_variable
    const cTextPrimary = Colors.white;
    final cTextMuted = Colors.white.withValues(alpha: 0.5);
    final cBorderC = Colors.white.withValues(alpha: 0.06);
    final chipBg = Colors.white.withValues(alpha: 0.04);

    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0A0A0A).withValues(alpha: 0.97),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 24,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Handle
                  Container(
                    width: 36,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                  const SizedBox(height: 12),

                  // â”€â”€ Top row: Avatar + Name + Fare â”€â”€
                  Row(
                    children: [
                      Container(
                        width: 44,
                        height: 44,
                        decoration: const BoxDecoration(
                          shape: BoxShape.circle,
                          gradient: LinearGradient(
                            colors: [_gold, _goldLight],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                        ),
                        child: Center(
                          child: Text(
                            init,
                            style: const TextStyle(
                              color: Colors.black,
                              fontSize: 19,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              name,
                              style: const TextStyle(
                                color: cTextPrimary,
                                fontSize: 16,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              vehicleType,
                              style: const TextStyle(
                                color: _gold,
                                fontSize: 11,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ),
                      ),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: _gold.withValues(alpha: 0.10),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: _gold.withValues(alpha: 0.2),
                          ),
                        ),
                        child: Text(
                          '\$${fare.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 22,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // â”€â”€ Info chips â”€â”€
                  Row(
                    children: [
                      _infoChip(
                        Icons.near_me_rounded,
                        '${(distToPickup * 0.621371).toStringAsFixed(1)} mi',
                        chipBg,
                        cTextMuted,
                      ),
                      const SizedBox(width: 8),
                      _infoChip(
                        Icons.timer_rounded,
                        '$etaToPickup min',
                        chipBg,
                        cTextMuted,
                      ),
                      const SizedBox(width: 8),
                      _infoChip(
                        Icons.route_rounded,
                        '${(tripDist * 0.621371).toStringAsFixed(1)} mi trip',
                        chipBg,
                        cTextMuted,
                      ),
                      const SizedBox(width: 8),
                      _infoChip(
                        Icons.schedule_rounded,
                        '$tripEta min',
                        chipBg,
                        cTextMuted,
                      ),
                    ],
                  ),
                  const SizedBox(height: 14),

                  // â”€â”€ Route: Driver â†’ Pickup â†’ Dropoff â”€â”€
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.02),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(color: cBorderC),
                    ),
                    child: Column(
                      children: [
                        // Driver location
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.blueAccent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 1.5,
                                  height: 20,
                                  color: cBorderC,
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.of(context).yourLocation,
                                    style: TextStyle(
                                      color: cTextMuted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    S.of(context).currentPosition,
                                    style: const TextStyle(
                                      color: cTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // Pickup
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Column(
                              children: [
                                Container(
                                  width: 10,
                                  height: 10,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    border: Border.all(
                                      color: Colors.greenAccent,
                                      width: 2,
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 1.5,
                                  height: 20,
                                  color: cBorderC,
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.of(context).pickupLabel,
                                    style: TextStyle(
                                      color: cTextMuted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    pickupAddr,
                                    style: const TextStyle(
                                      color: cTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                        // Dropoff
                        Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              width: 10,
                              height: 10,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Colors.white54,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    S.of(context).dropOffLabel,
                                    style: TextStyle(
                                      color: cTextMuted,
                                      fontSize: 10,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 0.5,
                                    ),
                                  ),
                                  Text(
                                    dropoffAddr,
                                    style: const TextStyle(
                                      color: cTextPrimary,
                                      fontSize: 13,
                                      fontWeight: FontWeight.w600,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 14),

                  // â”€â”€ Action buttons: Back + Accept â”€â”€
                  Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: _closePreview,
                            icon: const Icon(
                              Icons.arrow_back_rounded,
                              color: Colors.white70,
                              size: 18,
                            ),
                            label: Text(
                              S.of(context).back,
                              style: const TextStyle(
                                color: Colors.white70,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: OutlinedButton.styleFrom(
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.06,
                              ),
                              side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 2,
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton.icon(
                            onPressed: () {
                              _closePreview();
                              _acceptOffer(offer);
                            },
                            icon: const Icon(
                              Icons.check_rounded,
                              color: Colors.black,
                              size: 18,
                            ),
                            label: Text(
                              S.of(context).acceptRide,
                              style: const TextStyle(
                                color: Colors.black,
                                fontSize: 15,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: _gold,
                              foregroundColor: Colors.black,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(14),
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
          ),
        ),
      ),
    );
  }

  Widget _infoChip(IconData ic, String txt, Color bg, Color textColor) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 6),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(ic, size: 14, color: _gold.withValues(alpha: 0.7)),
            const SizedBox(height: 2),
            Text(
              txt,
              style: TextStyle(
                color: textColor,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }

  Widget _badge(IconData ic, String txt, Color c) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: c.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: c.withValues(alpha: 0.15)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(ic, size: 12, color: c),
          const SizedBox(width: 4),
          Text(
            txt,
            style: TextStyle(
              color: c,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }

  // â”€â”€ ROUTE SUMMARY PANEL (Google Maps-style overview before navigation) â”€â”€
  Widget _routeSummaryPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return _bottomSheet(
      isDark,
      bg,
      shadowC,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(isDark),
          const SizedBox(height: 10),
          // Route summary header
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: _gold.withValues(alpha: 0.12)),
            ),
            child: Row(
              children: [
                const Icon(Icons.route_rounded, color: _gold, size: 22),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        S.of(context).routeOverview,
                        style: TextStyle(
                          color: textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _dropoffAddr,
                        style: TextStyle(
                          color: textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Text(
                      '${(_navDist * 0.621371).toStringAsFixed(1)} mi',
                      style: const TextStyle(
                        color: _gold,
                        fontSize: 16,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      '$_navEta min',
                      style: TextStyle(
                        color: textMuted,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          // Rider info row
          Row(
            children: [
              _avatar(38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of(context).droppingOff(_riderName),
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_rounded,
                          size: 11,
                          color: textMuted,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _dropoffAddr,
                            style: TextStyle(color: textMuted, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              Text(
                '\$${_fare.toStringAsFixed(2)}',
                style: const TextStyle(
                  color: _gold,
                  fontSize: 18,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Re-center button + Start Navigation button
          Row(
            children: [
              // Re-center / overview button
              GestureDetector(
                onTap: () {
                  HapticFeedback.lightImpact();
                  _fitBoundsMulti([_pos, _pickupLL, _dropoffLL]);
                },
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: _gold.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(color: _gold.withValues(alpha: 0.2)),
                  ),
                  child: const Icon(
                    Icons.center_focus_strong_rounded,
                    color: _gold,
                    size: 22,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              // Start Navigation button
              Expanded(
                child: SizedBox(
                  height: 48,
                  child: ElevatedButton.icon(
                    onPressed: _beginNavigation,
                    icon: const Icon(
                      Icons.navigation_rounded,
                      color: Colors.black,
                      size: 20,
                    ),
                    label: Flexible(
                      child: Text(
                        S.of(context).startNavigation,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: _gold,
                      foregroundColor: Colors.black,
                      elevation: 4,
                      shadowColor: _gold.withValues(alpha: 0.3),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // â”€â”€ PICKUP PANEL â”€â”€
  Widget _pickupPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return _bottomSheet(
      isDark,
      bg,
      shadowC,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(isDark),
          const SizedBox(height: 12),
          Row(
            children: [
              _avatar(42),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of(context).pickingUp(_riderName),
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Text(
                      _pickupAddr,
                      style: TextStyle(color: textMuted, fontSize: 12),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              _actionBtn(Icons.phone_rounded, () async {
                if (_riderPhone.isNotEmpty) {
                  final uri = Uri(scheme: 'tel', path: _riderPhone);
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                }
              }),
              const SizedBox(width: 8),
              _actionBtn(Icons.chat_bubble_rounded, () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      recipientName: _riderName,
                      recipientPhone: _riderPhone,
                      tripId: _tripId,
                    ),
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 14),
          // Show ARRIVED button (prominent when near pickup)
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _arrivePickup,
              icon: const Icon(
                Icons.place_rounded,
                color: Colors.black,
                size: 20,
              ),
              label: Flexible(
                child: Text(
                  _nearPickupNotified
                      ? S.of(context).arrived
                      : S.of(context).arrivedAtPickup,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.black,
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _nearPickupNotified
                    ? _gold
                    : _gold.withValues(alpha: 0.85),
                foregroundColor: Colors.black,
                elevation: _nearPickupNotified ? 6 : 2,
                shadowColor: _gold.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _cancelRow(isDark),
        ],
      ),
    );
  }

  // â”€â”€ ARRIVED PANEL â”€â”€
  Widget _arrivedPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return _bottomSheet(
      isDark,
      bg,
      shadowC,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(isDark),
          const SizedBox(height: 12),
          // Waiting status
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: _goldLight.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _goldLight.withValues(alpha: 0.1)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    valueColor: AlwaysStoppedAnimation(
                      _goldLight.withValues(alpha: 0.8),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  S.of(context).waitingForRider,
                  style: TextStyle(
                    color: textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              _avatar(50),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      _riderName,
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _gold.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        _vehicleType,
                        style: const TextStyle(
                          color: _gold,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              _actionBtn(Icons.phone_rounded, () async {
                if (_riderPhone.isNotEmpty) {
                  final uri = Uri(scheme: 'tel', path: _riderPhone);
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                }
              }),
              const SizedBox(width: 8),
              _actionBtn(Icons.chat_bubble_rounded, () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      recipientName: _riderName,
                      recipientPhone: _riderPhone,
                      tripId: _tripId,
                    ),
                  ),
                );
              }),
            ],
          ),
          const SizedBox(height: 14),
          // START TRIP button
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed: _startTrip,
              icon: const Icon(
                Icons.play_arrow_rounded,
                color: Colors.black,
                size: 22,
              ),
              label: Text(
                S.of(context).startTrip,
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 16,
                  fontWeight: FontWeight.w900,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _gold,
                foregroundColor: Colors.black,
                elevation: 4,
                shadowColor: _gold.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          _cancelRow(isDark),
        ],
      ),
    );
  }

  // â”€â”€ IN-TRIP PANEL â”€â”€
  // NAV STAT CHIP (icon + label, used in Google Maps-style ETA strip)
  Widget _navStat(IconData icon, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, color: color, size: 13),
        const SizedBox(width: 4),
        Text(
          value,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }

  Widget _tripPanel(
    bool isDark,
    Color bg,
    Color textPrimary,
    Color textMuted,
    Color borderC,
    Color shadowC,
  ) {
    return _bottomSheet(
      isDark,
      bg,
      shadowC,
      Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _handle(isDark),
          const SizedBox(height: 10),
          // Trip progress
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 16),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: _gold.withValues(alpha: 0.12)),
            ),
            child: Row(
              children: [
                Container(
                  width: 8,
                  height: 8,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _gold,
                    boxShadow: [
                      BoxShadow(
                        color: _gold.withValues(alpha: 0.5),
                        blurRadius: 6,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  S.of(context).tripInProgress,
                  style: TextStyle(
                    color: textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                  ),
                ),
                const Spacer(),
                Text(
                  '\$${_fare.toStringAsFixed(2)}',
                  style: const TextStyle(
                    color: _gold,
                    fontSize: 18,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: _navProgress,
              backgroundColor: isDark
                  ? Colors.white.withValues(alpha: 0.04)
                  : Colors.black.withValues(alpha: 0.06),
              valueColor: const AlwaysStoppedAnimation(_gold),
              minHeight: 4,
            ),
          ),
          const SizedBox(height: 8),
          // Google Maps–style ETA / distance strip ──────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            decoration: BoxDecoration(
              color: _gold.withValues(alpha: 0.07),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                _navStat(Icons.schedule_rounded, '$_navEta min', textPrimary),
                Container(
                  width: 1,
                  height: 20,
                  color: textMuted.withValues(alpha: 0.25),
                ),
                _navStat(
                  Icons.straighten_rounded,
                  '${(_navDist * 0.621371).toStringAsFixed(1)} mi',
                  textPrimary,
                ),
                Container(
                  width: 1,
                  height: 20,
                  color: textMuted.withValues(alpha: 0.25),
                ),
                _navStat(
                  Icons.place_rounded,
                  S.of(context).dropOffLabel.toUpperCase(),
                  _gold,
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _avatar(38),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      S.of(context).droppingOff(_riderName),
                      style: TextStyle(
                        color: textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Row(
                      children: [
                        Icon(
                          Icons.location_on_rounded,
                          size: 11,
                          color: textMuted,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: Text(
                            _dropoffAddr,
                            style: TextStyle(color: textMuted, fontSize: 11),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              _actionBtn(Icons.phone_rounded, () async {
                if (_riderPhone.isNotEmpty) {
                  final uri = Uri(scheme: 'tel', path: _riderPhone);
                  if (await canLaunchUrl(uri)) await launchUrl(uri);
                }
              }),
            ],
          ),
          const SizedBox(height: 12),
          // FINISH TRIP button — only active when near dropoff
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton.icon(
              onPressed:
                  _complete, // always enabled — driver manually ends trip
              icon: const Icon(
                Icons.flag_rounded,
                color: Colors.black,
                size: 20,
              ),
              label: Text(
                _nearDropoffNotified
                    ? S.of(context).finishTrip
                    : '${(_navDist * 0.621371).toStringAsFixed(1)} mi',
                style: const TextStyle(
                  color: Colors.black,
                  fontSize: 15,
                  fontWeight: FontWeight.w900,
                ),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: _nearDropoffNotified
                    ? _gold
                    : _gold.withValues(alpha: 0.65),
                foregroundColor: Colors.black,
                elevation: _nearDropoffNotified ? 6 : 2,
                shadowColor: _gold.withValues(alpha: 0.4),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          _cancelRow(isDark),
        ],
      ),
    );
  }

  // â”€â”€ COMPLETED OVERLAY â”€â”€
  Widget _completedOverlay(
    bool isDark,
    Color overlayBg,
    Color card,
    Color textPrimary,
    Color borderC,
    Color shadowC,
  ) {
    final subtleText = isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.35);
    final subtleBg = isDark
        ? Colors.white.withValues(alpha: 0.03)
        : Colors.black.withValues(alpha: 0.04);

    return GestureDetector(
      onTap: () {},
      child: Container(
        color: overlayBg,
        child: Center(
          child: ScaleTransition(
            scale: _doneScale,
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: card,
                borderRadius: BorderRadius.circular(24),
                border: Border.all(color: _gold.withValues(alpha: 0.2)),
                boxShadow: [
                  BoxShadow(
                    color: _gold.withValues(alpha: 0.08),
                    blurRadius: 40,
                    spreadRadius: 4,
                  ),
                ],
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 72,
                    height: 72,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: LinearGradient(
                        colors: [
                          _gold.withValues(alpha: 0.15),
                          _gold.withValues(alpha: 0.05),
                        ],
                      ),
                      border: Border.all(
                        color: _gold.withValues(alpha: 0.3),
                        width: 2,
                      ),
                    ),
                    child: const Icon(
                      Icons.check_rounded,
                      color: _gold,
                      size: 38,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    S.of(context).tripComplete,
                    style: TextStyle(
                      color: textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  const SizedBox(height: 20),
                  // Fare
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: _gold.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(16),
                      border: Border.all(color: _gold.withValues(alpha: 0.1)),
                    ),
                    child: Column(
                      children: [
                        Text(
                          '\$${_fare.toStringAsFixed(2)}',
                          style: const TextStyle(
                            color: _gold,
                            fontSize: 36,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                        Text(
                          S.of(context).fareEarned,
                          style: TextStyle(color: subtleText, fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Rating
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    decoration: BoxDecoration(
                      color: subtleBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Column(
                      children: [
                        Text(
                          S.of(context).rateRider,
                          style: TextStyle(color: subtleText, fontSize: 11),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: List.generate(
                            5,
                            (i) => GestureDetector(
                              onTap: () {
                                HapticFeedback.selectionClick();
                                setState(() => _stars = i + 1);
                              },
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 3,
                                ),
                                child: Icon(
                                  Icons.star_rounded,
                                  color: i < _stars
                                      ? _gold
                                      : _gold.withValues(alpha: 0.15),
                                  size: 30,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  // Session summary
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _sumStat(
                        '\$${_earnings.toStringAsFixed(2)}',
                        S.of(context).totalLabel,
                        textPrimary,
                        subtleText,
                      ),
                      _sumStat(
                        '$_trips',
                        S.of(context).tripsLabel,
                        textPrimary,
                        subtleText,
                      ),
                      _sumStat(
                        _timeStr,
                        S.of(context).onlineLabel,
                        textPrimary,
                        subtleText,
                      ),
                    ],
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    height: 52,
                    child: ElevatedButton(
                      onPressed: _afterComplete,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _gold,
                        foregroundColor: Colors.black,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                        ),
                        elevation: 4,
                        shadowColor: _gold.withValues(alpha: 0.3),
                      ),
                      child: Text(
                        S.of(context).continueDriving,
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w900,
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
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  ONLINE PANEL (draggable with GO OFFLINE)
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  void _showOnlinePanel() {
    setState(() => _panelOpen = !_panelOpen);
  }

  Widget _draggablePanel(
    bool isDark,
    Color surface,
    Color textMuted,
    Color borderC,
    Color textPrimary,
    Color shadowC,
  ) {
    final screenH = MediaQuery.of(context).size.height;
    final botPad = MediaQuery.of(context).padding.bottom;
    final minFrac = ((86 + botPad) / screenH).clamp(0.10, 0.20);
    final panelItemText = isDark
        ? Colors.white.withValues(alpha: 0.7)
        : Colors.black.withValues(alpha: 0.6);
    final panelItemIcon = isDark
        ? Colors.white.withValues(alpha: 0.5)
        : Colors.black.withValues(alpha: 0.4);
    final panelItemChevron = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.black.withValues(alpha: 0.12);

    return DraggableScrollableSheet(
      controller: _panelSheetCtrl,
      initialChildSize: minFrac,
      minChildSize: minFrac,
      maxChildSize: 0.55,
      snap: true,
      snapSizes: [minFrac, 0.55],
      builder: (ctx, scrollCtrl) {
        return Container(
          decoration: BoxDecoration(
            color: surface,
            borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
            border: Border(
              top: BorderSide(color: _gold.withValues(alpha: 0.08)),
            ),
            boxShadow: [
              BoxShadow(
                color: shadowC,
                blurRadius: 20,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          child: ListView(
            controller: scrollCtrl,
            physics: const ClampingScrollPhysics(),
            padding: EdgeInsets.zero,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ListenableBuilder(
                    listenable: _searchPulseVal,
                    builder: (_, __) => SizedBox(
                      height: 2,
                      child: LinearProgressIndicator(
                        value: null,
                        backgroundColor: Colors.transparent,
                        valueColor: AlwaysStoppedAnimation(
                          _gold.withValues(alpha: 0.5),
                        ),
                        minHeight: 2,
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  _handle(isDark),
                  Icon(
                    Icons.keyboard_arrow_up_rounded,
                    color: textMuted.withValues(alpha: 0.5),
                    size: 18,
                  ),
                  SizedBox(
                    height: 40,
                    child: Row(
                      children: [
                        const SizedBox(width: 16),
                        Icon(Icons.tune_rounded, color: textMuted, size: 22),
                        const Spacer(),
                        Text(
                          S.of(context).findingTrips,
                          style: TextStyle(
                            color: textMuted,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const Spacer(),
                        Icon(
                          Icons.format_list_bulleted_rounded,
                          color: textMuted,
                          size: 22,
                        ),
                        const SizedBox(width: 16),
                      ],
                    ),
                  ),
                ],
              ),

              const SizedBox(height: 12),
              Divider(height: 1, color: borderC),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  S.of(context).recommendedForYou,
                  style: TextStyle(
                    color: textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              _panelItem(
                Icons.bar_chart_rounded,
                S.of(context).seeEarningsTrends,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DriverEarningsScreen(),
                    ),
                  );
                },
              ),
              _panelItem(
                Icons.star_outline_rounded,
                S.of(context).seeUpcomingPromotions,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DriverPromosScreen(),
                    ),
                  );
                },
              ),
              _panelItem(
                Icons.access_time_rounded,
                S.of(context).seeDrivingTime,
                panelItemIcon,
                panelItemText,
                panelItemChevron,
                () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const DriverAnalyticsScreen(),
                    ),
                  );
                },
              ),
              const SizedBox(height: 20),
              // GO OFFLINE button
              Center(
                child: GestureDetector(
                  onTap: _goOffline,
                  child: Column(
                    children: [
                      Container(
                        width: 62,
                        height: 62,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(
                            0xFFCC3333,
                          ).withValues(alpha: 0.15),
                          border: Border.all(
                            color: const Color(
                              0xFFCC3333,
                            ).withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                        child: const Icon(
                          Icons.pan_tool_rounded,
                          color: Color(0xFFCC3333),
                          size: 26,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        S.of(context).goOffline.toUpperCase(),
                        style: const TextStyle(
                          color: Color(0xFFCC3333),
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(height: MediaQuery.of(context).padding.bottom),
            ],
          ),
        );
      },
    );
  }

  Widget _panelItem(
    IconData ic,
    String txt,
    Color iconC,
    Color textC,
    Color chevronC,
    VoidCallback tap,
  ) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        onTap: () {
          HapticFeedback.selectionClick();
          tap();
        },
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
        contentPadding: const EdgeInsets.symmetric(horizontal: 12),
        leading: Icon(ic, color: iconC, size: 22),
        title: Text(
          txt,
          style: TextStyle(
            color: textC,
            fontSize: 14,
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: Icon(Icons.chevron_right_rounded, color: chevronC, size: 20),
      ),
    );
  }

  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  //  SHARED WIDGETS
  // â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•â•
  Widget _slideToAction(
    String label,
    Color c,
    bool isDark,
    VoidCallback onDone,
  ) {
    final labelColor = isDark
        ? Colors.white.withValues(alpha: 0.35)
        : Colors.black.withValues(alpha: 0.30);

    return StatefulBuilder(
      builder: (ctx, setLocal) {
        return Container(
          height: 56,
          decoration: BoxDecoration(
            color: c.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: c.withValues(alpha: 0.18), width: 1.5),
          ),
          child: LayoutBuilder(
            builder: (_, cons) {
              final max = cons.maxWidth - 60;
              return Stack(
                children: [
                  Center(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: labelColor,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(28),
                      child: FractionallySizedBox(
                        widthFactor: _slideVal,
                        alignment: Alignment.centerLeft,
                        child: Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                c.withValues(alpha: 0.12),
                                c.withValues(alpha: 0.0),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: _slideVal * max + 4,
                    top: 4,
                    bottom: 4,
                    child: GestureDetector(
                      onHorizontalDragUpdate: (d) {
                        setLocal(() {
                          _slideVal += d.delta.dx / max;
                          _slideVal = _slideVal.clamp(0.0, 1.0);
                        });
                        if (_slideVal >= 0.88 && !_slid) {
                          _slid = true;
                          HapticFeedback.heavyImpact();
                          onDone();
                        }
                      },
                      onHorizontalDragEnd: (_) {
                        if (!_slid) setLocal(() => _slideVal = 0);
                      },
                      child: Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: c,
                          shape: BoxShape.circle,
                          boxShadow: [
                            BoxShadow(
                              color: c.withValues(alpha: 0.35),
                              blurRadius: 10,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.chevron_right_rounded,
                          color: Colors.black,
                          size: 26,
                        ),
                      ),
                    ),
                  ),
                ],
              );
            },
          ),
        );
      },
    );
  }

  Widget _bottomSheet(bool isDark, Color bg, Color shadowC, Widget child) {
    return Container(
      decoration: BoxDecoration(
        color: bg,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        border: Border(top: BorderSide(color: _gold.withValues(alpha: 0.08))),
        boxShadow: [
          BoxShadow(
            color: shadowC,
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
          child: child,
        ),
      ),
    );
  }

  Widget _handle(bool isDark) => Center(
    child: Container(
      width: 40,
      height: 5,
      decoration: BoxDecoration(
        color: isDark
            ? Colors.white.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.2),
        borderRadius: BorderRadius.circular(3),
      ),
    ),
  );

  Widget _fab(
    IconData ic,
    double sz,
    Color bg,
    Color border,
    Color iconColor,
    VoidCallback tap,
  ) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        tap();
      },
      child: ClipOval(
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 10, sigmaY: 10),
          child: Container(
            width: sz,
            height: sz,
            decoration: BoxDecoration(
              color: bg,
              shape: BoxShape.circle,
              border: Border.all(color: border),
            ),
            child: Icon(ic, color: iconColor, size: sz * 0.44),
          ),
        ),
      ),
    );
  }

  Widget _avatar(double s) {
    return Container(
      width: s,
      height: s,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: const LinearGradient(colors: [_gold, _goldLight]),
      ),
      child: Center(
        child: Text(
          _riderInit,
          style: TextStyle(
            color: Colors.black,
            fontSize: s * 0.42,
            fontWeight: FontWeight.w900,
          ),
        ),
      ),
    );
  }

  Widget _actionBtn(IconData ic, VoidCallback tap) {
    return GestureDetector(
      onTap: () {
        HapticFeedback.lightImpact();
        tap();
      },
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: _gold.withValues(alpha: 0.1),
          shape: BoxShape.circle,
          border: Border.all(color: _gold.withValues(alpha: 0.2)),
        ),
        child: Icon(ic, color: _gold, size: 18),
      ),
    );
  }

  Widget _cancelRow(bool isDark) => TextButton(
    onPressed: _cancel,
    child: Text(
      S.of(context).cancelTrip,
      style: TextStyle(
        color: isDark
            ? Colors.white.withValues(alpha: 0.25)
            : Colors.black.withValues(alpha: 0.25),
        fontSize: 12,
        fontWeight: FontWeight.w600,
      ),
    ),
  );

  Widget _sumStat(String v, String l, Color vColor, Color lColor) => Column(
    children: [
      Text(
        v,
        style: TextStyle(
          color: vColor,
          fontSize: 13,
          fontWeight: FontWeight.w800,
        ),
      ),
      Text(l, style: TextStyle(color: lColor, fontSize: 10)),
    ],
  );
}
