import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_maps_flutter/google_maps_flutter.dart';
import 'package:apple_maps_flutter/apple_maps_flutter.dart' as amap;

import '../config/app_theme.dart';
import '../config/map_styles.dart';
import '../config/page_transitions.dart';
import '../navigation/car_icon_loader.dart';
import '../services/api_service.dart';
import '../services/directions_service.dart';
import '../services/local_data_service.dart';
import '../services/notification_service.dart';
import '../services/trip_firestore_service.dart';
import '../config/api_keys.dart';
import 'chat_screen.dart';
import 'home_screen.dart';
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
  final VoidCallback? onTripComplete;

  @override
  State<RiderTrackingScreen> createState() => _RiderTrackingScreenState();
}

enum _TrackPhase { arriving, arrived, onTrip, completed }

enum _PinIcon { house, store, airplane, person }

class _RiderTrackingScreenState extends State<RiderTrackingScreen>
    with TickerProviderStateMixin {
  GoogleMapController? _map;
  amap.AppleMapController? _appleMap;
  BitmapDescriptor? _carIcon;
  Uint8List? _carIconBytes;
  Uint8List? _pickupPinBytes;
  Uint8List? _dropoffPinBytes;
  Uint8List? _rotatedCarBytes; // pre-rotated PNG for Apple Maps
  int _lastRotQ = -1; // last quantised bearing sent to CarIconLoader

  _TrackPhase _phase = _TrackPhase.arriving;
  bool _greetingSent = false;
  final bool _arrivedNotifSent = false;
  LatLng _driverPos = const LatLng(0, 0);
  LatLng _animPos = const LatLng(0, 0);
  double _driverBearing = 0;
  double _animBearing = 0;
  int _etaMinutes = 2;
  double _distanceMiles = 0;
  List<LatLng> _routePts = [];
  bool _showDetails = false;
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

  Timer? _interpTimer;

  /// Target traveled distance (set by sim timer, approached smoothly by interp timer)
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
  Timer? _statusPollTimer;

  late AnimationController _etaPulse;

  String get _vehicleAsset {
    final m = widget.vehicleModel.toLowerCase();
    if (m.contains('suburban')) return 'assets/images/suburban.png';
    if (m.contains('fusion')) return 'assets/images/fusion.png';
    return 'assets/images/camry.png';
  }

  @override
  void initState() {
    super.initState();
    _etaPulse = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _loadCarIcon();
    _initRoute();
    _interpTimer = Timer.periodic(
      const Duration(milliseconds: 16),
      _interpolate,
    );
    _startRealTimeTracking();
    // Send greeting notification after 3 seconds
    Future.delayed(const Duration(seconds: 3), _sendDriverGreeting);
    // Notify rider that a driver was assigned
    _sendRideNotification(
      'Driver Assigned',
      '${widget.driverName.split(' ').first} is on the way in a ${widget.vehicleColor} ${widget.vehicleModel}',
    );
  }

  /// Connect to Firestore for real-time driver location and trip status.
  void _startRealTimeTracking() {
    final fsId = widget.firestoreTripId;
    if (fsId != null && fsId.isNotEmpty) {
      // Watch driver location in real time
      _driverLocSub = TripFirestoreService.watchDriverLocation(fsId).listen((
        ll,
      ) {
        if (!mounted || _phase == _TrackPhase.completed) return;
        _onRealDriverLocation(ll);
      });

      // Watch trip status changes
      _tripStatusSub = TripFirestoreService.watchTrip(fsId).listen((data) {
        if (!mounted || data == null) return;
        _onTripStatusUpdate(data);
      });
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
            }
          } else if (st == 'cancelled' || st == 'canceled') {
            _statusPollTimer?.cancel();
            if (mounted) {
              LocalDataService.clearActiveRide();
              widget.onTripComplete?.call();
            }
          }
        } catch (_) {}
      });
    }
  }

  /// Process real-time driver location from Firestore.
  void _onRealDriverLocation(LatLng ll) {
    if (ll.latitude == 0 && ll.longitude == 0) return;

    // Project real driver position onto the route polyline to get _tgtTraveledM
    // so the interpolation timer smoothly animates the car along the route.
    if (_segDist.isNotEmpty && _routePts.length >= 2) {
      _tgtTraveledM = _projectOntoRoute(ll);
    }

    // Update distance/ETA based on current phase
    if (_phase == _TrackPhase.arriving) {
      final dist = _hav(ll, widget.pickupLatLng);
      _distanceMiles = dist;
      _etaMinutes = (dist / 0.5).ceil().clamp(1, 99);
      if (dist < 0.05) {
        setState(() => _phase = _TrackPhase.arrived);
        _sendRideNotification(
          'Your driver has arrived',
          '${widget.driverName.split(' ').first} is waiting at the pickup spot in a ${widget.vehicleColor} ${widget.vehicleModel}.',
        );
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
    double bestDist = double.infinity;
    double bestM = 0;

    for (int i = 0; i + 1 < _routePts.length; i++) {
      final a = _routePts[i];
      final b = _routePts[i + 1];
      final segLen = _segDist[i + 1] - _segDist[i];
      if (segLen < 0.01) continue;

      // Project p onto segment a→b using simple lat/lng linear approximation
      final dx = b.longitude - a.longitude;
      final dy = b.latitude - a.latitude;
      var t = 0.0;
      if (dx != 0 || dy != 0) {
        t =
            ((p.longitude - a.longitude) * dx +
                (p.latitude - a.latitude) * dy) /
            (dx * dx + dy * dy);
        t = t.clamp(0.0, 1.0);
      }
      final projLat = a.latitude + dy * t;
      final projLng = a.longitude + dx * t;

      final dist = _hav(p, LatLng(projLat, projLng));
      if (dist < bestDist) {
        bestDist = dist;
        bestM = _segDist[i] + segLen * t;
      }
    }

    return bestM;
  }

  /// Process trip status changes from Firestore.
  void _onTripStatusUpdate(Map<String, dynamic> data) {
    final status = data['status']?.toString() ?? '';
    if (status == 'driver_arrived' && _phase == _TrackPhase.arriving) {
      setState(() => _phase = _TrackPhase.arrived);
    } else if (status == 'in_progress' &&
        (_phase == _TrackPhase.arriving || _phase == _TrackPhase.arrived)) {
      setState(() => _phase = _TrackPhase.onTrip);
    } else if (status == 'completed' && _phase != _TrackPhase.completed) {
      LocalDataService.clearActiveRide();
      setState(() => _phase = _TrackPhase.completed);
    } else if (status == 'cancelled') {
      LocalDataService.clearActiveRide();
      widget.onTripComplete?.call();
    }
  }

  @override
  void dispose() {
    _interpTimer?.cancel();
    _camTimer?.cancel();
    _driverLocSub?.cancel();
    _tripStatusSub?.cancel();
    _statusPollTimer?.cancel();
    _etaPulse.dispose();
    super.dispose();
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

  Future<void> _loadCarIcon() async {
    // Use ride-specific car type: Suburban→SUV, Fusion→black, Camry→white
    final bytes =
        await CarIconLoader.loadForRideBytes(widget.rideName) ??
        await CarIconLoader.loadUberBytes();
    if (bytes != null) {
      _carIconBytes = bytes;
      final icon = BitmapDescriptor.bytes(bytes, width: 22, height: 44);
      if (mounted) setState(() => _carIcon = icon);
    }
    await _loadPins();
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
    if (mounted) setState(() {});
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
    const double size = 100;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder, const Rect.fromLTWH(0, 0, size, size));
    const cx = size / 2;
    const cy = size / 2;
    const r = size * 0.38;
    const gold = Color(0xFFE8C547);

    final iconType = _detectPinIcon(label);

    // Drop shadow
    canvas.drawCircle(
      const Offset(cx, cy + 2),
      r + 3,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.35)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 7),
    );

    if (isPickup) {
      canvas.drawCircle(const Offset(cx, cy), r, Paint()..color = gold);
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
      canvas.drawRRect(rect, Paint()..color = gold);
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

    // White contextual icon
    final iconPaint = Paint()
      ..color = Colors.white
      ..isAntiAlias = true;
    const s = size * 0.13;

    switch (iconType) {
      case _PinIcon.house:
        final roofPath = Path()
          ..moveTo(cx, cy - s * 1.1)
          ..lineTo(cx - s * 1.0, cy - s * 0.15)
          ..lineTo(cx + s * 1.0, cy - s * 0.15)
          ..close();
        canvas.drawPath(roofPath, iconPaint);
        canvas.drawRect(
          Rect.fromLTRB(
            cx - s * 0.7,
            cy - s * 0.15,
            cx + s * 0.7,
            cy + s * 0.8,
          ),
          iconPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(cx - s * 0.2, cy + s * 0.2, cx + s * 0.2, cy + s * 0.8),
          Paint()..color = gold,
        );
        break;
      case _PinIcon.store:
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(
              cx - s * 0.9,
              cy - s * 0.9,
              cx + s * 0.9,
              cy - s * 0.2,
            ),
            Radius.circular(s * 0.3),
          ),
          iconPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(cx - s * 0.9, cy - s * 0.2, cx + s * 0.9, cy + s * 0.8),
          iconPaint,
        );
        canvas.drawRect(
          Rect.fromLTRB(cx - s * 0.5, cy + s * 0.0, cx + s * 0.5, cy + s * 0.5),
          Paint()..color = gold,
        );
        break;
      case _PinIcon.airplane:
        final planePath = Path()
          ..moveTo(cx, cy - s * 1.1)
          ..lineTo(cx - s * 0.15, cy - s * 0.6)
          ..lineTo(cx - s * 1.0, cy - s * 0.1)
          ..lineTo(cx - s * 0.15, cy - s * 0.15)
          ..lineTo(cx - s * 0.15, cy + s * 0.5)
          ..lineTo(cx - s * 0.55, cy + s * 0.9)
          ..lineTo(cx - s * 0.15, cy + s * 0.75)
          ..lineTo(cx, cy + s * 1.0)
          ..lineTo(cx + s * 0.15, cy + s * 0.75)
          ..lineTo(cx + s * 0.55, cy + s * 0.9)
          ..lineTo(cx + s * 0.15, cy + s * 0.5)
          ..lineTo(cx + s * 0.15, cy - s * 0.15)
          ..lineTo(cx + s * 1.0, cy - s * 0.1)
          ..lineTo(cx + s * 0.15, cy - s * 0.6)
          ..close();
        canvas.drawPath(planePath, iconPaint);
        break;
      case _PinIcon.person:
        canvas.drawCircle(Offset(cx, cy - s * 0.5), s * 0.5, iconPaint);
        canvas.drawRRect(
          RRect.fromRectAndCorners(
            Rect.fromLTRB(
              cx - s * 0.8,
              cy + s * 0.15,
              cx + s * 0.8,
              cy + s * 0.9,
            ),
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
    final img = await picture.toImage(size.toInt(), size.toInt());
    final byteData = await img.toByteData(format: ui.ImageByteFormat.png);
    return byteData!.buffer.asUint8List();
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

  void _interpolate(Timer t) {
    if (!mounted || _segDist.isEmpty) return;

    // ── Smoothly advance _traveledM toward _tgtTraveledM along the route ──
    const chase = 0.18;
    _traveledM += (_tgtTraveledM - _traveledM) * chase;
    // Clamp small residuals
    if ((_tgtTraveledM - _traveledM).abs() < 0.01) _traveledM = _tgtTraveledM;

    // Get exact position & bearing ON the route polyline (no shortcuts)
    final (pos, brg) = _posAtDist(_traveledM);

    // Smooth bearing interpolation
    double db = brg - _animBearing;
    if (db > 180) db -= 360;
    if (db < -180) db += 360;
    final nb = (_animBearing + db * chase) % 360;

    // Only rebuild if something changed visually
    final dLat = (pos.latitude - _animPos.latitude).abs();
    final dLng = (pos.longitude - _animPos.longitude).abs();
    final dBrg = (nb - _animBearing).abs();
    if (dLat > 0.0000001 || dLng > 0.0000001 || dBrg > 0.01) {
      _animPos = pos;
      _animBearing = nb;
      _driverPos = pos;
      _driverBearing = nb;

      // On iOS, pre-rotate the car icon when bearing changes (Apple Maps has no rotation)
      if (Platform.isIOS) {
        final q = ((nb % 360) / 10).round() % 36;
        if (q != _lastRotQ) {
          _lastRotQ = q;
          CarIconLoader.rotateBytesForRide(nb, rideName: widget.rideName).then((
            bytes,
          ) {
            if (mounted) setState(() => _rotatedCarBytes = bytes);
          });
        }
      }

      setState(() {});
    }

    // ── Smooth camera bounds interpolation (60fps) ──
    final hasCtrl = Platform.isIOS ? _appleMap != null : _map != null;
    if (hasCtrl && !_userMovedMap && _camInitialized) {
      const lerpSpeed = 0.06;
      _camSWLat += (_tgtSWLat - _camSWLat) * lerpSpeed;
      _camSWLng += (_tgtSWLng - _camSWLng) * lerpSpeed;
      _camNELat += (_tgtNELat - _camNELat) * lerpSpeed;
      _camNELng += (_tgtNELng - _camNELng) * lerpSpeed;
      _programmaticCam = true;
      if (Platform.isIOS) {
        _appleMap!.moveCamera(
          amap.CameraUpdate.newLatLngBounds(
            amap.LatLngBounds(
              southwest: amap.LatLng(_camSWLat, _camSWLng),
              northeast: amap.LatLng(_camNELat, _camNELng),
            ),
            50,
          ),
        );
      } else {
        _map!.moveCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(_camSWLat, _camSWLng),
              northeast: LatLng(_camNELat, _camNELng),
            ),
            50,
          ),
        );
      }
    }
  }

  // ── Update camera target bounds (called from sim tick) ──
  void _throttleCam() {
    _updateCamTarget();
  }

  // ── Compute ideal bounds and set as smooth target ──
  void _updateCamTarget() {
    final hasCtrl = Platform.isIOS ? _appleMap != null : _map != null;
    if (!hasCtrl || _userMovedMap) return;
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
      if (Platform.isIOS) {
        _appleMap!.moveCamera(
          amap.CameraUpdate.newLatLngBounds(
            amap.LatLngBounds(
              southwest: amap.LatLng(_camSWLat, _camSWLng),
              northeast: amap.LatLng(_camNELat, _camNELng),
            ),
            50,
          ),
        );
      } else {
        _map!.moveCamera(
          CameraUpdate.newLatLngBounds(
            LatLngBounds(
              southwest: LatLng(_camSWLat, _camSWLng),
              northeast: LatLng(_camNELat, _camNELng),
            ),
            50,
          ),
        );
      }
    }
  }

  void _fitAllPoints() {
    _updateCamTarget();
  }

  void _recenter() {
    setState(() => _userMovedMap = false);
    _fitAllPoints();
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

    // Bearing: look ahead ~30m for smooth heading
    final lookAhead = math.min(distM + 30, totalM);
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

  @override
  Widget build(BuildContext context) {
    final c = AppColors.of(context);
    final topPad = MediaQuery.of(context).padding.top;
    final botPad = MediaQuery.of(context).viewPadding.bottom;

    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light,
      child: Scaffold(
        backgroundColor: const Color(0xFF1A1A1A),
        body: Stack(
          children: [
            RepaintBoundary(
              child: Platform.isIOS
                  ? amap.AppleMap(
                      initialCameraPosition: amap.CameraPosition(
                        target: amap.LatLng(
                          widget.pickupLatLng.latitude,
                          widget.pickupLatLng.longitude,
                        ),
                        zoom: 14,
                      ),
                      mapType: amap.MapType.standard,
                      onMapCreated: (ctrl) {
                        _appleMap = ctrl;
                      },
                      onCameraMove: (_) {
                        if (!_programmaticCam) {
                          setState(() => _userMovedMap = true);
                        }
                      },
                      onCameraIdle: () => _programmaticCam = false,
                      myLocationEnabled: false,
                      myLocationButtonEnabled: false,
                      pitchGesturesEnabled: true,
                      compassEnabled: false,
                      padding: EdgeInsets.only(
                        bottom: 370 + botPad,
                        top: topPad + 16,
                      ),
                      annotations: _appleAnnotations(),
                      polylines: _applePolylines(),
                    )
                  : GoogleMap(
                      style: MapStyles.dark,
                      initialCameraPosition: CameraPosition(
                        target: widget.pickupLatLng,
                        zoom: 14,
                      ),
                      onMapCreated: (ctrl) {
                        _map = ctrl;
                      },
                      onCameraMoveStarted: () {
                        if (!_programmaticCam) {
                          setState(() => _userMovedMap = true);
                        }
                      },
                      onCameraIdle: () => _programmaticCam = false,
                      markers: _markers(),
                      polylines: _polylines(),
                      myLocationEnabled: false,
                      myLocationButtonEnabled: false,
                      zoomControlsEnabled: false,
                      compassEnabled: false,
                      mapToolbarEnabled: false,
                      tiltGesturesEnabled: false,
                      padding: EdgeInsets.only(
                        bottom: 370 + botPad,
                        top: topPad + 16,
                      ),
                    ),
            ),
            // ── Back button ──
            Positioned(
              top: topPad + 12,
              left: 16,
              child: _circleBtn(
                Icons.arrow_back,
                () => Navigator.of(context).pop(),
              ),
            ),
            // Recenter button — visible only when user panned / zoomed
            if (_userMovedMap)
              Positioned(
                bottom: 370 + botPad,
                right: 16,
                child: _circleBtn(Icons.navigation_rounded, _recenter),
              ),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: _phase == _TrackPhase.completed
                  ? _ratingOverlay(botPad)
                  : _bottomCard(c, botPad),
            ),
          ],
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

  Widget _addressBar({
    required String label,
    required bool isPickup,
    int? etaMinutes,
  }) {
    return Container(
      height: 34,
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A1A),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Row(
        children: [
          // ETA badge for dropoff
          if (!isPickup && etaMinutes != null) ...[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '$etaMinutes',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w900,
                      color: Colors.white,
                      height: 1.1,
                    ),
                  ),
                  const Text(
                    'MIN',
                    style: TextStyle(
                      fontSize: 7,
                      fontWeight: FontWeight.w700,
                      color: Colors.white54,
                      height: 1.1,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 6),
          ] else
            const SizedBox(width: 10),
          // Gold dot
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: Color(0xFFD4A843),
              shape: BoxShape.circle,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: Colors.white,
              ),
            ),
          ),
          Icon(
            Icons.chevron_right_rounded,
            color: Colors.white.withValues(alpha: 0.3),
            size: 16,
          ),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  Widget _tripAddressRow({required Color iconColor, required String label}) {
    return Row(
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: iconColor, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w500,
              color: Colors.white.withValues(alpha: 0.7),
            ),
          ),
        ),
      ],
    );
  }

  Set<Marker> _markers() {
    final m = <Marker>{};
    final pickupPin = _pickupPinBytes != null
        // ignore: deprecated_member_use
        ? BitmapDescriptor.fromBytes(_pickupPinBytes!)
        : BitmapDescriptor.defaultMarker;
    final dropoffPin = _dropoffPinBytes != null
        // ignore: deprecated_member_use
        ? BitmapDescriptor.fromBytes(_dropoffPinBytes!)
        : BitmapDescriptor.defaultMarker;
    if (_carIcon != null) {
      m.add(
        Marker(
          markerId: const MarkerId('car'),
          position: _animPos,
          icon: _carIcon!,
          rotation: _animBearing,
          anchor: const Offset(0.5, 0.5),
          flat: true,
          zIndexInt: 10,
        ),
      );
    }
    m.add(
      Marker(
        markerId: const MarkerId('pickup'),
        position: widget.pickupLatLng,
        icon: pickupPin,
        zIndexInt: 5,
        infoWindow: const InfoWindow(title: 'Pickup spot'),
      ),
    );
    // Always show dropoff marker so rider sees full route
    m.add(
      Marker(
        markerId: const MarkerId('drop'),
        position: widget.dropoffLatLng,
        icon: dropoffPin,
        zIndexInt: 5,
      ),
    );
    return m;
  }

  // ── Apple Maps converters (iOS) ──

  Set<amap.Annotation> _appleAnnotations() {
    final a = <amap.Annotation>{};
    // Use pre-rotated icon so the car faces the travel direction
    final bytes = _rotatedCarBytes ?? _carIconBytes;
    if (bytes != null) {
      a.add(
        amap.Annotation(
          annotationId: amap.AnnotationId('car'),
          position: amap.LatLng(_animPos.latitude, _animPos.longitude),
          icon: amap.BitmapDescriptor.fromBytes(bytes),
          anchor: const Offset(0.5, 0.5),
          alpha: 1.0,
        ),
      );
    }
    final pickupIcon = _pickupPinBytes != null
        ? amap.BitmapDescriptor.fromBytes(_pickupPinBytes!)
        : amap.BitmapDescriptor.defaultAnnotation;
    final dropoffIcon = _dropoffPinBytes != null
        ? amap.BitmapDescriptor.fromBytes(_dropoffPinBytes!)
        : amap.BitmapDescriptor.defaultAnnotation;
    a.add(
      amap.Annotation(
        annotationId: amap.AnnotationId('pickup'),
        position: amap.LatLng(
          widget.pickupLatLng.latitude,
          widget.pickupLatLng.longitude,
        ),
        icon: pickupIcon,
      ),
    );
    a.add(
      amap.Annotation(
        annotationId: amap.AnnotationId('drop'),
        position: amap.LatLng(
          widget.dropoffLatLng.latitude,
          widget.dropoffLatLng.longitude,
        ),
        icon: dropoffIcon,
      ),
    );
    return a;
  }

  Set<amap.Polyline> _applePolylines() {
    final gPolys = _polylines();
    return gPolys
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

  Set<Polyline> _polylines() {
    if (_routePts.isEmpty) return {};
    final s = <Polyline>{};
    // Full route outline (dim) so rider always sees the complete path
    if (_routePts.length >= 2) {
      s.add(
        Polyline(
          polylineId: const PolylineId('full'),
          points: _routePts,
          color: const Color(0xFF3A3A3A),
          width: 4,
          geodesic: true,
        ),
      );
    }
    // Remaining route (blue) from driver position
    int idx = 0;
    if (_segDist.isNotEmpty) {
      while (idx < _segDist.length - 1 && _segDist[idx + 1] < _traveledM) {
        idx++;
      }
    }
    final remaining = [_animPos, ..._routePts.sublist(idx + 1)];
    if (remaining.length >= 2) {
      s.add(
        Polyline(
          polylineId: const PolylineId('route'),
          points: remaining,
          color: const Color(0xFF4285F4),
          width: 5,
          geodesic: true,
        ),
      );
    }
    return s;
  }

  Widget _bottomCard(AppColors c, double botPad) {
    final s = S.of(context);
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF1E1E1E),
        borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 20,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                margin: const EdgeInsets.only(top: 10, bottom: 14),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              _banner(c),
              if (_phase == _TrackPhase.arriving ||
                  _phase == _TrackPhase.arrived) ...[
                AnimatedSize(
                  duration: const Duration(milliseconds: 300),
                  curve: Curves.easeInOut,
                  alignment: Alignment.topCenter,
                  child: _showDetails
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Padding(
                              padding: const EdgeInsets.only(top: 10),
                              child: Text(
                                s.driverArriveInstruction,
                                style: TextStyle(
                                  fontSize: 14,
                                  color: Colors.white.withValues(alpha: 0.5),
                                  height: 1.3,
                                ),
                              ),
                            ),
                            const SizedBox(height: 10),
                            _tripAddressRow(
                              iconColor: const Color(0xFFD4A843),
                              label: widget.pickupLabel.isNotEmpty
                                  ? widget.pickupLabel
                                  : s.pickupLocation,
                            ),
                            const SizedBox(height: 6),
                            _tripAddressRow(
                              iconColor: const Color(0xFFD4A843),
                              label: widget.dropoffLabel.isNotEmpty
                                  ? widget.dropoffLabel
                                  : s.destinationLabel,
                            ),
                          ],
                        )
                      : const SizedBox.shrink(),
                ),
                const SizedBox(height: 8),
                GestureDetector(
                  onTap: () => setState(() => _showDetails = !_showDetails),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    child: Row(
                      children: [
                        Text(
                          _showDetails ? 'Show less' : 'Show more',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Colors.white.withValues(alpha: 0.7),
                          ),
                        ),
                        const SizedBox(width: 2),
                        AnimatedRotation(
                          turns: _showDetails ? 0.5 : 0,
                          duration: const Duration(milliseconds: 250),
                          child: Icon(
                            Icons.keyboard_arrow_down,
                            color: Colors.white.withValues(alpha: 0.7),
                            size: 20,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
              const SizedBox(height: 14),
              _driverRow(c),
              const SizedBox(height: 14),
              Divider(height: 1, color: Colors.white.withValues(alpha: 0.1)),
              const SizedBox(height: 6),
              SizedBox(
                width: double.infinity,
                height: 48,
                child: TextButton(
                  onPressed: () {
                    Navigator.of(context).push(
                      slideFromRightRoute(
                        ChatScreen(
                          recipientName: widget.driverName.split(' ').first,
                          avatarInitial: widget.driverName[0].toUpperCase(),
                        ),
                      ),
                    );
                  },
                  style: TextButton.styleFrom(
                    backgroundColor: Colors.white.withValues(alpha: 0.08),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        Icons.message_rounded,
                        size: 18,
                        color: Colors.white.withValues(alpha: 0.7),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        s.messageDriver(widget.driverName.split(' ').first),
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              if (_phase == _TrackPhase.arriving) ...[
                const SizedBox(height: 4),
                SizedBox(
                  width: double.infinity,
                  height: 40,
                  child: TextButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        slideFromRightRoute(
                          const ChatScreen(
                            recipientName: 'Cruise Support',
                            isSupport: true,
                          ),
                        ),
                      );
                    },
                    child: Text(
                      s.contactSupport,
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: Color(0xFFFF3B30),
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 4),
            ],
          ),
        ),
      ),
    );
  }

  Widget _banner(AppColors c) {
    final s = S.of(context);
    switch (_phase) {
      case _TrackPhase.arriving:
        return Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Expanded(
              child: RichText(
                text: TextSpan(
                  style: const TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                    height: 1.2,
                  ),
                  text: s.meetDriverAtPickup,
                ),
              ),
            ),
            const SizedBox(width: 14),
            AnimatedBuilder(
              animation: _etaPulse,
              builder: (_, _) {
                return Container(
                  width: 62,
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '$_etaMinutes',
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          height: 1,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'min',
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        );
      case _TrackPhase.arrived:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF1B3A1B),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(Icons.place_rounded, color: Colors.green.shade400, size: 22),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.yourDriverArrivedExcl,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.green.shade300,
                  ),
                ),
              ),
            ],
          ),
        );
      case _TrackPhase.onTrip:
        return Row(
          children: [
            Expanded(
              child: Text(
                s.onTripToDestination,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                '$_etaMinutes min',
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
            ),
          ],
        );
      case _TrackPhase.completed:
        return Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
          decoration: BoxDecoration(
            color: const Color(0xFF1B3A1B),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            children: [
              Icon(
                Icons.check_circle_rounded,
                color: Colors.green.shade400,
                size: 22,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  s.youHaveArrived,
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: Colors.green.shade300,
                  ),
                ),
              ),
            ],
          ),
        );
    }
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
                  final amt = (fare * pct / 100).roundToDouble();
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
                  onPressed: () {
                    HapticFeedback.mediumImpact();
                    // Navigate to rider home with smooth fade
                    Navigator.of(context).pushAndRemoveUntil(
                      PageRouteBuilder(
                        pageBuilder: (_, _, _) => const HomeScreen(),
                        transitionsBuilder: (_, anim, _, child) {
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
            errorBuilder: (_, _, _) => Icon(
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
