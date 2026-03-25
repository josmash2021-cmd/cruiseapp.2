import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:mapbox_maps_flutter/mapbox_maps_flutter.dart' as mapbox;
import '../models/lat_lng.dart';
import '../config/mapbox_config.dart';
import '../config/map_theme.dart';

import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../config/page_transitions.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import '../services/trip_firestore_service.dart';
import '../widgets/offline_banner.dart';
import 'package:firebase_database/firebase_database.dart';
import '../config/api_keys.dart';
import 'chat_screen.dart';
import '../services/chat_service.dart';
import 'help_screen.dart';
import 'home_screen.dart';
import 'rider_rating_screen.dart';
import '../l10n/app_localizations.dart';

class RiderTrackingScreen extends StatefulWidget {
  const RiderTrackingScreen({
    super.key,
    required this.pickupLatLng,
    required this.dropoffLatLng,
    this.routePoints,
    this.driverName = 'Driver',
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
    this.onTripComplete,
  });

  final LatLng pickupLatLng;
  final LatLng dropoffLatLng;
  final List<LatLng>? routePoints;
  final String driverName;
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
  final VoidCallback? onTripComplete;

  @override
  State<RiderTrackingScreen> createState() => _RiderTrackingScreenState();
}

enum _TrackPhase { arriving, arrived, onTrip, completed }

enum _PinIcon { house, store, airplane, person }

class _RiderTrackingScreenState extends State<RiderTrackingScreen>
    with TickerProviderStateMixin {
  mapbox.MapboxMap? _map;
  mapbox.PointAnnotationManager? _pointAnnotMgr;
  mapbox.PolylineAnnotationManager? _polylineAnnotMgr;
  mapbox.PointAnnotation? _pickupAnnot;
  mapbox.PointAnnotation? _dropoffAnnot;
  mapbox.PolylineAnnotation? _fullRouteAnnot;
  mapbox.PolylineAnnotation? _remainingRouteAnnot;
  mapbox.PolylineAnnotation? _routeCasingAnnot;
  mapbox.PolylineAnnotation? _routeShineAnnot;
  final double _cameraBearing = 0;
  Uint8List? _pickupPinBytes;
  Uint8List? _dropoffPinBytes;
  Uint8List? _pickupPinWithLabelBytes;
  Uint8List? _dropoffPinWithLabelBytes;
  bool _pickupLabelRevealed = false;
  bool _dropoffLabelRevealed = false;

  // ── Cinematic intro animation ──
  AnimationController? _tiltCtrl;
  Animation<double>? _tiltAnim;
  AnimationController? _bearingCtrl;
  Animation<double>? _bearingAnim;
  AnimationController? _glowPulseCtrl;
  double _randomBearing = 0;
  double _cinematicPitch = 0;
  double _cinematicBearing = 0;
  bool _cinematicDone = false;

  // ── Car marker using GeoJSON source (correct approach for v10 SDK) ──
  Uint8List? _carIconBytes;
  Uint8List? _carShadowBytes; // Sombra difuminada
  String _currentCarType = '';
  static const String _carSourceId = 'car-source';
  static const String _carLayerId = 'car-layer';
  static const String _carImageId = 'car-image';
  static const String _carShadowSourceId = 'car-shadow-source';
  static const String _carShadowLayerId = 'car-shadow-layer';
  static const String _carShadowImageId = 'car-shadow-image';
  bool _carImageAdded = false;
  bool _carShadowAdded = false;
  bool _carUpdateInProgress = false; // guard: prevents 60fps async race conditions
  LatLng? _directTargetPos; // for GPS fallback: lerp target when off-route
  static const String _arrowImageId = 'arrow-image';
  bool _arrowImageAdded = false;
  static const double _kCarScale = 0.06; // car PNG is ~940px; 0.06 → ~56dp on screen

  // ── Car entrance animation (transición de formación profesional) ──
  bool _carEntranceStarted = false;
  bool _carEntranceComplete = false;
  double _carEntranceProgress = 0.0; // 0.0 a 1.0
  static const double _entranceDuration = 800.0; // ms
  DateTime? _entranceStartTime;
  Timer? _entranceTimer;

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

  int _pickupIdx = 0;

  /// Cumulative distance array — _segDist[i] = total meters from start to point i.
  List<double> _segDist = [];

  /// Current traveled distance in meters along the route.
  double _traveledM = 0;

  Ticker? _interpTicker;

  /// Target traveled distance (set by sim timer, approached smoothly by interp ticker)
  double _tgtTraveledM = 0;
  final double _tgtBrg = 0;
  Timer? _camTimer;
  bool _userMovedMap = false;
  bool _programmaticCam = false;

  // ── Smooth camera bounds (60fps lerp) ──
  double _camSWLat = 0, _camSWLng = 0, _camNELat = 0, _camNELng = 0;
  double _tgtSWLat = 0, _tgtSWLng = 0, _tgtNELat = 0, _tgtNELng = 0;
  bool _camInitialized = false;

  // ── Real-time tracking via Firestore ──
  StreamSubscription<LatLng>? _driverLocSub;
  StreamSubscription<Map<String, dynamic>?>? _tripStatusSub;
  StreamSubscription? _rtdbDriverLocSub;
  String? _rtdbDriverId;
  Timer? _statusPollTimer;
  Timer? _simTimer; // demo simulation timer

  late AnimationController _etaPulse;

  String get _vehicleAsset {
    final rn = widget.rideName.toLowerCase();
    final m = widget.vehicleModel.toLowerCase();
    if (rn.contains('vip') || rn.contains('suv') || rn.contains('suburban') || m.contains('suburban')) {
      return 'assets/images/car_suv.png';
    }
    if (rn.contains('sedan') || rn.contains('premium') || rn.contains('fusion') || m.contains('fusion')) {
      return 'assets/images/car_sedan.png';
    }
    return 'assets/images/car_economy.png';
  }

  @override
  void initState() {
    super.initState();
    _etaPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    // Load car PNG based on ride type
    _loadCarIcon();
    _loadPins();
    _initFromPersistence();
    _interpTicker = createTicker((_) => _interpolate())..start();
    _startRealTimeTracking();
    _startSimIfNeeded();
    // Send greeting notification after 3 seconds
    Future.delayed(const Duration(seconds: 3), _sendDriverGreeting);
    // Notify rider that a driver was assigned
    _sendRideNotification(
      'Driver Assigned',
      '${widget.driverName.split(' ').first} is on the way in a ${widget.vehicleColor} ${widget.vehicleModel}',
    );
    // Save state periodically for resume support
    Timer.periodic(const Duration(seconds: 5), (_) => _saveRideState());
  }

  /// Connect to Firestore for real-time driver location and trip status.
  void _startRealTimeTracking() {
    final fsId = widget.firestoreTripId;
    if (fsId != null && fsId.isNotEmpty) {
      // Watch driver location in real time
      _driverLocSub = TripFirestoreService.watchDriverLocation(fsId).listen(
        (ll) {
          if (!mounted || _phase == _TrackPhase.completed) return;
          _onRealDriverLocation(ll);
        },
        onError: (error) {
          debugPrint('[RiderTracking] Driver location listener error: $error');
        },
      );

      // Watch trip status changes
      _tripStatusSub = TripFirestoreService.watchTrip(fsId).listen(
        (data) {
          if (!mounted || data == null) return;
          _onTripStatusUpdate(data);
        },
        onError: (error) {
          debugPrint('[RiderTracking] Trip status listener error: $error');
        },
      );
    }

    // Also poll backend status as fallback
    final tripId = widget.tripId;
    if (tripId != null) {
      _statusPollTimer = Timer.periodic(const Duration(seconds: 5), (_) async {
        if (!mounted || _phase == _TrackPhase.completed) return;
        try {
          final status = await ApiService.getTrip(tripId);
          final st = status['status']?.toString() ?? '';
          if (st == 'completed') {
            _statusPollTimer?.cancel();
            if (mounted && _phase != _TrackPhase.completed) {
              LocalDataService.clearActiveRide();
              setState(() => _phase = _TrackPhase.completed);
              _goToRating();
            }
          } else if (st == 'cancelled' || st == 'canceled') {
            _statusPollTimer?.cancel();
            if (mounted) {
              LocalDataService.clearActiveRide();
              widget.onTripComplete?.call();
            }
          } else if (st == 'arrived' && _phase == _TrackPhase.arriving) {
            if (mounted) setState(() => _phase = _TrackPhase.arrived);
          } else if (st == 'in_trip' &&
              (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived)) {
            if (mounted) {
              setState(() => _phase = _TrackPhase.onTrip);
              _addDropoffPin();
            }
          }
        } catch (_) {}
      });
    }
  }

  /// Process real-time driver location from Firestore.
  void _onRealDriverLocation(LatLng ll) {
    if (ll.latitude == 0 && ll.longitude == 0) return;

    bool usedRouteProjection = false;
    
    // Try to project onto route for smooth animation
    if (_segDist.isNotEmpty && _routePts.length >= 2) {
      final projectedM = _projectOntoRoute(ll);
      final distToStart = _hav(ll, _routePts.first) * 1609.34;
      
      // Only use projection if it's reasonable
      if (projectedM > 0 || distToStart < 100) {
        _tgtTraveledM = projectedM.clamp(0.0, _segDist.last);
        usedRouteProjection = true;
      }
    }
    
    // Fallback: if projection didn't work, set a lerp target (never teleport _animPos)
    if (!usedRouteProjection) {
      _directTargetPos = ll;
    }

    // Update phase and distances
    if (_phase == _TrackPhase.arriving) {
      final dist = _hav(ll, widget.pickupLatLng);
      _distanceMiles = dist;
      _etaMinutes = (dist / 0.5).ceil().clamp(1, 99);
      if (dist < 0.05) {
        setState(() => _phase = _TrackPhase.arrived);
        if (!_arrivedNotifSent) {
          _arrivedNotifSent = true;
          _sendRideNotification(
            'Your driver has arrived',
            '${widget.driverName.split(' ').first} is waiting at the pickup spot in a ${widget.vehicleColor} ${widget.vehicleModel}.',
          );
        }
      }
    } else if (_phase == _TrackPhase.onTrip) {
      final dist = _hav(ll, widget.dropoffLatLng);
      _distanceMiles = dist;
      _etaMinutes = (dist / 0.5).ceil().clamp(1, 99);
    }

    setState(() {});
    _throttleCam();
  }

  /// Project a lat/lng onto the nearest point on the route polyline,
  /// returning the cumulative distance in meters along the route.
  double _projectOntoRoute(LatLng p) {
    if (_routePts.length < 2) return 0;
    
    double bestDist = double.infinity;
    double bestM = 0;

    for (int i = 0; i + 1 < _routePts.length; i++) {
      final a = _routePts[i];
      final b = _routePts[i + 1];
      final segStartM = _segDist[i];
      final segEndM = _segDist[i + 1];
      final segLenM = segEndM - segStartM;
      if (segLenM < 0.01) continue;

      // Convert to local coordinate system for accurate projection
      final dy = (b.latitude - a.latitude) * 111320; // meters per degree latitude
      final dx = (b.longitude - a.longitude) * 111320 * math.cos(a.latitude * math.pi / 180);
      final px = (p.longitude - a.longitude) * 111320 * math.cos(a.latitude * math.pi / 180);
      final py = (p.latitude - a.latitude) * 111320;
      
      var t = 0.0;
      if (dx != 0 || dy != 0) {
        final segLen2 = dx * dx + dy * dy;
        t = (px * dx + py * dy) / segLen2;
        t = t.clamp(0.0, 1.0);
      }
      
      final projLat = a.latitude + (b.latitude - a.latitude) * t;
      final projLng = a.longitude + (b.longitude - a.longitude) * t;
      final proj = LatLng(projLat, projLng);

      final dist = _hav(p, proj) * 1609.34; // Convert to meters
      if (dist < bestDist) {
        bestDist = dist;
        bestM = segStartM + segLenM * t;
      }
    }

    return bestM;
  }

  /// Process trip status changes from Firestore.
  void _onTripStatusUpdate(Map<String, dynamic> data) {
    // Start RTDB listener if we have a driverId
    final did = data['driverId']?.toString();
    if (did != null && did.isNotEmpty && _rtdbDriverId != did) {
      _startRtdbDriverListener(did);
    }

    final status = data['status']?.toString() ?? '';
    if (status == 'arrived' && _phase == _TrackPhase.arriving) {
      setState(() => _phase = _TrackPhase.arrived);
    } else if (status == 'in_trip' &&
        (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived)) {
      setState(() => _phase = _TrackPhase.onTrip);
      _addDropoffPin();
    } else if (status == 'completed' && _phase != _TrackPhase.completed) {
      LocalDataService.clearActiveRide();
      setState(() => _phase = _TrackPhase.completed);
      _goToRating();
    } else if (status == 'cancelled' || status == 'canceled') {
      LocalDataService.clearActiveRide();
      widget.onTripComplete?.call();
    }
  }

  /// Listen to driver GPS from Firebase RTDB for sub-200ms updates.
  void _startRtdbDriverListener(String driverId) {
    _rtdbDriverLocSub?.cancel();
    _rtdbDriverId = driverId;
    _rtdbDriverLocSub = FirebaseDatabase.instance
        .ref('drivers/$driverId/location')
        .onValue
        .listen((event) {
      if (!mounted || _phase == _TrackPhase.completed) return;
      if (event.snapshot.value == null) return;
      final data = Map<String, dynamic>.from(event.snapshot.value as Map);
      final lat = (data['lat'] as num?)?.toDouble();
      final lng = (data['lng'] as num?)?.toDouble();
      if (lat == null || lng == null) return;
      _onRealDriverLocation(LatLng(lat, lng));
    }, onError: (_) {});
  }

  /// Start a simulation timer when there is no real Firestore trip
  /// (demo mode). Advances the car along the route to simulate navigation.
  void _startSimIfNeeded() {
    final fsId = widget.firestoreTripId;
    if (fsId != null && fsId.isNotEmpty) return; // real trip — skip sim

    // Advance ~13 m/s (~30 mph) every 16ms (60fps) for perfectly smooth motion
    const tickMs = 16;
    const speedMps = 13.0; // meters per second
    const advancePerTick = speedMps * (tickMs / 1000.0);

    _simTimer = Timer.periodic(const Duration(milliseconds: tickMs), (_) {
      if (!mounted || _segDist.isEmpty) return;
      final totalM = _segDist.last;
      if (totalM <= 0) return;

      _tgtTraveledM = (_tgtTraveledM + advancePerTick).clamp(0.0, totalM);

      // Phase transitions based on progress
      final progress = _tgtTraveledM / totalM;
      if (_phase == _TrackPhase.arriving && progress > 0.02) {
        // Simulate arriving at pickup after a bit of movement
        setState(() => _phase = _TrackPhase.arrived);
      }
      if (_phase == _TrackPhase.arrived && progress > 0.06) {
        setState(() => _phase = _TrackPhase.onTrip);
        _addDropoffPin();
      }
      if (_phase == _TrackPhase.onTrip && progress >= 0.98) {
        _simTimer?.cancel();
        LocalDataService.clearActiveRide();
        setState(() => _phase = _TrackPhase.completed);
        _goToRating();
        return;
      }

      // Update ETA
      final remainingM = totalM - _tgtTraveledM;
      _etaMinutes = (remainingM / (speedMps * 60)).ceil().clamp(1, 99);
      _distanceMiles = remainingM / 1609.34;

      _throttleCam();
    });
  }

  @override
  void dispose() {
    _interpTicker?.dispose();
    _camTimer?.cancel();
    _simTimer?.cancel();
    _entranceTimer?.cancel();
    _routeDrawTicker?.dispose();
    _tiltCtrl?.dispose();
    _bearingCtrl?.dispose();
    _glowPulseCtrl?.dispose();
    _driverLocSub?.cancel();
    _rtdbDriverLocSub?.cancel();
    _tripStatusSub?.cancel();
    _statusPollTimer?.cancel();
    _etaPulse.dispose();
    super.dispose();
  }

  void _goToRating() {
    if (!mounted) return;
    // Small delay so the user sees the completed banner briefly
    Future.delayed(const Duration(milliseconds: 800), () {
      if (!mounted) return;
      Navigator.of(context).pushReplacement(
        PageRouteBuilder(
          pageBuilder: (_, __, ___) => RiderRatingScreen(
            driverName: widget.driverName,
            tripId: widget.tripId,
            fare: widget.price,
          ),
          transitionsBuilder: (_, anim, __, child) =>
              FadeTransition(opacity: anim, child: child),
          transitionDuration: const Duration(milliseconds: 500),
        ),
      );
    });
  }

  void _showFeedbackDialog() {
    final controller = TextEditingController(text: _anonymousFeedback);
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(s.leaveAnonymousFeedback),
        content: TextField(
          controller: controller,
          maxLines: 4,
          maxLength: 500,
          decoration: InputDecoration(
            hintText: s.typeMessage,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.cancel),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() {
                _anonymousFeedback = controller.text.trim();
              });
              Navigator.of(ctx).pop();
            },
            child: Text(s.save),
          ),
        ],
      ),
    );
  }

  void _showCancelDialog() {
    final s = S.of(context);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF2A2A2A),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        title: Text(
          s.cancelRideQuestion,
          style: const TextStyle(color: Colors.white),
        ),
        content: Text(
          s.cancelRideConfirm,
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(s.no, style: const TextStyle(color: Colors.white70)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              // Clear persisted active ride so banner disappears
              LocalDataService.clearActiveRide();
              if (widget.tripId != null) {
                try {
                  await ApiService.cancelTrip(widget.tripId!);
                } catch (_) {}
              }
              if (!mounted) return;
              Navigator.of(context).pushAndRemoveUntil(
                PageRouteBuilder(
                  pageBuilder: (_, __, ___) => const HomeScreen(),
                  transitionsBuilder: (_, a, __, child) =>
                      FadeTransition(opacity: a, child: child),
                  transitionDuration: const Duration(milliseconds: 400),
                ),
                (_) => false,
              );
            },
            child: Text(
              s.cancelRide,
              style: const TextStyle(color: Color(0xFFFF3B30)),
            ),
          ),
        ],
      ),
    );
  }

  void _sendDriverGreeting() {
    if (!mounted || _greetingSent) return;
    _greetingSent = true;
    final firstName = widget.driverName.split(' ').first;
    _sendRideNotification(
      'Message from $firstName',
      'Hello! I\'m $firstName, your private driver. I\'ll be arriving shortly.',
    );
  }

  void _sendRideNotification(String title, String body) {
    NotificationService.show(id: title.hashCode, title: title, body: body);
    LocalDataService.addNotification(title: title, message: body, type: 'ride');
  }


  Future<void> _loadPins() async {
    _pickupPinBytes = await _renderGoldPin(
      isPickup: true,
      label: widget.pickupLabel,
    );
    _dropoffPinBytes = await _renderGoldPin(
      isPickup: false,
      label: widget.dropoffLabel,
    );
    // Build pin+label bitmap variants for animated label reveal
    if (widget.pickupLabel.trim().isNotEmpty) {
      _pickupPinWithLabelBytes = await _renderGoldPinWithLabel(
        isPickup: true,
        label: widget.pickupLabel,
      );
    }
    if (widget.dropoffLabel.trim().isNotEmpty) {
      _dropoffPinWithLabelBytes = await _renderGoldPinWithLabel(
        isPickup: false,
        label: widget.dropoffLabel,
      );
    }
    if (mounted) {
      setState(() {});
      // Force annotation update now that bytes are ready
      _updateAnnotations();
    }
  }

  // ── Navigation arrow mode (when centering/navigation active) ──
  final bool _navArrowMode = false;
  Uint8List? _arrowIconBytes;
  
  Future<void> _loadCarIcon() async {
    final rideName = widget.rideName.toLowerCase();
    String carAsset;
    
    if (rideName.contains('vip') || rideName.contains('suv') || rideName.contains('suburban')) {
      carAsset = 'assets/images/car_suv.png';
    } else if (rideName.contains('sedan') || rideName.contains('premium') || rideName.contains('fusion')) {
      carAsset = 'assets/images/car_sedan.png';
    } else {
      carAsset = 'assets/images/car_economy.png';
    }
    
    try {
      final bytes = await rootBundle.load(carAsset);
      _carIconBytes = bytes.buffer.asUint8List();
      _currentCarType = carAsset;
    } catch (e) {
      // Fallback to economy if specific car not found
      try {
        final bytes = await rootBundle.load('assets/images/car_economy.png');
        _carIconBytes = bytes.buffer.asUint8List();
        _currentCarType = 'assets/images/car_economy.png';
      } catch (_) {}
    }
    
    // Also load navigation arrow icon
    await _loadArrowIcon();
    
    if (mounted) setState(() {});
  }
  
  /// Load navigation arrow icon for centering mode
  Future<void> _loadArrowIcon() async {
    // Generate a golden arrow icon
    _arrowIconBytes = await _renderNavigationArrow();
  }
  
  /// Render a golden navigation arrow
  Future<Uint8List> _renderNavigationArrow() async {
    const double size = 100;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    const cx = size / 2;
    const cy = size / 2;
    const gold = Color(0xFFE8C547);
    
    // Drop shadow
    canvas.drawCircle(
      const Offset(cx, cy + 2),
      size * 0.4,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.4)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 8),
    );
    
    // Gold circle background
    canvas.drawCircle(
      const Offset(cx, cy),
      size * 0.38,
      Paint()..color = gold,
    );
    
    // White arrow pointing up
    final arrowPath = Path()
      ..moveTo(cx, cy - size * 0.22)
      ..lineTo(cx - size * 0.18, cy + size * 0.08)
      ..lineTo(cx - size * 0.06, cy + size * 0.08)
      ..lineTo(cx - size * 0.06, cy + size * 0.22)
      ..lineTo(cx + size * 0.06, cy + size * 0.22)
      ..lineTo(cx + size * 0.06, cy + size * 0.08)
      ..lineTo(cx + size * 0.18, cy + size * 0.08)
      ..close();
    
    canvas.drawPath(
      arrowPath,
      Paint()..color = Colors.white,
    );
    
    // Inner highlight
    canvas.drawCircle(
      Offset(cx - size * 0.1, cy - size * 0.1),
      size * 0.15,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.2)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4),
    );
    
    final picture = recorder.endRecording();
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }


  /// Inicia la animación de entrada del carro - transición profesional estilo "formación"
  void _startCarEntranceAnimation() {
    if (_carEntranceStarted || _carEntranceComplete) return;
    
    _carEntranceStarted = true;
    _entranceStartTime = DateTime.now();
    
    // Animar a 60fps durante 800ms
    _entranceTimer = Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (_entranceStartTime == null) {
        timer.cancel();
        return;
      }
      
      final elapsed = DateTime.now().difference(_entranceStartTime!).inMilliseconds;
      final progress = (elapsed / _entranceDuration).clamp(0.0, 1.0);
      
      // Easing curve elástico (bounce out)
      _carEntranceProgress = _elasticOut(progress);
      
      // Redibujar el carro con la nueva escala
      _updateCarSmooth();
      
      if (progress >= 1.0) {
        _carEntranceComplete = true;
        timer.cancel();
        _entranceTimer = null;
      }
    });
  }

  /// Elastic bounce easing - para efecto "formación" profesional
  double _elasticOut(double t) {
    const p = 0.3;
    return math.pow(2.0, -10 * t) * math.sin((t - p / 4) * (2 * math.pi) / p) + 1.0;
  }

  /// Ease out cubic - para transición suave final
  double _easeOutCubic(double t) {
    return 1.0 - math.pow(1.0 - t, 3);
  }

  /// Genera imagen de sombra con efecto fade/blur
  Future<Uint8List> _generateShadowImage() async {
    const double size = 80.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, size, size));
    
    // Dibujar círculo negro difuminado (sombra)
    final shadowPaint = Paint()
      ..color = Colors.black.withValues(alpha: 0.4)
      ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 15);
    
    canvas.drawCircle(
      const Offset(size / 2, size / 2 + 5), // Ligeramente desplazada hacia abajo
      size * 0.35,
      shadowPaint,
    );
    
    final picture = recorder.endRecording();
    final img = picture.toImageSync(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Detect location type from address label for contextual icon
  _PinIcon _detectPinIcon(String label) {
    final l = label.toLowerCase();
    if (l.contains('airport') ||
        l.contains('terminal') ||
        RegExp(
          r'\b(mia|fll|jfk|lax|ord|atl|sfo|dfw|ewr|bos|iah|dca|phl|msp|dtw|sea|den|las|mco|clt)\b',
        ).hasMatch(l)) {
      return _PinIcon.airplane;
    }
    if (l.contains('store') ||
        l.contains('shop') ||
        l.contains('mall') ||
        l.contains('plaza') ||
        l.contains('market') ||
        l.contains('center') ||
        l.contains('restaurant') ||
        l.contains('hotel') ||
        l.contains('bar') ||
        l.contains('café') ||
        l.contains('cafe') ||
        l.contains('gym') ||
        l.contains('salon') ||
        l.contains('office') ||
        l.contains('hospital') ||
        l.contains('clinic') ||
        l.contains('bank') ||
        l.contains('pharmacy')) {
      return _PinIcon.store;
    }
    if (RegExp(r'^\d+\s').hasMatch(l) &&
        RegExp(
          r'\b(st|ave|rd|dr|ln|ct|blvd|way|pkwy|pl|cir|ter|loop)\b',
        ).hasMatch(l)) {
      return _PinIcon.house;
    }
    return _PinIcon.person;
  }

  /// Renders a gold pin with contextual icon (100px).
  /// Pickup: circle. Dropoff: rounded square.
  /// Icon: house, store, airplane, or person based on address.
  Future<Uint8List> _renderGoldPin({
    required bool isPickup,
    String label = '',
  }) async {
    const double w = 100;
    const double h = 130;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, w, h));
    const cx = w / 2;
    const r = 30.0;
    const headCY = r + 8;
    const tipY = h;
    const gold = Color(0xFFE8C547);

    final iconType = _detectPinIcon(label);

    // ── Teardrop path (head + tail, tip at exact bottom) ──
    final path = Path()
      ..moveTo(cx - r, headCY)
      ..arcTo(
        Rect.fromCircle(center: const Offset(cx, headCY), radius: r),
        math.pi, -math.pi, false,
      )
      ..cubicTo(cx + r, headCY + r, cx + r * 0.22, tipY - 4, cx, tipY)
      ..cubicTo(cx - r * 0.22, tipY - 4, cx - r, headCY + r, cx - r, headCY)
      ..close();

    // Shadow
    canvas.drawPath(
      path.shift(const Offset(0, 3)),
      Paint()
        ..color = Colors.black.withValues(alpha: 0.30)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6),
    );
    // Gold fill
    canvas.drawPath(path, Paint()..color = gold);
    // White border
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2
        ..color = Colors.white.withValues(alpha: 0.35),
    );
    // Specular highlight
    canvas.drawCircle(
      Offset(cx - r * 0.25, headCY - r * 0.25),
      r * 0.4,
      Paint()
        ..color = Colors.white.withValues(alpha: 0.25)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );

    // ── White icon inside head ──
    final iconPaint = Paint()
      ..color = Colors.white
      ..isAntiAlias = true;
    const s = r * 0.43;
    const iy = headCY;

    switch (iconType) {
      case _PinIcon.house:
        final roofPath = Path()
          ..moveTo(cx, iy - s * 1.1)
          ..lineTo(cx - s * 1.0, iy - s * 0.15)
          ..lineTo(cx + s * 1.0, iy - s * 0.15)
          ..close();
        canvas.drawPath(roofPath, iconPaint);
        canvas.drawRect(
          Rect.fromLTRB(cx - s * 0.7, iy - s * 0.15, cx + s * 0.7, iy + s * 0.8),
          iconPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(cx - s * 0.2, iy + s * 0.2, cx + s * 0.2, iy + s * 0.8),
          Paint()..color = gold,
        );
        break;
      case _PinIcon.store:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(cx - s * 0.9, iy - s * 0.9, cx + s * 0.9, iy - s * 0.2),
            Radius.circular(s * 0.3),
          ),
          iconPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(cx - s * 0.9, iy - s * 0.2, cx + s * 0.9, iy + s * 0.8),
          iconPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(cx - s * 0.5, iy, cx + s * 0.5, iy + s * 0.5),
          Paint()..color = gold,
        );
        break;
      case _PinIcon.airplane:
        // Clean flight_takeoff glyph — no custom path
        final tp = TextPainter(
          text: TextSpan(
            text: String.fromCharCode(Icons.flight_takeoff_rounded.codePoint),
            style: TextStyle(
              fontSize: s * 2.8,
              fontFamily: Icons.flight_takeoff_rounded.fontFamily,
              package: Icons.flight_takeoff_rounded.fontPackage,
              color: Colors.white,
            ),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(
          canvas,
          Offset(cx - tp.width / 2, iy - tp.height / 2),
        );
        break;
      case _PinIcon.person:
        canvas.drawCircle(Offset(cx, iy - s * 0.5), s * 0.5, iconPaint);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(cx - s * 0.8, iy + s * 0.15, cx + s * 0.8, iy + s * 0.9),
            topLeft: Radius.circular(s * 0.8),
            topRight: Radius.circular(s * 0.8),
            bottomLeft: Radius.circular(s * 0.15),
            bottomRight: Radius.circular(s * 0.15),
          ),
          iconPaint,
        );
        break;
    }

    final picture = recorder.endRecording();
    final img = await picture.toImage(w.toInt(), h.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Renders a gold pin + address label as a single combined bitmap.
  /// The pin tip is at bottom-center for iconAnchor: BOTTOM.
  Future<Uint8List> _renderGoldPinWithLabel({
    required bool isPickup,
    required String label,
  }) async {
    // Get the standalone pin bitmap
    final pinBytes = await _renderGoldPin(isPickup: isPickup, label: label);
    final codec = await ui.instantiateImageCodec(pinBytes);
    final frame = await codec.getNextFrame();
    final pinImg = frame.image;

    // Truncate label
    String displayLabel = label;
    if (label.length > 20) {
      int cut = (label.length * 0.5).round();
      for (int i = cut; i >= 0; i--) {
        if (label[i] == ',' || label[i] == ' ') { cut = i; break; }
      }
      displayLabel = '${label.substring(0, cut).trimRight()}\u2026';
    }

    const pinW = 100.0;
    const pinH = 130.0;

    // Measure label text
    final textPainter = TextPainter(
      text: TextSpan(
        text: displayLabel,
        style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w600, color: Colors.white),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout(maxWidth: 450);

    // Label box sizing
    const hPad = 14.0;
    const gap = 8.0;
    const dotSize = 10.0;
    final labelW = hPad + dotSize + gap + textPainter.width + hPad + 8;
    const labelH = 70.0;
    const pinLabelGap = 8.0;

    // Pickup label on right, dropoff on left
    final labelOnLeft = !isPickup;
    final rawW = pinW + pinLabelGap + labelW;

    double pinX, labelX;
    if (labelOnLeft) {
      labelX = 0;
      pinX = labelW + pinLabelGap;
    } else {
      pinX = 0;
      labelX = pinW + pinLabelGap;
    }

    // Pad canvas so pin tip is at bottom-center
    final pinTipX = pinX + pinW / 2;
    final leftMargin = pinTipX;
    final rightMargin = rawW - pinTipX;
    final maxM = math.max(leftMargin, rightMargin);
    final leftPad = maxM - leftMargin;
    final paddedW = 2 * maxM;

    final adjPinX = pinX + leftPad;
    final adjLabelX = labelX + leftPad;
    final labelY = (pinH - labelH) / 2;

    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, Rect.fromLTWH(0, 0, paddedW, pinH));

    // Draw the pre-rendered pin image
    canvas.drawImage(pinImg, Offset(adjPinX, 0), Paint());

    // Draw label box
    final bgRect = RRect.fromRectAndRadius(
      Rect.fromLTWH(adjLabelX, labelY, labelW, labelH),
      const Radius.circular(10),
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

    // Color dot
    canvas.drawCircle(
      Offset(x + dotSize / 2, labelY + labelH / 2),
      dotSize / 2,
      Paint()..color = isPickup ? Colors.green : const Color(0xFFE8C547),
    );
    x += dotSize + gap;

    // Address text
    textPainter.paint(canvas, Offset(x, labelY + (labelH - textPainter.height) / 2));

    final picture = recorder.endRecording();
    final img = await picture.toImage(paddedW.ceil(), pinH.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
  }

  /// Reveal pickup label: swap bitmap + spring scale animation.
  void _revealPickupLabel() {
    if (_pickupLabelRevealed || _pickupAnnot == null || _pickupPinWithLabelBytes == null) return;
    _pickupLabelRevealed = true;
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    try {
      _pickupAnnot!.image = _pickupPinWithLabelBytes!;
      mgr.update(_pickupAnnot!);
    } catch (_) {}
    _labelSpringAnimation(_pickupAnnot!);
  }

  /// Reveal dropoff label: swap bitmap + spring scale animation.
  void _revealDropoffLabel() {
    if (_dropoffLabelRevealed || _dropoffAnnot == null || _dropoffPinWithLabelBytes == null) return;
    _dropoffLabelRevealed = true;
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    try {
      _dropoffAnnot!.image = _dropoffPinWithLabelBytes!;
      mgr.update(_dropoffAnnot!);
    } catch (_) {}
    _labelSpringAnimation(_dropoffAnnot!);
  }

  /// Spring scale animation for label reveal: 0.50 → 1.15 → 0.95 → 1.05 over 600ms.
  void _labelSpringAnimation(mapbox.PointAnnotation annot) {
    final mgr = _pointAnnotMgr;
    if (mgr == null) return;
    const duration = 600;
    final start = DateTime.now();
    Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted) { timer.cancel(); return; }
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final t = (elapsed / duration).clamp(0.0, 1.0);
      double scale;
      if (t < 0.5) {
        scale = 0.50 + (1.15 - 0.50) * (t / 0.5);
      } else if (t < 0.75) {
        scale = 1.15 + (0.95 - 1.15) * ((t - 0.5) / 0.25);
      } else {
        scale = 0.95 + (1.05 - 0.95) * ((t - 0.75) / 0.25);
      }
      try {
        mgr.update(annot..iconSize = scale);
      } catch (_) {}
      if (t >= 1.0) timer.cancel();
    });
  }

  Future<void> _initRoute() async {
    // 1) Get the trip route (pickup → dropoff)
    List<LatLng> tripRoute = [];
    if (widget.routePoints != null && widget.routePoints!.isNotEmpty) {
      tripRoute = List.from(widget.routePoints!);
    } else {
      final ds = DirectionsService(ApiKeys.webServices);
      final r = await ds.getRoute(
        origin: widget.pickupLatLng,
        destination: widget.dropoffLatLng,
      );
      if (r != null && mounted) tripRoute = r.points;
    }
    if (tripRoute.isEmpty) {
      tripRoute = [widget.pickupLatLng, widget.dropoffLatLng];
    }
    // Force endpoints to exact pin coordinates
    tripRoute[0] = widget.pickupLatLng;
    tripRoute[tripRoute.length - 1] = widget.dropoffLatLng;

    // 2) Set up route — driver position comes from Firestore in real time
    _pickupIdx = 0;
    _routePts = tripRoute;

    // Build cumulative distance array
    _buildSegDist();

    // 3) Driver starts at pickup (will be updated by Firestore stream)
    _traveledM = 0;
    _tgtTraveledM = 0;
    _driverPos = widget.pickupLatLng;
    _animPos = _driverPos;

    // 4) Calculate pickup → dropoff distance
    double acc = 0;
    for (int i = 0; i + 1 < _routePts.length; i++) {
      acc += _hav(_routePts[i], _routePts[i + 1]);
    }
    _distanceMiles = acc;
    _etaMinutes = (acc / 0.5).ceil().clamp(1, 99);

    setState(() {});
    Future.delayed(const Duration(milliseconds: 600), _fitAllPoints);
  }

  /// Initialize from persisted state or start fresh
  Future<void> _initFromPersistence() async {
    final activeRide = await LocalDataService.getActiveRide();
    if (activeRide == null) {
      // No persisted ride - initialize fresh
      await _initRoute();
      return;
    }

    // Check if this is the same trip
    var isSameTrip = activeRide.tripId != null && 
                     activeRide.tripId == widget.tripId;
    
    if (!isSameTrip && widget.firestoreTripId != null && 
        widget.firestoreTripId!.isNotEmpty &&
        activeRide.firestoreTripId == widget.firestoreTripId) {
      // Same trip by Firestore ID
      isSameTrip = true;
    }

    if (!isSameTrip) {
      // Different trip - start fresh
      await _initRoute();
      return;
    }

    // Restore route
    if (activeRide.routePoints.isNotEmpty) {
      _routePts = activeRide.routePoints
          .map((p) => LatLng(p[0], p[1]))
          .toList();
    } else if (widget.routePoints != null && widget.routePoints!.isNotEmpty) {
      _routePts = List.from(widget.routePoints!);
    }

    if (_routePts.isEmpty) {
      await _initRoute();
      return;
    }
    // Force endpoints to exact pin coordinates
    _routePts[0] = widget.pickupLatLng;
    _routePts[_routePts.length - 1] = widget.dropoffLatLng;

    _buildSegDist();

    // Restore phase
    if (activeRide.phase != null) {
      switch (activeRide.phase) {
        case 'arriving':
          _phase = _TrackPhase.arriving;
        case 'arrived':
          _phase = _TrackPhase.arrived;
        case 'onTrip':
          _phase = _TrackPhase.onTrip;
          _addDropoffPin();
        default:
          _phase = _TrackPhase.arriving;
      }
    }

    // Restore traveled distance for ETA calculation
    if (activeRide.traveledMeters != null && activeRide.traveledMeters! > 0) {
      _traveledM = activeRide.traveledMeters!;
      _tgtTraveledM = _traveledM;
    }

    // Compute position from restored traveled distance so we resume
    // at the correct point on the route (not back at pickup).
    if (_segDist.isNotEmpty && _traveledM > 0) {
      final (pos, brg) = _posAtDistUltraSmooth(_traveledM);
      _driverPos = pos;
      _animPos = pos;
      _animBearing = brg;
      _driverBearing = brg;
    } else {
      _driverPos = widget.pickupLatLng;
      _animPos = _driverPos;
    }

    // Calculate remaining distance
    double remainingM = _segDist.isNotEmpty ? _segDist.last - _traveledM : 0;
    _distanceMiles = remainingM / 1609.34;
    _etaMinutes = (_distanceMiles / 0.5).ceil().clamp(1, 99);

    setState(() {});
    Future.delayed(const Duration(milliseconds: 600), _fitAllPoints);
  }

  /// Save current ride state for resuming later
  Future<void> _saveRideState() async {
    if (_phase == _TrackPhase.completed) return;

    final activeRide = await LocalDataService.getActiveRide();
    if (activeRide == null) return;

    // Update with current progress
    String phaseStr = 'arriving';
    switch (_phase) {
      case _TrackPhase.arrived:
        phaseStr = 'arrived';
      case _TrackPhase.onTrip:
        phaseStr = 'onTrip';
      default:
        phaseStr = 'arriving';
    }

    final updatedRide = ActiveRideInfo(
      pickupLat: activeRide.pickupLat,
      pickupLng: activeRide.pickupLng,
      dropoffLat: activeRide.dropoffLat,
      dropoffLng: activeRide.dropoffLng,
      pickupLabel: activeRide.pickupLabel,
      dropoffLabel: activeRide.dropoffLabel,
      driverName: activeRide.driverName,
      driverRating: activeRide.driverRating,
      vehicleMake: activeRide.vehicleMake,
      vehicleModel: activeRide.vehicleModel,
      vehicleColor: activeRide.vehicleColor,
      vehiclePlate: activeRide.vehiclePlate,
      vehicleYear: activeRide.vehicleYear,
      rideName: activeRide.rideName,
      price: activeRide.price,
      routePoints: activeRide.routePoints,
      tripId: activeRide.tripId,
      firestoreTripId: activeRide.firestoreTripId,
      phase: phaseStr,
      driverLat: _animPos.latitude,
      driverLng: _animPos.longitude,
      traveledMeters: _traveledM,
      driverPhotoUrl: activeRide.driverPhotoUrl,
    );

    await LocalDataService.setActiveRide(updatedRide);
  }

  // Called every vsync frame via Ticker — GPU-synchronized, zero-jolt movement
  void _interpolate() {
    if (!mounted || _segDist.isEmpty) return;

    // ── Constant-speed advance — zero jolts ──
    // Sim advances tgtTraveledM ~0.208 m/frame. For tiny diffs snap directly
    // (perfect smoothness). For large GPS jumps cap at 1.5 m/frame so the
    // car catches up steadily instead of lurching forward.
    final diff = _tgtTraveledM - _traveledM;
    const maxStep = 1.5; // metres per frame ceiling
    if (diff.abs() <= maxStep) {
      _traveledM = _tgtTraveledM;
    } else {
      _traveledM += diff.sign * maxStep;
    }

    final (pos, brg) = _posAtDistUltraSmooth(_traveledM);

    // ── Bearing: smooth 5% rotation per frame (only car icon rotates, map stays north-up) ──
    double db = brg - _animBearing;
    if (db > 180) db -= 360;
    if (db < -180) db += 360;
    final newBearing = (_animBearing + db * 0.05) % 360;

    _animPos = pos;
    _animBearing = newBearing;
    _driverPos = pos;
    _driverBearing = newBearing;

    // ── Direct-target lerp (GPS fallback when off-route) ──
    final tgt = _directTargetPos;
    if (tgt != null) {
      const lerpFactor = 0.08; // smooth catch-up, never teleport
      final newLat = _animPos.latitude + (tgt.latitude - _animPos.latitude) * lerpFactor;
      final newLng = _animPos.longitude + (tgt.longitude - _animPos.longitude) * lerpFactor;
      final newBrg = _bearing(_animPos, LatLng(newLat, newLng));
      _animPos = LatLng(newLat, newLng);
      _driverPos = _animPos;
      if (newBrg != 0) {
        double db = newBrg - _animBearing;
        if (db > 180) db -= 360;
        if (db < -180) db += 360;
        _animBearing = (_animBearing + db * 0.05) % 360;
      }
    }

    // Update map annotations directly — no setState needed (avoids 60fps widget rebuilds)
    _throttleBoundsFit();
    _updateCarSmooth(); // fast path: only car GeoJSON
    _updateStaticAnnotationsOnce(); // slow path: pins + route, created once
  }

  // ── Camera: fit bounds to show full route (throttled, not every frame) ──
  DateTime _lastBoundsFit = DateTime(2000);

  void _throttleBoundsFit() {
    final now = DateTime.now();
    if (now.difference(_lastBoundsFit).inMilliseconds < 2000) return;
    _lastBoundsFit = now;
    _updateCameraForRoute();
  }
  
  Future<void> _applyDarkNavyGoldTheme(mapbox.MapboxMap ctrl) async {
    await MapTheme.applyNavyGold(ctrl);
  }

  void _updateCameraForRoute() {
    if (_map == null || _userMovedMap || _routePts.isEmpty) return;
    
    // Fit bounds to show full route + driver + pins
    final pts = <LatLng>[_animPos, widget.pickupLatLng];
    if (_phase == _TrackPhase.onTrip || _phase == _TrackPhase.completed) {
      pts.add(widget.dropoffLatLng);
    }
    // Include route extremes for a tight fit
    for (final p in _routePts) {
      pts.add(p);
    }
    
    double mnLat = pts[0].latitude, mxLat = pts[0].latitude;
    double mnLng = pts[0].longitude, mxLng = pts[0].longitude;
    for (final p in pts) {
      mnLat = math.min(mnLat, p.latitude);
      mxLat = math.max(mxLat, p.latitude);
      mnLng = math.min(mnLng, p.longitude);
      mxLng = math.max(mxLng, p.longitude);
    }
    
    _map!.cameraForCoordinatesPadding(
      [mapbox.Point(coordinates: mapbox.Position(mnLng, mnLat)),
       mapbox.Point(coordinates: mapbox.Position(mxLng, mxLat))],
      mapbox.CameraOptions(bearing: _cinematicBearing, pitch: _cinematicPitch),
      mapbox.MbxEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
      null, null,
    ).then((cam) {
      if (mounted && _map != null) _map!.setCamera(cam);
    });
  }

  /// Blend two bearings with smooth interpolation
  double _blendBearings(double b1, double b2, double t) {
    double diff = b2 - b1;
    if (diff > 180) diff -= 360;
    if (diff < -180) diff += 360;
    return (b1 + diff * t) % 360;
  }

  // ── Update camera target bounds (called from sim tick) ──
  void _throttleCam() {
    _updateCamTarget();
  }

  // ── Compute ideal bounds and set as smooth target ──
  void _updateCamTarget() {
    if (_map == null || _userMovedMap) return;
    final pts = <LatLng>[_animPos];
    if (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived) {
      pts.add(widget.pickupLatLng);
    }
    if (_phase == _TrackPhase.onTrip) {
      pts.add(widget.dropoffLatLng);
    }
    if (pts.length < 2) {
      pts.add(widget.pickupLatLng);
    }
    double mnLat = pts[0].latitude, mxLat = pts[0].latitude;
    double mnLng = pts[0].longitude, mxLng = pts[0].longitude;
    for (final p in pts) {
      mnLat = math.min(mnLat, p.latitude);
      mxLat = math.max(mxLat, p.latitude);
      mnLng = math.min(mnLng, p.longitude);
      mxLng = math.max(mxLng, p.longitude);
    }
    // Smooth padding proportional to span
    final latSpan = mxLat - mnLat;
    final lngSpan = mxLng - mnLng;
    final span = math.max(latSpan, lngSpan);
    final padFrac = span > 0.01 ? 0.10 : 0.18;
    final pad = span * padFrac;
    const minPad = 0.0003;
    final lp = math.max(pad, minPad);

    _tgtSWLat = mnLat - lp;
    _tgtSWLng = mnLng - lp;
    _tgtNELat = mxLat + lp;
    _tgtNELng = mxLng + lp;

    // First call → snap immediately (no lerp delay)
    if (!_camInitialized) {
      _camSWLat = _tgtSWLat;
      _camSWLng = _tgtSWLng;
      _camNELat = _tgtNELat;
      _camNELng = _tgtNELng;
      _camInitialized = true;
      _programmaticCam = true;
      _map!.cameraForCoordinatesPadding(
        [mapbox.Point(coordinates: mapbox.Position(_camSWLng, _camSWLat)),
         mapbox.Point(coordinates: mapbox.Position(_camNELng, _camNELat))],
        mapbox.CameraOptions(bearing: _cinematicBearing, pitch: _cinematicPitch),
        mapbox.MbxEdgeInsets(top: 40, left: 40, bottom: 40, right: 40),
        null, null,
      ).then((cam) {
        if (mounted) _map?.flyTo(cam, mapbox.MapAnimationOptions(duration: 500));
      });
    }
  }

  void _fitAllPoints() {
    _updateCamTarget();
  }

  void _recenter() {
    setState(() => _userMovedMap = false);
    _camInitialized = false; // force re-fit
    _updateCameraForRoute();
  }

  double _hav(LatLng a, LatLng b) {
    const R = 3958.8;
    final dLat = (b.latitude - a.latitude) * math.pi / 180;
    final dLon = (b.longitude - a.longitude) * math.pi / 180;
    final la = a.latitude * math.pi / 180;
    final lb = b.latitude * math.pi / 180;
    final h =
        math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(la) * math.cos(lb) * math.sin(dLon / 2) * math.sin(dLon / 2);
    return 2 * R * math.asin(math.sqrt(h));
  }

  double _bearing(LatLng f, LatLng t) {
    final dL = (t.longitude - f.longitude) * math.pi / 180;
    final la = f.latitude * math.pi / 180;
    final lb = t.latitude * math.pi / 180;
    final y = math.sin(dL) * math.cos(lb);
    final x =
        math.cos(la) * math.sin(lb) -
        math.sin(la) * math.cos(lb) * math.cos(dL);
    return (math.atan2(y, x) * 180 / math.pi + 360) % 360;
  }

  /// Build cumulative distance array (meters) for the route.
  void _buildSegDist() {
    _segDist = List.filled(_routePts.length, 0.0);
    for (int i = 1; i < _routePts.length; i++) {
      _segDist[i] =
          _segDist[i - 1] + _hav(_routePts[i - 1], _routePts[i]) * 1609.34;
    }
  }

  /// Returns (position, bearing) at a given distance along the route (meters).
  /// Ultra-smooth version with enhanced interpolation for realistic rolling motion.
  (LatLng, double) _posAtDistUltraSmooth(double distM) {
    if (_routePts.isEmpty) return (const LatLng(0, 0), 0);
    if (distM <= 0) {
      return (
        _routePts.first,
        _bearing(_routePts[0], _routePts[math.min(1, _routePts.length - 1)]),
      );
    }
    final totalM = _segDist.last;
    if (distM >= totalM) return (_routePts.last, _driverBearing);

    // Binary search for exact segment
    int lo = 0, hi = _segDist.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (_segDist[mid] <= distM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final segLen = _segDist[hi] - _segDist[lo];
    // Use smooth step interpolation for natural acceleration/deceleration
    final rawT = segLen > 0.01 ? (distM - _segDist[lo]) / segLen : 0.0;
    // Apply smoothstep curve: 3t² - 2t³ for ease-in-out effect
    final t = rawT * rawT * (3.0 - 2.0 * rawT);
    
    final a = _routePts[lo];
    final b = _routePts[hi];
    final lat = a.latitude + (b.latitude - a.latitude) * t;
    final lng = a.longitude + (b.longitude - a.longitude) * t;
    final pos = LatLng(lat, lng);

    // Enhanced bearing calculation with look-ahead for smoother turning
    // Look ahead 8 meters for more responsive but smooth turning
    final lookAhead = math.min(distM + 8, totalM);
    int llo = lo, lhi = hi;
    if (lookAhead > _segDist[hi]) {
      llo = hi;
      lhi = math.min(hi + 1, _segDist.length - 1);
      while (lhi < _segDist.length - 1 && _segDist[lhi] < lookAhead) {
        lhi++;
      }
    }
    final lookSegLen = _segDist[lhi] - _segDist[llo];
    final lookRawT = lookSegLen > 0.01
        ? (lookAhead - _segDist[llo]) / lookSegLen
        : 0.0;
    // Apply smoothstep to look-ahead as well
    final lookT = lookRawT * lookRawT * (3.0 - 2.0 * lookRawT);
    
    final la = _routePts[llo];
    final lb = _routePts[lhi];
    final lookPos = LatLng(
      la.latitude + (lb.latitude - la.latitude) * lookT,
      la.longitude + (lb.longitude - la.longitude) * lookT,
    );
    final brg = _bearing(pos, lookPos);
    return (pos, brg);
  }

  /// Returns (position, bearing) at a given distance along the route (meters).
  (LatLng, double) _posAtDist(double distM) {
    if (_routePts.isEmpty) return (const LatLng(0, 0), 0);
    if (distM <= 0) {
      return (
        _routePts.first,
        _bearing(_routePts[0], _routePts[math.min(1, _routePts.length - 1)]),
      );
    }
    final totalM = _segDist.last;
    if (distM >= totalM) return (_routePts.last, _driverBearing);

    // Binary search for segment
    int lo = 0, hi = _segDist.length - 1;
    while (lo < hi - 1) {
      final mid = (lo + hi) >> 1;
      if (_segDist[mid] <= distM) {
        lo = mid;
      } else {
        hi = mid;
      }
    }

    final segLen = _segDist[hi] - _segDist[lo];
    final t = segLen > 0.01 ? (distM - _segDist[lo]) / segLen : 0.0;
    final a = _routePts[lo];
    final b = _routePts[hi];
    final lat = a.latitude + (b.latitude - a.latitude) * t;
    final lng = a.longitude + (b.longitude - a.longitude) * t;
    final pos = LatLng(lat, lng);

    // Bearing: look ahead only ~5m so the car turns at the actual
    // curve instead of starting to rotate 30 m before it.
    final lookAhead = math.min(distM + 5, totalM);
    int llo = lo, lhi = hi;
    if (lookAhead > _segDist[hi]) {
      llo = hi;
      lhi = math.min(hi + 1, _segDist.length - 1);
      while (lhi < _segDist.length - 1 && _segDist[lhi] < lookAhead) {
        lhi++;
      }
    }
    final lt = (_segDist[lhi] - _segDist[llo]) > 0.01
        ? (lookAhead - _segDist[llo]) / (_segDist[lhi] - _segDist[llo])
        : 0.0;
    final la = _routePts[llo];
    final lb = _routePts[lhi];
    final lookPos = LatLng(
      la.latitude + (lb.latitude - la.latitude) * lt,
      la.longitude + (lb.longitude - la.longitude) * lt,
    );
    final brg = _bearing(pos, lookPos);
    return (pos, brg);
  }

  Widget _driverInitial() => Container(
    color: const Color(0xFF1A1A1A),
    child: Center(
      child: Text(
        widget.driverName.isNotEmpty ? widget.driverName[0].toUpperCase() : 'D',
        style: const TextStyle(
          color: Color(0xFFD4AF37), fontSize: 18, fontWeight: FontWeight.w700,
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) return;
        _saveRideState();
        Navigator.of(context).pushAndRemoveUntil(
          PageRouteBuilder(
            pageBuilder: (_, __, ___) => const HomeScreen(),
            transitionsBuilder: (_, a, __, child) =>
                FadeTransition(opacity: a, child: child),
            transitionDuration: const Duration(milliseconds: 300),
          ),
          (_) => false,
        );
      },
      child: AnnotatedRegion<SystemUiOverlayStyle>(
        value: SystemUiOverlayStyle.light,
        child: Scaffold(
          backgroundColor: const Color(0xFF111318),
          appBar: _buildAppBar(),
          body: Column(
            children: [
              const OfflineBanner(),
              _buildInfoPanel(),
              SizedBox(
                height: MediaQuery.of(context).size.height * 0.45,
                child: _buildMapCard(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── AppBar ──
  PreferredSizeWidget _buildAppBar() {
    final s = S.of(context);
    String statusLabel;
    switch (_phase) {
      case _TrackPhase.arriving:
        statusLabel = s.meetDriverAtPickup;
      case _TrackPhase.arrived:
        statusLabel = s.yourDriverArrivedExcl;
      case _TrackPhase.onTrip:
        statusLabel = s.onTripToDestination;
      case _TrackPhase.completed:
        statusLabel = s.youHaveArrived;
    }
    return AppBar(
      backgroundColor: const Color(0xFF111318),
      elevation: 0,
      leading: IconButton(
        icon: const Icon(Icons.arrow_back_ios_rounded, color: Colors.white, size: 20),
        onPressed: () {
          _saveRideState();
          Navigator.of(context).pushAndRemoveUntil(
            PageRouteBuilder(
              pageBuilder: (_, __, ___) => const HomeScreen(),
              transitionsBuilder: (_, a, __, child) =>
                  FadeTransition(opacity: a, child: child),
              transitionDuration: const Duration(milliseconds: 300),
            ),
            (_) => false,
          );
        },
      ),
      title: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              color: Color(0xFFD4AF37),
            ),
          ),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              statusLabel,
              style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      centerTitle: true,
    );
  }

  // ── Info Panel (top — fixed) ──
  Widget _buildInfoPanel() {
    final s = S.of(context);
    final destAddr = _phase == _TrackPhase.onTrip || _phase == _TrackPhase.completed
        ? (widget.dropoffLabel.trim().isNotEmpty ? widget.dropoffLabel : s.destinationLabel)
        : (widget.pickupLabel.trim().isNotEmpty ? widget.pickupLabel : s.pickupLocation);
    final statusTag = _phase == _TrackPhase.arrived
        ? s.yourDriverArrivedExcl
        : (_phase == _TrackPhase.onTrip ? s.onTripToDestination : s.meetDriverAtPickup);

    final vehicleLabel = [
      widget.vehicleColor,
      widget.vehicleMake,
      widget.vehicleModel,
    ].where((v) => v.isNotEmpty).join(' ');

    return Container(
      color: const Color(0xFF111318),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // ROW 1 — Destination + ETA
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      statusTag,
                      style: const TextStyle(
                        color: Color(0xFFD4AF37),
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      destAddr,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // ETA badge
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.15),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ],
                ),
                child: Column(
                  children: [
                    Text(
                      '$_etaMinutes',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Text(
                      'min',
                      style: TextStyle(color: Colors.black54, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Container(height: 1, color: Colors.white.withValues(alpha: 0.07)),
          const SizedBox(height: 12),
          // ROW 2 — Driver info
          Row(
            children: [
              // Driver photo with verified badge
              SizedBox(
                width: 52, height: 58,
                child: Stack(
                  clipBehavior: Clip.none,
                  children: [
                    Container(
                      width: 48, height: 48,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: const Color(0xFFD4AF37), width: 2),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFFD4AF37).withValues(alpha: 0.25),
                            blurRadius: 8,
                          ),
                        ],
                      ),
                      child: ClipOval(
                        child: widget.driverPhotoUrl != null && widget.driverPhotoUrl!.isNotEmpty
                            ? Image.network(
                                widget.driverPhotoUrl!,
                                width: 44, height: 44,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => _driverInitial(),
                              )
                            : _driverInitial(),
                      ),
                    ),
                    Positioned(
                      bottom: -2, right: -2,
                      child: Container(
                        width: 18,
                        height: 18,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: const Color(0xFFD4AF37),
                          border: Border.all(color: Colors.black, width: 1.5),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFFD4AF37).withValues(alpha: 0.4),
                              blurRadius: 6,
                              spreadRadius: 1,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.check_rounded,
                          color: Colors.black,
                          size: 11,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              // Name + rating
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.driverName,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 3),
                    Row(
                      children: [
                        const Icon(Icons.star_rounded, color: Color(0xFFD4AF37), size: 14),
                        const SizedBox(width: 3),
                        Text(
                          widget.driverRating.toStringAsFixed(1),
                          style: const TextStyle(color: Colors.white60, fontSize: 13),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Plate + model
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      widget.vehiclePlate.isNotEmpty
                          ? widget.vehiclePlate.toUpperCase()
                          : '---',
                      style: const TextStyle(
                        color: Colors.black,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.5,
                      ),
                    ),
                  ),
                  if (vehicleLabel.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      vehicleLabel,
                      style: TextStyle(color: Colors.white.withValues(alpha: 0.45), fontSize: 11),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 12),
          // ROW 3 — Chat + Call + More
          Row(
            children: [
              Expanded(
                child: GestureDetector(
                  onTap: () => Navigator.of(context).push(
                    slideFromRightRoute(
                      ChatScreen(
                        recipientName: widget.driverName.split(' ').first,
                        avatarInitial: widget.driverName.isNotEmpty
                            ? widget.driverName[0].toUpperCase()
                            : 'D',
                        tripId: widget.tripId,
                        currentRole: 'rider',
                      ),
                    ),
                  ),
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
                        decoration: BoxDecoration(
                          color: const Color(0xFF161A21),
                          borderRadius: BorderRadius.circular(24),
                          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
                        ),
                        child: Text(
                          S.of(context).typeMessage,
                          style: const TextStyle(color: Colors.white30, fontSize: 13),
                        ),
                      ),
                      if (widget.tripId != null)
                        StreamBuilder<int>(
                          stream: ChatService().unreadCountStream(
                            rideId: widget.tripId.toString(),
                            readerRole: 'rider',
                          ),
                          builder: (context, snap) {
                            final count = snap.data ?? 0;
                            if (count == 0) return const SizedBox.shrink();
                            return Positioned(
                              right: -4, top: -4,
                              child: Container(
                                padding: const EdgeInsets.all(4),
                                decoration: const BoxDecoration(
                                  color: Color(0xFFEF4444),
                                  shape: BoxShape.circle,
                                ),
                                constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                                child: Text(
                                  count > 9 ? '9+' : '$count',
                                  style: const TextStyle(
                                    color: Colors.white, fontSize: 10, fontWeight: FontWeight.w800,
                                  ),
                                  textAlign: TextAlign.center,
                                ),
                              ),
                            );
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              _buildPanelIconButton(
                icon: Icons.phone_rounded,
                onTap: () {},
              ),
              const SizedBox(width: 8),
              _buildPanelIconButton(
                icon: Icons.more_horiz_rounded,
                onTap: _phase == _TrackPhase.onTrip
                    ? _showCancelOnTripDialog
                    : _showCancelDialog,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPanelIconButton({required IconData icon, required VoidCallback onTap}) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 44, height: 44,
        decoration: BoxDecoration(
          color: const Color(0xFF1E222B),
          shape: BoxShape.circle,
          border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
        ),
        child: Icon(icon, color: Colors.white60, size: 20),
      ),
    );
  }

  // ── Map Card (bottom — expanded) ──
  Widget _buildMapCard() {
    return Container(
      color: const Color(0xFF111318),
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(20),
          boxShadow: [
            // Layer 1: Deep bottom shadow
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.6),
              blurRadius: 32, spreadRadius: 4, offset: const Offset(0, 16),
            ),
            // Layer 2: Mid shadow
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 16, spreadRadius: 2, offset: const Offset(0, 8),
            ),
            // Layer 3: Gold accent glow
            BoxShadow(
              color: const Color(0xFFD4AF37).withValues(alpha: 0.15),
              blurRadius: 24, spreadRadius: 2, offset: const Offset(0, 4),
            ),
            // Layer 4: Gold edge glow
            BoxShadow(
              color: const Color(0xFFD4AF37).withValues(alpha: 0.08),
              blurRadius: 40, spreadRadius: 4,
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: Stack(
            children: [
              RepaintBoundary(
                child: mapbox.MapWidget(
                  key: const ValueKey('rider-map'),
                  styleUri: MapboxConfig.styleDark,
                  cameraOptions: mapbox.CameraOptions(
                    center: mapbox.Point(
                      coordinates: mapbox.Position(
                        widget.pickupLatLng.longitude,
                        widget.pickupLatLng.latitude,
                      ),
                    ),
                    zoom: 14.0, pitch: 0.0,
                  ),
                  textureView: true,
                  onMapCreated: (ctrl) async {
                    _map = ctrl;
                    ctrl.scaleBar.updateSettings(mapbox.ScaleBarSettings(enabled: false));
                    ctrl.compass.updateSettings(mapbox.CompassSettings(enabled: false));
                    ctrl.attribution.updateSettings(mapbox.AttributionSettings(enabled: false));
                    ctrl.logo.updateSettings(mapbox.LogoSettings(enabled: false));
                    _polylineAnnotMgr = await ctrl.annotations.createPolylineAnnotationManager(
                      below: 'road-label',
                    );
                    _pointAnnotMgr = await ctrl.annotations.createPointAnnotationManager();
                    _updateAnnotations();
                  },
                  onStyleLoadedListener: (_) async {
                    if (_map != null) await _applyDarkNavyGoldTheme(_map!);
                  },
                  onScrollListener: (_) {
                    if (!_userMovedMap) setState(() => _userMovedMap = true);
                  },
                ),
              ),
              // Resume button (gold pill)
              if (_userMovedMap)
                Positioned(
                  bottom: 12, left: 0, right: 0,
                  child: Center(
                    child: GestureDetector(
                      onTap: _recenter,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.92),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: const Color(0xFFD4AF37).withValues(alpha: 0.4),
                            width: 1,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.3),
                              blurRadius: 8,
                            ),
                          ],
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.my_location_rounded, color: Color(0xFFD4AF37), size: 14),
                            SizedBox(width: 6),
                            Text('Resume', style: TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.w600)),
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

  Widget _circleBtn(IconData icon, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
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
        child: Icon(icon, size: 20, color: Colors.white),
      ),
    );
  }


  // ── Fast path: update only the car GeoJSON (called every 60fps frame) ──
  void _updateCarSmooth() {
    if (_carUpdateInProgress) return; // skip frame if previous update still running
    if (_map == null) return;
    if (_animPos.latitude == 0 && _animPos.longitude == 0) return;
    _carUpdateInProgress = true;
    _updateCarGeoJsonOnly().whenComplete(() => _carUpdateInProgress = false);
  }

  // Update only the car/shadow GeoJSON source positions (no layer recreation)
  Future<void> _updateCarGeoJsonOnly() async {
    if (_map == null) return;
    final iconBytes = _navArrowMode && _arrowIconBytes != null ? _arrowIconBytes! : _carIconBytes;
    if (iconBytes == null) return;
    try {
      final style = _map!.style;
      final imageId = _navArrowMode ? _arrowImageId : _carImageId;
      final isArrow = _navArrowMode;

      // ── First time: add image + create source + layer ──
      if (isArrow && !_arrowImageAdded && _arrowIconBytes != null) {
        await style.addStyleImage(_arrowImageId, 1.0,
          mapbox.MbxImage(width: 100, height: 100, data: _arrowIconBytes!),
          false, [], [], null);
        _arrowImageAdded = true;
      } else if (!isArrow && !_carImageAdded && _carIconBytes != null) {
        await style.addStyleImage(_carImageId, 1.0,
          mapbox.MbxImage(width: 64, height: 64, data: _carIconBytes!),
          false, [], [], null);
        _carImageAdded = true;
        // Shadow image
        _carShadowBytes ??= await _generateShadowImage();
        if (_carShadowBytes != null && !_carShadowAdded) {
          await style.addStyleImage(_carShadowImageId, 1.0,
            mapbox.MbxImage(width: 80, height: 80, data: _carShadowBytes!),
            false, [], [], null);
          _carShadowAdded = true;
        }
      }

      final lng = _animPos.longitude;
      final lat = _animPos.latitude;
      final brg = _animBearing;
      final geoJson = '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{"bearing":$brg}}]}';

      final sourceExists = await style.styleSourceExists(_carSourceId);
      if (!sourceExists) {
        // Create shadow source + layer first
        if (!isArrow && _carShadowAdded) {
          final shadowGeo = '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{}}]}';
          await style.addSource(mapbox.GeoJsonSource(id: _carShadowSourceId, data: shadowGeo));
          await style.addLayer(mapbox.SymbolLayer(
            id: _carShadowLayerId, sourceId: _carShadowSourceId,
            iconImage: _carShadowImageId, iconSize: 0.7,
            iconAnchor: mapbox.IconAnchor.CENTER,
            iconAllowOverlap: true, iconIgnorePlacement: true, iconOpacity: 0.5,
          ));
        }
        // Create car source + layer
        await style.addSource(mapbox.GeoJsonSource(id: _carSourceId, data: geoJson));
        final scale = isArrow ? 1.0 : (_carEntranceProgress * _kCarScale).clamp(0.001, _kCarScale);
        await style.addLayer(mapbox.SymbolLayer(
          id: _carLayerId, sourceId: _carSourceId,
          iconImage: imageId,
          iconSize: scale,
          iconOpacity: 1.0,
          iconRotate: isArrow ? 0.0 : brg,
          iconRotationAlignment: mapbox.IconRotationAlignment.MAP,
          iconAllowOverlap: true, iconIgnorePlacement: true,
        ));
        try { await style.moveStyleLayer(_carLayerId, null); } catch (_) {}
        if (!isArrow) _startCarEntranceAnimation();
      } else {
        // ── Hot path: just update position + rotation in existing source ──
        final source = await style.getSource(_carSourceId);
        if (source != null) (source as mapbox.GeoJsonSource).updateGeoJSON(geoJson);

        final layerExists = await style.styleLayerExists(_carLayerId);
        if (layerExists) {
          await style.setStyleLayerProperty(_carLayerId, 'icon-image', imageId);
          await style.setStyleLayerProperty(_carLayerId, 'icon-rotate', isArrow ? 0.0 : brg);
          final scale = isArrow ? 1.0 : (_carEntranceProgress * _kCarScale).clamp(0.001, _kCarScale);
          await style.setStyleLayerProperty(_carLayerId, 'icon-size', scale);
          try { await style.moveStyleLayer(_carLayerId, null); } catch (_) {}
        }

        // Update shadow position
        if (!isArrow) {
          final shadowGeo = '{"type":"FeatureCollection","features":[{"type":"Feature","geometry":{"type":"Point","coordinates":[$lng,$lat]},"properties":{}}]}';
          final shadowSrc = await style.getSource(_carShadowSourceId);
          if (shadowSrc != null) (shadowSrc as mapbox.GeoJsonSource).updateGeoJSON(shadowGeo);
        }
      }
    } catch (_) {}
  }

  // ── Slow path: create pins + route polylines once when bytes are ready ──
  bool _staticAnnotsDone = false;
  Future<void> _updateStaticAnnotationsOnce() async {
    if (_staticAnnotsDone) return;
    final pointMgr = _pointAnnotMgr;
    final polyMgr = _polylineAnnotMgr;
    if (pointMgr == null || polyMgr == null) return;
    if (_pickupPinBytes == null || _dropoffPinBytes == null) return;
    if (_routePts.length < 2) return;
    _staticAnnotsDone = true; // mark before await to prevent double-creation

    // Pickup pin — always visible
    try {
      _pickupAnnot ??= await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(widget.pickupLatLng.longitude, widget.pickupLatLng.latitude)),
        image: _pickupPinBytes!,
        iconSize: 1.05,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
    } catch (_) {}

    // Dropoff pin — only when onTrip or later
    if (_phase == _TrackPhase.onTrip || _phase == _TrackPhase.completed) {
      _addDropoffPin();
    }

    // Cinematic intro: tilt + bearing + route draw + glow
    _startCinematicIntro();

    // Reveal pickup label after brief delay
    if (_pickupPinWithLabelBytes != null && !_pickupLabelRevealed) {
      Future.delayed(const Duration(milliseconds: 600), () {
        if (!mounted) return;
        _revealPickupLabel();
      });
    }
  }

  /// Add dropoff pin (called once when phase transitions to onTrip)
  Future<void> _addDropoffPin() async {
    if (_dropoffPinAdded) return;
    final pointMgr = _pointAnnotMgr;
    if (pointMgr == null || _dropoffPinBytes == null) return;
    _dropoffPinAdded = true;
    try {
      _dropoffAnnot ??= await pointMgr.create(mapbox.PointAnnotationOptions(
        geometry: mapbox.Point(coordinates: mapbox.Position(widget.dropoffLatLng.longitude, widget.dropoffLatLng.latitude)),
        image: _dropoffPinBytes!,
        iconSize: 0.01,
        iconAnchor: mapbox.IconAnchor.BOTTOM,
        iconOffset: [0, 0],
      ));
      // Animate pin pop: 0.01 → 1.15 → 0.95 → 1.05 over 500ms
      _animateDropoffPinPop();
    } catch (_) {}
  }

  /// Pin pop spring animation for dropoff pin
  void _animateDropoffPinPop() {
    if (_dropoffAnnot == null || _pointAnnotMgr == null) return;
    const duration = 500;
    final start = DateTime.now();
    Timer.periodic(const Duration(milliseconds: 16), (timer) {
      if (!mounted) { timer.cancel(); return; }
      final elapsed = DateTime.now().difference(start).inMilliseconds;
      final t = (elapsed / duration).clamp(0.0, 1.0);
      double scale;
      if (t < 0.4) {
        scale = 0.01 + (1.15 - 0.01) * (t / 0.4);
      } else if (t < 0.7) {
        scale = 1.15 + (0.95 - 1.15) * ((t - 0.4) / 0.3);
      } else {
        scale = 0.95 + (1.05 - 0.95) * ((t - 0.7) / 0.3);
      }
      try {
        _pointAnnotMgr!.update(_dropoffAnnot!..iconSize = scale);
      } catch (_) {}
      if (t >= 1.0) {
        timer.cancel();
        // Reveal dropoff label after pin pop settles
        Future.delayed(const Duration(milliseconds: 300), () {
          if (!mounted) return;
          _revealDropoffLabel();
        });
      }
    });
  }

  /// Animated route draw: progressively reveals the 4-layer gold gloss route
  void _startAnimatedRouteDraw() {
    if (_routeDrawDone || _routePts.length < 2) return;
    _routeDrawDone = true;
    final polyMgr = _polylineAnnotMgr;
    if (polyMgr == null) return;

    final allCoords = _routePts.map((p) => mapbox.Position(p.longitude, p.latitude)).toList();
    final totalPts = allCoords.length;
    const drawDurationMs = 1000;
    final startTime = DateTime.now();

    // Create all 4 layers with just 2 initial points
    final initGeom = mapbox.LineString(coordinates: allCoords.sublist(0, 2));
    _createRouteLayers(polyMgr, initGeom);

    _routeDrawTicker = createTicker((_) {
      final elapsed = DateTime.now().difference(startTime).inMilliseconds;
      final t = (elapsed / drawDurationMs).clamp(0.0, 1.0);
      final count = (2 + (totalPts - 2) * _easeOutCubic(t)).round().clamp(2, totalPts);
      final geom = mapbox.LineString(coordinates: allCoords.sublist(0, count));
      _updateRouteLayers(polyMgr, geom);
      if (t >= 1.0) {
        _routeDrawTicker?.stop();
      }
    })..start();
  }

  Future<void> _createRouteLayers(mapbox.PolylineAnnotationManager mgr, mapbox.LineString geom) async {
    try { _fullRouteAnnot ??= await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFFD4AF37).withValues(alpha: 0.15).toARGB32(),
      lineWidth: 16.0, lineJoin: mapbox.LineJoin.ROUND,
    )); } catch (_) {}
    try { _routeCasingAnnot ??= await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFFD4AF37).withValues(alpha: 0.25).toARGB32(),
      lineWidth: 10.0, lineJoin: mapbox.LineJoin.ROUND,
    )); } catch (_) {}
    try { _remainingRouteAnnot ??= await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: const Color(0xFFD4AF37).toARGB32(),
      lineWidth: 5.0, lineJoin: mapbox.LineJoin.ROUND,
    )); } catch (_) {}
    try { _routeShineAnnot ??= await mgr.create(mapbox.PolylineAnnotationOptions(
      geometry: geom,
      lineColor: Colors.white.withValues(alpha: 0.25).toARGB32(),
      lineWidth: 1.5, lineJoin: mapbox.LineJoin.ROUND,
    )); } catch (_) {}
  }

  void _updateRouteLayers(mapbox.PolylineAnnotationManager mgr, mapbox.LineString geom) {
    try {
      if (_fullRouteAnnot != null) mgr.update(_fullRouteAnnot!..geometry = geom);
      if (_routeCasingAnnot != null) mgr.update(_routeCasingAnnot!..geometry = geom);
      if (_remainingRouteAnnot != null) mgr.update(_remainingRouteAnnot!..geometry = geom);
      if (_routeShineAnnot != null) mgr.update(_routeShineAnnot!..geometry = geom);
    } catch (_) {}
  }

  /// Cinematic map intro: fit → tilt 55° + random bearing → route draw → glow
  Future<void> _startCinematicIntro() async {
    if (_cinematicDone || _map == null) {
      _startAnimatedRouteDraw();
      return;
    }
    _cinematicDone = true;

    final rng = math.Random();
    final degrees = 5.0 + rng.nextDouble() * 10.0;
    _randomBearing = degrees * (rng.nextBool() ? 1.0 : -1.0);

    // 1. Fit camera flat first
    _updateCameraForRoute();
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;

    // 2. Tilt 0° → 55° + random bearing simultaneously (1200ms)
    _tiltCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _tiltAnim = Tween<double>(begin: 0.0, end: 55.0).animate(
      CurvedAnimation(parent: _tiltCtrl!, curve: Curves.easeInOutCubic),
    );
    _bearingCtrl = AnimationController(vsync: this, duration: const Duration(milliseconds: 1200));
    _bearingAnim = Tween<double>(begin: 0.0, end: _randomBearing).animate(
      CurvedAnimation(parent: _bearingCtrl!, curve: Curves.easeInOutCubic),
    );
    _tiltAnim!.addListener(_applyCinematicCamera);
    _tiltCtrl!.forward(from: 0);
    _bearingCtrl!.forward(from: 0);

    // 3. Route draw starts 500ms into tilt
    await Future.delayed(const Duration(milliseconds: 500));
    if (!mounted) return;
    _startAnimatedRouteDraw();

    // 4. Set final camera values for ongoing tracking
    await Future.delayed(const Duration(milliseconds: 700));
    if (!mounted) return;
    _cinematicPitch = 55.0;
    _cinematicBearing = _randomBearing;

    // 5. Glow pulse after route draw
    await Future.delayed(const Duration(milliseconds: 300));
    if (!mounted) return;
    _startGlowPulse();
  }

  void _applyCinematicCamera() {
    if (_map == null || !mounted) return;
    _map!.setCamera(mapbox.CameraOptions(
      pitch: _tiltAnim?.value,
      bearing: _bearingAnim?.value,
    ));
  }

  void _startGlowPulse() {
    _glowPulseCtrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    )..repeat(reverse: true);
    _glowPulseCtrl!.addListener(_onGlowTick);
  }

  void _onGlowTick() {
    final mgr = _polylineAnnotMgr;
    if (mgr == null || _fullRouteAnnot == null) return;
    final v = _glowPulseCtrl?.value ?? 0.0;
    _fullRouteAnnot!.lineWidth = 14.0 + v * 6.0;
    try { mgr.update(_fullRouteAnnot!); } catch (_) {}
  }

  Future<void> _updateAnnotations() async {
    _updateCarSmooth();
    await _updateStaticAnnotationsOnce();
  }

  /// Shows cancel confirmation dialog during onTrip phase
  void _showCancelOnTripDialog() {
    showDialog(
      context: context,
      barrierDismissible: true,
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
                  color: const Color(0xFFFF3B30).withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: const Icon(
                  Icons.warning_rounded,
                  color: Color(0xFFFF3B30),
                  size: 28,
                ),
              ),
              const SizedBox(height: 16),
              Text(
                S.of(context).cancelTripConfirm,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                S.of(context).cancelFeeWarning,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 14,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF3B30),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () async {
                    Navigator.pop(ctx);
                    // Cancel the trip
                    if (widget.tripId != null) {
                      try {
                        await ApiService.cancelTrip(widget.tripId!);
                        LocalDataService.clearActiveRide();
                      } catch (_) {}
                    }
                    if (mounted) {
                      Navigator.of(context).pushAndRemoveUntil(
                        PageRouteBuilder(
                          pageBuilder: (_, __, ___) => const HomeScreen(),
                          transitionsBuilder: (_, anim, __, child) =>
                              FadeTransition(opacity: anim, child: child),
                          transitionDuration: const Duration(milliseconds: 400),
                        ),
                        (_) => false,
                      );
                    }
                  },
                  child: Text(
                    S.of(context).yesCancelTrip,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFD4A843),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    // Navigate to contact support
                    Navigator.of(context).push(
                      slideFromRightRoute(
                        const ChatScreen(
                          recipientName: 'Support',
                          avatarInitial: 'S',
                          tripId: null,
                        ),
                      ),
                    );
                  },
                  child: Text(
                    S.of(context).contactSupport,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'No',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                    color: Colors.white.withValues(alpha: 0.6),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── Rating / Tip / Save overlay (shown when trip completes) ──
  Widget _ratingOverlay(double botPad) {
    final s = S.of(context);
    final chipOptions = [
      s.friendlyDriver,
      s.cleanCar,
      s.goodDriving,
      s.aboveAndBeyond,
      s.greatMusic,
      s.goodConversation,
    ];
    final first = widget.driverName.split(' ').first;
    const gold = Color(0xFFD4A843);

    String starLabel() {
      switch (_ratingStars) {
        case 1:
          return s.ratingPoor;
        case 2:
          return s.ratingBelowAverage;
        case 3:
          return s.ratingAverage;
        case 4:
          return s.ratingGreat;
        case 5:
          return s.ratingExcellent;
        default:
          return '';
      }
    }

    // Percentage-based tips
    final fare = widget.price > 0 ? widget.price : 23.0;
    final tipPercents = [15, 20, 25];

    return Container(
      constraints: BoxConstraints(
        maxHeight: MediaQuery.of(context).size.height * 0.78,
      ),
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 24,
            offset: const Offset(0, -6),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          physics: const BouncingScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Drag handle
              Container(
                margin: const EdgeInsets.only(top: 12, bottom: 16),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),

              // ── "How was your ride?" title ──
              Text(
                s.howWasRide,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 16),

              // ── Stars ──
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(5, (i) {
                  return GestureDetector(
                    onTap: () => setState(() => _ratingStars = i + 1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(
                        i < _ratingStars
                            ? Icons.star_rounded
                            : Icons.star_outline_rounded,
                        size: 48,
                        color: i < _ratingStars
                            ? gold
                            : Colors.white.withValues(alpha: 0.2),
                      ),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 8),

              // ── Star label ──
              Text(
                starLabel(),
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: gold,
                ),
              ),

              const SizedBox(height: 6),
              Text(
                s.whatWentWell,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white.withValues(alpha: 0.85),
                ),
              ),
              const SizedBox(height: 12),

              // ── Feedback chips ──
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: chipOptions.map((label) {
                  final sel = _feedbackChips.contains(label);
                  return GestureDetector(
                    onTap: () => setState(() {
                      sel
                          ? _feedbackChips.remove(label)
                          : _feedbackChips.add(label);
                    }),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: sel
                            ? gold.withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                          color: sel
                              ? gold
                              : Colors.white.withValues(alpha: 0.15),
                          width: sel ? 1.5 : 1,
                        ),
                      ),
                      child: Text(
                        label,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: sel
                              ? gold
                              : Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 16),

              // ── Leave anonymous feedback ──
              GestureDetector(
                onTap: _showFeedbackDialog,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      s.leaveAnonymousFeedback,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Icon(
                      Icons.edit_note_rounded,
                      size: 18,
                      color: Colors.white.withValues(alpha: 0.4),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
              const SizedBox(height: 20),

              // ── Tip section header ──
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          s.tipFor(first),
                          style: const TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          s.tipGoesToDriver,
                          style: TextStyle(
                            fontSize: 13,
                            color: Colors.white.withValues(alpha: 0.5),
                          ),
                        ),
                      ],
                    ),
                  ),
                  // Driver avatar
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: Colors.white.withValues(alpha: 0.1),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.2),
                        width: 2,
                      ),
                    ),
                    child: Center(
                      child: Text(
                        widget.driverName.isNotEmpty
                            ? widget.driverName[0].toUpperCase()
                            : 'D',
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // ── Percentage tip buttons ──
              Row(
                children: tipPercents.map((pct) {
                  final amt = (fare * pct / 100);
                  final sel = _tipAmount == amt && !_customTip;
                  return Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: pct != tipPercents.last ? 10 : 0,
                      ),
                      child: GestureDetector(
                        onTap: () => setState(() {
                          _customTip = false;
                          _tipAmount = sel ? 0 : amt;
                        }),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          height: 60,
                          decoration: BoxDecoration(
                            color: sel
                                ? gold.withValues(alpha: 0.15)
                                : Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: sel
                                  ? gold
                                  : Colors.white.withValues(alpha: 0.15),
                              width: sel ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Text(
                                '$pct%',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: sel
                                      ? gold
                                      : Colors.white.withValues(alpha: 0.8),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '\$${amt.toStringAsFixed(2)}',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w500,
                                  color: sel
                                      ? gold.withValues(alpha: 0.8)
                                      : Colors.white.withValues(alpha: 0.45),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),

              // Custom tip link
              GestureDetector(
                onTap: () => setState(() {
                  _customTip = !_customTip;
                  if (!_customTip) _tipAmount = 0;
                }),
                child: Text(
                  _customTip ? s.cancelCustomTip : s.enterCustomAmount,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: gold.withValues(alpha: 0.7),
                  ),
                ),
              ),

              if (_customTip) ...[
                const SizedBox(height: 10),
                SizedBox(
                  width: 140,
                  height: 48,
                  child: TextField(
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 20,
                      fontWeight: FontWeight.w700,
                    ),
                    textAlign: TextAlign.center,
                    decoration: InputDecoration(
                      prefixText: '\$ ',
                      prefixStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.5),
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                      ),
                      hintText: '0',
                      hintStyle: TextStyle(
                        color: Colors.white.withValues(alpha: 0.3),
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.08),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: gold),
                      ),
                      enabledBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: gold),
                      ),
                      focusedBorder: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: gold, width: 2),
                      ),
                      contentPadding: const EdgeInsets.symmetric(vertical: 10),
                    ),
                    onChanged: (v) {
                      final parsed = double.tryParse(v);
                      setState(() => _tipAmount = parsed ?? 0);
                    },
                  ),
                ),
              ],
              const SizedBox(height: 20),

              // ── Favorite driver ──
              GestureDetector(
                onTap: () => setState(() => _saveDriver = !_saveDriver),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 14,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: _saveDriver
                          ? gold
                          : Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 24,
                        height: 24,
                        decoration: BoxDecoration(
                          color: _saveDriver ? gold : Colors.transparent,
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(
                            color: _saveDriver
                                ? gold
                                : Colors.white.withValues(alpha: 0.3),
                            width: 2,
                          ),
                        ),
                        child: _saveDriver
                            ? const Icon(
                                Icons.check_rounded,
                                size: 16,
                                color: Colors.white,
                              )
                            : null,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              s.favoriteThisDriver,
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.w700,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              s.favoriteDriverNote,
                              style: TextStyle(
                                fontSize: 12,
                                color: Colors.white.withValues(alpha: 0.5),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // ── Send button ──
              SizedBox(
                width: double.infinity,
                height: 54,
                child: ElevatedButton(
                  onPressed: () async {
                    HapticFeedback.mediumImpact();
                    // Submit rating to backend
                    if (widget.tripId != null) {
                      try {
                        await ApiService.rateTrip(
                          tripId: widget.tripId!,
                          stars: _ratingStars,
                          tipAmount: _tipAmount,
                          comment: _anonymousFeedback.isNotEmpty
                              ? _anonymousFeedback
                              : null,
                        );
                      } catch (_) {}
                    }
                    if (!mounted) return;
                    // Navigate to rider home with smooth fade
                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (_, __, ___) => const HomeScreen(),
                        transitionsBuilder: (_, anim, __, child) {
                          return FadeTransition(opacity: anim, child: child);
                        },
                        transitionDuration: const Duration(milliseconds: 500),
                      ),
                      (_) => false,
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: gold,
                    foregroundColor: Colors.black,
                    elevation: 0,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(27),
                    ),
                  ),
                  child: Text(
                    s.send,
                    style: const TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
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

  Widget _driverRow(AppColors c) {
    final s = S.of(context);
    final first = widget.driverName.split(' ').first;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 52,
              height: 52,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white.withValues(alpha: 0.1),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.2),
                  width: 2,
                ),
              ),
              child: Center(
                child: Text(
                  widget.driverName.isNotEmpty
                      ? widget.driverName[0].toUpperCase()
                      : 'D',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.star, size: 14, color: Colors.white),
                const SizedBox(width: 2),
                Text(
                  widget.driverRating.toStringAsFixed(1),
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 80,
          height: 50,
          child: Image.asset(
            _vehicleAsset,
            fit: BoxFit.contain,
            filterQuality: FilterQuality.high,
            isAntiAlias: true,
            cacheWidth: 320,
            errorBuilder: (_, __, ___) => Icon(
              Icons.directions_car_rounded,
              size: 36,
              color: Colors.white.withValues(alpha: 0.3),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '${widget.vehicleColor} ${widget.vehicleMake}${widget.vehicleModel.isNotEmpty ? ' ${widget.vehicleModel}' : ''}',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const SizedBox(height: 4),
              Row(
                children: [
                  const Icon(
                    Icons.person_rounded,
                    size: 16,
                    color: Color(0xFF4CAF50),
                  ),
                  const SizedBox(width: 4),
                  Flexible(
                    child: Text(
                      first,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                        color: Colors.white,
                      ),
                    ),
                  ),
                  Text(
                    '  \u00B7  ',
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                  ),
                  Flexible(
                    child: Text(
                      s.topRatedDriver,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                        color: Colors.white54,
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }
}
